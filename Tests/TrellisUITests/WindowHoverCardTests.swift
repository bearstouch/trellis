import AppKit
import SwiftUI
import XCTest

@testable import TrellisUI

/// FR-W06: the tabs hover card must never swallow a click meant for a tab, Settings or Hosts.
@MainActor final class WindowHoverCardTests: XCTestCase {
    private var window: NSWindow!
    private var anchor: NSView!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        anchor = NSView(frame: NSRect(x: 10, y: 10, width: 32, height: 32))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window = nil; anchor = nil
    }

    private func shownCard() throws -> PassThroughPopover {
        let card = PassThroughPopover()
        card.show(AnyView(Text("Tabs").frame(width: 120, height: 40)), relativeTo: anchor, edge: .maxX)
        try XCTSkipUnless(card.isShown, "The popover could not be shown in this session.")
        return card
    }

    private func mouseDown(in target: NSWindow?) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0, windowNumber: target?.windowNumber ?? 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testOutsideClickClosesCardAndStillReachesItsTarget() throws {
        let card = try shownCard()
        var dismissals = 0
        card.onDismiss = { dismissals += 1 }
        let click = try mouseDown(in: window)
        XCTAssertTrue(card.handleMouseDown(click) === click, "The click must pass through to the tab or button under it")
        XCTAssertFalse(card.isShown)
        XCTAssertEqual(dismissals, 1)
    }

    func testClickInsideCardKeepsItOpen() throws {
        let card = try shownCard()
        var dismissals = 0
        card.onDismiss = { dismissals += 1 }
        let click = try mouseDown(in: card.popover.contentViewController?.view.window)
        XCTAssertTrue(card.handleMouseDown(click) === click)
        XCTAssertTrue(card.isShown)
        XCTAssertEqual(dismissals, 0)
        card.close()
    }

    func testClosingProgrammaticallyDoesNotReportADismissal() throws {
        let card = try shownCard()
        var dismissals = 0
        card.onDismiss = { dismissals += 1 }
        card.close()
        XCTAssertFalse(card.isShown)
        XCTAssertEqual(dismissals, 0)
        // A later click with the card closed is left alone.
        let click = try mouseDown(in: window)
        XCTAssertTrue(card.handleMouseDown(click) === click)
        XCTAssertEqual(dismissals, 0)
    }

    func testCardClosedByAppKitReportsADismissal() throws {
        let card = try shownCard()
        var dismissals = 0
        card.onDismiss = { dismissals += 1 }
        card.popover.animates = false
        card.popover.close()
        let deadline = Date().addingTimeInterval(2)
        while card.isShown, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(card.isShown)
        XCTAssertEqual(dismissals, 1, "`presented` must follow a card AppKit closed, or the next update reopens it")
    }

    func testCardIsApplicationDefinedSoAppKitNeverConsumesTheDismissingClick() {
        XCTAssertEqual(PassThroughPopover().popover.behavior, .applicationDefined)
    }
}
