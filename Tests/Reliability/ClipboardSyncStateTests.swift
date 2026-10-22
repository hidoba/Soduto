import XCTest
@testable import SodutoReliability

final class ClipboardSyncStateTests: XCTestCase {
    func testRapidCopiesAndClockChangesKeepIncreasingGenerations() {
        var state = ClipboardSyncState(changeCount: 0)
        state.observeLocalChange(1, now: Date(timeIntervalSince1970: 1))
        state.observeLocalChange(2, now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(state.timestampMilliseconds, 1001)
        state.observeLocalChange(3, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(state.timestampMilliseconds, 1002)
    }

    func testReplayFilterRecognizesGenerationWithoutBlockingNewCopies() {
        var filter = ClipboardReplayFilter()
        filter.remember("synthetic value", timestamp: 1)
        XCTAssertTrue(filter.contains("synthetic value", timestamp: 1))
        XCTAssertFalse(filter.contains("different value", timestamp: 1))
        XCTAssertFalse(filter.contains("synthetic value", timestamp: 2))
    }

    func testReplayHistoryIsBounded() {
        var filter = ClipboardReplayFilter()
        for generation in 1...129 { filter.remember("synthetic value", timestamp: Int64(generation)) }
        XCTAssertFalse(filter.contains("synthetic value", timestamp: 1))
        XCTAssertTrue(filter.contains("synthetic value", timestamp: 2))
        XCTAssertTrue(filter.contains("synthetic value", timestamp: 129))
    }

    func testNewOfflineCopyRejectsOlderReconnectClipboard() {
        var state = ClipboardSyncState(changeCount: 1)
        state.recordRemoteChange(2, timestampMilliseconds: 100_000)
        XCTAssertTrue(state.observeLocalChange(3, now: Date(timeIntervalSince1970: 300)))
        XCTAssertEqual(state.timestampMilliseconds, 300_000)
        XCTAssertFalse(state.shouldAcceptConnect(timestampMilliseconds: 200_000))
        XCTAssertTrue(state.shouldAcceptConnect(timestampMilliseconds: 400_000))
    }

    func testRemoteReceivePreservesOriginalTimestampWithoutBecomingLocalCopy() {
        var state = ClipboardSyncState(changeCount: 10)
        state.recordRemoteChange(12, timestampMilliseconds: 123_456)
        XCTAssertFalse(state.observeLocalChange(12, now: Date(timeIntervalSince1970: 500)))
        XCTAssertEqual(state.timestampMilliseconds, 123_456)
        XCTAssertFalse(state.shouldAcceptConnect(timestampMilliseconds: 123_456))
    }

    func testUnknownAndNegativeTimestampsNeverOverwriteClipboard() {
        let state = ClipboardSyncState(changeCount: 0)
        XCTAssertFalse(state.shouldAcceptConnect(timestampMilliseconds: 0))
        XCTAssertFalse(state.shouldAcceptConnect(timestampMilliseconds: -1))
        XCTAssertTrue(state.shouldAcceptConnect(timestampMilliseconds: 1))
    }

    func testTimestampDoesNotAdvanceOnUnchangedPoll() {
        var state = ClipboardSyncState(changeCount: 1)
        XCTAssertTrue(state.observeLocalChange(2, now: Date(timeIntervalSince1970: 1)))
        XCTAssertFalse(state.observeLocalChange(2, now: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(state.timestampMilliseconds, 1000)
    }

    func testInvalidRemoteDatesCannotTrapIntegerConversion() {
        for time in [Double.nan, Double.infinity, -Double.infinity, -1, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(ClipboardSyncState.milliseconds(Date(timeIntervalSince1970: time)), 0)
        }
    }
}
