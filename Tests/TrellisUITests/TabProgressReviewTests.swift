import AppKit
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// FR-T09: a run of percentage updates redraws the chrome at most every 250 ms per pane; state changes show at once.
final class TabProgressReviewTests: XCTestCase {
    @MainActor private final class FlushGate { var open = false }

    @MainActor
    func testPercentUpdatesWithinTheWindowWaitAndOnlyTheLatestShows() async throws {
        let h = try Harness()
        var now = Date(timeIntervalSince1970: 1000)
        h.model.activityNow = { now }
        let gate = FlushGate()
        // The redraw window's sleep waits for the gate; the 15 s expiry sleeps past the test.
        h.model.activitySleep = { delay in
            if delay == AppWorkspaceModel.progressRedrawInterval {
                while !gate.open { try? await Task.sleep(for: .milliseconds(10)) }
            } else {
                try? await Task.sleep(for: .seconds(60))
            }
        }
        let created = await h.model.createSpace(name: "W", startSession: false)
        _ = try XCTUnwrap(created)
        let tab = try XCTUnwrap(h.model.presentation.selectedTab?.id)
        let pane = try XCTUnwrap(h.model.snapshot.tabs[tab]?.activePaneID)
        _ = try await h.model.service.execute(.configureStoppedSession(paneID: pane, launch: .process(executable: "/bin/sleep", arguments: ["30"], directory: "/tmp")))
        await h.model.refresh()
        await h.model.start(paneID: pane)
        let terminal = try XCTUnwrap(h.model.terminals[pane])
        defer { terminal.requestTermination(force: true); terminal.adapter.detach() }
        func report(_ kind: TerminalProgressReport.Kind, _ value: Int? = nil) throws {
            try XCTUnwrap(terminal.onProgress)(TerminalProgressReport(kind: kind, value: value))
        }

        try report(.set, 10)
        XCTAssertEqual(h.model.progress[pane]?.percent, 10, "Progress that appears shows at once")
        now.addTimeInterval(0.1)
        try report(.set, 20)
        try report(.set, 30)
        XCTAssertEqual(h.model.progress[pane]?.percent, 10, "A new percentage within 250 ms waits")
        XCTAssertEqual(h.model.progress(tabID: tab)?.percent, 10)

        gate.open = true
        let deadline = Date().addingTimeInterval(5)
        while h.model.progress[pane]?.percent != 30, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(h.model.progress[pane]?.percent, 30, "Only the latest shows when the window ends")

        now.addTimeInterval(0.1)
        try report(.set, 40)
        try report(.error)
        XCTAssertEqual(h.model.progress[pane], TerminalProgress(state: .error, percent: 40), "A change of state shows at once, with the latest percentage")
        try report(.remove)
        XCTAssertNil(h.model.progress[pane], "and so does removing it")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(h.model.progress[pane], "A waiting percentage never brings removed progress back")

        try report(.set, 50)
        now.addTimeInterval(1)
        try report(.set, 60)
        XCTAssertEqual(h.model.progress[pane]?.percent, 60, "After a quiet 250 ms an update shows at once")
    }
}
