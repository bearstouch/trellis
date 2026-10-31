import Foundation

/// A git repository a project names (FR-PL02): a checkout at the project folder, a tab's folder or a pane's folder.
public struct ProjectRepository: Codable, Equatable, Hashable, Sendable {
    public var url: String
    public var branch: String?
    public init(url: String, branch: String? = nil) { self.url = url; self.branch = branch }
}

/// What may reach git and the setup script (FR-PL02, FR-PL07). Values end up double-quoted in a POSIX script, so
/// anything a shell could reinterpret, and any transport other than https and ssh, is refused here.
public enum GitRepository {
    public static let maximumURLLength = 2048
    private static let urlCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/@%+=,")
    private static let branchCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")

    /// Nil when `url` is an `https://`, `ssh://` or scp-like `user@host:path` URL Trellis will hand to git.
    public static func urlProblem(_ url: String) -> String? {
        let invalid = "Use https://…, ssh://… or user@host:path, with only letters, digits and -._~:/@%+=, (at most \(maximumURLLength) characters)."
        guard !url.isEmpty, url.count <= maximumURLLength, !url.hasPrefix("-"), url.allSatisfy(urlCharacters.contains) else { return invalid }
        if url.hasPrefix("https://") || url.hasPrefix("ssh://") {
            let rest = url.drop { $0 != "/" }.dropFirst(2)
            let authority = rest.prefix { $0 != "/" }
            // A password in the URL would be stored with the project; credentials belong to the target's git.
            // A password or token in the URL would be stored with the project; credentials belong to the target's git.
            if url.hasPrefix("https://"), authority.contains("@") { return "Don't put a user, password or token in an https URL; git asks for them, or uses the target's credentials." }
            if let at = authority.lastIndex(of: "@"), authority[..<at].contains(":") { return "Don't put a password in the URL; git asks for it, or uses the target's credentials." }
            let host = authority.split(separator: "@").last ?? ""
            return host.isEmpty || host.hasPrefix("-") || rest.count <= authority.count + 1 ? invalid : nil
        }
        // scp-like: user@host:path. git reads "name::" anywhere before it as a remote helper (ext::, fd::, any
        // git-remote-<name>) and a "/" before the first ":" as a local path, so the user may hold neither.
        guard !url.contains("://"), let at = url.firstIndex(of: "@"), let colon = url[at...].firstIndex(of: ":") else { return invalid }
        let user = url[..<at], host = url[url.index(after: at)..<colon], path = url[url.index(after: colon)...]
        guard !user.isEmpty, !user.contains(":"), !user.contains("/"), !host.isEmpty, !host.hasPrefix("-"), !host.contains("/"), !path.isEmpty, !path.hasPrefix(":")
        else { return invalid }
        return nil
    }

    /// Nil when `branch` is a branch name git accepts and no shell reinterprets.
    public static func branchProblem(_ branch: String) -> String? {
        let valid =
            !branch.isEmpty && branch.utf8.count <= 255 && branch.allSatisfy(branchCharacters.contains) && !branch.hasPrefix("-") && !branch.hasPrefix(".")
            && !branch.hasPrefix("/") && !branch.hasSuffix("/") && !branch.hasSuffix(".") && !branch.hasSuffix(".lock") && !branch.contains("..")
            && !branch.contains("//") && !branch.contains("/.") && branch != "HEAD"
        return valid ? nil : "Use a git branch name: letters, digits and ._/-, without .., //, a leading - or . or a trailing /, . or .lock."
    }

    /// The normalized relative folder ("" for the project folder), or nil when it could leave the project, needs
    /// expansion, or holds a character the setup script can't quote.
    public static func folder(_ directory: String) -> String? {
        if directory == "." { return "" }
        guard let relative = ProjectText.relativeDirectory(directory), !directory.contains(where: { "\"'\\!".contains($0) }) else { return nil }
        return relative
    }

    /// A short name for a URL in lists: `acme/api` for `git@github.com:acme/api.git`.
    public static func shortName(_ url: String) -> String {
        var path = Substring(url)
        if let scheme = url.range(of: "://") {
            path = url[scheme.upperBound...].drop { $0 != "/" }.dropFirst()
        } else if let colon = url.firstIndex(of: ":") {
            path = url[url.index(after: colon)...]
        }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/").isEmpty ? url : parts.suffix(2).joined(separator: "/")
    }
}
