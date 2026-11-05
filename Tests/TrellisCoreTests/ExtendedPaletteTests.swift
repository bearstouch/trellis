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
        XCTAssertFalse(TerminalPalette.builtIn.hasLightTerminal, "Trellis Light keeps dark panes")
        XCTAssertFalse(try ThemeValidator.validate(ThemeExamples.data(.light)).resolved().terminal.hasLightTerminal)
    }
}
