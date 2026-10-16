import XCTest
@testable import TrellisCore

final class AppearanceSettingsTests: XCTestCase {
    func testFirstLaunchPalette() {
        let settings = AppearanceSettings()
        XCTAssertEqual(settings.chromeMode, .light)
        XCTAssertEqual(settings.fontName, "Monaco")
        XCTAssertEqual(settings.fontSize, 13)
        XCTAssertEqual(TerminalPalette.builtIn.background, 0x151719)
        XCTAssertEqual(TerminalPalette.builtIn.ansi.count, 16)
        XCTAssertTrue(settings.isValid)
    }
    func testSystemModeVsExplicitMode() {
        for dark in [false, true] {
            XCTAssertFalse(ChromeMode.light.isDark(systemIsDark: dark))
            XCTAssertTrue(ChromeMode.dark.isDark(systemIsDark: dark))
            XCTAssertEqual(ChromeMode.system.isDark(systemIsDark: dark), dark)
        }
        var settings = AppearanceSettings()
        settings.chromeMode = .system
        XCTAssertEqual(settings.themeID(systemIsDark: false), "trellis-light")
        XCTAssertEqual(settings.themeID(systemIsDark: true), "trellis-dark")
    }
    func testMissingMonacoFallback() {
        let menlo = TerminalFontChoice.resolve("Monaco") { $0 == "Menlo" }
        XCTAssertEqual(menlo.name, "Menlo")
        XCTAssertTrue(menlo.notice?.contains("Monaco") == true)
        let system = TerminalFontChoice.resolve("Monaco") { _ in false }
        XCTAssertNil(system.name)
        XCTAssertNotNil(system.notice)
        XCTAssertNil(TerminalFontChoice.resolve("Monaco") { _ in true }.notice)
    }
    func testLegacySettingsAndValidation() throws {
        let old = Data(#"{"shell":"/bin/zsh","directory":"/tmp"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceSettings.self, from: old).appearance, AppearanceSettings())
        var settings = AppearanceSettings()
        settings.fontSize = .nan
        XCTAssertFalse(settings.isValid)
        settings.fontSize = 20; settings.scrollbackLines = -1
        XCTAssertFalse(settings.isValid)
        settings.scrollbackLines = 50000
        let saved = WorkspaceSettings(appearance: settings)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceSettings.self, from: JSONEncoder().encode(saved)), saved)
    }
}
