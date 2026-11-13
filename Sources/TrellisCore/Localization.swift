import Foundation

/// The language the app's own text is shown in (FR-LN01). Terminal output, the CLI, the automation API and
/// anything the user named stay as they are.
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system, english = "en", portuguese = "pt-PT", french = "fr", spanish = "es"

    /// Languages with a translation, English first; `system` resolves to one of these.
    public static let translated: [AppLanguage] = [.english, .portuguese, .french, .spanish]

    /// A language's own name, the same whatever the app shows, so a reader can find theirs (FR-LN02).
    public var nativeName: String? {
        switch self {
        case .system: nil
        case .english: "English"
        case .portuguese: "Português"
        case .french: "Français"
        case .spanish: "Español"
        }
    }

    /// The first preferred language Trellis has, by language code alone (`pt-BR` and `fr-CA` match); English when none does.
    public static func matching(preferredLanguages: [String]) -> AppLanguage {
        for identifier in preferredLanguages {
            let code = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() }
            if let match = translated.first(where: { $0.rawValue.split(separator: "-").first.map(String.init) == code }) { return match }
        }
        return .english
    }

    public func resolved(preferredLanguages: [String]) -> AppLanguage { self == .system ? Self.matching(preferredLanguages: preferredLanguages) : self }
}

/// The app's translations: English source text is the key, so a missing entry reads as English (FR-LN04).
/// Starts in English and changes only when the app applies a language, which keeps tests and helpers English.
public final class Localization: @unchecked Sendable {
    public static let shared = Localization()

    /// Set around code whose text is saved or returned by the API: it reads English whatever the app shows.
    @TaskLocal public static var sourceTextOnly = false

    private let lock = NSLock()
    private var current: AppLanguage = .english
    private var table: [String: String] = [:]

    /// The language in use; never `system`.
    public var language: AppLanguage { lock.withLock { current } }

    /// Switches to a translated language. A table that can't be read leaves English text, never a blank label.
    public func setLanguage(_ language: AppLanguage) {
        let language = language == .system ? AppLanguage.english : language
        let loaded = language == .english ? [:] : (try? Self.table(for: language)) ?? [:]
        lock.withLock {
            current = language; table = loaded
        }
    }

    public func string(_ key: String) -> String {
        if Self.sourceTextOnly { return key }
        return lock.withLock { table[key].flatMap { $0.isEmpty ? nil : $0 } ?? key }
    }

    /// No locale is passed: a locale would group digits (1,234), and counts read as plain numbers everywhere in the app.
    public func format(_ key: String, _ arguments: [CVarArg]) -> String {
        String(format: string(key), arguments: arguments)
    }

    /// The bundled translation for a language; English has none.
    public static func table(for language: AppLanguage) throws -> [String: String] {
        guard language != .english, language != .system else { return [:] }
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Trellis_TrellisCore.bundle")
        let resources = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let url = resources.url(forResource: language.rawValue, withExtension: "json", subdirectory: "Localizations") else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }
}

/// Text in the app's language. The key is the English text and must be one plain string literal, so the
/// translation tables can be checked against the source (FR-LN04).
public func L(_ key: String) -> String { Localization.shared.string(key) }

/// Text with values: `%@` for text, `%d` for whole numbers, `%1$@`… where a translation reorders them.
public func L(_ key: String, _ first: CVarArg, _ rest: CVarArg...) -> String { Localization.shared.format(key, [first] + rest) }
