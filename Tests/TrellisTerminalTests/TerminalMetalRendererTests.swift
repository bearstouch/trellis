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
    private func hostedTerminal(_ settings: AppearanceSettings = TerminalMetalRendererTests.metalOn()) throws -> (NativeTerminal, AccessibleTerminalView) {
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

    private static func metalOn() -> AppearanceSettings {
        var settings = AppearanceSettings()
        settings.gpuRendering = true
        return settings
    }

    @MainActor
    private func jetBrains(ligatures: Bool = true) -> AppearanceSettings {
        var settings = Self.metalOn()
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
        XCTAssertFalse(AppearanceSettings().gpuRendering, "off by default")
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        native.applyAppearance(Self.metalOn())
        XCTAssertFalse(native.isUsingMetalRenderer, "Metal waits for a window")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }
        window.contentView?.addSubview(native.view)
        XCTAssertTrue(native.isUsingMetalRenderer)
        native.applyAppearance(AppearanceSettings())
        XCTAssertFalse(native.isUsingMetalRenderer)
        native.applyAppearance(Self.metalOn())
        XCTAssertTrue(native.isUsingMetalRenderer)
        // Panes move between containers; Metal stays on across the move.
        native.view.removeFromSuperview()
        window.contentView?.addSubview(native.view)
        XCTAssertTrue(native.isUsingMetalRenderer)
    }

    /// The Metal view covers the grid; a click on it must still give the terminal the keyboard, taking it from a text field
    /// (a sidebar filter, say).
    @MainActor
    func testClickOnMetalTerminalTakesKeyboardFromTextField() throws {
        let (native, view) = try hostedTerminal()
        defer { native.adapter.detach() }
        let window = try XCTUnwrap(view.window)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let field = NSTextField(frame: NSRect(x: 620, y: 10, width: 200, height: 24))
        window.contentView?.addSubview(field)
        XCTAssertTrue(native.isUsingMetalRenderer)
        XCTAssertTrue(window.makeFirstResponder(field))
        let point = view.convert(NSPoint(x: 100, y: 100), to: nil)
        let hit = try XCTUnwrap(window.contentView?.hitTest(window.contentView!.convert(point, from: nil)))
        XCTAssertTrue(hit === view, "the grid, not the Metal view, takes the click")
        // A test runner isn't the active app, so `sendEvent` would only try to make the window key; deliver the click
        // to the hit view as the key window does.
        for (type, deliver) in [(NSEvent.EventType.leftMouseDown, hit.mouseDown), (.leftMouseUp, hit.mouseUp)] {
            deliver(
                try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: 1, pressure: 1)))
        }
        XCTAssertTrue(window.firstResponder === view, "the clicked terminal has the keyboard")
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
    func testMetalDrawsDottedAndDashedUnderlinesAsOneSolidLine() throws {
        let (native, view) = try hostedTerminal()
        defer { native.adapter.detach() }
        native.adapter.receive(Data("\u{1b}[?25l\u{1b}[4:4mabcd\u{1b}[24m\r\n\u{1b}[4:5mabcd\u{1b}[24m".utf8))
        let cell = view.cellMetrics.size
        for row in 0...1 {
            let underline = try XCTUnwrap(view.metalRenderedRowForTesting(row)).decorations
            XCTAssertEqual(underline.count, 1, "row \(row): one continuous stroke, not dots or dashes")
            XCTAssertEqual(underline.first?.width ?? 0, 4 * cell.width, accuracy: 0.01, "row \(row)")
        }
        XCTAssertEqual(view.getTerminal().buffer.getChar(at: Position(col: 0, row: 0)).attribute.underlineStyle, .dotted, "the buffer keeps the requested style")
    }

    @MainActor
    func testMetalUnderlinesLinksWithOneSolidLine() throws {
        let (native, view) = try hostedTerminal()
        defer { native.adapter.detach() }
        view.linkHighlightMode = .always
        native.adapter.receive(Data("\u{1b}[?25l\u{1b}]8;;https://example.com\u{1b}\\link\u{1b}]8;;\u{1b}\\".utf8))
        let underline = try XCTUnwrap(view.metalRenderedRowForTesting(0)).decorations
        XCTAssertEqual(underline.count, 1, "one continuous stroke, not dashes")
        XCTAssertEqual(underline.first?.width ?? 0, 4 * view.cellMetrics.size.width, accuracy: 0.01)
    }

    /// FR-TH10: a translucent CAMetalLayer composites premultiplied pixels; a straight clear color made the
    /// terminal area lighter than the pane margins around it.
    @MainActor
    func testMetalClearsToThePremultipliedBackground() throws {
        let (native, view) = try hostedTerminal()
        defer { native.adapter.detach() }
        let bg = try XCTUnwrap(view.nativeBackgroundColor.usingColorSpace(.deviceRGB))
        let opaque = try XCTUnwrap(view.metalClearColorForTesting)
        XCTAssertEqual(opaque.alpha, 1, accuracy: 0.001)
        XCTAssertEqual(opaque.red, Double(bg.redComponent), accuracy: 0.001, "an opaque background is unchanged")
        var translucent = Self.metalOn()
        translucent.backgroundOpacity = 0.6
        native.applyAppearance(translucent)
        let clear = try XCTUnwrap(view.metalClearColorForTesting)
        XCTAssertEqual(clear.alpha, 0.6, accuracy: 0.001)
        XCTAssertEqual(clear.red, Double(bg.redComponent) * 0.6, accuracy: 0.001)
        XCTAssertEqual(clear.green, Double(bg.greenComponent) * 0.6, accuracy: 0.001)
        XCTAssertEqual(clear.blue, Double(bg.blueComponent) * 0.6, accuracy: 0.001)
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

    /// Smoothing a glyph for a new color pair costs two CoreGraphics draws, so a frame smooths a bounded number and
    /// the following frames finish the rest; output whose colors change every frame can't stall every frame.
    @MainActor
    func testMetalSmoothsNewColorPairsWithinAPerFrameBudget() throws {
        let (native, view) = try hostedTerminal()
        defer { native.adapter.detach() }
        let text = "abcdefghijkl".enumerated().map { i, c in "\u{1b}[38;2;\(20 * i);90;160m\(c)" }.joined()
        native.adapter.receive(Data("\u{1b}[?25l\(text)\u{1b}[0m".utf8))
        let first = try XCTUnwrap(view.metalBuildFrameForTesting(smoothedGlyphBudget: 5))
        XCTAssertEqual(first.smoothedGlyphs, 5)
        XCTAssertTrue(first.needsSmoothingPass, "the rest wait for a later frame")
        XCTAssertEqual(try XCTUnwrap(view.metalBuildFrameForTesting(smoothedGlyphBudget: 5)).smoothedGlyphs, 5, "the provisional row is rebuilt")
        let third = try XCTUnwrap(view.metalBuildFrameForTesting(smoothedGlyphBudget: 5))
        XCTAssertEqual(third.smoothedGlyphs, 2)
        XCTAssertFalse(third.needsSmoothingPass)
        let settled = try XCTUnwrap(view.metalBuildFrameForTesting(smoothedGlyphBudget: 5))
        XCTAssertEqual(settled.smoothedGlyphs, 0, "smoothed glyphs and the finished row are cached")
        XCTAssertFalse(settled.needsSmoothingPass)
    }

    /// Spaces have no atlas entry; without a negative cache every row rebuild asked CoreText for their bounds again.
    @MainActor
    func testMetalRemembersBlankGlyphsAcrossRowRebuilds() throws {
        let (native, view) = try hostedTerminal()
        defer { native.adapter.detach() }
        native.adapter.receive(Data("\u{1b}[?25la b  c\u{1b}[31m d e".utf8))
        XCTAssertGreaterThan(try XCTUnwrap(view.metalBuildFrameForTesting(smoothedGlyphBudget: 256)).glyphCacheMisses, 0)
        native.adapter.receive(Data("\u{1b}[0m\ra b  c\u{1b}[31m d e".utf8))  // rewrites the row in the same colors, so it's rebuilt
        XCTAssertEqual(try XCTUnwrap(view.metalBuildFrameForTesting(smoothedGlyphBudget: 256)).glyphCacheMisses, 0, "letters and spaces both come from cache")
    }

    /// One channel of `glyph` drawn by CoreGraphics in `fg` over `bg`, in a bitmap laid out like the Metal mask.
    private func coreGraphicsPixels(font: CTFont, glyph: CGGlyph, fg: SIMD4<Float>, bg: SIMD4<Float>, width: Int, height: Int, origin: CGPoint, smoothing: Bool) throws -> [Double] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        try pixels.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(
                CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
            func color(_ c: SIMD4<Float>) -> CGColor { CGColor(colorSpace: space, components: [CGFloat(c.x), CGFloat(c.y), CGFloat(c.z), 1])! }
            context.setFillColor(color(bg)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setAllowsFontSmoothing(smoothing); context.setShouldSmoothFonts(smoothing)
            context.setFillColor(color(fg))
            var glyph = glyph; var position = CGPoint(x: -origin.x, y: -origin.y)
            CTFontDrawGlyphs(font, &glyph, &position, 1, context)
        }
        return stride(from: 1, to: pixels.count, by: 4).map { Double(pixels[$0]) / 255 }  // green
    }

    /// Font smoothing thickens strokes by an amount that depends on the colors; a single white mask drew Metal text
    /// visibly heavier than CoreGraphics text in light themes. Blending Metal's mask must give CoreGraphics' pixels.
    @MainActor
    func testMetalGlyphMasksMatchCoreGraphicsSmoothingForEachColorPair() throws {
        NativeTerminalFont.registerBundledFonts()
        let font = CTFontCreateWithName("JetBrainsMono-Regular" as CFString, 24, nil)
        var character: UniChar = 0x6D, glyph: CGGlyph = 0  // "m"
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
        let pairs: [(name: String, fg: SIMD4<Float>, bg: SIMD4<Float>)] = [
            ("black on white", [0, 0, 0, 1], [1, 1, 1, 1]), ("grey on white", [0.23, 0.23, 0.23, 1], [1, 1, 1, 1]),
            ("white on black", [1, 1, 1, 1], [0, 0, 0, 1]), ("green on navy", [0.4, 0.85, 0.5, 1], [0.08, 0.1, 0.2, 1])
        ]
        var ink: [String: Double] = [:]
        for smoothing in [true, false] {
            for pair in pairs {
                let mask = try XCTUnwrap(TerminalView.metalGlyphCoverageForTesting(font: font, glyph: glyph, foreground: pair.fg, background: pair.bg, smoothing: smoothing))
                let reference = try coreGraphicsPixels(font: font, glyph: glyph, fg: pair.fg, bg: pair.bg, width: mask.width, height: mask.height, origin: mask.origin, smoothing: smoothing)
                // What the gray-atlas shader blends: fg * coverage over bg (green channel).
                let blended = mask.coverage.map { Double(pair.bg.y) + Double($0) / 255 * Double(pair.fg.y - pair.bg.y) }
                let worst = zip(blended, reference).map { abs($0 - $1) }.max() ?? 1
                XCTAssertLessThanOrEqual(worst, 3.0 / 255, "\(pair.name), smoothing \(smoothing): every pixel matches CoreGraphics")
                if smoothing { ink[pair.name] = mask.coverage.reduce(0) { $0 + Double($1) } }
            }
        }
        XCTAssertLessThan(try XCTUnwrap(ink["black on white"]), try XCTUnwrap(ink["white on black"]) * 0.95, "dark text on light is thickened less than light text on dark")
    }
}
