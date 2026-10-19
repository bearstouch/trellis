import AppKit
import XCTest
import TrellisCore
@testable import TrellisTerminal

@MainActor
final class FakeKeptTransport: TerminalProcessTransport {
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var onInputError: ((Error) -> Void)?
    var onPasswordPromptChanged: ((Bool) -> Void)?
    var isRunning = true
    var passwordPromptActive = false
    var survivesQuit: Bool { true }
    var sent: [Data] = [], signals: [Int32] = [], sizes: [TerminalSize] = [], keepAlive: [Bool] = []
    var delivering = false
    func launch(_ configuration: ValidatedLocalLaunch, size: TerminalSize) async throws -> Int32 { XCTFail("An adopted session never launches"); return 0 }
    func send(_ data: Data) throws { sent.append(data) }
    func resize(_ size: TerminalSize) { sizes.append(size) }
    func signalGroup(_ signal: Int32) { signals.append(signal) }
    func setKeepAlive(_ on: Bool) { keepAlive.append(on) }
    func beginDelivery() { delivering = true }
}

/// FR-R03/FR-R04: replayed and restored output is display only. Nothing it contains may answer the program,
/// ask for attention, notify, report progress, ring or reach the output journal.
final class NativeTerminalReplayTests: XCTestCase {
    private let hostile =
        "\u{1b}[c\u{1b}[>c\u{1b}[6n\u{1b}[5n\u{1b}[?u\u{1b}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1b}\\\u{1b}]1337;ReportCellSize\u{07}"
        + "\u{1b}]99;i=1:p=?;\u{1b}\\\u{07}\u{1b}]9;Build done\u{07}\u{1b}]777;notify;T;B\u{07}\u{1b}]9;4;1;50\u{07}visible text\r\n"

    @MainActor
    func testReplayedQueriesAreNeverAnsweredAndRaiseNothing() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        var attention = 0, notifications = 0, progress = 0, journal = 0, bells = 0
        native.onAttentionRequested = { attention += 1 }
        native.onNotification = { _ in notifications += 1 }
        native.onProgress = { _ in progress += 1 }
        native.onOutputData = { _ in journal += 1 }
        native.playBell = { bells += 1 }
        let transport = FakeKeptTransport()
        let adopted = native.adopt(
            BrokerAdoption(sessionID: native.sessionID, processID: 4242, exitCode: nil, nonce: nil, replay: Data(hostile.utf8), transport: transport))
        XCTAssertTrue(adopted)
        XCTAssertEqual(transport.sent, [], "No reply to a replayed query reaches the program")
        XCTAssertEqual([attention, notifications, progress, journal, bells], [0, 0, 0, 0, 0])
        XCTAssertTrue(try native.adapter.read(.retainedText).contains("visible text"))
        XCTAssertEqual(native.sessionState, .running)
        XCTAssertEqual(native.processID, 4242)
        XCTAssertTrue(transport.delivering, "Live output starts only after the replay")
        XCTAssertFalse(transport.sizes.isEmpty, "The adopted session gets this view's size")
        XCTAssertFalse(native.isReplaying)

        // Live output after the replay behaves normally again.
        transport.onOutput?(Data("\u{1b}[c\u{07}".utf8))
        XCTAssertFalse(transport.sent.isEmpty, "A live query is answered")
        XCTAssertEqual(attention, 1)
        XCTAssertEqual(journal, 1)
    }

    @MainActor
    func testAdoptionRestoresTheNonceAndKeepAliveStopsSignals() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let nonce = String(repeating: "ab", count: 16)
        var events: [ShellIntegrationEvent] = []
        native.onShellIntegrationEvent = { events.append($0) }
        let transport = FakeKeptTransport()
        XCTAssertTrue(native.adopt(BrokerAdoption(sessionID: native.sessionID, processID: 7, exitCode: nil, nonce: nonce, replay: Data(), transport: transport)))
        XCTAssertEqual(native.shellMarkOrigin, .authenticated)
        transport.onOutput?(Data("\u{1b}]133;A;trellis=\(nonce)\u{07}\u{1b}]133;A\u{07}".utf8))
        XCTAssertEqual(events, [.promptStart(directory: nil)], "Only marks with the session's nonce count")
        XCTAssertTrue(native.survivesQuit)
        native.prepareForKeepRunning()
        XCTAssertEqual(transport.keepAlive, [true])
        native.prepareForKeepRunning(false)
        XCTAssertEqual(transport.keepAlive, [true, false])
        native.requestTermination(force: false)
        XCTAssertEqual(transport.signals, [SIGHUP])
        transport.onExit?(129)
        XCTAssertEqual(native.sessionState, .exited)
        XCTAssertFalse(native.adopt(BrokerAdoption(sessionID: native.sessionID, processID: 8, exitCode: nil, nonce: nil, replay: Data(), transport: FakeKeptTransport())))
    }

    @MainActor
    func testRestoredTextIsSanitizedAndSilent() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        var attention = 0, journal = 0
        native.onAttentionRequested = { attention += 1 }
        native.onOutputData = { _ in journal += 1 }
        let sent = FakeKeptTransport()
        XCTAssertTrue(native.useTransport(sent))
        native.showRestoredOutput("line one\n\u{1b}[6n\u{1b}]9;ping\u{07}\u{9b}31mline two", savedAt: Date(timeIntervalSince1970: 0))
        let text = try native.adapter.read(.retainedText)
        XCTAssertTrue(text.contains("line one"))
        XCTAssertTrue(text.contains("[6n]9;ping31mline two"), "Control characters are removed; what remains is literal text")
        XCTAssertTrue(text.contains("— Restored output from"))
        XCTAssertEqual(sent.sent, [])
        XCTAssertEqual([attention, journal], [0, 0])
        XCTAssertEqual(native.sessionState, .stopped)
        XCTAssertEqual(NativeTerminal.printable("a\tb\r\nc\u{7f}\u{85}"), "a\tb\r\nc")
    }

    @MainActor
    func testAnEndedSessionShowsItsReplayAndStaysStopped() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        native.showEndedSession(replay: Data("build ok\r\n\u{1b}[c".utf8), exitCode: 3)
        let text = try native.adapter.read(.retainedText)
        XCTAssertTrue(text.contains("build ok"))
        XCTAssertTrue(text.contains("— Session ended while Trellis was closed (exit 3) —"))
        XCTAssertEqual(native.sessionState, .stopped)
    }
}
