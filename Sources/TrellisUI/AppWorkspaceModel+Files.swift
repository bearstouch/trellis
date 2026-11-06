import AppKit
import Foundation
import TrellisCore

/// What the Files view shows (FR-FB02–FR-FB06). Runtime only: nothing here is saved with the workspace.
public struct FilesBrowserState: Equatable, Sendable {
    public enum Folder: Equatable, Sendable {
        case loaded([FileEntry])
        case unreadable
    }

    /// One visible line of the tree: an entry, or the note under a folder that couldn't be read.
    public struct Row: Identifiable, Equatable, Sendable {
        public let entry: FileEntry
        public let depth: Int
        public let unreadable: Bool
        public var id: String { unreadable ? entry.path + "\u{0}unreadable" : entry.path }
    }

    public internal(set) var paneID: UUID?
    /// The project root the tree shows; nil when the focused pane has no local folder.
    public internal(set) var root: String?
    public internal(set) var folders: [String: Folder] = [:]
    public internal(set) var expanded: Set<String> = []
    public internal(set) var selection: String?
    public internal(set) var showHidden = false
    public internal(set) var query = ""
    public internal(set) var search: FileSearchResult?
    public internal(set) var searching = false
    /// A short confirmation such as "Copied ~/x/y", cleared after a moment.
    public internal(set) var status: String?
    /// The editors installed on this Mac, in menu order, read when the view loads.
    public internal(set) var editors: [EditorApp] = []
    public internal(set) var editorID = EditorApp.finder.id
    /// Each installed editor's app, for its menu icon.
    var editorAppURLs: [String: URL] = [:]
    var ignore = IgnorePatterns.none
    /// Each root's open folders, so going back to a project's pane finds its tree as it was (this session only).
    var expandedByRoot: [String: Set<String>] = [:]

    public init() {}

    public var editor: EditorApp { editors.first { $0.id == editorID } ?? .finder }

    /// The tree flattened in display order, through open folders only.
    public var rows: [Row] {
        guard let root else { return [] }
        var rows: [Row] = []
        func add(_ folder: String, depth: Int) {
            switch folders[folder] {
            case .loaded(let entries)?:
                for entry in entries {
                    rows.append(Row(entry: entry, depth: depth, unreadable: false))
                    if entry.isDirectory, expanded.contains(entry.path) { add(entry.path, depth: depth + 1) }
                }
            case .unreadable?:
                rows.append(Row(entry: FileEntry(path: folder, isDirectory: true), depth: depth, unreadable: true))
            case nil: break
            }
        }
        add(root, depth: 0)
        return rows
    }

    /// The entries keyboard navigation moves through: search results while searching, else the tree.
    public var navigableEntries: [FileEntry] {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return search?.matches.map(\.entry) ?? [] }
        return rows.filter { !$0.unreadable }.map(\.entry)
    }

    public var selectedEntry: FileEntry? { selection.flatMap { path in navigableEntries.first { $0.path == path } } }
}

public enum FilePathStyle: Sendable { case absolute, relative, name }

extension AppWorkspaceModel {
    static let filesEditorKey = "files.editor"

    /// The tree's root for a folder: its project (the nearest folder with `.trellis` or `.git`), else the folder itself.
    nonisolated static func filesRoot(directory: String, home: String) -> String {
        let manager = FileManager.default
        return canonical(ProjectLocator.taskRoot(containing: directory, home: home, exists: { manager.fileExists(atPath: $0) }) ?? directory)
    }

    /// Reads the focused pane's project again: its root, the root listing and each open folder (FR-FB02, FR-FB03).
    public func refreshFiles(paneID: UUID) async {
        filesGeneration &+= 1
        let generation = filesGeneration
        loadEditorChoices()
        guard presentation.activePane?.id == paneID, sidebarUnavailableReason(.files) == nil, let directory = paneDirectory(paneID) else {
            resetFiles(paneID: paneID, root: nil)
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let root = await Task.detached(priority: .userInitiated) { Self.filesRoot(directory: directory, home: home) }.value
        guard generation == filesGeneration else { return }
        if files.root != root { resetFiles(paneID: paneID, root: root) }
        files.paneID = paneID
        let listing = fileListing, showHidden = files.showHidden
        let wanted = [root] + files.expanded.sorted()
        var (ignore, folders) = await Task.detached(priority: .userInitiated) {
            let ignore = FileBrowser.ignorePatterns(root: root, listing: listing)
            var folders: [String: FilesBrowserState.Folder] = [:]
            for folder in wanted { folders[folder] = Self.listFolder(folder, root: root, listing: listing, showHidden: showHidden, ignore: ignore) }
            return (ignore, folders)
        }.value
        guard generation == filesGeneration, files.root == root, files.showHidden == showHidden else { return }
        // A folder opened while this read ran keeps the listing it got; dropping it would leave it open but empty.
        for (path, folder) in files.folders where folders[path] == nil && files.expanded.contains(path) { folders[path] = folder }
        files.ignore = ignore
        files.folders = folders
        if !files.query.isEmpty { startFilesSearch() }
    }

    /// The installed editors and the remembered choice, shared by Files and Changes (FR-FB05, FR-GC07). Looked up when a
    /// view loads, not while drawing: the view redraws on every model change and Launch Services isn't free.
    func loadEditorChoices() {
        files.editorAppURLs = Dictionary(uniqueKeysWithValues: EditorApp.catalog.compactMap { app in appURL(for: app).map { (app.id, $0) } })
        files.editors = EditorApp.catalog.filter { $0.bundleIDs.isEmpty || $0 == .finder || files.editorAppURLs[$0.id] != nil }
        files.editorID = preferences.string(forKey: Self.filesEditorKey) ?? EditorApp.finder.id
    }

    private func resetFiles(paneID: UUID, root: String?) {
        filesSearchTask?.cancel()
        if let old = files.root { files.expandedByRoot[old] = files.expanded }
        var state = FilesBrowserState()
        (state.paneID, state.root, state.showHidden) = (paneID, root, files.showHidden)
        (state.editors, state.editorID, state.status, state.editorAppURLs) = (files.editors, files.editorID, files.status, files.editorAppURLs)
        state.expandedByRoot = files.expandedByRoot
        state.expanded = root.flatMap { files.expandedByRoot[$0] } ?? []
        files = state
    }

    nonisolated static func listFolder(_ folder: String, root: String, listing: any FileListing, showHidden: Bool, ignore: IgnorePatterns) -> FilesBrowserState.Folder {
        (try? FileBrowser.children(of: folder, root: root, listing: listing, showHidden: showHidden, ignore: ignore)).map { .loaded($0) } ?? .unreadable
    }

    /// Opens or closes a folder; its children are read the first time it opens.
    public func toggleFilesFolder(_ path: String) async {
        files.selection = path
        if files.expanded.contains(path) {
            files.expanded.remove(path)
            return
        }
        files.expanded.insert(path)
        guard files.folders[path] == nil, let root = files.root else { return }
        let listing = fileListing, showHidden = files.showHidden, ignore = files.ignore
        let folder = await Task.detached(priority: .userInitiated) { Self.listFolder(path, root: root, listing: listing, showHidden: showHidden, ignore: ignore) }.value
        guard files.root == root, files.showHidden == showHidden else { return }
        files.folders[path] = folder
    }

    public func collapseAllFilesFolders() { files.expanded = [] }

    public func setFilesShowHidden(_ show: Bool) async {
        guard files.showHidden != show else { return }
        files.showHidden = show
        files.folders = [:]
        if let paneID = files.paneID { await refreshFiles(paneID: paneID) }
    }

    public func selectFile(_ path: String?) { files.selection = path }

    /// Moves the selection up or down the visible entries, from the first one when nothing is selected.
    public func moveFilesSelection(by offset: Int) {
        let entries = files.navigableEntries
        guard !entries.isEmpty else { return }
        guard let current = files.selection.flatMap({ path in entries.firstIndex { $0.path == path } }) else {
            files.selection = (offset < 0 ? entries.last : entries.first)?.path
            return
        }
        files.selection = entries[max(0, min(entries.count - 1, current + offset))].path
    }

    // MARK: Search (FR-FB04)

    public func setFilesQuery(_ query: String) {
        guard files.query != query else { return }
        files.query = query
        startFilesSearch()
    }

    func startFilesSearch() {
        filesSearchTask?.cancel()
        let query = files.query
        guard let root = files.root, query.contains(where: { !$0.isWhitespace }) else {
            (files.search, files.searching) = (nil, false)
            return
        }
        files.searching = true
        let listing = fileListing, showHidden = files.showHidden, ignore = files.ignore
        filesSearchTask = Task { [weak self] in
            // Typing settles before the walk starts, so each letter doesn't start one.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) { FileBrowser.search(query, root: root, listing: listing, showHidden: showHidden, ignore: ignore) }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, let self, self.files.query == query, self.files.root == root else { return }
            self.files.search = result
            self.files.searching = false
            self.files.selection = result.matches.first?.entry.path
        }
    }

    /// Waits for the search in flight; for tests.
    public func waitForFilesSearch() async { await filesSearchTask?.value }

    // MARK: Open in (FR-FB05)

    func appURL(for editor: EditorApp) -> URL? { editor.bundleIDs.lazy.compactMap { self.applicationURL($0) }.first }

    /// The editor's app on this Mac, for its icon; nil for the built-in choices.
    public func filesEditorAppURL(_ editor: EditorApp) -> URL? { files.editorAppURLs[editor.id] }

    /// Opens a file or folder (the root when nil) in `editor`, or in the remembered one. Choosing an editor remembers it.
    public func openFile(_ entry: FileEntry?, in editor: EditorApp? = nil) async {
        if let editor {
            files.editorID = editor.id
            preferences.set(editor.id, forKey: Self.filesEditorKey)
        }
        let editor = editor ?? files.editor
        guard let entry = entry ?? files.root.map({ FileEntry(path: $0, isDirectory: true) }) else { return }
        let url = URL(fileURLWithPath: entry.path, isDirectory: entry.isDirectory)
        switch editor.id {
        case EditorApp.finder.id, EditorApp.defaultApp.id:
            // Opening with what the Mac picks must never run code (as for file links, FR-L03): an app, a script or an
            // executable is only revealed; a FIFO or device does nothing.
            let path = entry.path
            switch await Task.detached(priority: .userInitiated, operation: { FileLinkPolicy.action(path: path) }).value {
            case .open(let target)? where editor == .defaultApp || entry.isDirectory: openFileInApp(target, nil)
            case .open(let target)?, .reveal(let target)?: revealFiles([target])
            case nil: errorMessage = "\(entry.name) can't be opened."
            }
        case EditorApp.newTab.id: await openTabForDirectory(entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent, target: .local)
        default:
            guard let app = appURL(for: editor) else {
                errorMessage = "\(editor.name) isn't installed on this Mac."
                return
            }
            openFileInApp(url, app)
        }
    }

    /// Opens a file or folder in an app the user picked; it isn't remembered.
    public func openFile(_ entry: FileEntry?, withApp app: URL) {
        guard let path = entry?.path ?? files.root else { return }
        openFileInApp(URL(fileURLWithPath: path), app)
    }

    public func revealFile(_ entry: FileEntry) { revealFiles([URL(fileURLWithPath: entry.path)]) }

    // MARK: Copy and insert (FR-FB06)

    public func copyFilePath(_ entry: FileEntry, style: FilePathStyle = .absolute) {
        let text: String
        switch style {
        case .absolute: text = entry.path
        case .relative: text = files.root.map { FileBrowser.relativePath(entry.path, root: $0) } ?? entry.path
        case .name: text = entry.name
        }
        copyToPasteboard(text)
        showFilesStatus("Copied \(style == .absolute ? Self.abbreviatingHome(text) : text)")
    }

    /// Inserts the path, quoted for the shell, at the focused pane's prompt through the paste route; nothing runs.
    public func insertFilePath(_ entry: FileEntry) {
        guard let paneID = presentation.activePane?.id else { return }
        requestPaste(.paths([entry.path]), paneID: paneID)
        focusActiveTerminal()
    }

    /// Types `cd '<folder>'` at the prompt without pressing Return, so the user decides whether it runs.
    public func typeChangeDirectory(_ entry: FileEntry) {
        guard let paneID = presentation.activePane?.id else { return }
        let folder = entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent
        requestPaste(.text("cd '" + folder.replacingOccurrences(of: "'", with: "'\\''") + "'"), paneID: paneID)
        focusActiveTerminal()
    }

    func showFilesStatus(_ text: String) {
        files.status = text
        filesStatusTask?.cancel()
        filesStatusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.files.status == text else { return }
            self.files.status = nil
        }
    }

    nonisolated static func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
