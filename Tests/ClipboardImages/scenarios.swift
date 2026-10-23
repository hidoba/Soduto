// Compiled with the production service and image codec by test-clipboard-service.py.
// Network/pasteboard stubs are isolated; the image codec and final AppKit check are real.
func fixture(_ color: NSColor, type: UTType = .png, width: Int = 8, height: Int = 6, orientation: Int = 1) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}
func pumpUntil(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    precondition(condition(), "Asynchronous image operation did not finish")
}
func streamData(_ stream: InputStream) -> Data {
    stream.open(); defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        precondition(count >= 0)
        if count == 0 { return data }
        data.append(contentsOf: buffer.prefix(count))
    }
}
let redPNG = fixture(.red)
let redTIFF = fixture(.red, type: .tiff)
let bluePNG = fixture(.blue)
func imagePacket(_ data: Data, size: Int64? = nil, timestamp: Int64? = nil, filename: String = "image.PNG") -> (DataPacket, DownloadTask) {
    let task = DownloadTask()
    var body: DataPacket.Body = ["filename": filename as NSString]
    if let timestamp { body["timestamp"] = NSNumber(value: timestamp); body["sodutoTimestamped"] = NSNumber(value: true) }
    var packet = DataPacket(type: "kdeconnect.clipboard.file", body: body)
    packet.payloadSize = size ?? Int64(data.count)
    packet.downloadTask = task
    return (packet, task)
}
func completedImages() -> Int {
    Diagnostics.events.filter { ["clipboard.image_applied", "clipboard.image_ignored", "clipboard.image_failed"].contains($0.0) }.count
}
func imageScenarios() {
    UserDefaults.standard.set(true, forKey: "incoming")
    UserDefaults.standard.set(true, forKey: "outgoing")
    NSPasteboard.general = NSPasteboard()
    let service = ClipboardService()
    let peer = Device("image-sender"), other = Device("image-other"), legacy = Device("text-only")
    legacy.incomingCapabilities = ["kdeconnect.clipboard", "kdeconnect.clipboard.connect"]
    for device in [peer, other, legacy] { service.setup(for: device); device.sent = [] }
    let connection = Connection()
    precondition(service.incomingCapabilities.contains("kdeconnect.clipboard.file"))
    precondition(service.outgoingCapabilities.contains("kdeconnect.clipboard.file"))
    NSPasteboard.general.simulateImage(redTIFF, type: .tiff, text: "image caption")
    service.pollForTest()
    pumpUntil { peer.sent.count == 1 && other.sent.count == 1 }
    precondition(peer.sent[0].type == "kdeconnect.clipboard.file" && legacy.sent.isEmpty)
    let first = streamData(peer.sent[0].payload!), second = streamData(other.sent[0].payload!)
    precondition(first == second && ClipboardImage.decode(first)?.fingerprint == ClipboardImage.decode(redPNG)?.fingerprint)
    precondition(peer.sent[0].payloadSize == Int64(first.count))
    print("PASS: TIFF image takes priority over text and sends independent PNG streams only to capable peers")

    peer.sent = []; other.sent = []
    let connecting = Device("new-peer")
    service.setup(for: connecting)
    precondition(connecting.sent.isEmpty)
    service.cleanup(for: connecting)
    print("PASS: reconnect does not replay an image or its alternate text over a newer remote clipboard")

    var (packet, task) = imagePacket(bluePNG, filename: "../../do-not-create.PNG")
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection)
    task.finish(bluePNG)
    pumpUntil { NSPasteboard.general.data(forType: .png).flatMap { ClipboardImage.decode($0) }?.fingerprint == ClipboardImage.decode(bluePNG)?.fingerprint }
    precondition(NSPasteboard.general.content == nil && peer.sent.isEmpty && other.sent.count == 1 && legacy.sent.isEmpty)
    service.pollForTest()
    precondition(peer.sent.isEmpty && other.sent.count == 1)
    print("PASS: KDE image payload applies and relays once without using the supplied filename as a path")

    let remoteURL = DataPacket(type: "kdeconnect.clipboard.connect", body: [
        "content": "file:///tmp/synthetic-kde-image/clipboard.png" as NSString,
        "timestamp": NSNumber(value: Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
    ])
    let beforeURLConnect = NSPasteboard.general.changeCount
    _ = service.handleDataPacket(remoteURL, fromDevice: peer, onConnection: connection)
    precondition(NSPasteboard.general.changeCount == beforeURLConnect && NSPasteboard.general.content == nil)
    print("PASS: KDE's temporary image URL in a reconnect packet cannot turn an image into remote path text")

    let beforeDuplicate = NSPasteboard.general.changeCount
    let endCount = completedImages()
    (packet, task) = imagePacket(fixture(.blue, type: .tiff))
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection)
    task.finish(fixture(.blue, type: .tiff))
    pumpUntil { completedImages() > endCount }
    precondition(NSPasteboard.general.changeCount == beforeDuplicate && other.sent.count == 1)
    print("PASS: identical pixels in different encodings neither rewrite nor echo")

    for size: Int64 in [0, -1, Int64(ClipboardImage.maximumBytes + 1)] {
        (packet, task) = imagePacket(redPNG, size: size)
        _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection)
        precondition(task.stream == nil)
    }
    (packet, task) = imagePacket(redPNG); packet.payloadSize = nil
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection)
    precondition(task.stream == nil)
    print("PASS: unknown, zero, negative and oversized payload sizes are rejected before downloading")

    let beforeInvalid = NSPasteboard.general.changeCount
    let invalidCount = completedImages()
    let invalid = Data("not an image".utf8)
    (packet, task) = imagePacket(invalid)
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection); task.finish(invalid)
    pumpUntil { completedImages() > invalidCount }
    precondition(NSPasteboard.general.changeCount == beforeInvalid)
    (packet, task) = imagePacket(redPNG)
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection); task.finish(redPNG.prefix(12))
    precondition(NSPasteboard.general.changeCount == beforeInvalid)
    print("PASS: malformed and truncated payloads leave the clipboard intact")

    (packet, task) = imagePacket(redPNG)
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection)
    NSPasteboard.general.simulateCopy("newer local text")
    service.pollForTest(); task.finish(redPNG)
    precondition(task.cancelled && NSPasteboard.general.content == "newer local text")
    print("PASS: a local copy cancels an in-flight image download")

    (packet, task) = imagePacket(redPNG)
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection); task.finish(redPNG)
    let freshText = DataPacket(type: "kdeconnect.clipboard", body: ["content": "newer remote text" as NSString])
    _ = service.handleDataPacket(freshText, fromDevice: peer, onConnection: connection)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(NSPasteboard.general.content == "newer remote text" && NSPasteboard.general.data(forType: .png) == nil)
    print("PASS: a newer text packet invalidates an image already being decoded")

    (packet, task) = imagePacket(redPNG)
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection)
    service.cleanup(for: peer); task.finish(redPNG)
    precondition(task.cancelled && NSPasteboard.general.content == "newer remote text")
    service.setup(for: peer)
    print("PASS: disconnect cancels pending image downloads")

    UserDefaults.standard.set(false, forKey: "incoming")
    (packet, task) = imagePacket(redPNG)
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection)
    precondition(task.stream == nil && !service.incomingCapabilities.contains("kdeconnect.clipboard.file"))
    peer.sent = []; other.sent = []
    NSPasteboard.general.simulateImage(redPNG); service.pollForTest()
    pumpUntil { peer.sent.count == 1 }
    UserDefaults.standard.set(true, forKey: "incoming")
    UserDefaults.standard.set(false, forKey: "outgoing")
    precondition(!service.outgoingCapabilities.contains("kdeconnect.clipboard.file"))
    peer.sent = []; other.sent = []
    (packet, task) = imagePacket(bluePNG)
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection); task.finish(bluePNG)
    pumpUntil { NSPasteboard.general.data(forType: .png).flatMap { ClipboardImage.decode($0) }?.fingerprint == ClipboardImage.decode(bluePNG)?.fingerprint }
    precondition(peer.sent.isEmpty && other.sent.isEmpty)
    UserDefaults.standard.set(true, forKey: "outgoing")
    print("PASS: incoming and outgoing direction settings independently govern image transfers")

    (packet, task) = imagePacket(redPNG)
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection)
    UserDefaults.standard.set(false, forKey: "incoming"); task.finish(redPNG)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(NSPasteboard.general.data(forType: .png).flatMap { ClipboardImage.decode($0) }?.fingerprint == ClipboardImage.decode(bluePNG)?.fingerprint)
    UserDefaults.standard.set(true, forKey: "incoming")
    print("PASS: turning off incoming sharing before completion prevents a clipboard write")

    (packet, task) = imagePacket(redPNG)
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection); task.finish(redPNG)
    service.cleanup(for: peer); service.setup(for: peer)
    service.finishImagesForTest()
    precondition(NSPasteboard.general.data(forType: .png).flatMap { ClipboardImage.decode($0) }?.fingerprint == ClipboardImage.decode(bluePNG)?.fingerprint)
    print("PASS: disconnect and immediate reconnect invalidate an image already being decoded")

    peer.sent = []; other.sent = []; legacy.sent = []
    NSPasteboard.general.simulateImage(redPNG); service.pollForTest()
    NSPasteboard.general.simulateCopy("text copied during image encoding"); service.pollForTest()
    service.finishImagesForTest()
    precondition(peer.sent.count == 1 && peer.sent[0].type == "kdeconnect.clipboard")
    print("PASS: a rapid text copy prevents a stale outgoing image from being sent later")

    (packet, task) = imagePacket(redPNG)
    _ = service.handleDataPacket(packet, fromDevice: peer, onConnection: connection)
    ClipboardTestTimers.timers.last!.fire()
    precondition(task.cancelled && NSPasteboard.general.content == "text copied during image encoding")
    print("PASS: stalled image transfers time out without clearing the clipboard")

    // A highly compressible source must still obey the decoded pixel limit.
    precondition(ClipboardImage.decode(fixture(.black, width: 8192, height: 2049)) == nil)
    precondition(ClipboardImage.decode(redTIFF)?.fingerprint == ClipboardImage.decode(redPNG)?.fingerprint)
    for alpha in [0.0, 0.004, 0.1, 0.333, 0.5, 0.9, 1.0] {
        let image = ClipboardImage.decode(fixture(NSColor(srgbRed: 0.62, green: 0.17, blue: 0.84, alpha: alpha), type: .tiff))!
        precondition(image.fingerprint == ClipboardImage.decode(image.png)!.fingerprint, "PNG alpha round-trip changed the fingerprint")
    }
    let oriented = ClipboardImage.decode(fixture(.green, type: .tiff, orientation: 6))!
    let orientedImage = NSImage(data: oriented.png)!
    precondition(orientedImage.size.width == 6 && orientedImage.size.height == 8)
    print("PASS: decoded pixel limits and PNG/TIFF fingerprint normalization use the real ImageIO codec")

    let isolated = AppKit.NSPasteboard.withUniqueName()
    defer { isolated.releaseGlobally() }
    isolated.clearContents()
    precondition(isolated.setData(ClipboardImage.decode(redTIFF)!.png, forType: .png))
    let images = isolated.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage]
    precondition(images?.count == 1 && images![0].size.width == 8 && images![0].size.height == 6)
    print("PASS: native AppKit recognizes the received PNG as a pasteable image on an isolated pasteboard")
}
imageScenarios()

func imageMeshScenarios() {
    UserDefaults.standard.set(true, forKey: "incoming")
    UserDefaults.standard.set(true, forKey: "outgoing")
    let names = ["A", "B", "C"]
    var services: [String: ClipboardService] = [:]
    var boards: [String: NSPasteboard] = [:]
    var peers: [String: [String: Device]] = [:]
    for name in names {
        let board = NSPasteboard(); boards[name] = board; NSPasteboard.general = board
        let service = ClipboardService(); services[name] = service
        peers[name] = [:]
        for remote in names where remote != name {
            let peer = Device(remote); peers[name]![remote] = peer; service.setup(for: peer); peer.sent = []
        }
    }
    func drain() -> Int {
        var delivered = 0
        for _ in 0..<20 {
            var messages: [(String, String, DataPacket)] = []
            for source in names {
                for destination in names where source != destination {
                    let peer = peers[source]![destination]!
                    messages += peer.sent.map { (source, destination, $0) }; peer.sent = []
                }
            }
            if messages.isEmpty { return delivered }
            for (source, destination, outgoing) in messages {
                NSPasteboard.general = boards[destination]!
                var incoming = outgoing
                if outgoing.type == "kdeconnect.clipboard.file" {
                    let bytes = streamData(outgoing.payload!)
                    let task = DownloadTask(); incoming.downloadTask = task; incoming.payload = nil
                    _ = services[destination]!.handleDataPacket(incoming, fromDevice: peers[destination]![source]!, onConnection: Connection())
                    task.finish(bytes)
                    services[destination]!.finishImagesForTest()
                } else {
                    _ = services[destination]!.handleDataPacket(incoming, fromDevice: peers[destination]![source]!, onConnection: Connection())
                }
                delivered += 1
            }
        }
        preconditionFailure("Image relay mesh did not settle")
    }
    NSPasteboard.general = boards["A"]!
    NSPasteboard.general.simulateImage(redPNG); services["A"]!.pollForTest(); services["A"]!.finishImagesForTest()
    precondition(drain() <= 6)
    let redFingerprint = ClipboardImage.decode(redPNG)!.fingerprint
    precondition(boards.values.allSatisfy { $0.data(forType: .png).flatMap { ClipboardImage.decode($0) }?.fingerprint == redFingerprint })
    print("PASS: a three-peer image relay triangle converges without echo loops")

    NSPasteboard.general = boards["B"]!
    NSPasteboard.general.simulateCopy("interleaved text"); services["B"]!.pollForTest()
    NSPasteboard.general = boards["C"]!
    NSPasteboard.general.simulateImage(bluePNG); services["C"]!.pollForTest(); services["C"]!.finishImagesForTest()
    _ = drain()
    let values = boards.values.map { board in
        board.data(forType: .png).flatMap { ClipboardImage.decode($0) }?.fingerprint.base64EncodedString() ?? board.content ?? "empty"
    }
    precondition(Set(values).count == 1)
    // An intentional re-copy is a new generation, even for an earlier picture.
    NSPasteboard.general = boards["A"]!
    NSPasteboard.general.simulateImage(redPNG); services["A"]!.pollForTest(); services["A"]!.finishImagesForTest()
    _ = drain()
    precondition(boards.values.allSatisfy { $0.data(forType: .png).flatMap { ClipboardImage.decode($0) }?.fingerprint == redFingerprint })
    print("PASS: interleaved text/image generations converge and intentionally re-copying an image synchronizes again")
}
imageMeshScenarios()
