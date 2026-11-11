import Foundation
import TrellisBroker
import TrellisCore

/// What reading a folder's repository found (FR-GC02).
public enum GitChangesRead: Equatable, Sendable {
    case notRepository
    case failed
    case loaded(GitChangeList)
}

/// Git for the Changes view (FR-GC03, FR-GC06); injected by tests. Every call blocks, so the model runs them off the main thread.
public struct GitChangesClient: Sendable {
    public var list: @Sendable (_ directory: String) -> GitChangesRead
    public var diff: @Sendable (_ root: String, _ file: GitChangedFile, _ hasCommits: Bool) -> GitFileDiff?
    /// Stages (`true`) or unstages the whole file; false when git failed.
    public var stage: @Sendable (_ root: String, _ file: GitChangedFile, _ stage: Bool, _ hasCommits: Bool) -> Bool

    public init(
        list: @escaping @Sendable (String) -> GitChangesRead, diff: @escaping @Sendable (String, GitChangedFile, Bool) -> GitFileDiff?,
        stage: @escaping @Sendable (String, GitChangedFile, Bool, Bool) -> Bool
    ) {
        self.list = list; self.diff = diff; self.stage = stage
    }

    /// Git on this Mac, through `BrokerGit.capture`: a fixed argument list, no shell, hooks, fsmonitor, filters, external diff
    /// and text conversion off, literal pathspecs.
    public static let local = GitChangesClient(
        list: { LocalGitChanges.list($0, environment: ProcessInfo.processInfo.environment) },
        diff: { LocalGitChanges.diff(root: $0, file: $1, hasCommits: $2, environment: ProcessInfo.processInfo.environment) },
        stage: { LocalGitChanges.stage(root: $0, file: $1, stage: $2, hasCommits: $3, environment: ProcessInfo.processInfo.environment) }
    )
}

public enum LocalGitChanges {
    public static let timeout: Int32 = 5000

    public static func list(_ directory: String, environment: [String: String], timeout: Int32 = timeout) -> GitChangesRead {
        guard let top = BrokerGit.capture(["rev-parse", "--show-toplevel"], directory: directory, environment: environment, timeout: timeout, limit: 65536) else { return .failed }
        let root = top.output.trimmingCharacters(in: .newlines)
        guard top.exit == 0, root.hasPrefix("/") else { return .notRepository }
        guard
            let status = BrokerGit.capture(
                ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all", "--no-renames", "--ignore-submodules=dirty"], directory: root, environment: environment,
                timeout: timeout,
                limit: 8 * 1024 * 1024),
            status.exit == 0
        else { return .failed }
        var list = GitChanges.parseStatus(status.output, root: root, complete: !status.full)
        let base = list.hasCommits ? "HEAD" : GitChanges.emptyTree
        if let counts = BrokerGit.capture(
            ["diff", "--numstat", "-z", "--no-renames", "--no-ext-diff", "--no-textconv", "--ignore-submodules=dirty", base, "--"], directory: root, environment: environment, timeout: timeout,
            limit: 8 * 1024 * 1024), counts.exit == 0, !counts.full
        {
            list = GitChanges.applying(GitChanges.parseNumstat(counts.output), to: list)
        }
        for index in list.files.indices where list.files[index].kind == .untracked {
            let count = untrackedLineCount(root + "/" + list.files[index].path)
            list.files[index].added = count.lines; list.files[index].removed = 0; list.files[index].binary = count.binary
            if count.binary { list.files[index].removed = nil }
        }
        return .loaded(list)
    }

    /// A new regular file's lines, read only up to the limit; a link counts as one line, as git shows its target.
    static func untrackedLineCount(_ path: String) -> (lines: Int?, binary: Bool) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), let type = attributes[.type] as? FileAttributeType else { return (nil, false) }
        if type == .typeSymbolicLink { return (1, false) }
        guard type == .typeRegular, let size = attributes[.size] as? Int, size <= GitChanges.countByteLimit,
            let handle = FileHandle(forReadingAtPath: path)
        else { return (nil, false) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: GitChanges.countByteLimit) else { return (nil, false) }
        let lines = GitChanges.lineCount(data)
        return (lines, lines == nil)
    }

    public static func diff(root: String, file: GitChangedFile, hasCommits: Bool, environment: [String: String], timeout: Int32 = timeout) -> GitFileDiff? {
        let words =
            file.kind == .untracked
            ? ["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--", "/dev/null", file.path]
            : ["diff", "--no-renames", "--no-ext-diff", "--no-textconv", "--no-color", "--ignore-submodules=dirty", hasCommits ? "HEAD" : GitChanges.emptyTree, "--", file.path]
        guard let result = BrokerGit.capture(words, directory: root, environment: environment, timeout: timeout, limit: GitChanges.diffByteLimit + 1) else { return nil }
        // `--no-index` exits 1 when the files differ, which a new file always does.
        guard result.exit == 0 || (file.kind == .untracked && result.exit == 1) else { return nil }
        return result.full ? GitFileDiff(body: .tooLarge) : GitChanges.parseDiff(result.output)
    }

    public static func stage(root: String, file: GitChangedFile, stage: Bool, hasCommits: Bool, environment: [String: String], timeout: Int32 = timeout) -> Bool {
        let words: [String]
        if stage {
            // `add` of a path that is gone stages its deletion. The repository's filters run, as for `git add` in a shell.
            words = ["add", "--", file.path]
        } else if hasCommits {
            words = ["restore", "--staged", "--", file.path]
        } else {
            words = ["rm", "--cached", "-q", "-f", "--", file.path]
        }
        return BrokerGit.capture(words, directory: root, environment: environment, timeout: timeout, limit: 65536, filters: stage)?.exit == 0
    }
}

/// What the Changes view shows (FR-GC02–FR-GC04). Runtime only: nothing here is saved with the workspace.
public struct GitChangesState: Equatable, Sendable {
    public enum Load: Equatable, Sendable {
        case idle
        case loading
        /// The folder that isn't in a repository.
        case noRepository(String)
        case failed
        case loaded(GitChangeList)
    }

    public internal(set) var paneID: UUID?
    public internal(set) var load: Load = .idle
    public internal(set) var filter = ""
    /// The selected file's path.
    public internal(set) var selection: String?
    /// A short confirmation or failure, cleared after a moment.
    public internal(set) var status: String?
    /// Files being staged or unstaged.
    public internal(set) var staging: Set<String> = []
    /// Each repository's folded folders, for the session only.
    var collapsedByRoot: [String: Set<String>] = [:]

    public init() {}

    public var list: GitChangeList? { if case .loaded(let list) = load { list } else { nil } }
    public var collapsed: Set<String> { list.flatMap { collapsedByRoot[$0.root] } ?? [] }
    public var rows: [GitChangeRow] { list.map { GitChanges.rows($0.files, collapsed: collapsed, filter: filter) } ?? [] }
    public var selectedFile: GitChangedFile? { selection.flatMap { path in list?.files.first { $0.path == path } } }
}

/// A space's Review tab (FR-GC05): one file's diff, never saved.
public struct ReviewTab: Equatable, Sendable {
    public internal(set) var root: String
    public internal(set) var file: GitChangedFile
    public internal(set) var hasCommits: Bool
    /// Nil while loading.
    public internal(set) var diff: GitFileDiff?
    public internal(set) var failed = false

    public var absolutePath: String { root + "/" + file.path }
}

extension AppWorkspaceModel {
    // MARK: Reading (FR-GC02, FR-GC03)

    /// Reads the focused pane's repository again; a newer read supersedes this one.
    public func refreshGitChanges(paneID: UUID) async {
        gitChangesGeneration &+= 1
        let generation = gitChangesGeneration
        if files.editors.isEmpty { loadEditorChoices() }
        // A late call for a pane no longer focused (staging that finished after a focus change) leaves the view alone.
        guard presentation.activePane?.id == paneID else { return }
        guard sidebarUnavailableReason(.changes) == nil, let directory = paneDirectory(paneID) else {
            gitChanges.paneID = paneID; gitChanges.load = .idle
            return
        }
        if gitChanges.paneID != paneID || gitChanges.list == nil { gitChanges.load = .loading }
        gitChanges.paneID = paneID
        let client = gitChangesClient
        let read = await Task.detached(priority: .userInitiated) { client.list(directory) }.value
        guard generation == gitChangesGeneration, gitChanges.paneID == paneID else { return }
        switch read {
        case .notRepository: gitChanges.load = .noRepository(directory)
        case .failed: gitChanges.load = .failed
        case .loaded(let list):
            gitChanges.load = .loaded(list)
            if let selection = gitChanges.selection, !list.files.contains(where: { $0.path == selection }) { gitChanges.selection = nil }
            await refreshReviews(with: list, generation: generation)
        }
    }

    /// A prompt may follow a command that changed files (FR-GC03).
    func refreshGitChangesAtPrompt(paneID: UUID) {
        guard visibleSidebarView == .changes, presentation.activePane?.id == paneID else { return }
        Task { await refreshGitChanges(paneID: paneID) }
    }

    /// Review tabs on this repository take the file's new state and diff; a file no longer changed says so.
    private func refreshReviews(with list: GitChangeList, generation: Int) async {
        for spaceID in Array(reviewTabs.keys) {
            // Each diff is awaited: a newer refresh takes over, and a tab closed or replaced meanwhile isn't brought back.
            guard generation == gitChangesGeneration else { return }
            guard let review = reviewTabs[spaceID], review.root == list.root else { continue }
            guard let file = list.files.first(where: { $0.path == review.file.path }) else {
                // A cut list may just not reach the file.
                if !list.truncated { reviewTabs[spaceID]?.diff = GitFileDiff(body: .unchanged) }
                continue
            }
            guard file != review.file || review.hasCommits != list.hasCommits else { continue }
            await loadReview(spaceID: spaceID, root: list.root, file: file, hasCommits: list.hasCommits, keepShown: true)
        }
    }

    // MARK: Filter, folds, selection (FR-GC04)

    public func setGitChangesFilter(_ text: String) {
        gitChanges.filter = text
        if let selection = gitChanges.selection, !gitChanges.rows.contains(where: { $0.file?.path == selection }) { gitChanges.selection = nil }
    }

    public func toggleGitChangesFolder(_ path: String) {
        guard let root = gitChanges.list?.root else { return }
        var collapsed = gitChanges.collapsedByRoot[root] ?? []
        if collapsed.remove(path) == nil { collapsed.insert(path) }
        gitChanges.collapsedByRoot[root] = collapsed
    }

    public func collapseAllGitChanges() {
        guard let list = gitChanges.list else { return }
        gitChanges.collapsedByRoot[list.root] = GitChanges.folderPaths(list.files)
    }

    public func selectGitChange(_ path: String?) { gitChanges.selection = path }

    /// ↑ and ↓ through the visible files.
    public func moveGitChangesSelection(by offset: Int) {
        let paths = gitChanges.rows.compactMap { $0.file?.path }
        guard !paths.isEmpty else { return }
        guard let current = gitChanges.selection.flatMap({ paths.firstIndex(of: $0) }) else {
            gitChanges.selection = offset > 0 ? paths.first : paths.last
            return
        }
        gitChanges.selection = paths[min(max(current + offset, 0), paths.count - 1)]
    }

    // MARK: Review tab (FR-GC05)

    /// The selected space's Review tab.
    public var currentReview: ReviewTab? { presentation.selectedSpace.flatMap { reviewTabs[$0.id] } }
    /// Whether the selected space shows its Review tab in place of the terminals.
    public var reviewVisible: Bool { presentation.selectedSpace.map { reviewShownSpaces.contains($0.id) && reviewTabs[$0.id] != nil } ?? false }

    /// Opens the file's diff in the selected space's Review tab, replacing what it showed.
    public func reviewGitChange(_ path: String) async {
        guard let list = gitChanges.list, let file = list.files.first(where: { $0.path == path }), let spaceID = presentation.selectedSpace?.id else { return }
        gitChanges.selection = path
        await loadReview(spaceID: spaceID, root: list.root, file: file, hasCommits: list.hasCommits, keepShown: false)
    }

    private func loadReview(spaceID: UUID, root: String, file: GitChangedFile, hasCommits: Bool, keepShown: Bool) async {
        reviewTabs[spaceID] = ReviewTab(root: root, file: file, hasCommits: hasCommits, diff: nil)
        if !keepShown {
            reviewShownSpaces.insert(spaceID)
            cancelPaste()
        }
        let client = gitChangesClient
        let diff = await Task.detached(priority: .userInitiated) { client.diff(root, file, hasCommits) }.value
        guard let current = reviewTabs[spaceID], current.root == root, current.file == file else { return }
        reviewTabs[spaceID]?.diff = diff
        reviewTabs[spaceID]?.failed = diff == nil
    }

    /// The actions that act on the focused pane: while the Review tab hides the terminals they show them first (FR-GC05).
    public static let reviewRevealingActions: Set<ShortcutAction> = [
        .findInPane, .findNext, .findPrevious, .previousPrompt, .nextPrompt, .clearPane, .splitLeftRight, .splitTopBottom, .maximizePane,
        .focusLeft, .focusRight, .focusUp, .focusDown, .resizeLeft, .resizeRight, .resizeUp, .resizeDown
    ]

    /// Before a pane action: shows the terminals when the Review tab hides them, so nothing acts on a pane out of sight.
    public func revealTerminalsForPaneAction(_ action: ShortcutAction) {
        guard reviewVisible, Self.reviewRevealingActions.contains(action) else { return }
        hideReview()
    }

    /// After a workspace change: a deleted space drops its Review tab, and a space whose tab changed (new, closed, selected
    /// by automation) shows its terminals again (FR-GC05). Kept out of `publish` and in plain loops: Swift 6.3 miscompiled
    /// the closure-based form inline there (a task-allocator abort in unrelated async tests).
    func pruneReviews(previous: WorkspaceSnapshot, next: WorkspaceSnapshot) {
        var tabs: [UUID: UUID] = [:], before: [UUID: UUID] = [:]
        for space in next.spaces { tabs[space.id] = space.activeTabID }
        for space in previous.spaces { before[space.id] = space.activeTabID }
        for spaceID in Array(reviewTabs.keys) where tabs[spaceID] == nil { reviewTabs[spaceID] = nil }
        for spaceID in Array(reviewShownSpaces) where tabs[spaceID] == nil || tabs[spaceID] != before[spaceID] { reviewShownSpaces.remove(spaceID) }
    }

    /// Shows the selected space's Review tab again.
    public func showReview() {
        guard let spaceID = presentation.selectedSpace?.id, reviewTabs[spaceID] != nil else { return }
        reviewShownSpaces.insert(spaceID)
    }

    /// Back to the terminal tabs, keeping the Review tab.
    public func hideReview() {
        guard let spaceID = presentation.selectedSpace?.id else { return }
        reviewShownSpaces.remove(spaceID)
        focusActiveTerminal()
    }

    public func closeReview() {
        guard let spaceID = presentation.selectedSpace?.id else { return }
        reviewTabs[spaceID] = nil
        reviewShownSpaces.remove(spaceID)
        focusActiveTerminal()
    }

    /// The Review tab's file's place in the list ("12 of 17"); nil when the list is another repository's.
    public var reviewPosition: (index: Int, count: Int)? {
        guard let review = currentReview, let list = gitChanges.list, list.root == review.root else { return nil }
        let ordered = list.orderedFiles
        return ordered.firstIndex { $0.path == review.file.path }.map { ($0 + 1, ordered.count) }
    }

    /// `]` and `[`: the next or previous file in the tree's order.
    public func reviewAdjacentFile(_ offset: Int) async {
        guard let review = currentReview, let list = gitChanges.list, list.root == review.root else { return }
        let ordered = list.orderedFiles
        guard let index = ordered.firstIndex(where: { $0.path == review.file.path }), ordered.indices.contains(index + offset) else { return }
        await reviewGitChange(ordered[index + offset].path)
    }

    /// Reads the Review tab's diff again, with the list.
    public func reloadReview() async {
        if let paneID = presentation.activePane?.id, visibleSidebarView == .changes || gitChanges.paneID == paneID { await refreshGitChanges(paneID: paneID) }
        guard let spaceID = presentation.selectedSpace?.id, let review = reviewTabs[spaceID] else { return }
        let file = gitChanges.list.flatMap { $0.root == review.root ? $0.files.first { $0.path == review.file.path } : nil }
        guard let file else {
            if let list = gitChanges.list, list.root == review.root, !list.truncated { reviewTabs[spaceID]?.diff = GitFileDiff(body: .unchanged) }
            return
        }
        await loadReview(spaceID: spaceID, root: review.root, file: file, hasCommits: review.hasCommits, keepShown: true)
    }

    // MARK: Staging (FR-GC06)

    /// Stages a file that isn't fully staged, or unstages one that is.
    public func toggleGitChangeStaged(_ path: String) async {
        guard let list = gitChanges.list, let file = list.files.first(where: { $0.path == path }), !gitChanges.staging.contains(path) else { return }
        let stage = file.staging != .full
        // `git add` on a conflicted file marks it resolved, markers and all, so that needs a yes (FR-GC06).
        if stage, file.kind == .conflicted, !confirmStageConflict(file.name) { return }
        gitChanges.staging.insert(path)
        let client = gitChangesClient, root = list.root, hasCommits = list.hasCommits
        let succeeded = await Task.detached(priority: .userInitiated) { client.stage(root, file, stage, hasCommits) }.value
        gitChanges.staging.remove(path)
        let name = file.name
        if succeeded {
            showGitChangesStatus(stage ? L("Staged %@", name) : L("Unstaged %@", name))
        } else {
            showGitChangesStatus(stage ? L("Couldn't stage %@; git reported an error.", name) : L("Couldn't unstage %@; git reported an error.", name))
        }
        if let paneID = presentation.activePane?.id { await refreshGitChanges(paneID: paneID) }
    }

    func showGitChangesStatus(_ text: String) {
        gitChanges.status = text
        gitChangesStatusTask?.cancel()
        gitChangesStatusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.gitChanges.status == text else { return }
            self.gitChanges.status = nil
        }
    }

    // MARK: Open and copy (FR-GC07)

    public func openGitChange(_ root: String, _ file: GitChangedFile) async {
        let path = root + "/" + file.path
        guard FileManager.default.fileExists(atPath: path) else {
            showGitChangesStatus(L("%@ was deleted; there's nothing to open.", file.name))
            return
        }
        await openFile(FileEntry(path: path, isDirectory: false))
    }

    public func copyGitChangePath(_ root: String, _ file: GitChangedFile, relative: Bool = false) {
        let text = relative ? file.path : root + "/" + file.path
        copyToPasteboard(text)
        showGitChangesStatus(L("Copied %@", relative ? text : Self.abbreviatingHome(text)))
    }
}
