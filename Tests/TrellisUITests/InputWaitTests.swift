import AppKit
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// FR-T06: the terminal's signals are driven directly; real PTY detection is covered in TrellisTerminalTests.
final class InputWaitTests: XCTestCase {
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
        XCTAssertEqual(h.model.presentation.activePane?.id, paneA)
        return (a, b, paneA, paneB)
    }

    @MainActor
    private func cleanUp(_ h: Harness) {
        h.model.terminals.values.forEach {
            $0.requestTermination(force: true); $0.adapter.detach()
        }
    }

    @MainActor
    func testBellInBackgroundTabLabelsItUntilTheTabIsShown() async throws {
        let h = try Harness()
        defer { cleanUp(h) }
        try await h.grant("full")
        let t = try await makeTabs(h)
        h.model.terminals[t.paneB]?.onAttentionRequested?()
        XCTAssertEqual(h.model.inputWait(tabID: t.b), .attention)
        XCTAssertNil(h.model.inputWait(tabID: t.a))
        XCTAssertEqual(h.model.windowsNeedingInput, [try XCTUnwrap(h.model.snapshot.activeWindowID)])
        XCTAssertTrue(h.model.accessibility.windows.first?.value.contains("waiting for input") == true)

        let session = try XCTUnwrap(h.model.terminals[t.paneB]?.sessionID)
        let reported = try result(try await h.call("session.get", ["id": session.uuidString]))
        XCTAssertEqual(reported["waitingForInput"] as? String, "attention")

        await h.model.selectTab(t.b)
        XCTAssertNil(h.model.inputWait(tabID: t.b), "Showing the pane answers the bell")
        XCTAssertTrue(h.model.windowsNeedingInput.isEmpty)
        let cleared = try result(try await h.call("session.get", ["id": session.uuidString]))
        XCTAssertNil(cleared["waitingForInput"])
    }

    @MainActor
    func testBellInTheFocusedPaneOrAtTheShellPromptIsIgnored() async throws {
        let h = try Harness()
        defer { cleanUp(h) }
        let t = try await makeTabs(h)
        h.model.terminals[t.paneA]?.onAttentionRequested?()
        XCTAssertNil(h.model.inputWait(tabID: t.a))

        let terminal = try XCTUnwrap(h.model.terminals[t.paneB])
        terminal.onShellIntegrationEvent?(.promptStart(directory: nil))
        terminal.onAttentionRequested?()
        terminal.onPasswordPromptChanged?(true)
        XCTAssertNil(h.model.inputWait(tabID: t.b), "A completion bell or the user's own stty -echo at the prompt never counts")

        terminal.onShellIntegrationEvent?(.commandStart(commandLine: "claude"))
        terminal.onAttentionRequested?()
        XCTAssertEqual(h.model.inputWait(tabID: t.b), .attention)
        terminal.onShellIntegrationEvent?(.promptStart(directory: nil))
        XCTAssertNil(h.model.inputWait(tabID: t.b), "The next prompt means the program that asked is gone")
    }

    @MainActor
    func testPasswordPromptShowsEvenWhenFocusedAndOutranksABell() async throws {
        let h = try Harness()
        defer { cleanUp(h) }
        let t = try await makeTabs(h)
        let terminal = try XCTUnwrap(h.model.terminals[t.paneA])
        terminal.onPasswordPromptChanged?(true)
        XCTAssertEqual(h.model.inputWait(tabID: t.a), .password)
        XCTAssertTrue(h.model.accessibility.panes.first { $0.id == t.paneA }?.value.contains("Waiting for a password") == true)
        await h.model.selectTab(t.b)
        await h.model.selectTab(t.a)
        XCTAssertEqual(h.model.inputWait(tabID: t.a), .password, "Looking at a password prompt doesn't answer it")
        await h.model.selectTab(t.b)
        terminal.onAttentionRequested?()
        XCTAssertEqual(h.model.inputWait(tabID: t.a), .password)
        terminal.onPasswordPromptChanged?(false)
        XCTAssertNil(h.model.inputWait(tabID: t.a))
    }

    @MainActor
    func testClosingOrExitingThePaneDropsItsWait() async throws {
        let h = try Harness()
        defer { cleanUp(h) }
        let t = try await makeTabs(h)
        let terminal = try XCTUnwrap(h.model.terminals[t.paneB])
        terminal.onPasswordPromptChanged?(true)
        XCTAssertEqual(h.model.inputWaits[t.paneB], .password)
        terminal.requestTermination(force: true)
        let deadline = Date().addingTimeInterval(5)
        while h.model.inputWaits[t.paneB] != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(h.model.inputWaits[t.paneB])

        h.model.terminals[t.paneA]?.onPasswordPromptChanged?(true)
        h.model.confirmCloseSessions = { _ in true }
        await h.model.closeTab(t.a)
        let closed = Date().addingTimeInterval(5)
        while h.model.snapshot.tabs[t.a] != nil, Date() < closed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(h.model.inputWaits[t.paneA])
    }
}
