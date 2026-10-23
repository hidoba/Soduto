// File clipboard regressions use a private temporary directory and fake peers.
func filePacket(_ data: Data, name: String = "example.txt", timestamp: Int64? = nil, marked: Bool = false) -> (DataPacket, DownloadTask) {
    let task = DownloadTask()
    var body: DataPacket.Body = ["filename": name as NSString]
    if marked { body["sodutoClipboardKind"] = "file" as NSString }
    if let timestamp { body["timestamp"] = NSNumber(value: timestamp); body["sodutoTimestamped"] = NSNumber(value: true) }
    var packet = DataPacket(type: "kdeconnect.clipboard.file", body: body)
    packet.payloadSize = Int64(data.count); packet.downloadTask = task
    return (packet, task)
}
func fileScenarios() {
    UserDefaults.standard.set(true, forKey: "incoming"); UserDefaults.standard.set(true, forKey: "outgoing")
    let manager = FileManager.default
    let root = clipboardTestDirectory.deletingLastPathComponent().appendingPathComponent("file-fixtures")
    try! manager.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("a copied file.txt")
    let contents = Data("synthetic file content".utf8)
    try! contents.write(to: source)
    NSPasteboard.general = NSPasteboard()
    let service = ClipboardService()
    let peer = Device("file-sender"), other = Device("file-other"), legacy = Device("file-incapable")
    legacy.incomingCapabilities = ["kdeconnect.clipboard"]
    let connection = Connection()
    for device in [peer, other, legacy] { service.setup(for: device); device.sent = [] }
    NSPasteboard.general.simulateFiles([source]); service.pollForTest(); service.finishImagesForTest()
    precondition(peer.sent.count == 1 && other.sent.count == 1 && legacy.sent.isEmpty)
    precondition(peer.sent[0].body["filename"] as? String == source.lastPathComponent)
    precondition(streamData(peer.sent[0].payload!) == contents && streamData(other.sent[0].payload!) == contents)
    print("PASS: one copied file sends its original filename and independent snapshots to capable peers")

    let snapshot = ClipboardFile.read(source)!
    try! Data("edited after the snapshot".utf8).write(to: source)
    precondition(snapshot.data == contents && (try! Data(contentsOf: source)) != snapshot.data)
    print("PASS: editing the original file cannot change an already captured upload snapshot")

    let received = Data("a file received from KDE".utf8)
    var (packet, task) = filePacket(received, name: "../../safe received.txt")
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection); task.finish(received)
    service.finishImagesForTest()
    let pasted = NSPasteboard.general.fileURLs.first!
    precondition(pasted.lastPathComponent == "safe received.txt" && pasted.path.hasPrefix(clipboardTestDirectory.path + "/"))
    precondition(try! Data(contentsOf: pasted) == received)
    precondition((try! manager.attributesOfItem(atPath: pasted.path)[.posixPermissions] as! NSNumber).intValue == 0o600)
    precondition((try! manager.attributesOfItem(atPath: pasted.deletingLastPathComponent().path)[.posixPermissions] as! NSNumber).intValue == 0o700)
    precondition(try! Data(contentsOf: source) == Data("edited after the snapshot".utf8))
    print("PASS: an incoming file becomes a private pasteable file URL with a safe filename and source files untouched")

    let before = NSPasteboard.general.changeCount
    let peerCount = peer.sent.count, otherCount = other.sent.count
    (packet, task) = filePacket(received, name: "safe received.txt")
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection); task.finish(received); service.finishImagesForTest()
    service.pollForTest()
    precondition(NSPasteboard.general.changeCount == before && peer.sent.count == peerCount && other.sent.count == otherCount)
    print("PASS: identical file payloads preserve the clipboard and do not echo")

    (packet, task) = filePacket(Data(), name: "empty.txt")
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection); task.finish(Data()); service.finishImagesForTest()
    precondition(NSPasteboard.general.fileURLs.first!.lastPathComponent == "empty.txt")
    precondition(try! Data(contentsOf: NSPasteboard.general.fileURLs.first!).isEmpty)
    var framed = DataPacket(type: "kdeconnect.clipboard.file", body: ["filename": "empty.txt" as NSString])
    framed.payload = InputStream(data: Data()); framed.payloadSize = 0; framed.payloadInfo = ["port": NSNumber(value: 1739)]
    let decoded = DataPacket(data: Data(try! framed.serialize()))!
    precondition(decoded.payloadSize == 0)
    let empty = root.appendingPathComponent("empty outgoing.txt"); try! Data().write(to: empty)
    peer.sent = []; NSPasteboard.general.simulateFiles([empty]); service.pollForTest(); service.finishImagesForTest()
    precondition(peer.sent.count == 1 && peer.sent[0].payloadSize == 0 && streamData(peer.sent[0].payload!).isEmpty)
    print("PASS: zero-byte files work in both directions and survive real packet serialization")

    let link = root.appendingPathComponent("link.txt"); try! manager.createSymbolicLink(at: link, withDestinationURL: source)
    let oversized = root.appendingPathComponent("oversized.bin"); manager.createFile(atPath: oversized.path, contents: nil)
    let handle = try! FileHandle(forWritingTo: oversized); try! handle.truncate(atOffset: UInt64(ClipboardFile.maximumBytes + 1)); try! handle.close()
    precondition(ClipboardFile.read(link) == nil && ClipboardFile.read(root) == nil && ClipboardFile.read(oversized) == nil)
    precondition(ClipboardFile.read(URL(string: "https://example.com/not-a-local-file")!) == nil)
    peer.sent = []
    NSPasteboard.general.simulateFiles([source, empty]); service.pollForTest(); service.finishImagesForTest()
    precondition(peer.sent.isEmpty)
    print("PASS: directories, symlinks, oversized files, remote URLs and multiple-file selections are rejected")

    NSPasteboard.general.simulateFiles([source]); service.pollForTest(); service.finishImagesForTest()
    let added = Device("new-file-peer"); service.setup(for: added); precondition(added.sent.isEmpty); service.cleanup(for: added)
    let remoteURL = DataPacket(type: "kdeconnect.clipboard.connect", body: ["content": "file:///tmp/remote-file.txt" as NSString,
        "timestamp": NSNumber(value: Date().addingTimeInterval(10).timeIntervalSince1970 * 1000)])
    let beforeConnect = NSPasteboard.general.changeCount
    _ = service.handleDataPacket(remoteURL, fromDevice: peer, onConnection: connection)
    precondition(NSPasteboard.general.changeCount == beforeConnect)
    print("PASS: reconnect neither replays a copied file nor replaces it with a remote temporary URL")

    (packet, task) = filePacket(received)
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection)
    NSPasteboard.general.simulateCopy("text after file transfer"); service.pollForTest(); task.finish(received); service.finishImagesForTest()
    precondition(task.cancelled && NSPasteboard.general.content == "text after file transfer" && NSPasteboard.general.fileURLs.isEmpty)
    (packet, task) = filePacket(received)
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection); task.finish(received)
    service.cleanup(for: peer); service.setup(for: peer); service.finishImagesForTest()
    precondition(NSPasteboard.general.content == "text after file transfer")
    print("PASS: newer copies and disconnect/reconnect invalidate pending file transfers and cached completions")

    UserDefaults.standard.set(false, forKey: "incoming")
    (packet, task) = filePacket(received); _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection)
    precondition(task.stream == nil)
    peer.sent = []; NSPasteboard.general.simulateFiles([source]); service.pollForTest(); service.finishImagesForTest(); precondition(peer.sent.count == 1)
    UserDefaults.standard.set(true, forKey: "incoming"); UserDefaults.standard.set(false, forKey: "outgoing")
    peer.sent = []; other.sent = []
    (packet, task) = filePacket(received); _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection)
    task.finish(received); service.finishImagesForTest()
    precondition(NSPasteboard.general.fileURLs.first!.lastPathComponent == "example.txt" && peer.sent.isEmpty && other.sent.isEmpty)
    UserDefaults.standard.set(true, forKey: "outgoing")
    print("PASS: incoming and outgoing settings independently govern file clipboard transfers")

    (packet, task) = filePacket(redPNG, name: "a real image file.png", marked: true)
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection); task.finish(redPNG); service.finishImagesForTest()
    let imageURL = NSPasteboard.general.fileURLs.first!
    precondition(imageURL.lastPathComponent == "a real image file.png" && (try! Data(contentsOf: imageURL)) == redPNG)
    precondition(NSPasteboard.general.data(forType: .png) != nil)
    let isolated = AppKit.NSPasteboard.withUniqueName(); defer { isolated.releaseGlobally() }
    isolated.clearContents(); precondition(isolated.writeObjects([imageURL as NSURL]))
    precondition(isolated.setData(NSPasteboard.general.data(forType: .png)!, forType: .png))
    let urls = isolated.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as! [URL]
    precondition(urls == [imageURL] && (isolated.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.count == 1)
    print("PASS: copied image files retain their original filename and bytes and offer native file and image pasteboard formats")

    let future = Int64(Date().addingTimeInterval(10800).timeIntervalSince1970 * 1000)
    let red = ClipboardImage.decode(redPNG)!, blue = ClipboardImage.decode(bluePNG)!
    let high = red.fingerprint.lexicographicallyPrecedes(blue.fingerprint) ? bluePNG : redPNG
    let low = high == redPNG ? bluePNG : redPNG
    (packet, task) = filePacket(high, name: "file-preview.png", timestamp: future, marked: true)
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection); task.finish(high); service.finishImagesForTest()
    let (image, imageTask) = imagePacket(low, timestamp: future)
    _ = service.handleDataPacket(image, fromDevice: other, onConnection: connection); imageTask.finish(low); service.finishImagesForTest()
    precondition(NSPasteboard.general.data(forType: .png).flatMap { ClipboardImage.decode($0) }?.fingerprint == ClipboardImage.decode(low)!.fingerprint)
    print("PASS: file image previews retain file generation ordering during simultaneous image/file copies")

    let cache = ClipboardFileStore(directory: root.appendingPathComponent("cache-prune"))
    let protected = cache.save(ClipboardFile(data: contents, name: "keep.txt"), protecting: [])!
    let removable = cache.save(ClipboardFile(data: contents, name: "expire.txt"), protecting: [protected])!
    let foreign = cache.directory.appendingPathComponent("not-owned-by-soduto")
    try! manager.createDirectory(at: foreign, withIntermediateDirectories: false)
    let fresh = cache.save(ClipboardFile(data: contents, name: "new.txt"), protecting: [protected], now: Date().addingTimeInterval(25 * 3600))!
    precondition(manager.fileExists(atPath: protected.path) && !manager.fileExists(atPath: removable.path) && manager.fileExists(atPath: fresh.path))
    precondition(manager.fileExists(atPath: foreign.path))
    cache.discard(source); precondition(manager.fileExists(atPath: source.path))
    print("PASS: cache expiry protects the current clipboard and never removes foreign directories or source files")

    let quota = ClipboardFileStore(directory: root.appendingPathComponent("cache-quota"))
    var stored: [URL] = []
    for index in 0..<5 {
        let url = quota.save(ClipboardFile(data: contents, name: "\(index).bin"), protecting: stored.first.map { [$0] } ?? [])!
        let file = try! FileHandle(forWritingTo: url); try! file.truncate(atOffset: UInt64(ClipboardFile.maximumBytes)); try! file.close()
        stored.append(url)
    }
    _ = quota.save(ClipboardFile(data: contents, name: "trigger.txt"), protecting: [stored[0]])
    let surviving = stored.filter { manager.fileExists(atPath: $0.path) }
    precondition(surviving.count <= 3 && surviving.contains(stored[0]))
    print("PASS: the private clipboard file cache enforces its disk budget while retaining the current clipboard")
}
fileScenarios()
