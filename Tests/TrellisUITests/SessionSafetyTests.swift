import AppKit
import XCTest
import TrellisCore
@testable import TrellisUI

final class SessionSafetyTests: XCTestCase {
    @MainActor
    func testInteractiveShellCloseAsksForConfirmationOnlyOnce() async throws {
        _ = NSApplication.shared
        let seed = try WorkspaceStore()
        var state = try await seed.execute(.createWindow(name: "Interactive shell")).snapshot
        let source = try XCTUnwrap(state.panes.values.first)
        state.sessions[source.sessionID]?.launch = .process(
            executable: "/bin/zsh", arguments: ["-f", "-i", "-c", "printf 'READY\\n'; read -r line"], directory: "/tmp")
        let model = AppWorkspaceModel(store: try WorkspaceStore(snapshot: state))
        await model.refresh()
        await model.createTab(duplicate: try XCTUnwrap(state.tabs.keys.first))
        let terminal = try XCTUnwrap(model.activeTerminal)
        defer { terminal.requestTermination(force: true) }
        let pane = try XCTUnwrap(model.presentation.activePane)
        let deadline = Date().addingTimeInterval(5)
        while !(try terminal.adapter.read(.retainedText).contains("READY")), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(try terminal.adapter.read(.retainedText).contains("READY"))
        var closePrompts = 0, forcePrompts = 0
        model.confirmCloseSessions = { _ in
            closePrompts += 1; return true
        }
        model.confirmForceSessions = { _ in
            forcePrompts += 1; return false
        }
        await model.closePane(pane.id)
        XCTAssertEqual(closePrompts, 1)
        XCTAssertEqual(forcePrompts, 0)
        XCTAssertFalse(terminal.isRunning)
        XCTAssertNil(model.snapshot.panes[pane.id])
    }

    @MainActor
    func testRestartRetainsExitedOutputUntilExplicitReplacement() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        await model.createWindow(fixture: true)
        let deadline = Date().addingTimeInterval(5)
        while model.activeTerminal?.isRunning == true, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        await model.waitForUpdates()
        let pane = try XCTUnwrap(model.presentation.activePane)
        let old = try XCTUnwrap(model.activeTerminal)
        XCTAssertEqual(old.exitCode, 7)
        XCTAssertTrue(try old.adapter.read(.retainedText).contains("Fixture complete"))
        await model.restartPane(pane.id, startSession: false)
        let new = try XCTUnwrap(model.activeTerminal)
        XCTAssertFalse(old === new)
        XCTAssertTrue(old.adapter.isDetached)
        XCTAssertEqual(new.sessionState, .stopped)
        XCTAssertNotEqual(model.presentation.activePane?.sessionID, pane.sessionID)
        XCTAssertTrue(try new.adapter.read(.retainedText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testCancelledQuitLeavesExistingSessionAndStructureUntouched() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        await model.createWindow(fixture: true)
        let before = model.snapshot
        model.confirmCloseSessions = { _ in false }
        XCTAssertFalse(model.confirmAllSessionClosure())
        // The cancelled action restores creation; its existing sessions are untouched.
        XCTAssertEqual(model.snapshot, before)
        while model.activeTerminal?.isRunning == true { try await Task.sleep(for: .milliseconds(10)) }
        await model.waitForUpdates()
        XCTAssertEqual(model.activeTerminal?.exitCode, 7)
    }

    @MainActor
    func testForceDeclineKeepsStructureAndDoesNotSilentlyKill() async throws {
        _ = NSApplication.shared
        let seed = try WorkspaceStore()
        var state = try await seed.execute(.createWindow(name: "Controlled")).snapshot
        let source = try XCTUnwrap(state.panes.values.first)
        state.sessions[source.sessionID]?.launch = .process(executable: "/bin/zsh", arguments: ["-f", "-c", "trap '' HUP TERM; printf 'READY\\n'; while :; do sleep 1; done"], directory: "/tmp")
        let model = AppWorkspaceModel(store: try WorkspaceStore(snapshot: state))
        await model.refresh()
        await model.createTab(duplicate: try XCTUnwrap(state.tabs.keys.first))
        let terminal = try XCTUnwrap(model.activeTerminal)
        let pane = try XCTUnwrap(model.presentation.activePane)
        let deadline = Date().addingTimeInterval(5)
        while !(try terminal.adapter.read(.retainedText).contains("READY")), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        await model.waitForUpdates()
        model.confirmCloseSessions = { _ in true }
        var forcePrompts = 0
        model.confirmForceSessions = { count in
            forcePrompts += 1; XCTAssertEqual(count, 1); return false
        }
        await model.closePane(pane.id)
        XCTAssertEqual(forcePrompts, 1)
        XCTAssertTrue(terminal.isRunning)
        XCTAssertNotNil(model.snapshot.panes[pane.id])
        XCTAssertEqual(model.snapshot.sessions[pane.sessionID]?.state, .closing)
        model.confirmForceSessions = { _ in true }
        await model.closePane(pane.id)
        XCTAssertFalse(terminal.isRunning)
        XCTAssertNil(model.snapshot.panes[pane.id])
        XCTAssertNil(model.errorMessage)
    }
}
