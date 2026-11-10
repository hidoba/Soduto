import XCTest
@testable import SodutoReliability

final class JournalRecoveryTests: XCTestCase {
    func testCrashTruncatedRecordDoesNotCorruptNextSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("events.jsonl")
        try Data("{\"event\":\"complete\"}\n{\"event\":\"partial".utf8).write(to: file)
        let store = DiagnosticLogStore(directory: directory)
        store.record(DiagnosticEvent(session: store.session, level: .info, event: "after.restart"))
        store.flush()
        let lines = try String(contentsOf: file).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        for line in lines { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8))) }
        XCTAssertTrue(lines[1].contains("after.restart"))
    }
}
