import AppKit
import XCTest
import TrellisCore
@testable import TrellisUI

/// FR-R04/FR-R05: the opt-in, redacted scrollback file.
final class ScrollbackRestoreTests: XCTestCase {
    private var directory: URL!
    private var suites: [String] = []

    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-scrollback-ui-\(UUID())") }
    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
    }

    @MainActor
    private func makeModel() throws -> AppWorkspaceModel {
        _ = NSApplication.shared
        let suite = "trellis.tests.\(UUID())"
        suites.append(suite)
        return AppWorkspaceModel(store: try WorkspaceStore(), preferences: try XCTUnwrap(UserDefaults(suiteName: suite)), persistence: WorkspacePersistence(directory: directory))
    }

    private var scrollbackDirectory: URL { directory.appendingPathComponent("Scrollback") }
    private func files() -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: scrollbackDirectory.path)) ?? []) }

    @MainActor
    func testQuitSavesRedactedTextThatReturnsInTheStoppedPane() async throws {
        let model = try makeModel()
        _ = await model.loadWorkspace()
        model.setRestoreScrollback(true)
        await model.createWindow(startSession: false)
        let pane = try XCTUnwrap(model.presentation.activePane)
        model.terminals[pane.id]?.adapter.receive(Data("build finished\r\necho GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789\r\n".utf8))
        await model.saveScrollback()
        _ = await model.flushWorkspaceSave()
        XCTAssertEqual(files(), ["\(pane.sessionID.uuidString).txt"])
        let saved = try String(contentsOf: scrollbackDirectory.appendingPathComponent("\(pane.sessionID.uuidString).txt"), encoding: .utf8)
        XCTAssertFalse(saved.contains("ghp_"))
        XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("workspace.json"), encoding: .utf8).contains("build finished"), "Output never enters workspace.json")

        let restored = try makeModel()
        _ = await restored.loadWorkspace()
        XCTAssertTrue(restored.restoreScrollback)
        let terminal = try XCTUnwrap(restored.terminals[pane.id])
        XCTAssertEqual(terminal.sessionState, .stopped, "Restoring text never starts anything")
        XCTAssertTrue(terminal.retainedText.contains("build finished"))
        XCTAssertTrue(terminal.retainedText.contains("— Restored output from"))
        XCTAssertFalse(terminal.retainedText.contains("ghp_"))
        XCTAssertFalse(restored.outputJournal.contains(session: pane.sessionID), "Restored text is not journaled")
    }

    @MainActor
    func testFilesGoWhenPanesCloseOrTheSettingIsTurnedOff() async throws {
        let model = try makeModel()
        _ = await model.loadWorkspace()
        model.setRestoreScrollback(true)
        await model.createWindow(startSession: false)
        let first = try XCTUnwrap(model.presentation.activePane)
        let secondID = await model.splitPane(first.id, axis: .x, startSession: false)
        let second = try XCTUnwrap(secondID.flatMap { model.snapshot.panes[$0] })
        for pane in [first, second] { model.terminals[pane.id]?.adapter.receive(Data("text of \(pane.id)\r\n".utf8)) }
        await model.saveScrollback()
        XCTAssertEqual(files().count, 2)
        await model.closePane(second.id)
        let deadline = Date().addingTimeInterval(2)
        while files().count != 1, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(files(), ["\(first.sessionID.uuidString).txt"], "Closing a pane deletes its saved text")
        model.setRestoreScrollback(false)
        while FileManager.default.fileExists(atPath: scrollbackDirectory.path), Date() < deadline + 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scrollbackDirectory.path), "Turning the setting off deletes everything")
    }

    @MainActor
    func testOffByDefaultWritesNothingAndStaleFilesAreDropped() async throws {
        let model = try makeModel()
        _ = await model.loadWorkspace()
        XCTAssertFalse(model.restoreScrollback)
        await model.createWindow(startSession: false)
        model.activeTerminal?.adapter.receive(Data("private\r\n".utf8))
        await model.saveScrollback()
        _ = await model.flushWorkspaceSave()
        XCTAssertFalse(FileManager.default.fileExists(atPath: scrollbackDirectory.path))

        // A file for a session that isn't in the saved workspace is deleted at the next launch.
        model.setRestoreScrollback(true)
        _ = await model.flushWorkspaceSave()
        try FileManager.default.createDirectory(at: scrollbackDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("orphan".utf8).write(to: scrollbackDirectory.appendingPathComponent("\(UUID().uuidString).txt"))
        let restored = try makeModel()
        _ = await restored.loadWorkspace()
        XCTAssertEqual(files(), [])
    }
}
