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
