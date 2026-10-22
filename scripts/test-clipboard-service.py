#!/usr/bin/env python3
"""Exercise the real ClipboardService with a fake pasteboard and peers.

No system clipboard, keychain, network or device configuration is touched.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
stubs = r'''
import Foundation
public enum Service { public typealias Id = String; public typealias Capability = String }
public struct ServiceAction { public typealias Id = Int }
public protocol BidirectionalService {}
extension BidirectionalService {
    var incomingEnabled: Bool { true }
    var outgoingEnabled: Bool { true }
    func send(_ packet: DataPacket, to device: Device) { device.sent.append(packet) }
}
public enum AppDefaultsStore { public enum Preferences { public enum Services { public enum Clipboard {
    static let incomingKey = "incoming"
    static let outgoingKey = "outgoing"
}}}}
public final class Device {
    public let id: String
    public var sent: [DataPacket] = []
    public init(_ id: String) { self.id = id }
}
public final class Connection {}
public struct DataPacket {
    public typealias Body = [String: AnyObject]
    public let type: String
    public let body: Body
    public init(type: String, body: Body) { self.type = type; self.body = body }
}
final class NSPasteboard {
    static let general = NSPasteboard()
    var changeCount = 0
    var content: String? = "initial synthetic text"
    func readObjects(forClasses classes: [AnyClass], options: [String: Any]?) -> [Any]? {
        content.map { [$0 as NSString] }
    }
    func clearContents() { content = nil; changeCount += 1 }
    @discardableResult func writeObjects(_ values: [NSString]) -> Bool {
        content = values.first as String?; changeCount += 1; return true
    }
    func simulateCopy(_ value: String?) { content = value; changeCount += 1 }
}
extension Timer {
    static func compatScheduledTimer(withTimeInterval interval: TimeInterval, repeats: Bool,
                                     block: @escaping (Timer) -> Void) -> Timer {
        Timer(timeInterval: interval, repeats: repeats, block: block)
    }
}
enum Diagnostics {
    static func peer(_ id: String?) -> String { id ?? "unknown" }
    static func record(_ event: String, level: DiagnosticEvent.Level = .info, fields: [String: String] = [:]) {}
}
'''
tests = r'''
extension ClipboardService { func pollForTest() { checkPasteboard() } }
let service = ClipboardService()
let peer = Device("sender")
let other = Device("other")
let connection = Connection()
let oldTime = Date().addingTimeInterval(-120).timeIntervalSince1970 * 1000
func packet(_ type: String, _ content: String, _ timestamp: Double) -> DataPacket {
    DataPacket(type: type, body: ["content": content as NSString, "timestamp": NSNumber(value: timestamp)])
}
func receive(_ type: String, _ content: String, _ timestamp: Double) {
    precondition(service.handleDataPacket(packet(type, content, timestamp), fromDevice: peer, onConnection: connection))
}
service.setup(for: peer)
receive("kdeconnect.clipboard", "old synthetic text", oldTime)
service.pollForTest()
service.cleanup(for: peer)
NSPasteboard.general.simulateCopy("new offline copy")
service.setup(for: peer)
let reconnect = peer.sent.last!
precondition(reconnect.type == "kdeconnect.clipboard.connect")
let timestamp = (reconnect.body["timestamp"] as! NSNumber).doubleValue
precondition(timestamp > oldTime + 60_000)
receive("kdeconnect.clipboard.connect", "stale remote text", oldTime + 60_000)
precondition(NSPasteboard.general.content == "new offline copy", "Offline copy was overwritten")
print("PASS: new offline clipboard beats stale reconnect clipboard")

// A packet can arrive before the next 0.5s monitoring tick.
NSPasteboard.general.simulateCopy("copy immediately before incoming packet")
receive("kdeconnect.clipboard.connect", "stale remote text", oldTime + 60_000)
precondition(NSPasteboard.general.content == "copy immediately before incoming packet")
print("PASS: local copy between timer ticks is preserved")

// Fresh images/files count as changes even though there is no shareable text.
NSPasteboard.general.simulateCopy(nil)
receive("kdeconnect.clipboard.connect", "stale text replacing image", oldTime + 60_000)
precondition(NSPasteboard.general.content == nil)
print("PASS: fresh non-text clipboard survives a stale text handshake")

service.setup(for: other)
peer.sent.removeAll(); other.sent.removeAll()
receive("kdeconnect.clipboard", "new remote synthetic text", oldTime)
precondition(peer.sent.isEmpty, "Incoming clipboard echoed to sender")
precondition(other.sent.count == 1, "Incoming clipboard was not relayed to another peer")
service.pollForTest()
precondition(peer.sent.isEmpty && other.sent.count == 1, "Timer echoed or duplicated remote text")
print("PASS: remote clipboard relays once without an echo")

let before = NSPasteboard.general.content
receive("kdeconnect.clipboard.connect", "unknown timestamp", 0)
precondition(NSPasteboard.general.content == before)
receive("kdeconnect.clipboard.connect", "invalid timestamp", Double.infinity)
precondition(NSPasteboard.general.content == before)
print("PASS: zero and non-finite timestamps are ignored")
'''
with tempfile.TemporaryDirectory(prefix="soduto-clipboard-tests-") as directory:
    directory = Path(directory)
    source = root / "Soduto/Services/ClipboardService.swift"
    combined = directory / "main.swift"
    combined.write_text(stubs + source.read_text().replace("import Cocoa", "") + tests)
    executable = directory / "clipboard-tests"
    subprocess.run([
        "swiftc", str(root / "Soduto/Core/Diagnostics/DiagnosticEvent.swift"),
        str(root / "Soduto/Core/Diagnostics/ClipboardSyncState.swift"),
        str(combined), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)
