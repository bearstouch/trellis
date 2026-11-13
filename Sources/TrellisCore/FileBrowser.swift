import Foundation

/// One file or folder in the Files view (FR-FB03). A symbolic link is never a folder here, so the tree never follows one.
public struct FileEntry: Hashable, Identifiable, Sendable {
    public let path: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, isDirectory: Bool, isSymbolicLink: Bool = false) {
        self.path = path
        self.isDirectory = isDirectory && !isSymbolicLink
        self.isSymbolicLink = isSymbolicLink
    }
}

/// Lists one folder's direct children; injected by tests.
public protocol FileListing: Sendable {
    func contents(of directory: String) throws -> [FileEntry]
    /// A text file's contents, for the root's `.gitignore`; nil when it is missing or unreadable.
    func text(at path: String) -> String?
}

/// The Mac's file system. Symbolic links are reported as links and not resolved.
public struct LocalFileListing: FileListing {
    public init() {}

    public func contents(of directory: String) throws -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory, isDirectory: true), includingPropertiesForKeys: keys)
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return FileEntry(path: directory == "/" ? "/" + url.lastPathComponent : directory + "/" + url.lastPathComponent, isDirectory: values?.isDirectory == true, isSymbolicLink: values?.isSymbolicLink == true)
        }
    }

    public func text(at path: String) -> String? {
        // Checked after resolving links: a `.gitignore` linked to a FIFO or `/dev/zero` would block or never end.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved), attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.size] as? Int ?? .max) <= 256 * 1024
        else { return nil }
        return try? String(contentsOfFile: resolved, encoding: .utf8)
    }
}

/// The simple `.gitignore` patterns the Files view honors (FR-FB03, FR-FB04): one per line, `#` comments, a trailing `/` for
/// folders only, a leading `/` or an inner `/` anchors to the root, otherwise the name matches at any depth. Negations
/// (`!`) are not supported and are skipped, so a file can only be hidden by a pattern, never shown by one.
public struct IgnorePatterns: Equatable, Sendable {
    struct Pattern: Equatable, Sendable {
        let glob: String
        let anchored: Bool
        let directoryOnly: Bool
    }
    let patterns: [Pattern]

    public init(gitignore text: String) {
        patterns = text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { return nil }
            let directoryOnly = line.hasSuffix("/")
            if directoryOnly { line.removeLast() }
            let anchored = line.hasPrefix("/") || line.dropFirst().contains("/")
            if line.hasPrefix("/") { line.removeFirst() }
            if line.hasPrefix("**/") { return Pattern(glob: String(line.dropFirst(3)), anchored: false, directoryOnly: directoryOnly) }
            return line.isEmpty ? nil : Pattern(glob: line, anchored: anchored, directoryOnly: directoryOnly)
        }
    }

    public static let none = IgnorePatterns(gitignore: "")

    /// Whether a path, relative to the root, is ignored.
    public func ignores(relativePath: String, isDirectory: Bool) -> Bool {
        let name = (relativePath as NSString).lastPathComponent
        return patterns.contains { pattern in
            guard !pattern.directoryOnly || isDirectory else { return false }
            return fnmatch(pattern.glob, pattern.anchored ? relativePath : name, pattern.anchored ? FNM_PATHNAME : 0) == 0
        }
    }
}

public enum FileBrowser {
    /// Folders never shown or searched: version control, build output and dependency caches (FR-FB03).
    public static let skippedNames: Set<String> = [".git", ".build", ".swiftpm", "node_modules", "DerivedData", ".DS_Store"]
    /// Search stops after this many files and says so, so a huge tree can't stall the view (FR-FB04).
    public static let searchFileLimit = 20_000
    public static let searchResultLimit = 200

    public static func isShown(_ entry: FileEntry, showHidden: Bool) -> Bool {
        !skippedNames.contains(entry.name) && (showHidden || !entry.name.hasPrefix("."))
    }

    /// Folders first, then case-insensitive natural name order.
    public static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The children of `directory` the tree shows, sorted.
    public static func children(of directory: String, root: String, listing: any FileListing, showHidden: Bool, ignore: IgnorePatterns) throws -> [FileEntry] {
        sorted(try listing.contents(of: directory).filter { isShown($0, showHidden: showHidden) && !ignore.ignores(relativePath: relativePath($0.path, root: root), isDirectory: $0.isDirectory) })
    }

    /// The root's ignore patterns, from its `.gitignore`.
    public static func ignorePatterns(root: String, listing: any FileListing) -> IgnorePatterns {
        listing.text(at: root + "/.gitignore").map(IgnorePatterns.init(gitignore:)) ?? .none
    }

    /// `path` relative to `root`; `path` itself when it is outside.
    public static func relativePath(_ path: String, root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Fuzzy file-name search under `root` (FR-FB04): names match by `FuzzyMatch`; a query holding `/` matches the
    /// relative path instead. Unreadable folders are skipped; the walk checks for cancellation between folders.
    public static func search(
        _ query: String, root: String, listing: any FileListing, showHidden: Bool, ignore: IgnorePatterns,
        fileLimit: Int = searchFileLimit, resultLimit: Int = searchResultLimit
    ) -> FileSearchResult {
        let byPath = query.contains("/")
        var matches: [FileSearchMatch] = []
        var queue = [root], next = 0, visited = 0, truncated = false
        walk: while next < queue.count {
            if Task.isCancelled { break }
            let directory = queue[next]
            next += 1
            guard let entries = try? children(of: directory, root: root, listing: listing, showHidden: showHidden, ignore: ignore) else { continue }
            for entry in entries {
                if entry.isDirectory { queue.append(entry.path); continue }
                visited += 1
                if visited > fileLimit { truncated = true; break walk }
                let relative = relativePath(entry.path, root: root)
                guard let match = FuzzyMatch.match(query, in: byPath ? relative : entry.name) else { continue }
                // Name positions are offsets into the name, so a path match is shown without highlights.
                matches.append(FileSearchMatch(entry: entry, relativeFolder: (relative as NSString).deletingLastPathComponent, score: match.score, namePositions: byPath ? [] : match.positions))
            }
        }
        matches.sort { $0.score != $1.score ? $0.score > $1.score : $0.entry.path.count < $1.entry.path.count }
        if matches.count > resultLimit { matches.removeLast(matches.count - resultLimit) }
        return FileSearchResult(query: query, matches: matches, truncated: truncated)
    }
}

public struct FileSearchMatch: Equatable, Identifiable, Sendable {
    public let entry: FileEntry
    /// The folder, relative to the root; empty for a file at the root.
    public let relativeFolder: String
    public let score: Int
    /// Character offsets of the matched letters in the name.
    public let namePositions: [Int]
    public var id: String { entry.path }
}

public struct FileSearchResult: Equatable, Sendable {
    public let query: String
    public let matches: [FileSearchMatch]
    /// The walk stopped at the file limit, so a match may be missing.
    public let truncated: Bool
}

/// An app the Files view can open a file in (FR-FB05). Finder reveals a file and opens a folder; `defaultApp` opens with
/// whatever the Mac uses for that file; `newTab` opens a Trellis tab in the folder; `trellisEditor` an editor tab.
public struct EditorApp: Equatable, Identifiable, Sendable {
    public let id: String
    private let englishName: String
    /// App names are proper names; only the two entries that aren't apps are translated.
    public var name: String {
        switch id {
        case "default": L("Default App")
        case "trellis-tab": L("New Tab Here")
        case "trellis-editor": L("Trellis Editor")
        default: englishName
        }
    }
    /// Tried in order; the first installed one is used.
    public let bundleIDs: [String]

    public init(id: String, name: String, bundleIDs: [String]) { self.id = id; englishName = name; self.bundleIDs = bundleIDs }

    public static let finder = EditorApp(id: "finder", name: "Finder", bundleIDs: ["com.apple.finder"])
    public static let defaultApp = EditorApp(id: "default", name: "Default App", bundleIDs: [])
    public static let newTab = EditorApp(id: "trellis-tab", name: "New Tab Here", bundleIDs: [])
    /// An editor tab in the current space (FR-ED09); the default until another app is chosen.
    public static let trellisEditor = EditorApp(id: "trellis-editor", name: "Trellis Editor", bundleIDs: [])

    /// The catalog, in menu order. Editors not installed aren't offered.
    public static let catalog: [EditorApp] = [
        .trellisEditor, .finder,
        EditorApp(id: "cursor", name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
        EditorApp(id: "vscode", name: "VS Code", bundleIDs: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium"]),
        EditorApp(id: "zed", name: "Zed", bundleIDs: ["dev.zed.Zed", "dev.zed.Zed-Preview"]),
        EditorApp(id: "xcode", name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"]),
        EditorApp(id: "sublime", name: "Sublime Text", bundleIDs: ["com.sublimetext.4", "com.sublimetext.3"]),
        EditorApp(id: "nova", name: "Nova", bundleIDs: ["com.panic.Nova"]),
        EditorApp(id: "intellij", name: "IntelliJ IDEA", bundleIDs: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]),
        EditorApp(id: "webstorm", name: "WebStorm", bundleIDs: ["com.jetbrains.WebStorm"]),
        EditorApp(id: "pycharm", name: "PyCharm", bundleIDs: ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"]),
        .defaultApp, .newTab
    ]

    public static func with(id: String) -> EditorApp? { catalog.first { $0.id == id } }
}
