import XCTest
@testable import TrellisCore

/// FR-SS01, FR-SS02: the screensaver setting and the idle countdown.
final class IdleScreensaverTests: XCTestCase {
    private func legacyJSON() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppearanceSettings())) as? [String: Any])
    }
    private func decode(_ json: [String: Any]) throws -> AppearanceSettings {
        try JSONDecoder().decode(AppearanceSettings.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testScreensaverIsOffByDefaultWithAFiveMinuteDelay() {
        XCTAssertEqual(AppearanceSettings().idleScreensaver, .off)
        XCTAssertEqual(AppearanceSettings().idleScreensaverDelaySeconds, 300)
        XCTAssertTrue(IdleScreensaverDelay.choices.contains(IdleScreensaverDelay.defaultSeconds))
        XCTAssertEqual(IdleScreensaverStyle.animations.count, 5)
        XCTAssertFalse(IdleScreensaverStyle.animations.contains(.off))
    }

    func testSettingsSavedBeforeTheScreensaverLoadOffAndKeepTheRest() throws {
        var legacy = try legacyJSON()
        legacy["idleScreensaver"] = nil; legacy["idleScreensaverDelaySeconds"] = nil; legacy["chromeMode"] = "light"
        let decoded = try decode(legacy)
        XCTAssertEqual(decoded.idleScreensaver, .off)
        XCTAssertEqual(decoded.idleScreensaverDelaySeconds, 300)
        XCTAssertEqual(decoded.chromeMode, .light)
    }

    func testUnknownStyleOrDelayFallsBackInsteadOfDiscardingAppearance() throws {
        var json = try legacyJSON()
        json["idleScreensaver"] = "starfield"; json["idleScreensaverDelaySeconds"] = 7; json["chromeMode"] = "light"
        let decoded = try decode(json)
        XCTAssertEqual(decoded.idleScreensaver, .off)
        XCTAssertEqual(decoded.idleScreensaverDelaySeconds, 300)
        XCTAssertEqual(decoded.chromeMode, .light)
        XCTAssertTrue(decoded.isValid)
    }

    func testChosenStyleAndDelayRoundTrip() throws {
        var settings = AppearanceSettings()
        settings.idleScreensaver = .hexSpirals; settings.idleScreensaverDelaySeconds = 30
        XCTAssertEqual(try JSONDecoder().decode(AppearanceSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testDelayOutsideTheChoicesIsInvalid() {
        var settings = AppearanceSettings()
        settings.idleScreensaverDelaySeconds = 45
        XCTAssertFalse(settings.isValid)
        XCTAssertEqual(IdleScreensaverDelay.normalized(45), 300)
        XCTAssertEqual(IdleScreensaverDelay.normalized(600), 600)
    }

    func testScreensaverChangesNeverRestyleTerminals() {
        var settings = AppearanceSettings()
        settings.idleScreensaver = .plasma; settings.idleScreensaverDelaySeconds = 60
        XCTAssertFalse(settings.terminalRenderingDiffers(from: AppearanceSettings()))
    }

    func testDelayLabels() {
        XCTAssertEqual(IdleScreensaverDelay.label(seconds: 30), "30 seconds")
        XCTAssertEqual(IdleScreensaverDelay.label(seconds: 60), "1 minute")
        XCTAssertEqual(IdleScreensaverDelay.label(seconds: 300), "5 minutes")
        XCTAssertEqual(IdleScreensaverDelay.label(seconds: 3600), "1 hour")
    }

    func testClockCountsFromLastActivityAndRestartsForAnotherPane() {
        let start = Date(timeIntervalSince1970: 1000), a = UUID(), b = UUID()
        var clock = IdleScreensaverClock(now: start)
        XCTAssertFalse(clock.isIdle(at: start.addingTimeInterval(1000), delay: 60), "Nothing watched is never idle")
        clock.watch(a, at: start)
        XCTAssertFalse(clock.isIdle(at: start.addingTimeInterval(59), delay: 60))
        XCTAssertTrue(clock.isIdle(at: start.addingTimeInterval(60), delay: 60))
        clock.noteActivity(at: start.addingTimeInterval(50))
        XCTAssertFalse(clock.isIdle(at: start.addingTimeInterval(100), delay: 60))
        clock.watch(a, at: start.addingTimeInterval(200))
        XCTAssertTrue(clock.isIdle(at: start.addingTimeInterval(200), delay: 60), "Watching the same pane keeps its countdown")
        clock.watch(b, at: start.addingTimeInterval(200))
        XCTAssertFalse(clock.isIdle(at: start.addingTimeInterval(200), delay: 60), "Another pane starts its own countdown")
    }
}
