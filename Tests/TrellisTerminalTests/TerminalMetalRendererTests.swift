import AppKit
import Metal
import XCTest
import SwiftTerm
import TrellisCore
@testable import TrellisTerminal

/// FR-TX05: the Metal renderer follows the setting and draws what the CoreGraphics renderer draws.
final class TerminalMetalRendererTests: XCTestCase {
    /// A terminal in a window (Metal needs one) with the given settings.
    @MainActor
    private func hostedTerminal(_ settings: AppearanceSettings = AppearanceSettings()) throws -> (NativeTerminal, AccessibleTerminalView) {
        _ = NSApplication.shared
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        NativeTerminalFont.registerBundledFonts()
        let native = NativeTerminal()
        native.applyAppearance(settings)
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        addTeardownBlock { @MainActor in window.close() }
        return (native, view)
    }

    @MainActor
    private func jetBrains(ligatures: Bool = true) -> AppearanceSettings {
        var settings = AppearanceSettings()
        settings.fontName = "JetBrainsMono-Regular"
        settings.fontLigatures = ligatures
        return settings
    }

    /// Glyph IDs by column as the Metal renderer places them.
    @MainActor
    private func metalGlyphs(_ view: AccessibleTerminalView, row: Int = 0, file: StaticString = #filePath, line: UInt = #line) throws -> [Int: CGGlyph] {
        let rendered = try XCTUnwrap(view.metalRenderedRowForTesting(row), "Metal is drawing", file: file, line: line)
        var result: [Int: CGGlyph] = [:]
        for run in rendered.runs {
            for (glyph, column) in zip(run.glyphs, run.glyphColumns) { result[column] = glyph }
        }
        return result
    }

    /// Glyph IDs by column as the CoreGraphics renderer places them.
    @MainActor
    private func coreGraphicsGlyphs(_ view: AccessibleTerminalView, row: Int = 0) -> [Int: CGGlyph] {
        var result: [Int: CGGlyph] = [:]
        for run in view.renderedRowForTesting(row) {
            for (i, glyph) in run.glyphs.enumerated() where i < run.columns.count { result[run.columns.lowerBound + i] = glyph }
        }
        return result
    }

    @MainActor
    func testGPURenderingSettingSwitchesRendererOnceInAWindow() throws {
        _ = NSApplication.shared
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        XCTAssertTrue(AppearanceSettings().gpuRendering, "on by default")
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        native.applyAppearance(AppearanceSettings())
        XCTAssertFalse(native.isUsingMetalRenderer, "Metal waits for a window")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }
        window.contentView?.addSubview(native.view)
        XCTAssertTrue(native.isUsingMetalRenderer)
        var off = AppearanceSettings()
        off.gpuRendering = false
        native.applyAppearance(off)
        XCTAssertFalse(native.isUsingMetalRenderer)
        native.applyAppearance(AppearanceSettings())
        XCTAssertTrue(native.isUsingMetalRenderer)
        // Panes move between containers; Metal stays on across the move.
        native.view.removeFromSuperview()
        window.contentView?.addSubview(native.view)
        XCTAssertTrue(native.isUsingMetalRenderer)
    }

    @MainActor
    func testMetalLigaturesMatchCoreGraphicsAndFollowTheSetting() throws {
        let (native, view) = try hostedTerminal(jetBrains())
        defer { native.adapter.detach() }
        XCTAssertTrue(view.isUsingMetalRenderer)
        native.adapter.receive(Data("\u{1b}[?25la->b != c ab".utf8))
        let on = try metalGlyphs(view)
        XCTAssertEqual(on, coreGraphicsGlyphs(view), "Metal places the same glyphs in the same columns")
        native.applyAppearance(jetBrains(ligatures: false))
        let off = try metalGlyphs(view)
        XCTAssertEqual(off, coreGraphicsGlyphs(view))
        XCTAssertNotEqual(on[1], off[1], "turning ligatures off isn't hidden by cached shaping")
        XCTAssertNotEqual(on[5], off[5])
        XCTAssertEqual(on[3], off[3], "'b' stays in column 3")
        native.applyAppearance(jetBrains())
        XCTAssertEqual(try metalGlyphs(view), on, "turning ligatures back on restores them")
    }

    @MainActor
    func testMetalKeepsLigatureAcrossAColorChange() throws {
        let (native, view) = try hostedTerminal(jetBrains())
        defer { native.adapter.detach() }
        native.adapter.receive(Data("\u{1b}[?25la->b\r\na-\u{1b}[31m>\u{1b}[0mb\r\na-\u{1b}[7m>\u{1b}[0mb".utf8))
        let joined = try metalGlyphs(view, row: 0)
        for row in 1...2 {
            let split = try metalGlyphs(view, row: row)
            XCTAssertEqual(split[1], joined[1], "row \(row): a colour change keeps the ligature")
            XCTAssertEqual(split[2], joined[2], "row \(row)")
            XCTAssertEqual(split, coreGraphicsGlyphs(view, row: row), "row \(row)")
        }
    }

    @MainActor
    func testMetalDecorationsCoverWideCellsAndDrawOverline() throws {
        let (native, view) = try hostedTerminal()
        defer { native.adapter.detach() }
        native.adapter.receive(Data("\u{1b}[?25l\u{1b}[4m日\u{1b}[24m\r\n\u{1b}[9m日本\u{1b}[29m\r\n\u{1b}[53mab\u{1b}[55mc\r\n\u{1b}[4:3mabcd".utf8))
        let cell = view.cellMetrics.size
        let underline = try XCTUnwrap(view.metalRenderedRowForTesting(0)).decorations
        XCTAssertEqual(underline.map(\.minX).min() ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(underline.map(\.maxX).max() ?? 0, 2 * cell.width, accuracy: 0.01, "the underline covers both columns of a wide character")
        let strike = try XCTUnwrap(view.metalRenderedRowForTesting(1)).decorations
        XCTAssertEqual(strike.count, 1, "one stroke across the run, not one per glyph")
        XCTAssertEqual(strike.first?.width ?? 0, 4 * cell.width, accuracy: 0.01)
        let overline = try XCTUnwrap(view.metalRenderedRowForTesting(2)).decorations
        XCTAssertEqual(overline.count, 1, "overline is drawn (SGR 53) and cleared (SGR 55)")
        XCTAssertEqual(overline.first?.width ?? 0, 2 * cell.width, accuracy: 0.01)
        XCTAssertGreaterThan(overline.first?.midY ?? 0, cell.height / 2, "above the text")
        XCTAssertLessThanOrEqual(overline.first?.maxY ?? .infinity, cell.height + 0.01, "inside the cell")
        let curly = try XCTUnwrap(view.metalRenderedRowForTesting(3)).decorations
        XCTAssertEqual(curly.map(\.maxX).max() ?? 0, 4 * cell.width, accuracy: 0.01)
        // Phased from the row origin: the wave is continuous across cell boundaries.
        let sorted = curly.sorted { $0.minX < $1.minX }
        for (a, b) in zip(sorted, sorted.dropFirst()) { XCTAssertEqual(a.maxX, b.minX, accuracy: 0.01) }
    }

    @MainActor
    func testMetalCursorHidesConcealedTextAndDrawsTheWholeCharacter() throws {
        let (native, view) = try hostedTerminal()
        defer { native.adapter.detach() }
        view.caretViewTracksFocus = false
        native.adapter.receive(Data("\u{1b}[8mX\u{1b}[28m\u{1b}[D".utf8))
        XCTAssertEqual(try XCTUnwrap(view.metalRenderedRowForTesting(0)).cursorGlyphCount, 0, "concealed text stays hidden under a block cursor")
        native.adapter.receive(Data("\r\nY\u{1b}[D".utf8))
        XCTAssertEqual(try XCTUnwrap(view.metalRenderedRowForTesting(1)).cursorGlyphCount, 1)
        native.adapter.receive(Data("\r\nx\u{0301}\u{1b}[D".utf8))
        XCTAssertGreaterThan(try XCTUnwrap(view.metalRenderedRowForTesting(2)).cursorGlyphCount, 1, "the combining mark is drawn with its base")
    }
}
