import XCTest
@testable import TrellisUI

final class PaneOutputActivityTests: XCTestCase {
    private let pane = UUID()
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    func testEchoAfterKeystrokeIsIgnoredWithoutIntegration() {
        var activity = PaneOutputActivity()
        activity.recordInput(pane, at: start)
        XCTAssertFalse(activity.recordOutput(pane, at: start.addingTimeInterval(0.05), commandRunning: nil))
        XCTAssertFalse(activity.isBusy(pane, at: start.addingTimeInterval(0.06)))
        XCTAssertTrue(activity.recordOutput(pane, at: start.addingTimeInterval(0.3), commandRunning: nil))
        XCTAssertTrue(activity.isBusy(pane, at: start.addingTimeInterval(0.4)))
    }

    func testPromptOutputIsIgnoredWithIntegration() {
        var activity = PaneOutputActivity()
        XCTAssertFalse(activity.recordOutput(pane, at: start, commandRunning: false))
        XCTAssertFalse(activity.isBusy(pane, at: start))
    }

    func testRunningCommandOutputCountsButEchoDoesNot() {
        var activity = PaneOutputActivity()
        XCTAssertTrue(activity.recordOutput(pane, at: start, commandRunning: true))
        XCTAssertTrue(activity.isBusy(pane, at: start))
        activity.settle(pane)
        activity.recordInput(pane, at: start.addingTimeInterval(1))
        XCTAssertFalse(activity.recordOutput(pane, at: start.addingTimeInterval(1.1), commandRunning: true), "An interactive program redrawing a keystroke is not busy")
    }

    func testPaneGoesQuietAfterInterval() {
        var activity = PaneOutputActivity()
        activity.recordOutput(pane, at: start, commandRunning: nil)
        XCTAssertTrue(activity.isBusy(pane, at: start.addingTimeInterval(PaneOutputActivity.quietInterval - 0.01)))
        XCTAssertFalse(activity.isBusy(pane, at: start.addingTimeInterval(PaneOutputActivity.quietInterval + 0.01)))
    }

    func testSettleRemoveAndRetainClearState() {
        var activity = PaneOutputActivity()
        let other = UUID()
        activity.recordOutput(pane, at: start, commandRunning: true)
        activity.recordOutput(other, at: start, commandRunning: true)
        activity.settle(pane)
        XCTAssertFalse(activity.isBusy(pane, at: start))
        activity.recordInput(pane, at: start)
        activity.remove(pane)
        XCTAssertTrue(activity.recordOutput(pane, at: start, commandRunning: nil), "Removing a pane forgets its last keystroke")
        activity.retain([pane])
        XCTAssertFalse(activity.isBusy(other, at: start))
        XCTAssertTrue(activity.isBusy(pane, at: start))
    }
}
