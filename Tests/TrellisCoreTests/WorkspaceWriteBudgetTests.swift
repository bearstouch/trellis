import Foundation
import XCTest

@testable import TrellisCore

/// FR-R06: the workspace file is rewritten only when it changes, within an hourly write budget.
final class WorkspaceWriteBudgetTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testBudgetCountsOnlyTheLastHour() {
        var budget = WorkspaceWriteBudget(megabytesPerHour: 10)
        budget.record(6_000_000, at: start)
        budget.record(4_000_000, at: start.addingTimeInterval(1800))
        XCTAssertEqual(budget.written(at: start.addingTimeInterval(1800)), 10_000_000)
        XCTAssertTrue(budget.isExhausted(at: start.addingTimeInterval(1800)))
        // The first write leaves the window after an hour.
        XCTAssertEqual(budget.written(at: start.addingTimeInterval(3600)), 4_000_000)
        XCTAssertFalse(budget.isExhausted(at: start.addingTimeInterval(3600)))
    }

    func testUnknownBudgetFallsBackToTheDefault() {
        XCTAssertEqual(WorkspaceWriteBudget(megabytesPerHour: 7).megabytesPerHour, WorkspaceWriteBudget.defaultMegabytesPerHour)
        XCTAssertEqual(WorkspaceSettings(saveBudgetMegabytesPerHour: -1).saveBudgetMegabytesPerHour, WorkspaceWriteBudget.defaultMegabytesPerHour)
        XCTAssertEqual(WorkspaceSettings(saveBudgetMegabytesPerHour: 250).saveBudgetMegabytesPerHour, 250)
    }

    func testSettingsDecodeAMissingOrInvalidBudgetWithoutFailingTheWorkspace() throws {
        let encoded = try JSONEncoder().encode(WorkspaceSettings(shell: "/bin/zsh", directory: "/tmp", saveBudgetMegabytesPerHour: 100))
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceSettings.self, from: encoded).saveBudgetMegabytesPerHour, 100)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["saveBudgetMegabytesPerHour"] = "lots"
        let invalid = try JSONDecoder().decode(WorkspaceSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(invalid.saveBudgetMegabytesPerHour, WorkspaceWriteBudget.defaultMegabytesPerHour)
        object.removeValue(forKey: "saveBudgetMegabytesPerHour")
        let missing = try JSONDecoder().decode(WorkspaceSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(missing.saveBudgetMegabytesPerHour, WorkspaceWriteBudget.defaultMegabytesPerHour)
    }

    func testUnchangedWorkspaceIsNotRewritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-budget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WorkspacePersistence(directory: directory)
        guard case .missing = await persistence.load() else { return XCTFail("Expected an empty directory") }
        let store = try WorkspaceStore()
        _ = try await store.execute(.createWindow(name: "Budget"))
        let snapshot = await store.snapshot()
        let settings = WorkspaceSettings(shell: "/bin/zsh", directory: "/tmp")

        let first = try await persistence.save(snapshot, settings: settings, sequence: 1)
        let size = try Data(contentsOf: persistence.currentURL).count
        XCTAssertEqual(first, size, "A first save has no previous file to back up")
        let modified = try FileManager.default.attributesOfItem(atPath: persistence.currentURL.path)[.modificationDate] as? Date

        let unchanged = try await persistence.save(snapshot, settings: settings, sequence: 2)
        XCTAssertEqual(unchanged, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.backupURL.path), "Nothing was rewritten, so no backup was made")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: persistence.currentURL.path)[.modificationDate] as? Date, modified)

        var changed = settings; changed.saveBudgetMegabytesPerHour = 10
        let next = try await persistence.save(snapshot, settings: changed, sequence: 3)
        XCTAssertEqual(next, size + (try Data(contentsOf: persistence.currentURL).count), "A real change writes the backup and the new file")
        XCTAssertEqual(try Data(contentsOf: persistence.backupURL).count, size)
    }

    func testUnchangedWorkspaceDeletedMeanwhileIsWrittenAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-budget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WorkspacePersistence(directory: directory)
        _ = await persistence.load()
        let store = try WorkspaceStore()
        _ = try await store.execute(.createWindow(name: "Budget"))
        let snapshot = await store.snapshot()
        let settings = WorkspaceSettings(shell: "/bin/zsh", directory: "/tmp")
        let size = try await persistence.save(snapshot, settings: settings, sequence: 1)
        try FileManager.default.removeItem(at: persistence.currentURL)
        let written = try await persistence.save(snapshot, settings: settings, sequence: 2)
        XCTAssertEqual(written, size, "Quit must never leave a deleted workspace unsaved")
        XCTAssertNotNil(try WorkspaceSnapshotCodec.decode(Data(contentsOf: persistence.currentURL)))
    }

    func testLoadedWorkspaceIsNotRewrittenUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-budget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = WorkspacePersistence(directory: directory)
        _ = await first.load()
        let store = try WorkspaceStore()
        _ = try await store.execute(.createWindow(name: "Budget"))
        try await first.save(await store.snapshot(), settings: WorkspaceSettings(shell: "/bin/zsh", directory: "/tmp"), sequence: 1)

        let second = WorkspacePersistence(directory: directory)
        guard case .loaded(let restored) = await second.load() else { return XCTFail("Expected the saved workspace") }
        let written = try await second.save(restored.snapshot, settings: restored.settings, sequence: 1)
        XCTAssertEqual(written, 0)
    }
}
