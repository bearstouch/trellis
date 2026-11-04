import XCTest
@testable import TrellisCore

final class BundledThemesTests: XCTestCase {
    func testAllFamiliesHaveCompleteReadableLightAndDarkPalettes() throws {
        let documents = try BundledThemes.documents()
        XCTAssertEqual(documents.count, 20)
        XCTAssertEqual(Set(documents.map(\.id)).count, 20)
        for family in BundledThemes.families {
            for appearance in ThemeAppearance.allCases {
                let id = "trellis-\(family)-\(appearance.rawValue)"
                let document = try XCTUnwrap(documents.first { $0.id == id })
                XCTAssertEqual(document.appearance, appearance)
                XCTAssertTrue(document.hasReservedID)
                XCTAssertEqual(document.terminal.count, TerminalColorField.allCases.count)
                XCTAssertEqual(document.ui.count, UIColorField.allCases.count)
                XCTAssertEqual(document.ansi?.count, 16)
                let theme = document.resolved()
                XCTAssertTrue(theme.contrastWarnings.isEmpty, "\(id): \(theme.contrastWarnings.map(\.message))")
                let background = try XCTUnwrap(document.terminal[.background])
                XCTAssertEqual(background.relativeLuminance > 0.5, appearance == .light)
                XCTAssertEqual(try ThemeValidator.validate(theme.encoded()).resolved(), theme)
            }
        }
    }

    func testBundledThemesExportAndCannotBeOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = ThemeLibrary(directory: directory)
        for theme in BundledThemes.all {
            let data = try await library.export(theme.id)
            XCTAssertEqual(try ThemeValidator.validate(data).resolved(), theme)
            do {
                _ = try await library.install(data, replace: true)
                XCTFail("Bundled themes must remain immutable")
            } catch { XCTAssertEqual(error as? ThemeLibraryError, .reservedID) }
        }
    }
}

final class BundledFontsTests: XCTestCase {
    func testAllTerminalFacesAreBundledWithLicense() throws {
        let urls = BundledFonts.urls()
        XCTAssertEqual(urls.map { $0.deletingPathExtension().lastPathComponent }, BundledFonts.faces)
        XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let directory = try XCTUnwrap(urls.first?.deletingLastPathComponent())
        XCTAssertEqual(BundledFonts.faces.count, BundledFonts.families.count * 4)
        for family in BundledFonts.families {
            let license = directory.appendingPathComponent(BundledFonts.licenseName(for: family)).appendingPathExtension("txt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: license.path), family)
        }
        XCTAssertTrue(BundledFonts.faces.contains(AppearanceSettings.defaultFontName))
    }
}

final class FocusedPaneHeaderTests: XCTestCase {
    func testEveryBundledThemeKeepsHeaderContentReadableOnTheTint() {
        for theme in BundledThemes.all {
            let tint = theme.focusedPaneHeader
            for field in [UIColorField.foreground, .mutedForeground] {
                XCTAssertGreaterThanOrEqual(theme[field].contrast(against: tint), 4.5, "\(theme.id) \(field)")
            }
            for field in [UIColorField.accent, .focusRing, .warning] {
                XCTAssertGreaterThanOrEqual(theme[field].contrast(against: tint), 3, "\(theme.id) \(field)")
            }
        }
    }

    func testBuiltInThemesActuallyTint() {
        for appearance in ThemeAppearance.allCases {
            let theme = ResolvedTheme.builtIn(appearance)
            XCTAssertNotEqual(theme.focusedPaneHeader, theme[.surface], appearance.rawValue)
        }
    }

    func testAThemeWithNoRoomForATintKeepsItsSurface() throws {
        let theme = try XCTUnwrap(BundledThemes.all.first { $0.id == "trellis-solarized-dark" })
        XCTAssertEqual(theme.focusedPaneHeader, theme[.surface])
    }

    func testAThemeWithLittleRoomGetsAWeakerTint() throws {
        let theme = try XCTUnwrap(BundledThemes.all.first { $0.id == "trellis-nord-dark" })
        XCTAssertEqual(theme.focusedPaneHeader, theme[.surface].mixed(with: theme[.accent], fraction: 0.08))
    }

    func testMixingClampsItsFraction() throws {
        let black = try XCTUnwrap(ThemeColor(hex: "#000000")), white = try XCTUnwrap(ThemeColor(hex: "#FFFFFF"))
        XCTAssertEqual(black.mixed(with: white, fraction: -1), black)
        XCTAssertEqual(black.mixed(with: white, fraction: 2), white)
        XCTAssertEqual(white.mixed(with: black, fraction: .nan), white)
    }

    func testMixingMovesTowardTheOtherColorAndStaysInRange() throws {
        let black = try XCTUnwrap(ThemeColor(hex: "#000000")), white = try XCTUnwrap(ThemeColor(hex: "#FFFFFF"))
        XCTAssertEqual(black.mixed(with: white, fraction: 0), black)
        XCTAssertEqual(black.mixed(with: white, fraction: 1), white)
        XCTAssertEqual(white.mixed(with: black, fraction: 1), black)
        XCTAssertEqual(black.mixed(with: white, fraction: 0.5).hex, "#808080")
    }
}
