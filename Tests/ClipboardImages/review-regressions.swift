// Regressions for the build-33 review. No general pasteboard or real peer is used.
func reviewRegressions() {
    let manager = FileManager.default
    let root = clipboardTestDirectory.deletingLastPathComponent().appendingPathComponent("review-regressions")
    try! manager.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("outgoing.txt")
    try! Data("outgoing file".utf8).write(to: source)
    func fresh(_ name: String) -> (ClipboardService, Device, Device) {
        UserDefaults.standard.set(true, forKey: "incoming"); UserDefaults.standard.set(true, forKey: "outgoing")
        NSPasteboard.general = NSPasteboard()
        let service = ClipboardService(clipboardFileDirectory: root.appendingPathComponent(name))
        let peer = Device("KDE"), other = Device("other")
        for device in [peer, other] { service.setup(for: device); device.sent = [] }
        return (service, peer, other)
    }
    func deliver(_ data: Data, name: String, to service: ClipboardService, from peer: Device) {
        let (packet, task) = filePacket(data, name: name) // Official KDE sends no Soduto kind marker.
        _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: Connection())
        task.finish(data); service.finishImagesForTest()
    }
    func localFile(_ service: ClipboardService) {
        NSPasteboard.general.simulateFiles([source]); service.pollForTest(); service.finishImagesForTest()
    }
    func cached(_ file: ClipboardFile, in store: ClipboardFileStore) -> URL { store.publish(store.stage(file)!)! }
    do {
        let (service, peer, _) = fresh("obsolete-cache")
        let store = ClipboardFileStore(directory: root.appendingPathComponent("obsolete-cache"))
        let a = cached(ClipboardFile(data: Data("A".utf8), name: "A.txt"), in: store)
        let b = cached(ClipboardFile(data: Data("B".utf8), name: "B.txt"), in: store)
        try! manager.setAttributes([.creationDate: Date().addingTimeInterval(-26 * 3600)], ofItemAtPath: b.deletingLastPathComponent().path)
        NSPasteboard.general.simulateFiles([a]); service.pollForTest(); service.finishImagesForTest()
        service.suspendImagesForTest(true)
        let data = Data("obsolete incoming payload".utf8)
        let (packet, task) = filePacket(data)
        _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: Connection()); task.finish(data)
        // A new copy occurs after the worker captured A, before the next timer poll.
        NSPasteboard.general.simulateFiles([b])
        service.suspendImagesForTest(false); service.finishImagesForTest()
        precondition(NSPasteboard.general.fileURLs == [b] && manager.fileExists(atPath: b.path))
        precondition(try! Data(contentsOf: b) == Data("B".utf8))
        print("PASS: an obsolete background transfer cannot evict an older file restored to the clipboard")
    }
    do {
        let store = ClipboardFileStore(directory: root.appendingPathComponent("live-cache"))
        let a = cached(ClipboardFile(data: Data([1]), name: "A.txt"), in: store)
        let b = cached(ClipboardFile(data: Data([2]), name: "B.txt"), in: store)
        let old = Date().addingTimeInterval(-26 * 3600)
        for (index, url) in [a, b].enumerated() {
            try! manager.setAttributes([.creationDate: old.addingTimeInterval(Double(index))], ofItemAtPath: url.deletingLastPathComponent().path)
        }
        let pending = store.stage(ClipboardFile(data: Data([3]), name: "pending.txt"))!
        precondition(manager.fileExists(atPath: a.path) && manager.fileExists(atPath: b.path))
        var reads = 0
        store.prune(protecting: { reads += 1; return reads == 1 ? [a] : [b] })
        precondition(reads == 2 && manager.fileExists(atPath: a.path) && manager.fileExists(atPath: b.path))
        precondition(manager.fileExists(atPath: pending.path))
        let published = store.publish(pending)!
        precondition(!manager.fileExists(atPath: pending.path) && manager.fileExists(atPath: published.path))
        store.discard(published); precondition(!manager.fileExists(atPath: published.path))
        print("PASS: staging never evicts files and cache eviction re-reads the live selection before each removal")
    }
    do {
        let (service, peer, other) = fresh("filenames")
        deliver(redPNG, name: "first.png", to: service, from: peer)
        let first = NSPasteboard.general.fileURLs.first!
        other.sent = []
        deliver(redPNG, name: "second.png", to: service, from: peer)
        let second = NSPasteboard.general.fileURLs.first!
        precondition(first != second && second.lastPathComponent == "second.png")
        precondition(try! Data(contentsOf: second) == redPNG)
        precondition(other.sent.count == 1 && other.sent[0].body["filename"] as? String == "second.png")
        precondition(streamData(other.sent[0].payload!) == redPNG)
        let count = NSPasteboard.general.changeCount
        deliver(redPNG, name: "second.png", to: service, from: peer)
        precondition(NSPasteboard.general.changeCount == count && other.sent.count == 1)
        print("PASS: official KDE image files with identical pixels retain the newest filename and relay original bytes once")
    }
    do {
        let (service, peer, _) = fresh("encodings")
        deliver(redPNG, name: "picture.png", to: service, from: peer)
        deliver(redTIFF, name: "picture.tiff", to: service, from: peer)
        let url = NSPasteboard.general.fileURLs.first!
        precondition(url.lastPathComponent == "picture.tiff" && (try! Data(contentsOf: url)) == redTIFF)
        precondition(NSPasteboard.general.data(forType: .png) != nil)
        print("PASS: official KDE files preserve different original encodings even when their bitmap pixels match")
    }
    do {
        let (service, peer, other) = fresh("svg")
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\"/></svg>".utf8)
        deliver(svg, name: "drawing.svg", to: service, from: peer)
        let url = NSPasteboard.general.fileURLs.first!
        precondition(url.lastPathComponent == "drawing.svg" && (try! Data(contentsOf: url)) == svg)
        precondition(other.sent.count == 1 && streamData(other.sent[0].payload!) == svg)
        print("PASS: a valid SVG from official KDE remains a pasteable file without requiring a bitmap decoder")
    }
    do {
        let (service, peer, _) = fresh("large-image-file")
        let large = fixture(.black, width: 5000, height: 4000)
        precondition(large.count < ClipboardFile.maximumBytes && ClipboardImage.decode(large) == nil)
        deliver(large, name: "20-megapixel.png", to: service, from: peer)
        let url = NSPasteboard.general.fileURLs.first!
        precondition((try! Data(contentsOf: url)) == large && NSPasteboard.general.data(forType: .png) == nil)
        let before = NSPasteboard.general.changeCount
        let (packet, task) = imagePacket(large)
        _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: Connection()); task.finish(large); service.finishImagesForTest()
        precondition(NSPasteboard.general.changeCount == before)
        print("PASS: large-pixel KDE image files transfer under the file limit while explicit bitmaps retain the pixel limit")
    }
    do {
        let (service, peer, other) = fresh("cancel-text")
        localFile(service)
        let ids = [peer.sent.last!.id, other.sent.last!.id]
        NSPasteboard.general.simulateCopy("newer local text"); service.pollForTest()
        precondition(peer.cancelledUploads.contains(ids[0]) && other.cancelledUploads.contains(ids[1]))
        precondition(peer.sent.last!.type == "kdeconnect.clipboard" && NSPasteboard.general.content == "newer local text")
        print("PASS: copying newer text cancels older file uploads to every peer before sending the text")
    }
    do {
        let (service, peer, _) = fresh("cancel-payload")
        localFile(service); let fileID = peer.sent.last!.id
        NSPasteboard.general.simulateImage(redPNG); service.pollForTest(); service.finishImagesForTest()
        let imageID = peer.sent.last!.id
        precondition(peer.cancelledUploads.contains(fileID) && imageID != fileID)
        localFile(service)
        precondition(peer.cancelledUploads.contains(imageID))
        print("PASS: image and file copies cancel superseded payload uploads in both directions")
    }
    do {
        let (service, peer, other) = fresh("cancel-remote-text")
        localFile(service); let id = other.sent.last!.id
        let packet = DataPacket(type: "kdeconnect.clipboard", body: ["content": "newer remote text" as NSString])
        _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: Connection())
        precondition(other.cancelledUploads.contains(id) && NSPasteboard.general.content == "newer remote text")
        print("PASS: accepting newer remote text cancels older uploads before relaying the new clipboard")
    }
    do {
        let (service, peer, other) = fresh("cancel-header")
        localFile(service); let senderID = peer.sent.last!.id, otherID = other.sent.last!.id
        let bytes = try! Data(contentsOf: source)
        let (duplicate, duplicateTask) = filePacket(bytes, name: source.lastPathComponent)
        _ = service.handleDataPacket(duplicate, fromDevice: peer, onConnection: Connection())
        precondition(peer.cancelledUploads.contains(senderID) && !other.cancelledUploads.contains(otherID))
        duplicateTask.finish(bytes); service.finishImagesForTest()
        precondition(!other.cancelledUploads.contains(otherID))
        deliver(Data("a new remote file".utf8), name: "new.txt", to: service, from: peer)
        precondition(other.cancelledUploads.contains(otherID) && NSPasteboard.general.fileURLs.first!.lastPathComponent == "new.txt")
        print("PASS: a duplicate file header cancels only its sender's upload and accepted new content cancels superseded peer uploads")
    }
    do {
        let (service, peer, other) = fresh("cancel-disconnect")
        localFile(service); let id = peer.sent.last!.id, otherID = other.sent.last!.id
        service.cleanup(for: peer)
        precondition(peer.cancelledUploads.contains(id) && !other.cancelledUploads.contains(otherID))
        print("PASS: disconnecting a peer cancels its uploads while preserving transfers to other peers")
    }
    do {
        let (service, peer, other) = fresh("cancel-disabled")
        localFile(service); let id = peer.sent.last!.id, otherID = other.sent.last!.id
        UserDefaults.standard.set(false, forKey: "outgoing"); service.pollForTest()
        precondition(peer.cancelledUploads.contains(id) && other.cancelledUploads.contains(otherID))
        UserDefaults.standard.set(true, forKey: "outgoing")
        print("PASS: disabling outgoing clipboard sharing cancels existing uploads without requiring another copy")
    }
    do {
        var (service, peer, other): (ClipboardService?, Device, Device) = fresh("cancel-completed")
        localFile(service!); let completedID = peer.sent.last!.id, otherID = other.sent.last!.id
        peer.finishUpload(completedID)
        service = nil
        precondition(!peer.cancelledUploads.contains(completedID) && other.cancelledUploads.contains(otherID))
        print("PASS: completed uploads leave tracking and stopping the service cancels only unfinished transfers")
    }
}
reviewRegressions()
