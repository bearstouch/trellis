import Foundation

public enum SmartSelectionKind: String, Sendable, CaseIterable {
    case url, email, filePath, uuid, ipv6, ipv4, gitHash, quotedString
}

/// A recognized token; `range` is in grapheme (Character) offsets of the searched text.
public struct SmartSelectionMatch: Equatable, Sendable {
    public let kind: SmartSelectionKind
    public let range: Range<Int>
    public init(kind: SmartSelectionKind, range: Range<Int>) { self.kind = kind; self.range = range }
}

/// iTerm2-style smart selection (FR-C06): the most specific token containing a
/// clicked character. Rules are character-class runs that may only start at a
/// run boundary, so hostile output can't make matching quadratic.
public enum SmartSelection {
    public static let maximumLength = 4096

    private struct Rule: Sendable {
        let kind: SmartSelectionKind
        let precedence: Int
        let regex: NSRegularExpression
        var accepts: @Sendable (String) -> Bool = { _ in true }
    }

    private static let pathCharacters = #"[\p{L}\p{M}\p{N}._\-+@%=,~#]"#
    private static let rules: [Rule] = [
        Rule(kind: .url, precedence: 100, regex: regex(#"\b[A-Za-z][A-Za-z0-9+.\-]{1,15}://[^\s<>"'`{}|\\^]+|\bmailto:[^\s<>"'`{}|\\^]+"#)),
        Rule(kind: .email, precedence: 90, regex: regex(#"(?<![A-Za-z0-9._%+\-])[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+"#)),
        Rule(
            kind: .filePath, precedence: 80,
            regex: regex(#"(?<![/P])(?:(?:~|\.{1,2})?(?:/P+)+/?|P+(?:/P+)+/?)(?::\d+(?::\d+)?)?"#.replacingOccurrences(of: "P", with: pathCharacters))),
        Rule(kind: .uuid, precedence: 70, regex: regex(#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#)),
        Rule(kind: .ipv6, precedence: 60, regex: regex(#"(?<![0-9A-Fa-f:])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?![0-9A-Fa-f:])"#), accepts: isIPv6),
        Rule(kind: .ipv4, precedence: 60, regex: regex(#"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b"#), accepts: isIPv4),
        Rule(kind: .gitHash, precedence: 50, regex: regex(#"\b[0-9a-f]{7,40}\b"#), accepts: { $0.contains(where: \.isNumber) }),
        Rule(kind: .quotedString, precedence: 10, regex: regex(#""[^"\n]*"|'[^'\n]*'"#))
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants; a typo must fail every test, not ship.
        try! NSRegularExpression(pattern: pattern)
    }

    /// The best token containing `offset` (a grapheme index into `text`), or nil
    /// so the caller can fall back to plain word selection.
    public static func match(in text: String, at offset: Int) -> SmartSelectionMatch? {
        let characters = Array(text)
        guard offset >= 0, offset < characters.count else { return nil }
        // Hostile output can make a logical line huge; look only near the click.
        let lower = max(0, min(offset - maximumLength / 2, characters.count - maximumLength))
        let window = Array(characters[lower..<min(characters.count, lower + maximumLength)])
        let click = offset - lower
        let string = String(window)
        // UTF-16 offset → grapheme index, so a match never splits a cluster.
        var graphemeAt: [Int] = []
        for (index, character) in window.enumerated() {
            graphemeAt.append(contentsOf: repeatElement(index, count: character.utf16.count))
        }
        graphemeAt.append(window.count)
        var best: (precedence: Int, match: SmartSelectionMatch)?
        let all = NSRange(location: 0, length: graphemeAt.count - 1)
        for rule in rules {
            for result in rule.regex.matches(in: string, range: all) {
                let start = graphemeAt[result.range.lowerBound]
                let end = result.range.upperBound == 0 ? 0 : graphemeAt[result.range.upperBound - 1] + 1
                guard start <= click, click < end else { continue }
                let range = rule.kind == .quotedString ? start..<end : trimmed(start..<end, in: window)
                guard range.contains(click), !range.isEmpty else { continue }
                if rule.kind == .quotedString, click != range.lowerBound, click != range.upperBound - 1 { continue }
                guard rule.accepts(String(window[range])) else { continue }
                let candidate = SmartSelectionMatch(kind: rule.kind, range: range.lowerBound + lower..<range.upperBound + lower)
                if let current = best {
                    let better =
                        rule.precedence != current.precedence
                        ? rule.precedence > current.precedence
                        : range.count != current.match.range.count
                            ? range.count > current.match.range.count : candidate.range.lowerBound < current.match.range.lowerBound
                    if !better { continue }
                }
                best = (rule.precedence, candidate)
            }
        }
        return best?.match
    }

    /// Drops sentence punctuation and unbalanced brackets around a token; balanced
    /// pairs stay, as in `https://en.wikipedia.org/wiki/A_(b)`.
    public static func trimmed(_ text: String) -> String {
        let characters = Array(text)
        return String(characters[trimmed(0..<characters.count, in: characters)])
    }

    static func trimmed(_ range: Range<Int>, in characters: [Character]) -> Range<Int> {
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{", ">": "<"]
        let openers: [Character: Character] = ["(": ")", "[": "]", "{": "}", "<": ">"]
        var lower = range.lowerBound, upper = range.upperBound
        // Bracket counts follow each dropped character, so a hostile bracket tail trims in linear time.
        var counts: [Character: Int] = [:]
        for character in characters[lower..<upper] where pairs[character] != nil || openers[character] != nil { counts[character, default: 0] += 1 }
        func count(_ character: Character) -> Int { counts[character] ?? 0 }
        func drop(_ character: Character) { counts[character, default: 0] -= 1 }
        while lower < upper {
            let last = characters[upper - 1], first = characters[lower]
            if openers[first] == last {
                drop(first); drop(last); lower += 1; upper -= 1
            } else if ".,;:!?'\"".contains(last) {
                upper -= 1
            } else if let opener = pairs[last], count(opener) < count(last) {
                drop(last); upper -= 1
            } else if "'\"".contains(first) {
                lower += 1
            } else if let closer = openers[first], count(closer) < count(first) {
                drop(first); lower += 1
            } else {
                break
            }
        }
        return lower..<upper
    }

    static func isIPv4(_ text: String) -> Bool {
        let address = text.split(separator: ":", maxSplits: 1)
        if address.count == 2, Int(address[1]).map({ !(1...65535).contains($0) }) ?? true { return false }
        let octets = address[0].split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { Int($0).map { $0 <= 255 } ?? false }
    }

    static func isIPv6(_ text: String) -> Bool {
        let colons = text.filter { $0 == ":" }.count
        let compressed = text.components(separatedBy: "::").count - 1
        guard compressed <= 1, compressed == 1 || colons == 7, !text.contains(":::") else { return false }
        if compressed == 0, text.hasPrefix(":") || text.hasSuffix(":") { return false }
        return text.split(separator: ":").allSatisfy { (1...4).contains($0.count) } && text != "::"
    }
}
