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
}
