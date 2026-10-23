import Foundation

public enum ScratchpadTokenKind: Sendable { case keyword, command, string, comment, variable, number, `operator` }

public struct ScratchpadToken: Equatable, Sendable {
    /// UTF-16 offsets, as `NSString` and the text view count them.
    public let range: NSRange
    public let kind: ScratchpadTokenKind
    public init(_ location: Int, _ length: Int, _ kind: ScratchpadTokenKind) { range = NSRange(location: location, length: length); self.kind = kind }
}

/// A display-only tokenizer for the scratchpad editor (FR-SP02). One linear pass, no backtracking, so any input
/// finishes quickly; it colors the common cases and never decides what runs. Later tokens may lie inside earlier
/// ones (a variable inside a string) and are applied after them.
public enum ScratchpadHighlighter {
    public static func tokens(in text: String, grammar: ScratchpadLanguage.Grammar) -> [ScratchpadToken] {
        let units = Array(text.utf16)
        switch grammar {
        case .shell: return shell(units)
        case .javascript: return javascript(units)
        }
    }

    private static func unit(_ c: Character) -> UInt16 { c.utf16.first! }
    private static let newline = unit("\n"), space = unit(" "), tab = unit("\t"), backslash = unit("\\")
    private static func isSpace(_ u: UInt16) -> Bool { u == space || u == tab || u == unit("\r") }
    private static func isDigit(_ u: UInt16) -> Bool { (unit("0")...unit("9")).contains(u) }
    private static func isLetter(_ u: UInt16) -> Bool { (unit("a")...unit("z")).contains(u) || (unit("A")...unit("Z")).contains(u) || u == unit("_") }
    private static func string(_ units: ArraySlice<UInt16>) -> String { String(decoding: units, as: UTF16.self) }

    // MARK: Shell

    static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "select", "time", "!", "{", "}", "[[", "]]"
    ]
    /// After these a new command starts.
    private static let shellCommandStarters: Set<String> = ["if", "then", "else", "elif", "while", "until", "do", "!", "{", "time"]
    private static let shellOperators = Set(";|&<>".utf16)
    private static let shellWordEnd = Set(" \t\r\n;|&<>()\"'`$".utf16)
    private static let specialParameters = Set("0123456789?@#$!*-".utf16)

    private static func shell(_ u: [UInt16]) -> [ScratchpadToken] {
        var tokens: [ScratchpadToken] = [], i = 0, commandPosition = true
        let n = u.count
        func lineEnd(_ from: Int) -> Int { var j = from; while j < n, u[j] != newline { j += 1 }; return j }
        /// The end of a `$` expansion starting at `at`, or nil when the `$` is literal.
        func expansion(_ at: Int) -> Int? {
            guard at + 1 < n else { return nil }
            let next = u[at + 1]
            if next == unit("(") { return at + 2 < n && u[at + 2] == unit("(") ? at + 3 : at + 2 }
            if next == unit("{") {
                var j = at + 2, depth = 1
                while j < n, depth > 0, u[j] != newline { if u[j] == unit("{") { depth += 1 } else if u[j] == unit("}") { depth -= 1 }; j += 1 }
                return j
            }
            if isLetter(next) { var j = at + 2; while j < n, isLetter(u[j]) || isDigit(u[j]) { j += 1 }; return j }
            return specialParameters.contains(next) ? at + 2 : nil
        }
        while i < n {
            let c = u[i]
            if c == newline { commandPosition = true; i += 1; continue }
            if isSpace(c) { i += 1; continue }
            if c == backslash { i += 2; continue }
            if c == unit("#") {
                let end = lineEnd(i)
                tokens.append(ScratchpadToken(i, end - i, .comment))
                i = end
                continue
            }
            if c == unit("'") {
                var j = i + 1
                while j < n, u[j] != unit("'") { j += 1 }
                j = min(j + 1, n)
                tokens.append(ScratchpadToken(i, j - i, .string))
                i = j; commandPosition = false
                continue
            }
            if c == unit("\"") {
                var j = i + 1, inner: [ScratchpadToken] = []
                while j < n, u[j] != unit("\"") {
                    if u[j] == backslash { j += 2; continue }
                    if u[j] == unit("$"), let end = expansion(j) { inner.append(ScratchpadToken(j, end - j, .variable)); j = end; continue }
                    j += 1
                }
                j = min(j + 1, n)
                tokens.append(ScratchpadToken(i, j - i, .string))
                tokens += inner
                i = j; commandPosition = false
                continue
            }
            if c == unit("$") {
                guard let end = expansion(i) else { i += 1; continue }
                tokens.append(ScratchpadToken(i, end - i, .variable))
                // `$(` starts a command substitution.
                commandPosition = u[i + 1] == unit("(") && end == i + 2
                i = end
                continue
            }
            if shellOperators.contains(c) {
                var j = i + 1
                while j < n, shellOperators.contains(u[j]) { j += 1 }
                tokens.append(ScratchpadToken(i, j - i, .operator))
                // A redirection names a file next; `;`, `|` and `&` start a command.
                commandPosition = !(c == unit("<") || c == unit(">"))
                i = j
                continue
            }
            if c == unit("(") || c == unit(")") || c == unit("`") { commandPosition = c != unit(")"); i += 1; continue }
            var j = i
            while j < n, !shellWordEnd.contains(u[j]) { j += 1 }
            if j == i { i += 1; continue }
            let word = string(u[i..<j])
            // `NAME=value` sets a variable; the command comes after it.
            if commandPosition, let equals = word.firstIndex(of: "="), equals != word.startIndex, word[..<equals].utf16.allSatisfy({ isLetter($0) || isDigit($0) }),
                !isDigit(word.utf16.first!)
            {
                let nameLength = word[..<equals].utf16.count
                tokens.append(ScratchpadToken(i, nameLength, .variable))
                tokens.append(ScratchpadToken(i + nameLength, 1, .operator))
                // The value isn't the command either.
                i = j
                continue
            }
            if shellKeywords.contains(word) && (commandPosition || word == "in") {
                tokens.append(ScratchpadToken(i, j - i, .keyword))
                commandPosition = shellCommandStarters.contains(word)
            } else if word.utf16.allSatisfy(isDigit) {
                tokens.append(ScratchpadToken(i, j - i, .number))
                commandPosition = false
            } else if commandPosition {
                tokens.append(ScratchpadToken(i, j - i, .command))
                commandPosition = false
            }
            i = j
        }
        return tokens
    }

    // MARK: JavaScript

    static let javascriptKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "false",
        "finally", "for", "from", "function", "if", "import", "in", "instanceof", "let", "new", "null", "of", "return", "static", "super", "switch", "this",
        "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "yield"
    ]
    private static let javascriptOperators = Set("=+-*%!<>&|?:^~".utf16)

    private static func javascript(_ u: [UInt16]) -> [ScratchpadToken] {
        var tokens: [ScratchpadToken] = [], i = 0
        let n = u.count
        func isIdentifier(_ c: UInt16) -> Bool { isLetter(c) || isDigit(c) || c == unit("$") }
        while i < n {
            let c = u[i]
            if c == newline || isSpace(c) { i += 1; continue }
            if c == unit("/"), i + 1 < n, u[i + 1] == unit("/") {
                var j = i
                while j < n, u[j] != newline { j += 1 }
                tokens.append(ScratchpadToken(i, j - i, .comment))
                i = j
                continue
            }
            if c == unit("/"), i + 1 < n, u[i + 1] == unit("*") {
                var j = i + 2
                while j < n, !(u[j] == unit("*") && j + 1 < n && u[j + 1] == unit("/")) { j += 1 }
                j = min(j + 2, n)
                tokens.append(ScratchpadToken(i, j - i, .comment))
                i = j
                continue
            }
            if c == unit("'") || c == unit("\"") {
                var j = i + 1
                while j < n, u[j] != c, u[j] != newline { j += u[j] == backslash ? 2 : 1 }
                j = min(j + 1, n)
                tokens.append(ScratchpadToken(i, j - i, .string))
                i = j
                continue
            }
            if c == unit("`") {
                var j = i + 1, inner: [ScratchpadToken] = []
                while j < n, u[j] != unit("`") {
                    if u[j] == backslash { j += 2; continue }
                    if u[j] == unit("$"), j + 1 < n, u[j + 1] == unit("{") {
                        var k = j + 2, depth = 1
                        while k < n, depth > 0 { if u[k] == unit("{") { depth += 1 } else if u[k] == unit("}") { depth -= 1 }; k += 1 }
                        inner.append(ScratchpadToken(j, k - j, .variable))
                        j = k
                        continue
                    }
                    j += 1
                }
                j = min(j + 1, n)
                tokens.append(ScratchpadToken(i, j - i, .string))
                tokens += inner
                i = j
                continue
            }
            if isDigit(c) || (c == unit(".") && i + 1 < n && isDigit(u[i + 1])) {
                var j = i + 1
                while j < n, isIdentifier(u[j]) || u[j] == unit(".") { j += 1 }
                tokens.append(ScratchpadToken(i, j - i, .number))
                i = j
                continue
            }
            if isLetter(c) || c == unit("$") {
                var j = i + 1
                while j < n, isIdentifier(u[j]) { j += 1 }
                if javascriptKeywords.contains(string(u[i..<j])) {
                    tokens.append(ScratchpadToken(i, j - i, .keyword))
                } else {
                    var k = j
                    while k < n, isSpace(u[k]) { k += 1 }
                    if k < n, u[k] == unit("(") { tokens.append(ScratchpadToken(i, j - i, .command)) }
                }
                i = j
                continue
            }
            if javascriptOperators.contains(c) {
                var j = i + 1
                while j < n, javascriptOperators.contains(u[j]) { j += 1 }
                tokens.append(ScratchpadToken(i, j - i, .operator))
                i = j
                continue
            }
            i += 1
        }
        return tokens
    }
}
