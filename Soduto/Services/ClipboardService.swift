//
//  ClipboardService.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-30.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Cocoa

/// Service providing clipboard content sharing between devices
///
/// When the clipboard changes, it sends a package with type kdeconnect.clipboard
/// and the field "content" (string) containing the new clipboard content.
///
/// When a device connects, a `kdeconnect.clipboard.connect` packet is sent containing
/// the current clipboard content and a timestamp (ms since epoch). The receiver
/// compares timestamps and only applies the content if it is newer than its own.
///
/// When it receives a package of the same kind, it should update the system
/// clipboard with the received content, so the clipboard in both devices always
/// have the same content.
///
/// This plugin is symmetric to its counterpart in the other device: both have the
/// same behaviour.
/// Images use `kdeconnect.clipboard.file` with a bounded PNG payload over TLS.
public class ClipboardService: BidirectionalService, DownloadTaskDelegate {
    
    // MARK: Properties
    
    private static let monitoringInterval: TimeInterval = 0.5
    
    var userDefaults: UserDefaults = .standard
    let incomingPreferenceKey = AppDefaultsStore.Preferences.Services.Clipboard.incomingKey
    let outgoingPreferenceKey = AppDefaultsStore.Preferences.Services.Clipboard.outgoingKey
    
    private var monitoringTimer: Timer? = nil
    private var syncState = ClipboardSyncState(changeCount: NSPasteboard.general.changeCount)
    private var replayFilter = ClipboardReplayFilter()
    private var devices: [Device] = []
    private let imageQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.soduto.clipboard.images"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var imageRevision = UUID()
    private var imageSourceDeviceID: String?
    private var pendingImageTimestamp: Int64?
    private var peerSessions: [String: UUID] = [:]
    private var currentImage: ClipboardImage?
    private var currentFile: ClipboardFile?
    private let fileStore: ClipboardFileStore
    private var outgoingUploads: [Int64: Device] = [:]
    private struct ImageDownload {
        let task: DownloadTask
        let stream: OutputStream
        let device: Device
        let revision: UUID
        let changeCount: Int
        let timestamp: Int64
        let ordered: Bool
        let size: Int
        let timeout: Timer
        let filename: String
        let imageRequired: Bool
        var logKind: String { imageRequired ? "image" : "file" }
    }
    private var imageDownload: ImageDownload?
    
    /// Start tracking immediately, including periods without a connected peer.
    public init(clipboardFileDirectory: URL? = nil) {
        fileStore = ClipboardFileStore(directory: clipboardFileDirectory)
        // Track local changes while disconnected too. Otherwise a reconnect sends
        // new text with an old timestamp and a stale peer can overwrite it.
        startMonitoring()
    }

    deinit {
        monitoringTimer?.invalidate()
        imageQueue.cancelAllOperations()
        imageDownload?.timeout.invalidate()
        imageDownload?.task.delegate = nil
        imageDownload?.task.cancel()
        cancelOutgoingUploads(reason: "service_stopped")
    }
    
    
    // MARK: Service
    
    public static let serviceId: Service.Id = "com.soduto.services.clipboard"
    
    public var incomingCapabilities: Set<Service.Capability> {
        incomingEnabled ? [DataPacket.clipboardPacketType, DataPacket.clipboardConnectPacketType, DataPacket.clipboardFilePacketType] : []
    }
    public var outgoingCapabilities: Set<Service.Capability> {
        outgoingEnabled ? [DataPacket.clipboardPacketType, DataPacket.clipboardConnectPacketType, DataPacket.clipboardFilePacketType] : []
    }
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        guard dataPacket.isClipboardPacket || dataPacket.isClipboardConnectPacket || dataPacket.isClipboardFilePacket else { return false }
        // Catch a local copy in the interval between timer ticks before deciding
        // which side has the freshest clipboard.
        checkPasteboard()
        switch dataPacket.type {
        case DataPacket.clipboardFilePacketType:
            receiveImage(dataPacket, from: device)
            return true
        case DataPacket.clipboardPacketType:
            guard incomingEnabled else {
                logDecision("ignored", device: device, reason: "incoming_disabled")
                return true
            }
            guard let contents = try? dataPacket.getContent() else {
                logDecision("ignored", device: device, reason: "invalid_content")
                return true
            }
            let reportedTimestamp = try? dataPacket.getTimestamp()
            let ordered = dataPacket.hasOrderedClipboardTimestamp && (reportedTimestamp ?? 0) > 0
            let senderTimestamp = ordered ? reportedTimestamp! : nextClipboardTimestamp
            if ordered, let pendingImageTimestamp, senderTimestamp <= pendingImageTimestamp {
                logDecision("ignored", device: device, reason: "newer_image_pending")
                return true
            }
            applyExternalClipboard(contents, from: device, timestamp: senderTimestamp, ordered: ordered)
            return true
        case DataPacket.clipboardConnectPacketType:
            guard incomingEnabled else {
                logDecision("ignored", device: device, reason: "incoming_disabled")
                return true
            }
            guard let contents = try? dataPacket.getContent() else {
                logDecision("ignored", device: device, reason: "invalid_content")
                return true
            }
            // KDE stores received images as temporary file URLs, and its text
            // reconnect packet can serialize that URL as `content`. It isn't a
            // newer text copy and must not turn our image into a remote temp path.
            if pasteboardHasImage || !pasteboardFileURLs.isEmpty, URL(string: contents)?.isFileURL == true {
                logDecision("ignored", device: device, reason: "image_file_url_connect")
                return true
            }
            let remoteMilliseconds = (try? dataPacket.getTimestamp()) ?? 0
            if syncState.shouldAcceptConnect(timestampMilliseconds: remoteMilliseconds),
               remoteMilliseconds > (pendingImageTimestamp ?? 0) {
                applyExternalClipboard(contents, from: device, timestamp: remoteMilliseconds)
            } else {
                Diagnostics.record("clipboard.connect_ignored", fields: [
                    "device": Diagnostics.peer(device.id), "reason": "remote_not_newer",
                    "remote_timestamp_ms": String(remoteMilliseconds),
                    "local_timestamp_ms": String(syncState.timestampMilliseconds)
                ])
            }
            return true
        default:
            return false
        }
    }
    
    public func setup(for device: Device) {
        guard !self.devices.contains(where: { $0.id == device.id }) else { return }
        checkPasteboard()
        
        self.devices.append(device)
        peerSessions[device.id] = UUID()
        
        // On connect, send our current clipboard with its timestamp so the peer
        // can decide which side has the newer content
        // KDE's connect handshake has no image timestamp negotiation. Replaying an
        // old image at reconnect would overwrite a newer copy on the peer.
        if !pasteboardHasImage, pasteboardFileURLs.isEmpty,
           let items = NSPasteboard.general.readObjects(forClasses: [NSString.self], options: nil),
           let content = items.first as? String {
            send(DataPacket.clipboardConnectPacket(withContent: content, timestamp: currentTimestamp), to: device)
            logDecision(outgoingEnabled ? "connect_sent" : "ignored", device: device,
                        reason: outgoingEnabled ? "new_connection" : "outgoing_disabled")
        }
        Diagnostics.record("clipboard.peer_added", fields: ["device": Diagnostics.peer(device.id), "count": String(devices.count),
            "incoming": String(incomingEnabled), "outgoing": String(outgoingEnabled),
            "image_file_send_supported": String(device.incomingCapabilities.contains(DataPacket.clipboardFilePacketType)),
            "image_file_receive_supported": String(device.outgoingCapabilities.contains(DataPacket.clipboardFilePacketType))])
    }
    
    public func cleanup(for device: Device) {
        guard let index = self.devices.firstIndex(where: { $0.id == device.id }) else { return }
        
        self.devices.remove(at: index)
        peerSessions.removeValue(forKey: device.id)
        cancelOutgoingUploads(toDeviceID: device.id, reason: "peer_disconnected")
        if imageSourceDeviceID == device.id { invalidateImageWork() }
        
        Diagnostics.record("clipboard.peer_removed", fields: ["device": Diagnostics.peer(device.id), "count": String(devices.count)])
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        // No supported actions
        return []
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device, userInfo: [String: Any]?) {
        // No supported actions
    }
    
    
    // MARK: Private methods
    
    private func startMonitoring() {
        let interval = ClipboardService.monitoringInterval
        self.monitoringTimer = Timer.compatScheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
        if let monitoringTimer { RunLoop.main.add(monitoringTimer, forMode: .common) }
    }
    
    private var currentTimestamp: Int64 { syncState.timestampMilliseconds }

    private var nextClipboardTimestamp: Int64 {
        let pending = pendingImageTimestamp ?? 0
        return max(syncState.timestampForNextChange(), pending < Int64.max ? pending + 1 : pending)
    }
    
    private func checkPasteboard() {
        if !outgoingEnabled { cancelOutgoingUploads(reason: "outgoing_disabled") }
        if NSPasteboard.general.changeCount != syncState.changeCount,
           let pendingImageTimestamp, pendingImageTimestamp > currentTimestamp {
            // A deliberate copy must supersede a generation still downloading,
            // including a marked peer whose clock is ahead of this Mac.
            syncState.recordRemoteChange(syncState.changeCount, timestampMilliseconds: pendingImageTimestamp)
        }
        guard syncState.observeLocalChange(NSPasteboard.general.changeCount) else { return }
        cancelOutgoingUploads(reason: "local_clipboard_changed")
        invalidateImageWork()
        currentImage = nil
        currentFile = nil
        Diagnostics.record("clipboard.local_changed", level: .debug, fields: [
            "change_count": String(syncState.changeCount), "timestamp_ms": String(syncState.timestampMilliseconds), "count": String(devices.count)
        ])
        if !pasteboardFileURLs.isEmpty {
            sendLocalFile()
            return
        }
        if pasteboardHasImage {
            sendLocalImage()
            return
        }
        // Unsupported formats still advance freshness, protecting them from stale text.
        guard let items = NSPasteboard.general.readObjects(forClasses: [ NSString.self ], options: nil) else { return }
        guard items.count > 0 else { return }
        guard let content = items[0] as? String else { return }
        replayFilter.remember(content, timestamp: syncState.timestampMilliseconds)
        
        for device in self.devices {
            send(DataPacket.clipboardPacket(withContent: content, timestamp: currentTimestamp), to: device)
            logDecision(outgoingEnabled ? "sent" : "ignored", device: device,
                        reason: outgoingEnabled ? "local_change" : "outgoing_disabled")
        }
    }
    
    /// Apply content received from a remote device.
    /// - Parameter timestamp: The sender's copy timestamp, stored in the sync state
    ///   so that future `clipboard.connect` packets carry the original creation time rather than
    ///   our receive time, preventing the peer from seeing a "newer" timestamp on every reconnect.
    private func applyExternalClipboard(_ content: String, from device: Device, timestamp milliseconds: Int64, ordered: Bool = true) {
        // A relay may return through a different connection with a new packet ID.
        // Keep both checks: legacy peers omit timestamps, while a remembered
        // generation also stops two different clipboard values circling a mesh.
        let current = pasteboardHasImage || !pasteboardFileURLs.isEmpty ? nil : NSPasteboard.general.readObjects(forClasses: [NSString.self], options: nil)?.first as? String
        if current == content {
            if !ordered || milliseconds >= syncState.timestampMilliseconds { invalidateImageWork() }
            replayFilter.remember(content, timestamp: milliseconds)
            if ordered && milliseconds > syncState.timestampMilliseconds {
                syncState.recordRemoteChange(NSPasteboard.general.changeCount, timestampMilliseconds: milliseconds)
                // This hub already has the text, but another peer may not. A
                // fresh marked generation must still cross the hub exactly once.
                relayClipboard(content, excluding: device)
                logDecision(outgoingEnabled ? "relayed" : "ignored", device: device,
                            reason: outgoingEnabled ? "new_generation_same_content" : "outgoing_disabled")
            } else {
                logDecision("ignored", device: device, reason: "identical_content")
            }
            return
        }
        if ordered {
            // This fork explicitly marks ordered normal relays as an extension.
            // Order those generations, including simultaneous copies, so a mesh
            // converges. Unmarked KDE packets remain live edits, even if another
            // client includes its own timestamp extension or has a skewed clock.
            if milliseconds < syncState.timestampMilliseconds {
                logDecision("ignored", device: device, reason: "older_generation")
                return
            }
            if milliseconds == syncState.timestampMilliseconds,
               current == nil || !current!.utf8.lexicographicallyPrecedes(content.utf8) {
                if let currentImage, !replayFilter.contains(content, timestamp: milliseconds) {
                    replayFilter.remember(content, timestamp: milliseconds)
                    sendImage(currentImage, timestamp: milliseconds)
                } else if let currentFile, !replayFilter.contains(content, timestamp: milliseconds) {
                    replayFilter.remember(content, timestamp: milliseconds)
                    sendFile(currentFile, timestamp: milliseconds)
                }
                logDecision("ignored", device: device, reason: "timestamp_tie")
                return
            }
        }
        guard !replayFilter.contains(content, timestamp: milliseconds) else {
            logDecision("ignored", device: device, reason: "replayed_generation")
            return
        }
        invalidateImageWork()
        cancelOutgoingUploads(reason: "remote_clipboard_changed")
        currentImage = nil
        currentFile = nil
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([content as NSString]) else {
            Diagnostics.record("clipboard.write_failed", level: .error, fields: ["device": Diagnostics.peer(device.id)])
            return
        }
        syncState.recordRemoteChange(NSPasteboard.general.changeCount, timestampMilliseconds: milliseconds)
        replayFilter.remember(content, timestamp: milliseconds)
        logDecision("applied", device: device, reason: "remote_change")
        // Relay explicitly; marking the remote change observed prevents echoing
        // it back to its sender on the next timer tick.
        relayClipboard(content, excluding: device)
    }

    private func relayClipboard(_ content: String, excluding sender: Device) {
        for peer in devices where peer.id != sender.id {
            send(DataPacket.clipboardPacket(withContent: content, timestamp: currentTimestamp), to: peer)
        }
    }

    // MARK: Image clipboard (KDE Connect clipboard.file)

    private var pasteboardHasImage: Bool {
        NSPasteboard.general.availableType(from: [.png, .tiff]) != nil
    }

    private var pasteboardFileURLs: [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func sendLocalFile() {
        guard outgoingEnabled else {
            Diagnostics.record("clipboard.file_ignored", fields: ["reason": "outgoing_disabled"])
            return
        }
        let urls = pasteboardFileURLs
        // KDE's wire protocol carries one filename, not a list or directory tree.
        guard urls.count == 1, let url = urls.first else {
            Diagnostics.record("clipboard.file_ignored", fields: ["reason": "multiple_files_unsupported"])
            return
        }
        guard devices.contains(where: { $0.incomingCapabilities.contains(DataPacket.clipboardFilePacketType) }) else {
            Diagnostics.record("clipboard.file_ignored", fields: ["reason": "no_file_capable_peer"])
            return
        }
        let revision = imageRevision, count = syncState.changeCount, timestamp = currentTimestamp
        let sessions = peerSessions
        imageQueue.addOperation { [weak self] in
            let file = ClipboardFile.read(url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.imageRevision == revision, NSPasteboard.general.changeCount == count else {
                    Diagnostics.record("clipboard.file_ignored", fields: ["reason": "obsolete_local_copy"])
                    return
                }
                guard let file else {
                    Diagnostics.record("clipboard.file_ignored", fields: ["reason": "unreadable_unsupported_or_oversized_file"])
                    return
                }
                self.currentFile = file
                self.replayFilter.rememberFile(file.fingerprint, timestamp: timestamp)
                self.sendFile(file, timestamp: timestamp, sessions: sessions)
            }
        }
    }

    private func sendFile(_ file: ClipboardFile, timestamp: Int64, excluding sender: Device? = nil, sessions: [String: UUID]? = nil) {
        guard outgoingEnabled else { return }
        for device in devices where device.id != sender?.id && device.incomingCapabilities.contains(DataPacket.clipboardFilePacketType) {
            if let sessions, sessions[device.id] == nil || sessions[device.id] != peerSessions[device.id] { continue }
            sendPayload(DataPacket.clipboardFilePacket(file, timestamp: timestamp), to: device)
            Diagnostics.record("clipboard.file_sent", fields: ["device": Diagnostics.peer(device.id), "bytes": String(file.data.count),
                                                            "reason": sender == nil ? "local_change" : "relay"])
        }
    }

    private func sendPayload(_ packet: DataPacket, to device: Device) {
        guard outgoingEnabled else { return }
        let packetID = packet.id
        outgoingUploads[packetID] = device
        device.send(packet) { [weak self] sent, payloadSent in
            guard let self, self.outgoingUploads.removeValue(forKey: packetID) != nil else { return }
            Diagnostics.record("clipboard.upload_completed", fields: [
                "packet_id": String(packetID), "result": String(sent && payloadSent)
            ])
        }
    }

    private func cancelOutgoingUploads(toDeviceID id: String? = nil, reason: String) {
        let obsolete = outgoingUploads.filter { id == nil || $0.value.id == id }
        // Remove before calling the transport: cancellation can complete inline.
        for packetID in obsolete.keys { outgoingUploads.removeValue(forKey: packetID) }
        for (packetID, device) in obsolete {
            device.cancelUpload(forPacketId: packetID)
            Diagnostics.record("clipboard.upload_cancelled", fields: [
                "device": Diagnostics.peer(device.id), "packet_id": String(packetID), "reason": reason
            ])
        }
    }

    private func pasteboardImageData() -> Data? {
        guard let type = NSPasteboard.general.availableType(from: [.png, .tiff]),
              let data = NSPasteboard.general.data(forType: type),
              data.count <= ClipboardImage.maximumBytes else { return nil }
        return data
    }

    private func invalidateImageWork() {
        imageRevision = UUID()
        imageSourceDeviceID = nil
        pendingImageTimestamp = nil
        imageQueue.cancelAllOperations()
        if let download = imageDownload {
            imageDownload = nil
            download.timeout.invalidate()
            download.task.delegate = nil
            download.task.cancel()
            logImage("cancelled", device: download.device, reason: "clipboard_or_connection_changed", kind: download.logKind)
        }
    }

    private func sendLocalImage() {
        guard outgoingEnabled else {
            Diagnostics.record("clipboard.image_ignored", fields: ["reason": "outgoing_disabled"])
            return
        }
        guard devices.contains(where: { $0.incomingCapabilities.contains(DataPacket.clipboardFilePacketType) }) else {
            Diagnostics.record("clipboard.image_ignored", fields: ["reason": "no_image_capable_peer"])
            return
        }
        guard let data = pasteboardImageData() else {
            Diagnostics.record("clipboard.image_ignored", fields: ["reason": "invalid_or_oversized_image"])
            return
        }
        let revision = imageRevision
        let changeCount = syncState.changeCount
        let timestamp = currentTimestamp
        let sessions = peerSessions
        imageQueue.addOperation { [weak self] in
            let image = ClipboardImage.decode(data)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.imageRevision == revision, NSPasteboard.general.changeCount == changeCount else {
                    Diagnostics.record("clipboard.image_ignored", fields: ["reason": "obsolete_local_copy"])
                    return
                }
                guard let image else {
                    Diagnostics.record("clipboard.image_ignored", fields: ["reason": "invalid_or_oversized_image"])
                    return
                }
                self.currentImage = image
                self.replayFilter.rememberImage(image.fingerprint, timestamp: timestamp)
                self.sendImage(image, timestamp: timestamp, sessions: sessions)
            }
        }
    }

    private func sendImage(_ image: ClipboardImage, timestamp: Int64, excluding sender: Device? = nil, sessions: [String: UUID]? = nil) {
        guard outgoingEnabled else { return }
        for device in devices where device.id != sender?.id && device.incomingCapabilities.contains(DataPacket.clipboardFilePacketType) {
            if let sessions, sessions[device.id] == nil || sessions[device.id] != peerSessions[device.id] { continue }
            // Each upload consumes its stream; never share a stream across peers.
            sendPayload(DataPacket.clipboardImagePacket(image.png, timestamp: timestamp), to: device)
            logImage("sent", device: device, reason: sender == nil ? "local_change" : "relay", bytes: image.png.count)
        }
    }

    private func receiveImage(_ packet: DataPacket, from device: Device) {
        guard incomingEnabled else {
            logImage("ignored", device: device, reason: "incoming_disabled")
            return
        }
        guard let task = packet.downloadTask, let size = packet.payloadSize,
              let rawFilename = packet.body["filename"] as? String, !rawFilename.isEmpty,
              size >= 0, size <= Int64(ClipboardFile.maximumBytes),
              devices.contains(where: { $0.id == device.id }) else {
            logImage("ignored", device: device, reason: "invalid_payload_or_size")
            return
        }
        let filename = ClipboardFile.safeName(rawFilename)
        // Official KDE uses this packet for both copied files and bitmaps. An
        // extension cannot tell those apart; only our explicit image marker can.
        let imageRequired = packet.body["sodutoClipboardKind"] as? String == "image"
        guard size > 0 || !imageRequired else {
            logImage("ignored", device: device, reason: "invalid_payload_or_size")
            return
        }
        let reported = (try? packet.getTimestamp()) ?? 0
        let ordered = packet.hasOrderedClipboardTimestamp && reported > 0
        let timestamp = ordered ? reported : nextClipboardTimestamp
        guard !ordered || timestamp >= max(currentTimestamp, pendingImageTimestamp ?? 0) else {
            logImage("ignored", device: device, reason: "older_generation")
            return
        }
        // The sender has a new clipboard value. It no longer needs an older
        // upload from us, even while this incoming payload is being decoded.
        cancelOutgoingUploads(toDeviceID: device.id, reason: "peer_clipboard_changed")
        invalidateImageWork()
        imageSourceDeviceID = device.id
        pendingImageTimestamp = timestamp
        let revision = imageRevision
        let stream = OutputStream.toMemory()
        let timeout = Timer.compatScheduledTimer(withTimeInterval: 35, repeats: false) { [weak self] _ in
            guard let self, self.imageDownload?.revision == revision else { return }
            self.logImage("failed", device: device, reason: "transfer_timeout", kind: imageRequired ? "image" : "file")
            self.invalidateImageWork()
        }
        RunLoop.main.add(timeout, forMode: .common)
        // DownloadTask caps writes at the declared payload size. Reject unknown
        // sizes above so the memory stream is always bounded at 50 MiB.
        imageDownload = ImageDownload(task: task, stream: stream, device: device, revision: revision,
                                      changeCount: NSPasteboard.general.changeCount, timestamp: timestamp,
                                      ordered: ordered, size: Int(size), timeout: timeout,
                                      filename: filename, imageRequired: imageRequired)
        task.delegate = self
        logImage("receiving", device: device, reason: "remote_change", bytes: Int(size), kind: imageRequired ? "image" : "file")
        task.start(withStream: stream)
    }

    public func downloadTask(_ task: DownloadTask, finishedWithSuccess success: Bool) {
        guard let download = imageDownload, download.task === task else { return }
        imageDownload = nil
        download.timeout.invalidate()
        task.delegate = nil
        guard success, let data = download.stream.property(forKey: .dataWrittenToMemoryStreamKey) as? Data,
              data.count == download.size else {
            pendingImageTimestamp = nil
            imageSourceDeviceID = nil
            logImage("failed", device: download.device, reason: "incomplete_payload", kind: download.logKind)
            return
        }
        let existing = currentImage
        // A file may also offer a PNG preview. Its generation must retain the
        // file tie order instead of masquerading as an image generation.
        let existingData = existing == nil && currentFile == nil && pasteboardFileURLs.isEmpty ? pasteboardImageData() : nil
        let existingFile = currentFile
        let existingURLs = pasteboardFileURLs
        let store = fileStore
        imageQueue.addOperation { [weak self] in
            let image = ClipboardImage.decode(data)
            let previous = existing ?? existingData.flatMap { ClipboardImage.decode($0) }
            let previousFile = existingFile ?? existingURLs.first.flatMap { ClipboardFile.read($0) }
            let file = ClipboardFile(data: data, name: download.filename)
            let valid = !download.imageRequired || image != nil
            let url = valid ? store.stage(file) : nil
            DispatchQueue.main.async { [weak self] in
                // A discarded/duplicate transfer must not retain an unused cache file.
                defer {
                    if let url, !(self?.pasteboardFileURLs.contains(url) ?? false) {
                        DispatchQueue.global(qos: .utility).async { store.discard(url) }
                    }
                }
                guard let self else { return }
                guard self.imageRevision == download.revision,
                      NSPasteboard.general.changeCount == download.changeCount,
                      self.devices.contains(where: { $0.id == download.device.id }) else {
                    self.logImage("ignored", device: download.device, reason: "clipboard_or_connection_changed", kind: download.logKind)
                    return
                }
                self.imageSourceDeviceID = nil
                self.pendingImageTimestamp = nil
                guard self.incomingEnabled else {
                    self.logImage("ignored", device: download.device, reason: "incoming_disabled", kind: download.logKind)
                    return
                }
                guard valid else {
                    self.logImage("ignored", device: download.device, reason: "invalid_or_oversized_image")
                    return
                }
                if let image, download.imageRequired {
                    self.applyImage(image, previous: previous, file: file, url: url, download: download)
                } else {
                    self.applyFile(file, preview: image, previous: previousFile, url: url, download: download)
                }
            }
        }
    }

    private func applyImage(_ image: ClipboardImage, previous: ClipboardImage?, file: ClipboardFile, url: URL?, download: ImageDownload) {
        let timestamp = download.timestamp
        if previous?.fingerprint == image.fingerprint {
            replayFilter.rememberImage(image.fingerprint, timestamp: timestamp)
            if download.ordered && timestamp > currentTimestamp {
                syncState.recordRemoteChange(NSPasteboard.general.changeCount, timestampMilliseconds: timestamp)
                sendImage(image, timestamp: timestamp, excluding: download.device)
            }
            currentImage = image
            logImage("ignored", device: download.device, reason: "identical_image")
            return
        }
        // Images win text/image timestamp ties. Pixel fingerprints order image
        // ties consistently, matching the text service's deterministic ordering.
        if download.ordered && (timestamp < currentTimestamp ||
            (timestamp == currentTimestamp && previous != nil && !previous!.fingerprint.lexicographicallyPrecedes(image.fingerprint))) {
            // If two images overlapped in flight, the losing hub may never have
            // seen our winner. Correct that peer once per losing generation;
            // remembering the loser prevents correction packets echoing forever.
            if timestamp == currentTimestamp, let previous,
               !replayFilter.containsImage(image.fingerprint, timestamp: timestamp) {
                replayFilter.rememberImage(image.fingerprint, timestamp: timestamp)
                currentImage = previous
                sendImage(previous, timestamp: timestamp)
            }
            logImage("ignored", device: download.device, reason: "older_generation_or_tie")
            return
        }
        guard !replayFilter.containsImage(image.fingerprint, timestamp: timestamp) else {
            logImage("ignored", device: download.device, reason: "replayed_generation")
            return
        }
        guard let staged = url, let url = fileStore.publish(staged) else {
            logImage("failed", device: download.device, reason: "clipboard_cache_write_failed")
            return
        }
        defer { if !pasteboardFileURLs.contains(url) { fileStore.discard(url) } }
        cancelOutgoingUploads(reason: "remote_clipboard_changed")
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([url as NSURL]), NSPasteboard.general.setData(image.png, forType: .png) else {
            logImage("failed", device: download.device, reason: "pasteboard_write_failed")
            return
        }
        currentImage = image
        currentFile = file
        syncState.recordRemoteChange(NSPasteboard.general.changeCount, timestampMilliseconds: timestamp)
        fileStore.prune(protecting: { self.pasteboardFileURLs })
        replayFilter.rememberImage(image.fingerprint, timestamp: timestamp)
        logImage("applied", device: download.device, reason: "remote_change", bytes: image.png.count)
        sendImage(image, timestamp: timestamp, excluding: download.device)
    }

    private func applyFile(_ file: ClipboardFile, preview: ClipboardImage?, previous: ClipboardFile?, url: URL?, download: ImageDownload) {
        let timestamp = download.timestamp
        // A file representation identical to an image's cached bytes must not
        // downgrade that image generation before resolving a timestamp tie.
        if download.ordered && timestamp == currentTimestamp, let currentImage {
            if !replayFilter.containsFile(file.fingerprint, timestamp: timestamp) {
                replayFilter.rememberFile(file.fingerprint, timestamp: timestamp)
                sendImage(currentImage, timestamp: timestamp)
            }
            Diagnostics.record("clipboard.file_ignored", fields: ["device": Diagnostics.peer(download.device.id), "reason": "older_generation_or_tie"])
            return
        }
        if previous?.fingerprint == file.fingerprint {
            replayFilter.rememberFile(file.fingerprint, timestamp: timestamp)
            if download.ordered && timestamp > currentTimestamp {
                syncState.recordRemoteChange(NSPasteboard.general.changeCount, timestampMilliseconds: timestamp)
                sendFile(file, timestamp: timestamp, excluding: download.device)
            }
            currentFile = file
            currentImage = nil
            Diagnostics.record("clipboard.file_ignored", fields: ["device": Diagnostics.peer(download.device.id), "reason": "identical_file"])
            return
        }
        if download.ordered && (timestamp < currentTimestamp || (timestamp == currentTimestamp &&
            (currentImage != nil || (previous != nil && !previous!.fingerprint.lexicographicallyPrecedes(file.fingerprint))))) {
            if timestamp == currentTimestamp, !replayFilter.containsFile(file.fingerprint, timestamp: timestamp) {
                replayFilter.rememberFile(file.fingerprint, timestamp: timestamp)
                if let currentImage { sendImage(currentImage, timestamp: timestamp) }
                else if let previous { sendFile(previous, timestamp: timestamp) }
            }
            Diagnostics.record("clipboard.file_ignored", fields: ["device": Diagnostics.peer(download.device.id), "reason": "older_generation_or_tie"])
            return
        }
        guard !replayFilter.containsFile(file.fingerprint, timestamp: timestamp) else {
            Diagnostics.record("clipboard.file_ignored", fields: ["device": Diagnostics.peer(download.device.id), "reason": "replayed_generation"])
            return
        }
        guard let staged = url, let url = fileStore.publish(staged) else {
            Diagnostics.record("clipboard.file_failed", fields: ["device": Diagnostics.peer(download.device.id), "reason": "clipboard_cache_write_failed"])
            return
        }
        defer { if !pasteboardFileURLs.contains(url) { fileStore.discard(url) } }
        cancelOutgoingUploads(reason: "remote_clipboard_changed")
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([url as NSURL]) else {
            Diagnostics.record("clipboard.file_failed", fields: ["device": Diagnostics.peer(download.device.id), "reason": "pasteboard_write_failed"])
            return
        }
        if let preview { NSPasteboard.general.setData(preview.png, forType: .png) }
        currentImage = nil // File generations have their own fingerprint/tie order.
        currentFile = file
        syncState.recordRemoteChange(NSPasteboard.general.changeCount, timestampMilliseconds: timestamp)
        fileStore.prune(protecting: { self.pasteboardFileURLs })
        replayFilter.rememberFile(file.fingerprint, timestamp: timestamp)
        Diagnostics.record("clipboard.file_applied", fields: ["device": Diagnostics.peer(download.device.id), "bytes": String(file.data.count)])
        sendFile(file, timestamp: timestamp, excluding: download.device)
    }

    private func logImage(_ result: String, device: Device, reason: String, bytes: Int? = nil, kind: String = "image") {
        var fields = ["device": Diagnostics.peer(device.id), "reason": reason, "timestamp_ms": String(currentTimestamp)]
        if let bytes { fields["bytes"] = String(bytes) }
        Diagnostics.record("clipboard.\(kind)_\(result)", level: result == "failed" ? .warning : .info, fields: fields)
    }

    private func logDecision(_ result: String, device: Device, reason: String) {
        Diagnostics.record("clipboard.\(result)", fields: ["device": Diagnostics.peer(device.id), "reason": reason,
                                                         "timestamp_ms": String(syncState.timestampMilliseconds)])
    }
}


// MARK: DataPacket (Clipboard)

/// Clipboard service data packet utilities
fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum ClipboardError: Error {
        case wrongType
        case invalidContent
        case invalidTimestamp
    }
    
    enum ClipboardProperty: String {
        case content = "content"
        case timestamp = "timestamp"
    }
    
    
    // MARK: Properties
    
    static let clipboardPacketType = "kdeconnect.clipboard"
    static let clipboardConnectPacketType = "kdeconnect.clipboard.connect"
    static let clipboardFilePacketType = "kdeconnect.clipboard.file"
    
    var isClipboardPacket: Bool { return self.type == DataPacket.clipboardPacketType }
    var isClipboardConnectPacket: Bool { return self.type == DataPacket.clipboardConnectPacketType }
    var isClipboardFilePacket: Bool { return self.type == DataPacket.clipboardFilePacketType }
    var hasOrderedClipboardTimestamp: Bool { (body["sodutoTimestamped"] as? NSNumber)?.boolValue == true }
    
    
    // MARK: Public static methods
    
    static func clipboardPacket(withContent content: String, timestamp: Int64? = nil) -> DataPacket {
        var body: [String: AnyObject] = [ClipboardProperty.content.rawValue: content as AnyObject]
        if let ts = timestamp {
            body[ClipboardProperty.timestamp.rawValue] = NSNumber(value: ts)
            body["sodutoTimestamped"] = NSNumber(value: true)
        }
        return DataPacket(type: clipboardPacketType, body: body)
    }
    
    static func clipboardConnectPacket(withContent content: String, timestamp: Int64) -> DataPacket {
        return DataPacket(type: clipboardConnectPacketType, body: [
            ClipboardProperty.content.rawValue: content as AnyObject,
            ClipboardProperty.timestamp.rawValue: NSNumber(value: timestamp)
        ])
    }

    static func clipboardImagePacket(_ png: Data, timestamp: Int64) -> DataPacket {
        var packet = DataPacket(type: clipboardFilePacketType, body: [
            "filename": "clipboard.png" as NSString,
            "sodutoClipboardKind": "image" as NSString,
            "timestamp": NSNumber(value: timestamp), "sodutoTimestamped": NSNumber(value: true)
        ])
        packet.payload = InputStream(data: png)
        packet.payloadSize = Int64(png.count)
        return packet
    }

    static func clipboardFilePacket(_ file: ClipboardFile, timestamp: Int64) -> DataPacket {
        var packet = DataPacket(type: clipboardFilePacketType, body: [
            "filename": file.name as NSString, "sodutoClipboardKind": "file" as NSString,
            "timestamp": NSNumber(value: timestamp), "sodutoTimestamped": NSNumber(value: true)
        ])
        packet.payload = InputStream(data: file.data)
        packet.payloadSize = Int64(file.data.count)
        return packet
    }
    
    
    // MARK: Public methods
    
    func getContent() throws -> String {
        try self.validateClipboardType()
        guard body.keys.contains(ClipboardProperty.content.rawValue) else { throw ClipboardError.invalidContent }
        guard let value = body[ClipboardProperty.content.rawValue] as? String else { throw ClipboardError.invalidContent }
        return value
    }
    
    func getTimestamp() throws -> Int64 {
        guard isClipboardPacket || isClipboardConnectPacket || isClipboardFilePacket else { throw ClipboardError.wrongType }
        guard body.keys.contains(ClipboardProperty.timestamp.rawValue) else { throw ClipboardError.invalidTimestamp }
        guard let value = body[ClipboardProperty.timestamp.rawValue] as? NSNumber else { throw ClipboardError.invalidTimestamp }
        let milliseconds = value.doubleValue
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < Double(Int64.max) else { throw ClipboardError.invalidTimestamp }
        return Int64(milliseconds)
    }
    
    func validateClipboardType() throws {
        guard isClipboardPacket || isClipboardConnectPacket else { throw ClipboardError.wrongType }
    }
}
