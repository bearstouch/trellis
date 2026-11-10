import AppKit
import XCTest
import TrellisCore
@testable import TrellisUI

final class SpaceManagementTests: XCTestCase {
    func testCreateInitialHierarchy() async throws {
        let store = try WorkspaceStore()
        let result = try await store.execute(.createSpace(name: "Project"))
        let state = result.snapshot
        XCTAssertEqual(state.spaces.count, 1)
        XCTAssertEqual(state.tabs.count, 1)
        XCTAssertEqual(state.panes.count, 1)
        XCTAssertEqual(state.sessions.count, 1)
        let ids = state.spaces.map(\.id) + Array(state.tabs.keys) + Array(state.panes.keys) + Array(state.sessions.keys)
        XCTAssertEqual(Set(ids).count, 4)
        try state.validate()
    }

    func testSwitchRestoresSelection() async throws {
        let store = try WorkspaceStore()
        let first = try await store.execute(.createSpace(name: "One"))
        let second = try await store.execute(.createSpace(name: "Two"))
        let firstID = try XCTUnwrap(first.createdSpaceID)
        let secondID = try XCTUnwrap(second.createdSpaceID)
        var initial = second.snapshot
        // Both windows keep a non-default active tab and pane. Include live
        // session ownership so selection cannot silently reconstruct sessions.
        for index in initial.spaces.indices {
            let spaceID = initial.spaces[index].id
            let tabID = UUID(), paneA = UUID(), paneB = UUID(), sessionA = UUID(), sessionB = UUID()
            initial.spaces[index].tabIDs.append(tabID)
            initial.spaces[index].activeTabID = tabID
            initial.tabs[tabID] = WorkspaceTab(
                id: tabID, spaceID: spaceID, title: "Split",
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
        _ = try await restoredStore.execute(.selectSpace(id: firstID))
        _ = try await restoredStore.execute(.selectSpace(id: secondID))
        let back = try await restoredStore.execute(.selectSpace(id: firstID)).snapshot
        XCTAssertEqual(back.spaces, initial.spaces)
        XCTAssertEqual(back.tabs, initial.tabs)
        XCTAssertEqual(back.panes, initial.panes)
        XCTAssertEqual(back.sessions, initial.sessions)
        let expectedTab = try XCTUnwrap(initial.tabs[initial.spaces[0].activeTabID])
        XCTAssertEqual(WorkspacePresentation(snapshot: back).selectedTab?.id, expectedTab.id)
        XCTAssertEqual(WorkspacePresentation(snapshot: back).activePane?.id, expectedTab.activePaneID)
    }

    func testReorderIsPermutation() async throws {
        let store = try WorkspaceStore()
        _ = try await store.execute(.createSpace(name: "One"))
        let before = try await store.execute(.createSpace(name: "Two")).snapshot
        let ids = before.spaces.map(\.id)
        for invalid in [[ids[0]], [ids[0], ids[0]], [ids[0], UUID()]] {
            do { _ = try await store.execute(.reorderSpaces(ids: invalid)); XCTFail("Accepted invalid order") } catch {}
            let unchanged = await store.snapshot()
            XCTAssertEqual(unchanged, before)
        }
        let after = try await store.execute(.reorderSpaces(ids: ids.reversed())).snapshot
        XCTAssertEqual(after.spaces.map(\.id), ids.reversed())
        XCTAssertEqual(after.activeSpaceID, before.activeSpaceID)
    }

    @MainActor
    func testInactiveOutputDoesNotSelect() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createSpace(name: "One", startSession: false)
        let first = try XCTUnwrap(model.snapshot.activeSpaceID)
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        let terminal = model.activeTerminal
        await model.createSpace(name: "Two", startSession: false)
        let active = model.snapshot.activeSpaceID
        for _ in 0..<10_000 { model.recordActivity(paneID: pane) }
        model.recordActivity(paneID: pane, exited: true)
        XCTAssertEqual(model.snapshot.activeSpaceID, active)
        XCTAssertEqual(model.activity.count, 1)
        XCTAssertEqual(model.activity[first]?.hasOutput, true)
        XCTAssertEqual(model.activity[first]?.hasExit, true)
        await model.selectSpace(first)
        XCTAssertNil(model.activity[first])
        XCTAssertTrue(model.activeTerminal === terminal)
    }

    @MainActor
    func testDeletingSelectedSpaceClearsFallbackActivity() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createSpace(name: "One", startSession: false)
        let first = try XCTUnwrap(model.snapshot.activeSpaceID)
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        await model.createSpace(name: "Two", startSession: false)
        let second = try XCTUnwrap(model.snapshot.activeSpaceID)
        model.recordActivity(paneID: pane, exited: true)
        XCTAssertEqual(model.activity[first]?.hasExit, true)
        await model.deleteSpace(second)
        XCTAssertEqual(model.snapshot.activeSpaceID, first)
        XCTAssertNil(model.activity[first])
    }

    @MainActor
    func testOlderCommandReplyCannotRestoreDeletedSpace() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createSpace(startSession: false)
        let old = model.snapshot
        await model.deleteSpace(try XCTUnwrap(old.activeSpaceID))
        let deleted = model.snapshot
        model.publish(old)
        XCTAssertEqual(model.snapshot, deleted)
        XCTAssertTrue(model.presentation.isEmpty)
    }

    func testDeletionRejectsLiveSessionsAtomically() async throws {
        let store = try WorkspaceStore()
        let created = try await store.execute(.createSpace(name: "One"))
        let paneID = try XCTUnwrap(created.snapshot.panes.keys.first)
        let launched = try await store.execute(.startSession(paneID: paneID))
        do { _ = try await store.execute(.deleteSpace(id: try XCTUnwrap(created.createdSpaceID))); XCTFail("Deleted starting process") } catch {}
        let unchanged = await store.snapshot()
        XCTAssertEqual(unchanged, launched.snapshot)
    }

    @MainActor
    func testDeleteLastStoppedSpaceReachesEmptyState() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        model.confirmForceSessions = { _ in true }  // Explicit cleanup authorization for owned test processes.
        await model.createSpace(startSession: false)
        let id = try XCTUnwrap(model.snapshot.activeSpaceID)
        await model.deleteSpace(id)
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
        await model.createSpace()
        let id = try XCTUnwrap(model.snapshot.activeSpaceID)
        let terminal = try XCTUnwrap(model.activeTerminal)
        defer { terminal.stop() }
        model.confirmCloseSessions = { count in
            XCTAssertEqual(count, 1); return false
        }
        await model.deleteSpace(id)
        XCTAssertTrue(terminal.isRunning)
        XCTAssertEqual(model.snapshot.spaces.count, 1)
        await model.createSpace(name: "Unaffected")
        let otherID = try XCTUnwrap(model.snapshot.activeSpaceID)
        let other = try XCTUnwrap(model.activeTerminal)
        defer { other.stop() }
        let otherPID = other.processID
        let otherSession = model.presentation.activePane?.sessionID
        model.confirmCloseSessions = { count in
            XCTAssertEqual(count, 1); return true
        }
        await model.deleteSpace(id)
        XCTAssertFalse(terminal.isRunning)
        XCTAssertEqual(model.snapshot.spaces.map(\.id), [otherID])
        XCTAssertEqual(model.snapshot.activeSpaceID, otherID)
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
    func testTabPreviewsListInactiveSpaceTabsInOrderWithActiveTab() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        let firstResult = await model.createSpace(name: "One", startSession: false)
        let first = try XCTUnwrap(firstResult)
        let firstTab = try XCTUnwrap(model.presentation.selectedTab?.id)
        let secondResult = await model.createTab(spaceID: first, startSessions: false)
        let second = try XCTUnwrap(secondResult)
        let thirdResult = await model.createTab(spaceID: first, startSessions: false)
        let third = try XCTUnwrap(thirdResult)
        let splitFrom = try XCTUnwrap(model.presentation.activePane?.id)
        _ = await model.splitPane(splitFrom, axis: .x, startSession: false)
        await model.selectTab(second)
        _ = await model.createSpace(name: "Two", startSession: false)
        XCTAssertNotEqual(model.snapshot.activeSpaceID, first)
        let previews = model.tabPreviews(spaceID: first)
        XCTAssertEqual(previews.map(\.id), [firstTab, second, third])
        XCTAssertEqual(previews.map(\.isActive), [false, true, false])
        XCTAssertEqual(previews.map(\.paneCount), [1, 1, 2])
        XCTAssertTrue(previews.allSatisfy { !$0.isBusy && $0.inputWait == nil && $0.failedCommandExit == nil && !$0.hasExitedSession })
    }

    @MainActor
    func testTabPreviewsReflectRenameColorAndInputWait() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        let spaceResult = await model.createSpace(name: "One", startSession: false)
        let space = try XCTUnwrap(spaceResult)
        let tab = try XCTUnwrap(model.presentation.selectedTab?.id)
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        await model.renameTab(tab, title: "api-server")
        await model.setTabColor(tab, color: .green)
        model.terminals[pane]?.onPasswordPromptChanged?(true)
        let preview = try XCTUnwrap(model.tabPreviews(spaceID: space).first)
        XCTAssertEqual(preview.title, "api-server")
        XCTAssertEqual(preview.color, .green)
        XCTAssertEqual(preview.inputWait, .password)
    }

    @MainActor
    func testTabPreviewsMarkOnlyTheTabWhoseCommandFailed() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        let spaceResult = await model.createSpace(name: "One", startSession: false)
        let space = try XCTUnwrap(spaceResult)
        let tabResult = await model.createTab(spaceID: space, startSessions: false)
        let failing = try XCTUnwrap(tabResult)
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        let terminal = try XCTUnwrap(model.terminals[pane])
        for event: ShellIntegrationEvent in [.promptStart(directory: "/tmp"), .commandStart(commandLine: "false"), .commandFinished(exitCode: 2)] {
            terminal.onShellIntegrationEvent?(event)
        }
        let previews = model.tabPreviews(spaceID: space)
        XCTAssertEqual(previews.map(\.failedCommandExit), [nil, 2])
        XCTAssertEqual(previews.last?.id, failing)
    }

    @MainActor
    func testSelectSpaceTabSwitchesSpaceAndTab() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        let firstResult = await model.createSpace(name: "One", startSession: false)
        let first = try XCTUnwrap(firstResult)
        let targetResult = await model.createTab(spaceID: first, startSessions: false)
        let target = try XCTUnwrap(targetResult)
        let firstTab = try XCTUnwrap(model.snapshot.spaces.first?.tabIDs.first)
        await model.selectTab(firstTab)
        let secondResult = await model.createSpace(name: "Two", startSession: false)
        let second = try XCTUnwrap(secondResult)
        let before = model.snapshot
        await model.selectSpaceTab(spaceID: second, tabID: target)
        XCTAssertEqual(model.snapshot, before, "A tab from another space is ignored")
        await model.selectSpaceTab(spaceID: first, tabID: target)
        XCTAssertEqual(model.snapshot.activeSpaceID, first)
        XCTAssertEqual(model.presentation.selectedTab?.id, target)
    }

    @MainActor
    func testTabPreviewsEmptyForUnknownSpace() async throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        _ = await model.createSpace(name: "One", startSession: false)
        XCTAssertEqual(model.tabPreviews(spaceID: UUID()), [])
    }
}
