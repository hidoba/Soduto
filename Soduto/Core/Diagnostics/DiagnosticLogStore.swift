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
