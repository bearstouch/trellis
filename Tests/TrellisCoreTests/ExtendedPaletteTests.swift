import XCTest
@testable import TrellisCore

final class ExtendedPaletteTests: XCTestCase {
    private func color(_ palette: TerminalPalette, _ index: Int) -> ThemeColor { ThemeColor(palette.extendedColors()[index - 16]) }

    func testEveryLightFamilyDerivesItsPaletteFromTheTheme() throws {
        for document in try BundledThemes.documents() where document.appearance == .light {
            let palette = document.resolved().terminal
            XCTAssertTrue(palette.hasLightTerminal, document.id)
            XCTAssertEqual(palette.extendedColors().count, 240, document.id)
            XCTAssertEqual(palette.extendedColors()[0], palette.background, "\(document.id): 16 is the background")
            XCTAssertEqual(palette.extendedColors()[231 - 16], palette.foreground, "\(document.id): 231 is the foreground")
        }
    }

    func testDarkPanelIndexesBecomeSoftTintsOnLightTerminals() throws {
        for document in try BundledThemes.documents() where document.appearance == .light {
            let palette = document.resolved().terminal
            for index in 232...238 {
                XCTAssertLessThan(color(palette, index).contrast(against: ThemeColor(palette.background)), 2, "\(document.id): \(index)")
            }
            XCTAssertLessThan(color(palette, 234).contrast(against: ThemeColor(palette.background)), 1.5, document.id)
        }
    }

    func testGreyRampRunsFromBackgroundToForeground() throws {
        for document in try BundledThemes.documents() where document.appearance == .light {
            let palette = document.resolved().terminal
            let contrasts = (232...255).map { color(palette, $0).contrast(against: ThemeColor(palette.background)) }
            XCTAssertEqual(contrasts, contrasts.sorted(), document.id)
        }
    }

    func testDarkTerminalsAreNotLightEvenWithLightChrome() throws {
        for document in try BundledThemes.documents() where document.appearance == .dark {
            XCTAssertFalse(document.resolved().terminal.hasLightTerminal, document.id)
        }
        XCTAssertFalse(TerminalPalette.builtIn.hasLightTerminal, "Trellis Dark")
        XCTAssertFalse(try ThemeValidator.validate(ThemeExamples.data(.light)).resolved().terminal.hasLightTerminal)
    }

    func testTrellisLightHasAWhiteTerminalWithReadableColors() {
        let palette = ResolvedTheme.builtIn(.light).terminal
        XCTAssertEqual(palette, .builtInLight)
        XCTAssertEqual(palette.background, 0xFFFFFF)
        XCTAssertTrue(palette.hasLightTerminal)
        XCTAssertEqual(ResolvedTheme.builtIn(.dark).terminal, .builtIn, "Trellis Dark keeps its panes")
        for index in 1...15 {
            XCTAssertGreaterThanOrEqual(ThemeColor(palette.ansi[index]).contrast(against: ThemeColor(palette.background)), 4.5, "ANSI \(index)")
        }
        XCTAssertEqual(palette.extendedColors()[0], 0xFFFFFF, "16 is the background")
    }

    func testLightThemesInheritTheTerminalThatMatchesTheirBackground() throws {
        func document(_ terminal: String) throws -> ResolvedTheme {
            let json = #"{"version":1,"id":"custom","name":"Custom","appearance":"light","terminal":{\#(terminal)}}"#
            return try ThemeValidator.validate(Data(json.utf8)).resolved()
        }
        let dark = try document(##""background":"#141820""##).terminal
        XCTAssertEqual(dark.foreground, TerminalPalette.builtIn.foreground, "dark panes keep light text")
        XCTAssertEqual(dark.ansi, TerminalPalette.builtIn.ansi)
        XCTAssertEqual(try document(##""background":"#F4F4F4""##).terminal.foreground, TerminalPalette.builtInLight.foreground)
        XCTAssertEqual(try document("").terminal, .builtInLight)
        // Written against the old dark default: these must not land on a white terminal.
        XCTAssertEqual(try document(##""foreground":"#E8EEF4""##).terminal.background, TerminalPalette.builtIn.background)
        XCTAssertEqual(try document(##""selectionBackground":"#354C6A""##).terminal.background, TerminalPalette.builtIn.background)
        let ansi = String(repeating: ##""#F0F0F0","##, count: 15) + ##""#F0F0F0""##
        XCTAssertEqual(try document(#""ansi":[\#(ansi)]"#).terminal.background, TerminalPalette.builtIn.background)
        XCTAssertEqual(try document(##""foreground":"#123456""##).terminal.background, 0xFFFFFF, "dark text means a light terminal")
    }
}
