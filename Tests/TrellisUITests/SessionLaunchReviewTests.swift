import AppKit
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// A broker whose `prepare` waits until the test lets it finish, so a quit or close can begin mid-launch.
@MainActor
private final class PausedBroker: SessionBrokerClient {
    private var waiting: CheckedContinuation<Bool, Never>?
    var isWaiting: Bool { waiting != nil }
    func finishPrepare() { waiting?.resume(returning: true); waiting = nil }
    func prepare() async -> Bool { await withCheckedContinuation { waiting = $0 } }
    func makeTransport(sessionID: UUID) -> (any TerminalProcessTransport)? { nil }
    func existingSessions() async -> BrokerListing? { nil }
    func adopt(sessionID: UUID, size: TerminalSize) async -> BrokerAdoption? { nil }
    func release(sessionID: UUID) {}
    func hangUp(sessionIDs: [UUID]) {}
    func stopIncompatibleBroker() async {}
    func detach() async {}
}

/// Review-driven: launches cancelled by a quit or close that is then cancelled.
final class SessionLaunchReviewTests: XCTestCase {
    @MainActor
    func testALaunchCancelledByAQuitLeavesARestartablePane() async throws {
        _ = NSApplication.shared
        let suite = "trellis.tests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let broker = PausedBroker()
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: nil)
        model.sessionBroker = broker
        model.setKeepSessionsRunning(true)
        await model.createWindow(startSession: false)
        let pane = try XCTUnwrap(model.presentation.activePane)
        let terminal = try XCTUnwrap(model.terminals[pane.id])
        defer {
            model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }

        let launch = Task { await model.start(paneID: pane.id) }
        let deadline = Date().addingTimeInterval(3)
        while !broker.isWaiting, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(broker.isWaiting)
        // Quit begins while the launch waits for the broker, then the user cancels it.
        model.shuttingDown = true
        broker.finishPrepare()
        await launch.value
        model.cancelShutdown()

        let session = try XCTUnwrap(model.snapshot.sessions[pane.sessionID])
        XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(terminal.sessionState, .failed, "The pane matches the store instead of offering a Start that can't work")
        await model.restartPane(pane.id, startSession: false)
        let restarted = try XCTUnwrap(model.snapshot.panes[pane.id])
        XCTAssertNotEqual(restarted.sessionID, pane.sessionID, "Restart is offered and gives the pane a new session")
        XCTAssertEqual(model.terminals[pane.id]?.sessionState, .stopped)
    }
}
