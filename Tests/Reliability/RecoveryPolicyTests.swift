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

    func testRepeatedEqualPathNotificationsPreserveConnections() {
        XCTAssertTrue(RecoveryPolicy.shouldHandlePathUpdate("wifi-route-A", previous: nil,
            available: true, servicesRunning: false))
        // The live trace delivered equal NWPaths every 5–15 seconds. None may
        // restart a working connection, regardless of the three-second cooldown.
        for _ in 0..<20 {
            XCTAssertFalse(RecoveryPolicy.shouldHandlePathUpdate("wifi-route-A", previous: "wifi-route-A",
                available: true, servicesRunning: true))
        }
        XCTAssertTrue(RecoveryPolicy.shouldHandlePathUpdate("wifi-route-B", previous: "wifi-route-A",
            available: true, servicesRunning: true))
        XCTAssertTrue(RecoveryPolicy.shouldHandlePathUpdate("offline", previous: "wifi-route-B",
            available: false, servicesRunning: true))
        XCTAssertTrue(RecoveryPolicy.shouldHandlePathUpdate("wifi-route-B", previous: "offline",
            available: true, servicesRunning: true))
    }

    func testRepeatedPathCanRetryAFailedServiceStart() {
        XCTAssertTrue(RecoveryPolicy.shouldHandlePathUpdate("wifi", previous: "wifi",
            available: true, servicesRunning: false))
        XCTAssertFalse(RecoveryPolicy.shouldHandlePathUpdate("offline", previous: "offline",
            available: false, servicesRunning: false))
    }
}
