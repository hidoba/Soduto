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
public class ClipboardService: BidirectionalService {
    
    // MARK: Properties
    
    private static let monitoringInterval: TimeInterval = 0.5
    
    var userDefaults: UserDefaults = .standard
    let incomingPreferenceKey = AppDefaultsStore.Preferences.Services.Clipboard.incomingKey
    let outgoingPreferenceKey = AppDefaultsStore.Preferences.Services.Clipboard.outgoingKey
    
    private var monitoringTimer: Timer? = nil
    private var syncState = ClipboardSyncState(changeCount: NSPasteboard.general.changeCount)
    private var replayFilter = ClipboardReplayFilter()
    private var devices: [Device] = []
    
    /// Start tracking immediately, including periods without a connected peer.
    public init() {
        // Track local changes while disconnected too. Otherwise a reconnect sends
        // new text with an old timestamp and a stale peer can overwrite it.
        startMonitoring()
    }

    deinit { monitoringTimer?.invalidate() }
    
    
    // MARK: Service
    
    public static let serviceId: Service.Id = "com.soduto.services.clipboard"
    
    public var incomingCapabilities: Set<Service.Capability> {
        incomingEnabled ? [DataPacket.clipboardPacketType, DataPacket.clipboardConnectPacketType] : []
    }
    public var outgoingCapabilities: Set<Service.Capability> {
        outgoingEnabled ? [DataPacket.clipboardPacketType, DataPacket.clipboardConnectPacketType] : []
    }
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        guard dataPacket.isClipboardPacket || dataPacket.isClipboardConnectPacket else { return false }
        // Catch a local copy in the interval between timer ticks before deciding
        // which side has the freshest clipboard.
        checkPasteboard()
        switch dataPacket.type {
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
            let senderTimestamp = ordered ? reportedTimestamp! : syncState.timestampForNextChange()
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
            let remoteMilliseconds = (try? dataPacket.getTimestamp()) ?? 0
            if syncState.shouldAcceptConnect(timestampMilliseconds: remoteMilliseconds) {
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
        
        // On connect, send our current clipboard with its timestamp so the peer
        // can decide which side has the newer content
        if let items = NSPasteboard.general.readObjects(forClasses: [NSString.self], options: nil),
           let content = items.first as? String {
            send(DataPacket.clipboardConnectPacket(withContent: content, timestamp: currentTimestamp), to: device)
            logDecision(outgoingEnabled ? "connect_sent" : "ignored", device: device,
                        reason: outgoingEnabled ? "new_connection" : "outgoing_disabled")
        }
        Diagnostics.record("clipboard.peer_added", fields: ["device": Diagnostics.peer(device.id), "count": String(devices.count),
                                                           "incoming": String(incomingEnabled), "outgoing": String(outgoingEnabled)])
    }
    
    public func cleanup(for device: Device) {
        guard let index = self.devices.firstIndex(where: { $0.id == device.id }) else { return }
        
        self.devices.remove(at: index)
        
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
    
    private func checkPasteboard() {
        guard syncState.observeLocalChange(NSPasteboard.general.changeCount) else { return }
        Diagnostics.record("clipboard.local_changed", level: .debug, fields: [
            "change_count": String(syncState.changeCount), "timestamp_ms": String(syncState.timestampMilliseconds), "count": String(devices.count)
        ])
        // Non-text changes still advance freshness, preventing a stale remote
        // text clipboard from replacing a newly copied image or file.
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
        let current = NSPasteboard.general.readObjects(forClasses: [NSString.self], options: nil)?.first as? String
        if current == content {
            replayFilter.remember(content, timestamp: milliseconds)
            if ordered && milliseconds > syncState.timestampMilliseconds {
                syncState.recordRemoteChange(NSPasteboard.general.changeCount, timestampMilliseconds: milliseconds)
            }
            logDecision("ignored", device: device, reason: "identical_content")
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
                logDecision("ignored", device: device, reason: "timestamp_tie")
                return
            }
        }
        guard !replayFilter.contains(content, timestamp: milliseconds) else {
            logDecision("ignored", device: device, reason: "replayed_generation")
            return
        }
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
        for peer in devices where peer.id != device.id {
            send(DataPacket.clipboardPacket(withContent: content, timestamp: currentTimestamp), to: peer)
        }
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
    
    var isClipboardPacket: Bool { return self.type == DataPacket.clipboardPacketType }
    var isClipboardConnectPacket: Bool { return self.type == DataPacket.clipboardConnectPacketType }
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
    
    
    // MARK: Public methods
    
    func getContent() throws -> String {
        try self.validateClipboardType()
        guard body.keys.contains(ClipboardProperty.content.rawValue) else { throw ClipboardError.invalidContent }
        guard let value = body[ClipboardProperty.content.rawValue] as? String else { throw ClipboardError.invalidContent }
        return value
    }
    
    func getTimestamp() throws -> Int64 {
        guard isClipboardPacket || isClipboardConnectPacket else { throw ClipboardError.wrongType }
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
