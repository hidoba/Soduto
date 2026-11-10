import Foundation

enum RecoveryPolicy {
    static let handshakeTimeout: TimeInterval = 10
    static let restartCooldown: TimeInterval = 3

    static func isValidTCPPort(_ port: Int) -> Bool { (1716...1764).contains(port) }

    static func restartDelay(lastStart: Date?, now: Date = Date()) -> TimeInterval {
        guard let lastStart else { return 0 }
        return min(restartCooldown, max(0, restartCooldown - now.timeIntervalSince(lastStart)))
    }

    /// Network.framework can repeat an equal path notification. Keep working
    /// sockets alive, but allow another start attempt if services failed to start.
    static func shouldHandlePathUpdate<Path: Equatable>(_ path: Path, previous: Path?,
                                                       available: Bool, servicesRunning: Bool) -> Bool {
        previous != path || (available && !servicesRunning)
    }
}
