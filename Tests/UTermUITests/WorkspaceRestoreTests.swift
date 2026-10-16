import AppKit
import XCTest
import UTermCore
@testable import UTermUI

final class WorkspaceRestoreTests: XCTestCase {
    @MainActor
    func testRestoreBuildsStoppedNativeViewsAndOmitsRenderedOutput() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uterm-restore-\(UUID())")
        let suite = "uterm.tests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); preferences.removePersistentDomain(forName: suite) }
        let persistence = WorkspacePersistence(directory: directory)
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: persistence)
        let exists = await model.loadWorkspace()
        XCTAssertFalse(exists)
        await model.createWindow(name: "Saved Project", startSession: false)
        let first = try XCTUnwrap(model.presentation.activePane?.id)
        await model.splitPane(first, axis: .x, startSession: false)
        let marker = "PRIVATE_RENDERED_OUTPUT_\(UUID())"
        model.activeTerminal?.adapter.receive(Data(marker.utf8))
        let before = model.snapshot
        let saved = await model.flushWorkspaceSave()
        XCTAssertTrue(saved)
        XCTAssertFalse(try String(contentsOf: persistence.currentURL, encoding: .utf8).contains(marker))
        let restored = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: directory))
        let didRestore = await restored.loadWorkspace()
        XCTAssertTrue(didRestore)
        XCTAssertEqual(restored.snapshot.windows, before.windows)
        XCTAssertEqual(restored.snapshot.tabs, before.tabs)
        XCTAssertEqual(restored.snapshot.panes, before.panes)
        XCTAssertEqual(restored.terminals.count, 2)
        for terminal in restored.terminals.values {
            XCTAssertFalse(terminal.isRunning)
            XCTAssertNil(terminal.processID)
            XCTAssertEqual(terminal.sessionState, .stopped)
            XCTAssertTrue(try terminal.adapter.read(.retainedText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @MainActor
    func testFutureVersionEmptyRecoveryIsTemporaryAndPreservesBytes() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uterm-future-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "uterm.tests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); preferences.removePersistentDomain(forName: suite) }
        let persistence = WorkspacePersistence(directory: directory)
        let original = Data("{\"schemaVersion\":999}".utf8)
        try original.write(to: persistence.currentURL)
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: persistence)
        let didLoad = await model.loadWorkspace()
        XCTAssertTrue(didLoad)
        XCTAssertNotNil(model.recoveryMessage)
        await model.recoverWorkspace(useBackup: false)
        XCTAssertTrue(model.persistenceReadOnly)
        await model.createWindow(startSession: false)
        let saved = await model.flushWorkspaceSave()
        XCTAssertTrue(saved)
        XCTAssertEqual(try Data(contentsOf: persistence.currentURL), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["workspace.json"])
    }

    @MainActor
    func testCancelledStartupStillPreservesStoppedWorkspaceBeforeShutdownSave() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uterm-cancelled-restore-\(UUID())")
        let suite = "uterm.tests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); preferences.removePersistentDomain(forName: suite) }
        let persistence = WorkspacePersistence(directory: directory)
        _ = await persistence.load()
        let store = try WorkspaceStore()
        let saved = try await store.execute(.createWindow(name: "Do not lose me")).snapshot
        try await persistence.save(saved, settings: WorkspaceSettings(), sequence: 1)
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: persistence)
        let restore = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await model.loadWorkspace()
        }
        let didRestore = await restore.value
        XCTAssertTrue(didRestore)
        XCTAssertEqual(model.snapshot.windows, saved.windows)
        let flushed = await model.flushWorkspaceSave()
        XCTAssertTrue(flushed)
        XCTAssertEqual(try WorkspaceSnapshotCodec.decode(Data(contentsOf: persistence.currentURL)).snapshot.windows, saved.windows)
    }

    @MainActor
    func testWindowFrameChangesAreDebouncedAndRestoredIntoPreferences() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uterm-geometry-\(UUID())")
        let suite = "uterm.tests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); preferences.removePersistentDomain(forName: suite) }
        let persistence = WorkspacePersistence(directory: directory)
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: persistence)
        _ = await model.loadWorkspace()
        let frame = "{{80, 100}, {980, 650}}"
        model.updateWindowFrame(frame)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !FileManager.default.fileExists(atPath: persistence.currentURL.path), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try WorkspaceSnapshotCodec.decode(Data(contentsOf: persistence.currentURL)).settings.windowFrame, frame)
        preferences.set("stale frame", forKey: "app.windowFrame")
        let restored = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: persistence)
        var appliedFrame: String?
        restored.onRestoreWindowFrame = { appliedFrame = $0 }
        _ = await restored.loadWorkspace()
        XCTAssertEqual(preferences.string(forKey: "app.windowFrame"), frame)
        XCTAssertEqual(appliedFrame, frame)
    }

    @MainActor
    func testCancelledQuitAfterSaveFailureAllowsWorkspaceCommands() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        await model.createWindow(startSession: false)
        XCTAssertEqual(model.snapshot.windows.count, 1)
        let closed = await model.shutdown()
        XCTAssertTrue(closed)
        model.cancelShutdown()
        await model.createWindow(startSession: false)
        XCTAssertEqual(model.snapshot.windows.count, 2)
    }

}
