import Darwin
import XCTest
@testable import UTermCore

@MainActor
private final class CloseSpy: ClosableSession {
    let sessionID = UUID()
    var isRunning = true
    var requiresTermination = true
    var signals: [Bool] = []
    var exitsOnForce = false
    func requestTermination(force: Bool) {
        signals.append(force)
        if force && exitsOnForce { isRunning = false }
    }
}

@MainActor
private final class FakeClosureClock {
    var elapsed: TimeInterval = 0
    func sleep(_ duration: TimeInterval) async throws { elapsed += duration }
}

final class SessionClosureTests: XCTestCase {
    @MainActor
    func testS009_UT01_cancelHasNoEffects() async throws {
        let clock = FakeClosureClock()
        let coordinator = SessionClosureCoordinator(now: { clock.elapsed }, sleep: { try await clock.sleep($0) })
        let sessions = [CloseSpy(), CloseSpy(), CloseSpy()]
        let store = try WorkspaceStore()
        let before = try await store.execute(.createWindow(name: "Project")).snapshot
        let result = await coordinator.close(sessions, allowRunning: false)
        XCTAssertEqual(result.code, "CONFIRMATION_REQUIRED")
        XCTAssertEqual(result, .confirmationRequired(sessionIDs: sessions.map(\.sessionID)))
        XCTAssertTrue(sessions.allSatisfy { $0.signals.isEmpty && $0.isRunning })
        XCTAssertEqual(clock.elapsed, 0)
        let after = await store.snapshot()
        XCTAssertEqual(before, after)
    }

    @MainActor
    func testS009_UT02_graceTimeoutRequiresExplicitForce() async {
        let clock = FakeClosureClock()
        let coordinator = SessionClosureCoordinator(now: { clock.elapsed }, sleep: { try await clock.sleep($0) })
        let session = CloseSpy()
        session.exitsOnForce = true
        let premature = await coordinator.close([session], allowRunning: true, force: true)
        XCTAssertEqual(premature.code, "CLOSE_PENDING")
        XCTAssertTrue(session.signals.isEmpty)
        let pending = await coordinator.close([session], allowRunning: true)
        XCTAssertEqual(pending, .closePending(sessionIDs: [session.sessionID]))
        XCTAssertEqual(clock.elapsed, 2, accuracy: 0.000001)
        XCTAssertEqual(session.signals, [false])
        let unauthorized = await coordinator.close([session], allowRunning: false, force: true)
        XCTAssertEqual(unauthorized.code, "CONFIRMATION_REQUIRED")
        XCTAssertEqual(session.signals, [false])
        let closed = await coordinator.close([session], allowRunning: true, force: true)
        XCTAssertEqual(closed, .closed)
        XCTAssertEqual(session.signals, [false, true])
    }

    @MainActor
    func testExitedChildDrainsWithoutAnotherSignal() async {
        let clock = FakeClosureClock()
        let coordinator = SessionClosureCoordinator(now: { clock.elapsed }, sleep: { try await clock.sleep($0) })
        let session = CloseSpy()
        session.requiresTermination = false
        let result = await coordinator.close([session], allowRunning: true)
        XCTAssertEqual(result.code, "CLOSE_PENDING")
        XCTAssertTrue(session.signals.isEmpty)
        session.isRunning = false
        let closed = await coordinator.close([session], allowRunning: true)
        XCTAssertEqual(closed, .closed)
    }

    func testS009_UT03_neverSignalReusedPid() {
        let original = OwnedProcessIdentity(pid: 1234, parentPID: 567, groupID: 1234, startedSeconds: 100, startedMicroseconds: 10)
        let reused = OwnedProcessIdentity(pid: 1234, parentPID: 567, groupID: 1234, startedSeconds: 101, startedMicroseconds: 10)
        XCTAssertTrue(original.permitsSignal(current: original, ownerPID: 567))
        XCTAssertFalse(original.permitsSignal(current: reused, ownerPID: 567))
        XCTAssertFalse(original.permitsSignal(current: nil, ownerPID: 567))
        XCTAssertFalse(original.permitsSignal(current: original, ownerPID: 999))
    }

    func testS009_UT04_restartReplacesOnlySession() async throws {
        let store = try WorkspaceStore()
        let created = try await store.execute(.createWindow(name: "Project")).snapshot
        let pane = try XCTUnwrap(created.panes.values.first)
        let launch = try await store.execute(.startSession(paneID: pane.id))
        guard case .start(let request) = launch.effects.first else { return XCTFail("No launch request") }
        _ = try await store.execute(.completeLaunch(sessionID: pane.sessionID, attemptID: request.attemptID, outcome: .started(processID: 1234)))
        let exited = try await store.execute(.recordSessionExit(sessionID: pane.sessionID, code: 7)).snapshot
        let restarted = try await store.execute(.restartSession(paneID: pane.id)).snapshot
        let newID = try XCTUnwrap(restarted.panes[pane.id]?.sessionID)
        XCTAssertNotEqual(newID, pane.sessionID)
        XCTAssertNil(restarted.sessions[pane.sessionID])
        XCTAssertEqual(restarted.windows, exited.windows)
        XCTAssertEqual(restarted.tabs, exited.tabs)
        XCTAssertEqual(restarted.panes[pane.id]?.tabID, pane.tabID)
        XCTAssertEqual(restarted.sessions[newID]?.launch, exited.sessions[pane.sessionID]?.launch)
        XCTAssertEqual(restarted.sessions[newID]?.state, .stopped)
        XCTAssertNil(restarted.sessions[newID]?.processID)
        XCTAssertNil(restarted.sessions[newID]?.exitCode)
        try restarted.validate()
    }
}
