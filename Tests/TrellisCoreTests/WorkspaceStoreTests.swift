import Foundation
import XCTest
@testable import TrellisCore

final class WorkspaceStoreTests: XCTestCase {
    func testRejectDanglingReferences() async throws {
        let store = try WorkspaceStore()
        let created = try await store.execute(.createWindow(name: "Project"))
        let tabID = try XCTUnwrap(created.snapshot.windows.first?.activeTabID)
        do {
            _ = try await store.execute(.replaceTabLayout(id: tabID, root: .pane(UUID())))
            XCTFail("dangling pane was accepted")
        } catch { XCTAssertNotNil(error as? WorkspaceError) }
        let after = await store.snapshot()
        XCTAssertEqual(after, created.snapshot)
    }

    func testRejectMalformedSplit() async throws {
        for count in [0, 1, 3] {
            let store = try WorkspaceStore()
            let initial = try await store.execute(.createWindow(name: "Project"))
            let tabID = try XCTUnwrap(initial.snapshot.windows.first?.activeTabID)
            let paneID = try XCTUnwrap(initial.snapshot.tabs[tabID]?.activePaneID)
            let root = PaneLayout.split(id: UUID(), axis: .x, ratio: 0.5, children: Array(repeating: .pane(paneID), count: count))
            do { _ = try await store.execute(.replaceTabLayout(id: tabID, root: root)); XCTFail("accepted \(count) children") } catch { XCTAssertNotNil(error as? WorkspaceError) }
            let after = await store.snapshot()
            XCTAssertEqual(after, initial.snapshot)
        }
    }

    func testRejectStaleRevision() async throws {
        let store = try WorkspaceStore()
        let original = try await store.execute(.createWindow(name: "Project"), expectedRevision: 0)
        let id = try XCTUnwrap(original.createdWindowID)
        let changed = try await store.execute(.renameWindow(id: id, name: "Renamed"), expectedRevision: 1)
        do {
            _ = try await store.execute(.renameWindow(id: id, name: "Stale"), expectedRevision: 1)
            XCTFail("accepted stale revision")
        } catch {
            XCTAssertEqual(error as? WorkspaceError, .conflict(expected: 1, actual: 2))
        }
        let after = await store.snapshot()
        XCTAssertEqual(after, changed.snapshot)
    }

    func testFailedLaunchKeepsValidPane() async throws {
        let store = try WorkspaceStore()
        let service = WorkspaceCommandService(store: store)
        let created = try await service.execute(.createWindow(name: "Project"))
        let pane = try XCTUnwrap(created.snapshot.panes.values.first)
        XCTAssertTrue(created.effects.isEmpty)
        let started = try await service.execute(.startSession(paneID: pane.id))
        guard case .start(let request) = try XCTUnwrap(started.effects.first) else { return XCTFail("missing launch effect") }
        // The effect runner is outside the store; inject its failed outcome.
        let failed = try await service.execute(.completeLaunch(sessionID: request.sessionID, attemptID: request.attemptID, outcome: .failed(message: "Executable unavailable")))
        try failed.snapshot.validate()
        XCTAssertEqual(failed.snapshot.panes[pane.id], pane)
        XCTAssertEqual(failed.snapshot.sessions[pane.sessionID]?.state, .failed)
        XCTAssertEqual(failed.snapshot.sessions[pane.sessionID]?.failureMessage, "Executable unavailable")
        XCTAssertNil(failed.snapshot.sessions[pane.sessionID]?.processID)
        XCTAssertTrue(failed.effects.isEmpty)
    }

    func testConcurrentCommandsAreSerializedAndNoUpdatesAreLost() async throws {
        let store = try WorkspaceStore()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<20 {
                group.addTask { _ = try await store.execute(.createWindow(name: "Window \(n)")) }
            }
            try await group.waitForAll()
        }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.revision, 20)
        XCTAssertEqual(snapshot.windows.count, 20)
        XCTAssertEqual(snapshot.panes.count, 20)
        try snapshot.validate()
    }

    func testStoreRejectsInvalidInitialSnapshotsAndOrphanResources() throws {
        var orphan = WorkspaceSnapshot()
        let session = WorkspaceSession(id: UUID())
        orphan.sessions[session.id] = session
        XCTAssertThrowsError(try WorkspaceStore(snapshot: orphan))
        var selectedEmpty = WorkspaceSnapshot()
        selectedEmpty.activeWindowID = UUID()
        XCTAssertThrowsError(try WorkspaceStore(snapshot: selectedEmpty))
    }

    func testDuplicateIDGeneratorCannotCorruptState() async throws {
        let duplicate = UUID()
        let store = try WorkspaceStore(makeID: { duplicate })
        do { _ = try await store.execute(.createWindow(name: "Project")); XCTFail("duplicate IDs accepted") } catch { XCTAssertNotNil(error as? WorkspaceError) }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot, WorkspaceSnapshot())
    }

    func testDuplicateCompletionAndStaleAttemptCannotChangeSession() async throws {
        let store = try WorkspaceStore()
        let created = try await store.execute(.createWindow(name: "Project"))
        let pane = try XCTUnwrap(created.snapshot.panes.values.first)
        let started = try await store.execute(.startSession(paneID: pane.id))
        guard case .start(let request) = try XCTUnwrap(started.effects.first) else { return XCTFail("missing effect") }
        do { _ = try await store.execute(.completeLaunch(sessionID: request.sessionID, attemptID: UUID(), outcome: .started(processID: 42))); XCTFail("stale attempt accepted") } catch {
            XCTAssertEqual(error as? WorkspaceError, .staleLaunch)
        }
        let running = try await store.execute(.completeLaunch(sessionID: request.sessionID, attemptID: request.attemptID, outcome: .started(processID: 42)))
        XCTAssertEqual(running.snapshot.sessions[request.sessionID]?.state, .running)
        do { _ = try await store.execute(.completeLaunch(sessionID: request.sessionID, attemptID: request.attemptID, outcome: .failed(message: "late"))); XCTFail("duplicate completion accepted") } catch {
            XCTAssertEqual(error as? WorkspaceError, .staleLaunch)
        }
        let after = await store.snapshot()
        XCTAssertEqual(after, running.snapshot)
    }

    func testSnapshotCopyIsIsolatedAndSameNameDoesNotAdvanceRevision() async throws {
        let store = try WorkspaceStore()
        let created = try await store.execute(.createWindow(name: "Project"))
        let id = try XCTUnwrap(created.createdWindowID)
        var externalCopy = created.snapshot
        externalCopy.windows.removeAll()
        let same = try await store.execute(.renameWindow(id: id, name: " Project "))
        XCTAssertEqual(same.snapshot, created.snapshot)
        let after = await store.snapshot()
        XCTAssertEqual(after.windows.count, 1)
    }

    func testUIAndAutomationFacadesProduceEquivalentDomainState() async throws {
        // Reuse the same validated initial snapshot so comparison is exact.
        let seed = try WorkspaceStore()
        let initial = try await seed.execute(.createWindow(name: "Project"))
        let id = try XCTUnwrap(initial.createdWindowID)
        let ui = WorkspaceCommandService(store: try WorkspaceStore(snapshot: initial.snapshot))
        let automation = WorkspaceCommandService(store: try WorkspaceStore(snapshot: initial.snapshot))
        let a = try await ui.execute(.renameWindow(id: id, name: "Renamed"), expectedRevision: 1)
        let b = try await automation.execute(.renameWindow(id: id, name: "Renamed"), expectedRevision: 1)
        XCTAssertEqual(a, b)
    }

    func testValidOrderedTabsAndBinarySplitsCanBeLoadedAndUpdated() async throws {
        let initial = makeSplitWorkspace()
        let store = try WorkspaceStore(snapshot: initial)
        let window = try XCTUnwrap(initial.windows.first)
        let tab = try XCTUnwrap(initial.tabs[window.tabIDs[1]])
        guard case .split(let id, let axis, _, let children) = tab.root else {
            return XCTFail("fixture must contain a split")
        }
        let changed = try await store.execute(
            .replaceTabLayout(
                id: tab.id, root: .split(id: id, axis: axis, ratio: 0.7, children: children.reversed())
            ), expectedRevision: 0)
        try changed.snapshot.validate()
        XCTAssertEqual(changed.snapshot.windows.first?.tabIDs, window.tabIDs)
        XCTAssertEqual(changed.snapshot.tabs[tab.id]?.root.paneIDs, children.reversed().flatMap(\.paneIDs))
        XCTAssertEqual(changed.snapshot.tabs[tab.id]?.activePaneID, tab.activePaneID)
        XCTAssertEqual(changed.snapshot.tabs[tab.id]?.revision, 1)
        XCTAssertEqual(changed.snapshot.revision, 1)
        XCTAssertTrue(changed.effects.isEmpty)
    }

    func testRejectsIncorrectOwnershipSharedSessionsAndDuplicateSplitIDs() throws {
        let initial = makeSplitWorkspace()
        let tabIDs = try XCTUnwrap(initial.windows.first?.tabIDs)
        let firstTab = try XCTUnwrap(initial.tabs[tabIDs[0]])
        let secondTab = try XCTUnwrap(initial.tabs[tabIDs[1]])
        let pane = try XCTUnwrap(initial.panes[firstTab.activePaneID])
        let otherPane = try XCTUnwrap(initial.panes[secondTab.activePaneID])

        var wrongOwner = initial
        wrongOwner.panes[pane.id] = WorkspacePane(id: pane.id, tabID: secondTab.id, sessionID: pane.sessionID)
        XCTAssertThrowsError(try WorkspaceStore(snapshot: wrongOwner))

        var sharedSession = initial
        sharedSession.panes[pane.id]?.sessionID = otherPane.sessionID
        sharedSession.sessions.removeValue(forKey: pane.sessionID)
        XCTAssertThrowsError(try WorkspaceStore(snapshot: sharedSession))

        var duplicateSplit = initial
        guard case .split(let firstID, _, _, _) = firstTab.root,
            case .split(_, let axis, let ratio, let children) = secondTab.root
        else {
            return XCTFail("fixture must contain splits")
        }
        duplicateSplit.tabs[secondTab.id]?.root = .split(id: firstID, axis: axis, ratio: ratio, children: children)
        XCTAssertThrowsError(try WorkspaceStore(snapshot: duplicateSplit))

        var emptyWindow = initial
        emptyWindow.windows[0].tabIDs = []
        XCTAssertThrowsError(try WorkspaceStore(snapshot: emptyWindow))
    }

    func testConcurrentExpectedRevisionCommandsCommitExactlyOnce() async throws {
        let store = try WorkspaceStore()
        let result = try await store.execute(.createWindow(name: "Project"))
        let id = try XCTUnwrap(result.createdWindowID)
        let successCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<20 {
                group.addTask {
                    do {
                        _ = try await store.execute(.renameWindow(id: id, name: "Window \(index)"), expectedRevision: 1)
                        return true
                    } catch { return false }
                }
            }
            var successes = 0
            for await succeeded in group { if succeeded { successes += 1 } }
            return successes
        }
        let after = await store.snapshot()
        XCTAssertEqual(successCount, 1)
        XCTAssertEqual(after.revision, 2)
        XCTAssertEqual(after.windows[0].revision, 2)
        try after.validate()
    }

    func testDuplicateLiveProcessOwnershipIsRejectedAtomically() async throws {
        let initial = makeSplitWorkspace()
        let paneIDs = initial.panes.keys.sorted { $0.uuidString < $1.uuidString }
        let store = try WorkspaceStore(snapshot: initial)
        let first = try await store.execute(.startSession(paneID: paneIDs[0]))
        guard case .start(let firstRequest) = try XCTUnwrap(first.effects.first) else {
            return XCTFail("missing first launch effect")
        }
        _ = try await store.execute(
            .completeLaunch(
                sessionID: firstRequest.sessionID, attemptID: firstRequest.attemptID, outcome: .started(processID: 42)
            ))
        let second = try await store.execute(.startSession(paneID: paneIDs[1]))
        guard case .start(let secondRequest) = try XCTUnwrap(second.effects.first) else {
            return XCTFail("missing second launch effect")
        }
        do {
            _ = try await store.execute(
                .completeLaunch(
                    sessionID: secondRequest.sessionID, attemptID: secondRequest.attemptID, outcome: .started(processID: 42)
                ))
            XCTFail("duplicate PID ownership accepted")
        } catch { XCTAssertNotNil(error as? WorkspaceError) }
        let after = await store.snapshot()
        XCTAssertEqual(after, second.snapshot)
        XCTAssertEqual(after.sessions[secondRequest.sessionID]?.state, .starting)

        // Initial snapshots must enforce the same ownership rule, including
        // sessions reserving a process while closing.
        var duplicate = second.snapshot
        duplicate.sessions[firstRequest.sessionID]?.state = .closing
        duplicate.sessions[secondRequest.sessionID]?.state = .running
        duplicate.sessions[secondRequest.sessionID]?.launchAttemptID = nil
        duplicate.sessions[secondRequest.sessionID]?.processID = 42
        XCTAssertThrowsError(try WorkspaceStore(snapshot: duplicate))
    }

    private func makeSplitWorkspace() -> WorkspaceSnapshot {
        var snapshot = WorkspaceSnapshot()
        let windowID = UUID()
        var tabIDs: [UUID] = []
        for title in ["First", "Second"] {
            let tabID = UUID()
            var paneIDs: [UUID] = []
            for _ in 0..<2 {
                let paneID = UUID(), sessionID = UUID()
                snapshot.panes[paneID] = WorkspacePane(id: paneID, tabID: tabID, sessionID: sessionID)
                snapshot.sessions[sessionID] = WorkspaceSession(id: sessionID)
                paneIDs.append(paneID)
            }
            snapshot.tabs[tabID] = WorkspaceTab(
                id: tabID, windowID: windowID, title: title,
                root: .split(id: UUID(), axis: .x, ratio: 0.5, children: paneIDs.map(PaneLayout.pane)),
                activePaneID: paneIDs[0]
            )
            tabIDs.append(tabID)
        }
        snapshot.windows = [ManagedWindow(id: windowID, name: "Project", tabIDs: tabIDs, activeTabID: tabIDs[0])]
        snapshot.activeWindowID = windowID
        return snapshot
    }
}
