import XCTest
@testable import SodutoReliability

final class DiagnosticBundleExporterTests: XCTestCase {
    func testExportCreatesReadableZIPWithSummaryAndPersistedEvents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticLogStore(directory: root.appendingPathComponent("logs"))
        store.record(DiagnosticEvent(session: store.session, level: .info, event: "test.before_export"))
        let destination = root.appendingPathComponent("bundle.zip")
        let count = try DiagnosticBundleExporter.export(store: store, summary: ["session": store.session], to: destination)
        XCTAssertEqual(count, 1)
        let unzip = Process()
        let pipe = Pipe()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", destination.path, "Soduto-Diagnostics/summary.json"]
        unzip.standardOutput = pipe
        try unzip.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        let summary = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(summary["session"] as? String, store.session)
        XCTAssertEqual(summary["log_files"] as? [String], ["events.jsonl"])
        XCTAssertGreaterThan(try Data(contentsOf: destination).count, 100)
    }
}
