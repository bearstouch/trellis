import AppKit
import SwiftTerm
import XCTest
import UTermCore
@testable import UTermTerminal

final class TerminalSelectionBookmarkTests: XCTestCase {
    @MainActor
    func testCurrentCursorRowKeepsTextSelectionAndNextWriteAcrossZoom() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let text = String(repeating: "x", count: view.getTerminal().cols - 1) + "Z"
        native.adapter.receive(Data(text.utf8))
        view.selection.select(row: 0)
        var settings = AppearanceSettings()
        settings.fontSize = 20
        native.applyAppearance(settings)
        XCTAssertTrue(view.retainedText.contains(text))
        XCTAssertEqual(view.accessibilitySelectedText(), text)
        settings.fontSize = 13
        native.applyAppearance(settings)
        XCTAssertEqual(view.accessibilitySelectedText(), text)
        native.adapter.receive(Data("NEXT".utf8))
        XCTAssertTrue(view.retainedText.contains(text + "NEXT"), view.retainedText)
    }

    @MainActor
    func testCursorReflowWideGlyphsAndFullHistoryKeepNextWrite() throws {
        _ = NSApplication.shared
        for history in [0, 20] {
            let native = NativeTerminal(scrollbackBudget: ScrollbackBudget(lineLimit: 4))
            defer { native.adapter.detach() }
            let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
            let terminal = view.getTerminal()
            terminal.resize(cols: 11, rows: 4)
            native.adapter.receive(Data(String(repeating: "old\r\n", count: history).utf8))
            let text = "abcd漢e\u{301}👩‍💻123456789漢last"
            native.adapter.receive(Data(text.utf8))
            terminal.reflowCursorLine = true
            for width in [7, 15, 8, 11] { terminal.resize(cols: width, rows: 4) }
            terminal.reflowCursorLine = false
            native.adapter.receive(Data("NEXT".utf8))
            XCTAssertTrue(view.retainedText.contains(text + "NEXT"), view.retainedText)
        }
    }

    @MainActor
    func testCursorDestinationSurvivesEvictionOfItsLogicalLineStart() throws {
        _ = NSApplication.shared
        let native = NativeTerminal(scrollbackBudget: ScrollbackBudget(lineLimit: 4))
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let terminal = view.getTerminal()
        terminal.resize(cols: 20, rows: 4)
        native.adapter.receive(Data((String(repeating: "x", count: 59) + "Z").utf8))
        terminal.reflowCursorLine = true
        terminal.resize(cols: 5, rows: 4)
        terminal.reflowCursorLine = false
        native.adapter.receive(Data("NEXT".utf8))
        XCTAssertTrue(view.retainedText.contains("ZNEXT"), view.retainedText)
        XCTAssertTrue((0..<4).contains(terminal.buffer.y))
    }

    @MainActor
    func testFontChangeKeepsAlternateScreenAndItsSurvivingSelection() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        native.adapter.receive(Data("normal\u{1b}[?1049hALT text".utf8))
        native.searchQuery = "ALT text"
        XCTAssertTrue(native.findInPane(reset: true))
        var settings = AppearanceSettings(); settings.fontSize = 18
        native.applyAppearance(settings)
        XCTAssertTrue(view.getTerminal().isCurrentBufferAlternate)
        XCTAssertEqual(view.accessibilitySelectedText(), "ALT text")
        native.adapter.receive(Data("\u{1b}[?1049l".utf8))
        XCTAssertTrue(view.retainedText.contains("normal"))
    }

    @MainActor
    func testHistoryReductionRemapsSurvivingSelection() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        native.adapter.receive(Data((0..<100).map { "row \($0)\r\n" }.joined().utf8))
        native.searchQuery = "row 90"
        XCTAssertTrue(native.findInPane(reset: true))
        let oldRow = view.selection.start.row
        var settings = AppearanceSettings()
        settings.scrollbackLines = 2
        native.applyAppearance(settings)
        XCTAssertEqual(view.accessibilitySelectedText(), "row 90")
        XCTAssertLessThan(view.selection.start.row, oldRow)
    }

    @MainActor
    func testEvictedSelectionDoesNotJumpToLaterDuplicate() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        native.adapter.receive(Data((0..<100).map { _ in "duplicate\r\n" }.joined().utf8))
        view.selection.setSoftStart(bufferPosition: Position(col: 0, row: 0))
        view.selection.startSelection()
        view.selection.dragExtend(bufferPosition: Position(col: 9, row: 0))
        XCTAssertEqual(view.accessibilitySelectedText(), "duplicate")
        var settings = AppearanceSettings()
        settings.scrollbackLines = 2
        native.applyAppearance(settings)
        XCTAssertFalse(view.selection.active)
        XCTAssertEqual(view.accessibilitySelectedText(), "")
    }

    @MainActor
    func testSelectionAfterWideCharacterStartsAfterItsContinuationCell() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        native.adapter.receive(Data("漢abc\r\n".utf8))
        view.selection.setSoftStart(bufferPosition: Position(col: 2, row: 0))
        view.selection.startSelection()
        view.selection.dragExtend(bufferPosition: Position(col: 5, row: 0))
        var settings = AppearanceSettings()
        settings.fontSize = 20
        native.applyAppearance(settings)
        XCTAssertEqual(view.accessibilitySelectedText(), "abc")
        XCTAssertEqual(view.selection.start, Position(col: 2, row: 0))
    }

    @MainActor
    func testFullWidthRowSelectionKeepsLastCellAcrossFontReflow() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let text = String(repeating: "x", count: view.getTerminal().cols - 1) + "Z"
        native.adapter.receive(Data((text + "\r\n").utf8))
        view.selection.select(row: 0)
        XCTAssertEqual(view.accessibilitySelectedText(), text)
        var settings = AppearanceSettings()
        settings.fontSize = 20
        native.applyAppearance(settings)
        XCTAssertTrue(view.retainedText.contains(text))
        XCTAssertEqual(view.accessibilitySelectedText(), text)
    }

    @MainActor
    func testOverlappingRepeatedTextKeepsItsExactLogicalLocation() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        native.adapter.receive(Data("aaaaa".utf8))
        view.selection.setSoftStart(bufferPosition: Position(col: 1, row: 0))
        view.selection.startSelection()
        view.selection.dragExtend(bufferPosition: Position(col: 4, row: 0))
        var settings = AppearanceSettings()
        settings.fontSize = 20
        native.applyAppearance(settings)
        XCTAssertEqual(view.accessibilitySelectedText(), "aaa")
        XCTAssertEqual(view.selection.start, Position(col: 1, row: 0))
        XCTAssertEqual(view.selection.end, Position(col: 4, row: 0))
    }
}
