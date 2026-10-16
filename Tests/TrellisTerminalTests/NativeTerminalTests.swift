import AppKit
import XCTest
import SwiftTerm
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
