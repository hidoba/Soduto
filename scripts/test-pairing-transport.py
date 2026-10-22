#!/usr/bin/env python3
"""Run production pairing/state callbacks against fake transport and certificates.

No real socket, pasteboard, keychain, device configuration or app is touched.
Swift source sections are extracted verbatim; the test fails if they disappear.
"""
from pathlib import Path
import hashlib
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
connection = (root / 'Soduto/Core/Connection.swift').read_text()
packet = (root / 'Soduto/Core/DataPacket.swift').read_text()
certificate = (root / 'Soduto/Core/CertificateUtils.swift').read_text()

def section(source, start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]

stubs = r'''
import Foundation
import CryptoKit
public typealias SecCertificate = Data
public struct SecIdentity { let certificate: SecCertificate? }
public final class DeviceConfiguration {
    public let deviceId = "synthetic-peer"
    public var name = "Synthetic peer"
    public var type = DeviceType.Desktop
    public var certificate: SecCertificate?
    public var isPaired = false
    public var hostCertificate: SecIdentity? = SecIdentity(certificate: Data([1]))
}
public final class FakeConfiguration {
    let device: DeviceConfiguration
    init(_ device: DeviceConfiguration) { self.device = device }
    public func deviceConfig(for id: String) -> DeviceConfiguration { device }
    public func knownDeviceConfigs() -> [DeviceConfiguration] { [device] }
    public var hostDeviceId: String { "synthetic-host" }
}
public struct DataPacket {
    public typealias Body = [String: AnyObject]
    public static let protocolVersion: UInt = 8
    public let type: String
    public let body: Body
    public var id: Int64 { 1 }
    public init(type: String, body: Body) { self.type = type; self.body = body }
    public enum IdentityError: Error { case invalidProtocolVersion }
    enum IdentityProperty: String { case protocolVersion }
    func validateIdentityType() throws {}
    func getDeviceId() throws -> String { body["deviceId"] as? String ?? "synthetic-peer" }
    func getDeviceName() throws -> String { "Synthetic peer" }
    func getDeviceType() throws -> String { "desktop" }
    func getIncomingCapabilities() throws -> Set<String> { Set(body["incomingCapabilities"] as? [String] ?? []) }
    func getOutgoingCapabilities() throws -> Set<String> { Set(body["outgoingCapabilities"] as? [String] ?? []) }
    func getClientName() -> String? { nil }
    func getClientVersion() -> String? { nil }
    func getPlatformName() -> String? { nil }
    func getPlatformVersion() -> String? { nil }
'''
stubs += section(packet, '    public func getProtocolVersion()', '    public func getTCPPort()') + '}\n'
stubs += r'''
final class TimerTracker { static var timers: [Timer] = [] }
extension Timer {
    static func compatScheduledTimer(withTimeInterval interval: TimeInterval, repeats: Bool,
                                     block: @escaping (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        TimerTracker.timers.append(timer)
        RunLoop.main.add(timer, forMode: .default)
        return timer
    }
}
enum Diagnostics {
    struct Settings { var packetTracingEnabled = false }
    static let shared = Settings()
    static func peer(_ id: String) -> String { id }
    static func record(_ event: String, level: DiagnosticEvent.Level = .info, fields: [String: String]) {}
}
enum DiagnosticEvent { enum Level { case debug, info, warning, error } }
enum Privacy { case `public` }
extension String.StringInterpolation {
    mutating func appendInterpolation<T>(_ value: T, privacy: Privacy) { appendLiteral(String(describing: value)) }
}
enum Logger {
    struct Sink { func error(_ message: String) {}; func debug(_ message: String) {} }
    static let network = Sink()
    static let device = Sink()
}
public struct ServiceAction { public typealias Id = Int }
public protocol CapabilitiesDataSource {
    var incomingCapabilities: Set<String> { get }
    var outgoingCapabilities: Set<String> { get }
}
extension UserDefaults { func serviceBool(_ key: String) -> Bool { true } }
public class CertificateUtils {
    class func pairVerificationCode(localCert: SecCertificate, remoteCert: SecCertificate, timestamp: Int64?) -> String? {
        pairVerificationCode(localPublicKey: localCert, remotePublicKey: remoteCert, timestamp: timestamp)
    }
'''
stubs += section(certificate, '    public class func pairVerificationCode(localPublicKey:', '    /// Generates a pair verification code from two certificates.') + '}\n'
stubs += r'''
public protocol ConnectionDelegate: AnyObject {
    func connection(_ connection: Connection, didSwitchToState state: Connection.State)
    func connection(_ connection: Connection, didSendPacket packet: DataPacket, uploadedPayload: Bool)
    func connection(_ connection: Connection, didReadPacket packet: DataPacket)
    func connectionCapacityChanged(_ connection: Connection)
    func connection(_ connection: Connection, uploadPayloadProgress bytesSent: Int64, totalBytes: Int64?, forPacket packet: DataPacket)
}
extension ConnectionDelegate {
    public func connection(_ connection: Connection, didSendPacket packet: DataPacket, uploadedPayload: Bool) {}
    public func connection(_ connection: Connection, didReadPacket packet: DataPacket) {}
    public func connectionCapacityChanged(_ connection: Connection) {}
    public func connection(_ connection: Connection, uploadPayloadProgress bytesSent: Int64, totalBytes: Int64?, forPacket packet: DataPacket) {}
}
final class FakeChannel { func close(promise: Any?) {} }
public final class Connection: PairingHandlerDelegate, Equatable {
    public static func == (lhs: Connection, rhs: Connection) -> Bool { lhs === rhs }
    public typealias SendingCompletionHandler = (Bool, Bool) -> Void
    public enum State { case Initializing, Open, Closed }
    public weak var delegate: ConnectionDelegate?
    public weak var pairingDelegate: ConnectionPairingDelegate?
    public var peerCertificate: SecCertificate? = Data([2])
    var pairingHandler: DefaultPairingHandler?
    var peerProtocolVersion: UInt = 8
    var identity: DataPacket? = DataPacket(type: "kdeconnect.identity", body: [:])
    let config: FakeConfiguration
    let channel: FakeChannel? = FakeChannel()
    var sent: [DataPacket] = []
    var events: [String] = []
    var unsent: [(dataPacket: DataPacket, completionHandler: SendingCompletionHandler?)] = []
    var hasActiveUploadTasks = false
    let diagnosticID = "synthetic-connection"
    let peerAddress = "synthetic-address"
    var verificationCode: String? { pairingHandler?.verificationCode }
    var packetReceiver: (() -> Void)?
    var initializationTimeout: DispatchWorkItem?
    var diagnosticPhase = "test"
    var diagnosticFields: [String: String] { [:] }
    func rememberHwAddress() {}
    func recordDiagnostic(_ event: String, level: DiagnosticEvent.Level = .info, error: Error? = nil) { events.append(event) }
    public func send(_ packet: DataPacket) -> Bool { sent.append(packet); return true }
    public func send(_ packet: DataPacket, whenCompleted: SendingCompletionHandler?) -> Bool {
        sent.append(packet); whenCompleted?(true, false); return true
    }
    func reclaimUnsentPackets() -> [(dataPacket: DataPacket, completionHandler: SendingCompletionHandler?)] {
        defer { unsent = [] }; return unsent
    }
    func cancelUpload(forPacketId: Int64) {}
    func sendKeepAlivePacket() {}
    func closeAfterWriting() { close() }
    init(config: DeviceConfiguration = DeviceConfiguration(), version: UInt = 8) {
        self.config = FakeConfiguration(config)
        self.state = .Open
        self.peerProtocolVersion = version
        self.pairingHandler = DefaultPairingHandler(config: config)
        self.pairingHandler!.delegate = self
        self.pairingHandler!.setPeerProtocolVersion(version)
    }
    func prepareHandshake() { state = .Initializing }
    func completeTLSHandshake() { state = .Open }
    func handleReceivedPacket(_ data: Data) { packetReceiver?() }
'''
stubs += section(connection, '    public private(set) var state: State {', '    public private(set) var identity:')
stubs += section(connection, '    public var pairingStatus: PairingStatus {', '    // MARK: CustomStringConvertible')
stubs += section(connection, '    public func close() {', '    public func closeAfterWriting()')
stubs += section(connection, '    private func handlePairingPacket(', '    fileprivate func handleTLSEstablished()').replace('private func handlePairingPacket', 'func handlePairingPacket')
stubs += section(connection, '    fileprivate func handleTLSEstablished()', '    private func completeTLSHandshake()')
stubs += section(connection, '    fileprivate func handleReceivedData(', '    private func handleReceivedPacket(')
stubs += '}\n'
stubs = stubs.replace('        self.pairingHandler!.setPeerProtocolVersion(version)\n',
    '        self.pairingHandler!.setPeerProtocolVersion(version)\n' +
    section(connection, '        self.pairingHandler!.timeoutHandler =', '        // Every supported connection'))
stubs += r'''
public protocol ConnectionProviderDelegate: AnyObject {
    func isNewConnectionNeeded(byProvider provider: ConnectionProvider, deviceId: String) -> Bool
    func connectionProvider(_ provider: ConnectionProvider, probeConnectionsFor deviceId: String)
    func connectionProviderWillRestart(_ provider: ConnectionProvider, reason: String)
    func connectionProvider(_ provider: ConnectionProvider, didCreateConnection connection: Connection)
}
public final class ConnectionProvider {}
extension FakeConfiguration: DeviceManagerConfiguration {}
func CACurrentMediaTime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
enum PairingState { case outgoingRequest, incomingRequest, failed, timeout }
enum PairingWindowController {
    static func isActive(for id: String) -> Bool { false }
    static func state(for id: String) -> PairingState? { nil }
    static func updateState(for id: String, state: PairingState) {}
}
enum PairingInterfaceController {
    static func updatePairingUI(for deviceId: String, success: Bool) {}
}
final class ClipboardProbe: Service {
    static let serviceId = "synthetic.clipboard"
    let incomingCapabilities: Set<String> = ["kdeconnect.clipboard"]
    let outgoingCapabilities: Set<String> = ["kdeconnect.clipboard"]
    var handled = 0
    func handleDataPacket(_ packet: DataPacket, fromDevice: Device, onConnection: Connection) -> Bool {
        guard packet.type == "kdeconnect.clipboard" else { return false }
        handled += 1; return true
    }
    func setup(for device: Device) {}
    func cleanup(for device: Device) {}
    func actions(for device: Device) -> [ServiceAction] { [] }
    func performAction(_ id: Int, forDevice device: Device, userInfo: [String: Any]?) {}
}
'''

tests = r'''
final class Spy: ConnectionPairingDelegate, ConnectionDelegate {
    var requests = 0
    var failures = 0
    var statuses: [PairingStatus] = []
    var states: [Connection.State] = []
    var ownsOpenConnection = false
    func connection(_ connection: Connection, receivedPairingRequest request: PairingRequest) { requests += 1 }
    func connection(_ connection: Connection, pairingFailed error: Error) { failures += 1 }
    func connection(_ connection: Connection, pairingStatusChanged status: PairingStatus) { statuses.append(status) }
    func connection(_ connection: Connection, didSwitchToState state: Connection.State) {
        states.append(state)
        ownsOpenConnection = state == .Open
    }
}
func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
func request(_ value: AnyObject?) -> DataPacket {
    var body: DataPacket.Body = ["pair": NSNumber(value: true)]
    body["timestamp"] = value
    return DataPacket(type: DataPacket.pairingPacketType, body: body)
}
let now = Date()
for bad: AnyObject? in [nil, "invalid" as NSString, NSNumber(value: 0), NSNumber(value: -1),
                        NSNumber(value: Double.infinity), NSNumber(value: Double.nan),
                        NSNumber(value: now.timeIntervalSince1970 + 0.5),
                        NSNumber(value: Int64(now.timeIntervalSince1970) - 1801),
                        NSNumber(value: Int64(now.timeIntervalSince1970) + 1801),
                        NSNumber(value: Double.greatestFiniteMagnitude)] {
    let connection = Connection()
    let spy = Spy(); connection.pairingDelegate = spy
    connection.handlePairingPacket(request(bad))
    precondition(connection.pairingStatus == .Unpaired && spy.requests == 0 && spy.failures == 1)
}
print("PASS: invalid, stale and future v8 pairing requests are rejected")

let incoming = Connection()
let incomingSpy = Spy(); incoming.pairingDelegate = incomingSpy
let timestamp = Int64(Date().timeIntervalSince1970)
incoming.handlePairingPacket(.pairPacket(timestamp: timestamp))
precondition(incoming.pairingStatus == .RequestedByPeer && incomingSpy.requests == 1)
let incomingCode = incoming.pairingHandler!.verificationCode
incoming.acceptPairing()
precondition(incoming.pairingStatus == .Paired && incoming.config.device.certificate == Data([2]))
let replyCount = incoming.sent.count
incoming.handlePairingPacket(.pairPacket())
precondition(incoming.sent.count == replyCount)
print("PASS: v8 pairing stores the TLS certificate and duplicate confirmations do not echo")
let previousPin = incoming.config.device.certificate
incoming.handlePairingPacket(.pairPacket(timestamp: timestamp - 1801))
precondition(incoming.config.device.certificate == previousPin && incoming.pairingStatus == .Paired)
incoming.handlePairingPacket(.pairPacket(timestamp: timestamp))
precondition(incoming.pairingStatus == .RequestedByPeer && incomingSpy.requests == 2)
precondition(incoming.sent.count == replyCount, "Re-pair request was accepted automatically")
incoming.acceptPairing()
precondition(incoming.pairingStatus == .Paired)
print("PASS: fresh re-pair requests require approval and stale requests preserve the existing pin")


let outgoing = Connection()
outgoing.requestPairing()
let sentTimestamp = try outgoing.sent.last!.getPairingTimestamp()
let expected = CertificateUtils.pairVerificationCode(localPublicKey: Data([2]), remotePublicKey: Data([1]), timestamp: sentTimestamp)
precondition(outgoing.pairingHandler!.verificationCode == expected)
outgoing.handlePairingPacket(.pairPacket())
precondition(outgoing.pairingStatus == .Paired)
print("PASS: v8 outgoing request and timestamp-less acceptance use matching verification codes")

let legacy = Connection(version: 7)
legacy.handlePairingPacket(.pairPacket())
precondition(legacy.pairingStatus == .RequestedByPeer)
precondition(legacy.pairingHandler!.verificationCode == CertificateUtils.pairVerificationCode(localPublicKey: Data([1]), remotePublicKey: Data([2])))
legacy.acceptPairing()
precondition(legacy.pairingStatus == .Paired)
print("PASS: protocol v7 pairing remains supported without a timestamp")

let missingCertificate = Connection()
missingCertificate.peerCertificate = nil
missingCertificate.requestPairing()
missingCertificate.handlePairingPacket(.pairPacket())
precondition(missingCertificate.pairingStatus == .Unpaired)
let unsolicitedAccept = Connection()
unsolicitedAccept.acceptPairing()
precondition(unsolicitedAccept.sent.isEmpty && unsolicitedAccept.config.device.certificate == nil)
print("PASS: pairing cannot succeed without a certificate or an incoming request")

let interrupted = Connection()
let interruptedSpy = Spy(); interrupted.pairingDelegate = interruptedSpy
interrupted.requestPairing()
spin()
interrupted.close()
spin()
precondition(interrupted.state == .Closed && interrupted.pairingHandler!.pairingStatus == .Unpaired)
precondition(interruptedSpy.failures == 1)
precondition(TimerTracker.timers.allSatisfy { !$0.isValid })
let pairedPin = incoming.config.device.certificate
incoming.close()
precondition(incoming.config.device.certificate == pairedPin)
print("PASS: disconnect cancels pending pairing timers while preserving established pins")
let timedOut = Connection()
let timeoutSpy = Spy(); timedOut.pairingDelegate = timeoutSpy
 timedOut.requestPairing()
spin()
TimerTracker.timers.last!.fire()
precondition(timedOut.pairingStatus == .Unpaired && timeoutSpy.failures == 1)
let timeoutPairFlag = try timedOut.sent.last!.getPairFlag()
precondition(timeoutPairFlag == false)
print("PASS: pairing timeout clears the request and reports failure once")


let opening = Connection()
let handoffSpy = Spy(); opening.delegate = handoffSpy
opening.prepareHandshake()
var receivedAfterHandoff = false
opening.packetReceiver = { receivedAfterHandoff = handoffSpy.ownsOpenConnection }
opening.handleTLSEstablished()
opening.handleReceivedData(Data())
spin()
precondition(receivedAfterHandoff, "First service packet raced the Open handoff")
opening.close()
var processedClosedPacket = false
opening.packetReceiver = { processedClosedPacket = true }
opening.handleReceivedData(Data())
opening.handleTLSEstablished()
spin()
precondition(!processedClosedPacket && opening.state == .Closed)
print("PASS: initial packets follow the Open handoff and late closed-socket events are discarded")

for version in [7,8] {
    let value = try DataPacket(type: "kdeconnect.identity", body: ["protocolVersion": NSNumber(value: version)]).getProtocolVersion()
    precondition(value == UInt(version))
}
for version in [Double(-1), 0, 6, 7.5, 9, Double.nan, Double.infinity, Double.greatestFiniteMagnitude] {
    do {
        _ = try DataPacket(type: "kdeconnect.identity", body: ["protocolVersion": NSNumber(value: version)]).getProtocolVersion()
        preconditionFailure("Invalid protocol version accepted")
    } catch {}
}
print("PASS: protocol parsing admits only supported TLS-capable versions")

let pairedConfig = DeviceConfiguration()
pairedConfig.isPaired = true; pairedConfig.certificate = Data([2])
let oldConnection = Connection(config: pairedConfig)
let device = try Device(connection: oldConnection, config: pairedConfig)
var failedClipboardCompletions = 0
oldConnection.unsent = [
    (DataPacket(type: "kdeconnect.clipboard", body: [:]), { sent, _ in
        precondition(!sent); failedClipboardCompletions += 1
    }),
    (DataPacket(type: "kdeconnect.clipboard.connect", body: [:]), { sent, _ in
        precondition(!sent); failedClipboardCompletions += 1
    }),
    (DataPacket(type: "synthetic.retry", body: [:]), nil)
]
oldConnection.close()
precondition(!device.isReachable && failedClipboardCompletions == 2)
let reconnected = Connection(config: pairedConfig)
reconnected.identity = DataPacket(type: "kdeconnect.identity", body: [
    "incomingCapabilities": ["kdeconnect.clipboard"] as NSArray,
    "outgoingCapabilities": ["kdeconnect.clipboard", "kdeconnect.clipboard.connect"] as NSArray
])
device.addConnection(reconnected)
precondition(device.isReachable && device.incomingCapabilities.contains("kdeconnect.clipboard"))
precondition(device.outgoingCapabilities.contains("kdeconnect.clipboard.connect"))
precondition(reconnected.sent.map { $0.type } == ["synthetic.retry"], "Stale clipboard replayed after reconnect")
print("PASS: reconnect refreshes capabilities and never replays an obsolete queued clipboard")

let serviceManager = ServiceManager()
let clipboardProbe = ClipboardProbe(); serviceManager.add(service: clipboardProbe)
let deviceManager = DeviceManager(config: FakeConfiguration(pairedConfig), serviceManager: serviceManager)
let provider = ConnectionProvider()
let beforePluginEnable = Connection(config: pairedConfig)
deviceManager.connectionProvider(provider, didCreateConnection: beforePluginEnable)
let retainedDevice = deviceManager.device(withId: "synthetic-peer")!
beforePluginEnable.close()
let afterPluginEnable = Connection(config: pairedConfig)
afterPluginEnable.identity = reconnected.identity
deviceManager.connectionProvider(provider, didCreateConnection: afterPluginEnable)
precondition(deviceManager.device(withId: "synthetic-peer") === retainedDevice)
retainedDevice.connection(afterPluginEnable, didReadPacket: DataPacket(type: "kdeconnect.clipboard", body: [:]))
precondition(clipboardProbe.handled == 1, "Cached device lost its newly enabled clipboard handler")
print("PASS: enabling clipboard across a brief reconnect rebuilds cached device dispatch")

retainedDevice.unpair()
retainedDevice.requestPairing()
let competing = Connection(config: pairedConfig)
deviceManager.connectionProvider(provider, didCreateConnection: competing)
precondition(competing.state == .Closed && retainedDevice.pairingStatus == .Requested)
deviceManager.closeAllConnections()
precondition(deviceManager.pairedRechableDevices.isEmpty)
print("PASS: competing connections cannot replace an active pairing prompt")
'''
# Independent known-answer check for the production verification hash function.
expected = hashlib.sha256(bytes([2, 1]) + b'1700000000').hexdigest()[:8].upper()
tests += '\nprecondition(CertificateUtils.pairVerificationCode(localPublicKey: Data([1]), remotePublicKey: Data([2]), timestamp: 1700000000) == "' + expected[:4] + ' ' + expected[4:] + '")\n'
with tempfile.TemporaryDirectory(prefix='soduto-pairing-tests-') as directory:
    directory = Path(directory)
    source = directory / 'main.swift'
    source.write_text(stubs + (root / 'Soduto/Core/Device.swift').read_text().replace('import os', '') +
                      (root / 'Soduto/Core/Service.swift').read_text() +
                      (root / 'Soduto/Core/ServiceManager.swift').read_text() +
                      (root / 'Soduto/Core/DeviceManager.swift').read_text().replace('import os', '').replace('import QuartzCore', '') +
                      (root / 'Soduto/Core/Pairable.swift').read_text() +
                      (root / 'Soduto/Core/DefaultPairingHandler.swift').read_text() + tests)
    executable = directory / 'pairing-tests'
    subprocess.run(['swiftc', str(source), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
