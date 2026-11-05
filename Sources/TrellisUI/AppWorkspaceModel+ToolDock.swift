import AppKit
import Combine
import Foundation
import TrellisCore

/// One tab's dock (FR-TD05). Memory only.
public struct ToolDockState: Equatable, Sendable {
    public var isOpen = false
    public var toolID = ToolDockTool.files.id
    /// Open files, as opened (not resolved), in tab order.
    public var openFiles: [String] = []
    public var activeFile: String?
    /// The line a `file:line` link opened each file at (FR-TD09).
    public var markedLines: [String: Int] = [:]
    public var revealRequest = 0
    /// A width the user dragged; nil uses the default for what the dock shows.
    public var width: Double?
    public var treeHidden = false
    public var filter = ""
    /// Expanded folders, as absolute paths.
    public var expanded: Set<String> = []
    /// A file that didn't open, and why (FR-TD10).
    public var openFailure: OpenFailure?
    public struct OpenFailure: Equatable, Sendable {
        public let path: String, message: String
    }
    public init() {}
}

/// What the Files tree shows for the focused pane (FR-TD06, FR-TD07).
public enum ToolDockContext: Equatable, Sendable {
    case project(root: String, paneTitle: String)
    /// Home or `/`: never shown as a root.
    case notAProject(paneTitle: String)
    case needsShellIntegration(paneTitle: String)
    case remote(host: String, paneTitle: String)
    case noPane

    public var root: String? { if case .project(let root, _) = self { root } else { nil } }
    public var isRemote: Bool { if case .remote = self { true } else { false } }
}

public enum UnsavedEditsChoice: Sendable { case save, discard, cancel }

/// An open file's buffer and what it was loaded from (FR-TD12–FR-TD14).
@MainActor
public final class EditorBuffer: ObservableObject, Identifiable {
    public enum Conflict: Equatable, Sendable {
        /// Changed on disk while the buffer had unsaved edits.
        case changedWhileEditing
        /// Save found the file changed since it was read or saved.
        case saveWouldOverwrite
    }
    public nonisolated var id: String { path }
    public nonisolated let path: String
    @Published public var text: String { didSet { dirtyMayHaveChanged() } }
    @Published public internal(set) var file: EditorFile { didSet { dirtyMayHaveChanged() } }
    @Published public internal(set) var conflict: Conflict?
    @Published public internal(set) var missingOnDisk = false
    /// A failed save's reason, until the next edit or save.
    @Published public internal(set) var message: String?
    /// What the file holds as this buffer last read or wrote it. Compared with `text`, not `file.text`: a CRLF file reads
    /// back with CRLF while typed lines hold LF, and reading it back must neither mark it Edited nor replace the text.
    public private(set) var savedText: String { didSet { dirtyMayHaveChanged() } }
    public var isDirty: Bool { text != savedText }
    public var name: String { (path as NSString).lastPathComponent }
    /// Called when `isDirty` flips: the rail and the tree watch the model, not each buffer, and mark Edited (FR-TD14).
    var dirtyChanged: () -> Void = {}
    private var wasDirty = false

    private func dirtyMayHaveChanged() {
        let dirty = isDirty
        if dirty != wasDirty { wasDirty = dirty; dirtyChanged() }
    }

    init(path: String, file: EditorFile) {
        self.path = path
        self.file = file
        savedText = file.text
        text = file.text
    }

    /// After a save: the text stays as typed, so undo and the selection survive.
    func markSaved(_ saved: EditorFile, text written: String) { file = saved; savedText = written }

    /// After a reload from disk: the file's text replaces the buffer.
    func load(_ file: EditorFile) { self.file = file; savedText = file.text; text = file.text }
}

/// Watches one file, re-arming after an atomic replace (a rename over the path) so later changes are still seen.
/// Events arrive on the main queue.
@MainActor
final class EditorFileWatch {
    // Cancelled from deinit, which isn't isolated; only ever touched on the main queue.
    nonisolated(unsafe) private var source: DispatchSourceFileSystemObject?
    private let path: String
    private let changed: @MainActor () -> Void

    init?(path: String, changed: @escaping @MainActor () -> Void) {
        self.path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        self.changed = changed
        guard arm() else { return nil }
    }

    deinit { source?.cancel() }

    @discardableResult private func arm() -> Bool {
        source?.cancel()
        let fd = open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { source = nil; return false }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.handle() } }
        source.setCancelHandler { _ = close(fd) }
        source.resume()
        self.source = source
        return true
    }

    private func handle() {
        let event = source?.data ?? []
        if event.contains(.delete) || event.contains(.rename) {
            // The path may now name a new file; watch that one once it appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in MainActor.assumeIsolated { _ = self?.arm() } }
        }
        changed()
    }
}

extension AppWorkspaceModel {
    // MARK: State

    public func toolDock(_ tabID: UUID) -> ToolDockState { toolDocks[tabID] ?? ToolDockState() }

    func updateToolDock(_ tabID: UUID, _ change: (inout ToolDockState) -> Void) {
        var state = toolDock(tabID)
        change(&state)
        if toolDocks[tabID] != state { toolDocks[tabID] = state }
    }

    public var selectedToolDock: ToolDockState { presentation.selectedTab.map { toolDock($0.id) } ?? ToolDockState() }

    public func buffer(_ tabID: UUID, _ path: String) -> EditorBuffer? { editorBuffers[tabID]?[path] }

    /// Opens or closes the dock with `tool` in the selected tab (FR-TD01): its rail button again closes it.
    public func toggleToolDock(_ tool: ToolDockTool = .files) {
        guard let tabID = presentation.selectedTab?.id else { return }
        let state = toolDock(tabID)
        let closing = state.isOpen && state.toolID == tool.id
        updateToolDock(tabID) {
            $0.isOpen = !closing; $0.toolID = tool.id
        }
        if closing { focusActiveTerminal() } else { toolDockFocusRequest &+= 1 }
    }

    public func closeToolDock() {
        guard let tabID = presentation.selectedTab?.id else { return }
        updateToolDock(tabID) { $0.isOpen = false }
        focusActiveTerminal()
    }

    /// ⇄: the other side, for every tab and window, saved with the settings (FR-TD02).
    public func moveToolDockToOtherSide() {
        var settings = appearance
        settings.toolDockSide = settings.toolDockSide.other
        _ = applyAppearance(settings)
    }

    public func setToolDockWidth(_ width: Double?, tabID: UUID) { updateToolDock(tabID) { $0.width = width } }
    public func setToolDockTreeHidden(_ hidden: Bool, tabID: UUID) { updateToolDock(tabID) { $0.treeHidden = hidden } }
    public func setToolDockFilter(_ filter: String, tabID: UUID) { updateToolDock(tabID) { $0.filter = filter } }
    public func toggleToolDockFolder(_ path: String, tabID: UUID) {
        updateToolDock(tabID) { if $0.expanded.contains(path) { $0.expanded.remove(path) } else { $0.expanded.insert(path) } }
    }

    // MARK: Following focus (FR-TD06, FR-TD07)

    public func toolDockContext(_ tabID: UUID) -> ToolDockContext {
        guard let paneID = snapshot.tabs[tabID]?.activePaneID, let pane = snapshot.panes[paneID] else { return .noPane }
        let title = paneTitle(paneID)
        let launch = snapshot.sessions[pane.sessionID]?.launch
        if launch.map(Self.isRemote) == true || isRemoteWorkspace(paneID: paneID) {
            let name = paneContext(paneID).machine.name
            return .remote(host: name == PaneMachine.ssh.name ? "the SSH host" : name, paneTitle: title)
        }
        guard let directory = currentDirectory(paneID: paneID) else { return .needsShellIntegration(paneTitle: title) }
        switch ToolDockRoot.resolve(directory: directory, home: NSHomeDirectory(), exists: { FileManager.default.fileExists(atPath: $0) }) {
        case .project(let root): return .project(root: root, paneTitle: title)
        case .notAProject: return .notAProject(paneTitle: title)
        }
    }

    // MARK: Files (FR-TD09, FR-TD10)

    /// Opens `path` in `tabID`'s dock, or the selected tab's, at `line` when given. False when it can't open; the
    /// dock then shows why, with Open in Default App.
    @discardableResult
    public func openFileInToolDock(_ path: String, line: Int? = nil, tabID: UUID? = nil) -> Bool {
        guard let tabID = tabID ?? presentation.selectedTab?.id else { return false }
        if editorBuffers[tabID]?[path] == nil {
            switch EditorFile.open(path) {
            case .failure(let error):
                updateToolDock(tabID) {
                    $0.isOpen = true; $0.toolID = ToolDockTool.files.id; $0.openFailure = .init(path: path, message: error.message)
                }
                return false
            case .success(let file):
                let buffer = EditorBuffer(path: path, file: file)
                buffer.dirtyChanged = { [weak self] in self?.objectWillChange.send() }
                editorBuffers[tabID, default: [:]][path] = buffer
                if let watch = editorFileWatcher(path, { [weak self] in self?.checkFileOnDisk(path, tabID: tabID) }) {
                    editorWatches[tabID, default: [:]][path] = watch
                }
            }
        }
        updateToolDock(tabID) { state in
            state.isOpen = true
            state.toolID = ToolDockTool.files.id
            state.openFailure = nil
            if !state.openFiles.contains(path) { state.openFiles.append(path) }
            state.activeFile = path
            if let line { state.markedLines[path] = line; state.revealRequest &+= 1 } else { state.markedLines[path] = nil }
        }
        toolDockFocusRequest &+= 1
        return true
    }

    /// A ⌘-clicked file link (FR-TD09): a text file opens in the dock of the pane's tab, at its line, and the pane is
    /// focused; anything the editor can't open, or every file with the Default app setting, goes to the default app.
    func openLinkedFile(_ path: String, line: Int?, paneID: UUID) -> Bool {
        guard appearance.fileLinkTarget == .toolDock, let tabID = snapshot.panes[paneID]?.tabID, case .success = EditorFile.open(path) else { return false }
        if snapshot.tabs[tabID]?.activePaneID != paneID { Task { _ = await selectPane(paneID) } }
        return openFileInToolDock(path, line: line, tabID: tabID)
    }

    public func selectFile(_ path: String, tabID: UUID) { updateToolDock(tabID) { $0.activeFile = path } }

    public func dismissOpenFailure(tabID: UUID) { updateToolDock(tabID) { $0.openFailure = nil } }

    /// What Open in Default App does with a file the editor refused (FR-TD10): FR-L03 and FR-L04 still apply, so an
    /// executable or app is only revealed and a network path is left alone.
    nonisolated static func defaultAppAction(for path: String, probe: FileProbe = .live) -> FileLinkAction? {
        let root = URL(fileURLWithPath: path).standardized.path.split(separator: "/").first?.lowercased()
        guard root != "net", root != "network" else { return nil }
        return FileLinkPolicy.action(path: path, probe: probe)
    }

    public func openRefusedFileInDefaultApp(tabID: UUID) {
        guard let failure = toolDock(tabID).openFailure else { return }
        dismissOpenFailure(tabID: tabID)
        switch Self.defaultAppAction(for: failure.path) {
        case .open(let url): NSWorkspace.shared.open(url)
        case .reveal(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case nil: break
        }
    }

    /// Closes a file tab; unsaved edits ask first (FR-TD14). False when cancelled or a save failed.
    @discardableResult
    public func closeFile(_ path: String, tabID: UUID) -> Bool {
        guard let buffer = buffer(tabID, path) else { return true }
        guard confirmDiscarding([buffer]) else { return false }
        removeFile(path, tabID: tabID)
        return true
    }

    func removeFile(_ path: String, tabID: UUID) {
        editorBuffers[tabID]?[path] = nil
        editorWatches[tabID]?[path] = nil
        updateToolDock(tabID) { state in
            let index = state.openFiles.firstIndex(of: path) ?? 0
            state.openFiles.removeAll { $0 == path }
            state.markedLines[path] = nil
            if state.activeFile == path { state.activeFile = state.openFiles.isEmpty ? nil : state.openFiles[max(0, min(index, state.openFiles.count) - 1)] }
        }
    }

    // MARK: Saving and changes on disk (FR-TD12, FR-TD13)

    /// Saves the buffer. A file changed on disk since it was read is never overwritten unless `overwrite`; the
    /// buffer then asks (Overwrite, Reload, Cancel).
    @discardableResult
    public func saveFile(_ path: String, tabID: UUID, overwrite: Bool = false) -> Bool {
        guard let buffer = buffer(tabID, path) else { return false }
        switch buffer.file.save(buffer.text, overwrite: overwrite) {
        case .success(let saved):
            buffer.markSaved(saved, text: buffer.text)
            (buffer.conflict, buffer.missingOnDisk, buffer.message) = (nil, false, nil)
            // An atomic save replaces the inode; watch the new file.
            if let watch = editorFileWatcher(path, { [weak self] in self?.checkFileOnDisk(path, tabID: tabID) }) { editorWatches[tabID, default: [:]][path] = watch }
            return true
        case .failure(.changedOnDisk):
            buffer.conflict = .saveWouldOverwrite
            return false
        case .failure(let error):
            buffer.message = error.message
            return false
        }
    }

    /// Replaces the buffer with the file on disk, dropping unsaved edits.
    public func reloadFile(_ path: String, tabID: UUID) {
        guard let buffer = buffer(tabID, path) else { return }
        switch EditorFile.open(path) {
        case .success(let file):
            buffer.load(file)
            (buffer.conflict, buffer.missingOnDisk, buffer.message) = (nil, false, nil)
        case .failure(let error):
            buffer.message = error.message
        }
    }

    /// Keeps the edits; the next save still asks before overwriting the change on disk.
    public func keepEdits(_ path: String, tabID: UUID) { buffer(tabID, path)?.conflict = nil }

    func checkFileOnDisk(_ path: String, tabID: UUID) {
        guard let buffer = buffer(tabID, path) else { return }
        guard let current = buffer.file.currentFingerprint() else { buffer.missingOnDisk = true; return }
        buffer.missingOnDisk = false
        guard current != buffer.file.fingerprint else { return }
        if buffer.isDirty { buffer.conflict = .changedWhileEditing } else { reloadFile(path, tabID: tabID) }
    }

    // MARK: Unsaved edits (FR-TD14)

    func dirtyBuffers(tabs: [UUID]) -> [EditorBuffer] {
        tabs.flatMap { tabID in toolDock(tabID).openFiles.compactMap { editorBuffers[tabID]?[$0] } }.filter(\.isDirty)
    }

    /// Asks once for `buffers` with unsaved edits: Save saves them all (any failure keeps everything open), Don't
    /// Save drops them, Cancel keeps them. True when it's safe to go on.
    func confirmDiscarding(_ buffers: [EditorBuffer]) -> Bool {
        let dirty = buffers.filter(\.isDirty)
        guard !dirty.isEmpty else { return true }
        switch confirmUnsavedEdits(dirty.map(\.name)) {
        case .cancel: return false
        case .discard: return true
        case .save:
            for buffer in dirty {
                guard let tabID = editorBuffers.first(where: { $0.value[buffer.path] === buffer })?.key, saveFile(buffer.path, tabID: tabID) else { return false }
            }
            return true
        }
    }

    /// Before closing tabs or windows, or quitting.
    func confirmClosingEdits(tabs: [UUID]) -> Bool { confirmDiscarding(dirtyBuffers(tabs: tabs)) }

    // MARK: Insert Path (FR-TD15)

    /// Why Insert Path is disabled for the selected tab's focused pane; nil when it can type.
    public var insertPathBlockedReason: String? {
        guard let paneID = presentation.selectedTab?.activePaneID else { return "No pane is focused." }
        if case .remote(let host, _)? = presentation.selectedTab.map({ toolDockContext($0.id) }) { return "The focused pane is on \(host); this path is on this Mac." }
        guard currentDirectory(paneID: paneID) != nil else { return TaskRunAvailability.noIntegration.reason }
        return taskAvailability(paneID: paneID).reason
    }

    /// Types `path` at the focused pane's prompt, quoted, with a space and no Return: relative when it's inside the
    /// pane's directory, else absolute with `~` for home.
    @discardableResult
    public func insertPath(_ path: String) -> Bool {
        guard insertPathBlockedReason == nil, let paneID = presentation.selectedTab?.activePaneID, let terminal = terminals[paneID],
            let directory = currentDirectory(paneID: paneID)
        else { return false }
        // Quoting doesn't neutralize a control character: typed, a name's Ctrl-U or Return would edit or run the line.
        guard !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            errorMessage = "This path has control characters, so it isn't typed at the prompt."
            return false
        }
        let text = Self.insertedPath(path, directory: directory, home: NSHomeDirectory())
        do { try terminal.adapter.send(Data((text + " ").utf8)) } catch {
            errorMessage = "The path could not be typed. The session may have stopped."
            return false
        }
        return true
    }

    nonisolated static func insertedPath(_ path: String, directory: String, home: String) -> String {
        let directory = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        if path.hasPrefix(directory + "/") { return AgentCommand.quote(String(path.dropFirst(directory.count + 1))) }
        if path.hasPrefix(home + "/") { return "~/" + AgentCommand.quote(String(path.dropFirst(home.count + 1))) }
        return AgentCommand.quote(path)
    }
}
