import AppKit
import SwiftUI
import XCTest
import TrellisTerminal
@testable import TrellisUI

final class TerminalSearchFocusTests: XCTestCase {
    @MainActor
    func testReopeningSearchTransfersFirstResponderFromTerminalToField() async throws {
        _ = NSApplication.shared
        let terminal = NativeTerminal()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SearchableTerminalSurface(terminal: terminal, isFocused: true, background: .black))
        window.makeKeyAndOrderFront(nil)
        defer { terminal.adapter.detach(); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        terminal.showSearch()
        try await Task.sleep(for: .milliseconds(100))
        let field = try XCTUnwrap(findFields(in: window.contentView!).first)
        XCTAssertTrue(window.firstResponder === field.currentEditor())
        terminal.closeSearch()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(window.firstResponder === terminal.view)
        terminal.showSearch()
        try await Task.sleep(for: .milliseconds(100))
        let reopened = try XCTUnwrap(findFields(in: window.contentView!).first)
        XCTAssertTrue(window.firstResponder === reopened.currentEditor())
        // Repeated Cmd-F is also a fresh request after an explicit terminal click.
        window.makeFirstResponder(terminal.view)
        terminal.showSearch()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(window.firstResponder === reopened.currentEditor())
    }

    @MainActor
    func testTwoOpenSearchFieldsReportOwningPaneWithoutStealingFocus() async throws {
        _ = NSApplication.shared
        let a = NativeTerminal(), b = NativeTerminal()
        var active = ""
        a.onFocused = { active = "a" }; b.onFocused = { active = "b" }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: HStack {
                SearchableTerminalSurface(terminal: a, isFocused: true, background: .black)
                SearchableTerminalSurface(terminal: b, isFocused: false, background: .black)
            })
        window.makeKeyAndOrderFront(nil)
        defer { a.adapter.detach(); b.adapter.detach(); window.close() }
        a.showSearch(); b.showSearch()
        try await Task.sleep(for: .milliseconds(100))
        let fields = findFields(in: window.contentView!)
        XCTAssertEqual(fields.count, 2)
        for (index, owner) in [(0, "a"), (1, "b"), (0, "a")] {
            let field = fields[index]
            window.makeFirstResponder(field)
            XCTAssertEqual(active, owner)
            field.currentEditor()?.insertText(owner)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(active, owner)
            XCTAssertTrue(window.firstResponder === field.currentEditor())
        }
        XCTAssertEqual(a.searchQuery, "a")
        XCTAssertEqual(b.searchQuery, "b")
        window.makeFirstResponder(fields[1])
        XCTAssertEqual(active, "b")
        a.closeSearch()
        XCTAssertEqual(active, "a", "Closing another pane's toolbar transfers terminal focus to its owner")
        XCTAssertTrue(window.firstResponder === a.view)
    }

    @MainActor
    func testASurfaceReusedForAnotherPaneSearchesThatPane() async throws {
        _ = NSApplication.shared
        let a = NativeTerminal(), b = NativeTerminal()
        var active = ""
        a.onFocused = { active = "a" }; b.onFocused = { active = "b" }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SearchableTerminalSurface(terminal: a, isFocused: true, background: .black))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { a.adapter.detach(); b.adapter.detach(); window.close() }
        a.showSearch(); b.showSearch()
        try await Task.sleep(for: .milliseconds(100))
        // Switching to a tab of the same shape reuses the surface with the other pane's terminal.
        host.rootView = SearchableTerminalSurface(terminal: b, isFocused: true, background: .black)
        try await Task.sleep(for: .milliseconds(100))
        let field = try XCTUnwrap(findFields(in: host).first)
        window.makeFirstResponder(field)
        XCTAssertEqual(active, "b")
        field.currentEditor()?.insertText("needle")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(b.searchQuery, "needle")
        XCTAssertEqual(a.searchQuery, "", "The hidden pane's search is untouched")
        field.currentEditor()?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(b.searchVisible, "Esc closes the visible pane's search")
        XCTAssertTrue(a.searchVisible)
    }

    @MainActor
    private func findFields(in view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField, field.placeholderString == "Find in this pane" { return [field] }
        return view.subviews.flatMap { findFields(in: $0) }
    }
}
