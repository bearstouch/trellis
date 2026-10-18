import AppKit
import XCTest
import SwiftTerm
import TrellisCore
@testable import TrellisTerminal

final class NativeTerminalTests: XCTestCase {
    @MainActor
    func testEngineRendersUnicodeAndAlternateScreen() async throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        native.adapter.receive(Data("hello café 漢字 👋\r\n".utf8))
        XCTAssertTrue(try native.adapter.read(.retainedText).contains("hello café 漢字 👋"))
        native.adapter.receive(Data("\u{1b}[?1049hhidden alternate\u{1b}[?1049l".utf8))
        let text = try native.adapter.read(.retainedText)
        XCTAssertTrue(text.contains("hello café 漢字 👋"))
        XCTAssertFalse(text.contains("hidden alternate"))
        native.adapter.detach()
    }

    @MainActor
    func testAccessibilityReadsRealTextAndUTF16Ranges() async throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        native.adapter.receive(Data("hello 👋\r\nsecond line".utf8))
        let surface = try XCTUnwrap(native.view as? AccessibleTerminalView)
        XCTAssertTrue(surface.isAccessibilityElement())
        XCTAssertEqual(surface.accessibilityRole(), .textArea)
        XCTAssertTrue((surface.accessibilityValue() as? String)?.contains("hello 👋") == true)
        XCTAssertEqual(surface.accessibilityString(for: NSRange(location: 6, length: 2)), "👋")
        XCTAssertEqual(surface.accessibilityString(for: surface.accessibilityRange(forLine: 1)), "second line")
        XCTAssertNil(surface.accessibilityString(for: NSRange(location: NSNotFound, length: 2)))
        XCTAssertEqual(surface.accessibilityRange(forLine: -1).location, NSNotFound)
        native.adapter.detach()
    }

    @MainActor
    func testNativeSelectionRangeMatchesRetainedText() async throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        native.adapter.receive(Data("first 👋\r\nsecond".utf8))
        let surface = try XCTUnwrap(native.view as? AccessibleTerminalView)
        surface.selectAll(nil)
        let selected = surface.accessibilitySelectedText()
        let range = surface.accessibilitySelectedTextRange()
        XCTAssertNotEqual(range.location, NSNotFound)
        XCTAssertEqual(surface.accessibilityString(for: range), selected)
        XCTAssertTrue(selected?.contains("first 👋") == true)
        native.adapter.detach()
    }

    @MainActor
    func testIMECompositionSendsOnlyCommittedText() async throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        let surface = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let input = InputObserver()
        surface.terminalDelegate = input
        surface.setMarkedText(
            "漢", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(input.received, Data())
        surface.insertText("漢字", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(input.received, Data("漢字".utf8))
        native.adapter.detach()
    }

    @MainActor
    func testTerminalOriginatedClipboardIsDenied() async throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        let surface = try XCTUnwrap(native.view as? AccessibleTerminalView)
        XCTAssertNil(native.clipboardRead(source: surface))
        // No pasteboard fixture is needed: these callbacks have no pasteboard access.
        native.clipboardCopy(source: surface, content: Data("untrusted".utf8))
        native.adapter.detach()
    }

    @MainActor
    func testRealPTYFixtureProducesOutputAndExitCode() async throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        let exited = expectation(description: "fixture exits")
        var exitCode: Int32?
        native.onExit = { code in
            exitCode = code; exited.fulfill()
        }
        native.start(fixture: true)
        await fulfillment(of: [exited], timeout: 10)
        // PTY and child-exit notifications are independent; let queued reads drain.
        let deadline = Date().addingTimeInterval(2)
        while !(try native.adapter.read(.retainedText)).contains("Fixture complete"), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let output = try native.adapter.read(.retainedText)
        XCTAssertTrue(output.contains("PTY ready"), output)
        XCTAssertTrue(output.contains("café 漢字 👋"), output)
        XCTAssertTrue(output.contains("Fixture complete"), output)
        XCTAssertEqual(exitCode, 7)
        XCTAssertFalse(native.isRunning)
        native.adapter.detach()
    }

    @MainActor
    func testBellAndNotificationsRequestAttentionButProgressDoesNot() async throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        var count = 0, reports: [TerminalProgressReport] = []
        native.onAttentionRequested = { count += 1 }
        native.onProgress = { reports.append($0) }
        for (bytes, expected) in [
            ("\u{07}", 1), ("\u{1b}]9;Build done\u{07}", 1), ("\u{1b}]777;notify;Title;Body\u{07}", 1), ("\u{1b}]9;3 tests failed\u{07}", 1),
            ("\u{1b}]9;4;1;50\u{07}", 0), ("\u{1b}]9;1\u{07}", 0), ("\u{1b}]777;other;x\u{07}", 0), ("plain text", 0)
        ] {
            count = 0
            native.adapter.receive(Data(bytes.utf8))
            XCTAssertEqual(count, expected, bytes.debugDescription)
        }
        XCTAssertFalse(try native.adapter.read(.retainedText).contains("Build done"), "Notification text is not printed")
        XCTAssertEqual(reports, [TerminalProgressReport(kind: .set, value: 50)], "9;4 progress reaches only onProgress")
        native.adapter.receive(Data("\u{1b}]9;4;2\u{07}\u{1b}]9;4;3;\u{07}\u{1b}]9;4;4;250\u{07}\u{1b}]9;4;0\u{07}\u{1b}]9;4;9\u{07}".utf8))
        XCTAssertEqual(
            reports.dropFirst(), [.init(kind: .error), .init(kind: .indeterminate), .init(kind: .pause, value: 100), .init(kind: .remove)],
            "Unknown states are dropped, values clamped")
        XCTAssertEqual(count, 0)
        // Trellis draws progress on the tab and pane (FR-T09); the engine's own bar never shows.
        native.adapter.receive(Data("\u{1b}]9;4;1;50\u{07}".utf8))
        let bar = native.view.subviews.first { String(describing: type(of: $0)).contains("ProgressBar") }
        XCTAssertNotEqual(bar?.isHidden, false, "The engine's progress bar stays hidden")
    }

    @MainActor
    func testRemoteShellMarksAreObservedOnlyWhenChosen() throws {
        _ = NSApplication.shared
        let marks =
            "\u{1b}]133;A\u{07}\u{1b}]7;file://web/srv/app\u{07}\u{1b}]1337;CurrentDir=/srv\u{07}\u{1b}]1337;RemoteHost=u@web\u{07}"
            + "\u{1b}]133;C\u{07}\u{1b}]133;D;2\u{07}"
        let local = NativeTerminal()
        defer { local.adapter.detach() }
        var localEvents: [ShellIntegrationEvent] = []
        local.onShellIntegrationEvent = { localEvents.append($0) }
        local.adapter.receive(Data(marks.utf8))
        XCTAssertEqual(localEvents, [], "Without a choice, nonce-less marks change nothing")
        XCTAssertNil(local.shellMarkOrigin)

        let remote = NativeTerminal()
        defer { remote.adapter.detach() }
        var events: [ShellIntegrationEvent] = []
        remote.onShellIntegrationEvent = { events.append($0) }
        remote.observeRemoteShellMarks()
        XCTAssertEqual(remote.shellMarkOrigin, .remote)
        remote.adapter.receive(Data(marks.utf8))
        XCTAssertEqual(
            events,
            [
                .promptStart(directory: nil), .reportedDirectory("/srv/app", host: "web"), .reportedDirectory("/srv", host: nil), .reportedHost("web"),
                .commandStart(commandLine: nil), .commandFinished(exitCode: 2)
            ])
        XCTAssertFalse(try remote.adapter.read(.retainedText).contains("srv"), "Marks are never printed")
    }

    @MainActor
    func testNotificationTextReachesOnlyTheNotificationCallback() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        var posted: [TerminalNotification] = [], attention = 0, replies = 0
        native.onNotification = { posted.append($0) }
        native.onAttentionRequested = { attention += 1 }
        native.onInput = { replies += 1 }
        native.adapter.receive(Data("\u{1b}]9;Build done\u{07}\u{1b}]777;notify;Claude;Needs approval\u{07}".utf8))
        native.adapter.receive(Data("\u{1b}]99;i=1:d=0;Tests\u{1b}\\\u{1b}]99;i=1:p=body;All passed\u{1b}\\\u{1b}]9;4;1;50\u{07}".utf8))
        XCTAssertEqual(posted.map(\.title), ["", "Claude", "Tests"])
        XCTAssertEqual(posted.map(\.body), ["Build done", "Needs approval", "All passed"])
        XCTAssertEqual(attention, 3, "A finished OSC 99 notification labels the tab like OSC 9 and 777; its first chunk doesn't")
        XCTAssertEqual(replies, 0)
        native.adapter.receive(Data("\u{1b}]99;i=q:p=?;\u{1b}\\".utf8))
        XCTAssertEqual(replies, 1, "A p=? query is answered through the PTY")
        XCTAssertEqual(posted.count, 3)
        let text = try native.adapter.read(.retainedText)
        for part in ["Build done", "Needs approval", "All passed", "Tests"] { XCTAssertFalse(text.contains(part), part) }
    }

    @MainActor
    func testEchoOffWithLineEditingIsReportedAsAPasswordPrompt() async throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.requestTermination(force: true); native.adapter.detach() }
        var changes: [Bool] = []
        native.onPasswordPromptChanged = { changes.append($0) }
        native.start(arguments: ["-f", "-c", "stty -echo; printf 'Password:'; sleep 1; stty echo; printf '\\n'; stty -echo -icanon; printf 'raw'; sleep 1"])
        let deadline = Date().addingTimeInterval(8)
        while changes != [true, false], Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(changes, [true, false])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(changes, [true, false], "Raw mode (a line editor or full-screen program) is never a password prompt")
    }
}

@MainActor
private final class InputObserver: NSObject, @preconcurrency TerminalViewDelegate {
    var received = Data()
    func send(source: TerminalView, data: ArraySlice<UInt8>) { received.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
