import AppKit
import SwiftTerm
import XCTest
@testable import TrellisTerminal

@MainActor
final class SmartSelectionTerminalTests: XCTestCase {
    private func selectedText(_ surface: AccessibleTerminalView, at position: Position) -> String? {
        guard let range = surface.doubleClickSelection?(position) else { return nil }
        surface.selection.setWordSelection(start: range.start, end: range.end)
        return surface.selection.getSelectedText()
    }

    func testDoubleClickSelectsPathAcrossSoftWrap() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let surface = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let cols = surface.getTerminal().cols
        let path = "/var/" + String(repeating: "d", count: cols) + "/file.txt:12"
        native.adapter.receive(Data("see \(path) now".utf8))
        XCTAssertEqual(selectedText(surface, at: Position(col: 6, row: 0)), path)
        XCTAssertEqual(selectedText(surface, at: Position(col: 3, row: 1)), path, "Clicking the wrapped part selects the whole path")
    }

    func testDoubleClickFallsBackToWordSelection() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let surface = try XCTUnwrap(native.view as? AccessibleTerminalView)
        native.adapter.receive(Data("plain words only".utf8))
        XCTAssertNil(surface.doubleClickSelection?(Position(col: 7, row: 0)))
        XCTAssertNil(surface.doubleClickSelection?(Position(col: 40, row: 0)), "Empty cells have no token")
    }

    func testDoubleClickOnWideCharacterLineMapsColumns() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let surface = try XCTUnwrap(native.view as? AccessibleTerminalView)
        native.adapter.receive(Data("漢字 /tmp/a.txt 👋 x".utf8))
        let range = try XCTUnwrap(surface.doubleClickSelection?(Position(col: 7, row: 0)))
        XCTAssertEqual(range.start, Position(col: 5, row: 0))
        XCTAssertEqual(range.end, Position(col: 15, row: 0))
        XCTAssertEqual(selectedText(surface, at: Position(col: 7, row: 0)), "/tmp/a.txt")
    }

    func testSmartSelectionLastColumnIncluded() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let surface = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let cols = surface.getTerminal().cols
        let url = "https://example.com/z"
        native.adapter.receive(Data((String(repeating: " ", count: cols - url.count) + url).utf8))
        let range = try XCTUnwrap(surface.doubleClickSelection?(Position(col: cols - 3, row: 0)))
        XCTAssertEqual(range.end, Position(col: cols, row: 0))
        XCTAssertEqual(selectedText(surface, at: Position(col: cols - 3, row: 0)), url)
    }

    func testDragAfterSmartDoubleClickKeepsToken() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let surface = try XCTUnwrap(native.view as? AccessibleTerminalView)
        native.adapter.receive(Data("one user@example.com two three".utf8))
        XCTAssertEqual(selectedText(surface, at: Position(col: 8, row: 0)), "user@example.com")
        surface.selection.dragExtend(bufferPosition: Position(col: 22, row: 0))
        XCTAssertEqual(surface.selection.getSelectedText(), "user@example.com two")
        surface.selection.dragExtend(bufferPosition: Position(col: 1, row: 0))
        XCTAssertEqual(surface.selection.getSelectedText(), "one user@example.com", "Dragging back keeps the whole token")
    }

    func testDoubleClickEventUsesHook() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let surface = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let window = TerminalPointer.window(for: surface)
        defer { window.close() }
        native.adapter.receive(Data("open ~/notes/todo.md:4 now".utf8))
        let point = try XCTUnwrap(TerminalPointer.point(in: surface, at: Position(col: 10, row: 0)))
        surface.mouseDown(with: try TerminalPointer.event(.leftMouseDown, at: point, in: window, clickCount: 2))
        XCTAssertEqual(surface.selection.getSelectedText(), "~/notes/todo.md:4")
    }

    func testMouseReportingSkipsSmartSelection() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let surface = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let window = TerminalPointer.window(for: surface)
        defer { window.close() }
        native.adapter.receive(Data("open ~/notes/todo.md now\u{1b}[?1000h".utf8))
        var calls = 0
        surface.doubleClickSelection = { _ in
            calls += 1; return nil
        }
        let point = try XCTUnwrap(TerminalPointer.point(in: surface, at: Position(col: 10, row: 0)))
        surface.mouseDown(with: try TerminalPointer.event(.leftMouseDown, at: point, in: window, clickCount: 2))
        XCTAssertEqual(calls, 0, "A program that captures the mouse receives the double-click")
        XCTAssertFalse(surface.selection.active)
    }
}

/// Finds a window point for a buffer cell through the engine's own hit test.
@MainActor
enum TerminalPointer {
    static func window(for surface: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        return window
    }

    static func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: clickCount, pressure: 1))
    }

    static func point(in surface: AccessibleTerminalView, at position: Position) -> NSPoint? {
        guard let window = surface.window else { return nil }
        func hit(_ point: NSPoint) -> Position? { (try? event(.leftMouseDown, at: point, in: window)).map(surface.bufferPosition(for:)) }
        let bounds = surface.convert(surface.bounds, to: nil)
        var y = bounds.maxY - 1
        while y > bounds.minY, let found = hit(NSPoint(x: bounds.minX + 1, y: y)), found.row < position.row { y -= 2 }
        var x = bounds.minX + 1
        while x < bounds.maxX, let found = hit(NSPoint(x: x, y: y)), found.col < position.col { x += 1 }
        let point = NSPoint(x: x + 1, y: y - 2)
        return hit(point) == position ? point : nil
    }
}
