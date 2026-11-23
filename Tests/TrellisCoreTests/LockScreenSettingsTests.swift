import XCTest
@testable import TrellisCore

/// FR-LK01, FR-LK05: the lock screen setting and the Lock Trellis shortcut.
final class LockScreenSettingsTests: XCTestCase {
    private func json() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppearanceSettings())) as? [String: Any])
    }
    private func decode(_ json: [String: Any]) throws -> AppearanceSettings {
        try JSONDecoder().decode(AppearanceSettings.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testVaultDialIsTheDefaultOfFiveStyles() {
        XCTAssertEqual(AppearanceSettings().lockScreen, .vaultDial)
        XCTAssertEqual(LockScreenStyle.allCases, [.vaultDial, .redactedShell, .cipherWall, .ridgelines, .signalLost])
        XCTAssertEqual(Set(LockScreenStyle.allCases.map(\.displayName)).count, 5)
    }

    func testSettingsSavedBeforeTheLockScreenLoadTheDefaultAndKeepTheRest() throws {
        var legacy = try json()
        legacy["lockScreen"] = nil; legacy["chromeMode"] = "light"
        let decoded = try decode(legacy)
        XCTAssertEqual(decoded.lockScreen, .vaultDial)
        XCTAssertEqual(decoded.chromeMode, .light)
    }

    func testUnknownStyleFallsBackInsteadOfDiscardingAppearance() throws {
        var newer = try json()
        newer["lockScreen"] = "aquarium"; newer["chromeMode"] = "light"; newer["idleScreensaver"] = "plasma"
        let decoded = try decode(newer)
        XCTAssertEqual(decoded.lockScreen, .vaultDial)
        XCTAssertEqual(decoded.chromeMode, .light)
        XCTAssertEqual(decoded.idleScreensaver, .plasma)
        XCTAssertTrue(decoded.isValid)
    }

    func testChosenStyleRoundTripsAndNeverRestylesTerminals() throws {
        var settings = AppearanceSettings()
        settings.lockScreen = .signalLost
        XCTAssertEqual(try JSONDecoder().decode(AppearanceSettings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertFalse(settings.terminalRenderingDiffers(from: AppearanceSettings()))
    }

    func testLockShortcutDefaultsToControlCommandLInTheWindowMenu() {
        XCTAssertEqual(ShortcutMap.defaults[.lockWorkspace], KeyChord("l", [.command, .control]))
        XCTAssertEqual(ShortcutAction.lockWorkspace.menu, .window)
        XCTAssertEqual(ShortcutAction.lockWorkspace.title, "Lock Trellis")
        XCTAssertTrue(ShortcutMap.defaults.issues().isEmpty, "⌃⌘L clashes with no other default")
        XCTAssertNil(ShortcutAction.lockWorkspace.tabIndex)
    }

    func testLockDefaultYieldsToAChordTheUserAlreadyChose() throws {
        let chord = String(decoding: try JSONEncoder().encode(KeyChord("l", [.command, .control])), as: UTF8.self)
        let data = Data(#"{"optionAsMeta":false,"overrides":{"renameTab":{"chord":\#(chord)}}}"#.utf8)
        let loaded = try JSONDecoder().decode(KeyboardSettings.self, from: data)
        XCTAssertEqual(loaded.shortcuts[.renameTab], KeyChord("l", [.command, .control]))
        XCTAssertNil(loaded.shortcuts[.lockWorkspace], "A chord the user already chose keeps working; Lock Trellis starts unbound")
        XCTAssertTrue(loaded.shortcuts.issues().isEmpty)
    }
}
