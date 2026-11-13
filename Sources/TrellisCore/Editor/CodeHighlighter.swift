import Foundation

/// How one C-like or hash-comment language looks to the editor's tokenizer (FR-ED03, FR-ED09). A table, so another
/// language is one more value; compared by `id` only.
public struct CodeSyntax: Hashable, Sendable {
    public let id: String
    let lineComments: [[UInt16]]
    let blockComment: (open: [UInt16], close: [UInt16])?
    /// Quote characters that open a one-line string; a backslash escapes.
    let quotes: Set<UInt16>
    /// Quote characters whose strings may span lines (JavaScript's backtick, Go's raw string).
    let multilineQuotes: Set<UInt16>
    /// `"""` (and `'''` when `'` is a quote) open a string that ends at the same three quotes.
    let tripleQuotes: Bool
    let keywords: Set<String>
    /// Words like `true` and `nil`, colored as numbers.
    let constants: Set<String>
    /// A capitalized word is a type name.
    let capitalizedTypes: Bool
    /// `@Attribute`, `#if`, `@media`: the marker and the word after it are colored as variables.
    let markers: Set<UInt16>
    /// A word starting with this (shell-like `$name`) is a variable.
    let variablePrefix: UInt16?

    init(
        id: String, lineComments: [String] = ["//"], blockComment: (String, String)? = ("/*", "*/"), quotes: String = "\"'", multilineQuotes: String = "",
        tripleQuotes: Bool = false, keywords: [String], constants: [String] = ["true", "false"], capitalizedTypes: Bool = true, markers: String = "",
        variablePrefix: Character? = nil
    ) {
        self.id = id
        self.lineComments = lineComments.map { Array($0.utf16) }
        self.blockComment = blockComment.map { (Array($0.0.utf16), Array($0.1.utf16)) }
        self.quotes = Set(quotes.utf16)
        self.multilineQuotes = Set(multilineQuotes.utf16)
        self.tripleQuotes = tripleQuotes
        self.keywords = Set(keywords)
        self.constants = Set(constants)
        self.capitalizedTypes = capitalizedTypes
        self.markers = Set(markers.utf16)
        self.variablePrefix = variablePrefix?.utf16.first
    }

    public static func == (a: CodeSyntax, b: CodeSyntax) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: Languages

    public static let swift = CodeSyntax(
        id: "swift", tripleQuotes: true,
        keywords: [
            "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "convenience", "default", "defer", "deinit",
            "didSet", "do", "dynamic", "else", "enum", "extension", "fallthrough", "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in",
            "indirect", "init", "inout", "internal", "is", "isolated", "lazy", "let", "mutating", "nonisolated", "nonmutating", "open", "operator", "optional",
            "override", "package", "precedencegroup", "private", "protocol", "public", "repeat", "required", "rethrows", "return", "self", "Self", "set", "some",
            "static", "struct", "subscript", "super", "switch", "throw", "throws", "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet"
        ], constants: ["true", "false", "nil"], markers: "@#")
    public static let python = CodeSyntax(
        id: "python", lineComments: ["#"], blockComment: nil, tripleQuotes: true,
        keywords: [
            "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from",
            "global", "if", "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "self"
        ], constants: ["True", "False", "None"], markers: "@")
    public static let typescript = CodeSyntax(
        id: "typescript", multilineQuotes: "`",
        keywords: [
            "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "constructor", "continue", "declare", "default", "delete", "do",
            "else", "enum", "export", "extends", "finally", "for", "from", "function", "get", "if", "implements", "import", "in", "instanceof", "interface",
            "keyof", "let", "namespace", "new", "of", "private", "protected", "public", "readonly", "return", "satisfies", "set", "static", "super", "switch",
            "this", "throw", "try", "type", "typeof", "var", "void", "while", "yield"
        ], constants: ["true", "false", "null", "undefined"], markers: "@")
    public static let go = CodeSyntax(
        id: "go", quotes: "\"'", multilineQuotes: "`",
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
            "map", "package", "range", "return", "select", "struct", "switch", "type", "var"
        ], constants: ["true", "false", "nil", "iota"])
    public static let rust = CodeSyntax(
        id: "rust", quotes: "\"",
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop",
            "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while"
        ], markers: "#")
    public static let cFamily = CodeSyntax(
        id: "c",
        keywords: [
            "auto", "break", "case", "catch", "char", "class", "const", "constexpr", "continue", "default", "delete", "do", "double", "else", "enum",
            "explicit", "extern", "float", "for", "friend", "goto", "if", "inline", "int", "long", "namespace", "new", "noexcept", "operator", "override",
            "private", "protected", "public", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "throw",
            "try", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while", "self", "super", "id", "instancetype"
        ], constants: ["true", "false", "NULL", "nullptr", "nil", "YES", "NO"], capitalizedTypes: false, markers: "#@")
    public static let java = CodeSyntax(
        id: "java", tripleQuotes: true,
        keywords: [
            "abstract", "as", "break", "case", "catch", "class", "companion", "const", "continue", "data", "default", "do", "else", "enum", "extends",
            "final", "finally", "for", "fun", "if", "implements", "import", "in", "instanceof", "interface", "internal", "is", "lateinit", "new", "object",
            "open", "override", "package", "private", "protected", "public", "return", "sealed", "static", "super", "suspend", "switch", "synchronized",
            "this", "throw", "throws", "try", "val", "var", "void", "when", "while"
        ], constants: ["true", "false", "null"], markers: "@")
    public static let css = CodeSyntax(id: "css", lineComments: [], keywords: ["!important"], constants: [], capitalizedTypes: false, markers: "@#")

    public static let all: [CodeSyntax] = [.swift, .python, .typescript, .go, .rust, .cFamily, .java, .css]
}

/// Tokenizers for the editor's languages beyond the scratchpad's (FR-ED03). Like `ScratchpadHighlighter`, each is one
/// linear pass with no backtracking: a search for a closing delimiter always resumes after it.
enum CodeHighlighter {
    private static func unit(_ c: Character) -> UInt16 { c.utf16.first! }
    private static let newline = unit("\n"), backslash = unit("\\")
    private static func isSpace(_ u: UInt16) -> Bool { u == unit(" ") || u == unit("\t") || u == unit("\r") }
    private static func isDigit(_ u: UInt16) -> Bool { (unit("0")...unit("9")).contains(u) }
    private static func isUpper(_ u: UInt16) -> Bool { (unit("A")...unit("Z")).contains(u) }
    private static func isLetter(_ u: UInt16) -> Bool { (unit("a")...unit("z")).contains(u) || isUpper(u) || u == unit("_") || u > 127 }
    private static func isWord(_ u: UInt16) -> Bool { isLetter(u) || isDigit(u) }
    private static let operators = Set("=+-*/%!<>&|?:^~".utf16)

    private static func matches(_ u: [UInt16], _ at: Int, _ target: [UInt16]) -> Bool {
        guard !target.isEmpty, at + target.count <= u.count else { return false }
        for k in 0..<target.count where u[at + k] != target[k] { return false }
        return true
    }

    /// The index just past the next `target` at or after `from`, else the end.
    private static func past(_ u: [UInt16], _ target: [UInt16], from: Int) -> Int {
        var j = from
        while j < u.count { if matches(u, j, target) { return j + target.count }; j += 1 }
        return u.count
    }

    static func code(_ u: [UInt16], _ syntax: CodeSyntax) -> [ScratchpadToken] {
        var tokens: [ScratchpadToken] = [], i = 0
        let n = u.count
        while i < n {
            let c = u[i]
            if c == newline || isSpace(c) { i += 1; continue }
            if let prefix = syntax.lineComments.first(where: { matches(u, i, $0) }) {
                var j = i + prefix.count
                while j < n, u[j] != newline { j += 1 }
                tokens.append(ScratchpadToken(i, j - i, .comment)); i = j
                continue
            }
            if let block = syntax.blockComment, matches(u, i, block.open) {
                let j = past(u, block.close, from: i + block.open.count)
                tokens.append(ScratchpadToken(i, j - i, .comment)); i = j
                continue
            }
            if syntax.tripleQuotes, c == unit("\"") || (c == unit("'") && syntax.quotes.contains(c)), matches(u, i, [c, c, c]) {
                let j = past(u, [c, c, c], from: i + 3)
                tokens.append(ScratchpadToken(i, j - i, .string)); i = j
                continue
            }
            if syntax.quotes.contains(c) || syntax.multilineQuotes.contains(c) {
                let multiline = syntax.multilineQuotes.contains(c)
                var j = i + 1
                while j < n, u[j] != c, multiline || u[j] != newline { j += u[j] == backslash ? 2 : 1 }
                j = min(j + 1, n)
                tokens.append(ScratchpadToken(i, j - i, .string)); i = j
                continue
            }
            if isDigit(c) || (c == unit(".") && i + 1 < n && isDigit(u[i + 1])) {
                var j = i + 1
                while j < n, isWord(u[j]) || u[j] == unit(".") { j += 1 }
                tokens.append(ScratchpadToken(i, j - i, .number)); i = j
                continue
            }
            if syntax.markers.contains(c), i + 1 < n, isLetter(u[i + 1]) {
                var j = i + 1
                while j < n, isWord(u[j]) || u[j] == unit("-") { j += 1 }
                tokens.append(ScratchpadToken(i, j - i, .variable)); i = j
                continue
            }
            if let prefix = syntax.variablePrefix, c == prefix, i + 1 < n, isLetter(u[i + 1]) {
                var j = i + 1
                while j < n, isWord(u[j]) { j += 1 }
                tokens.append(ScratchpadToken(i, j - i, .variable)); i = j
                continue
            }
            if isLetter(c) || (c == unit("!") && syntax.keywords.contains("!important") && matches(u, i, Array("!important".utf16))) {
                var j = i + 1
                while j < n, isWord(u[j]) { j += 1 }
                let word = String(decoding: u[i..<j], as: UTF16.self)
                if syntax.keywords.contains(word) {
                    tokens.append(ScratchpadToken(i, j - i, .keyword))
                } else if syntax.constants.contains(word) {
                    tokens.append(ScratchpadToken(i, j - i, .number))
                } else {
                    var k = j
                    while k < n, isSpace(u[k]) { k += 1 }
                    if syntax.capitalizedTypes, isUpper(c) {
                        tokens.append(ScratchpadToken(i, j - i, .type))
                    } else if k < n, u[k] == unit("(") {
                        tokens.append(ScratchpadToken(i, j - i, .command))
                    }
                }
                i = j
                continue
            }
            if operators.contains(c) {
                var j = i + 1
                while j < n, operators.contains(u[j]), !syntax.lineComments.contains(where: { matches(u, j, $0) }),
                    !(syntax.blockComment.map { matches(u, j, $0.open) } ?? false)
                {
                    j += 1
                }
                tokens.append(ScratchpadToken(i, j - i, .operator)); i = j
                continue
            }
            i += 1
        }
        return tokens
    }

    /// HTML and XML: comments, tag names, attribute names, quoted values and entities.
    static func markup(_ u: [UInt16]) -> [ScratchpadToken] {
        var tokens: [ScratchpadToken] = [], i = 0
        let n = u.count
        while i < n {
            let c = u[i]
            if c == unit("<"), matches(u, i, Array("<!--".utf16)) {
                let j = past(u, Array("-->".utf16), from: i + 4)
                tokens.append(ScratchpadToken(i, j - i, .comment)); i = j
                continue
            }
            if c == unit("<"), i + 1 < n, isLetter(u[i + 1]) || u[i + 1] == unit("/") || u[i + 1] == unit("!") || u[i + 1] == unit("?") {
                var j = i + 1
                while j < n, u[j] == unit("/") || u[j] == unit("!") || u[j] == unit("?") { j += 1 }
                while j < n, isWord(u[j]) || u[j] == unit("-") || u[j] == unit(":") || u[j] == unit(".") { j += 1 }
                tokens.append(ScratchpadToken(i, j - i, .keyword))
                // Attributes until the tag ends.
                while j < n, u[j] != unit(">"), u[j] != unit("<") {
                    let a = u[j]
                    if a == unit("\"") || a == unit("'") {
                        var k = j + 1
                        while k < n, u[k] != a { k += 1 }
                        k = min(k + 1, n)
                        tokens.append(ScratchpadToken(j, k - j, .string)); j = k
                    } else if isLetter(a) {
                        var k = j + 1
                        while k < n, isWord(u[k]) || u[k] == unit("-") || u[k] == unit(":") || u[k] == unit(".") { k += 1 }
                        tokens.append(ScratchpadToken(j, k - j, .variable)); j = k
                    } else if a == unit("/") || a == unit("?") || a == unit("=") {
                        tokens.append(ScratchpadToken(j, 1, .operator)); j += 1
                    } else {
                        j += 1
                    }
                }
                if j < n, u[j] == unit(">") { tokens.append(ScratchpadToken(j, 1, .keyword)); j += 1 }
                i = j
                continue
            }
            if c == unit("&") {
                var j = i + 1
                while j < n, j - i < 12, isWord(u[j]) || u[j] == unit("#") { j += 1 }
                if j < n, u[j] == unit(";"), j > i + 1 { tokens.append(ScratchpadToken(i, j + 1 - i, .number)); i = j + 1; continue }
            }
            i += 1
        }
        return tokens
    }

    /// YAML (`separator` ":") and TOML ("="): line by line, comments, keys, `[sections]`, quoted strings, numbers and booleans.
    static func keyValue(_ u: [UInt16], separator: UInt16) -> [ScratchpadToken] {
        var tokens: [ScratchpadToken] = [], start = 0
        let n = u.count
        let constants: Set<String> = ["true", "false", "null", "yes", "no", "on", "off", "~"]
        while start < n {
            var end = start
            while end < n, u[end] != newline { end += 1 }
            var i = start
            while i < end, isSpace(u[i]) { i += 1 }
            if i < end, u[i] == unit("-"), i + 1 == end || isSpace(u[i + 1]) { tokens.append(ScratchpadToken(i, 1, .operator)); i += 1; while i < end, isSpace(u[i]) { i += 1 } }
            if separator == unit("="), i < end, u[i] == unit("[") {
                tokens.append(ScratchpadToken(i, end - i, .type)); start = end + 1
                continue
            }
            if separator == unit(":"), matches(u, i, Array("---".utf16)) || matches(u, i, Array("...".utf16)) {
                tokens.append(ScratchpadToken(i, 3, .operator))
            }
            // A key runs to the separator, unless a quote or comment comes first.
            var k = i
            while k < end, u[k] != separator, u[k] != unit("#"), u[k] != unit("\""), u[k] != unit("'") { k += 1 }
            var value = i
            if k < end, u[k] == separator, k > i, separator == unit("=") || k + 1 == end || isSpace(u[k + 1]) {
                var keyEnd = k
                while keyEnd > i, isSpace(u[keyEnd - 1]) { keyEnd -= 1 }
                tokens.append(ScratchpadToken(i, keyEnd - i, .keyword))
                tokens.append(ScratchpadToken(k, 1, .operator))
                value = k + 1
            }
            var j = value
            while j < end {
                let c = u[j]
                if c == unit("#"), j == start || isSpace(u[j - 1]) {
                    tokens.append(ScratchpadToken(j, end - j, .comment)); break
                }
                if c == unit("\"") || c == unit("'") {
                    var k = j + 1
                    while k < end, u[k] != c { k += c == unit("\"") && u[k] == backslash ? 2 : 1 }
                    k = min(k + 1, end)
                    tokens.append(ScratchpadToken(j, k - j, .string)); j = k
                    continue
                }
                if !isSpace(c), j == value || isSpace(u[j - 1]) || u[j - 1] == unit("[") || u[j - 1] == unit(",") {
                    var k = j
                    while k < end, !isSpace(u[k]), u[k] != unit(","), u[k] != unit("]"), u[k] != unit("}") { k += 1 }
                    let word = String(decoding: u[j..<k], as: UTF16.self)
                    if constants.contains(word.lowercased())
                        || (isDigit(c) || c == unit("-") || c == unit("+")) && word.dropFirst().allSatisfy({ $0.isNumber || ".:-_eE+TZ".contains($0) }) && word.contains(where: \.isNumber)
                    {
                        tokens.append(ScratchpadToken(j, k - j, .number))
                    }
                    j = max(k, j + 1)
                    continue
                }
                j += 1
            }
            start = end + 1
        }
        return tokens
    }
}
