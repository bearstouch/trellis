import XCTest
@testable import TrellisCore

final class AppearanceSettingsTests: XCTestCase {
    func testBundledAppIconIsAPNG() throws {
        let data = try Data(contentsOf: XCTUnwrap(BundledAppIcon.url()))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
    func testSettingsSavedBeforeBellStyleLoadAsSoundAndKeepTheirMode() throws {
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppearanceSettings())) as? [String: Any])
        legacy["bellStyle"] = nil; legacy["chromeMode"] = "light"
        let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.bellStyle, .sound)
        XCTAssertEqual(decoded.chromeMode, .light)
        XCTAssertTrue(decoded.desktopNotifications, "Settings saved before FR-T08 keep notifications on")
        XCTAssertEqual(decoded.commandFinishedNotificationSeconds, 10, "Settings saved before FR-SI08 notify after 10 s")
        legacy["commandFinishedNotificationSeconds"] = 7
        let unknown = try JSONDecoder().decode(AppearanceSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(unknown.commandFinishedNotificationSeconds, 10, "An unoffered threshold falls back to the default")
        XCTAssertEqual(unknown.chromeMode, .light)
        legacy["commandFinishedNotificationSeconds"] = nil
        legacy["bellStyle"] = "chime"
        XCTAssertEqual(try JSONDecoder().decode(AppearanceSettings.self, from: JSONSerialization.data(withJSONObject: legacy)).bellStyle, .sound)
    }
    func testSettingsSavedWithRobotoMonoKeepItAfterTheDefaultChange() throws {
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppearanceSettings())) as? [String: Any])
        legacy["fontName"] = "RobotoMono-Regular"
        let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.fontName, "RobotoMono-Regular")
        XCTAssertEqual(AppearanceSettings().fontName, "JetBrainsMono-Regular")
    }
    func testSettingsSavedBeforeGPURenderingLoadWithMetalOff() throws {
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppearanceSettings())) as? [String: Any])
        legacy["gpuRendering"] = nil; legacy["fontLigatures"] = false
        let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(decoded.gpuRendering)
        XCTAssertFalse(decoded.fontLigatures, "other settings are kept")
    }
    func testFirstLaunchPalette() {
        let settings = AppearanceSettings()
        XCTAssertEqual(settings.chromeMode, .dark)
        XCTAssertEqual(settings.bellStyle, .sound)
        XCTAssertTrue(settings.desktopNotifications)
        XCTAssertEqual(settings.commandFinishedNotificationSeconds, 10)
        XCTAssertEqual(settings.fontName, "JetBrainsMono-Regular")
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
    func testTextRenderingDefaults() {
        let settings = AppearanceSettings()
        XCTAssertTrue(settings.fontLigatures)
        XCTAssertTrue(settings.boldAsBright)
        XCTAssertTrue(settings.allowBoldFont)
        XCTAssertTrue(settings.allowItalicFont)
        XCTAssertTrue(settings.blinkingText)
        XCTAssertFalse(settings.gpuRendering, "FR-TX05: Metal is opt-in")
    }
    func testAppearanceWithoutTextRenderingKeysDecodesWithDefaults() throws {
        // The appearance object as saved before FR-TX01/FR-TX03.
        let appearance = #"{"chromeMode":"dark","fontName":"Menlo","fontSize":15,"cursorShape":"bar","cursorBlinks":true,"scrollbackLines":500,"lightThemeID":"trellis-light","darkThemeID":"trellis-dark"}"#
        let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: Data(appearance.utf8))
        var expected = AppearanceSettings()
        expected.chromeMode = .dark; expected.fontName = "Menlo"; expected.fontSize = 15
        expected.cursorShape = .bar; expected.cursorBlinks = true; expected.scrollbackLines = 500
        XCTAssertEqual(decoded, expected)
        let workspace = Data(#"{"shell":"/bin/zsh","directory":"/tmp","appearance":\#(appearance)}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceSettings.self, from: workspace).appearance, expected)
    }
    func testTextRenderingRoundTrip() throws {
        var settings = AppearanceSettings()
        settings.fontLigatures = false; settings.boldAsBright = false; settings.allowBoldFont = false
        settings.allowItalicFont = false; settings.blinkingText = false; settings.bellStyle = .visual
        settings.desktopNotifications = false; settings.commandFinishedNotificationSeconds = 0
        settings.gpuRendering = true
        XCTAssertEqual(try JSONDecoder().decode(AppearanceSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
    func testTerminalRenderingDiffersCoversTextStyleFields() {
        let base = AppearanceSettings()
        var themeOnly = base
        themeOnly.chromeMode = .dark; themeOnly.darkThemeID = "custom-dark"; themeOnly.lightThemeID = "custom-light"
        XCTAssertFalse(base.terminalRenderingDiffers(from: themeOnly))
        themeOnly.desktopNotifications = false
        XCTAssertFalse(base.terminalRenderingDiffers(from: themeOnly), "The notification toggle never touches terminals")
        themeOnly.commandFinishedNotificationSeconds = 60
        XCTAssertFalse(base.terminalRenderingDiffers(from: themeOnly), "Nor does the command-finished threshold")
        var invalid = base
        invalid.commandFinishedNotificationSeconds = 7
        XCTAssertFalse(invalid.isValid)
        let changes: [(inout AppearanceSettings) -> Void] = [
            { $0.fontName = "Menlo" }, { $0.fontSize = 14 }, { $0.cursorShape = .bar }, { $0.cursorBlinks = true },
            { $0.scrollbackLines = 1 }, { $0.fontLigatures = false }, { $0.boldAsBright = false },
            { $0.allowBoldFont = false }, { $0.allowItalicFont = false }, { $0.blinkingText = false }, { $0.gpuRendering = true },
            { $0.bellStyle = .off }
        ]
        for (index, change) in changes.enumerated() {
            var changed = base
            change(&changed)
            XCTAssertTrue(base.terminalRenderingDiffers(from: changed), "change \(index)")
        }
    }
}
