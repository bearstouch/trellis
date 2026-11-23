import Foundation

/// A prompt the bundled integration scripts set after the user's startup files (FR-SI10). `none` leaves the shell's own
/// prompt alone. The raw values travel to the scripts in `TRELLIS_PROMPT_PRESET`, so they never change.
public enum ShellPromptPreset: String, Codable, CaseIterable, Sendable {
    case none, minimal, classic, directory, compact, git, twoLine, status, clock, lambda, bracketed

    public var displayName: String {
        switch self {
        case .none: L("Shell default");
        case .minimal: L("Minimal");
        case .classic: L("Classic");
        case .directory: L("Full path");
        case .compact: L("Folder name");
        case .git: L("Git branch");
        case .twoLine: L("Two lines");
        case .status: L("Exit status");
        case .clock: L("Clock");
        case .lambda: L("Lambda");
        case .bracketed: L("Bracketed")
        }
    }

    /// The prompt looks different after a failed command (a red arrow, or `✘ 1`).
    public var showsFailure: Bool { ![.none, .classic, .bracketed].contains(self) }

    /// What the scripts draw, line by line, for `sample`; empty for `none`. Colors are ANSI indexes, so the theme colors them.
    public func preview(_ sample: ShellPromptSample = .example, failed: Bool = false) -> [[ShellPromptSegment]] {
        typealias S = ShellPromptSegment
        let arrow = { (glyph: String) in S(glyph, color: failed ? 1 : 2, bold: true) }
        let branch = sample.branch.map { [S(" (\($0))", color: 5)] } ?? []
        let userHost = "\(sample.user)@\(sample.host)"
        switch self {
        case .none: return []
        case .minimal: return [[arrow("❯"), S(" ")]]
        case .classic: return [[S(userHost, color: 2, bold: true), S(":"), S(sample.path, color: 4, bold: true), S("$ ")]]
        case .directory: return [[S(sample.path, color: 6), S(" "), arrow("❯"), S(" ")]]
        case .compact: return [[S(sample.folder, color: 4, bold: true), S(" "), arrow("❯"), S(" ")]]
        case .git: return [[S(sample.path, color: 6)] + branch + [S(" "), arrow("❯"), S(" ")]]
        case .twoLine:
            return [
                [S("╭─ ", color: 8), S(userHost, color: 2), S(" "), S(sample.path, color: 4, bold: true)] + branch,
                [S("╰─", color: 8), arrow("❯"), S(" ")]
            ]
        case .status:
            let mark = failed ? S("✘ \(sample.exitCode)", color: 1, bold: true) : S("✔", color: 2)
            return [[mark, S(" "), S(sample.path, color: 6), S(" ❯ ")]]
        case .clock: return [[S("[\(sample.time)]", color: 8), S(" "), S(sample.path, color: 6), S(" "), arrow("❯"), S(" ")]]
        case .lambda: return [[S("λ", color: 3, bold: true), S(" "), S(sample.folder, color: 4), S(" "), arrow("→"), S(" ")]]
        case .bracketed: return [[S("["), S(userHost, color: 2), S(" "), S(sample.folder, color: 4), S("]$ ")]]
        }
    }

    /// The preview as plain text, one string per line: what a screen reader hears and what tests compare with a real shell.
    public func previewText(_ sample: ShellPromptSample = .example, failed: Bool = false) -> [String] {
        preview(sample, failed: failed).map { $0.map(\.text).joined() }
    }
}

/// One styled run of a prompt preview.
public struct ShellPromptSegment: Equatable, Sendable {
    public let text: String
    /// An ANSI palette index (0–15); nil is the terminal's foreground.
    public let color: Int?
    public let bold: Bool
    public init(_ text: String, color: Int? = nil, bold: Bool = false) { self.text = text; self.color = color; self.bold = bold }
}

/// The values a preview shows in place of the live user, host, directory, branch and time.
public struct ShellPromptSample: Equatable, Sendable {
    public var user: String
    public var host: String
    /// The directory with the home folder shortened to `~`.
    public var path: String
    /// The last path component, `~` at home.
    public var folder: String
    /// nil outside a Git repository.
    public var branch: String?
    /// 24-hour `HH:MM`.
    public var time: String
    public var exitCode: Int32

    public init(user: String, host: String, path: String, folder: String, branch: String?, time: String, exitCode: Int32 = 1) {
        self.user = user; self.host = host; self.path = path; self.folder = folder; self.branch = branch; self.time = time; self.exitCode = exitCode
    }

    public static let example = Self(user: "you", host: "mac", path: "~/projects/trellis", folder: "trellis", branch: "main", time: "14:32")
}
