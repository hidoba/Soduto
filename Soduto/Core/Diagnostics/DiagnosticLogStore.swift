import Foundation

/// A serial, bounded journal. Files survive app restarts, including crashes.
/// Each line is independently parseable JSON; a partial last line is harmless.
final class DiagnosticLogStore {
    let directory: URL
    let session = UUID().uuidString
    private let queue = DispatchQueue(label: "com.hidoba.Soduto.diagnostics", qos: .utility)
    private let maxFileBytes: Int
    private let fileCount: Int
    private var handle: FileHandle?
    private var fileBytes = 0
    private var writeError: NSError?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    init(directory: URL, maxFileBytes: Int = 5 * 1024 * 1024, fileCount: Int = 4) {
        self.directory = directory
        self.maxFileBytes = max(1024, maxFileBytes)
        self.fileCount = max(1, fileCount)
    }

    deinit { try? handle?.close() }

    func record(_ event: DiagnosticEvent) {
        queue.async { [self] in
            do {
                var data = try encoder.encode(event)
                data.append(0x0a)
                // A single oversized event cannot defeat the size bound.
                guard data.count <= maxFileBytes else { return }
                try openIfNeeded()
                if fileBytes + data.count > maxFileBytes { try rotate() }
                try handle?.write(contentsOf: data)
                fileBytes += data.count
                if event.level == .error { try handle?.synchronize() }
            } catch {
                writeError = error as NSError
                try? handle?.close()
                handle = nil
            }
        }
    }

    func flush() { queue.sync { try? handle?.synchronize() } }

    var lastError: NSError? { queue.sync { writeError } }

    /// Snapshot on the writer queue, so export and rotation cannot race.
    func snapshot(to destination: URL) throws -> [String] {
        try queue.sync {
            try handle?.synchronize()
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var copied: [String] = []
            for index in 0..<fileCount {
                let source = fileURL(index)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let target = destination.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                copied.append(target.lastPathComponent)
            }
            return copied
        }
    }

    private func fileURL(_ index: Int) -> URL {
        directory.appendingPathComponent(index == 0 ? "events.jsonl" : "events.\(index).jsonl")
    }

    private func openIfNeeded() throws {
        guard handle == nil else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let url = fileURL(0)
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let opened = try FileHandle(forWritingTo: url)
        // A crash may leave half a JSON record. Trim it before appending the
        // next session, otherwise its first event would be glued to that tail.
        let existing = try Data(contentsOf: url, options: .mappedIfSafe)
        if let last = existing.last, last != 0x0a {
            let end = existing.lastIndex(of: 0x0a).map { $0 + 1 } ?? 0
            try opened.truncate(atOffset: UInt64(end))
        }
        fileBytes = Int(try opened.seekToEnd())
        handle = opened
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let manager = FileManager.default
        let oldest = fileURL(fileCount - 1)
        if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
        if fileCount > 1 {
            for index in stride(from: fileCount - 2, through: 0, by: -1) {
                let source = fileURL(index)
                if manager.fileExists(atPath: source.path) { try manager.moveItem(at: source, to: fileURL(index + 1)) }
            }
        }
        fileBytes = 0
        try openIfNeeded()
    }
}

/// Kept outside the UI so the same ZIP export used by the menu is regression-tested.
enum DiagnosticBundleExporter {
    @discardableResult
    static func export(store: DiagnosticLogStore, summary: [String: Any], to destination: URL) throws -> Int {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: temporary) }
        let bundle = temporary.appendingPathComponent("Soduto-Diagnostics", isDirectory: true)
        let files = try store.snapshot(to: bundle)
        var summary = summary
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
        System Console logs are excluded: inherited debug statements may contain personal data.
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
        try Data(contentsOf: archive).write(to: destination, options: .atomic)
        return files.count
    }
}
