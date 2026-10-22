import Foundation

/// Tracks freshness without retaining or logging clipboard contents.
struct ClipboardSyncState {
    private(set) var changeCount: Int
    private(set) var timestampMilliseconds: Int64 = 0

    init(changeCount: Int) { self.changeCount = changeCount }

    @discardableResult
    mutating func observeLocalChange(_ newCount: Int, now: Date = Date()) -> Bool {
        guard newCount != changeCount else { return false }
        changeCount = newCount
        timestampMilliseconds = Self.milliseconds(now)
        return true
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
