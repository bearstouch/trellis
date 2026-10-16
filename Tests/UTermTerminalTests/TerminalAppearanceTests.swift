import AppKit
import XCTest
import SwiftTerm
import UTermCore
@testable import UTermTerminal

final class TerminalAppearanceTests: XCTestCase {
    @MainActor
    func testS014_UT04_appearanceHasNoSessionEffects() async throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.requestTermination(force: true) }
        await native.start(configuration: LocalLaunchConfiguration(executable: "/bin/zsh", arguments: ["-f", "-c", "read -r line; printf 'UNEXPECTED_INPUT'; exit 42"], directory: "/tmp"))
        let pid = try XCTUnwrap(native.processID)
        let id = native.sessionID
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view))
        native.adapter.receive(Data((String(repeating: "prefix ", count: 20) + "café e\u{301}漢字 👩‍💻 target\r\nsecond row").utf8))
        native.searchQuery = "café e\u{301}漢字 👩‍💻 target"
        XCTAssertTrue(native.findInPane(reset: true))
        var inputErrors = 0, exits = 0
        native.onInputError = { _ in inputErrors += 1 }; native.onExit = { _ in exits += 1 }
        let observer = AppearanceInputObserver(native: native)
        view.terminalDelegate = observer
        // Application cursor mode, SGR attributes, and bracketed paste must
        // survive metrics changes; DECSTR would reset the first two.
        native.adapter.receive(Data("\u{1b}[?1h\u{1b}[?2004h\u{1b}[31mQ".utf8))
        let beforeCursor = view.getTerminal().getCursorLocation()
        let attribute = view.getTerminal().buffer.getChar(at: Position(col: beforeCursor.x - 1, row: beforeCursor.y)).attribute
        XCTAssertTrue(native.findInPane(reset: true))
        var settings = AppearanceSettings()
        settings.chromeMode = .dark; settings.fontName = "Menlo"; settings.fontSize = 22
        settings.cursorShape = .bar
        native.applyAppearance(settings)
        XCTAssertEqual(native.processID, pid)
        XCTAssertEqual(native.sessionID, id)
        XCTAssertTrue(native.isRunning)
        XCTAssertEqual(inputErrors, 0); XCTAssertEqual(exits, 0)
        XCTAssertTrue(observer.sent.isEmpty)
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertEqual(view.accessibilitySelectedText(), native.searchQuery)
        XCTAssertTrue(view.getTerminal().bracketedPasteMode)
        XCTAssertTrue(view.getTerminal().applicationCursor)
        XCTAssertEqual(view.font.pointSize, 22)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBar)
        XCTAssertFalse(try native.adapter.read(.retainedText).contains("UNEXPECTED_INPUT"))
        native.adapter.receive(Data("R".utf8))
        let afterCursor = view.getTerminal().getCursorLocation()
        XCTAssertEqual(view.getTerminal().buffer.getChar(at: Position(col: afterCursor.x - 1, row: afterCursor.y)).attribute, attribute)
    }

    @MainActor
    func testFallbackAndReducedHistory() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        native.adapter.receive(Data((0..<100).map { "row \($0)\r\n" }.joined().utf8))
        var settings = AppearanceSettings()
        settings.fontName = "No such uTerm font"
        settings.scrollbackLines = 2
        native.applyAppearance(settings)
        XCTAssertNotNil(NativeTerminalFont.choice(for: settings.fontName).notice)
        XCTAssertLessThanOrEqual(view.scrollback.retainedHistoryRows, 2)
        XCTAssertTrue(native.historyNotice.contains("evicted"))
        settings.scrollbackLines = 1000
        native.applyAppearance(settings)
        XCTAssertTrue(native.historyNotice.contains("evicted"))
    }
}

@MainActor
private final class AppearanceInputObserver: NSObject, @preconcurrency TerminalViewDelegate {
    let native: NativeTerminal
    var sent = Data()
    init(native: NativeTerminal) { self.native = native }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sent.append(contentsOf: data)
        native.send(source: source, data: data)
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        native.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
