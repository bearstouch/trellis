import AppKit
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// FR-T09: the terminal's progress reports are driven directly; OSC parsing is covered in TrellisTerminalTests.
final class TabProgressTests: XCTestCase {
    /// A window with two tabs running `sleep`; tab A (the first) ends up selected.
    @MainActor
    private func makeTabs(_ h: Harness) async throws -> (a: UUID, b: UUID, paneA: UUID, paneB: UUID) {
        let created = await h.model.createWindow(name: "W", startSession: false)
        let windowID = try XCTUnwrap(created)
        let a = try XCTUnwrap(h.model.presentation.selectedTab?.id)
        let tab = await h.model.createTab(windowID: windowID, startSessions: false)
        let b = try XCTUnwrap(tab)
        let paneA = try XCTUnwrap(h.model.snapshot.tabs[a]?.activePaneID), paneB = try XCTUnwrap(h.model.snapshot.tabs[b]?.activePaneID)
        for pane in [paneA, paneB] {
            _ = try await h.model.service.execute(
                .configureStoppedSession(paneID: pane, launch: .process(executable: "/bin/sleep", arguments: ["30"], directory: "/tmp")))
            await h.model.refresh()
            await h.model.start(paneID: pane)
        }
        await h.model.selectTab(a)
        return (a, b, paneA, paneB)
    }

    @MainActor
    private func cleanUp(_ h: Harness) {
        h.model.terminals.values.forEach {
            $0.requestTermination(force: true); $0.adapter.detach()
        }
    }

    @MainActor
    private func report(_ h: Harness, _ pane: UUID, _ kind: TerminalProgressReport.Kind, _ value: Int? = nil) throws {
        try XCTUnwrap(h.model.terminals[pane]?.onProgress)(TerminalProgressReport(kind: kind, value: value))
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    @MainActor
    func testProgressShowsOnTheTabAndPaneButNeverLabelsInput() async throws {
        let h = try Harness()
        defer { cleanUp(h) }
        try await h.grant("full")
        let t = try await makeTabs(h)
        try report(h, t.paneB, .set, 50)
        XCTAssertEqual(h.model.progress(tabID: t.b), TerminalProgress(state: .normal, percent: 50))
        XCTAssertNil(h.model.progress(tabID: t.a))
        XCTAssertNil(h.model.inputWait(tabID: t.b), "Progress is not a request for input")
        XCTAssertTrue(h.model.windowsNeedingInput.isEmpty)
        let windowID = try XCTUnwrap(h.model.snapshot.activeWindowID)
        XCTAssertEqual(h.model.tabPreviews(windowID: windowID).map(\.progress), [nil, TerminalProgress(state: .normal, percent: 50)])

        let session = try XCTUnwrap(h.model.terminals[t.paneB]?.sessionID)
        let reported = try result(try await h.call("session.get", ["id": session.uuidString]))
        let progress = try XCTUnwrap(reported["progress"] as? [String: Any])
        XCTAssertEqual(progress["state"] as? String, "normal")
        XCTAssertEqual(progress["percent"] as? Double, 50)
        XCTAssertNil(reported["waitingForInput"])

        try report(h, t.paneB, .indeterminate)
        let indeterminate = try result(try await h.call("session.get", ["id": session.uuidString]))
        let unknown = try XCTUnwrap(indeterminate["progress"] as? [String: Any])
        XCTAssertEqual(unknown["state"] as? String, "indeterminate")
        XCTAssertNil(unknown["percent"], "Indeterminate progress has no percentage")

        await h.model.selectTab(t.b)
        XCTAssertNotNil(h.model.progress(tabID: t.b), "Looking at the tab doesn't clear progress")
        try report(h, t.paneB, .pause)
        XCTAssertTrue(h.model.accessibility.panes.first { $0.id == t.paneB }?.value.contains("progress paused at 50 percent") == true)
        try report(h, t.paneB, .remove)
        XCTAssertNil(h.model.progress(tabID: t.b))
        let removed = try result(try await h.call("session.get", ["id": session.uuidString]))
        XCTAssertNil(removed["progress"])
    }

    @MainActor
    func testTabShowsTheMostUrgentPane() async throws {
        let h = try Harness()
        defer { cleanUp(h) }
        let t = try await makeTabs(h)
        let split = await h.model.splitPane(t.paneA, axis: .x, startSession: false)
        let other = try XCTUnwrap(split)
        try report(h, t.paneA, .set, 80)
        try report(h, other, .set, 30)
        XCTAssertEqual(h.model.progress(tabID: t.a)?.percent, 30, "The lowest percentage")
        try report(h, t.paneA, .pause, 90)
        XCTAssertEqual(h.model.progress(tabID: t.a)?.state, .paused)
        try report(h, other, .error)
        XCTAssertEqual(h.model.progress(tabID: t.a), TerminalProgress(state: .error, percent: 30))
        XCTAssertEqual(h.model.progress(tabID: t.a)?.visibleText, "Error")
    }

    @MainActor
    func testProgressClearsAtThePromptOnExitRestartAndClose() async throws {
        let h = try Harness()
        defer { cleanUp(h) }
        let t = try await makeTabs(h)
        let terminal = try XCTUnwrap(h.model.terminals[t.paneB])
        try report(h, t.paneB, .set, 40)
        terminal.onShellIntegrationEvent?(.promptStart(directory: nil))
        XCTAssertNil(h.model.progress[t.paneB], "The next prompt means the program that reported is gone")

        try report(h, t.paneB, .set, 40)
        terminal.requestTermination(force: true)
        try await waitUntil { h.model.progress[t.paneB] == nil }
        XCTAssertNil(h.model.progress[t.paneB], "Exit clears progress")

        try await waitUntil { terminal.sessionState == .exited || terminal.sessionState == .failed }
        terminal.onProgress?(TerminalProgressReport(kind: .set, value: 60))
        XCTAssertEqual(h.model.progress[t.paneB]?.percent, 60)
        await h.model.restartPane(t.paneB, startSession: false)
        XCTAssertNotIdentical(h.model.terminals[t.paneB], terminal)
        XCTAssertNil(h.model.progress[t.paneB], "Restart clears progress")
        terminal.onProgress?(TerminalProgressReport(kind: .set, value: 70))
        XCTAssertNil(h.model.progress[t.paneB], "A replaced terminal can't report")

        try report(h, t.paneA, .set, 10)
        h.model.confirmCloseSessions = { _ in true }
        await h.model.closeTab(t.a)
        try await waitUntil { h.model.snapshot.tabs[t.a] == nil }
        XCTAssertNil(h.model.progress[t.paneA], "Closing the pane drops its progress")
    }

    @MainActor
    func testProgressExpiresFifteenSecondsAfterTheLastUpdate() async throws {
        let h = try Harness()
        defer { cleanUp(h) }
        var now = Date(timeIntervalSince1970: 1000)
        h.model.activityNow = { now }
        let sleeps = SleepLog()
        h.model.activitySleep = { delay in
            sleeps.delays.append(delay); try? await Task.sleep(for: .milliseconds(10))
        }
        let t = try await makeTabs(h)
        try report(h, t.paneB, .set, 20)
        try report(h, t.paneA, .indeterminate)
        try await waitUntil { !sleeps.delays.isEmpty }
        XCTAssertEqual(sleeps.delays.first, PaneProgressTracker.staleInterval, "One task sleeps to the earliest deadline")
        now.addTimeInterval(10)
        try report(h, t.paneB, .set, 30)
        now.addTimeInterval(5)
        try await waitUntil { h.model.progress[t.paneA] == nil }
        XCTAssertNil(h.model.progress[t.paneA])
        XCTAssertEqual(h.model.progress[t.paneB]?.percent, 30, "An update restarts the pane's 15 s")
        now.addTimeInterval(10)
        try await waitUntil { h.model.progress.isEmpty }
        XCTAssertTrue(h.model.progress.isEmpty)
    }
}

@MainActor private final class SleepLog { var delays: [TimeInterval] = [] }
