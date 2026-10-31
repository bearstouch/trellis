import Foundation
import XCTest

@testable import TrellisCore

/// The domain rules of remote workspaces (FR-RW01, FR-RW04): a window bound to a host runs only that host's shells,
/// PIDs are unique per machine, and only a workspace with a remote window is saved as schema 2.
final class RemoteWorkspaceStoreTests: XCTestCase {
    private let host = UUID(), other = UUID()
    private let size = try! TerminalSize(columns: 160, rows: 48)

    func testNewPanesInARemoteWindowRunOnItsHost() async throws {
        let store = try WorkspaceStore()
        let created = try await store.execute(.createRemoteWindow(name: "build-box", hostID: host))
        let window = try XCTUnwrap(created.snapshot.windows.first)
        XCTAssertEqual(window.remoteHostID, host)
        let first = try XCTUnwrap(created.snapshot.tabs[window.activeTabID]?.activePaneID)
        let split = try await store.execute(.splitPane(id: first, axis: .x, availableSize: size))
        let tab = try await store.execute(.createTab(windowID: window.id))
        let duplicate = try await store.execute(.duplicateTab(id: window.activeTabID))
        for snapshot in [created.snapshot, split.snapshot, tab.snapshot, duplicate.snapshot] {
            for session in snapshot.sessions.values { XCTAssertEqual(session.launch, .remoteShell(hostID: host, directory: nil)) }
        }
        let local = try await store.execute(.createWindow(name: "Local"))
        let localPane = try XCTUnwrap(local.snapshot.tabs[local.snapshot.windows.last!.activeTabID]?.activePaneID)
        XCTAssertEqual(local.snapshot.panes[localPane].flatMap { local.snapshot.sessions[$0.sessionID]?.launch }, .shell(directory: nil))
    }

    func testRemoteAndLocalLaunchesNeverMix() async throws {
        let store = try WorkspaceStore()
        let remote = try await store.execute(.createRemoteWindow(name: "build-box", hostID: host)).snapshot
        let remotePane = try XCTUnwrap(remote.tabs[remote.windows[0].activeTabID]?.activePaneID)
        await assertRejected(store, .configureStoppedSession(paneID: remotePane, launch: .shell(directory: "/tmp")), "A local shell in a remote window")
        await assertRejected(store, .configureStoppedSession(paneID: remotePane, launch: .remoteShell(hostID: other, directory: nil)), "Another host's shell")
        _ = try await store.execute(.configureStoppedSession(paneID: remotePane, launch: .remoteShell(hostID: host, directory: "/srv/app")))
        let local = try await store.execute(.createWindow(name: "Local")).snapshot
        let localPane = try XCTUnwrap(local.tabs[local.windows[1].activeTabID]?.activePaneID)
        await assertRejected(store, .configureStoppedSession(paneID: localPane, launch: .remoteShell(hostID: host, directory: nil)), "A remote shell in a local window")
    }

    func testProcessIDsAreUniquePerMachineNotAcrossThem() async throws {
        let store = try WorkspaceStore()
        let remote = try await store.execute(.createRemoteWindow(name: "build-box", hostID: host)).snapshot
        let local = try await store.execute(.createWindow(name: "Local")).snapshot
        let remoteSession = try XCTUnwrap(remote.panes.values.first.map(\.sessionID))
        let localSession = try XCTUnwrap(local.panes.values.first { $0.sessionID != remoteSession }?.sessionID)
        _ = try await store.execute(.adoptRunningSession(sessionID: remoteSession, processID: 4242))
        _ = try await store.execute(.adoptRunningSession(sessionID: localSession, processID: 4242))
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.sessions[remoteSession]?.processID, 4242, "The same PID on the host and on this Mac are different processes")
    }

    func testALayoutKeepsTheBindingAndLandsOnTheHost() async throws {
        let store = try WorkspaceStore()
        let remote = try await store.execute(.createRemoteWindow(name: "build-box", hostID: host)).snapshot
        var unbound = remote
        unbound.windows[0].remoteHostID = nil
        await assertRejected(store, .applyLayout(target: unbound), "A window's host never changes")
        // A new pane written as a local shell, as the layout planner does, runs on the host.
        var target = remote
        let tabID = remote.windows[0].activeTabID
        let old = try XCTUnwrap(remote.tabs[tabID]?.activePaneID)
        let pane = UUID(), session = UUID(), branch = UUID()
        target.tabs[tabID]?.root = .split(id: branch, axis: .x, ratio: 0.5, children: [.pane(old), .pane(pane)])
        target.panes[pane] = WorkspacePane(id: pane, tabID: tabID, sessionID: session)
        target.sessions[session] = WorkspaceSession(id: session, launch: .shell(directory: "/srv/app"))
        let applied = try await store.execute(.applyLayout(target: target)).snapshot
        XCTAssertEqual(applied.sessions[session]?.launch, .remoteShell(hostID: host, directory: "/srv/app"))
    }

    func testOnlyAWorkspaceWithARemoteWindowIsSavedAsVersionTwo() async throws {
        let store = try WorkspaceStore()
        let local = try await store.execute(.createWindow(name: "Local")).snapshot
        XCTAssertEqual(try schemaVersion(WorkspaceSnapshotCodec.encode(local, settings: WorkspaceSettings())), 1, "Older builds keep reading it")
        let remote = try await store.execute(.createRemoteWindow(name: "build-box", hostID: host)).snapshot
        let pane = try XCTUnwrap(remote.panes.values.first { remote.sessions[$0.sessionID]?.launch.remoteHostID == host })
        _ = try await store.execute(.configureStoppedSession(paneID: pane.id, launch: .remoteShell(hostID: host, directory: "/srv/app")))
        let saved = await store.snapshot()
        let data = try WorkspaceSnapshotCodec.encode(saved, settings: WorkspaceSettings())
        XCTAssertEqual(try schemaVersion(data), 2)
        let restored = try WorkspaceSnapshotCodec.decode(data).snapshot
        XCTAssertEqual(restored.windows.first { $0.remoteHostID != nil }?.remoteHostID, host)
        XCTAssertEqual(restored.sessions[pane.sessionID]?.launch, .remoteShell(hostID: host, directory: "/srv/app"))
        XCTAssertEqual(restored.sessions[pane.sessionID]?.state, .stopped, "Restored stopped; re-attaching is the helper's answer, never a restore")
        // What a build that only knows version 1 does with it: unsupported (read-only), never corrupt.
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        future["schemaVersion"] = WorkspaceSnapshotCodec.currentVersion + 1
        XCTAssertThrowsError(try WorkspaceSnapshotCodec.decode(JSONSerialization.data(withJSONObject: future))) {
            XCTAssertEqual($0 as? WorkspacePersistenceError, .unsupportedVersion(WorkspaceSnapshotCodec.currentVersion + 1))
        }
    }

    private func schemaVersion(_ data: Data) throws -> Int? {
        (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int
    }

    private func assertRejected(_ store: WorkspaceStore, _ command: WorkspaceCommand, _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        let before = await store.snapshot()
        do {
            _ = try await store.execute(command)
            XCTFail(message, file: file, line: line)
        } catch {}
        let after = await store.snapshot()
        XCTAssertEqual(after, before, "Rejected without a change: \(message)", file: file, line: line)
    }
}
