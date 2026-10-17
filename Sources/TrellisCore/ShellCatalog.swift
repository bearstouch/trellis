import Foundation

/// A shell offered in Settings; `integration` is nil when no bundled script supports it.
public struct ShellOption: Identifiable, Equatable, Sendable {
    public let path: String
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var integration: ShellIntegrationKind? { ShellIntegrationKind(executable: path) }
}

/// Installed shells for the Settings picker: `/etc/shells` order, then common package-manager
/// locations, then the configured shell if it is listed nowhere else. Read only; never runs anything.
public enum ShellCatalog {
    public static let packageManagerShells = [
        "/opt/homebrew/bin/zsh", "/opt/homebrew/bin/bash", "/opt/homebrew/bin/fish",
        "/usr/local/bin/zsh", "/usr/local/bin/bash", "/usr/local/bin/fish"
    ]

    public static func options(
        shellsFile: String = "/etc/shells", extra: [String] = packageManagerShells, current: String? = nil,
        files: any LaunchFileAccess = SystemLaunchFileAccess(), read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> [ShellOption] {
        var seen = Set<String>()
        let candidates = (read(shellsFile).map(parse) ?? []) + extra + (current.map { [$0] } ?? [])
        return candidates.compactMap { path in
            guard seen.insert(path).inserted, files.isExecutableFile(path) else { return nil }
            return ShellOption(path: path)
        }
    }

    /// Absolute paths from a shells(5) file; comments and blank or relative lines are ignored.
    public static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let path = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first?.trimmingCharacters(in: .whitespaces) ?? ""
            return path.hasPrefix("/") && !path.contains("\0") ? path : nil
        }
    }
}
