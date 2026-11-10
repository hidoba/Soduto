import AppKit
import os
import UniformTypeIdentifiers

/// App integration for the persistent metadata journal and one-click export.
final class Diagnostics: NSObject {
    static let shared = Diagnostics()
    static let tracePreference = "diagnostics.packetTracing"
    static let writeLogsPreference = "diagnostics.writeLogs"
    static let loggingSettingDidChange = Notification.Name("SodutoDiagnosticLoggingDidChange")
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.hidoba.Soduto", category: "diagnostics")
    // Event metadata can call peer(), so this lock deliberately permits reentry.
    private let stateLock = NSRecursiveLock()
    private let preferences: UserDefaults
    private let directory: URL
    private var writingLogs: Bool
    private var journal: DiagnosticLogStore?
    private var aliases: [String: String] = [:]
    private weak var menu: NSMenu?
    private var exporting = false
    private var snapshotProvider: (() -> [String: Any])?
    private var recoveryAction: (() -> Void)?

    var packetTracingEnabled: Bool {
        get {
            stateLock.lock(); defer { stateLock.unlock() }
            return writingLogs && (preferences.object(forKey: Self.tracePreference) as? Bool ?? true)
        }
        set {
            stateLock.lock()
            preferences.set(newValue, forKey: Self.tracePreference)
            stateLock.unlock()
            publishSettingChange()
        }
    }

    var writeLogsEnabled: Bool {
        get {
            stateLock.lock(); defer { stateLock.unlock() }
            return writingLogs
        }
        set {
            stateLock.lock()
            guard newValue != writingLogs else { stateLock.unlock(); return }
            if !newValue, let journal {
                journal.record(DiagnosticEvent(session: journal.session, level: .info, event: "diagnostics.logging_disabled"))
            }
            writingLogs = newValue
            preferences.set(newValue, forKey: Self.writeLogsPreference)
            if newValue {
                recordEvent("diagnostics.logging_enabled")
            } else {
                // Drain queued events and close the file before Off takes effect.
                // Every enqueue uses stateLock, so no later event can slip through.
                journal?.close()
            }
            stateLock.unlock()
            publishSettingChange()
        }
    }

    init(userDefaults: UserDefaults = .standard, directory: URL? = nil) {
        preferences = userDefaults
        writingLogs = userDefaults.object(forKey: Self.writeLogsPreference) as? Bool ?? false
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = directory ?? root.appendingPathComponent("Soduto/Diagnostics", isDirectory: true)
        super.init()
    }

    deinit { journal?.close() }

    static func record(_ event: @autoclosure () -> String, level: DiagnosticEvent.Level = .info,
                       fields: @autoclosure () -> [String: String] = [:]) {
        shared.recordEvent(event(), level: level, fields: fields())
    }

    func recordEvent(_ event: @autoclosure () -> String, level: DiagnosticEvent.Level = .info,
                     fields: @autoclosure () -> [String: String] = [:]) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard writingLogs else { return }
        let store = journalLocked()
        let name = event()
        store.record(DiagnosticEvent(session: store.session, level: level, event: name, fields: fields()))
        switch level {
        case .error: logger.error("\(name, privacy: .public)")
        case .warning: logger.warning("\(name, privacy: .public)")
        default: logger.debug("\(name, privacy: .public)")
        }
    }

    static func peer(_ deviceID: @autoclosure () -> String?) -> String { shared.peerAlias(deviceID()) }

    func peerAlias(_ deviceID: @autoclosure () -> String?) -> String {
        stateLock.lock(); defer { stateLock.unlock() }
        guard writingLogs else { return "logging-disabled" }
        let deviceID = deviceID()
        guard let deviceID else { return "unknown" }
        if let alias = aliases[deviceID] { return alias }
        guard aliases.count < 4096 else { return "peer-overflow" }
        let alias = "peer-" + UUID().uuidString.prefix(8).lowercased()
        aliases[deviceID] = alias
        return alias
    }

    static func errorFields(_ error: Error) -> [String: String] {
        let nsError = error as NSError
        var fields = ["error_domain": nsError.domain, "error_code": String(nsError.code),
                      "error_type": String(reflecting: type(of: error))]
        // Enum case labels identify failures such as handshakeFailed without
        // serializing associated values (which may contain paths or payloads).
        let mirror = Mirror(reflecting: error)
        if mirror.displayStyle == .enum, let label = mirror.children.first?.label { fields["error_case"] = label }
        return fields
    }

    static func packet(_ direction: @autoclosure () -> String, type: @autoclosure () -> String,
                       id: @autoclosure () -> Int64, bytes: @autoclosure () -> Int,
                       connection: @autoclosure () -> String, device: @autoclosure () -> String) {
        shared.recordPacket(direction(), type: type(), id: id(), bytes: bytes(), connection: connection(), device: device())
    }

    func recordPacket(_ direction: @autoclosure () -> String, type: @autoclosure () -> String,
                      id: @autoclosure () -> Int64, bytes: @autoclosure () -> Int,
                      connection: @autoclosure () -> String, device: @autoclosure () -> String) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard packetTracingEnabled else { return }
        recordEvent("packet.\(direction())", level: .debug, fields: [
            "direction": direction(), "packet_type": type(), "packet_id": String(id()),
            "bytes": String(bytes()), "connection": connection(), "device": device()
        ])
    }

    func flush() {
        stateLock.lock(); defer { stateLock.unlock() }
        journal?.flush()
    }

    private func journalLocked() -> DiagnosticLogStore {
        if let journal { return journal }
        let store = DiagnosticLogStore(directory: directory)
        journal = store
        return store
    }

    private func publishSettingChange() {
        let update: @MainActor () -> Void = {
            self.updateMenuState()
            NotificationCenter.default.post(name: Self.loggingSettingDidChange, object: self)
        }
        if Thread.isMainThread { MainActor.assumeIsolated { update() } }
        else { DispatchQueue.main.async { update() } }
    }

    @MainActor
    func makeMenu(snapshot: @escaping () -> [String: Any], recover: @escaping () -> Void) -> NSMenuItem {
        snapshotProvider = snapshot
        recoveryAction = recover
        let parent = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Diagnostics")
        menu.autoenablesItems = false
        for (title, action) in [
            ("Write diagnostic logs", #selector(toggleLogWriting(_:))),
            ("Export Diagnostic Bundle…", #selector(exportDiagnostics(_:))),
            ("Open Diagnostic Logs", #selector(openLogs(_:))),
            ("Detailed Packet Logging", #selector(togglePacketTracing(_:))),
            ("Reconnect All Devices", #selector(reconnect(_:)))
        ] {
            if action == #selector(reconnect(_:)) { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        parent.submenu = menu
        self.menu = menu
        updateMenuState()
        return parent
    }

    @MainActor
    func updateMenuState() {
        let enabled = writeLogsEnabled
        for item in menu?.items ?? [] {
            switch item.action {
            case #selector(toggleLogWriting(_:)):
                item.state = enabled ? .on : .off
            case #selector(togglePacketTracing(_:)):
                item.isEnabled = enabled
                item.state = packetTracingEnabled ? .on : .off
            case #selector(exportDiagnostics(_:)), #selector(openLogs(_:)):
                item.isEnabled = enabled
            default: break
            }
        }
    }

    @objc private func toggleLogWriting(_ item: NSMenuItem) { writeLogsEnabled.toggle() }

    @objc private func togglePacketTracing(_ item: NSMenuItem) {
        guard writeLogsEnabled else { return }
        packetTracingEnabled.toggle()
        item.state = packetTracingEnabled ? .on : .off
        recordEvent("diagnostics.packet_tracing", fields: ["enabled": String(packetTracingEnabled)])
    }

    @objc private func reconnect(_ sender: Any?) {
        recordEvent("recovery.requested", fields: ["reason": "user"])
        recoveryAction?()
    }

    @objc private func openLogs(_ sender: Any?) {
        guard writeLogsEnabled else { return }
        stateLock.lock()
        let store = journalLocked()
        stateLock.unlock()
        store.flush()
        NSWorkspace.shared.open(store.directory)
    }

    @objc private func exportDiagnostics(_ sender: Any?) {
        guard writeLogsEnabled, !exporting else { return }
        stateLock.lock()
        let store = journalLocked()
        stateLock.unlock()
        exporting = true
        let panel = NSSavePanel()
        panel.title = "Export Soduto Diagnostics"
        panel.message = "Includes connection events and packet metadata. Clipboard text, messages, file contents and keys are excluded."
        panel.allowedContentTypes = [.zip]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "Soduto-Diagnostics-\(stamp).zip"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = panel.url else { self.exporting = false; return }
            let scoped = destination.startAccessingSecurityScopedResource()
            var summary = self.snapshotProvider?() ?? [:]
            summary["session"] = store.session
            summary["packet_tracing"] = self.packetTracingEnabled
            summary["write_logs"] = self.writeLogsEnabled
            summary["source_revision"] = Bundle.main.object(forInfoDictionaryKey: "SodutoSourceRevision") as? String ?? "unknown"
            if let error = store.lastError { summary["journal_error"] = Self.errorFields(error) }
            let baseSummary = summary
            self.recordEvent("diagnostics.export_started")
            DispatchQueue.global(qos: .utility).async {
                do {
                    let count = try DiagnosticBundleExporter.export(store: store, summary: baseSummary, to: destination)
                    self.recordEvent("diagnostics.export_finished", fields: ["count": String(count)])
                    DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                } catch {
                    self.recordEvent("diagnostics.export_failed", level: .error, fields: Self.errorFields(error))
                    DispatchQueue.main.async { NSAlert(error: error).runModal() }
                }
                DispatchQueue.main.async {
                    if scoped { destination.stopAccessingSecurityScopedResource() }
                    self.exporting = false
                }
            }
        }
    }
}
