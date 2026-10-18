import AppKit
import XCTest
import SwiftTerm
import TrellisCore
@testable import TrellisTerminal

final class TerminalClearTests: XCTestCase {
    @MainActor
    func testClearDropsHistoryAndKeepsThePromptLineAtTheTop() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        view.getTerminal().resize(cols: 40, rows: 5)
        native.adapter.receive(Data(((0..<20).map { "old \($0)\r\n" }.joined() + "$ git st").utf8))
        let column = view.getTerminal().buffer.x
        native.clear()
        let terminal = view.getTerminal()
        XCTAssertEqual(try native.adapter.read(.retainedText).trimmingCharacters(in: .whitespacesAndNewlines), "$ git st")
        XCTAssertEqual(terminal.buffer.y, 0)
        XCTAssertEqual(terminal.buffer.x, column)
        XCTAssertNil(terminal.bufferLine(atRow: terminal.rows))
        XCTAssertEqual(view.scrollback.retainedHistoryRows, 0)
        // Later output continues from the kept line.
        native.adapter.receive(Data("atus\r\nnext".utf8))
        XCTAssertEqual(native.screenText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.prefix(2), ["$ git status", "next"])
    }

    @MainActor
    func testClearKeepsAWrappedCommandLineWhole() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        view.getTerminal().resize(cols: 10, rows: 6)
        let command = "$ " + String(repeating: "x", count: 15)
        native.adapter.receive(Data(("before\r\n" + command).utf8))
        native.clear()
        XCTAssertEqual(try native.adapter.read(.retainedText).replacingOccurrences(of: "\n", with: "").trimmingCharacters(in: .whitespaces), command)
        XCTAssertEqual(view.getTerminal().buffer.y, 1)
    }

    @MainActor
    func testClearLeavesAnAlternateScreenProgramAlone() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        view.getTerminal().resize(cols: 40, rows: 5)
        native.adapter.receive(Data(((0..<20).map { "old \($0)\r\n" }.joined() + "\u{1b}[?1049h\u{1b}[H\u{1b}[2JEDITOR").utf8))
        native.clear()
        XCTAssertTrue(native.screenText.contains("EDITOR"))
        native.adapter.receive(Data("\u{1b}[?1049l".utf8))
        XCTAssertFalse(try native.adapter.read(.retainedText).contains("old 0\n"))
    }

    @MainActor
    func testClearIsInTheTerminalContextMenu() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let item = try XCTUnwrap(view.menu(for: event)?.items.first { $0.title == "Clear" })
        XCTAssertEqual(item.action, #selector(AccessibleTerminalView.clearTerminal(_:)))
        XCTAssertTrue(view.validateUserInterfaceItem(item))
    }

    @MainActor
    func testClearDuringAnAlternateScreenKeepsTheSavedCursorForItsExit() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        view.getTerminal().resize(cols: 40, rows: 5)
        native.adapter.receive(Data(((0..<20).map { "old \($0)\r\n" }.joined() + "$ vim").utf8))
        let row = view.getTerminal().buffer.y
        native.adapter.receive(Data("\u{1b}[?1049h\u{1b}[H\u{1b}[2JEDITOR".utf8))
        native.clear()
        native.adapter.receive(Data("\u{1b}[?1049l".utf8))
        XCTAssertEqual(view.getTerminal().buffer.y, row)
    }

    @MainActor
    func testClearWhileScrolledUpFollowsLaterOutput() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        view.getTerminal().resize(cols: 40, rows: 5)
        native.adapter.receive(Data(((0..<20).map { "old \($0)\r\n" }.joined() + "$ ").utf8))
        view.scrollTo(row: 2)
        native.clear()
        native.adapter.receive(Data((0..<8).map { "new \($0)\r\n" }.joined().utf8))
        let terminal = view.getTerminal()
        var count = 0
        while terminal.bufferLine(atRow: count) != nil { count += 1 }
        XCTAssertGreaterThan(count, terminal.rows)
        XCTAssertEqual(terminal.buffer.yDisp, count - terminal.rows)
    }

    @MainActor
    func testClearIgnoresTheProgramsScrollRegionAndMargins() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        view.getTerminal().resize(cols: 20, rows: 6)
        // Scroll region rows 2-4, then left/right margins 3-8 with DECLRMM on.
        native.adapter.receive(Data(("a\r\nb\r\nc\r\nd\r\n\u{1b}[2;4r\u{1b}[?69h\u{1b}[4;9s\u{1b}[5;1H$ ls").utf8))
        native.clear()
        XCTAssertEqual(try native.adapter.read(.retainedText).trimmingCharacters(in: .whitespacesAndNewlines), "$ ls")
        XCTAssertEqual(view.getTerminal().buffer.y, 0)
        XCTAssertEqual(view.getTerminal().buffer.scrollTop, 1)
        XCTAssertEqual(view.getTerminal().buffer.marginLeft, 3)
    }
}
