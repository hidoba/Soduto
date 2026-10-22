import XCTest
@testable import SodutoReliability

final class RecoveryPolicyTests: XCTestCase {
    func testUntrustedPortsCannotOverflowOrEscapeKDEConnectRange() {
        for invalid in [Int.min, -1, 0, 1715, 1765, 65536, Int.max] {
            XCTAssertFalse(RecoveryPolicy.isValidTCPPort(invalid))
        }
        XCTAssertTrue(RecoveryPolicy.isValidTCPPort(1716))
        XCTAssertTrue(RecoveryPolicy.isValidTCPPort(1764))
    }

    func testRestartCooldownDoesNotQueueRepeatedImmediateRestarts() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(RecoveryPolicy.restartDelay(lastStart: nil, now: now), 0)
        XCTAssertEqual(RecoveryPolicy.restartDelay(lastStart: now, now: now), 3)
        XCTAssertEqual(RecoveryPolicy.restartDelay(lastStart: now.addingTimeInterval(-1), now: now), 2)
        XCTAssertEqual(RecoveryPolicy.restartDelay(lastStart: now.addingTimeInterval(-30), now: now), 0)
        XCTAssertEqual(RecoveryPolicy.restartDelay(lastStart: now.addingTimeInterval(3600), now: now), 3)
    }
}
