import AppKit
import XCTest
import TrellisCore
@testable import TrellisUI

/// FR-R06: past the hourly budget, ordinary saves are batched; ⌘S and Quit still save at once.
@MainActor final class WorkspaceWriteBudgetUITests: XCTestCase {
    private var directory: URL!
    private var suite: String!
    private var model: AppWorkspaceModel!
    private var persistence: WorkspacePersistence!
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private var delays: [TimeInterval] = []
    private var released = false

    override func setUp() async throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-write-budget-\(UUID())")
        suite = "trellis.tests.\(UUID())"
        persistence = WorkspacePersistence(directory: directory)
        model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: try XCTUnwrap(UserDefaults(suiteName: suite)), persistence: persistence)
        let fixed = now
        model.activityNow = { fixed }
        _ = await model.loadWorkspace()
        await model.createWindow(name: "Budget", startSession: false)
        _ = await model.flushWorkspaceSave()
        model.saveSleep = { [unowned self] delay in
            delays.append(delay)
            while !released, !Task.isCancelled { await Task.yield() }
            try Task.checkCancellation()
        }
    }

    override func tearDown() async throws {
        released = true
        try? FileManager.default.removeItem(at: directory)
        UserDefaults().removePersistentDomain(forName: suite)
        model = nil
    }

    private func savedText() throws -> String { try String(contentsOf: persistence.currentURL, encoding: .utf8) }

    private func waitFor(_ condition: () throws -> Bool) async rethrows {
        for _ in 0..<2000 where try !condition() { await Task.yield() }
    }

    func testSpentBudgetBatchesLaterChangesIntoOneSave() async throws {
        let window = try XCTUnwrap(model.snapshot.windows.first?.id)
        model.writeBudget.record(60_000_000, at: now)
        await model.renameWindow(window, name: "First change")
        await waitFor { !delays.isEmpty }
        await model.renameWindow(window, name: "Second change")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(delays, [WorkspaceWriteBudget.throttledInterval], "Both changes wait for one batched save")
        XCTAssertTrue(model.savesThrottled)
        XCTAssertFalse(try savedText().contains("Second change"))
        released = true
        try await waitFor { try savedText().contains("Second change") }
        XCTAssertTrue(try savedText().contains("Second change"))
    }

    func testWithinBudgetChangesSaveAfterTheShortDelay() async throws {
        let window = try XCTUnwrap(model.snapshot.windows.first?.id)
        released = true
        await model.renameWindow(window, name: "Quick")
        try await waitFor { try savedText().contains("Quick") }
        XCTAssertEqual(delays, [0.3])
        XCTAssertFalse(model.savesThrottled)
    }

    func testExplicitSaveIgnoresTheBudget() async throws {
        let window = try XCTUnwrap(model.snapshot.windows.first?.id)
        model.writeBudget.record(60_000_000, at: now)
        await model.renameWindow(window, name: "Saved now")
        let saved = await model.flushWorkspaceSave()
        XCTAssertTrue(saved)
        XCTAssertTrue(try savedText().contains("Saved now"))
    }

    func testBudgetSettingPersistsAndRejectsUnknownValues() async throws {
        model.setSaveBudget(megabytesPerHour: 7)
        XCTAssertEqual(model.saveBudgetMegabytesPerHour, WorkspaceWriteBudget.defaultMegabytesPerHour)
        model.setSaveBudget(megabytesPerHour: 250)
        _ = await model.flushWorkspaceSave()
        let restored = AppWorkspaceModel(
            store: try WorkspaceStore(), preferences: try XCTUnwrap(UserDefaults(suiteName: suite)), persistence: WorkspacePersistence(directory: directory))
        _ = await restored.loadWorkspace()
        XCTAssertEqual(restored.saveBudgetMegabytesPerHour, 250)
    }

    func testRaisingTheBudgetEndsBatching() async throws {
        let window = try XCTUnwrap(model.snapshot.windows.first?.id)
        model.setSaveBudget(megabytesPerHour: 10)
        model.writeBudget.record(20_000_000, at: now)
        await model.renameWindow(window, name: "Batched")
        await waitFor { !delays.isEmpty }
        XCTAssertTrue(model.savesThrottled)
        model.setSaveBudget(megabytesPerHour: 100)
        await waitFor { delays.count > 1 }
        XCTAssertEqual(delays.last, 0.3)
        XCTAssertFalse(model.savesThrottled)
        released = true
        try await waitFor { try savedText().contains("Batched") }
        XCTAssertTrue(try savedText().contains("Batched"))
    }
}
