import AppKit
import XCTest
import SwiftTerm
@testable import TrellisTerminal

final class TerminalCopyTests: XCTestCase {
    @MainActor
    private func key(_ flags: NSEvent.ModifierFlags, characters: String, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
    }

    @MainActor
    func testS011_UT01_copyStripsControlsPreservesUnicode() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let surface = try XCTUnwrap(native.view as? AccessibleTerminalView)
        var writes: [String] = []
        surface.writeClipboard = { writes.append($0) }
        native.adapter.receive(Data("\u{1b}[32mcafé e\u{301} 漢字 👩‍💻\u{1b}[0m\r\nsecond\tline".utf8))
        surface.selectAllTerminalText(nil)
        surface.copy(self)
        XCTAssertEqual(writes, ["café e\u{301} 漢字 👩‍💻\nsecond  line"])
        XCTAssertFalse(writes[0].contains("\u{1b}"))
    }

    @MainActor
    func testS011_UT02_cmdCWithoutSelectionDoesNotInterrupt() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let surface = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let input = CopyInputObserver()
        surface.terminalDelegate = input
        var writes = 0
        surface.writeClipboard = { _ in writes += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = surface
        XCTAssertTrue(window.makeFirstResponder(surface))
        XCTAssertTrue(surface.performKeyEquivalent(with: try key(.command, characters: "c", window: window)))
        surface.copy(self)
        XCTAssertEqual(input.received, Data())
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testS011_UT03_ctrlCStillReachesTerminal() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let surface = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let input = CopyInputObserver()
        surface.terminalDelegate = input
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = surface
        window.makeFirstResponder(surface)
        surface.keyDown(with: try key(.control, characters: "\u{3}", window: window))
        XCTAssertEqual(input.received, Data([3]))
    }

    @MainActor
    func testS011_UT04_copyUsesFocusedPane() throws {
        _ = NSApplication.shared
        let first = NativeTerminal(), second = NativeTerminal()
        defer { first.adapter.detach(); second.adapter.detach() }
        let a = try XCTUnwrap(first.view as? AccessibleTerminalView)
        let b = try XCTUnwrap(second.view as? AccessibleTerminalView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host
        host.addSubview(a); host.addSubview(b)
        first.adapter.receive(Data("first pane".utf8)); second.adapter.receive(Data("second pane".utf8))
        a.selectAllTerminalText(nil); b.selectAllTerminalText(nil)
        var writes: [String] = []
        a.writeClipboard = { writes.append($0) }; b.writeClipboard = { writes.append($0) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(b)
        XCTAssertTrue(NSApp.sendAction(#selector(NSText.copy(_:)), to: window.firstResponder, from: self))
        XCTAssertEqual(writes, ["second pane"])
        window.makeFirstResponder(a)
        XCTAssertTrue(NSApp.sendAction(#selector(NSText.copy(_:)), to: window.firstResponder, from: self))
        XCTAssertEqual(writes, ["second pane", "first pane"])
    }

    @MainActor
    func testCopyAllIsBoundedAndReportsEvictionAndAlternateScreen() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let surface = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let terminal = surface.getTerminal()
        terminal.changeScrollback(3)
        native.adapter.receive(Data(("DISCARDED\r\n" + (0..<100).map { "line \($0)\r\n" }.joined() + "retained 👋").utf8))
        var writes: [String] = []
        surface.writeClipboard = { writes.append($0) }
        let item = NSMenuItem(title: "Copy All Retained Text", action: #selector(AccessibleTerminalView.copyAllRetainedText(_:)), keyEquivalent: "")
        XCTAssertTrue(surface.validateUserInterfaceItem(item))
        XCTAssertTrue(item.title.contains("Older Lines Evicted"))
        surface.copyAllRetainedText(self)
        XCTAssertFalse(writes[0].contains("DISCARDED"))
        XCTAssertTrue(writes[0].contains("retained 👋"))
        native.adapter.receive(Data("\u{1b}[?1049h\u{1b}[H\u{1b}[2JALTERNATE".utf8))
        surface.copyAllRetainedText(self)
        XCTAssertEqual(writes[1], "ALTERNATE")
        XCTAssertTrue(surface.copyAllTitle.contains("No Scrollback"))
        native.adapter.receive(Data("\u{1b}[?1049l".utf8))
        surface.copyAllRetainedText(self)
        XCTAssertEqual(writes[2], writes[0])
    }

    @MainActor
    func testSelectAllAndLineCopyIncludeLastColumn() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let surface = try XCTUnwrap(native.view as? AccessibleTerminalView)
        surface.getTerminal().resize(cols: 8, rows: 2)
        native.adapter.receive(Data("12345678\r\nABCDEFGH".utf8))
        var writes: [String] = []
        surface.writeClipboard = { writes.append($0) }
        surface.selectAllTerminalText(nil)
        surface.copy(self)
        XCTAssertEqual(writes, ["12345678\nABCDEFGH"])
        surface.selection.select(row: 1)
        surface.copy(self)
        XCTAssertEqual(writes.last, "ABCDEFGH")
    }

    @MainActor
    func testContextMenuFocusesClickedPaneAndDoesNotReadClipboard() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let surface = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = surface
        native.adapter.receive(Data("context 👋".utf8))
        surface.selectAllTerminalText(nil)
        var focused = 0, writes: [String] = []
        surface.onFocused = { focused += 1 }
        surface.writeClipboard = { writes.append($0) }
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(surface.menu(for: event))
        XCTAssertTrue(window.firstResponder === surface)
        XCTAssertEqual(focused, 1)
        XCTAssertEqual(writes, [])
        let copy = try XCTUnwrap(menu.item(at: 0))
        XCTAssertTrue(copy.target === surface)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(copy.action), to: copy.target, from: copy))
        XCTAssertEqual(writes, ["context 👋"])
    }
}

@MainActor
private final class CopyInputObserver: NSObject, @preconcurrency TerminalViewDelegate {
    var received = Data()
    func send(source: TerminalView, data: ArraySlice<UInt8>) { received.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
