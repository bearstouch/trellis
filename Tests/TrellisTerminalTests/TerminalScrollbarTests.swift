import AppKit
import XCTest
@testable import TrellisTerminal

@MainActor
final class TerminalScrollbarTests: XCTestCase {
    func testScrollbarRevealsOnlyWhenGestureMovesViewportAndThenHides() async throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        view.scrollbarIdleDelay = .milliseconds(40)
        let scroller = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScroller }.first)
        let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        view.scrollWheel(with: event)
        XCTAssertEqual(scroller.alphaValue, 0, "No scrollback means no scrollbar")
        view.display(Data((0..<100).map { "line \($0)\r\n" }.joined().utf8))
        XCTAssertEqual(scroller.alphaValue, 0, "Output alone must not reveal the scrollbar")
        let before = view.scrollPosition
        view.scrollWheel(with: event)
        XCTAssertNotEqual(view.scrollPosition, before)
        XCTAssertEqual(scroller.alphaValue, 1)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(scroller.alphaValue, 0, accuracy: 0.01)
        view.scrollWheel(with: event)
        XCTAssertEqual(scroller.alphaValue, 1)
        window.contentView = nil
        XCTAssertEqual(scroller.alphaValue, 0, "Detaching a terminal clears visibility")
    }

    func testHiddenOverlayScrollbarLeavesLastColumnClicksToTheTerminal() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.display(Data((0..<100).map { "line \($0)\r\n" }.joined().utf8))
        let scroller = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScroller }.first)
        XCTAssertTrue(scroller.isEnabled, "Scrollback enables the scroller")
        let edge = try XCTUnwrap(view.superview).convert(NSPoint(x: view.bounds.maxX - 3, y: view.bounds.midY), from: view)
        XCTAssertEqual(scroller.alphaValue, 0)
        XCTAssertTrue(view.hitTest(edge) === view, "The faded-out scroller must not swallow clicks on the last column")
        XCTAssertTrue(view.hitTest(NSPoint(x: 10, y: 150)) === view)
    }

    func testOverlayScrollbarReservesNoColumns() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        XCTAssertEqual(view.scrollerStyle, .overlay)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let cell = view.cellMetrics.size.width
        XCTAssertEqual(view.getTerminal().cols, Int(600 / cell), "The hidden overlay scroller must not leave an empty strip on the right")
        view.scrollerStyle = .legacy
        view.frame = NSRect(x: 0, y: 0, width: 601, height: 300)
        let legacy = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        XCTAssertEqual(view.getTerminal().cols, Int((601 - legacy) / cell), "An always-visible scroller keeps its own track")
    }
}
