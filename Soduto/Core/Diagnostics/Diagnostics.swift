import AppKit
import os
import UniformTypeIdentifiers

/// App integration for the persistent metadata journal and one-click export.
final class Diagnostics: NSObject {
    static let shared = Diagnostics()
    static let tracePreference = "diagnostics.packetTracing"
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.hidoba.Soduto", category: "diagnostics")
    private let store: DiagnosticLogStore
    private let aliasLock = NSLock()
    private var aliases: [String: String] = [:]
    private var exporting = false
    private var snapshotProvider: (() -> [String: Any])?
    private var recoveryAction: (() -> Void)?

    var packetTracingEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.tracePreference) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.tracePreference) }
    }

    private override init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        store = DiagnosticLogStore(directory: root.appendingPathComponent("Soduto/Diagnostics", isDirectory: true))
        super.init()
    }

    static func record(_ event: String, level: DiagnosticEvent.Level = .info, fields: [String: String] = [:]) {
        let instance = shared
        instance.store.record(DiagnosticEvent(session: instance.store.session, level: level, event: event, fields: fields))
        switch level {
        case .error: instance.logger.error("\(event, privacy: .public)")
        case .warning: instance.logger.warning("\(event, privacy: .public)")
        default: instance.logger.debug("\(event, privacy: .public)")
        }
    }

    static func peer(_ deviceID: String?) -> String {
        guard let deviceID else { return "unknown" }
        let instance = shared
        instance.aliasLock.lock()
        defer { instance.aliasLock.unlock() }
        if let alias = instance.aliases[deviceID] { return alias }
        guard instance.aliases.count < 4096 else { return "peer-overflow" }
        let alias = "peer-" + UUID().uuidString.prefix(8).lowercased()
        instance.aliases[deviceID] = alias
        return alias
    }

    static func errorFields(_ error: Error) -> [String: String] {
        let error = error as NSError
        return ["error_domain": error.domain, "error_code": String(error.code)]
    }

    static func packet(_ direction: String, type: String, id: Int64, bytes: Int,
                       connection: String, device: String) {
        guard shared.packetTracingEnabled else { return }
        record("packet.\(direction)", level: .debug, fields: [
            "direction": direction, "packet_type": type, "packet_id": String(id),
            "bytes": String(bytes), "connection": connection, "device": device
        ])
    }

    func flush() { store.flush() }

    func makeMenu(snapshot: @escaping () -> [String: Any], recover: @escaping () -> Void) -> NSMenuItem {
        snapshotProvider = snapshot
        recoveryAction = recover
        let parent = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Diagnostics")
        for (title, action) in [
            ("Export Diagnostic Bundle…", #selector(exportDiagnostics(_:))),
            ("Open Diagnostic Logs", #selector(openLogs(_:))),
            ("Detailed Packet Logging", #selector(togglePacketTracing(_:))),
            ("Reconnect All Devices", #selector(reconnect(_:)))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if action == #selector(togglePacketTracing(_:)) { item.state = packetTracingEnabled ? .on : .off }
            menu.addItem(item)
        }
        parent.submenu = menu
        return parent
    }

    @objc private func togglePacketTracing(_ item: NSMenuItem) {
        packetTracingEnabled.toggle()
        item.state = packetTracingEnabled ? .on : .off
        Self.record("diagnostics.packet_tracing", fields: ["enabled": String(packetTracingEnabled)])
    }

    @objc private func reconnect(_ sender: Any?) {
        Self.record("recovery.requested", fields: ["reason": "user"])
        recoveryAction?()
    }

    @objc private func openLogs(_ sender: Any?) {
        store.flush()
        NSWorkspace.shared.open(store.directory)
    }

    @objc private func exportDiagnostics(_ sender: Any?) {
        guard !exporting else { return }
        let panel = NSSavePanel()
        panel.title = "Export Soduto Diagnostics"
        panel.message = "Includes connection events and packet metadata. Clipboard text, messages, file contents and keys are excluded."
        panel.allowedContentTypes = [.zip]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "Soduto-Diagnostics-\(stamp).zip"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            self.exporting = true
            let scoped = destination.startAccessingSecurityScopedResource()
            var summary = self.snapshotProvider?() ?? [:]
            summary["session"] = self.store.session
            summary["packet_tracing"] = self.packetTracingEnabled
            summary["source_revision"] = Bundle.main.object(forInfoDictionaryKey: "SodutoSourceRevision") as? String ?? "unknown"
            if let error = self.store.lastError { summary["journal_error"] = Self.errorFields(error) }
            Self.record("diagnostics.export_started")
            DispatchQueue.global(qos: .utility).async {
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    let bundle = temporary.appendingPathComponent("Soduto-Diagnostics", isDirectory: true)
                    let files = try self.store.snapshot(to: bundle)
                    summary["log_files"] = files
                    let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: bundle.appendingPathComponent("summary.json"), options: .atomic)
                    try """
                    Soduto diagnostics — hidoba/Soduto
                    Events are newline-delimited JSON. Match session + connection + device aliases.
                    Files are newest first: events.jsonl, events.1.jsonl, etc. Sessions survive restarts.
                    Device aliases change each launch. No clipboard/message bodies, paths, addresses or keys are recorded.
                    summary.json describes app, network and device state at export time.
                    The journal retains up to four 5 MiB files. Detailed packet logging is on by default.
                    System Console logs are intentionally excluded: older upstream debug statements may contain personal data.
                    """.write(to: bundle.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
                    let archive = temporary.appendingPathComponent("diagnostics.zip")
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    process.arguments = ["-c", "-k", "--keepParent", bundle.path, archive.path]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
                    // Atomic replacement is handled by Data.write and the save-panel sandbox grant.
                    try Data(contentsOf: archive).write(to: destination, options: .atomic)
                    Self.record("diagnostics.export_finished", fields: ["count": String(files.count)])
                    DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                } catch {
                    Self.record("diagnostics.export_failed", level: .error, fields: Self.errorFields(error))
                    DispatchQueue.main.async { NSAlert(error: error).runModal() }
                }
                try? FileManager.default.removeItem(at: temporary)
                DispatchQueue.main.async {
                    if scoped { destination.stopAccessingSecurityScopedResource() }
                    self.exporting = false
                }
            }
        }
    }
}
