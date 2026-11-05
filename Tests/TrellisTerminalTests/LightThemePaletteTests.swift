import AppKit
import SwiftTerm
import TrellisCore
import XCTest
@testable import TrellisTerminal

/// FR-TH09, through the runs both renderers build from.
final class LightThemePaletteTests: XCTestCase {
    private func palette(_ id: String) throws -> TerminalPalette {
        try XCTUnwrap(BundledThemes.documents().first { $0.id == id }).resolved().terminal
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
    private func run(at column: Int, in view: AccessibleTerminalView) throws -> RenderedRunForTesting {
        try XCTUnwrap(view.renderedRowForTesting(0).first { $0.columns.contains(column) }, "a run covers column \(column)")
    }

    private func rgb(_ color: CGColor?) throws -> UInt32 {
        let components = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(color))?.usingColorSpace(.sRGB))
        func channel(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
        return channel(components.redComponent) << 16 | channel(components.greenComponent) << 8 | channel(components.blueComponent)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) throws -> Double {
        let (first, second) = (try XCTUnwrap(ThemeColor(hex: String(format: "#%06X", a))), try XCTUnwrap(ThemeColor(hex: String(format: "#%06X", b))))
        return first.contrast(against: second)
    }

    @MainActor
    func testPromptPanelsFollowEveryLightTheme() throws {
        for family in BundledThemes.families {
            let theme = try palette("trellis-\(family)-light")
            let (native, view) = try terminal(theme, "\u{1b}[38;5;76;48;5;234mprompt\u{1b}[0m \u{1b}[38;5;254;44mbox\u{1b}[0m")
            defer { native.adapter.detach() }
            let panel = try run(at: 0, in: view)
            let panelBackground = try rgb(panel.backgroundColor)
            XCTAssertEqual(panelBackground, theme.extendedColors()[234 - 16], family)
            XCTAssertNotEqual(panelBackground, 0x1C1C1C, family)
            XCTAssertGreaterThanOrEqual(try contrast(rgb(panel.foregroundColor), panelBackground), 4.45, family)
            let box = try run(at: 7, in: view)
            XCTAssertGreaterThanOrEqual(try contrast(rgb(box.foregroundColor), rgb(box.backgroundColor)), 4.45, "\(family): light text on ANSI blue")
        }
    }

    @MainActor
    func testTrueColorIsNeverAdjusted() throws {
        let theme = try palette("trellis-github-light")
        let (native, view) = try terminal(theme, "\u{1b}[38;2;250;250;250;48;5;234mT\u{1b}[0m\u{1b}[48;2;28;28;28;38;2;30;30;30mU\u{1b}[0m")
        defer { native.adapter.detach() }
        XCTAssertEqual(try rgb(run(at: 0, in: view).foregroundColor), 0xFAFAFA)
        XCTAssertEqual(try rgb(run(at: 1, in: view).backgroundColor), 0x1C1C1C)
        XCTAssertEqual(try rgb(run(at: 1, in: view).foregroundColor), 0x1E1E1E)
    }

    @MainActor
    func testNearlyInvisibleBaseColorPairsAreLiftedOnEveryLightTheme() throws {
        for family in BundledThemes.families {
            let theme = try palette("trellis-\(family)-light")
            // Black on default, default on white, default on bright white, bright white on white.
            let (native, view) = try terminal(theme, "\u{1b}[30mA\u{1b}[0m\u{1b}[47mB\u{1b}[0m\u{1b}[107mC\u{1b}[0m\u{1b}[97;47mD\u{1b}[0m")
            defer { native.adapter.detach() }
            XCTAssertGreaterThanOrEqual(try contrast(rgb(run(at: 0, in: view).foregroundColor), theme.background), 4.45, "\(family): 30 on default")
            for column in 1...3 {
                let cell = try run(at: column, in: view)
                XCTAssertGreaterThanOrEqual(try contrast(rgb(cell.foregroundColor), rgb(cell.backgroundColor)), 4.45, "\(family): column \(column)")
            }
        }
    }

    @MainActor
    func testReadableBaseColorsAndSameIndexPairsKeepTheThemesExactValues() throws {
        for family in BundledThemes.families {
            let theme = try palette("trellis-\(family)-light")
            let (native, view) = try terminal(theme, "\u{1b}[31mA\u{1b}[0m\u{1b}[94mB\u{1b}[0m\u{1b}[37;47mC\u{1b}[0m\u{1b}[30;40mD\u{1b}[0mE")
            defer { native.adapter.detach() }
            XCTAssertEqual(try rgb(run(at: 0, in: view).foregroundColor), theme.ansi[1], family)
            XCTAssertEqual(try rgb(run(at: 1, in: view).foregroundColor), theme.ansi[12], family)
            XCTAssertEqual(try rgb(run(at: 2, in: view).foregroundColor), theme.ansi[7], "\(family): hidden on purpose")
            XCTAssertEqual(try rgb(run(at: 3, in: view).foregroundColor), theme.ansi[0], "\(family): hidden on purpose")
            XCTAssertEqual(try rgb(run(at: 4, in: view).foregroundColor), theme.foreground, family)
        }
    }

    @MainActor
    func testDarkTerminalsAndTrueColorBackgroundsKeepBaseColors() throws {
        let dark = try palette("trellis-github-dark")
        let (darkNative, darkView) = try terminal(dark, "\u{1b}[30mA\u{1b}[0m")
        defer { darkNative.adapter.detach() }
        XCTAssertEqual(try rgb(run(at: 0, in: darkView).foregroundColor), dark.ansi[0], "no lift on dark terminals")
        let light = try palette("trellis-github-light")
        let (native, view) = try terminal(light, "\u{1b}[48;2;28;28;28mA\u{1b}[0m")
        defer { native.adapter.detach() }
        XCTAssertEqual(try rgb(run(at: 0, in: view).foregroundColor), light.foreground, "a true-color pair stays as sent")
    }

    @MainActor
    func testBoxLinesFollowBaseColorTextButOtherShapesKeepTheirColor() throws {
        let theme = try palette("trellis-github-light")
        // Box line, Powerline separator and half block, each in default text on ANSI white.
        let (native, view) = try terminal(theme, "\u{1b}[47m\u{2502}\u{E0B0}\u{2580}\u{1b}[0m")
        defer { native.adapter.detach() }
        let line = try run(at: 0, in: view)
        XCTAssertGreaterThanOrEqual(try contrast(rgb(line.foregroundColor), rgb(line.backgroundColor)), 4.45, "a frame stays visible")
        XCTAssertEqual(try rgb(run(at: 2, in: view).foregroundColor), theme.foreground, "a block keeps its color")
    }

    @MainActor
    func testBaseColorLiftFollowsInverseAndScreenReverse() throws {
        let theme = try palette("trellis-github-light")
        let (native, view) = try terminal(theme, "\u{1b}[7;30mA\u{1b}[0m\u{1b}[7mB\u{1b}[0m")
        defer { native.adapter.detach() }
        let lifted = try run(at: 0, in: view), plain = try run(at: 1, in: view)
        XCTAssertGreaterThanOrEqual(try contrast(rgb(lifted.foregroundColor), rgb(lifted.backgroundColor)), 4.45, "reversed black")
        XCTAssertEqual(try rgb(plain.backgroundColor), theme.foreground, "plain reverse video keeps the swapped pair")
        XCTAssertEqual(try rgb(plain.foregroundColor), theme.background)
        native.adapter.receive(Data("\u{1b}[?5h".utf8))
        let screen = try run(at: 0, in: view)
        XCTAssertGreaterThanOrEqual(try contrast(rgb(screen.foregroundColor), rgb(screen.backgroundColor)), 4.45, "DECSCNM doesn't reuse stale colors")
    }

    @MainActor
    func testSameIndexPairStaysHiddenAndShapesKeepTheirColor() throws {
        let theme = try palette("trellis-github-light")
        let panel = theme.extendedColors()[234 - 16]
        // Hidden text, then a Powerline separator and a box line drawn in the panel's color on the default background.
        let (native, view) = try terminal(theme, "\u{1b}[38;5;234;48;5;234mH\u{1b}[0m\u{1b}[38;5;234mX\u{1b}[0m\u{1b}[38;5;234m\u{E0B0}\u{2502}\u{1b}[0m")
        defer { native.adapter.detach() }
        XCTAssertEqual(try rgb(run(at: 0, in: view).foregroundColor), panel)
        XCTAssertNotEqual(try rgb(run(at: 1, in: view).foregroundColor), panel, "text is lifted")
        XCTAssertEqual(try rgb(run(at: 2, in: view).foregroundColor), panel, "a Powerline separator is not")
        XCTAssertEqual(try rgb(run(at: 3, in: view).foregroundColor), panel, "a box line is not")
    }

    @MainActor
    func testSwitchingThemesRestoresEachModeExactly() throws {
        let light = try palette("trellis-github-light"), dark = try palette("trellis-github-dark")
        let (native, view) = try terminal(light, "\u{1b}[38;5;76;48;5;234mX\u{1b}[0m")
        defer { native.adapter.detach() }
        XCTAssertEqual(try rgb(run(at: 0, in: view).backgroundColor), light.extendedColors()[234 - 16])
        native.applyPalette(dark)
        XCTAssertEqual(try rgb(run(at: 0, in: view).backgroundColor), 0x1C1C1C)
        XCTAssertEqual(try rgb(run(at: 0, in: view).foregroundColor), 0x5FD700, "the floor is off on dark terminals")
        native.applyPalette(light)
        XCTAssertEqual(try rgb(run(at: 0, in: view).backgroundColor), light.extendedColors()[234 - 16])
    }

    @MainActor
    func testInsertedColumnsUseTheDefaultBackground() throws {
        let theme = try palette("trellis-github-light")
        // DECIC, then DECBI at the left margin: both shift cells right and must not fill with reverse video.
        let (native, view) = try terminal(theme, "ABCD\u{1b}[2D\u{1b}[2\u{27}}")
        defer { native.adapter.detach() }
        for column in 2...3 { XCTAssertEqual(try rgb(run(at: column, in: view).backgroundColor), theme.background) }
        native.adapter.receive(Data("\r\u{1b}6".utf8))
        XCTAssertEqual(try rgb(run(at: 0, in: view).backgroundColor), theme.background)
    }

    @MainActor
    func testApplicationOverridesSurviveBaseColorChangesAndOSC104RestoresThePalette() throws {
        let theme = try palette("trellis-github-light")
        // One index for both colors is never adjusted, so the run shows the palette entry itself.
        let cell = "\u{1b}[38;5;100;48;5;100mX\u{1b}[0m"
        let (native, view) = try terminal(theme, "\u{1b}]4;100;#123456\u{7}\u{1b}]11;#EEEEEE\u{7}\(cell)")
        defer { native.adapter.detach() }
        XCTAssertEqual(try rgb(run(at: 0, in: view).foregroundColor), 0x123456, "OSC 11 must not wipe an OSC 4 override")
        native.adapter.receive(Data("\u{1b}]104\u{7}\r\(cell)".utf8))
        XCTAssertEqual(try rgb(run(at: 0, in: view).foregroundColor), theme.extendedColors()[100 - 16], "OSC 104 restores the derived palette")
    }
}
