import AppKit
import SwiftTerm
import TrellisCore
import XCTest
@testable import TrellisTerminal

/// FR-TH09 paths the main tests don't reach: Powerline icons, reverse video, resets and wide cells.
final class LightThemePaletteReviewTests: XCTestCase {
    private func theme() throws -> TerminalPalette {
        try XCTUnwrap(BundledThemes.documents().first { $0.id == "trellis-github-light" }).resolved().terminal
    }

    @MainActor
    private func terminal(_ palette: TerminalPalette, _ output: String) throws -> (NativeTerminal, AccessibleTerminalView) {
        _ = NSApplication.shared
        let native = NativeTerminal()
        native.applyPalette(palette)
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        native.adapter.receive(Data(output.utf8))
        return (native, view)
    }

    @MainActor
    private func colors(at column: Int, in view: AccessibleTerminalView) throws -> (fg: UInt32, bg: UInt32) {
        let run = try XCTUnwrap(view.renderedRowForTesting(0).first { $0.columns.contains(column) }, "a run covers column \(column)")
        return (try rgb(run.foregroundColor), try rgb(run.backgroundColor))
    }

    private func rgb(_ color: CGColor?) throws -> UInt32 {
        let components = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(color))?.usingColorSpace(.sRGB))
        func channel(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
        return channel(components.redComponent) << 16 | channel(components.greenComponent) << 8 | channel(components.blueComponent)
    }

    private func contrast(_ pair: (fg: UInt32, bg: UInt32)) throws -> Double {
        let first = try XCTUnwrap(ThemeColor(hex: String(format: "#%06X", pair.fg))), second = try XCTUnwrap(ThemeColor(hex: String(format: "#%06X", pair.bg)))
        return first.contrast(against: second)
    }

    @MainActor
    func testPowerlineIconsReadLikeTheTextBesideThemWhileSeparatorsKeepTheirColor() throws {
        let palette = try theme()
        // A branch icon and a lock are text in the prompt; the separator is a shape.
        let (native, view) = try terminal(palette, "\u{1b}[38;5;76;48;5;234ma\u{E0A0}\u{E0A2}\u{E0B0}\u{1b}[0m")
        defer { native.adapter.detach() }
        let text = try colors(at: 0, in: view)
        XCTAssertEqual(try colors(at: 1, in: view).fg, text.fg)
        XCTAssertEqual(try colors(at: 2, in: view).fg, text.fg)
        XCTAssertEqual(try colors(at: 3, in: view).fg, palette.extendedColors()[76 - 16])
    }

    @MainActor
    func testInverseCellsLiftTextButLeaveSeparatorsRaw() throws {
        let palette = try theme()
        let (native, view) = try terminal(palette, "\u{1b}[7;38;5;234m\u{E0B0}x\u{1b}[0m")
        defer { native.adapter.detach() }
        let panel = palette.extendedColors()[234 - 16]
        let separator = try colors(at: 0, in: view)
        XCTAssertEqual(separator.fg, palette.background)
        XCTAssertEqual(separator.bg, panel)
        let text = try colors(at: 1, in: view)
        XCTAssertEqual(text.bg, panel)
        XCTAssertGreaterThanOrEqual(try contrast(text), 4.45)
    }

    @MainActor
    func testReverseScreenModeLiftsAgainstTheSwappedBackgroundAndRecoversWhenOff() throws {
        let palette = try theme()
        let (native, view) = try terminal(palette, "\u{1b}[?5h\u{1b}[38;5;76mx\u{1b}[0m")
        defer { native.adapter.detach() }
        let reversed = try colors(at: 0, in: view)
        XCTAssertEqual(reversed.bg, palette.foreground)
        XCTAssertGreaterThanOrEqual(try contrast(reversed), 4.45)
        native.adapter.receive(Data("\u{1b}[?5l".utf8))
        XCTAssertEqual(try colors(at: 0, in: view).bg, palette.background)
        XCTAssertEqual(try colors(at: 0, in: view).fg, palette.extendedColors()[76 - 16], "already readable on the normal background")
    }

    @MainActor
    func testSoftResetAndResizeKeepTheDerivedPalette() throws {
        let palette = try theme()
        let panel = palette.extendedColors()[234 - 16]
        let (native, view) = try terminal(palette, "\u{1b}]4;234;#112233\u{7}\u{1b}[48;5;234mx\u{1b}[0m")
        defer { native.adapter.detach() }
        XCTAssertEqual(try colors(at: 0, in: view).bg, 0x112233)
        native.adapter.receive(Data("\u{1b}[!p".utf8))
        XCTAssertEqual(try colors(at: 0, in: view).bg, panel, "DECSTR restores the derived value, not xterm's")
        view.getTerminal().resize(cols: 50, rows: 20)
        XCTAssertEqual(try colors(at: 0, in: view).bg, panel)
    }

    @MainActor
    func testWideAndClusterCellsAreLiftedAsText() throws {
        let palette = try theme()
        // Index 16 is the background itself. A cluster's code is a table index, never a code point in an exempt range.
        let (native, view) = try terminal(palette, "\u{1b}[38;5;16m\u{6F22}\u{1F469}\u{200D}\u{1F4BB}e\u{301}\u{1b}[0m")
        defer { native.adapter.detach() }
        for column in [0, 2, 4] {
            XCTAssertGreaterThanOrEqual(try contrast(colors(at: column, in: view)), 4.45, "column \(column)")
        }
    }
}
