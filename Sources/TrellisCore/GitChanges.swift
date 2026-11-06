import Foundation

/// One file of a repository's uncommitted changes (FR-GC02). Runtime only: never saved or logged.
public struct GitChangedFile: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case modified, added, deleted, untracked, conflicted

        public var letter: String {
            switch self {
            case .modified: "M"
            case .added: "A"
            case .deleted: "D"
            case .untracked: "U"
            case .conflicted: "C"
            }
        }

        public var word: String {
            switch self {
            case .modified: "Modified"
            case .added: "Added"
            case .deleted: "Deleted"
            case .untracked: "Untracked"
            case .conflicted: "Conflicted"
            }
        }
    }

    /// How much of the change is in the index.
    public enum Staging: Sendable {
        case none, partial, full

        public var word: String? {
            switch self {
            case .none: nil
            case .partial: "Partly staged"
            case .full: "Staged"
            }
        }
    }

    /// Relative to the repository's top level, with `/` between folders.
    public var path: String
    public var kind: Kind
    public var staging: Staging
    /// Lines added and removed against `HEAD`; nil when binary or not counted.
    public var added: Int?
    public var removed: Int?
    public var binary: Bool

    public init(path: String, kind: Kind, staging: Staging, added: Int? = nil, removed: Int? = nil, binary: Bool = false) {
        self.path = path; self.kind = kind; self.staging = staging; self.added = added; self.removed = removed; self.binary = binary
    }

    public var id: String { path }
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// A repository's uncommitted changes against `HEAD` (FR-GC02).
public struct GitChangeList: Equatable, Sendable {
    /// The repository's top level.
    public var root: String
    public var branch: String?
    /// The short commit when HEAD is detached.
    public var commit: String?
    public var ahead = 0
    public var behind = 0
    /// False before the first commit, when everything compares with the empty tree.
    public var hasCommits = true
    public var files: [GitChangedFile] = []
    /// More files changed than are listed.
    public var truncated = false

    public init(root: String, branch: String? = nil, commit: String? = nil, ahead: Int = 0, behind: Int = 0, hasCommits: Bool = true, files: [GitChangedFile] = [], truncated: Bool = false) {
        self.root = root; self.branch = branch; self.commit = commit; self.ahead = ahead; self.behind = behind; self.hasCommits = hasCommits
        self.files = files; self.truncated = truncated
    }

    public var added: Int { files.reduce(0) { $0 + ($1.added ?? 0) } }
    public var removed: Int { files.reduce(0) { $0 + ($1.removed ?? 0) } }
    /// The files in the tree's order, for "N of M" and next and previous file.
    public var orderedFiles: [GitChangedFile] { GitChanges.rows(files, collapsed: [], filter: "").compactMap(\.file) }
}

/// One line of a file's unified diff (FR-GC05).
public struct GitDiffLine: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case hunk, context, added, removed, note }
    public let id: Int
    public let kind: Kind
    public let old: Int?
    public let new: Int?
    public let text: String

    public init(id: Int, kind: Kind, old: Int?, new: Int?, text: String) { self.id = id; self.kind = kind; self.old = old; self.new = new; self.text = text }

    /// "Added line 12: …" for VoiceOver (FR-GC08).
    public var spoken: String {
        switch kind {
        case .hunk: "Hunk \(text)"
        case .added: "Added line \(new ?? 0): \(text)"
        case .removed: "Removed line \(old ?? 0): \(text)"
        case .context: "Line \(new ?? 0): \(text)"
        case .note: text
        }
    }
}

/// A file's diff against `HEAD`, as the Review tab shows it (FR-GC05).
public struct GitFileDiff: Equatable, Sendable {
    public enum Body: Equatable, Sendable { case lines([GitDiffLine]), binary, tooLarge, unchanged }
    public var body: Body
    public var hunks: Int
    /// The first line of each run of added or removed lines, for `n` and `p`.
    public var changeStarts: [Int]

    public init(body: Body, hunks: Int = 0, changeStarts: [Int] = []) { self.body = body; self.hunks = hunks; self.changeStarts = changeStarts }
}

/// One visible line of the Changes tree: a folder or a file (FR-GC02, FR-GC04).
public struct GitChangeRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case folder(expanded: Bool)
        case file(GitChangedFile)
    }
    public let kind: Kind
    /// A folder's path, or the file's, relative to the top level.
    public let path: String
    /// A merged folder chain shows as one name ("docs/features").
    public let name: String
    public let depth: Int
    public let added: Int
    public let removed: Int

    public var id: String { file == nil ? "d:" + path : "f:" + path }
    public var file: GitChangedFile? { if case .file(let file) = kind { file } else { nil } }
    public var isExpanded: Bool { if case .folder(let expanded) = kind { expanded } else { false } }
}

/// Reading git's output for the Changes view (FR-GC02, FR-GC05). Pure: the app runs git (`BrokerGit.capture`).
public enum GitChanges {
    /// Git's empty tree, the base before the first commit.
    public static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    public static let fileLimit = 2000
    public static let diffLineLimit = 20_000
    public static let diffByteLimit = 2 * 1024 * 1024
    /// Untracked files larger than this aren't read to count their lines.
    public static let countByteLimit = 1024 * 1024

    /// `git status --porcelain=v2 --branch -z` as a list without line counts. `complete` is false when the output was cut,
    /// so its last record may be partial.
    public static func parseStatus(_ output: String, root: String, complete: Bool = true) -> GitChangeList {
        var list = GitChangeList(root: root)
        var oid: String?
        var records = output.split(separator: "\0", omittingEmptySubsequences: true)
        if !complete, !records.isEmpty { records.removeLast(); list.truncated = true }
        var seen: Set<String> = []
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            if record.hasPrefix("# ") {
                if record.hasPrefix("# branch.oid ") {
                    let value = record.dropFirst("# branch.oid ".count)
                    list.hasCommits = value != "(initial)"
                    oid = list.hasCommits ? String(value.prefix(7)) : nil
                } else if record.hasPrefix("# branch.head ") {
                    let value = record.dropFirst("# branch.head ".count)
                    list.branch = value == "(detached)" ? nil : String(value.prefix(255))
                } else if record.hasPrefix("# branch.ab ") {
                    let parts = record.dropFirst("# branch.ab ".count).split(separator: " ")
                    if parts.count == 2 { list.ahead = Int(parts[0].dropFirst()) ?? 0; list.behind = Int(parts[1].dropFirst()) ?? 0 }
                }
                continue
            }
            guard let type = record.first else { continue }
            let fields: Int
            switch type {
            case "1": fields = 8
            case "2": fields = 9; index += 1  // the original path follows as its own record
            case "u": fields = 10
            case "?": fields = 1
            default: continue  // "!" ignored files
            }
            let parts = record.split(separator: " ", maxSplits: fields, omittingEmptySubsequences: false)
            guard parts.count == fields + 1 else { continue }
            let path = String(parts[fields])
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            if type == "?" {
                list.files.append(GitChangedFile(path: path, kind: .untracked, staging: .none))
                continue
            }
            let xy = Array(parts[1])
            guard xy.count == 2 else { continue }
            let (x, y) = (xy[0], xy[1])
            let kind: GitChangedFile.Kind = type == "u" ? .conflicted : x == "A" ? .added : (x == "D" || y == "D") ? .deleted : .modified
            let staging: GitChangedFile.Staging = type == "u" || x == "." ? .none : y == "." ? .full : .partial
            list.files.append(GitChangedFile(path: path, kind: kind, staging: staging))
        }
        if list.files.count > fileLimit { list.files.removeLast(list.files.count - fileLimit); list.truncated = true }
        if list.branch == nil { list.commit = oid }
        return list
    }

    /// `git diff --numstat -z --no-renames` as each path's lines added and removed; nil counts for a binary file.
    public static func parseNumstat(_ output: String) -> [String: (added: Int?, removed: Int?)] {
        var counts: [String: (added: Int?, removed: Int?)] = [:]
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            counts[String(parts[2])] = (Int(parts[0]), Int(parts[1]))
        }
        return counts
    }

    /// Puts numstat's counts on the listed files; a file numstat calls binary is marked so.
    public static func applying(_ counts: [String: (added: Int?, removed: Int?)], to list: GitChangeList) -> GitChangeList {
        var list = list
        for index in list.files.indices where list.files[index].kind != .untracked {
            guard let count = counts[list.files[index].path] else { list.files[index].added = 0; list.files[index].removed = 0; continue }
            list.files[index].added = count.added; list.files[index].removed = count.removed
            list.files[index].binary = count.added == nil
        }
        return list
    }

    /// A new file's line count, as `git diff` would count it: nil when it looks binary (a NUL byte in its first 8000).
    public static func lineCount(_ data: Data) -> Int? {
        guard !data.prefix(8000).contains(0) else { return nil }
        guard !data.isEmpty else { return 0 }
        let newlines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return data.last == 0x0A ? newlines : newlines + 1
    }

    /// `git diff` for one file as numbered lines; header lines before the first hunk are dropped.
    public static func parseDiff(_ output: String, lineLimit: Int = diffLineLimit) -> GitFileDiff {
        var lines: [GitDiffLine] = []
        var starts: [Int] = []
        var hunks = 0
        var old = 0, new = 0
        // Lines the hunk header promised, so a blank line inside a hunk (a context line whose space was stripped) stays context.
        var oldLeft = 0, newLeft = 0
        var inHunk = false
        var previousWasChange = false
        // "\r\n" is one Character, so splitting on "\n" alone would leave a CRLF file's diff as one line.
        for raw in output.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw[...]
            if !inHunk, hunks == 0, line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { return GitFileDiff(body: .binary) }
            if line.hasPrefix("@@ ") {
                guard let range = hunkRange(line) else { continue }
                (old, new, oldLeft, newLeft) = range
                inHunk = true; hunks += 1; previousWasChange = false
                lines.append(GitDiffLine(id: lines.count, kind: .hunk, old: nil, new: nil, text: String(line)))
            } else if inHunk {
                let text = String(line.dropFirst())
                switch line.first {
                case "+":
                    if !previousWasChange { starts.append(lines.count) }
                    lines.append(GitDiffLine(id: lines.count, kind: .added, old: nil, new: new, text: text)); new += 1; newLeft -= 1; previousWasChange = true
                case "-":
                    if !previousWasChange { starts.append(lines.count) }
                    lines.append(GitDiffLine(id: lines.count, kind: .removed, old: old, new: nil, text: text)); old += 1; oldLeft -= 1; previousWasChange = true
                case "\\":
                    lines.append(GitDiffLine(id: lines.count, kind: .note, old: nil, new: nil, text: String(line.dropFirst(2))))
                case " ",
                    nil where oldLeft > 0 && newLeft > 0:
                    lines.append(GitDiffLine(id: lines.count, kind: .context, old: old, new: new, text: text))
                    old += 1; new += 1; oldLeft -= 1; newLeft -= 1; previousWasChange = false
                default:
                    // The blank line at the end of the output, or anything else, ends the hunk.
                    inHunk = false
                }
            }
            if lines.count > lineLimit { return GitFileDiff(body: .tooLarge) }
        }
        guard hunks > 0 else { return GitFileDiff(body: .unchanged) }
        return GitFileDiff(body: .lines(lines), hunks: hunks, changeStarts: starts)
    }

    /// "@@ -12,7 +12,9 @@ …" → (12, 12, 7, 9): each side's first line and line count (1 when left out). A count of 0 means
    /// the side is empty and starts after the given line.
    static func hunkRange(_ line: Substring) -> (Int, Int, Int, Int)? {
        let parts = line.split(separator: " ", maxSplits: 3)
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func side(_ part: Substring) -> (Int, Int)? {
            let numbers = part.dropFirst().split(separator: ",")
            guard let first = numbers.first.flatMap({ Int($0) }) else { return nil }
            let count = numbers.count > 1 ? Int(numbers[1]) ?? 0 : 1
            return (count == 0 ? first + 1 : first, count)
        }
        guard let old = side(parts[1]), let new = side(parts[2]) else { return nil }
        return (old.0, new.0, old.1, new.1)
    }

    // MARK: The tree (FR-GC02, FR-GC04)

    private struct Node {
        var folders: [String: Node] = [:]
        var files: [GitChangedFile] = []

        var totals: (Int, Int) {
            var added = files.reduce(0) { $0 + ($1.added ?? 0) }, removed = files.reduce(0) { $0 + ($1.removed ?? 0) }
            for folder in folders.values {
                let (a, r) = folder.totals
                added += a; removed += r
            }
            return (added, removed)
        }
    }

    /// The tree flattened in display order: folders first, then files, each by name; a folder holding only one folder is
    /// merged with it. With a filter, only files whose path contains it (ignoring case) show, inside open folders.
    public static func rows(_ files: [GitChangedFile], collapsed: Set<String>, filter: String) -> [GitChangeRow] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var root = Node()
        for file in files where query.isEmpty || file.path.lowercased().contains(query) {
            let parts = file.path.split(separator: "/").map(String.init)
            insert(file, folders: parts.dropLast(), into: &root)
        }
        var rows: [GitChangeRow] = []
        func walk(_ node: Node, prefix: String, depth: Int) {
            for key in node.folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                var name = key, path = prefix + key, folder = node.folders[key]!
                while folder.files.isEmpty, folder.folders.count == 1, let (only, inner) = folder.folders.first {
                    name += "/" + only; path += "/" + only; folder = inner
                }
                let open = !query.isEmpty || !collapsed.contains(path)
                let (added, removed) = folder.totals
                rows.append(GitChangeRow(kind: .folder(expanded: open), path: path, name: name, depth: depth, added: added, removed: removed))
                if open { walk(folder, prefix: path + "/", depth: depth + 1) }
            }
            for file in node.files.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                rows.append(GitChangeRow(kind: .file(file), path: file.path, name: file.name, depth: depth, added: file.added ?? 0, removed: file.removed ?? 0))
            }
        }
        walk(root, prefix: "", depth: 0)
        return rows
    }

    private static func insert(_ file: GitChangedFile, folders: ArraySlice<String>, into node: inout Node) {
        guard let first = folders.first else { node.files.append(file); return }
        insert(file, folders: folders.dropFirst(), into: &node.folders[first, default: Node()])
    }

    /// Every folder path the tree would show, for Collapse All.
    public static func folderPaths(_ files: [GitChangedFile]) -> Set<String> {
        Set(rows(files, collapsed: [], filter: "").filter { $0.file == nil }.map(\.path))
    }
}
