import CryptoKit
import Foundation

/// Which side of the window the tool rail and dock sit on (FR-TD02).
public enum ToolDockSide: String, Codable, CaseIterable, Sendable {
    case right, left
    public var displayName: String { self == .right ? "Right" : "Left" }
    public var other: Self { self == .right ? .left : .right }
}

/// Where ⌘-clicked text files open (FR-TD09).
public enum FileLinkTarget: String, Codable, CaseIterable, Sendable {
    case toolDock, defaultApp
    public var displayName: String { self == .toolDock ? "Tool dock" : "Default app" }
}

/// One tool on the rail (FR-TD18). Adding a tool adds an entry here; the rail, menu and palette list `all`.
public struct ToolDockTool: Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    /// SF Symbol for the rail button.
    public let symbol: String
    public static let files = ToolDockTool(id: "files", title: "Files", symbol: "folder")
    public static let all: [ToolDockTool] = [.files]
}

/// Whether the dock docks beside the panes or floats over them (FR-TD03, FR-TD04).
public enum ToolDockLayout {
    public static let treeOnlyWidth = 300.0
    public static let editorWidth = 760.0
    public static let minimumWidth = 260.0
    public static let maximumShare = 0.7

    /// Floats when docking at `dockWidth` would leave the panes less than the split tree's minimum width (FR-P02's
    /// 20 columns per pane, as `CanvasDimensions.minimum` computes it).
    public static func floats(availableWidth: Double, dockWidth: Double, minimumCanvasWidth: Double) -> Bool {
        availableWidth - dockWidth < minimumCanvasWidth
    }

    /// A dragged width, kept between 260 points and 70% of the space beside the rail.
    public static func clamped(_ width: Double, availableWidth: Double) -> Double {
        min(max(width, minimumWidth), max(minimumWidth, availableWidth * maximumShare))
    }
}

/// The folder the Files tree shows for a pane's directory (FR-TD06).
public enum ToolDockRoot: Equatable, Sendable {
    case project(String)
    /// The home folder or `/`, which are never shown as a root.
    case notAProject

    /// The git work tree (or `.trellis` project) containing `directory`, else the library project folder containing it,
    /// else the directory itself; never home or `/`.
    public static func resolve(directory: String, home: String, libraryFolders: [String] = [], exists: (String) -> Bool) -> Self {
        let directory = URL(fileURLWithPath: directory).standardizedFileURL.path
        let home = URL(fileURLWithPath: home).standardizedFileURL.path
        if let root = ProjectLocator.taskRoot(containing: directory, home: home, exists: exists) { return .project(root) }
        let library = libraryFolders.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { $0 != "/" && $0 != home && (directory == $0 || directory.hasPrefix($0 + "/")) }
        if let folder = library.max(by: { $0.count < $1.count }) { return .project(folder) }
        return directory == "/" || directory == home ? .notAProject : .project(directory)
    }
}

/// A row of the Files tree (FR-TD08).
public struct FileTreeEntry: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case directory, file
        /// A symbolic link: shown, never expanded; a file link opens only when its target is inside the root.
        case link(targetIsDirectory: Bool, targetInsideRoot: Bool)
    }
    public let name: String
    public let path: String
    public let kind: Kind
    public init(name: String, path: String, kind: Kind) { self.name = name; self.path = path; self.kind = kind }
    public var isDirectory: Bool { kind == .directory }
    /// Opens in the editor when clicked.
    public var opensAsFile: Bool {
        switch kind {
        case .file: true
        case .directory: false
        case .link(let isDirectory, let inside): !isDirectory && inside
        }
    }
    var sortsWithFolders: Bool {
        switch kind {
        case .directory: true
        case .file: false
        case .link(let isDirectory, _): isDirectory
        }
    }
}

public struct FileTreeListing: Equatable, Sendable {
    public let entries: [FileTreeEntry]
    /// More than `FileTreeReader.maximumEntries` were there; only the first ones are listed.
    public let truncated: Bool
}

/// Reads one folder of the Files tree at a time (FR-TD08).
public enum FileTreeReader {
    public static let maximumEntries = 5_000
    /// What the filter searches at most, across the whole project.
    public static let maximumFilterFiles = 20_000

    /// Folders first, then files, each by Finder's order. Hidden files are listed; `.git` is not.
    public static func list(_ directory: String, root: String, fileManager: FileManager = .default) -> FileTreeListing {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return FileTreeListing(entries: [], truncated: false) }
        let rootPath = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        var entries: [FileTreeEntry] = []
        for name in names where name != ".git" {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let kind = kind(of: path, root: rootPath) else { continue }
            entries.append(FileTreeEntry(name: name, path: path, kind: kind))
        }
        entries.sort { a, b in
            a.sortsWithFolders != b.sortsWithFolders ? a.sortsWithFolders : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let truncated = entries.count > maximumEntries
        return FileTreeListing(entries: Array(entries.prefix(maximumEntries)), truncated: truncated)
    }

    static func kind(of path: String, root: String) -> FileTreeEntry.Kind? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        case S_IFLNK:
            let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            var targetInfo = stat()
            let isDirectory = stat(target, &targetInfo) == 0 && targetInfo.st_mode & S_IFMT == S_IFDIR
            return .link(targetIsDirectory: isDirectory, targetInsideRoot: target.hasPrefix(root + "/"))
        default: return nil
        }
    }

    /// Files under `root` whose relative path contains every whitespace-separated fragment of `query`, ignoring case,
    /// sorted by relative path. Symbolic links to folders and `.git` aren't descended into.
    public static func filter(root: String, query: String, fileManager: FileManager = .default) -> FileTreeListing {
        let fragments = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !fragments.isEmpty else { return FileTreeListing(entries: [], truncated: false) }
        let rootPath = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        var matches: [FileTreeEntry] = [], seen = 0, pending = [root]
        while let directory = pending.popLast() {
            for entry in list(directory, root: rootPath, fileManager: fileManager).entries {
                if entry.isDirectory { pending.append(entry.path); continue }
                guard entry.opensAsFile else { continue }
                seen += 1
                if seen > maximumFilterFiles { return FileTreeListing(entries: sorted(matches, root: root), truncated: true) }
                let relative = String(entry.path.dropFirst(root.count + 1)).lowercased()
                if fragments.allSatisfy(relative.contains) { matches.append(entry) }
            }
        }
        return FileTreeListing(entries: sorted(matches, root: root), truncated: false)
    }

    private static func sorted(_ entries: [FileTreeEntry], root: String) -> [FileTreeEntry] {
        entries.sorted { $0.path.dropFirst(root.count).localizedStandardCompare(String($1.path.dropFirst(root.count))) == .orderedAscending }
    }
}

/// The language a file is highlighted as (FR-TD11), from its extension; nil is plain text.
public enum EditorLanguage: String, CaseIterable, Sendable {
    case swift, json, markdown, shell, javascript, typescript, yaml, html

    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .json: "JSON"
        case .markdown: "Markdown"
        case .shell: "Shell"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .yaml: "YAML"
        case .html: "HTML"
        }
    }

    public static func detect(fileName: String) -> EditorLanguage? {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "swift": .swift
        case "json", "jsonc": .json
        case "md", "markdown": .markdown
        case "sh", "bash", "zsh", "command": .shell
        case "js", "mjs", "cjs", "jsx": .javascript
        case "ts", "mts", "cts", "tsx": .typescript
        case "yml", "yaml": .yaml
        case "html", "htm": .html
        default: nil
        }
    }
}

/// Why a file didn't open or save (FR-TD10, FR-TD12, FR-TD13). Codes are shared with the docs.
public enum EditorFileError: Error, Equatable, Sendable {
    case notFound, notRegularFile, networkPath, tooLarge, binary, notUTF8, permissionDenied
    /// The file on disk differs from the one the buffer was loaded from or last saved over.
    case changedOnDisk
    case readOnly
    case writeFailed(Int32)

    public var code: String {
        switch self {
        case .notFound: "FILE_NOT_FOUND"
        case .notRegularFile: "NOT_REGULAR_FILE"
        case .networkPath: "NETWORK_PATH_REFUSED"
        case .tooLarge: "FILE_TOO_LARGE"
        case .binary: "BINARY_FILE"
        case .notUTF8: "NOT_UTF8"
        case .permissionDenied: "PERMISSION_DENIED"
        case .changedOnDisk: "CHANGED_ON_DISK"
        case .readOnly: "READ_ONLY"
        case .writeFailed: "WRITE_FAILED"
        }
    }

    public var message: String {
        switch self {
        case .notFound: "The file is no longer on disk."
        case .notRegularFile: "Not a regular file."
        case .networkPath: "Files under /net and /Network aren't opened."
        case .tooLarge: "Larger than 2 MiB."
        case .binary: "Binary file."
        case .notUTF8: "Not UTF-8 text."
        case .permissionDenied: "Permission denied."
        case .changedOnDisk: "The file changed on disk."
        case .readOnly: "You can't write to this file."
        case .writeFailed(let code): "Couldn't save: \(String(cString: strerror(code)))."
        }
    }
}

/// What a file looked like when it was read or written, to notice changes made elsewhere (FR-TD13).
public struct EditorFileFingerprint: Equatable, Sendable {
    public let size: Int64
    public let modified: timespec
    public let sha256: String
    public static func == (a: Self, b: Self) -> Bool {
        a.size == b.size && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec && a.sha256 == b.sha256
    }
}

/// A text file opened in the editor: its contents and everything needed to write it back unchanged (FR-TD10–FR-TD13).
public struct EditorFile: Equatable, Sendable {
    public enum LineEnding: String, Sendable { case lf = "LF", crlf = "CRLF" }
    public static let maximumBytes = 2 * 1024 * 1024
    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// The path as opened; a symbolic link's target is what gets read and written.
    public let path: String
    public let resolvedPath: String
    public let text: String
    public let hasByteOrderMark: Bool
    public let lineEnding: LineEnding
    public let isWritable: Bool
    public let mode: mode_t
    public let fingerprint: EditorFileFingerprint
    public var language: EditorLanguage? { EditorLanguage.detect(fileName: path) }

    /// Reads a regular file of at most 2 MiB that is UTF-8 (with or without a byte order mark) without NUL bytes.
    public static func open(_ path: String) -> Result<EditorFile, EditorFileError> {
        let first = URL(fileURLWithPath: path).standardized.path.split(separator: "/").first?.lowercased()
        guard first != "net", first != "network" else { return .failure(.networkPath) }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let fd = Darwin.open(resolved, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(errno == ENOENT ? .notFound : errno == EACCES ? .permissionDenied : .notRegularFile) }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .failure(.notRegularFile) }
        guard info.st_size <= maximumBytes else { return .failure(.tooLarge) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; return .failure(.permissionDenied) }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { return .failure(.tooLarge) }
        }
        return decode(data).map { decoded in
            EditorFile(
                path: path, resolvedPath: resolved, text: decoded.text, hasByteOrderMark: decoded.bom, lineEnding: decoded.ending,
                isWritable: access(resolved, W_OK) == 0, mode: info.st_mode & 0o7777,
                fingerprint: EditorFileFingerprint(size: Int64(data.count), modified: info.st_mtimespec, sha256: ProjectTrustList.digest(data)))
        }
    }

    static func decode(_ data: Data) -> Result<(text: String, bom: Bool, ending: LineEnding), EditorFileError> {
        if data.contains(0) { return .failure(.binary) }
        let bom = data.starts(with: byteOrderMark)
        guard let text = String(data: bom ? data.dropFirst(3) : data, encoding: .utf8) else { return .failure(.notUTF8) }
        // Bytes, not Characters: "\r\n" is one Character in Swift.
        let newline = data.firstIndex(of: 0x0A)
        let ending: LineEnding = newline.map { $0 > data.startIndex && data[data.index(before: $0)] == 0x0D } == true ? .crlf : .lf
        return .success((text, bom, ending))
    }

    /// The bytes a save writes: a CRLF file keeps CRLF on every line, including lines typed since, and a byte order
    /// mark stays. The final newline, or its absence, is whatever the text has.
    public func encoded(_ text: String) -> Data {
        var body = text
        if lineEnding == .crlf { body = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") }
        return (hasByteOrderMark ? Data(Self.byteOrderMark) : Data()) + Data(body.utf8)
    }

    /// The fingerprint of what is on disk now; nil when the file is gone.
    public func currentFingerprint() -> EditorFileFingerprint? {
        guard case .success(let file) = Self.open(resolvedPath) else { return nil }
        return file.fingerprint
    }

    /// Writes `text` back atomically, keeping the permission bits and a symbolic link (its target is saved). Unless
    /// `overwrite`, refuses when the file changed on disk since this version was read or saved, so a change made
    /// elsewhere is never lost silently. A file that was deleted is recreated. On failure the file on disk is unchanged.
    public func save(_ text: String, overwrite: Bool = false) -> Result<EditorFile, EditorFileError> {
        guard isWritable else { return .failure(.readOnly) }
        let data = encoded(text)
        guard data.count <= Self.maximumBytes else { return .failure(.tooLarge) }
        let exists = FileManager.default.fileExists(atPath: resolvedPath)
        if exists, !overwrite, currentFingerprint() != fingerprint { return .failure(.changedOnDisk) }
        let target = URL(fileURLWithPath: resolvedPath)
        do {
            try OwnerOnlyStorage.atomicWrite(data, to: target, temporaryPrefix: "." + target.lastPathComponent + ".trellis-")
        } catch WorkspacePersistenceError.io(let code) {
            return .failure(code == EACCES || code == EPERM ? .permissionDenied : .writeFailed(code))
        } catch {
            return .failure(.writeFailed(EIO))
        }
        _ = chmod(resolvedPath, mode)
        switch Self.open(path) {
        case .success(let saved): return .success(saved)
        case .failure(let error): return .failure(error)
        }
    }

    public init(
        path: String, resolvedPath: String, text: String, hasByteOrderMark: Bool, lineEnding: LineEnding, isWritable: Bool, mode: mode_t,
        fingerprint: EditorFileFingerprint
    ) {
        self.path = path; self.resolvedPath = resolvedPath; self.text = text; self.hasByteOrderMark = hasByteOrderMark
        self.lineEnding = lineEnding; self.isWritable = isWritable; self.mode = mode; self.fingerprint = fingerprint
    }
}
