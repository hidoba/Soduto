import Foundation
import CryptoKit

/// Remember a bounded set of clipboard generations without retaining their text.
/// Packet IDs cannot identify a relay: each forwarding peer creates a new one.
struct ClipboardReplayFilter {
    private struct Fingerprint: Equatable {
        let digest: Data
        let timestamp: Int64
    }
    private var recent: [Fingerprint] = []
    private let capacity = 128

    func contains(_ content: String, timestamp: Int64) -> Bool {
        recent.contains(fingerprint(content, timestamp: timestamp))
    }

    mutating func remember(_ content: String, timestamp: Int64) {
        let value = fingerprint(content, timestamp: timestamp)
        remember(value)
    }

    func containsImage(_ digest: Data, timestamp: Int64) -> Bool {
        recent.contains(Fingerprint(digest: Data([1]) + digest, timestamp: timestamp))
    }

    mutating func rememberImage(_ digest: Data, timestamp: Int64) {
        remember(Fingerprint(digest: Data([1]) + digest, timestamp: timestamp))
    }

    private mutating func remember(_ value: Fingerprint) {
        guard !recent.contains(value) else { return }
        recent.append(value)
        if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
    }

    private func fingerprint(_ content: String, timestamp: Int64) -> Fingerprint {
        Fingerprint(digest: Data([0]) + Data(SHA256.hash(data: Data(content.utf8))), timestamp: timestamp)
    }
}

/// Tracks freshness without retaining or logging clipboard contents.
struct ClipboardSyncState {
    private(set) var changeCount: Int
    private(set) var timestampMilliseconds: Int64 = 0

    init(changeCount: Int) { self.changeCount = changeCount }

    @discardableResult
    mutating func observeLocalChange(_ newCount: Int, now: Date = Date()) -> Bool {
        guard newCount != changeCount else { return false }
        changeCount = newCount
        timestampMilliseconds = timestampForNextChange(now: now)
        return true
    }

    func timestampForNextChange(now: Date = Date()) -> Int64 {
        // Two copies in one millisecond must still have different generations.
        let next = timestampMilliseconds < Int64.max ? timestampMilliseconds + 1 : Int64.max
        return max(next, Self.milliseconds(now))
    }

    mutating func recordRemoteChange(_ newCount: Int, timestampMilliseconds: Int64) {
        changeCount = newCount
        self.timestampMilliseconds = timestampMilliseconds
    }

    func shouldAcceptConnect(timestampMilliseconds: Int64) -> Bool {
        timestampMilliseconds > 0 && timestampMilliseconds > self.timestampMilliseconds
    }

    static func milliseconds(_ date: Date) -> Int64 {
        let value = date.timeIntervalSince1970 * 1000
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return 0 }
        return Int64(value)
    }
}
