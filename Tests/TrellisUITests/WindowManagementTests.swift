import AppKit
import XCTest
import TrellisCore
@testable import TrellisUI

final class WindowManagementTests: XCTestCase {
    func testCreateInitialHierarchy() async throws {
        let store = try WorkspaceStore()
        let result = try await store.execute(.createWindow(name: "Project"))
        let state = result.snapshot
        XCTAssertEqual(state.windows.count, 1)
        XCTAssertEqual(state.tabs.count, 1)
        XCTAssertEqual(state.panes.count, 1)
        XCTAssertEqual(state.sessions.count, 1)
        let ids = state.windows.map(\.id) + Array(state.tabs.keys) + Array(state.panes.keys) + Array(state.sessions.keys)
        XCTAssertEqual(Set(ids).count, 4)
        try state.validate()
    }

    func testSwitchRestoresSelection() async throws {
        let store = try WorkspaceStore()
        let first = try await store.execute(.createWindow(name: "One"))
        let second = try await store.execute(.createWindow(name: "Two"))
        let firstID = try XCTUnwrap(first.createdWindowID)
        let secondID = try XCTUnwrap(second.createdWindowID)
        var initial = second.snapshot
        // Both windows keep a non-default active tab and pane. Include live
        // session ownership so selection cannot silently reconstruct sessions.
        for index in initial.windows.indices {
            let windowID = initial.windows[index].id
            let tabID = UUID(), paneA = UUID(), paneB = UUID(), sessionA = UUID(), sessionB = UUID()
            initial.windows[index].tabIDs.append(tabID)
            initial.windows[index].activeTabID = tabID
            initial.tabs[tabID] = WorkspaceTab(
                id: tabID, windowID: windowID, title: "Split",
                root: .split(id: UUID(), axis: .x, ratio: 0.5, children: [.pane(paneA), .pane(paneB)]), activePaneID: paneB)
            initial.panes[paneA] = WorkspacePane(id: paneA, tabID: tabID, sessionID: sessionA)
            initial.panes[paneB] = WorkspacePane(id: paneB, tabID: tabID, sessionID: sessionB)
            initial.sessions[sessionA] = WorkspaceSession(id: sessionA)
            var live = WorkspaceSession(id: sessionB)
            live.state = .running
            live.processID = Int32(5000 + index)  // Value-only domain fixture; no native process.
            initial.sessions[sessionB] = live
        }
        let restoredStore = try WorkspaceStore(snapshot: initial)
        _ = try await restoredStore.execute(.selectWindow(id: firstID))
        _ = try await restoredStore.execute(.selectWindow(id: secondID))
        let back = try await restoredStore.execute(.selectWindow(id: firstID)).snapshot
        XCTAssertEqual(back.windows, initial.windows)
        XCTAssertEqual(back.tabs, initial.tabs)
        XCTAssertEqual(back.panes, initial.panes)
        XCTAssertEqual(back.sessions, initial.sessions)
        let expectedTab = try XCTUnwrap(initial.tabs[initial.windows[0].activeTabID])
        XCTAssertEqual(WorkspacePresentation(snapshot: back).selectedTab?.id, expectedTab.id)
        XCTAssertEqual(WorkspacePresentation(snapshot: back).activePane?.id, expectedTab.activePaneID)
    }

    func testReorderIsPermutation() async throws {
        let store = try WorkspaceStore()
        _ = try await store.execute(.createWindow(name: "One"))
        let before = try await store.execute(.createWindow(name: "Two")).snapshot
        let ids = before.windows.map(\.id)
        for invalid in [[ids[0]], [ids[0], ids[0]], [ids[0], UUID()]] {
            do { _ = try await store.execute(.reorderWindows(ids: invalid)); XCTFail("Accepted invalid order") } catch {}
            let unchanged = await store.snapshot()
            XCTAssertEqual(unchanged, before)
        }
        let after = try await store.execute(.reorderWindows(ids: ids.reversed())).snapshot
        XCTAssertEqual(after.windows.map(\.id), ids.reversed())
        XCTAssertEqual(after.activeWindowID, before.activeWindowID)
    }

    @MainActor
    func testInactiveOutputDoesNotSelect() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createWindow(name: "One", startSession: false)
        let first = try XCTUnwrap(model.snapshot.activeWindowID)
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        let terminal = model.activeTerminal
        await model.createWindow(name: "Two", startSession: false)
        let active = model.snapshot.activeWindowID
        for _ in 0..<10_000 { model.recordActivity(paneID: pane) }
        model.recordActivity(paneID: pane, exited: true)
        XCTAssertEqual(model.snapshot.activeWindowID, active)
        XCTAssertEqual(model.activity.count, 1)
        XCTAssertEqual(model.activity[first]?.hasOutput, true)
        XCTAssertEqual(model.activity[first]?.hasExit, true)
        await model.selectWindow(first)
        XCTAssertNil(model.activity[first])
        XCTAssertTrue(model.activeTerminal === terminal)
    }

    @MainActor
    func testDeletingSelectedWindowClearsFallbackActivity() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createWindow(name: "One", startSession: false)
        let first = try XCTUnwrap(model.snapshot.activeWindowID)
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        await model.createWindow(name: "Two", startSession: false)
        let second = try XCTUnwrap(model.snapshot.activeWindowID)
        model.recordActivity(paneID: pane, exited: true)
        XCTAssertEqual(model.activity[first]?.hasExit, true)
        await model.deleteWindow(second)
        XCTAssertEqual(model.snapshot.activeWindowID, first)
        XCTAssertNil(model.activity[first])
    }

    @MainActor
    func testOlderCommandReplyCannotRestoreDeletedWindow() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createWindow(startSession: false)
        let old = model.snapshot
        await model.deleteWindow(try XCTUnwrap(old.activeWindowID))
        let deleted = model.snapshot
        model.publish(old)
        XCTAssertEqual(model.snapshot, deleted)
        XCTAssertTrue(model.presentation.isEmpty)
    }

    func testDeletionRejectsLiveSessionsAtomically() async throws {
        let store = try WorkspaceStore()
        let created = try await store.execute(.createWindow(name: "One"))
        let paneID = try XCTUnwrap(created.snapshot.panes.keys.first)
        let launched = try await store.execute(.startSession(paneID: paneID))
        do { _ = try await store.execute(.deleteWindow(id: try XCTUnwrap(created.createdWindowID))); XCTFail("Deleted starting process") } catch {}
        let unchanged = await store.snapshot()
        XCTAssertEqual(unchanged, launched.snapshot)
    }

    @MainActor
    func testDeleteLastStoppedWindowReachesEmptyState() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createWindow(startSession: false)
        let id = try XCTUnwrap(model.snapshot.activeWindowID)
        await model.deleteWindow(id)
        XCTAssertTrue(model.presentation.isEmpty)
        XCTAssertTrue(model.terminals.isEmpty)
        XCTAssertTrue(model.snapshot.sessions.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testLiveDeletionCanBeCancelledThenConfirmed() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createWindow()
        let id = try XCTUnwrap(model.snapshot.activeWindowID)
        let terminal = try XCTUnwrap(model.activeTerminal)
        defer { terminal.stop() }
        model.confirmCloseSessions = { count in
            XCTAssertEqual(count, 1); return false
        }
        await model.deleteWindow(id)
        XCTAssertTrue(terminal.isRunning)
        XCTAssertEqual(model.snapshot.windows.count, 1)
        await model.createWindow(name: "Unaffected")
        let otherID = try XCTUnwrap(model.snapshot.activeWindowID)
        let other = try XCTUnwrap(model.activeTerminal)
        defer { other.stop() }
        let otherPID = other.processID
        let otherSession = model.presentation.activePane?.sessionID
        model.confirmCloseSessions = { count in
            XCTAssertEqual(count, 1); return true
        }
        await model.deleteWindow(id)
        XCTAssertFalse(terminal.isRunning)
        XCTAssertEqual(model.snapshot.windows.map(\.id), [otherID])
        XCTAssertEqual(model.snapshot.activeWindowID, otherID)
        XCTAssertTrue(other.isRunning)
        XCTAssertEqual(other.processID, otherPID)
        XCTAssertEqual(model.presentation.activePane?.sessionID, otherSession)
        XCTAssertNil(model.errorMessage)
        await model.shutdown()
        XCTAssertFalse(other.isRunning)
    }

    @MainActor
    func testSidebarCollapseIsRememberedAcrossLaunches() throws {
        let suite = "trellis.tests.sidebar.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences)
        XCTAssertFalse(model.sidebarCollapsed)
        model.toggleSidebar()
        XCTAssertTrue(model.sidebarCollapsed)
        XCTAssertTrue(AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences).sidebarCollapsed)
        model.toggleSidebar()
        XCTAssertFalse(AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences).sidebarCollapsed)
    }

    @MainActor
    func testTabPreviewsListInactiveWindowTabsInOrderWithActiveTab() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        let firstResult = await model.createWindow(name: "One", startSession: false)
        let first = try XCTUnwrap(firstResult)
        let firstTab = try XCTUnwrap(model.presentation.selectedTab?.id)
        let secondResult = await model.createTab(windowID: first, startSessions: false)
        let second = try XCTUnwrap(secondResult)
        let thirdResult = await model.createTab(windowID: first, startSessions: false)
        let third = try XCTUnwrap(thirdResult)
        let splitFrom = try XCTUnwrap(model.presentation.activePane?.id)
        _ = await model.splitPane(splitFrom, axis: .x, startSession: false)
        await model.selectTab(second)
        _ = await model.createWindow(name: "Two", startSession: false)
        XCTAssertNotEqual(model.snapshot.activeWindowID, first)
        let previews = model.tabPreviews(windowID: first)
        XCTAssertEqual(previews.map(\.id), [firstTab, second, third])
        XCTAssertEqual(previews.map(\.isActive), [false, true, false])
        XCTAssertEqual(previews.map(\.paneCount), [1, 1, 2])
        XCTAssertTrue(previews.allSatisfy { !$0.isBusy && $0.inputWait == nil && $0.failedCommandExit == nil && !$0.hasExitedSession })
    }

    @MainActor
    func testTabPreviewsReflectRenameColorAndInputWait() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        let windowResult = await model.createWindow(name: "One", startSession: false)
        let window = try XCTUnwrap(windowResult)
        let tab = try XCTUnwrap(model.presentation.selectedTab?.id)
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        await model.renameTab(tab, title: "api-server")
        await model.setTabColor(tab, color: .green)
        model.terminals[pane]?.onPasswordPromptChanged?(true)
        let preview = try XCTUnwrap(model.tabPreviews(windowID: window).first)
        XCTAssertEqual(preview.title, "api-server")
        XCTAssertEqual(preview.color, .green)
        XCTAssertEqual(preview.inputWait, .password)
    }

    @MainActor
    func testTabPreviewsMarkOnlyTheTabWhoseCommandFailed() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        let windowResult = await model.createWindow(name: "One", startSession: false)
        let window = try XCTUnwrap(windowResult)
        let tabResult = await model.createTab(windowID: window, startSessions: false)
        let failing = try XCTUnwrap(tabResult)
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        let terminal = try XCTUnwrap(model.terminals[pane])
        for event: ShellIntegrationEvent in [.promptStart(directory: "/tmp"), .commandStart(commandLine: "false"), .commandFinished(exitCode: 2)] {
            terminal.onShellIntegrationEvent?(event)
        }
        let previews = model.tabPreviews(windowID: window)
        XCTAssertEqual(previews.map(\.failedCommandExit), [nil, 2])
        XCTAssertEqual(previews.last?.id, failing)
    }

    @MainActor
    func testSelectWindowTabSwitchesWindowAndTab() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        let firstResult = await model.createWindow(name: "One", startSession: false)
        let first = try XCTUnwrap(firstResult)
        let targetResult = await model.createTab(windowID: first, startSessions: false)
        let target = try XCTUnwrap(targetResult)
        let firstTab = try XCTUnwrap(model.snapshot.windows.first?.tabIDs.first)
        await model.selectTab(firstTab)
        let secondResult = await model.createWindow(name: "Two", startSession: false)
        let second = try XCTUnwrap(secondResult)
        let before = model.snapshot
        await model.selectWindowTab(windowID: second, tabID: target)
        XCTAssertEqual(model.snapshot, before, "A tab from another window is ignored")
        await model.selectWindowTab(windowID: first, tabID: target)
        XCTAssertEqual(model.snapshot.activeWindowID, first)
        XCTAssertEqual(model.presentation.selectedTab?.id, target)
    }

    @MainActor
    func testTabPreviewsEmptyForUnknownWindow() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        _ = await model.createWindow(name: "One", startSession: false)
        XCTAssertEqual(model.tabPreviews(windowID: UUID()), [])
    }
}
