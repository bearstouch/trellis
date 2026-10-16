import AppKit
import XCTest
import TrellisCore
@testable import TrellisUI

final class TabManagementTests: XCTestCase {
    @MainActor
    func testS006_UT01_renameCommitsWithoutRestart() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true } // Explicit cleanup authorization for owned test processes.
        await model.createWindow()
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        let pane = try XCTUnwrap(model.presentation.activePane)
        let terminal = try XCTUnwrap(model.activeTerminal)
        let pid = terminal.processID
        let session = model.snapshot.sessions[pane.sessionID]
        await model.finishTabRename(tab.id, draft: "  Build Server  ", action: .commit)
        XCTAssertEqual(model.presentation.selectedTab?.title, "Build Server")
        XCTAssertEqual(model.presentation.activePane?.id, pane.id)
        XCTAssertTrue(model.activeTerminal === terminal)
        XCTAssertEqual(terminal.processID, pid)
        XCTAssertEqual(model.snapshot.sessions[pane.sessionID], session)
        await model.shutdown()
    }

    @MainActor
    func testS006_UT02_cancelAndEmptyRenamePreserveTitle() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true } // Explicit cleanup authorization for owned test processes.
        await model.createWindow(startSession: false)
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        let original = model.snapshot
        await model.finishTabRename(tab.id, draft: "Discard me", action: .cancel)
        XCTAssertEqual(model.snapshot, original)
        await model.finishTabRename(tab.id, draft: " \n\t ", action: .commit)
        XCTAssertEqual(model.snapshot, original)
        await model.finishTabRename(tab.id, draft: tab.title, action: .commit)
        XCTAssertEqual(model.snapshot, original)
    }

    func testS006_UT03_duplicateRemapsHierarchy() async throws {
        let initial = try await Self.splitFixture()
        let tab = try XCTUnwrap(initial.tabs.values.first)
        let store = try WorkspaceStore(snapshot: initial)
        let result = try await store.execute(.duplicateTab(id: tab.id))
        let clone = try XCTUnwrap(result.snapshot.tabs[try XCTUnwrap(result.createdTabID)])
        let originalIDs = allIDs(initial)
        var cloneIDs = Set(clone.root.paneIDs)
        cloneIDs.insert(clone.id)
        func compare(_ old: PaneLayout, _ new: PaneLayout) throws {
            switch (old, new) {
            case (.pane(let a), .pane(let b)):
                let oldPane = try XCTUnwrap(initial.panes[a])
                let newPane = try XCTUnwrap(result.snapshot.panes[b])
                cloneIDs.insert(newPane.sessionID)
                XCTAssertEqual(newPane.profileID, oldPane.profileID)
                let session = try XCTUnwrap(result.snapshot.sessions[newPane.sessionID])
                XCTAssertEqual(session.launch, initial.sessions[oldPane.sessionID]?.launch)
                XCTAssertEqual(session.state, .stopped)
                XCTAssertNil(session.processID)
                XCTAssertNil(session.startedAt)
                XCTAssertNil(session.exitCode)
            case (.split(_, let axis, let ratio, let children), .split(let id, let newAxis, let newRatio, let newChildren)):
                cloneIDs.insert(id)
                XCTAssertEqual(axis, newAxis); XCTAssertEqual(ratio, newRatio)
                XCTAssertEqual(children.count, newChildren.count)
                for (a, b) in zip(children, newChildren) { try compare(a, b) }
            default: XCTFail("Tree shape changed")
            }
        }
        try compare(tab.root, clone.root)
        XCTAssertTrue(cloneIDs.isDisjoint(with: originalIDs))
        XCTAssertEqual(cloneIDs.count, 9) // tab + 2 branches + 3 panes + 3 sessions
        XCTAssertEqual(clone.activePaneID, clone.root.paneIDs.last)
        try result.snapshot.validate()
    }

    func testS006_UT04_tabOrderIsWindowLocal() async throws {
        let store = try WorkspaceStore()
        let first = try await store.execute(.createWindow(name: "A"))
        let a = try XCTUnwrap(first.createdWindowID)
        _ = try await store.execute(.createTab(windowID: a))
        let second = try await store.execute(.createWindow(name: "B"))
        let b = try XCTUnwrap(second.createdWindowID)
        let original = try await store.execute(.createTab(windowID: b)).snapshot
        let aTabs = try XCTUnwrap(original.windows.first(where: { $0.id == a })?.tabIDs)
        let after = try await store.execute(.reorderTabs(windowID: a, ids: aTabs.reversed())).snapshot
        XCTAssertEqual(after.windows.first(where: { $0.id == b }), original.windows.first(where: { $0.id == b }))
        XCTAssertEqual(after.activeWindowID, b)
        XCTAssertEqual(after.tabs, original.tabs)
        for invalid in [[aTabs[0]], [aTabs[0], aTabs[0]], [aTabs[0], UUID()]] {
            do { _ = try await store.execute(.reorderTabs(windowID: a, ids: invalid)); XCTFail("Invalid permutation accepted") } catch {}
            let unchanged = await store.snapshot()
            XCTAssertEqual(unchanged, after)
        }
    }

    @MainActor
    func testDuplicateStartsFreshProcessesWithConfiguredLaunchAndEmptyBuffers() async throws {
        _ = NSApplication.shared
        let initial = try await Self.splitFixture()
        let tab = try XCTUnwrap(initial.tabs.values.first)
        let model = AppWorkspaceModel(store: try WorkspaceStore(snapshot: initial))
        model.confirmForceSessions = { _ in true } // Explicit cleanup authorization for owned test processes.
        await model.refresh()
        await model.createTab(duplicate: tab.id, startSessions: false)
        let clone = try XCTUnwrap(model.presentation.selectedTab)
        XCTAssertNotEqual(clone.id, tab.id)
        for id in clone.root.paneIDs {
            let terminal = try XCTUnwrap(model.terminals[id])
            let output = try terminal.adapter.read(.retainedText)
            XCTAssertTrue(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            await model.start(paneID: id)
        }
        let deadline = Date().addingTimeInterval(5)
        while model.runningTerminals.count > 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        await model.waitForUpdates()
        for id in clone.root.paneIDs {
            let pane = try XCTUnwrap(model.snapshot.panes[id])
            XCTAssertEqual(model.snapshot.sessions[pane.sessionID]?.exitCode, 7)
            XCTAssertEqual(model.snapshot.sessions[pane.sessionID]?.state, .exited)
        }
        await model.shutdown()
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testClosingLastTabUsesConfirmationAndRemovesWindow() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true } // Explicit cleanup authorization for owned test processes.
        await model.createWindow()
        let tab = try XCTUnwrap(model.presentation.selectedTab)
        let terminal = try XCTUnwrap(model.activeTerminal)
        model.confirmCloseSessions = { _ in false }
        await model.closeTab(tab.id)
        XCTAssertTrue(terminal.isRunning)
        XCTAssertEqual(model.presentation.selectedTab?.id, tab.id)
        model.confirmCloseSessions = { _ in true }
        await model.closeTab(tab.id)
        XCTAssertFalse(terminal.isRunning)
        XCTAssertTrue(model.presentation.isEmpty)
        XCTAssertTrue(model.terminals.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testDuplicatePreservesAppliedShellAfterSettingsChange() async throws {
        _ = NSApplication.shared
        let suite = "trellis.s006.launch.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences)
        model.confirmForceSessions = { _ in true } // Explicit cleanup authorization for owned test processes.
        let saved = await model.saveLaunchSettings(shell: "/bin/zsh", directory: "/tmp")
        XCTAssertTrue(saved)
        await model.createWindow()
        await model.waitForUpdates()
        let original = try XCTUnwrap(model.presentation.selectedTab)
        let originalTerminal = try XCTUnwrap(model.activeTerminal)
        let originalPane = try XCTUnwrap(model.presentation.activePane)
        let applied = try XCTUnwrap(model.snapshot.sessions[originalPane.sessionID]?.launch)
        XCTAssertEqual(applied, .process(executable: "/bin/zsh", arguments: ["-l"], directory: "/tmp"))
        let changed = await model.saveLaunchSettings(shell: "/bin/bash", directory: "/")
        XCTAssertTrue(changed)
        await model.createTab(duplicate: original.id)
        await model.waitForUpdates()
        let clonePane = try XCTUnwrap(model.presentation.activePane)
        let cloneTerminal = try XCTUnwrap(model.activeTerminal)
        XCTAssertEqual(model.snapshot.sessions[clonePane.sessionID]?.launch, applied)
        XCTAssertTrue(originalTerminal.isRunning)
        XCTAssertTrue(cloneTerminal.isRunning)
        XCTAssertNotEqual(originalTerminal.processID, cloneTerminal.processID)
        await model.shutdown()
        XCTAssertNil(model.errorMessage)
    }

    private func allIDs(_ state: WorkspaceSnapshot) -> Set<UUID> {
        var ids = Set(state.windows.map(\.id) + Array(state.tabs.keys) + Array(state.panes.keys) + Array(state.sessions.keys))
        func visit(_ tree: PaneLayout) {
            if case .split(let id, _, _, let children) = tree { ids.insert(id); children.forEach(visit) }
        }
        state.tabs.values.forEach { visit($0.root) }
        return ids
    }

    private static func splitFixture() async throws -> WorkspaceSnapshot {
        let store = try WorkspaceStore()
        var state = try await store.execute(.createWindow(name: "Project")).snapshot
        let tabID = try XCTUnwrap(state.windows.first?.activeTabID)
        let a = try XCTUnwrap(state.tabs[tabID]?.activePaneID), b = UUID(), c = UUID()
        for id in [b, c] {
            let session = UUID()
            state.panes[id] = WorkspacePane(id: id, tabID: tabID, sessionID: session, profileID: "custom", title: "Worker")
            state.sessions[session] = WorkspaceSession(id: session)
        }
        for id in [a, b, c] {
            let sessionID = try XCTUnwrap(state.panes[id]?.sessionID)
            state.sessions[sessionID]?.launch = .process(executable: "/bin/zsh", arguments: ["-f", "-c", "printf 'fresh session\\n'; exit 7"], directory: "/tmp")
        }
        state.tabs[tabID]?.root = .split(id: UUID(), axis: .x, ratio: 0.3, children: [.pane(a),
            .split(id: UUID(), axis: .y, ratio: 0.6, children: [.pane(b), .pane(c)])])
        state.tabs[tabID]?.activePaneID = c
        try state.validate()
        return state
    }
}
