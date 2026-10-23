import XCTest
@testable import SodutoReliability

final class DiagnosticLogStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func event(_ store: DiagnosticLogStore, count: Int) -> DiagnosticEvent {
        DiagnosticEvent(session: store.session, level: .info, event: "test.event", fields: ["count": String(count)])
    }

    func testSensitiveFieldsAreExcludedAndMetadataIsBounded() throws {
        let store = DiagnosticLogStore(directory: root)
        store.record(DiagnosticEvent(session: store.session, level: .info, event: "test.privacy", fields: [
            "content": "PRIVATE CLIPBOARD", "body": "PRIVATE MESSAGE", "filename": "PRIVATE FILE",
            "private_key": "PRIVATE KEY", "device": "peer-1234", "reason": String(repeating: "x", count: 1000),
            "image_file_send_supported": "false", "image_file_receive_supported": "true"
        ]))
        store.flush()
        let data = try Data(contentsOf: root.appendingPathComponent("events.jsonl"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE"))
        let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let fields = value["fields"] as! [String: String]
        XCTAssertEqual(fields["device"], "peer-1234")
        XCTAssertEqual(fields["reason"]?.count, 200)
        XCTAssertEqual(fields["image_file_send_supported"], "false")
        XCTAssertEqual(fields["image_file_receive_supported"], "true")
    }

    func testRotationStaysBoundedAndRetainsNewestEvents() throws {
        let store = DiagnosticLogStore(directory: root, maxFileBytes: 1024, fileCount: 3)
        for index in 0..<100 { store.record(event(store, count: index)) }
        store.flush()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertEqual(files.count, 3)
        for file in files {
            XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!, 1024)
            for line in try String(contentsOf: file).split(separator: "\n") {
                XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
            }
        }
        let latest = try String(contentsOf: root.appendingPathComponent("events.jsonl"))
        XCTAssertTrue(latest.contains("\"count\":\"99\""))
    }

    func testSingleFileRotationDoesNotLoseWriter() throws {
        let store = DiagnosticLogStore(directory: root, maxFileBytes: 1024, fileCount: 1)
        for index in 0..<20 { store.record(event(store, count: index)) }
        store.flush()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["events.jsonl"])
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("events.jsonl")).contains("\"count\":\"19\""))
    }

    func testLogsSurviveProcessSessionChanges() throws {
        let first = DiagnosticLogStore(directory: root)
        first.record(event(first, count: 1)); first.flush()
        let second = DiagnosticLogStore(directory: root)
        second.record(event(second, count: 2)); second.flush()
        let contents = try String(contentsOf: root.appendingPathComponent("events.jsonl"))
        XCTAssertTrue(contents.contains(first.session))
        XCTAssertTrue(contents.contains(second.session))
        XCTAssertNotEqual(first.session, second.session)
    }

    func testConcurrentEventsAndExportProduceConsistentSnapshots() throws {
        let store = DiagnosticLogStore(directory: root.appendingPathComponent("journal"))
        DispatchQueue.concurrentPerform(iterations: 100) { index in store.record(event(store, count: index)) }
        let destination = root.appendingPathComponent("export")
        let copied = try store.snapshot(to: destination)
        XCTAssertEqual(copied, ["events.jsonl"])
        let contents = try String(contentsOf: destination.appendingPathComponent("events.jsonl"))
        XCTAssertEqual(contents.split(separator: "\n").count, 100)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("events.jsonl").path)
        XCTAssertEqual((attributes[.posixPermissions] as! NSNumber).intValue, 0o600)
    }

    func testIOFailureIsVisibleWithoutCrashingCaller() throws {
        let file = root.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        let store = DiagnosticLogStore(directory: file)
        store.record(event(store, count: 1)); store.flush()
        XCTAssertNotNil(store.lastError)
    }
}
