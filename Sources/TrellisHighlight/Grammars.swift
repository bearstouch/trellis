import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML
import TrellisCore

/// The tree-sitter grammar behind each editor language (FR-TD11), with its highlight queries.
enum Grammar: String, CaseIterable {
    case swift, json, markdown, markdownInline = "markdown_inline", bash, javascript, typescript, tsx, yaml, html

    static func forFile(_ fileName: String) -> Grammar? {
        guard let language = EditorLanguage.detect(fileName: fileName) else { return nil }
        switch language {
        case .swift: return .swift
        case .json: return .json
        case .markdown: return .markdown
        case .shell: return .bash
        case .javascript: return .javascript
        case .typescript: return (fileName as NSString).pathExtension.lowercased() == "tsx" ? .tsx : .typescript
        case .yaml: return .yaml
        case .html: return .html
        }
    }

    /// An injected language's name, as the grammars' injection queries spell it.
    static func injected(_ name: String) -> Grammar? {
        switch name.lowercased() {
        case "markdown_inline": .markdownInline
        case "javascript", "js": .javascript
        case "typescript", "ts": .typescript
        case "json": .json
        case "yaml": .yaml
        case "bash", "sh", "shell", "zsh": .bash
        case "html": .html
        case "swift": .swift
        default: nil
        }
    }

    var pointer: OpaquePointer {
        switch self {
        case .swift: tree_sitter_swift()
        case .json: tree_sitter_json()
        case .markdown: tree_sitter_markdown()
        case .markdownInline: tree_sitter_markdown_inline()
        case .bash: tree_sitter_bash()
        case .javascript: tree_sitter_javascript()
        case .typescript: tree_sitter_typescript()
        case .tsx: tree_sitter_tsx()
        case .yaml: tree_sitter_yaml()
        case .html: tree_sitter_html()
        }
    }

    /// Languages its injection queries embed that are highlighted too (Markdown's inline grammar, HTML's scripts).
    var injections: [Grammar] {
        switch self {
        case .markdown: [.markdownInline]
        case .html: [.javascript]
        default: []
        }
    }

    /// The SwiftPM resource bundle holding `queries/`.
    var bundleName: String {
        switch self {
        case .swift: "TreeSitterSwift_TreeSitterSwift"
        case .json: "TreeSitterJSON_TreeSitterJSON"
        case .markdown: "TreeSitterMarkdown_TreeSitterMarkdown"
        case .markdownInline: "TreeSitterMarkdown_TreeSitterMarkdownInline"
        case .bash: "TreeSitterBash_TreeSitterBash"
        case .javascript: "TreeSitterGrammars_TreeSitterJavaScript"
        case .typescript: "TreeSitterTypeScript_TreeSitterTypeScript"
        case .tsx: "TreeSitterTypeScript_TreeSitterTSX"
        case .yaml: "TreeSitterGrammars_TreeSitterYAML"
        case .html: "TreeSitterHTML_TreeSitterHTML"
        }
    }

    /// Where the grammar bundles are: inside the app's Resources when packaged, beside the executable or test bundle
    /// in a SwiftPM build.
    static func queriesURL(bundleName: String) -> URL? {
        var folders = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        folders += Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent() }
        for folder in folders {
            let bundle = folder.appendingPathComponent(bundleName + ".bundle")
            for queries in [bundle.appendingPathComponent("queries"), bundle.appendingPathComponent("Contents/Resources/queries")]
            where FileManager.default.fileExists(atPath: queries.path) {
                return queries
            }
        }
        return nil
    }

    /// Loaded once per grammar; nil when its queries can't be found or don't compile.
    @MainActor static var configurations: [Grammar: LanguageConfiguration?] = [:]

    @MainActor var configuration: LanguageConfiguration? {
        if let cached = Self.configurations[self] { return cached }
        let loaded = Self.queriesURL(bundleName: bundleName).flatMap { try? LanguageConfiguration(pointer, name: rawValue, queriesURL: $0) }
        Self.configurations[self] = loaded
        return loaded
    }
}
