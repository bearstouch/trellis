import Foundation

/// The languages an editor tab highlights (FR-ED09). They are `ScratchpadLanguage` values that never run, so the shared
/// editor view shows their name and grammar the same way.
public enum EditorLanguage {
    private static func language(_ id: String, _ name: String, _ ext: String, _ grammar: ScratchpadLanguage.Grammar) -> ScratchpadLanguage {
        ScratchpadLanguage(id: id, displayName: name, fileExtension: ext, interpreter: nil, checkArguments: [], grammar: grammar)
    }

    public static let plainText = language("plain", "Plain Text", "txt", .plain)
    public static let shell = language("shell", "Shell", "sh", .shell)
    public static let javascript = language("javascript", "JavaScript", "js", .javascript)
    public static let json = language("json", "JSON", "json", .javascript)
    public static let markdown = language("markdown", "Markdown", "md", .markdown)
    public static let swift = language("swift", "Swift", "swift", .code(.swift))
    public static let python = language("python", "Python", "py", .code(.python))
    public static let typescript = language("typescript", "TypeScript", "ts", .code(.typescript))
    public static let ruby = language("ruby", "Ruby", "rb", .code(.python))
    public static let go = language("go", "Go", "go", .code(.go))
    public static let rust = language("rust", "Rust", "rs", .code(.rust))
    public static let c = language("c", "C", "c", .code(.cFamily))
    public static let cpp = language("cpp", "C++", "cpp", .code(.cFamily))
    public static let objectiveC = language("objc", "Objective-C", "m", .code(.cFamily))
    public static let java = language("java", "Java", "java", .code(.java))
    public static let kotlin = language("kotlin", "Kotlin", "kt", .code(.java))
    public static let css = language("css", "CSS", "css", .code(.css))
    public static let html = language("html", "HTML", "html", .markup)
    public static let xml = language("xml", "XML", "xml", .markup)
    public static let yaml = language("yaml", "YAML", "yaml", .yaml)
    public static let toml = language("toml", "TOML", "toml", .toml)

    private static let byExtension: [String: ScratchpadLanguage] = {
        var map: [String: ScratchpadLanguage] = [:]
        func add(_ language: ScratchpadLanguage, _ extensions: String) { for ext in extensions.split(separator: " ") { map[String(ext)] = language } }
        add(shell, "sh bash zsh fish command ksh")
        add(javascript, "js mjs cjs jsx")
        add(json, "json jsonc json5 geojson webmanifest")
        add(markdown, "md markdown mdown mkd")
        add(swift, "swift")
        add(python, "py pyi pyw")
        add(typescript, "ts tsx mts cts")
        add(ruby, "rb rake gemspec podspec")
        add(go, "go")
        add(rust, "rs")
        add(c, "c h")
        add(cpp, "cc cpp cxx hpp hh hxx ino")
        add(objectiveC, "m mm")
        add(java, "java gradle groovy scala cs dart")
        add(kotlin, "kt kts")
        add(css, "css scss sass less")
        add(html, "html htm xhtml vue svelte")
        add(xml, "xml plist svg xib storyboard entitlements csproj xsd xsl")
        add(yaml, "yaml yml")
        add(toml, "toml")
        return map
    }()

    private static let byName: [String: ScratchpadLanguage] = [
        "Package.resolved": json, "Podfile": ruby, "Gemfile": ruby, "Rakefile": ruby, "Makefile": shell, "makefile": shell, "GNUmakefile": shell,
        "Dockerfile": shell, "Containerfile": shell, "Brewfile": ruby, "Justfile": shell, "justfile": shell, "CMakeLists.txt": shell,
        ".bashrc": shell, ".bash_profile": shell, ".zshrc": shell, ".zprofile": shell, ".profile": shell, ".envrc": shell, ".env": shell,
        ".gitignore": shell, ".gitattributes": shell, ".editorconfig": toml, ".swift-format": json, ".prettierrc": json, ".eslintrc": json
    ]

    /// The language of `fileName`: by full name, then extension, then (for a file with no extension) its `#!` line.
    public static func detect(fileName: String, firstLine: String) -> ScratchpadLanguage {
        if let known = byName[fileName] { return known }
        let ext = (fileName as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let known = byExtension[ext] { return known }
        guard ext.isEmpty, firstLine.hasPrefix("#!") else { return plainText }
        let words = firstLine.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let program =
            (words.first.map { ($0 as NSString).lastPathComponent } == "env" ? words.dropFirst().first { !$0.hasPrefix("-") } : words.first)
            .map { ($0 as NSString).lastPathComponent } ?? ""
        switch program {
        case "sh", "bash", "zsh", "dash", "ksh", "fish": return shell
        case "node", "deno", "bun": return javascript
        case let name where name.hasPrefix("python"): return python
        case "swift": return swift
        case "ruby": return ruby
        default: return plainText
        }
    }
}
