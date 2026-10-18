import AppKit
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

@MainActor
private final class RecordingNotifier: DesktopNotifier {
    var posted: [DesktopNotification] = []
    func post(_ notification: DesktopNotification) { posted.append(notification) }
}

/// FR-T08: the terminal's notification callback is driven directly; OSC parsing is covered in Core and Terminal tests.
final class DesktopNotificationTests: XCTestCase {
    @MainActor
    private func makeTabs(_ h: Harness) async throws -> (a: UUID, b: UUID, paneA: UUID, paneB: UUID) {
        let created = await h.model.createWindow(name: "W", startSession: false)
        let windowID = try XCTUnwrap(created)
        let a = try XCTUnwrap(h.model.presentation.selectedTab?.id)
        let tab = await h.model.createTab(windowID: windowID, startSessions: false)
        let b = try XCTUnwrap(tab)
        let paneA = try XCTUnwrap(h.model.snapshot.tabs[a]?.activePaneID), paneB = try XCTUnwrap(h.model.snapshot.tabs[b]?.activePaneID)
        await h.model.selectTab(a)
        return (a, b, paneA, paneB)
    }

    @MainActor
    private func notify(_ h: Harness, _ pane: UUID, title: String = "", body: String = "Done", occasion: TerminalNotification.Occasion = .unfocused) throws {
        try XCTUnwrap(h.model.terminals[pane]).onNotification?(XCTUnwrap(TerminalNotification(title: title, body: body, occasion: occasion)))
    }

    @MainActor
    private func setUp(_ h: Harness, frontmost: Bool = true) -> RecordingNotifier {
        let notifier = RecordingNotifier()
        h.model.desktopNotifier = notifier
        h.model.workspaceIsFrontmost = { frontmost }
        return notifier
    }

    @MainActor
    func testNotificationFromAPaneOutOfViewIsPostedWithItsPaneTitleAsFallback() async throws {
        let h = try Harness()
        let notifier = setUp(h)
        let t = try await makeTabs(h)
        try notify(h, t.paneB, body: "Build done")
        try notify(h, t.paneB, title: "Claude", body: "Needs approval")
        XCTAssertEqual(
            notifier.posted,
            [
                DesktopNotification(paneID: t.paneB, title: h.model.paneTitle(t.paneB), body: "Build done"),
                DesktopNotification(paneID: t.paneB, title: "Claude", body: "Needs approval")
            ])
    }

    @MainActor
    func testTheFocusedPaneNotifiesOnlyWhenTrellisIsInTheBackgroundOrAsked() async throws {
        let h = try Harness()
        var frontmost = true
        let notifier = setUp(h)
        h.model.workspaceIsFrontmost = { frontmost }
        let t = try await makeTabs(h)
        try notify(h, t.paneA)
        XCTAssertTrue(notifier.posted.isEmpty, "The user is looking at the pane")
        try notify(h, t.paneA, occasion: .always)
        XCTAssertEqual(notifier.posted.count, 1, "OSC 99 o=always shows even in view")
        frontmost = false
        try notify(h, t.paneA)
        XCTAssertEqual(notifier.posted.count, 2, "Trellis isn't the key window")
    }

    @MainActor
    func testInvisibleOccasionSkipsAVisibleButUnfocusedPane() async throws {
        let h = try Harness()
        let notifier = setUp(h)
        let t = try await makeTabs(h)
        let split = await h.model.splitPane(t.paneA, axis: .x, startSession: false)
        let second = try XCTUnwrap(split)
        _ = await h.model.selectPane(second)
        try notify(h, t.paneA, occasion: .invisible)
        XCTAssertTrue(notifier.posted.isEmpty, "The pane is on screen")
        try notify(h, t.paneA)
        XCTAssertEqual(notifier.posted.count, 1, "Unfocused is enough for the default occasion")
        await h.model.toggleMaximize(second)
        try notify(h, t.paneA, occasion: .invisible)
        XCTAssertEqual(notifier.posted.count, 2, "Hidden behind a maximized pane")
        try notify(h, t.paneB, occasion: .invisible)
        XCTAssertEqual(notifier.posted.count, 3)
        await h.model.toggleMaximize(second)
        var visible = true
        h.model.workspaceIsFrontmost = { false }
        h.model.workspaceIsVisible = { visible }
        try notify(h, t.paneA, occasion: .invisible)
        XCTAssertEqual(notifier.posted.count, 3, "Another app is key, but the pane is still on screen")
        visible = false
        try notify(h, t.paneA, occasion: .invisible)
        XCTAssertEqual(notifier.posted.count, 4, "The window is hidden, minimized or covered")
    }

    @MainActor
    func testTurningNotificationsOffPostsNothingButKeepsTheAttentionLabel() async throws {
        let h = try Harness()
        let notifier = setUp(h)
        let t = try await makeTabs(h)
        var settings = h.model.appearance
        settings.desktopNotifications = false
        XCTAssertTrue(h.model.applyAppearance(settings))
        try notify(h, t.paneB, occasion: .always)
        h.model.terminals[t.paneB]?.onAttentionRequested?()
        XCTAssertTrue(notifier.posted.isEmpty)
        XCTAssertEqual(h.model.inputWait(tabID: t.b), .attention)
        settings.desktopNotifications = true
        XCTAssertTrue(h.model.applyAppearance(settings))
        try notify(h, t.paneB)
        XCTAssertEqual(notifier.posted.count, 1)
    }

    @MainActor
    func testShellPromptAndFloodsAreSuppressed() async throws {
        let h = try Harness()
        let notifier = setUp(h)
        var now = Date(timeIntervalSince1970: 1000)
        h.model.activityNow = { now }
        let t = try await makeTabs(h)
        let terminal = try XCTUnwrap(h.model.terminals[t.paneB])
        terminal.onShellIntegrationEvent?(.promptStart(directory: nil))
        try notify(h, t.paneB)
        XCTAssertTrue(notifier.posted.isEmpty, "Nothing posts while the shell is at its own prompt")
        terminal.onShellIntegrationEvent?(.commandStart(commandLine: "make"))
        for _ in 0..<20 { try notify(h, t.paneB) }
        XCTAssertEqual(notifier.posted.count, NotificationRateLimiter().limit)
        now.addTimeInterval(11)
        try notify(h, t.paneB)
        XCTAssertEqual(notifier.posted.count, NotificationRateLimiter().limit + 1)
    }

    /// FR-SI08: runs `line` for `seconds` of injected time in the pane through its shell-integration callback.
    @MainActor
    private func run(_ h: Harness, _ pane: UUID, _ line: String?, for seconds: TimeInterval, exit: Int32? = 0, advance: (TimeInterval) -> Void) throws {
        let terminal = try XCTUnwrap(h.model.terminals[pane])
        terminal.onShellIntegrationEvent?(.commandStart(commandLine: line))
        advance(seconds)
        terminal.onShellIntegrationEvent?(.commandFinished(exitCode: exit))
        terminal.onShellIntegrationEvent?(.promptStart(directory: nil))
    }

    @MainActor
    func testLongCommandOutOfViewNotifiesWithItsProgramNameAndDurationOnly() async throws {
        let h = try Harness()
        let notifier = setUp(h)
        var now = Date(timeIntervalSince1970: 1000)
        h.model.activityNow = { now }
        let t = try await makeTabs(h)
        try run(h, t.paneB, "TOKEN=s3cret /usr/bin/make release --password hunter2", for: 12, advance: { now.addTimeInterval($0) })
        try run(h, t.paneB, "cargo test", for: 75, exit: 101, advance: { now.addTimeInterval($0) })
        XCTAssertEqual(
            notifier.posted,
            [
                DesktopNotification(paneID: t.paneB, title: "Command finished", body: "make ran for 12 s"),
                DesktopNotification(paneID: t.paneB, title: "Command failed (exit 101)", body: "cargo ran for 1 min 15 s")
            ])
        for text in notifier.posted.flatMap({ [$0.title, $0.body] }) {
            for secret in ["s3cret", "release", "hunter2", "TOKEN", "/usr/bin", "test"] { XCTAssertFalse(text.contains(secret), text) }
        }
        XCTAssertNil(h.model.inputWait(tabID: t.b), "A finished command never labels the tab")
        XCTAssertTrue(h.model.inputWaits.isEmpty)
    }

    @MainActor
    func testCommandEndedByAPromptOrWithoutANameStillNotifies() async throws {
        let h = try Harness()
        let notifier = setUp(h)
        var now = Date(timeIntervalSince1970: 1000)
        h.model.activityNow = { now }
        let t = try await makeTabs(h)
        let terminal = try XCTUnwrap(h.model.terminals[t.paneB])
        terminal.onShellIntegrationEvent?(.commandStart(commandLine: "ssh build-box"))
        now.addTimeInterval(30)
        terminal.onShellIntegrationEvent?(.promptStart(directory: nil))
        try run(h, t.paneB, nil, for: 10, advance: { now.addTimeInterval($0) })
        XCTAssertEqual(
            notifier.posted,
            [
                DesktopNotification(paneID: t.paneB, title: "Command finished", body: "ssh ran for 30 s"),
                DesktopNotification(paneID: t.paneB, title: "Command finished", body: "\(h.model.paneTitle(t.paneB)) ran for 10 s")
            ])
    }

    @MainActor
    func testCommandFinishedRespectsThresholdFocusAndSettings() async throws {
        let h = try Harness()
        var frontmost = true
        let notifier = setUp(h)
        h.model.workspaceIsFrontmost = { frontmost }
        var now = Date(timeIntervalSince1970: 1000)
        h.model.activityNow = { now }
        let t = try await makeTabs(h)
        try run(h, t.paneB, "make", for: 9.9, advance: { now.addTimeInterval($0) })
        XCTAssertTrue(notifier.posted.isEmpty, "Shorter than the 10 s default")
        try run(h, t.paneA, "make", for: 60, advance: { now.addTimeInterval($0) })
        XCTAssertTrue(notifier.posted.isEmpty, "The user is looking at the pane")
        frontmost = false
        try run(h, t.paneA, "make", for: 60, advance: { now.addTimeInterval($0) })
        XCTAssertEqual(notifier.posted.count, 1, "Trellis isn't the key window")
        var settings = h.model.appearance
        settings.commandFinishedNotificationSeconds = 30
        XCTAssertTrue(h.model.applyAppearance(settings))
        try run(h, t.paneB, "make", for: 20, advance: { now.addTimeInterval($0) })
        XCTAssertEqual(notifier.posted.count, 1, "Below the chosen threshold")
        settings.commandFinishedNotificationSeconds = 0
        XCTAssertTrue(h.model.applyAppearance(settings))
        try run(h, t.paneB, "make", for: 600, advance: { now.addTimeInterval($0) })
        XCTAssertEqual(notifier.posted.count, 1, "Off")
        settings.commandFinishedNotificationSeconds = 5; settings.desktopNotifications = false
        XCTAssertTrue(h.model.applyAppearance(settings))
        try run(h, t.paneB, "make", for: 600, advance: { now.addTimeInterval($0) })
        XCTAssertEqual(notifier.posted.count, 1, "Desktop notifications are off")
        settings.desktopNotifications = true
        XCTAssertTrue(h.model.applyAppearance(settings))
        try run(h, t.paneB, "make", for: 5, advance: { now.addTimeInterval($0) })
        XCTAssertEqual(notifier.posted.count, 2)
    }

    @MainActor
    func testCommandFinishedSharesThePaneRateLimit() async throws {
        let h = try Harness()
        let notifier = setUp(h)
        var now = Date(timeIntervalSince1970: 1000)
        h.model.activityNow = { now }
        let t = try await makeTabs(h)
        var settings = h.model.appearance
        settings.commandFinishedNotificationSeconds = 5
        XCTAssertTrue(h.model.applyAppearance(settings))
        let terminal = try XCTUnwrap(h.model.terminals[t.paneB])
        terminal.onShellIntegrationEvent?(.commandStart(commandLine: "make"))
        for _ in 0..<NotificationRateLimiter().limit { try notify(h, t.paneB) }
        now.addTimeInterval(6)
        terminal.onShellIntegrationEvent?(.commandFinished(exitCode: 0))
        XCTAssertEqual(notifier.posted.count, NotificationRateLimiter().limit, "OSC notifications used up this pane's allowance")
        try run(h, t.paneB, "make", for: 5, advance: { now.addTimeInterval($0) })
        XCTAssertEqual(notifier.posted.count, NotificationRateLimiter().limit + 1, "The window has passed")
        XCTAssertEqual(notifier.posted.last, DesktopNotification(paneID: t.paneB, title: "Command finished", body: "make ran for 5 s"))
    }

    @MainActor
    func testRevealPaneSelectsItsWindowTabAndPane() async throws {
        let h = try Harness()
        let t = try await makeTabs(h)
        let other = await h.model.createWindow(name: "Other", startSession: false)
        XCTAssertEqual(h.model.snapshot.activeWindowID, other)
        await h.model.revealPane(t.paneB)
        XCTAssertEqual(h.model.presentation.selectedTab?.id, t.b)
        XCTAssertEqual(h.model.presentation.activePane?.id, t.paneB)
        await h.model.revealPane(UUID())
        XCTAssertEqual(h.model.presentation.activePane?.id, t.paneB, "An unknown or closed pane changes nothing")
    }
}
