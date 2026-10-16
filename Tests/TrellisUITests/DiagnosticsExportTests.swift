import AppKit
import XCTest
import TrellisControl
import TrellisCore
@testable import TrellisUI

final class DiagnosticsExportTests: XCTestCase {
    @MainActor
    func testDiagnosticCancelCreatesNoExport() async throws {
        let h = try Harness()
        defer { h.model.terminals.values.forEach { $0.adapter.detach() }; h.discardPreferences() }
        await h.model.createWindow(name: "SECRET-WINDOW", startSession: false)
        h.model.errorMessage = "Something failed for /Users/someone/private"
        let exporter = DiagnosticsExporter(model: h.model, hosts: h.hosts, grants: nil) { false }
        var presented: [String] = [], writes = 0
        let cancelled = await exporter.export(
            present: {
                presented.append($0); return nil
            }, write: { _, _ in writes += 1 })
        XCTAssertFalse(cancelled)
        XCTAssertEqual(writes, 0, "Cancel creates no export")
        XCTAssertEqual(presented.count, 1, "The user saw the exact preview first")

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: destination) }
        var written = Data()
        let saved = await exporter.export(
            present: { _ in destination },
            write: { data, _ in
                written = data; writes += 1
            })
        XCTAssertTrue(saved)
        XCTAssertEqual(writes, 1)
        let text = String(decoding: written, as: UTF8.self)
        XCTAssertEqual(text, presented[0], "What is saved is exactly what was previewed")
        XCTAssertFalse(text.contains("SECRET-WINDOW"))
        XCTAssertFalse(text.contains("/Users/someone"))
        XCTAssertTrue(text.contains("UI_ERROR"))
    }
}
