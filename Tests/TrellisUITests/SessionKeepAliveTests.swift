import AppKit
import Darwin
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// Stands in for a broker-held session: records every request; a signal (unless kept alive) ends it.
@MainActor
final class FakeBrokerTransport: TerminalProcessTransport {
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var onInputError: ((Error) -> Void)?
    var onPasswordPromptChanged: ((Bool) -> Void)?
    var isRunning = false
    var passwordPromptActive = false
    var survivesQuit: Bool { true }
    let pid: Int32
    var signals: [Int32] = [], keepAlive: [Bool] = [], launched = 0
    init(pid: Int32, running: Bool = false) { self.pid = pid; isRunning = running }
    func launch(_ configuration: ValidatedLocalLaunch, size: TerminalSize) async throws -> Int32 { launched += 1; isRunning = true; return pid }
    func send(_ data: Data) throws {}
    func resize(_ size: TerminalSize) {}
    func signalGroup(_ signal: Int32) {
        signals.append(signal)
        guard keepAlive.last != true, isRunning else { return }
        isRunning = false
        Task { @MainActor in self.onExit?(128 + signal) }
    }
    func setKeepAlive(_ on: Bool) { keepAlive.append(on) }
    func beginDelivery() {}
}

@MainActor
final class FakeSessionBroker: SessionBrokerClient {
    var ready = true, prepared = 0, detached = 0, stoppedIncompatible = 0
    var listing: BrokerListing?
    var adoptions: [UUID: BrokerAdoption] = [:]
    var transports: [UUID: FakeBrokerTransport] = [:]
    var released: [UUID] = [], hungUp: [UUID] = []
    private var nextPID: Int32 = 61_000
    func prepare() async -> Bool { prepared += 1; return ready }
    func makeTransport(sessionID: UUID) -> (any TerminalProcessTransport)? {
        guard ready else { return nil }
        nextPID += 1
        let transport = FakeBrokerTransport(pid: nextPID)
        transports[sessionID] = transport
        return transport
    }
    func existingSessions() async -> BrokerListing? { listing }
    func adopt(sessionID: UUID, size: TerminalSize) async -> BrokerAdoption? { adoptions[sessionID] }
    func release(sessionID: UUID) { released.append(sessionID) }
    func hangUp(sessionIDs: [UUID]) { hungUp += sessionIDs }
    func stopIncompatibleBroker() async { stoppedIncompatible += 1 }
    func detach() async { detached += 1 }
}

/// FR-R03: sessions kept by the broker across quit, driven through a fake broker.
final class SessionKeepAliveTests: XCTestCase {
    private var cleanup: [() -> Void] = []
    override func tearDown() { cleanup.forEach { $0() }; cleanup = [] }

    @MainActor
    private func makeModel(directory: URL? = nil, broker: FakeSessionBroker?) throws -> AppWorkspaceModel {
        _ = NSApplication.shared
        let suite = "trellis.tests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        cleanup.append { preferences.removePersistentDomain(forName: suite) }
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: directory.map { WorkspacePersistence(directory: $0) })
        model.sessionBroker = broker
        model.confirmCloseSessions = { _ in true }
        model.confirmForceSessions = { _ in true }
        model.confirmKeepRunning = { _, _ in
            XCTFail("Unexpected keep-running prompt"); return .cancel
        }
        model.confirmStopOrphans = { _ in
            XCTFail("Unexpected orphan prompt"); return false
        }
        return model
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)); await Task.yield() }
    }

    @MainActor
    func testSettingOffNeverStartsABroker() async throws {
        let broker = FakeSessionBroker()
        let model = try makeModel(broker: broker)
        XCTAssertFalse(model.keepSessionsRunning, "Off by default")
        await model.createWindow(startSession: false)
        let terminal = try XCTUnwrap(model.activeTerminal)
        XCTAssertFalse(terminal.survivesQuit)
        XCTAssertEqual(broker.prepared, 0)
        model.confirmCloseSessions = { _ in true }
        XCTAssertEqual(model.confirmQuit(), .stopSessions, "Without the setting, quitting asks only to close")
    }

    @MainActor
    func testKeepRunningQuitSendsNoSignalAndDetaches() async throws {
        let broker = FakeSessionBroker()
        let model = try makeModel(broker: broker)
        model.setKeepSessionsRunning(true)
        await model.createWindow()
        let pane = try XCTUnwrap(model.presentation.activePane)
        let terminal = try XCTUnwrap(model.terminals[pane.id])
        let transport = try XCTUnwrap(broker.transports[pane.sessionID])
        await model.waitForUpdates()
        XCTAssertEqual(broker.prepared, 1)
        XCTAssertEqual(transport.launched, 1)
        XCTAssertTrue(terminal.survivesQuit)
        XCTAssertEqual(model.snapshot.sessions[pane.sessionID]?.state, .running)
        XCTAssertEqual(model.snapshot.sessions[pane.sessionID]?.processID, transport.pid)

        var asked: (Int, Int)?
        model.confirmKeepRunning = {
            asked = ($0, $1); return .cancel
        }
        XCTAssertEqual(model.confirmQuit(), .cancel)
        XCTAssertEqual(asked?.0, 1)
        XCTAssertFalse(model.shuttingDown, "Cancel restores the workspace")
        model.confirmKeepRunning = { _, _ in .keepRunning }
        XCTAssertEqual(model.confirmQuit(), .keepRunning)
        let detached = await model.detachForQuit()
        XCTAssertTrue(detached)
        XCTAssertEqual(transport.signals, [], "Keep Running sends no signal")
        XCTAssertEqual(transport.keepAlive, [true])
        XCTAssertEqual(broker.detached, 1)
        terminal.adapter.detach()
        XCTAssertEqual(transport.signals, [], "Tearing down the view after Keep Running still sends nothing")
    }

    @MainActor
    func testStopSessionsFromTheQuitPromptEndsBrokerSessions() async throws {
        let broker = FakeSessionBroker()
        let model = try makeModel(broker: broker)
        model.setKeepSessionsRunning(true)
        await model.createWindow()
        await model.waitForUpdates()
        let pane = try XCTUnwrap(model.presentation.activePane)
        let transport = try XCTUnwrap(broker.transports[pane.sessionID])
        model.confirmKeepRunning = { _, _ in .stopSessions }
        XCTAssertEqual(model.confirmQuit(), .stopSessions)
        model.stopAll()
        let closed = await model.shutdown()
        XCTAssertTrue(closed)
        XCTAssertEqual(transport.signals.first, SIGHUP)
        XCTAssertEqual(broker.detached, 0)
    }

    @MainActor
    func testFailedBrokerFallsBackToALocalSession() async throws {
        let broker = FakeSessionBroker()
        broker.ready = false
        let model = try makeModel(broker: broker)
        model.setKeepSessionsRunning(true)
        await model.createWindow(startSession: false)
        let pane = try XCTUnwrap(model.presentation.activePane)
        let terminal = try XCTUnwrap(model.terminals[pane.id])
        _ = await model.saveLaunchSettings(shell: "/bin/sh", directory: NSTemporaryDirectory())
        await model.start(paneID: pane.id)
        XCTAssertEqual(broker.prepared, 1)
        XCTAssertFalse(terminal.survivesQuit)
        XCTAssertNotNil(model.errorMessage, "The user learns this session won't survive quit")
        model.stopAll()
        _ = await model.shutdown()
    }

    @MainActor
    func testRelaunchAdoptsByUUIDShowsEndedSessionsAndAsksAboutOrphans() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-keep-\(UUID())")
        cleanup.append { try? FileManager.default.removeItem(at: directory) }
        let first = try makeModel(directory: directory, broker: nil)
        _ = await first.loadWorkspace()
        await first.createWindow(startSession: false)
        let left = try XCTUnwrap(first.presentation.activePane?.id)
        let split = await first.splitPane(left, axis: .x, startSession: false)
        let right = try XCTUnwrap(split)
        let kept = try XCTUnwrap(first.snapshot.panes[left]?.sessionID), ended = try XCTUnwrap(first.snapshot.panes[right]?.sessionID)
        _ = await first.flushWorkspaceSave()

        let broker = FakeSessionBroker()
        let orphan = UUID(), finishedOrphan = UUID()
        broker.listing = .sessions([
            BrokerSessionSummary(sessionID: kept, running: true, exitCode: nil), BrokerSessionSummary(sessionID: ended, running: false, exitCode: 3),
            BrokerSessionSummary(sessionID: orphan, running: true, exitCode: nil), BrokerSessionSummary(sessionID: finishedOrphan, running: false, exitCode: 0)
        ])
        let transport = FakeBrokerTransport(pid: 62_001, running: true)
        broker.adoptions[kept] = BrokerAdoption(sessionID: kept, processID: 62_001, exitCode: nil, nonce: nil, replay: Data("kept output\r\n\u{07}".utf8), transport: transport)
        broker.adoptions[ended] = BrokerAdoption(sessionID: ended, processID: nil, exitCode: 3, nonce: nil, replay: Data("old output\r\n".utf8), transport: nil)
        let second = try makeModel(directory: directory, broker: broker)
        var orphanCount: Int?
        second.confirmStopOrphans = {
            orphanCount = $0; return true
        }
        let restored = await second.loadWorkspace()
        XCTAssertTrue(restored)
        let keptTerminal = try XCTUnwrap(second.terminals[left]), endedTerminal = try XCTUnwrap(second.terminals[right])
        XCTAssertEqual(keptTerminal.sessionState, .running)
        XCTAssertEqual(keptTerminal.processID, 62_001)
        XCTAssertEqual(second.snapshot.sessions[kept]?.state, .running)
        XCTAssertEqual(second.snapshot.sessions[kept]?.processID, 62_001)
        XCTAssertTrue(keptTerminal.retainedText.contains("kept output"))
        XCTAssertNil(second.inputWaits[left], "A replayed bell raises no attention")
        XCTAssertFalse(second.outputJournal.contains(session: kept), "Replay is never journaled")
        XCTAssertEqual(endedTerminal.sessionState, .stopped)
        XCTAssertTrue(endedTerminal.retainedText.contains("old output"))
        XCTAssertTrue(endedTerminal.retainedText.contains("Session ended while Trellis was closed (exit 3)"))
        XCTAssertEqual(Set(broker.released), [ended, finishedOrphan])
        XCTAssertEqual(orphanCount, 1)
        XCTAssertEqual(broker.hungUp, [orphan], "Stop Them hangs up only sessions no pane claims")
        XCTAssertEqual(transport.launched, 0, "Adopting never spawns")

        // The adopted session's later exit reaches the store like any other.
        transport.isRunning = false
        transport.onExit?(0)
        await second.waitForUpdates()
        await waitUntil { second.snapshot.sessions[kept]?.state == .exited }
        XCTAssertEqual(second.snapshot.sessions[kept]?.state, .exited)
        XCTAssertEqual(second.snapshot.sessions[kept]?.exitCode, 0)
    }

    @MainActor
    func testLeaveRunningAndIncompatibleBrokers() async throws {
        let broker = FakeSessionBroker()
        let orphan = UUID()
        broker.listing = .sessions([BrokerSessionSummary(sessionID: orphan, running: true, exitCode: nil)])
        let model = try makeModel(directory: FileManager.default.temporaryDirectory.appendingPathComponent("trellis-orphan-\(UUID())"), broker: broker)
        var asked = 0
        model.confirmStopOrphans = { _ in
            asked += 1; return false
        }
        _ = await model.loadWorkspace()
        XCTAssertEqual(asked, 1, "Kept sessions are reported even with no saved workspace")
        XCTAssertEqual(broker.hungUp, [], "Leave Running sends nothing")

        broker.listing = .incompatible
        let other = try makeModel(directory: FileManager.default.temporaryDirectory.appendingPathComponent("trellis-incompatible-\(UUID())"), broker: broker)
        var count: Int?
        other.confirmStopOrphans = {
            count = $0; return true
        }
        _ = await other.loadWorkspace()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(broker.stoppedIncompatible, 1)
    }

    @MainActor
    func testClosingTheWindowStillEndsBrokerSessions() async throws {
        let broker = FakeSessionBroker()
        let model = try makeModel(broker: broker)
        model.setKeepSessionsRunning(true)
        await model.createWindow()
        await model.waitForUpdates()
        let pane = try XCTUnwrap(model.presentation.activePane)
        let transport = try XCTUnwrap(broker.transports[pane.sessionID])
        XCTAssertTrue(model.confirmAllSessionClosure())
        model.stopAll()
        let closed = await model.endSessionsForWindowClose()
        XCTAssertTrue(closed)
        XCTAssertEqual(transport.signals.first, SIGHUP)
        XCTAssertEqual(model.snapshot.windows.count, 1, "Closing the window keeps the layout (MAC-04)")
        XCTAssertTrue(model.runningTerminals.isEmpty)
    }
}
