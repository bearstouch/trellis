import XCTest
@testable import TrellisCore

final class LocalizationTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    override func tearDown() { Localization.shared.setLanguage(.english); super.tearDown() }

    /// Every `L("…")` key in Sources, read the way the compiler would unescape it.
    private static let sourceKeys: Set<String> = {
        let pattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])L\(\s*"((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        let sources = root.appendingPathComponent("Sources")
        for case let url as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                keys.insert(unescaped(String(text[Range(match.range(at: 1), in: text)!])))
            }
        }
        return keys
    }()
    private static func unescaped(_ literal: String) -> String {
        var result = "", characters = literal.makeIterator()
        while let character = characters.next() {
            guard character == "\\", let next = characters.next() else { result.append(character); continue }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "u":
                var hex = ""
                while let digit = characters.next(), digit != "}" { if digit != "{" { hex.append(digit) } }
                if let scalar = UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init) { result.unicodeScalars.append(scalar) }
            default: result.append(next)
            }
        }
        return result
    }
    /// `%@`, `%d`, `%1$@`… as a sorted list; positional and sequential forms of the same value compare equal.
    private static func placeholders(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(?:\.\d+)?(@|d|ld|lld|f|%)"#)
        var next = 1
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
            let kind = String(text[Range(match.range(at: 2), in: text)!])
            guard kind != "%" else { return nil }
            let position = Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) } ?? next
            next += 1
            return "\(position)\(kind)"
        }.sorted()
    }

    func testSystemLanguageMatchesOnTheLanguageAloneInPreferenceOrder() {
        XCTAssertEqual(AppLanguage.matching(preferredLanguages: ["pt-BR", "en-US"]), .portuguese)
        XCTAssertEqual(AppLanguage.matching(preferredLanguages: ["fr-CA"]), .french)
        XCTAssertEqual(AppLanguage.matching(preferredLanguages: ["es-419"]), .spanish)
        XCTAssertEqual(AppLanguage.matching(preferredLanguages: ["de-DE", "es-ES", "fr-FR"]), .spanish)
        XCTAssertEqual(AppLanguage.matching(preferredLanguages: ["en-GB", "fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.matching(preferredLanguages: ["de-DE"]), .english)
        XCTAssertEqual(AppLanguage.matching(preferredLanguages: []), .english)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["pt_PT"]), .portuguese)
        XCTAssertEqual(AppLanguage.french.resolved(preferredLanguages: ["es"]), .french, "An explicit choice ignores the system list")
    }

    func testLanguagesAreListedUnderTheirOwnNames() {
        XCTAssertEqual(AppLanguage.translated.map(\.nativeName), ["English", "Português", "Français", "Español"])
        XCTAssertNil(AppLanguage.system.nativeName)
        Localization.shared.setLanguage(.french)
        XCTAssertEqual(AppLanguage.portuguese.nativeName, "Português")
    }

    func testEnglishIsTheSourceAndTheDefault() {
        XCTAssertEqual(Localization.shared.language, .english)
        XCTAssertEqual(L("New Tab"), "New Tab")
        XCTAssertEqual(L("Zoom is 100 %"), "Zoom is 100 %", "Text without values is never read as a format")
        XCTAssertEqual(L("%1$@ has %2$d tabs", "Work", 3), "Work has 3 tabs")
    }

    func testChoosingALanguageTranslatesAndUnknownTextStaysEnglish() {
        Localization.shared.setLanguage(.portuguese)
        XCTAssertEqual(Localization.shared.language, .portuguese)
        XCTAssertNotEqual(L("New Tab"), "New Tab")
        XCTAssertEqual(L("Text nobody translated"), "Text nobody translated")
        XCTAssertEqual(L("%d untranslated things", 2), "2 untranslated things")
        Localization.shared.setLanguage(.system)
        XCTAssertEqual(Localization.shared.language, .english, "System is resolved by the caller; unresolved it reads English")
        XCTAssertEqual(L("New Tab"), "New Tab")
    }

    func testEveryTableCoversTheSourceExactlyWithMatchingPlaceholders() throws {
        let keys = Self.sourceKeys
        XCTAssertGreaterThan(keys.count, 500, "The source scan found too little text to be right")
        for language in AppLanguage.translated where language != .english {
            let table = try Localization.table(for: language)
            let missing = keys.subtracting(table.keys).sorted(), unused = Set(table.keys).subtracting(keys).sorted()
            XCTAssertTrue(missing.isEmpty, "\(language.rawValue) lacks \(missing.count): \(missing.prefix(8))")
            XCTAssertTrue(unused.isEmpty, "\(language.rawValue) has \(unused.count) unused: \(unused.prefix(8))")
            for (key, value) in table {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language.rawValue): empty text for \(key)")
                XCTAssertEqual(Self.placeholders(value), Self.placeholders(key), "\(language.rawValue): placeholders differ for \(key)")
                XCTAssertEqual(value.hasSuffix("…"), key.hasSuffix("…"), "\(language.rawValue): an ellipsis marks a command that asks first: \(key)")
            }
        }
    }

    func testTheSourceTablesMatchTheBundledCopies() throws {
        for language in AppLanguage.translated where language != .english {
            let source = Self.root.appendingPathComponent("Sources/TrellisCore/Resources/Localizations/\(language.rawValue).json")
            XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: source)), try Localization.table(for: language))
        }
    }

    func testCountedTextReadsCorrectlyForOneAndForManyInEveryLanguage() throws {
        // The plural wording is never shown for one (FR-LN06), so each pair must exist and differ in every table.
        let pairs = [("1 tab", "%d tabs"), ("1 pane", "%d panes"), ("1 space", "%d spaces"), ("1 agent", "%d agents"), ("1 visit", "%d visits")]
        for (one, many) in pairs {
            XCTAssertTrue(Self.sourceKeys.contains(one), one); XCTAssertTrue(Self.sourceKeys.contains(many), many)
        }
        for language in AppLanguage.translated where language != .english {
            Localization.shared.setLanguage(language)
            for (one, many) in pairs {
                XCTAssertFalse(L(one).contains("%"), "\(language.rawValue): \(one)")
                XCTAssertTrue(L(many, 3).contains("3"), "\(language.rawValue): \(many)")
                XCTAssertNotEqual(L(one).dropFirst(2), L(many, 3).dropFirst(2), "\(language.rawValue): \(one) and \(many) read the same")
            }
        }
    }

    func testCountsAreNeverDigitGroupedAndSavedTextCanStayEnglish() {
        XCTAssertEqual(L("%d tabs", 1_234_567), "1234567 tabs")
        Localization.shared.setLanguage(.french)
        XCTAssertFalse(L("%d tabs", 1_234_567).contains(" 234"), "A French count has no grouping either")
        XCTAssertTrue(L("%d tabs", 1_234_567).contains("1234567"))
        XCTAssertEqual(Localization.$sourceTextOnly.withValue(true) { L("New Tab") }, "New Tab", "Text saved or returned by the API reads English")
        XCTAssertNotEqual(L("New Tab"), "New Tab")
    }

    func testSettingsWithoutALanguageOrWithAnUnknownOneFollowTheSystem() throws {
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppearanceSettings())) as? [String: Any])
        XCTAssertEqual(saved["language"] as? String, "system")
        saved["language"] = nil; saved["chromeMode"] = "light"
        let legacy = try JSONDecoder().decode(AppearanceSettings.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertEqual(legacy.language, .system)
        XCTAssertEqual(legacy.chromeMode, .light)
        saved["language"] = "tlh"
        XCTAssertEqual(try JSONDecoder().decode(AppearanceSettings.self, from: JSONSerialization.data(withJSONObject: saved)).language, .system)
        saved["language"] = "pt-PT"
        let portuguese = try JSONDecoder().decode(AppearanceSettings.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertEqual(portuguese.language, .portuguese)
        XCTAssertFalse(portuguese.terminalRenderingDiffers(from: legacy), "A language change redraws no terminal")
    }
}
