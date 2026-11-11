import AppKit
import XCTest
@testable import TrellisCore
import TrellisTerminal
@testable import TrellisUI

final class LanguageSettingTests: XCTestCase {
    override func tearDown() { Localization.shared.setLanguage(.english); super.tearDown() }

    @MainActor private func makeModel() throws -> AppWorkspaceModel {
        _ = NSApplication.shared
        return AppWorkspaceModel(store: try WorkspaceStore(), preferences: try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())")))
    }

    @MainActor
    func testAModelOutsideTheAppReadsEnglishWhateverTheMacPrefers() throws {
        let model = try makeModel()
        XCTAssertEqual(model.appearance.language, .system)
        XCTAssertEqual(model.language, .english)
        XCTAssertEqual(ShortcutAction.newTab.title, "New Tab")
    }

    @MainActor
    func testApplyingALanguageTranslatesAtOnceAndTellsTheAppOnce() throws {
        let model = try makeModel()
        var changes = 0
        model.onLanguageChanged = { changes += 1 }
        var settings = model.appearance
        settings.language = .french
        XCTAssertTrue(model.applyAppearance(settings))
        XCTAssertEqual(model.language, .french)
        XCTAssertEqual(Localization.shared.language, .french)
        XCTAssertNotEqual(ShortcutAction.newTab.title, "New Tab")
        XCTAssertEqual(changes, 1)
        settings.fontSize = 15
        XCTAssertTrue(model.applyAppearance(settings))
        XCTAssertEqual(changes, 1, "An unrelated appearance change rebuilds no menus")
        settings.language = .english
        XCTAssertTrue(model.applyAppearance(settings))
        XCTAssertEqual(ShortcutAction.newTab.title, "New Tab")
        XCTAssertEqual(changes, 2)
    }

    @MainActor
    func testSystemFollowsTheMacsLanguagesAndTheLaunchChoiceWinsWithoutBeingSaved() throws {
        let model = try makeModel()
        model.systemLanguages = { ["de-DE", "pt-BR", "fr-FR"] }
        XCTAssertEqual(model.language, .portuguese)
        model.languageOverride = .spanish
        XCTAssertEqual(model.language, .spanish)
        XCTAssertEqual(model.appearance.language, .system, "--language is for one launch")
        var settings = model.appearance
        settings.language = .french
        XCTAssertTrue(model.applyAppearance(settings))
        XCTAssertEqual(model.language, .spanish, "The launch choice still wins")
        model.languageOverride = nil
        XCTAssertEqual(model.language, .french)
    }

    @MainActor
    func testFailureTextSavedWithASessionStaysEnglish() throws {
        let model = try makeModel()
        var settings = model.appearance
        settings.language = .portuguese
        XCTAssertTrue(model.applyAppearance(settings))
        let failure = RemoteHostLink.Failure.exited(nil)
        let shown = RemoteHostsModel.message(for: failure)
        let saved = Localization.$sourceTextOnly.withValue(true) { RemoteHostsModel.message(for: failure) }
        XCTAssertNotEqual(shown, saved)
        settings.language = .english
        XCTAssertTrue(model.applyAppearance(settings))
        XCTAssertEqual(RemoteHostsModel.message(for: failure), saved)
    }
}
