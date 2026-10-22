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
    static var general = NSPasteboard()
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
    DataPacket(type: type, body: ["content": content as NSString, "timestamp": NSNumber(value: timestamp), "sodutoTimestamped": NSNumber(value: true)])
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
receive("kdeconnect.clipboard", "new remote synthetic text", (Date().timeIntervalSince1970 + 1) * 1000)
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
// Legacy clipboard packets carry no timestamp. An identical update must not
// clear other pasteboard representations, change its generation, or be relayed.
peer.sent.removeAll(); other.sent.removeAll()
let countBeforeDuplicate = NSPasteboard.general.changeCount
let legacy = DataPacket(type: "kdeconnect.clipboard", body: ["content": before! as NSString])
_ = service.handleDataPacket(legacy, fromDevice: peer, onConnection: connection)
precondition(NSPasteboard.general.changeCount == countBeforeDuplicate)
precondition(peer.sent.isEmpty && other.sent.isEmpty)
print("PASS: identical legacy clipboard packets neither rewrite nor relay")
let skewedLegacy = DataPacket(type: "kdeconnect.clipboard", body: ["content": "fresh legacy edit" as NSString, "timestamp": NSNumber(value: 1)])
_ = service.handleDataPacket(skewedLegacy, fromDevice: peer, onConnection: connection)
precondition(NSPasteboard.general.content == "fresh legacy edit")
print("PASS: unmarked legacy edits remain live regardless of clock skew")


// Give each synthetic computer its own pasteboard. All peers are mutually
// connected; forwarding creates new packet identities as real clients do.
let names = ["A", "B", "C"]
var boards: [String: NSPasteboard] = [:]
var services: [String: ClipboardService] = [:]
var links: [String: [String: Device]] = [:]
for name in names {
    let board = NSPasteboard()
    boards[name] = board; NSPasteboard.general = board
    services[name] = ClipboardService()
    links[name] = Dictionary(uniqueKeysWithValues: names.filter { $0 != name }.map { ($0, Device($0)) })
    for peer in links[name]!.values { services[name]!.setup(for: peer) }
}
for peers in links.values { for peer in peers.values { peer.sent.removeAll() } }
var events: [(String, String, DataPacket)] = []
func collect() {
    for source in names { for (destination, peer) in links[source]! {
        for packet in peer.sent { events.append((source, destination, packet)) }
        peer.sent.removeAll()
    } }
}
func copy(on name: String, text: String) {
    NSPasteboard.general = boards[name]!
    NSPasteboard.general.simulateCopy(text)
    services[name]!.pollForTest()
    collect()
}
func drain() -> Int {
    var delivered = 0
    while !events.isEmpty && delivered < 100 {
        let (source, destination, packet) = events.removeFirst()
        NSPasteboard.general = boards[destination]!
        _ = services[destination]!.handleDataPacket(packet, fromDevice: links[destination]![source]!, onConnection: connection)
        delivered += 1
        collect()
    }
    precondition(events.isEmpty, "Clipboard relay did not settle")
    return delivered
}
copy(on: "A", text: "one mesh copy")
precondition(drain() <= 6)
precondition(boards.values.allSatisfy { $0.content == "one mesh copy" })
print("PASS: three-peer clipboard triangle settles after one copy")

copy(on: "A", text: "concurrent value one")
copy(on: "B", text: "concurrent value two")
_ = drain()
precondition(Set(boards.values.compactMap { $0.content }).count == 1, "Clipboard mesh did not converge")
print("PASS: interleaved clipboard generations do not circulate forever")

// Re-copying previously shared text is still a new local action.
copy(on: "A", text: "one mesh copy")
_ = drain()
precondition(boards.values.allSatisfy { $0.content == "one mesh copy" })
print("PASS: intentionally copying earlier text syncs again")

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
