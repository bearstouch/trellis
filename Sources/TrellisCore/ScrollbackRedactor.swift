import Darwin
import Foundation

/// FR-R05: best-effort removal of credentials from plain text before it is written to disk.
/// A pure function over text only, never raw terminal bytes; anything it misses stays on disk,
/// which is why the scrollback file is opt-in and documented as unencrypted.
public enum ScrollbackRedactor {
    public static let marker = "[redacted]"

    private struct Rule: @unchecked Sendable {
        let expression: NSRegularExpression
        /// The capture group replaced, or 0 for the whole match.
        let group: Int
        /// Lowercase text one of which must occur for the rule to run at all; empty always runs. Keeps a quit with
        /// many large panes fast: most text contains none of them.
        let needles: [String]
        init(_ pattern: String, group: Int = 0, options: NSRegularExpression.Options = [], needles: [String] = []) {
            // The patterns are constants; a typo is a programming error caught by the tests.
            expression = try! NSRegularExpression(pattern: pattern, options: options)
            self.group = group
            self.needles = needles
        }
    }

    private static let keyword = "(?:password|passwd|passphrase|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret|private[_-]?key)"

    private static let keywordNeedles = ["pass", "secret", "token", "key"]

    private static let rules: [Rule] = [
        // PEM private keys, whole blocks; a block cut by eviction loses its header, so bare body lines go too.
        Rule("-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[\\s\\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|\\z)", needles: ["private key"]),
        Rule("^[A-Za-z0-9+/]{64}$", options: [.anchorsMatchLines]),
        Rule("(?i)(\\bauthorization[ \\t]*[:=][ \\t]*)([^\\r\\n]+)", group: 2, needles: ["authorization"]),
        Rule("(?i)(\\bbearer[ \\t]+)([A-Za-z0-9._~+/=-]{8,})", group: 2, needles: ["bearer"]),
        // Credentials in URLs: scheme://user:password@host.
        Rule("(?<![A-Za-z0-9+.-])([A-Za-z][A-Za-z0-9+.-]{0,31}://[^\\s/:@]{0,256}:)([^\\s/@]{1,256})(@)", group: 2, needles: ["://"]),
        // Well-known token formats.
        Rule("\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b", needles: ["akia", "asia"]),
        Rule("\\bgh[pousr]_[A-Za-z0-9]{20,}\\b", needles: ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"]),
        Rule("\\bgithub_pat_[A-Za-z0-9_]{20,}\\b", needles: ["github_pat_"]),
        Rule("\\bglpat-[A-Za-z0-9_-]{20,}\\b", needles: ["glpat-"]),
        Rule("\\bxox[abprs]-[A-Za-z0-9-]{10,}\\b", needles: ["xox"]),
        Rule("\\bsk-(?:ant-)?[A-Za-z0-9_-]{20,}\\b", needles: ["sk-"]),
        Rule("\\b(?:sk|rk)_live_[A-Za-z0-9]{16,}\\b", needles: ["_live_"]),
        Rule("\\bAIza[0-9A-Za-z_-]{35}\\b", needles: ["aiza"]),
        Rule("\\bnpm_[A-Za-z0-9]{36}\\b", needles: ["npm_"]),
        Rule("\\beyJ[A-Za-z0-9_-]{8,}\\.eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\b", needles: ["eyj"]),
        // name="value", name: 'value', "name": "value" (env lines, YAML, JSON): everything up to the closing quote,
        // so a quoted secret with spaces, commas, semicolons or escaped quotes is hidden whole.
        Rule(
            "(?i)((?<![A-Za-z0-9_.-])[A-Za-z0-9_.-]{0,32}\(keyword)[A-Za-z0-9_.-]{0,32}[\"']?[ \\t]*[:=][ \\t]*)([\"'])((?:\\\\.|(?!\\2)[^\\\\\\r\\n])+)", group: 3,
            needles: keywordNeedles),
        // name=value, name: value, `--flag=value` unquoted: up to whitespace, which hides more rather than less.
        Rule("(?i)((?<![A-Za-z0-9_.-])[A-Za-z0-9_.-]{0,32}\(keyword)[A-Za-z0-9_.-]{0,32}[\"']?[ \\t]*[:=][ \\t]*)([^\\s\"'][^\\s]*)", group: 2, needles: keywordNeedles),
        // --password value, -p is too ambiguous to touch.
        Rule("(?i)(--?\(keyword)[ \\t]+)([^\\s-][^\\s]*)", group: 2, needles: keywordNeedles),
        // Text after a password-style prompt on the same line; echo is normally off, so this is a fallback.
        Rule("(?i)((?:password|passphrase)(?: for [^:\\r\\n]{1,80})?:[ \\t]*)([^\\s][^\\r\\n]*)", group: 2, needles: ["pass"])
    ]

    public static func redact(_ text: String) -> String {
        var result = text
        let lowercased = Array(text.lowercased().utf8)
        func occurs(_ needle: String) -> Bool {
            lowercased.withUnsafeBytes { haystack in
                Array(needle.utf8).withUnsafeBytes { memmem(haystack.baseAddress, haystack.count, $0.baseAddress, $0.count) != nil }
            }
        }
        for rule in rules where rule.needles.isEmpty || rule.needles.contains(where: occurs) {
            let source = result as NSString
            let matches = rule.expression.matches(in: result, range: NSRange(location: 0, length: source.length))
            guard !matches.isEmpty else { continue }
            let output = NSMutableString(string: result)
            for match in matches.reversed() {
                let range = match.range(at: rule.group)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                if output.substring(with: range) != marker { output.replaceCharacters(in: range, with: marker) }
            }
            result = output as String
        }
        return result
    }
}
