import XCTest
@testable import TrellisCore

/// FR-T09: OSC 9;4 progress resolution, staleness, aggregation and text.
final class TerminalProgressTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)

    func testReportsResolveLikeTheEngineBar() {
        var tracker = PaneProgressTracker()
        XCTAssertEqual(tracker.apply(.init(kind: .set, value: 50), at: start), TerminalProgress(state: .normal, percent: 50))
        XCTAssertEqual(tracker.apply(.init(kind: .error), at: start), TerminalProgress(state: .error, percent: 50), "An error keeps the last value")
        XCTAssertEqual(tracker.apply(.init(kind: .pause), at: start), TerminalProgress(state: .paused, percent: 50))
        XCTAssertEqual(tracker.apply(.init(kind: .indeterminate), at: start), TerminalProgress(state: .indeterminate))
        XCTAssertEqual(tracker.apply(.init(kind: .pause), at: start)?.percent, 50, "Indeterminate doesn't forget the last value")
        XCTAssertNil(tracker.apply(.init(kind: .remove), at: start))
        XCTAssertNil(tracker.progress)
        XCTAssertEqual(tracker.apply(.init(kind: .pause), at: start)?.percent, 100, "Remove forgets the value; a bare pause shows 100%")
        XCTAssertNil(tracker.apply(.init(kind: .remove), at: start))
        XCTAssertNil(tracker.apply(.init(kind: .error), at: start)?.percent)
        XCTAssertEqual(tracker.apply(.init(kind: .set), at: start)?.percent, 0, "A set without a value is 0%")
        XCTAssertEqual(TerminalProgressReport(kind: .set, value: 250).value, 100)
        XCTAssertEqual(TerminalProgressReport(kind: .set, value: -3).value, 0)
    }

    func testProgressExpiresFifteenSecondsAfterTheLastUpdate() {
        var tracker = PaneProgressTracker()
        XCTAssertNil(tracker.expiresAt)
        tracker.apply(.init(kind: .set, value: 10), at: start)
        tracker.apply(.init(kind: .set, value: 20), at: start.addingTimeInterval(10))
        XCTAssertEqual(tracker.expiresAt, start.addingTimeInterval(25))
        XCTAssertFalse(tracker.expire(at: start.addingTimeInterval(24.9)))
        XCTAssertEqual(tracker.progress?.percent, 20)
        XCTAssertTrue(tracker.expire(at: start.addingTimeInterval(25)))
        XCTAssertNil(tracker.progress)
        XCTAssertNil(tracker.expiresAt)
        XCTAssertFalse(tracker.expire(at: start.addingTimeInterval(100)))
        XCTAssertEqual(tracker.apply(.init(kind: .pause), at: start)?.percent, 100, "Expiry forgets the last value too")
    }

    func testAggregatePrefersErrorThenPauseThenLowestPercentThenIndeterminate() {
        let error = TerminalProgress(state: .error), paused = TerminalProgress(state: .paused, percent: 90)
        let low = TerminalProgress(state: .normal, percent: 20), high = TerminalProgress(state: .normal, percent: 80)
        let unknown = TerminalProgress(state: .indeterminate)
        XCTAssertEqual(TerminalProgress.aggregate([unknown, high, low, paused, error]), error)
        XCTAssertEqual(TerminalProgress.aggregate([unknown, high, paused, low]), paused)
        XCTAssertEqual(TerminalProgress.aggregate([high, unknown, low]), low)
        XCTAssertEqual(TerminalProgress.aggregate([unknown]), unknown)
        XCTAssertNil(TerminalProgress.aggregate([]))
    }

    func testStateIsAlwaysGivenInWords() {
        XCTAssertEqual(TerminalProgress(state: .normal, percent: 50).visibleText, "50%")
        XCTAssertEqual(TerminalProgress(state: .paused, percent: 50).visibleText, "Paused 50%")
        XCTAssertEqual(TerminalProgress(state: .error, percent: 50).visibleText, "Error")
        XCTAssertEqual(TerminalProgress(state: .indeterminate).visibleText, "Working")
        XCTAssertEqual(TerminalProgress(state: .normal, percent: 50).spokenText, "progress 50 percent")
        XCTAssertEqual(TerminalProgress(state: .paused, percent: 50).spokenText, "progress paused at 50 percent")
        XCTAssertEqual(TerminalProgress(state: .error).spokenText, "progress error")
        XCTAssertEqual(TerminalProgress(state: .indeterminate).spokenText, "progress, amount unknown")
    }

    func testPaneAccessibilityValueSpeaksProgress() {
        var snapshot = WorkspaceSnapshot()
        let windowID = UUID(), tabID = UUID(), paneID = UUID(), sessionID = UUID()
        snapshot.windows = [ManagedWindow(id: windowID, name: "W", tabIDs: [tabID], activeTabID: tabID)]
        snapshot.activeWindowID = windowID
        snapshot.tabs[tabID] = WorkspaceTab(id: tabID, windowID: windowID, title: "T", root: .pane(paneID), activePaneID: paneID)
        snapshot.panes[paneID] = WorkspacePane(id: paneID, tabID: tabID, sessionID: sessionID)
        let live = [paneID: WorkspaceAccessibility.LiveSession(state: .running, progress: TerminalProgress(state: .normal, percent: 40))]
        XCTAssertEqual(WorkspaceAccessibility(snapshot: snapshot, live: live).panes.first?.value, "Running, progress 40 percent")
    }
}
