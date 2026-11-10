import Foundation
import Security
import XCTest
import NIOCore
import NIOPosix
@testable import SodutoIdentity

/// Upload ports come from a fixed range of 26, so a task that ends without
/// releasing its port eventually makes every later upload fail.
final class UploadTaskPortTests: XCTestCase {
    private var keychain: TestKeychain!
    private var fixture: Fixture!
    private var group: MultiThreadedEventLoopGroup!

    override class func setUp() {
        super.setUp()
        // The fixture holds only synthetic keys and must never prompt.
        XCTAssertEqual(SecKeychainSetUserInteractionAllowed(false), errSecSuccess)
    }

    override func setUpWithError() throws {
        keychain = try TestKeychain()
        fixture = try Fixture(in: keychain.keychain)
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        XCTAssertFalse(PayloadPortRegistry.hasUsedPorts())
    }

    override func tearDownWithError() throws {
        try group.syncShutdownGracefully()
        group = nil
        fixture = nil
        keychain = nil
    }

    private func makeTask() -> UploadTask? {
        let data = Data(repeating: 1, count: 16)
        return UploadTask(packet: DataPacket(payload: InputStream(data: data), payloadSize: Int64(data.count)),
                          hostIdentity: fixture.identity, expectedPeerCertificate: nil, eventLoopGroup: group)
    }

    func testClosedTasksReleaseTheirPorts() throws {
        // A connection closes its pending uploads with close(), not cancel().
        for round in 0..<40 {
            let task = try XCTUnwrap(makeTask(), "no port available in round \(round)")
            task.close()
            XCTAssertFalse(PayloadPortRegistry.hasUsedPorts(), "round \(round)")
        }
    }

    func testDeallocatedTasksReleaseTheirPorts() throws {
        for round in 0..<40 {
            XCTAssertNotNil(makeTask(), "no port available in round \(round)")
            XCTAssertFalse(PayloadPortRegistry.hasUsedPorts(), "round \(round)")
        }
    }

    func testCancelledTasksReleaseTheirPortsOnce() throws {
        for round in 0..<40 {
            let task = try XCTUnwrap(makeTask(), "no port available in round \(round)")
            task.cancel()
            // Releasing an unused port is an assertion failure.
            task.close()
            XCTAssertFalse(PayloadPortRegistry.hasUsedPorts(), "round \(round)")
        }
    }

    func testOpenTasksKeepTheirPorts() throws {
        let tasks = (0..<3).compactMap { _ in makeTask() }
        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(Set(tasks.map { $0.payloadInfo["port"] as? UInt16 }).count, 3)
        XCTAssertTrue(PayloadPortRegistry.hasUsedPorts())
        tasks.forEach { $0.close() }
        XCTAssertFalse(PayloadPortRegistry.hasUsedPorts())
    }
}
