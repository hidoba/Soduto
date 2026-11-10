import Foundation
import CryptoKit
import Darwin

/// A bounded snapshot: later edits to the source file cannot change an upload.
struct ClipboardFile {
    static let maximumBytes = 50 * 1024 * 1024
    let data: Data
    let name: String
    let fingerprint: Data

    init(data: Data, name: String) {
        self.data = data
        self.name = Self.safeName(name)
        var hash = SHA256()
        hash.update(data: Data(self.name.utf8))
        hash.update(data: Data([0]))
        hash.update(data: data)
        fingerprint = Data(hash.finalize())
    }

    static func read(_ url: URL) -> ClipboardFile? {
        guard url.isFileURL else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Nonblocking/no-follow prevents clipboard URLs from opening FIFOs,
        // devices or symlinks. Check the opened descriptor, not just its path.
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= maximumBytes else { return nil }
        do {
            var data = Data()
            while data.count <= maximumBytes {
                guard let chunk = try handle.read(upToCount: min(1024 * 1024, maximumBytes + 1 - data.count)), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0, data.count <= maximumBytes,
                  data.count == before.st_size, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { return nil }
            return ClipboardFile(data: data, name: url.lastPathComponent)
        } catch { return nil }
    }

    static func safeName(_ input: String) -> String {
        var name = input.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "clipboard-file"
        name = String(name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || "/\\:".unicodeScalars.contains($0) ? "_" : String($0) }.joined())
        while name.utf8.count > 200 { name.removeLast() }
        return name.isEmpty || name == "." || name == ".." || name == "/" ? "clipboard-file" : name
    }
}

/// Received files need stable file URLs for Finder paste. Only private UUID
/// directories owned by this cache are pruned; source files are never modified.
final class ClipboardFileStore {
    let directory: URL
    static let maximumStoredBytes = 200 * 1024 * 1024
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hidoba.Soduto/Clipboard", isDirectory: true)
    }

    /// Staging never evicts existing files or publishes a clipboard URL. A slow
    /// or obsolete background transfer therefore cannot delete a user's selection.
    func stage(_ file: ClipboardFile) -> URL? {
        guard file.data.count <= ClipboardFile.maximumBytes else { return nil }
        let manager = FileManager.default
        let folder = directory.appendingPathComponent(".pending-" + UUID().uuidString, isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let destination = folder.appendingPathComponent(file.name)
            try file.data.write(to: destination, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return destination
        } catch {
            try? manager.removeItem(at: folder)
            return nil
        }
    }

    /// Called on the main queue after checking clipboard/connection freshness.
    func publish(_ staged: URL) -> URL? {
        let folder = staged.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              let id = pendingID(folder.lastPathComponent) else { return nil }
        let destination = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.moveItem(at: folder, to: destination)
            return destination.appendingPathComponent(staged.lastPathComponent)
        } catch { return nil }
    }

    func discard(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              UUID(uuidString: folder.lastPathComponent) != nil || pendingID(folder.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private func pendingID(_ name: String) -> UUID? {
        guard name.hasPrefix(".pending-") else { return nil }
        return UUID(uuidString: String(name.dropFirst(".pending-".count)))
    }

    /// Run after a successful clipboard commit. Re-read the live selection before
    /// every removal instead of retaining a snapshot from background decoding.
    func prune(protecting currentURLs: () -> [URL], now: Date = Date()) {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var entries: [(URL, Date, Int)] = []
        for folder in folders {
            let pending = pendingID(folder.lastPathComponent) != nil
            guard pending || UUID(uuidString: folder.lastPathComponent) != nil else { continue }
            guard let attributes = try? manager.attributesOfItem(atPath: folder.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
            let date = attributes[.creationDate] as? Date ?? .distantPast
            if pending {
                // Clean abandoned staging left by a crash, never active work.
                if now.timeIntervalSince(date) > 24 * 3600 { try? manager.removeItem(at: folder) }
                continue
            }
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let size = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            entries.append((folder, date, size))
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        for (folder, date, size) in entries.sorted(by: { $0.1 < $1.1 }) {
            let protected = Set(currentURLs().map { $0.deletingLastPathComponent().standardizedFileURL })
            guard !protected.contains(folder.standardizedFileURL) else { continue }
            if now.timeIntervalSince(date) > 24 * 3600 || total > Self.maximumStoredBytes {
                do { try manager.removeItem(at: folder); total -= size } catch { }
            }
        }
    }
}
