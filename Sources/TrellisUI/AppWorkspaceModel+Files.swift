import AppKit
import Foundation
import TrellisCore

/// The remote workspace host whose files the Files view shows (FR-FB09).
public struct FilesHost: Equatable, Sendable {
    public let id: UUID
    public let name: String
    /// The account's home folder there, for `~` in shown paths.
    public let home: String
}

/// What the Files view shows (FR-FB02–FR-FB06, FR-FB09). Runtime only: nothing here is saved with the workspace.
public struct FilesBrowserState: Equatable, Sendable {
    public enum Folder: Equatable, Sendable {
        case loaded([FileEntry])
        case unreadable
    }

    /// One visible line of the tree: an entry, or a note under a folder: it couldn't be read, or it holds more entries
    /// than a host lists (FR-FB09).
    public struct Row: Identifiable, Equatable, Sendable {
        public let entry: FileEntry
        public let depth: Int
        public let unreadable: Bool
        public var truncated = false
        public var isNote: Bool { unreadable || truncated }
        public var id: String { unreadable ? entry.path + "\u{0}unreadable" : truncated ? entry.path + "\u{0}truncated" : entry.path }
    }

    public internal(set) var paneID: UUID?
    /// The host the tree is read from; nil for this Mac.
    public internal(set) var host: FilesHost?
    /// Why a remote tree is missing or may be stale, in words (FR-FB09).
    public internal(set) var notice: String?
    /// Folders a host listed only in part.
    public internal(set) var truncated: Set<String> = [] { didSet { if truncated != oldValue { rebuildRows() } } }
    /// The project root the tree shows; nil when the focused pane has no folder to show.
    public internal(set) var root: String? { didSet { if root != oldValue { rebuildRows() } } }
    public internal(set) var folders: [String: Folder] = [:] { didSet { rebuildRows() } }
    public internal(set) var expanded: Set<String> = [] { didSet { if expanded != oldValue { rebuildRows() } } }
    /// The tree flattened in display order, through open folders only. Kept up to date as the tree changes, not built on
    /// every read: the view, the Open in menu and each arrow key all read it.
    public private(set) var rows: [Row] = []
    /// Each tree entry's place among the readable rows, for selection and arrow keys.
    private var treeIndex: [String: Int] = [:]
    private var treeEntries: [FileEntry] = []
    public internal(set) var selection: String?
    public internal(set) var showHidden = false
    /// Shows what the root's `.gitignore` ignores; independent of ``showHidden`` (FR-FB03).
    public internal(set) var showIgnored = false
    public internal(set) var query = ""
    public internal(set) var search: FileSearchResult?
    public internal(set) var searching = false
    /// A short confirmation such as "Copied ~/x/y", cleared after a moment.
    public internal(set) var status: String?
    /// The editors installed on this Mac, in menu order, read when the view loads.
    public internal(set) var editors: [EditorApp] = []
    public internal(set) var editorID = EditorApp.trellisEditor.id
    /// Each installed editor's app, for its menu icon.
    var editorAppURLs: [String: URL] = [:]
    var ignore = IgnorePatterns.none
    /// The patterns the tree and search apply: none while ignored files are shown.
    var effectiveIgnore: IgnorePatterns { showIgnored ? .none : ignore }
    /// Each root's open folders, so going back to a project's pane finds its tree as it was (this session only).
    var expandedByRoot: [String: Set<String>] = [:]

    public init() {}

    /// The app remembered for this Mac's files; Changes, review and editor tabs use it too.
    public var editor: EditorApp { editors.first { $0.id == editorID } ?? .trellisEditor }
    /// What the tree opens with: a host's files open only in Trellis, since nothing on this Mac can reach them.
    public var treeEditor: EditorApp { host != nil ? .trellisEditor : editor }
    /// What **Open in** lists: the installed editors, or for a host an editor tab and a tab there.
    public var offeredEditors: [EditorApp] { host != nil ? [.trellisEditor, .newTab] : editors }

    /// Open folders are remembered per project and machine: a host's `/srv/app` isn't this Mac's.
    static func rootKey(_ root: String, host: FilesHost?) -> String { (host?.id.uuidString ?? "") + "\u{0}" + root }

    private mutating func rebuildRows() {
        var rows: [Row] = []
        func add(_ folder: String, depth: Int) {
            switch folders[folder] {
            case .loaded(let entries)?:
                for entry in entries {
                    rows.append(Row(entry: entry, depth: depth, unreadable: false))
                    if entry.isDirectory, expanded.contains(entry.path) { add(entry.path, depth: depth + 1) }
                }
                if truncated.contains(folder) { rows.append(Row(entry: FileEntry(path: folder, isDirectory: true), depth: depth, unreadable: false, truncated: true)) }
            case .unreadable?:
                rows.append(Row(entry: FileEntry(path: folder, isDirectory: true), depth: depth, unreadable: true))
            case nil: break
            }
        }
        if let root { add(root, depth: 0) }
        self.rows = rows
        treeEntries = rows.filter { !$0.isNote }.map(\.entry)
        treeIndex = Dictionary(treeEntries.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var isSearching: Bool { query.contains { !$0.isWhitespace } }

    /// The entries keyboard navigation moves through: search results while searching, else the tree.
    public var navigableEntries: [FileEntry] { isSearching ? search?.matches.map(\.entry) ?? [] : treeEntries }

    /// Where `path` is in ``navigableEntries``.
    func navigableIndex(of path: String) -> Int? {
        isSearching ? search?.matches.firstIndex { $0.entry.path == path } : treeIndex[path]
    }

    public var selectedEntry: FileEntry? { selection.flatMap { navigableIndex(of: $0) }.map { navigableEntries[$0] } }
}

public enum FilePathStyle: Sendable { case absolute, relative, name }

/// Publishes the Files view's state on its own, so only the Files view redraws when it changes (see `AppWorkspaceModel.files`).
@MainActor public final class FilesBrowserModel: ObservableObject {
    @Published public internal(set) var state = FilesBrowserState() { didSet { marks.update(from: oldValue, to: state) } }
    let marks = FilesLineMarks()
    public init() {}
}

/// Whether one tree line is selected and, for a folder, open. Each line watches its own.
@MainActor final class FilesLineMark: ObservableObject {
    @Published fileprivate(set) var selected: Bool
    @Published fileprivate(set) var expanded: Bool
    fileprivate init(selected: Bool, expanded: Bool) { (self.selected, self.expanded) = (selected, expanded) }
}

/// The marks of the tree lines drawn so far, by path. The list keeps every line it has drawn, so lines that all watched the
/// Files state were all redrawn on each arrow key, thousands of them in a long folder; a selection move now tells two.
@MainActor final class FilesLineMarks {
    private struct Held { weak var mark: FilesLineMark? }
    private var held: [String: Held] = [:]
    /// How many paths are remembered, live or not; for tests.
    var count: Int { held.count }

    /// The mark for `path`, kept for as long as a line uses it.
    func mark(for path: String, in state: FilesBrowserState) -> FilesLineMark {
        if let mark = held[path]?.mark { return mark }
        let mark = FilesLineMark(selected: state.selection == path, expanded: state.expanded.contains(path))
        held[path] = Held(mark: mark)
        return mark
    }

    fileprivate func update(from old: FilesBrowserState, to new: FilesBrowserState) {
        if old.selection != new.selection {
            if let path = old.selection, let mark = held[path]?.mark, mark.selected { mark.selected = false }
            if let path = new.selection, let mark = held[path]?.mark, !mark.selected { mark.selected = true }
        }
        if old.expanded != new.expanded {
            for path in old.expanded.symmetricDifference(new.expanded) {
                let open = new.expanded.contains(path)
                if let mark = held[path]?.mark, mark.expanded != open { mark.expanded = open }
            }
        }
        // Marks no line uses any more are dropped when the tree moves to another project, or once they outnumber its rows.
        if old.root != new.root || held.count > max(1024, new.rows.count * 2) { held = held.filter { $0.value.mark != nil } }
    }
}

extension AppWorkspaceModel {
    static let filesEditorKey = "files.editor"

    /// The tree's root for a folder: its project (the nearest folder with `.trellis` or `.git`), else the folder itself.
    nonisolated static func filesRoot(directory: String, home: String) -> String {
        let manager = FileManager.default
        return canonical(ProjectLocator.taskRoot(containing: directory, home: home, exists: { manager.fileExists(atPath: $0) }) ?? directory)
    }

    /// Reads the focused pane's project again: its root, the root listing and each open folder (FR-FB02, FR-FB03). The
    /// installed editors are looked up the first time and on Reload (`reloadEditors`), not on every pane switch or `cd`:
    /// Launch Services lookups run on the main thread.
    public func refreshFiles(paneID: UUID, reloadEditors: Bool = false) async {
        filesGeneration &+= 1
        let generation = filesGeneration
        if reloadEditors || files.editors.isEmpty { loadEditorChoices() }
        // Reload reads a host's tree again for search too.
        if reloadEditors { filesSearchCache = nil }
        guard presentation.activePane?.id == paneID, sidebarUnavailableReason(.files) == nil else { return resetFiles(paneID: paneID, root: nil) }
        if let hostID = remoteHostID(paneID: paneID) { return await refreshRemoteFiles(paneID: paneID, hostID: hostID, generation: generation) }
        guard let directory = paneDirectory(paneID) else { return resetFiles(paneID: paneID, root: nil) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let root = await Task.detached(priority: .userInitiated) { Self.filesRoot(directory: directory, home: home) }.value
        guard generation == filesGeneration else { return }
        if files.root != root || files.host != nil || files.notice != nil { resetFiles(paneID: paneID, root: root) }
        files.paneID = paneID
        let listing = fileListing, showHidden = files.showHidden, showIgnored = files.showIgnored
        let wanted = [root] + files.expanded.sorted()
        var (ignore, folders) = await Task.detached(priority: .userInitiated) {
            let ignore = FileBrowser.ignorePatterns(root: root, listing: listing)
            let applied = showIgnored ? IgnorePatterns.none : ignore
            var folders: [String: FilesBrowserState.Folder] = [:]
            for folder in wanted { folders[folder] = Self.listFolder(folder, root: root, listing: listing, showHidden: showHidden, ignore: applied) }
            return (ignore, folders)
        }.value
        guard generation == filesGeneration, files.root == root, files.host == nil, files.showHidden == showHidden, files.showIgnored == showIgnored else { return }
        // A folder opened while this read ran keeps the listing it got; dropping it would leave it open but empty.
        for (path, folder) in files.folders where folders[path] == nil && files.expanded.contains(path) { folders[path] = folder }
        files.ignore = ignore
        files.folders = folders
        if !files.query.isEmpty { startFilesSearch() }
    }

    // MARK: A remote workspace's files (FR-FB09)

    /// The connected host's files, through its helper; nil while the host isn't connected.
    func remoteFiles(_ hostID: UUID) -> (any RemoteFileAccess)? {
        if let remoteFileAccess { return remoteFileAccess(hostID) }
        return remoteHosts?.workspaceConnection(hostID).flatMap { BrokerFileAccess(connection: $0) }
    }

    /// The host a remote workspace pane runs on.
    func remoteHostID(paneID: UUID) -> UUID? { snapshot.panes[paneID].flatMap { snapshot.sessions[$0.sessionID]?.launch.remoteHostID } }

    /// A remote workspace pane's folder on its host: where its shell says it is, else where it was started.
    func remotePaneDirectory(_ paneID: UUID) -> String? {
        if let directory = remoteWorkingDirectory(paneID: paneID) { return directory }
        switch snapshot.panes[paneID].flatMap({ snapshot.sessions[$0.sessionID] })?.launch {
        case .remoteShell(_, let directory)?: return directory
        case .agent(let agent)? where agent.hostID != nil: return agent.directory
        default: return nil
        }
    }

    /// What re-reads the tree: the pane, its folder (a `cd` re-roots it, FR-FB02) and, for a host, whether it is connected.
    public func filesRefreshKey(paneID: UUID) -> [String?] {
        guard let hostID = remoteHostID(paneID: paneID) else { return [paneID.uuidString, paneDirectory(paneID)] }
        return [paneID.uuidString, remotePaneDirectory(paneID), hostID.uuidString, remoteLinks[hostID] == .connected ? "connected" : "down"]
    }

    private func refreshRemoteFiles(paneID: UUID, hostID: UUID, generation: Int) async {
        let name = remoteHostName(hostID)
        func disconnected() {
            // The tree already read stays while the link is down; it says it may be stale.
            if files.host?.id == hostID, files.root != nil {
                files.paneID = paneID
                files.notice = L("Not connected to %@. The tree shows what was last read.", name)
            } else {
                resetFiles(paneID: paneID, root: nil, notice: L("Not connected to %@. Its files show once it is connected.", name))
            }
        }
        guard let access = remoteFiles(hostID) else { return disconnected() }
        guard access.browses else { return resetFiles(paneID: paneID, root: nil, notice: L("Update the Trellis helper on %@ to browse its files.", name)) }
        let host = FilesHost(id: hostID, name: name, home: access.home)
        let root = await access.projectRoot(containing: remotePaneDirectory(paneID) ?? access.home)
        guard generation == filesGeneration else { return }
        // The link went down while the root was asked for: the answer is a guess, and the tree already read stays.
        guard remoteFiles(hostID) != nil else { return disconnected() }
        if files.root != root || files.host != host { resetFiles(paneID: paneID, root: root, host: host) }
        files.paneID = paneID
        files.notice = nil
        let showHidden = files.showHidden, showIgnored = files.showIgnored
        let wanted = [root] + files.expanded.sorted()
        let ignore = await FileBrowser.ignorePatterns(root: root, source: access)
        let listed = await access.contents(of: wanted)
        guard generation == filesGeneration, files.root == root, files.host == host, files.showHidden == showHidden, files.showIgnored == showIgnored else { return }
        var folders: [String: FilesBrowserState.Folder] = [:], truncated = Set<String>()
        for folder in wanted {
            // No answer (the link went down mid-read) isn't "can't read": a folder already listed stays as it was.
            if listed[folder] == nil, let known = files.folders[folder] {
                folders[folder] = known
                if files.truncated.contains(folder) { truncated.insert(folder) }
                continue
            }
            let read = Self.folder(listed[folder], root: root, showHidden: showHidden, ignore: showIgnored ? .none : ignore)
            folders[folder] = read.folder
            if read.truncated { truncated.insert(folder) }
        }
        for (path, folder) in files.folders where folders[path] == nil && files.expanded.contains(path) {
            folders[path] = folder
            if files.truncated.contains(path) { truncated.insert(path) }
        }
        files.ignore = ignore
        files.truncated = truncated
        files.folders = folders
        if !files.query.isEmpty { startFilesSearch() }
    }

    nonisolated static func folder(_ listing: FolderListing?, root: String, showHidden: Bool, ignore: IgnorePatterns) -> (folder: FilesBrowserState.Folder, truncated: Bool) {
        guard case .entries(let entries, let truncated)? = listing else { return (.unreadable, false) }
        return (.loaded(FileBrowser.visible(entries, root: root, showHidden: showHidden, ignore: ignore)), truncated)
    }

    /// The installed editors and the remembered choice, shared by Files and Changes (FR-FB05, FR-GC07). Looked up when a
    /// view loads, not while drawing: the view redraws on every model change and Launch Services isn't free.
    func loadEditorChoices() {
        files.editorAppURLs = Dictionary(uniqueKeysWithValues: EditorApp.catalog.compactMap { app in appURL(for: app).map { (app.id, $0) } })
        files.editors = EditorApp.catalog.filter { $0.bundleIDs.isEmpty || $0 == .finder || files.editorAppURLs[$0.id] != nil }
        files.editorID = preferences.string(forKey: Self.filesEditorKey) ?? EditorApp.trellisEditor.id
    }

    private func resetFiles(paneID: UUID, root: String?, host: FilesHost? = nil, notice: String? = nil) {
        filesSearchTask?.cancel()
        filesSearchCache = nil
        if let old = files.root { files.expandedByRoot[FilesBrowserState.rootKey(old, host: files.host)] = files.expanded }
        var state = FilesBrowserState()
        (state.paneID, state.root, state.showHidden, state.showIgnored) = (paneID, root, files.showHidden, files.showIgnored)
        (state.host, state.notice) = (host, notice)
        (state.editors, state.editorID, state.status, state.editorAppURLs) = (files.editors, files.editorID, files.status, files.editorAppURLs)
        state.expandedByRoot = files.expandedByRoot
        state.expanded = root.flatMap { files.expandedByRoot[FilesBrowserState.rootKey($0, host: host)] } ?? []
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
        let listing = fileListing, showHidden = files.showHidden, showIgnored = files.showIgnored, ignore = files.effectiveIgnore
        if let host = files.host {
            let listed = await remoteFiles(host.id)?.contents(of: [path])[path]
            guard files.root == root, files.host == host, files.showHidden == showHidden, files.showIgnored == showIgnored else { return }
            let read = Self.folder(listed, root: root, showHidden: showHidden, ignore: ignore)
            if read.truncated { files.truncated.insert(path) } else { files.truncated.remove(path) }
            files.folders[path] = read.folder
            return
        }
        let folder = await Task.detached(priority: .userInitiated) { Self.listFolder(path, root: root, listing: listing, showHidden: showHidden, ignore: ignore) }.value
        guard files.root == root, files.host == nil, files.showHidden == showHidden, files.showIgnored == showIgnored else { return }
        files.folders[path] = folder
    }

    public func collapseAllFilesFolders() { files.expanded = [] }

    public func setFilesShowHidden(_ show: Bool) async {
        guard files.showHidden != show else { return }
        files.showHidden = show
        files.folders = [:]
        files.truncated = []
        if let paneID = files.paneID { await refreshFiles(paneID: paneID) }
    }

    /// Shows or hides what the root's `.gitignore` ignores (FR-FB03); the always-skipped names stay hidden.
    public func setFilesShowIgnored(_ show: Bool) async {
        guard files.showIgnored != show else { return }
        files.showIgnored = show
        files.folders = [:]
        files.truncated = []
        if let paneID = files.paneID { await refreshFiles(paneID: paneID) }
    }

    public func selectFile(_ path: String?) { files.selection = path }

    /// Moves the selection up or down the visible entries, from the first one when nothing is selected.
    public func moveFilesSelection(by offset: Int) {
        let entries = files.navigableEntries
        guard !entries.isEmpty else { return }
        guard let current = files.selection.flatMap({ files.navigableIndex(of: $0) }) else {
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
            // A cleared field ends the search a host's tree was remembered for.
            filesSearchCache = nil
            return
        }
        files.searching = true
        let listing = fileListing, showHidden = files.showHidden, ignore = files.effectiveIgnore
        let source = files.host.flatMap { remoteSearchSource(host: $0, root: root) }
        // A host that isn't connected has nothing to search; the results say so by being empty.
        let remote = files.host != nil
        filesSearchTask = Task { [weak self] in
            // Typing settles before the walk starts, so each letter doesn't start one.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) {
                if let source { return await FileBrowser.search(query, root: root, source: source, showHidden: showHidden, ignore: ignore) }
                if remote { return FileSearchResult(query: query, matches: [], truncated: false) }
                return FileBrowser.search(query, root: root, listing: listing, showHidden: showHidden, ignore: ignore)
            }
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

    /// One walk of the host's tree serves every letter of a search: the listings are remembered until the field is
    /// cleared, the tree is reloaded, or the root, host or toggles change.
    private func remoteSearchSource(host: FilesHost, root: String) -> CachedTreeSource? {
        let key = [host.id.uuidString, root, files.showHidden ? "h" : "", files.showIgnored ? "i" : ""].joined(separator: "\u{0}")
        if let cache = filesSearchCache, cache.key == key { return cache.source }
        guard let access = remoteFiles(host.id), access.browses else { return nil }
        let source = CachedTreeSource(access)
        filesSearchCache = (key, source)
        return source
    }

    /// Waits for the search in flight; for tests.
    public func waitForFilesSearch() async { await filesSearchTask?.value }

    // MARK: Open in (FR-FB05)

    func appURL(for editor: EditorApp) -> URL? { editor.bundleIDs.lazy.compactMap { self.applicationURL($0) }.first }

    /// The editor's app on this Mac, for its icon; nil for the built-in choices.
    public func filesEditorAppURL(_ editor: EditorApp) -> URL? { files.editorAppURLs[editor.id] }

    /// Opens a file or folder (the root when nil) in `editor`, or in the remembered one. Choosing an editor remembers it.
    /// From the Files view: a host's tree opens on the host (FR-FB09), this Mac's as ``openLocalFile(_:in:remember:)``.
    public func openFile(_ entry: FileEntry?, in editor: EditorApp? = nil, remember: Bool = true) async {
        if let host = files.host { return await openRemoteFile(entry, host: host, in: editor ?? files.treeEditor) }
        await openLocalFile(entry, in: editor, remember: remember)
    }

    /// Opens a file or folder on this Mac, whatever tree Files is showing: Changes, review and editor tabs open through here.
    public func openLocalFile(_ entry: FileEntry?, in editor: EditorApp? = nil, remember: Bool = true) async {
        if let editor, remember {
            files.editorID = editor.id
            preferences.set(editor.id, forKey: Self.filesEditorKey)
        }
        let editor = editor ?? files.editor
        // With nothing named, the project folder: only this Mac's, never a host's path.
        guard let entry = entry ?? (files.host == nil ? files.root.map { FileEntry(path: $0, isDirectory: true) } : nil) else { return }
        let url = URL(fileURLWithPath: entry.path, isDirectory: entry.isDirectory)
        switch editor.id {
        case EditorApp.finder.id, EditorApp.defaultApp.id:
            // Opening with what the Mac picks must never run code (as for file links, FR-L03): an app, a script or an
            // executable is only revealed; a FIFO or device does nothing.
            let path = entry.path
            switch await Task.detached(priority: .userInitiated, operation: { FileLinkPolicy.action(path: path) }).value {
            case .open(let target)? where editor == .defaultApp || entry.isDirectory: openFileInApp(target, nil)
            case .open(let target)?, .reveal(let target)?: revealFiles([target])
            case nil: errorMessage = L("%@ can't be opened.", entry.name)
            }
        case EditorApp.trellisEditor.id: await openFileInEditor(entry)
        case EditorApp.newTab.id: await openTabForDirectory(entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent, target: .local)
        default:
            guard let app = appURL(for: editor) else {
                errorMessage = L("%@ isn't installed on this Mac.", editor.name)
                return
            }
            openFileInApp(url, app)
        }
    }

    /// A host's file opens in a read-only editor tab (FR-ED16); a folder, or **New Tab Here**, opens a tab in that folder on
    /// the host. No app on this Mac is offered, and the remembered choice isn't changed.
    private func openRemoteFile(_ entry: FileEntry?, host: FilesHost, in editor: EditorApp) async {
        guard let entry = entry ?? files.root.map({ FileEntry(path: $0, isDirectory: true) }) else { return }
        if entry.isDirectory || editor == .newTab {
            let folder = entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent
            return await openTabForDirectory(folder.isEmpty ? "/" : folder, target: .host(host.id))
        }
        await openRemoteInEditor(hostID: host.id, path: entry.path, projectRoot: files.root)
    }

    /// A double click on a file: code opens in an editor tab whatever app is remembered (FR-ED09), and isn't remembered;
    /// anything else, a link to a folder, and code the editor refuses (FR-ED02) open in the remembered app, as **Open in** does.
    public func openFileOnDoubleClick(_ entry: FileEntry) async {
        guard files.host == nil else { return await openFile(entry, in: .trellisEditor) }
        let path = entry.path
        guard files.editor != .trellisEditor, !entry.isDirectory, EditorLanguage.isCode(fileName: entry.name),
            await Task.detached(priority: .userInitiated, operation: { !Self.isFolder(path) }).value
        else { return await openFile(entry) }
        // The refusal names the default app; the remembered one opens instead, so it isn't shown.
        let message = errorMessage
        guard await !openInEditor(path: path, projectRoot: files.root) else { return }
        errorMessage = message
        await openFile(entry)
    }

    nonisolated static func isFolder(_ path: String) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
    }

    /// Opens a file or folder in an app the user picked; it isn't remembered.
    public func openFile(_ entry: FileEntry?, withApp app: URL) {
        guard files.host == nil, let path = entry?.path ?? files.root else { return }
        openFileInApp(URL(fileURLWithPath: path), app)
    }

    public func revealFile(_ entry: FileEntry) { if files.host == nil { revealFiles([URL(fileURLWithPath: entry.path)]) } }

    // MARK: Copy and insert (FR-FB06)

    public func copyFilePath(_ entry: FileEntry, style: FilePathStyle = .absolute) {
        let text: String
        switch style {
        case .absolute: text = entry.path
        case .relative: text = files.root.map { FileBrowser.relativePath(entry.path, root: $0) } ?? entry.path
        case .name: text = entry.name
        }
        copyToPasteboard(text)
        showFilesStatus(L("Copied %@", style == .absolute ? Self.abbreviatingHome(text, home: files.host?.home) : text))
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

    /// `home`: a host's home folder; nil for this Mac's.
    nonisolated static func abbreviatingHome(_ path: String, home: String? = nil) -> String {
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
