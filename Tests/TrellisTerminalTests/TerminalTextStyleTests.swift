import AppKit
import XCTest
import SwiftTerm
import TrellisCore
@testable import TrellisTerminal

/// FR-TX02 and FR-TX03: SGR styles and the text-style settings, checked on the runs the renderer draws.
final class TerminalTextStyleTests: XCTestCase {
    @MainActor
    private func terminal(_ output: String, settings: AppearanceSettings = AppearanceSettings()) throws -> (NativeTerminal, AccessibleTerminalView) {
        _ = NSApplication.shared
        let native = NativeTerminal()
        native.applyAppearance(settings)
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        native.adapter.receive(Data(output.utf8))
        return (native, view)
    }

    @MainActor
    private func run(at column: Int, in view: AccessibleTerminalView, row: Int = 0) throws -> RenderedRunForTesting {
        try XCTUnwrap(view.renderedRowForTesting(row).first { $0.columns.contains(column) }, "a run covers column \(column)")
    }

    @MainActor
    private func cell(_ view: AccessibleTerminalView, _ col: Int, row: Int = 0) -> CharData {
        view.getTerminal().buffer.getChar(at: Position(col: col, row: row))
    }

    @MainActor
    func testOverlineSetAndClearedBySgr53And55() throws {
        let (native, view) = try terminal("\u{1b}[53mO\u{1b}[55mN\u{1b}[53mR\u{1b}[0mZ")
        defer { native.adapter.detach() }
        XCTAssertTrue(cell(view, 0).attribute.extendedStyle.contains(.overline))
        XCTAssertFalse(cell(view, 1).attribute.extendedStyle.contains(.overline), "SGR 55 clears it")
        XCTAssertTrue(cell(view, 2).attribute.extendedStyle.contains(.overline))
        XCTAssertFalse(cell(view, 3).attribute.extendedStyle.contains(.overline), "SGR 0 clears it")
        XCTAssertTrue(try run(at: 0, in: view).overline)
        XCTAssertFalse(try run(at: 1, in: view).overline)
        XCTAssertTrue(try run(at: 2, in: view).overline)
        XCTAssertFalse(try run(at: 3, in: view).overline)
    }

    func testOverlineDoesNotGrowCells() {
        // Scrollback memory scales with the cell size; overline fits in existing padding.
        XCTAssertLessThanOrEqual(MemoryLayout<CharData>.stride, 24)
    }

    @MainActor
    func testRapidBlinkIsBlink() throws {
        let (native, view) = try terminal("\u{1b}[6mF\u{1b}[25mS")
        defer { native.adapter.detach() }
        XCTAssertTrue(cell(view, 0).attribute.style.contains(.blink))
        XCTAssertFalse(cell(view, 1).attribute.style.contains(.blink))
    }

    @MainActor
    func testConcealedTextKeepsBackgroundOnly() throws {
        let (native, view) = try terminal("\u{1b}[8;4;41msecret\u{1b}[28mshown\u{1b}[0m")
        defer { native.adapter.detach() }
        let hidden = try run(at: 0, in: view)
        XCTAssertEqual(hidden.columns, 0..<6)
        XCTAssertEqual(hidden.foregroundColor?.alpha, 0, "concealed glyphs are transparent")
        XCTAssertFalse(hidden.underline, "decorations are hidden too")
        XCTAssertNotNil(hidden.backgroundColor)
        let shown = try run(at: 6, in: view)
        XCTAssertEqual(shown.foregroundColor?.alpha, 1)
        XCTAssertTrue(shown.underline)
        XCTAssertEqual(shown.backgroundColor, hidden.backgroundColor)
        XCTAssertTrue(try native.adapter.read(.retainedText).contains("secretshown"), "the buffer still holds concealed text")
    }

    @MainActor
    func testDecorationsSpanWideCharacters() throws {
        let (native, view) = try terminal("\u{1b}[4m漢\u{1b}[24m \u{1b}[4:3m👨‍👩‍👧\u{1b}[0m \u{1b}[9;53m字\u{1b}[0m")
        defer { native.adapter.detach() }
        let cjk = try run(at: 0, in: view)
        XCTAssertEqual(cjk.columns, 0..<2)
        XCTAssertTrue(cjk.underline)
        let emoji = try run(at: 3, in: view)
        XCTAssertEqual(emoji.columns, 3..<5)
        XCTAssertTrue(emoji.underline)
        XCTAssertEqual(cell(view, 3).attribute.underlineStyle, .curly)
        let struck = try run(at: 6, in: view)
        XCTAssertEqual(struck.columns, 6..<8)
        XCTAssertTrue(struck.strikethrough && struck.overline)
    }

    @MainActor
    func testBoldAndItalicFontSettings() throws {
        let output = "\u{1b}[1mB\u{1b}[0m\u{1b}[3mI\u{1b}[0m\u{1b}[1;3mX\u{1b}[0m"
        let (native, view) = try terminal(output)
        defer { native.adapter.detach() }
        XCTAssertEqual(try run(at: 0, in: view).fontName, "RobotoMono-Bold")
        XCTAssertEqual(try run(at: 1, in: view).fontName, "RobotoMono-Italic")
        XCTAssertEqual(try run(at: 2, in: view).fontName, "RobotoMono-BoldItalic")
        var settings = AppearanceSettings()
        settings.allowBoldFont = false
        native.applyAppearance(settings)
        XCTAssertEqual(try run(at: 0, in: view).fontName, "RobotoMono-Regular")
        XCTAssertEqual(try run(at: 2, in: view).fontName, "RobotoMono-Italic")
        settings.allowItalicFont = false
        native.applyAppearance(settings)
        XCTAssertEqual(try run(at: 1, in: view).fontName, "RobotoMono-Regular")
        XCTAssertEqual(try run(at: 2, in: view).fontName, "RobotoMono-Regular")
    }

    @MainActor
    func testBoldAsBrightOnlyAffectsBoldBaseColors() throws {
        // Columns: bold red, bright red, red, bold white, bright white, bold bright red.
        let output = "\u{1b}[1;31mA\u{1b}[0m\u{1b}[91mB\u{1b}[0m\u{1b}[31mC\u{1b}[0m\u{1b}[1;37mD\u{1b}[0m\u{1b}[97mE\u{1b}[0m\u{1b}[1;91mF\u{1b}[0m"
        let (native, view) = try terminal(output)
        defer { native.adapter.detach() }
        func fg(_ column: Int) throws -> CGColor? { try run(at: column, in: view).foregroundColor }
        XCTAssertEqual(try fg(0), try fg(1), "bold red is drawn bright")
        XCTAssertNotEqual(try fg(0), try fg(2))
        XCTAssertEqual(try fg(3), try fg(4), "bold white is drawn bright white")
        XCTAssertEqual(try fg(5), try fg(1))
        var settings = AppearanceSettings()
        settings.boldAsBright = false
        native.applyAppearance(settings)
        XCTAssertEqual(try fg(0), try fg(2), "bold red keeps its base color")
        XCTAssertNotEqual(try fg(1), try fg(2), "explicit bright red stays bright")
        XCTAssertEqual(try fg(5), try fg(1))
        XCTAssertEqual(try run(at: 0, in: view).fontName, "RobotoMono-Bold", "bold text still uses the bold face")
    }

    @MainActor
    func testBlinkingTextOnlyRunsWhenAllowed() {
        XCTAssertTrue(TerminalView.textBlinkCanRun(windowAttached: true, applicationActive: true, motionReduced: false, hasBlinkRows: true, enabled: true))
        XCTAssertFalse(TerminalView.textBlinkCanRun(windowAttached: true, applicationActive: true, motionReduced: false, hasBlinkRows: true, enabled: false))
        XCTAssertFalse(TerminalView.textBlinkCanRun(windowAttached: true, applicationActive: true, motionReduced: true, hasBlinkRows: true, enabled: true))
        XCTAssertFalse(TerminalView.textBlinkCanRun(windowAttached: true, applicationActive: false, motionReduced: false, hasBlinkRows: true, enabled: true))
        XCTAssertFalse(TerminalView.textBlinkCanRun(windowAttached: false, applicationActive: true, motionReduced: false, hasBlinkRows: true, enabled: true))
    }

    @MainActor
    func testApplyAppearancePropagatesTextSettingsWithoutResizing() throws {
        let (native, view) = try terminal("text")
        defer { native.adapter.detach() }
        let cols = view.getTerminal().cols, rows = view.getTerminal().rows, font = view.font
        var settings = AppearanceSettings()
        settings.fontLigatures = false; settings.boldAsBright = false; settings.allowBoldFont = false
        settings.allowItalicFont = false; settings.blinkingText = false
        native.applyAppearance(settings)
        XCTAssertFalse(view.fontLigatures)
        XCTAssertFalse(view.boldIsBright)
        XCTAssertFalse(view.allowBoldFont)
        XCTAssertFalse(view.allowItalicFont)
        XCTAssertFalse(view.textBlinkEnabled)
        XCTAssertEqual(view.font, font, "the host's font is unchanged")
        XCTAssertEqual(view.getTerminal().cols, cols)
        XCTAssertEqual(view.getTerminal().rows, rows)
        native.applyAppearance(AppearanceSettings())
        XCTAssertTrue(view.fontLigatures && view.boldIsBright && view.allowBoldFont && view.allowItalicFont && view.textBlinkEnabled)
    }
}
