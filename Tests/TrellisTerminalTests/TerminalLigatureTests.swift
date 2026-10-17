import AppKit
import XCTest
import SwiftTerm
import TrellisCore
@testable import TrellisTerminal

/// FR-TX01: ligatures stay on the cell grid and follow the setting.
final class TerminalLigatureTests: XCTestCase {
    func testLigatureGlyphKeepsLaterColumns() {
        // "a->b" with a font that joins "->" into one glyph: three glyphs for four cells.
        let cells = TerminalGlyphPlacement.glyphCells(stringIndices: [0, 1, 3], coreTextX: [0, 8, 24]) { $0 }
        XCTAssertEqual(cells.map(\.ordinal), [0, 1, 3], "b stays in column 3")
        XCTAssertEqual(cells.map(\.dx), [0, 0, 0])
        XCTAssertEqual(TerminalGlyphPlacement.cellSpan(stringRange: 1..<3) { $0 }, 1..<3)
        XCTAssertEqual(TerminalGlyphPlacement.cellSpan(stringRange: 0..<0) { $0 }, 0..<0)
    }

    func testCombiningMarkKeepsItsOffsetInTheBaseCell() {
        // "e\u{301}x": the mark shares cell 0 with its base.
        let ordinals = [0, 0, 1]
        let cells = TerminalGlyphPlacement.glyphCells(stringIndices: [0, 1, 2], coreTextX: [0, 1.5, 8]) { ordinals[$0] }
        XCTAssertEqual(cells.map(\.ordinal), [0, 0, 1])
        XCTAssertEqual(cells.map(\.dx), [0, 1.5, 0])
        XCTAssertEqual(TerminalGlyphPlacement.cellSpan(stringRange: 0..<3) { ordinals[$0] }, 0..<2)
    }

    @MainActor
    private func jetBrainsTerminal(ligatures: Bool = true) throws -> (NativeTerminal, AccessibleTerminalView) {
        _ = NSApplication.shared
        NativeTerminalFont.registerBundledFonts()
        let native = NativeTerminal()
        var settings = AppearanceSettings()
        settings.fontName = "JetBrainsMono-Regular"
        settings.fontLigatures = ligatures
        native.applyAppearance(settings)
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        XCTAssertEqual(view.font.fontName, "JetBrainsMono-Regular")
        return (native, view)
    }

    /// Glyph IDs by column for one row; asserts every glyph sits on the grid.
    @MainActor
    private func glyphs(_ view: AccessibleTerminalView, row: Int = 0, file: StaticString = #filePath, line: UInt = #line) -> [Int: CGGlyph] {
        let runs = view.renderedRowForTesting(row)
        // The grid's cell width is the font advance snapped to the pixel grid; take it from the trailing blanks.
        let blanks = runs.last { $0.glyphs.count > 1 }
        let cellWidth = (blanks.map { $0.glyphX[1] - $0.glyphX[0] }) ?? 0
        var result: [Int: CGGlyph] = [:]
        for run in runs {
            XCTAssertEqual(run.glyphs.count, run.columns.count, "one glyph per cell for ASCII", file: file, line: line)
            for (i, glyph) in run.glyphs.enumerated() {
                let column = run.columns.lowerBound + i
                XCTAssertEqual(run.glyphX[i], CGFloat(column) * cellWidth, accuracy: 0.5, "glyph \(i) on column \(column)", file: file, line: line)
                result[column] = glyph
            }
        }
        return result
    }

    @MainActor
    func testJetBrainsMonoLigaturesFollowTheSetting() throws {
        let (native, view) = try jetBrainsTerminal()
        defer { native.adapter.detach() }
        // Hide the cursor so its cell doesn't split anything.
        native.adapter.receive(Data("\u{1b}[?25la->b != c ab".utf8))
        let on = glyphs(view)
        view.fontLigatures = false
        let off = glyphs(view)
        XCTAssertNotEqual(on[1], off[1], "'-' of '->' is a ligature part")
        XCTAssertNotEqual(on[2], off[2], "'>' of '->' is a ligature part")
        XCTAssertNotEqual(on[5], off[5], "'!' of '!='")
        XCTAssertEqual(on[0], off[0])
        XCTAssertEqual(on[3], off[3], "'b' is unaffected and stays in column 3")
        XCTAssertEqual(on[11], off[11])
        XCTAssertEqual(on[12], off[12])
        view.fontLigatures = true
        XCTAssertEqual(glyphs(view), on, "turning ligatures back on restores them")
    }

    @MainActor
    func testCursorCellIsNeverPartOfALigature() throws {
        let (native, view) = try jetBrainsTerminal()
        defer { native.adapter.detach() }
        native.adapter.receive(Data("a->b\u{1b}[?25l".utf8))
        let joined = glyphs(view)
        // Show the cursor on '>' (column 2).
        native.adapter.receive(Data("\u{1b}[3G\u{1b}[?25h".utf8))
        let split = glyphs(view)
        let (plainNative, plainView) = try jetBrainsTerminal(ligatures: false)
        defer { plainNative.adapter.detach() }
        plainNative.adapter.receive(Data("a->b\u{1b}[?25l".utf8))
        let plain = glyphs(plainView)
        XCTAssertNotEqual(joined[2], plain[2])
        XCTAssertEqual(split[1], plain[1], "the cell before the cursor isn't joined to it")
        XCTAssertEqual(split[2], plain[2], "the cursor cell is drawn on its own")
        let cursorRuns = view.renderedRowForTesting(0).filter { $0.columns == 2..<3 }
        XCTAssertEqual(cursorRuns.count, 1)
    }

    @MainActor
    func testColorAndSelectionKeepLigatureButFontChangeSplitsIt() throws {
        let (native, view) = try jetBrainsTerminal()
        defer { native.adapter.detach() }
        native.adapter.receive(Data("\u{1b}[?25la->b\r\na-\u{1b}[31m>\u{1b}[0mb\r\na-\u{1b}[1m>\u{1b}[0mb".utf8))
        let joined = glyphs(view, row: 0)
        let colored = glyphs(view, row: 1)
        XCTAssertEqual(colored[1], joined[1], "a colour change keeps the ligature; each cell keeps its colour")
        XCTAssertEqual(colored[2], joined[2])
        let redRuns = view.renderedRowForTesting(1).filter { $0.columns == 2..<3 }
        XCTAssertEqual(redRuns.count, 1, "the red cell is its own run")
        let bold = glyphs(view, row: 2)
        XCTAssertNotEqual(bold[1], joined[1], "a different face splits it")
    }

    @MainActor
    func testLigatureFontCarriesContextualAlternates() throws {
        NativeTerminalFont.registerBundledFonts()
        // Only JetBrains Mono among the bundled fonts has programming ligatures (FR-TX01).
        for (name, hasLigatures) in [("JetBrainsMono-Regular", true), ("RobotoMono-Regular", false), ("CascadiaMonoNF-Regular", false)] {
            let font = try XCTUnwrap(NSFont(name: name, size: 13))
            let attributed = NSAttributedString(string: "->", attributes: [.font: font])
            let run = try XCTUnwrap((CTLineGetGlyphRuns(CTLineCreateWithAttributedString(attributed)) as? [CTRun])?.first)
            var shaped = [CGGlyph](repeating: 0, count: 2)
            CTRunGetGlyphs(run, CFRange(), &shaped)
            var characters: [UniChar] = Array("->".utf16)
            var nominal = [CGGlyph](repeating: 0, count: 2)
            XCTAssertTrue(CTFontGetGlyphsForCharacters(font, &characters, &nominal, 2))
            XCTAssertEqual(shaped != nominal, hasLigatures, name)
        }
    }
}
