import AppKit
import Foundation
import TrellisCore

/// A request to move the cursor to a line (and column), 1-based; a new `id` repeats a jump to the same place.
public struct EditorJump: Equatable, Sendable {
    public let id: UUID
    public let line: Int
    public let column: Int?
    public init(line: Int, column: Int?) { id = UUID(); self.line = line; self.column = column }
}

/// A space's editor tab (FR-ED01): a text file being edited, never saved with the workspace (FR-ED08).
public struct EditorTab: Identifiable, Equatable, Sendable {
    public enum Banner: Equatable, Sendable {
        case changedOnDisk, deleted
        case saveFailed(String)
    }

    public let id: UUID
    public internal(set) var spaceID: UUID
    /// The file as last read or saved; its `text` is what is on disk.
    public internal(set) var document: EditorDocument
    /// The text being edited.
    public internal(set) var text: String
    public internal(set) var banner: Banner?
    public internal(set) var jump: EditorJump?
    /// The project the file was opened from, for the path shown in the header.
    public let projectRoot: String?

    public var isDirty: Bool { text != document.text }
    public var fileName: String { document.fileName }
    public var language: ScratchpadLanguage { document.language }
    /// The path below the project, else with `~` for the home folder.
    public var displayPath: String {
        if let projectRoot, document.path.hasPrefix(projectRoot + "/") { return String(document.path.dropFirst(projectRoot.count + 1)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return document.path.hasPrefix(home + "/") ? "~" + document.path.dropFirst(home.count) : document.path
    }
}

public enum UnsavedEditorsChoice: Sendable { case save, discard, cancel }

extension AppWorkspaceModel {
    // MARK: State

    /// The selected space's editor tabs, in tab-bar order.
    public var currentEditors: [EditorTab] { presentation.selectedSpace.flatMap { editorTabs[$0.id] } ?? [] }
    /// Every space's editor tabs, in a stable order, for keeping their views mounted.
    public var allEditorTabs: [EditorTab] { editorTabs.keys.sorted { $0.uuidString < $1.uuidString }.flatMap { editorTabs[$0] ?? [] } }
    /// The editor tab shown in place of the terminals, if any.
    public var shownEditor: EditorTab? {
        guard let spaceID = presentation.selectedSpace?.id, let id = shownEditors[spaceID] else { return nil }
        return editorTabs[spaceID]?.first { $0.id == id }
    }
    public var editorVisible: Bool { shownEditor != nil }

    func editorTab(_ id: UUID) -> EditorTab? {
        for tabs in editorTabs.values { if let tab = tabs.first(where: { $0.id == id }) { return tab } }
        return nil
    }

    private func updateEditor(_ id: UUID, _ change: (inout EditorTab) -> Void) {
        for (spaceID, tabs) in editorTabs {
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { continue }
            change(&editorTabs[spaceID]![index])
            return
        }
    }

    /// The name shown on an editor tab: its file name, with its folder when another open file of the space shares it.
    public func editorTitle(_ tab: EditorTab) -> String {
        let clash = (editorTabs[tab.spaceID] ?? []).contains { $0.id != tab.id && $0.fileName == tab.fileName }
        guard clash else { return tab.fileName }
        let folder = ((tab.document.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return "\(tab.fileName) — \(folder)"
    }

    // MARK: Opening (FR-ED01, FR-ED02)

    /// Opens `path` in an editor tab of the selected space, or shows the tab that has it, at `line`. Returns false when
    /// the file isn't text the editor can keep intact (FR-ED02), so the caller can hand it elsewhere; other failures
    /// are shown and return true.
    @discardableResult
    public func openInEditor(path rawPath: String, line: Int? = nil, column: Int? = nil, projectRoot: String? = nil) async -> Bool {
        guard let spaceID = presentation.selectedSpace?.id else { return true }
        // `a/./b` and `a/x/../b` name one file, so they share one tab.
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        let jump = line.map { EditorJump(line: $0, column: column) }
        if let open = editorTabs[spaceID]?.first(where: { $0.document.path == path }) {
            if let jump { updateEditor(open.id) { $0.jump = jump } }
            selectEditor(open.id)
            return true
        }
        let fs = editorFileSystem
        let loaded = await Task.detached(priority: .userInitiated) { EditorDocument.loadResult(path: path, fs: fs) }.value
        switch loaded {
        case .success(let document):
            // The space may have closed, or the file opened twice, while it was read.
            guard snapshot.spaces.contains(where: { $0.id == spaceID }) else { return true }
            if let open = editorTabs[spaceID]?.first(where: { $0.document.path == path }) {
                selectEditor(open.id)
                return true
            }
            let root = projectRoot ?? files.root
            let tab = EditorTab(id: UUID(), spaceID: spaceID, document: document, text: document.text, banner: nil, jump: jump, projectRoot: root)
            var tabs = editorTabs[spaceID] ?? []
            // After the shown editor tab, else after the others.
            let index = shownEditors[spaceID].flatMap { shown in tabs.firstIndex { $0.id == shown } }.map { $0 + 1 } ?? tabs.count
            tabs.insert(tab, at: index)
            editorTabs[spaceID] = tabs
            selectEditor(tab.id)
            return true
        case .failure(let error) where error.opensElsewhere:
            errorMessage = L("%1$@ opens in the default app. %2$@", (path as NSString).lastPathComponent, error.message)
            return false
        case .failure(let error):
            errorMessage = L("%1$@ can't be opened in Trellis. %2$@", (path as NSString).lastPathComponent, error.message)
            return true
        }
    }

    /// Opens a file from the Files view; anything the editor refuses goes to the default app under FR-L03.
    func openFileInEditor(_ entry: FileEntry) async {
        // A symbolic link to a folder is listed as a file; it is shown in Finder like the folder.
        if entry.isDirectory || isDirectory(entry.path) {
            revealFiles([URL(fileURLWithPath: entry.path, isDirectory: true)])
            return
        }
        guard await !openInEditor(path: entry.path, projectRoot: files.root) else { return }
        let message = errorMessage
        await openFile(entry, in: .defaultApp, remember: false)
        if errorMessage == nil { errorMessage = message }
    }

    /// Opens a terminal link in an editor tab (FR-ED07); false hands it back to the terminal's usual open.
    func openLinkInEditor(paneID: UUID, path: String, line: Int?, column: Int?) async -> Bool {
        guard let context = fileLinkContext(paneID: paneID), editorMayOpenLink(path, context: context) else { return false }
        if let tabID = snapshot.panes[paneID]?.tabID, let spaceID = snapshot.tabs[tabID]?.spaceID, presentation.selectedSpace?.id != spaceID { return false }
        return await openInEditor(path: path, line: line, column: column, projectRoot: context.projectRoot)
    }

    /// A link to a regular file inside the pane's project or current folder; a folder keeps FR-L02 (opens in Finder).
    func editorMayOpenLink(_ path: String, context: FileLinkContext) -> Bool {
        context.editorMayOpen(path) && editorFileSystem.isRegularFile(path)
    }

    private func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    // MARK: Showing

    public func selectEditor(_ id: UUID) {
        guard let tab = editorTab(id) else { return }
        reviewShownSpaces.remove(tab.spaceID)
        shownEditors[tab.spaceID] = id
        cancelPaste()
        editorFocusRequest += 1
        checkEditorOnDisk(id)
    }

    /// Back to the terminal tabs, keeping the editor tabs.
    public func hideEditor() {
        guard let spaceID = presentation.selectedSpace?.id, shownEditors[spaceID] != nil else { return }
        shownEditors[spaceID] = nil
        focusActiveTerminal()
    }

    public func focusEditor() { if editorVisible { editorFocusRequest += 1 } }

    /// Next and previous tab move through the space's tabs, then its editor tabs (FR-ED08).
    public func selectAdjacentTab(_ offset: Int) async {
        let tabs = presentation.visibleTabs.map(\.id), editors = currentEditors.map(\.id)
        let sequence = tabs + editors
        guard sequence.count > 1 else { return }
        let current = shownEditor?.id ?? presentation.selectedTab?.id
        guard let index = current.flatMap({ sequence.firstIndex(of: $0) }) else { return }
        let next = sequence[(index + offset + sequence.count) % sequence.count]
        if editors.contains(next) { selectEditor(next) } else { await selectTab(next) }
    }

    func updateEditorText(_ id: UUID, _ text: String) {
        guard editorTab(id)?.text != text else { return }
        updateEditor(id) { $0.text = text }
    }

    public func clearEditorJump(_ id: UUID) { updateEditor(id) { $0.jump = nil } }
    public func goToLine(_ id: UUID, line: Int) { updateEditor(id) { $0.jump = EditorJump(line: line, column: nil) } }

    // MARK: Disk (FR-ED06)

    /// Compares the file on disk with what the tab read: a clean tab reloads, an edited one shows a banner.
    public func checkEditorOnDisk(_ id: UUID) {
        guard let tab = editorTab(id) else { return }
        let fs = editorFileSystem, document = tab.document
        Task {
            let state = await Task.detached { document.diskState(fs: fs) }.value
            guard let current = editorTab(id), current.document == document else { return }
            switch state {
            case .unchanged:
                if current.banner == .deleted || current.banner == .changedOnDisk { updateEditor(id) { $0.banner = nil } }
            case .deleted: updateEditor(id) { $0.banner = .deleted }
            case .changed:
                if current.isDirty { updateEditor(id) { $0.banner = .changedOnDisk } } else { await reloadEditor(id) }
            }
        }
    }

    /// Checks every editor tab of the selected space, as when Trellis becomes active again.
    public func checkEditorsOnDisk() { for tab in currentEditors { checkEditorOnDisk(tab.id) } }

    /// Reads the file again, dropping unsaved changes.
    public func reloadEditor(_ id: UUID) async {
        guard let tab = editorTab(id) else { return }
        let fs = editorFileSystem, path = tab.document.path
        let loaded = await Task.detached { EditorDocument.loadResult(path: path, fs: fs) }.value
        // Typing (or a save) while the file was read wins: the read is dropped and the disk is checked again.
        guard let current = editorTab(id), current.text == tab.text, current.document == tab.document else {
            checkEditorOnDisk(id)
            return
        }
        switch loaded {
        case .success(let document):
            updateEditor(id) {
                $0.document = document; $0.text = document.text; $0.banner = nil
            }
        case .failure(let error): errorMessage = L("%1$@ can't be reloaded. %2$@", tab.fileName, error.message)
        }
    }

    /// Keep Mine: the tab's text stays, and the version now on disk becomes the one it knows, so saving won't ask again.
    public func keepEditorChanges(_ id: UUID) {
        guard let tab = editorTab(id) else { return }
        let stamp = editorFileSystem.stamp(tab.document.path)
        updateEditor(id) {
            $0.document.stamp = stamp; $0.banner = nil
        }
    }

    // MARK: Saving (FR-ED04)

    /// Saves the tab; false when it wasn't saved (cancelled or failed), with the tab's text and unsaved mark kept.
    @discardableResult
    public func saveEditor(_ id: UUID) async -> Bool {
        // One save at a time per tab: a second one waits, then saves what is newer, without a false "changed on disk".
        let previous = editorSaves[id]
        let save = Task {
            _ = await previous?.value
            return await performSave(id)
        }
        editorSaves[id] = save
        let saved = await save.value
        if editorSaves[id] == save { editorSaves[id] = nil }
        return saved
    }

    private func performSave(_ id: UUID) async -> Bool {
        guard let tab = editorTab(id) else { return false }
        let fs = editorFileSystem, document = tab.document, text = tab.text
        let state = await Task.detached { document.diskState(fs: fs) }.value
        if state == .changed, !confirmOverwriteChangedFile(tab.fileName) { return false }
        let saved = await Task.detached { document.savingResult(text, fs: fs) }.value
        switch saved {
        case .success(let document):
            updateEditor(id) {
                $0.document = document; $0.banner = nil
            }
            return true
        case .failure(let error):
            updateEditor(id) { $0.banner = .saveFailed(error.message) }
            return false
        }
    }

    public func saveShownEditor() async { if let id = shownEditor?.id { await saveEditor(id) } }

    // MARK: Closing (FR-ED05)

    /// Closes the tab, asking first when it has unsaved changes.
    public func closeEditor(_ id: UUID) async {
        guard let tab = editorTab(id) else { return }
        if tab.isDirty {
            switch confirmUnsavedEditors([tab.fileName]) {
            case .cancel: return
            // Typing while it saved makes it unsaved again: it stays open.
            case .save: guard await saveEditor(id), editorTab(id)?.isDirty == false else { return }
            case .discard: break
            }
        }
        removeEditor(id)
    }

    public func closeShownEditor() async { if let id = shownEditor?.id { await closeEditor(id) } }

    private func removeEditor(_ id: UUID) {
        guard let tab = editorTab(id), var tabs = editorTabs[tab.spaceID], let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        editorTabs[tab.spaceID] = tabs.isEmpty ? nil : tabs
        guard shownEditors[tab.spaceID] == id else { return }
        // The neighbor takes its place, else the terminals.
        if tabs.isEmpty {
            shownEditors[tab.spaceID] = nil
            focusActiveTerminal()
        } else {
            selectEditor(tabs[min(index, tabs.count - 1)].id)
        }
    }

    /// Asks about the unsaved editor tabs of `spaces` (nil: every space) before they close; Save saves them all.
    /// False cancels whatever was closing.
    func resolveUnsavedEditors(in spaces: Set<UUID>?) async -> Bool {
        let dirty = editorTabs.filter { spaces?.contains($0.key) ?? true }.values.flatMap { $0 }.filter(\.isDirty)
        guard !dirty.isEmpty else { return true }
        switch confirmUnsavedEditors(dirty.map(\.fileName).sorted()) {
        case .cancel: return false
        case .discard:
            // Their spaces' editor tabs may now go with them (see `pruneEditors`).
            if let spaces { discardedEditorSpaces.formUnion(spaces) }
            return true
        case .save:
            for tab in dirty { guard await saveEditor(tab.id) else { return false } }
            return !dirty.contains { editorTab($0.id)?.isDirty == true }
        }
    }

    public var hasUnsavedEditors: Bool { editorTabs.values.contains { $0.contains(where: \.isDirty) } }
    public var unsavedEditorNames: [String] { editorTabs.values.flatMap { $0 }.filter(\.isDirty).map(\.fileName).sorted() }

    /// Saves every unsaved editor tab, stopping at the first that fails (it shows why); true when all were saved.
    public func saveAllEditors() async -> Bool {
        for tab in editorTabs.values.flatMap({ $0 }) where tab.isDirty { guard await saveEditor(tab.id) else { return false } }
        return true
    }

    /// After a workspace change: a deleted space drops its editor tabs, and a space whose tab changed shows its terminals.
    /// A space closed without Trellis asking (by automation, FR-ED05) hands its unsaved editor tabs to the selected space
    /// instead, so nothing typed is lost; with no space left they stay for the quit question.
    func pruneEditors(previous: WorkspaceSnapshot, next: WorkspaceSnapshot) {
        var tabs: [UUID: UUID] = [:], before: [UUID: UUID] = [:]
        for space in next.spaces { tabs[space.id] = space.activeTabID }
        for space in previous.spaces { before[space.id] = space.activeTabID }
        for spaceID in Array(editorTabs.keys) where tabs[spaceID] == nil {
            let unsaved = discardedEditorSpaces.contains(spaceID) ? [] : (editorTabs[spaceID] ?? []).filter(\.isDirty)
            if unsaved.isEmpty {
                editorTabs[spaceID] = nil
            } else if let target = next.activeSpaceID, tabs[target] != nil {
                editorTabs[spaceID] = nil
                editorTabs[target, default: []] += unsaved.map { tab in
                    var moved = tab
                    moved.spaceID = target
                    return moved
                }
            }
        }
        for spaceID in Array(shownEditors.keys) where tabs[spaceID] == nil || tabs[spaceID] != before[spaceID] { shownEditors[spaceID] = nil }
    }

    // MARK: Alerts

    static func showUnsavedEditorsConfirmation(_ names: [String]) -> UnsavedEditorsChoice {
        let alert = NSAlert()
        if names.count == 1 {
            alert.messageText = L("Save changes to “%@” before closing?", names[0])
        } else {
            alert.messageText = L("Save changes to %d files before closing?", names.count)
            alert.informativeText = names.prefix(8).joined(separator: "\n") + (names.count > 8 ? "\n" + L("…and %d more", names.count - 8) : "") + "\n\n"
        }
        alert.informativeText += L("Your changes will be lost if you don't save them.")
        alert.addButton(withTitle: names.count == 1 ? L("Save") : L("Save All"))
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Don't Save"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    static func showOverwriteConfirmation(_ name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("“%@” changed on disk. Save over it?", name)
        alert.informativeText = L("The version on disk will be replaced by yours.")
        alert.addButton(withTitle: L("Save Anyway"))
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
