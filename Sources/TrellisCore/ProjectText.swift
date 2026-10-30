import CryptoKit
import Foundation

/// Text and folder rules shared by task files, the scratchpad and the project library: what a reviewed or typed line
/// may hold, and which relative folders stay inside a project.
public enum ProjectText {
    /// A project's own Trellis folder, holding `launch.json` and saved scratchpads.
    public static let directoryName = ".trellis"
    public static let maximumCommandLength = 4096

    /// Bidi overrides, zero-width characters and line separators could make reviewed text differ from what runs.
    public static func hasHiddenCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { [.format, .control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }
    }

    public static func textProblem(_ text: String, limit: Int) -> String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > limit { return "needs 1–\(limit) characters." }
        return hasHiddenCharacters(text) ? "contains control or invisible formatting characters." : nil
    }

    /// One shell line, as `session.execute` accepts, with nothing hidden from review.
    public static func commandProblem(_ command: String) -> String? {
        if command.trimmingCharacters(in: .whitespaces).isEmpty || command.count > maximumCommandLength { return "needs 1–\(maximumCommandLength) characters." }
        // Commands also refuse other default-ignorable scalars (fillers, variation selectors), which render as nothing.
        let hidden = hasHiddenCharacters(command) || command.unicodeScalars.contains { $0.properties.isDefaultIgnorableCodePoint }
        return hidden ? "must be a single line without control or invisible formatting characters." : nil
    }

    /// The normalized relative form, or nil when it could escape the project or needs expansion.
    public static func relativeDirectory(_ directory: String) -> String? {
        guard !directory.isEmpty, directory.utf8.count <= 1024, !directory.hasPrefix("/"), !directory.hasPrefix("~"), !hasHiddenCharacters(directory),
            !directory.unicodeScalars.contains(where: { "$`".unicodeScalars.contains($0) })
        else { return nil }
        let segments = directory.split(separator: "/").filter { $0 != "." }
        guard !segments.contains("..") else { return nil }
        return segments.joined(separator: "/")
    }
}

public enum ProjectLocator {
    /// A task project (FR-TK02): the nearest folder with a `.trellis` folder, or a `.git` folder or file (worktrees
    /// and submodules use a file). Neither the home folder nor `/` counts, and the search never leaves the home folder
    /// it started in.
    public static func taskRoot(containing directory: String, home: String, exists: (String) -> Bool) -> String? {
        nearestRoot(containing: directory, home: home) { exists($0 + "/" + ProjectText.directoryName) || exists($0 + "/.git") }
    }

    /// The nearest folder at or above `directory` that `matches`, excluding home and `/`, never leaving home.
    public static func nearestRoot(containing directory: String, home: String, matches: (String) -> Bool) -> String? {
        guard directory.hasPrefix("/") else { return nil }
        let home = URL(fileURLWithPath: home).standardizedFileURL.path
        var current = URL(fileURLWithPath: directory).standardizedFileURL.path
        let underHome = current.hasPrefix(home + "/")
        while current != "/", current != home {
            if matches(current) { return current }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || (underHome && !parent.hasPrefix(home)) { return nil }
            current = parent
        }
        return nil
    }
}

/// Trusted (project folder, file digest) pairs (FR-TK06).
/// A folder holds one trusted digest: trusting a new version replaces the old one.
public struct ProjectTrustList: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let root: String, sha256: String
        public init(root: String, sha256: String) { self.root = root; self.sha256 = sha256 }
    }
    public static let maximumEntries = 1000
    public var version = 1
    public private(set) var trusted: [Entry] = []
    public init() {}

    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public func isTrusted(root: String, digest: String) -> Bool { trusted.contains(Entry(root: root, sha256: digest)) }
    /// A different version of this folder's file was trusted before.
    public func trustedOtherVersion(root: String, digest: String) -> Bool { trusted.contains { $0.root == root && $0.sha256 != digest } }

    public mutating func trust(root: String, digest: String) {
        trusted.removeAll { $0.root == root }
        trusted.append(Entry(root: root, sha256: digest))
        if trusted.count > Self.maximumEntries { trusted.removeFirst(trusted.count - Self.maximumEntries) }
    }
}
