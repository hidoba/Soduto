#!/usr/bin/env python3
"""Exercise production log gating and UI with isolated preferences/temp files.

No real clipboard, keychain, app preferences or journal is modified. Windows stay hidden.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
stubs = r'''
import AppKit
enum Privacy { case `public` }
extension String.StringInterpolation {
    mutating func appendInterpolation<T>(_ value: T, privacy: Privacy) { appendLiteral(String(describing: value)) }
}
struct Logger {
    init(subsystem: String, category: String) {}
    func error(_ message: String) {}
    func warning(_ message: String) {}
    func debug(_ message: String) {}
}
protocol HostConfiguration {}
protocol DeviceDataSource: AnyObject {}
class DevicePreferencesViewController: NSViewController {
    var deviceDataSource: DeviceDataSource?
    var config: HostConfiguration?
    func refreshDeviceList() {}
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 320)) }
}
class ServicePreferencesViewController: NSViewController {
    var deviceDataSource: DeviceDataSource?
    func refreshDeviceList() {}
}
@MainActor final class StatusBarMenuController: NSObject {
    let statusBarMenu = NSMenu()
    @objc func quit(_ sender: Any?) {}
'''
status = (root / "Soduto/UI/Controllers/StatusBarMenuController.swift").read_text()
start = status.index("    func installDiagnosticsMenu(")
end = status.index("    func refreshDeviceLists()", start)
stubs += status[start:end] + "}\n"
checks = r'''
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let manager = FileManager.default
    let temporary = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let domain = "com.hidoba.Soduto.tests." + UUID().uuidString
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let folder = temporary.appendingPathComponent("journal", isDirectory: true)
    let diagnostics = Diagnostics(userDefaults: preferences, directory: folder)
    defer { diagnostics.writeLogsEnabled = false }
    func contents() -> Data { (try? Data(contentsOf: folder.appendingPathComponent("events.jsonl"))) ?? Data() }
    var evaluations = 0
    func fields() -> [String: String] { evaluations += 1; return ["count": "7"] }
    preferences.set(true, forKey: Diagnostics.tracePreference)
    diagnostics.recordEvent("synthetic.disabled", fields: fields())
    diagnostics.recordPacket("received", type: "synthetic", id: 1, bytes: 4, connection: "test", device: "test")
    diagnostics.flush()
    precondition(!diagnostics.writeLogsEnabled && !diagnostics.packetTracingEnabled)
    precondition(evaluations == 0 && !manager.fileExists(atPath: folder.path))
    print("PASS: logging defaults off even with legacy tracing enabled, without creating a journal or evaluating metadata")

    diagnostics.writeLogsEnabled = true
    diagnostics.recordEvent("synthetic.enabled", fields: ["device": diagnostics.peerAlias("private-id"), "content": "must not persist"])
    diagnostics.flush()
    precondition(preferences.bool(forKey: Diagnostics.writeLogsPreference))
    let enabled = String(decoding: contents(), as: UTF8.self)
    precondition(enabled.contains("synthetic.enabled") && !enabled.contains("private-id") && !enabled.contains("must not persist"))
    precondition(diagnostics.peerAlias("private-id") == diagnostics.peerAlias("private-id"))
    print("PASS: enabling persists the choice and writes allowlisted, aliased metadata")

    diagnostics.packetTracingEnabled = false
    diagnostics.recordPacket("received", type: "synthetic", id: 2, bytes: 4, connection: "test", device: "test")
    diagnostics.recordEvent("synthetic.lifecycle")
    diagnostics.flush()
    let withoutPackets = String(decoding: contents(), as: UTF8.self)
    precondition(withoutPackets.contains("synthetic.lifecycle") && !withoutPackets.contains("packet.received"))
    diagnostics.packetTracingEnabled = true
    diagnostics.recordPacket("received", type: "synthetic", id: 3, bytes: 4, connection: "test", device: "test")
    diagnostics.flush()
    precondition(String(decoding: contents(), as: UTF8.self).contains("packet.received"))
    print("PASS: packet tracing can be disabled independently while lifecycle logging continues")

    DispatchQueue.concurrentPerform(iterations: 80) { index in
        diagnostics.recordEvent("synthetic.concurrent", fields: ["count": String(index)])
    }
    diagnostics.writeLogsEnabled = false
    let stopped = contents()
    precondition(!stopped.isEmpty && !preferences.bool(forKey: Diagnostics.writeLogsPreference))
    DispatchQueue.concurrentPerform(iterations: 80) { _ in diagnostics.recordEvent("synthetic.after_disabled") }
    diagnostics.recordEvent("synthetic.disabled", fields: fields())
    diagnostics.flush()
    precondition(contents() == stopped && evaluations == 0)
    print("PASS: disabling drains pending writes, closes the writer, preserves existing logs and blocks later writes")

    let settings = DiagnosticsPreferencesViewController(diagnostics: diagnostics)
    let checkbox = settings.view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Write diagnostic logs" }!
    var recoveries = 0
    let parent = diagnostics.makeMenu(snapshot: { [:] }, recover: { recoveries += 1 })
    let menu = parent.submenu!
    let controller = StatusBarMenuController()
    let quit = NSMenuItem(title: "Quit", action: #selector(StatusBarMenuController.quit(_:)), keyEquivalent: "q")
    controller.statusBarMenu.addItem(NSMenuItem(title: "About", action: nil, keyEquivalent: ""))
    controller.statusBarMenu.addItem(quit)
    controller.installDiagnosticsMenu(parent)
    let quitIndex = controller.statusBarMenu.index(of: quit)
    precondition(controller.statusBarMenu.item(at: quitIndex - 1) === parent)
    precondition(!menu.autoenablesItems && menu.items.count == 6)
    precondition(menu.items[0].state == .off && checkbox.state == .off)
    precondition(menu.items[1...3].allSatisfy { !$0.isEnabled })
    precondition(menu.items[4].isSeparatorItem && !menu.items[5].isSeparatorItem)
    menu.performActionForItem(at: 5)
    precondition(recoveries == 1 && contents() == stopped)
    menu.performActionForItem(at: 0)
    precondition(diagnostics.writeLogsEnabled && checkbox.state == .on && menu.items[1...3].allSatisfy(\.isEnabled))
    checkbox.performClick(nil)
    precondition(!diagnostics.writeLogsEnabled && menu.items[0].state == .off && menu.items[1...3].allSatisfy { !$0.isEnabled })
    let tabs = PreferencesTabViewController()
    let devices = NSTabViewItem(viewController: DevicePreferencesViewController())
    devices.label = "Devices"
    tabs.addTabViewItem(devices)
    _ = tabs.view
    precondition(tabs.tabViewItems.contains { $0.label == "Diagnostics" })
    print("PASS: Settings and menu toggles synchronize, log actions disable when off, recovery remains available and Diagnostics is above Quit")

    let deviceRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let deviceActions = NSMenu(title: "Device actions")
    deviceRow.submenu = deviceActions
    DeviceMenuPresentation.apply(to: deviceRow, name: "Ubuntu desktop", type: "desktop",
                                 connected: true, battery: nil, charging: false)
    precondition(deviceRow.title == "Ubuntu desktop" && deviceRow.image != nil)
    precondition(deviceRow.view == nil && deviceRow.submenu === deviceActions)
    if #available(macOS 14.4, *) { precondition(deviceRow.subtitle == "Connected") }
    if deviceRow.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) {
        precondition((deviceRow.value(forKey: "preferredImageVisibility") as? NSNumber)?.intValue == 1)
    }
    print("PASS: a desktop without battery reports still has a visible device icon, native subtitle and its original submenu")

    DeviceMenuPresentation.apply(to: deviceRow, name: "Pixel phone", type: "phone",
                                 connected: true, battery: 84, charging: true,
                                 networks: ["LTE", "Unknown"])
    if #available(macOS 14.4, *) {
        precondition(deviceRow.subtitle == "Connected · 84% · Charging · LTE")
    }
    DeviceMenuPresentation.apply(to: deviceRow, name: "Pixel phone", type: "phone",
                                 connected: false, battery: 84, charging: true, networks: ["LTE"])
    if #available(macOS 14.4, *) { precondition(deviceRow.subtitle == "Offline") }
    DeviceMenuPresentation.apply(to: deviceRow, name: "Pixel phone", type: "phone",
                                 connected: true, battery: 150, charging: false, networks: ["5G\nInjected"])
    precondition(!deviceRow.toolTip!.contains("150%") && !deviceRow.toolTip!.contains("\n"))
    print("PASS: live battery/network updates preserve native rows and offline state removes stale service details")

    let relaunchFolder = temporary.appendingPathComponent("relaunch", isDirectory: true)
    var first: Diagnostics? = Diagnostics(userDefaults: preferences, directory: relaunchFolder)
    first!.writeLogsEnabled = true
    first!.recordEvent("synthetic.before_relaunch")
    first!.flush()
    first = nil
    let next = Diagnostics(userDefaults: preferences, directory: relaunchFolder)
    precondition(next.writeLogsEnabled)
    next.recordEvent("synthetic.after_relaunch")
    next.flush()
    let relaunched = try! String(contentsOf: relaunchFolder.appendingPathComponent("events.jsonl"), encoding: .utf8)
    precondition(relaunched.contains("synthetic.before_relaunch") && relaunched.contains("synthetic.after_relaunch"))
    next.writeLogsEnabled = false
    print("PASS: explicit logging choice survives relaunch and existing journal records remain readable")

    if CommandLine.arguments.count > 2 {
        settings.view.appearance = NSAppearance(named: .aqua)
        settings.view.wantsLayer = true
        settings.view.layer?.backgroundColor = NSColor.white.cgColor
        let window = NSWindow(contentRect: settings.view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = settings.view
        settings.view.layoutSubtreeIfNeeded()
        let bitmap = settings.view.bitmapImageRepForCachingDisplay(in: settings.view.bounds)!
        settings.view.cacheDisplay(in: settings.view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
}
'''
with tempfile.TemporaryDirectory(prefix="soduto-diagnostics-settings-") as temporary:
    temporary = Path(temporary)
    source = temporary / "main.swift"
    source.write_text(stubs + (root / "Soduto/Core/Diagnostics/Diagnostics.swift").read_text().replace("import os", "") +
                      (root / "Soduto/UI/Controllers/PreferencesWindowController.swift").read_text() + checks)
    executable = temporary / "settings-tests"
    subprocess.run(["swiftc", str(root / "Soduto/Core/Diagnostics/DiagnosticEvent.swift"),
                    str(root / "Soduto/Core/Diagnostics/DiagnosticLogStore.swift"),
                    str(root / "Soduto/UI/Views/MenuView.swift"), str(source),
                    "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(temporary), *sys.argv[1:]], check=True)
