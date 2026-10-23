import AppKit
import Foundation
import TrellisControl
import TrellisCore

/// A project's saved scratchpads, by file name.
public struct ScratchpadFileList: Equatable, Sendable {
    /// The canonical project folder.
    public let root: String
    public let files: [String]
    public var projectName: String { URL(fileURLWithPath: root).lastPathComponent }
}

/// The command scratchpad (FR-SP01–FR-SP10): write a script beside the panes, check it, run it in the focused pane or
/// save it as a project task.
/// The scratchpad's buffer (FR-SP01), observed by its panel alone.
@MainActor
public final class ScratchpadBuffer: ObservableObject {
    @Published public internal(set) var document = ScratchpadDocument()
}

extension AppWorkspaceModel {
    /// The pane Run types into: the focused one.
    public var scratchpadPaneID: UUID? { presentation.activePane?.id }

    /// Private state, not the project, so trying a script never changes the repository.
    var scratchpadRunDirectory: URL {
        scratchpadDirectory ?? (persistence?.directory ?? FileManager.default.temporaryDirectory).appendingPathComponent("scratch", isDirectory: true)
    }

    /// Run's copies are deleted at quit and, after a crash, at the next launch: the shell reads one after Run returns, so
    /// it can't go sooner. A running script keeps its open file. Only the state directory's folder, never a shared one.
    public func removeScratchpadRunFiles() {
        guard scratchpadDirectory != nil || persistence != nil else { return }
        try? FileManager.default.removeItem(at: scratchpadRunDirectory)
    }

    /// Shows or hides the panel. From a pane's button it focuses that pane first; the panel stays open when the
    /// button belongs to another pane than the focused one.
    public func toggleScratchpad(paneID: UUID? = nil) async {
        if let paneID, paneID != presentation.activePane?.id {
            guard await selectPane(paneID) else { return }
            scratchpadVisible = true
        } else {
            scratchpadVisible.toggle()
        }
        if scratchpadVisible {
            scratchpadFocusRequest &+= 1
        } else if let terminal = activeTerminal {
            DispatchQueue.main.async { terminal.view.window?.makeFirstResponder(terminal.view) }
        }
    }

    public func setScratchpadLanguage(_ language: ScratchpadLanguage) { scratchpad.language = language }

    /// Why Run can't type into the focused pane now; nil when it can (FR-SP05).
    public var scratchpadRunBlocker: String? {
        guard let paneID = scratchpadPaneID else { return "Select a pane to run in." }
        if !scratchpad.language.isRunnable { return "\(scratchpad.language.displayName) isn't run." }
        if scratchpad.isEmpty { return "Write a command or script first." }
        if let reason = taskAvailability(paneID: paneID).reason { return reason }
        if scratchpadCheck?.outcome == .failed {
            let count = scratchpadCheck?.issues.count ?? 0
            return "Fix \(count == 1 ? "1 error" : "\(count) errors") to run."
        }
        return nil
    }

    /// Checks the buffer as it is now. A result for text that changed meanwhile is returned but not shown.
    @discardableResult
    public func validateScratchpad() async -> ScratchpadCheck {
        let document = scratchpad
        scratchpadChecking = true
        defer { scratchpadChecking = false }
        let check = await ScratchpadValidator.check(
            document, directory: scratchpadRunDirectory, searchPath: ScratchpadValidator.searchPath(environment: ProcessInfo.processInfo.environment),
            run: scratchpadProcessRunner)
        if scratchpad == document { scratchpadCheck = check }
        return check
    }

    /// Checks the buffer, writes it to the private scratch folder and types `<interpreter> '<file>'` into the focused
    /// pane, like a task. A failed check stops it; a check that couldn't run doesn't.
    @discardableResult
    public func runScratchpad() async -> Bool {
        guard let paneID = scratchpadPaneID, scratchpad.language.isRunnable else { return false }
        if let reason = taskAvailability(paneID: paneID).reason {
            errorMessage = reason
            return false
        }
        let document = scratchpad
        guard await validateScratchpad().outcome != .failed else { return false }
        let url = scratchpadRunDirectory.appendingPathComponent(document.fileName)
        do { try OwnerOnlyFile.publish(Data(document.text.utf8), to: url) } catch {
            errorMessage = "The script could not be written to \(url.path)."
            return false
        }
        let availability = taskAvailability(paneID: paneID)
        guard availability == .ready, let terminal = terminals[paneID], let shell = taskShell(paneID: paneID) else {
            errorMessage = availability.reason ?? TaskRunAvailability.noIntegration.reason
            return false
        }
        guard let line = document.runLine(path: url.path, kind: shell.kind) else {
            errorMessage = "The script's path can't be typed safely."
            return false
        }
        return sendTaskLine(line, to: terminal, paneID: paneID, taskID: "scratchpad:" + document.fileName, name: document.fileName)
    }

    /// Writes the buffer to `.trellis/scratch/<file>` in the focused pane's project and adds a task that runs it to
    /// launch.json (FR-SP06). If adding the task fails, the script file is put back as it was.
    @discardableResult
    public func saveScratchpadAsTask(name: String, scriptName: String? = nil, group: TaskGroup?) async -> LaunchTask? {
        var document = scratchpad
        if let scriptName { document.name = scriptName }
        guard let command = document.taskCommand else {
            errorMessage = "\(document.language.displayName) isn't run, so it can't be a task. Save it as a file instead."
            return nil
        }
        if let problem = LaunchFile.taskNameProblem(name) {
            errorMessage = problem
            return nil
        }
        guard let written = await writeScratchpadFile(document) else { return nil }
        // The catalog may have moved to another pane while saving; the task must go next to this script.
        let sameProject = taskCatalog?.root == written.root
        if !sameProject { errorMessage = "The project's tasks couldn't be read, so no task was added." }
        guard sameProject, let task = await addTask(LaunchTask(name: name, command: command, group: group)) else {
            if let previous = written.previous { try? previous.write(to: written.url, options: .atomic) } else { try? FileManager.default.removeItem(at: written.url) }
            // Folders made for this save go too, so a failed save doesn't turn the folder into a project.
            for folder in written.created.reversed() { rmdir(folder.path) }
            return nil
        }
        await finishScratchpadSave(document, url: written.url)
        scratchpadSavedTask = task
        return task
    }

    /// Saves text that isn't run, like Markdown notes, to `.trellis/scratch/<file>` without a task (FR-SP06).
    @discardableResult
    public func saveScratchpadFile(scriptName: String? = nil) async -> Bool {
        var document = scratchpad
        if let scriptName { document.name = scriptName }
        guard let written = await writeScratchpadFile(document) else { return false }
        await finishScratchpadSave(document, url: written.url)
        return true
    }

    /// Writes `document` into the focused pane's project; `previous` is the replaced content and `created` the folders
    /// made for it, for undoing the write.
    private func writeScratchpadFile(_ document: ScratchpadDocument) async -> (url: URL, root: String, previous: Data?, created: [URL])? {
        if let issue = document.issues.first {
            errorMessage = issue.message
            return nil
        }
        guard let paneID = scratchpadPaneID else { return nil }
        await refreshTaskCatalog(paneID: paneID)
        let rootPath: String
        if let catalog = taskCatalog, catalog.paneID == paneID {
            rootPath = catalog.root
        } else {
            // No project yet: the pane's folder becomes one once `.trellis` is created in it.
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            guard let pane = snapshot.panes[paneID], let launch = snapshot.sessions[pane.sessionID]?.launch, !Self.isRemote(launch),
                let directory = paneDirectory(paneID).map(Self.canonical), directory != "/", directory != Self.canonical(home)
            else {
                errorMessage = "Saving needs a local pane in a project folder. Your home folder and / can't hold a project; cd into a folder first."
                return nil
            }
            rootPath = directory
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let folder = root.appendingPathComponent(ScratchpadDocument.projectDirectory, isDirectory: true)
        let url = folder.appendingPathComponent(document.fileName)
        let manager = FileManager.default
        guard !Self.scratchpadPathIsLinked(root: root, file: url) else {
            errorMessage = "\(url.path) or one of its folders is a symbolic link, so nothing was saved."
            return nil
        }
        // Only a file this scratchpad saved or opened, and can read back for restoring, is replaced.
        let exists = manager.fileExists(atPath: url.path)
        let previous = exists && scratchpadSavedPaths.contains(url.path) ? (try? OwnerOnlyFile.read(url, limit: ScratchpadDocument.maximumBytes)) ?? nil : nil
        guard !exists || previous != nil else {
            errorMessage = "\(ScratchpadDocument.projectDirectory)/\(document.fileName) already exists. Rename the script to save it."
            return nil
        }
        let created = [root.appendingPathComponent(ProjectFile.directoryName), folder].filter { !manager.fileExists(atPath: $0.path) }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(document.text.utf8).write(to: url, options: .atomic)
            // A repository file, like launch.json.
            try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        } catch {
            for folder in created.reversed() { rmdir(folder.path) }
            errorMessage = "\(url.path) could not be written. Check the folder's permissions and try again."
            return nil
        }
        // A new `.trellis` made the folder a project; tasks are added to its launch.json.
        if taskCatalog?.root != rootPath { await refreshTaskCatalog(paneID: paneID) }
        return (url, rootPath, previous, created)
    }

    private func finishScratchpadSave(_ document: ScratchpadDocument, url: URL) async {
        scratchpadSavedPaths.insert(url.path)
        // Keep any edit made while saving; it shows as unsaved.
        if scratchpad.text == document.text, scratchpad.language == document.language { scratchpad.name = document.name }
        scratchpadSaved = document
        await refreshScratchpadFiles()
    }

    /// Through a symbolic link a script could be read from or written to outside the project.
    nonisolated static func scratchpadPathIsLinked(root: URL, file: URL? = nil) -> Bool {
        let folder = root.appendingPathComponent(ScratchpadDocument.projectDirectory, isDirectory: true)
        return ([root.appendingPathComponent(ProjectFile.directoryName), folder] + (file.map { [$0] } ?? [])).contains {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) != nil
        }
    }

    // MARK: Saved scratchpads (FR-SP10)

    /// Rereads the focused pane's project's `.trellis/scratch` off the main actor; nil when the pane has no project.
    public func refreshScratchpadFiles() async {
        guard let paneID = scratchpadPaneID, let pane = snapshot.panes[paneID], let launch = snapshot.sessions[pane.sessionID]?.launch, !Self.isRemote(launch),
            let directory = paneDirectory(paneID)
        else {
            scratchpadFiles = nil
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let list = await Task.detached(priority: .utility) { Self.loadScratchpadFiles(directory: directory, home: home) }.value
        if scratchpadPaneID == paneID, scratchpadFiles != list { scratchpadFiles = list }
    }

    nonisolated static func loadScratchpadFiles(directory: String, home: String) -> ScratchpadFileList? {
        let manager = FileManager.default
        guard let found = ProjectFileLocator.taskRoot(containing: directory, home: home, exists: { manager.fileExists(atPath: $0) }) else { return nil }
        let root = canonical(found)
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard !scratchpadPathIsLinked(root: rootURL) else { return ScratchpadFileList(root: root, files: []) }
        let folder = rootURL.appendingPathComponent(ScratchpadDocument.projectDirectory).path
        let files = ((try? manager.contentsOfDirectory(atPath: folder)) ?? []).filter { name in
            // attributesOfItem doesn't follow a final link, so links are skipped.
            ScratchpadDocument.isScriptFileName(name) && (try? manager.attributesOfItem(atPath: folder + "/" + name)[.type] as? FileAttributeType) == .typeRegular
        }
        return ScratchpadFileList(root: root, files: files.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    /// Loads a saved script into the buffer; it counts as saved, so Save may replace it. The view confirms first when
    /// the buffer has unsaved changes.
    @discardableResult
    public func openScratchpadFile(_ fileName: String) async -> Bool {
        guard let list = scratchpadFiles, ScratchpadDocument.isScriptFileName(fileName) else { return false }
        let root = URL(fileURLWithPath: list.root, isDirectory: true)
        let url = root.appendingPathComponent(ScratchpadDocument.projectDirectory).appendingPathComponent(fileName)
        let data: Data?
        do {
            guard !Self.scratchpadPathIsLinked(root: root) else { throw CocoaError(.fileReadNoPermission) }
            data = try OwnerOnlyFile.read(url, limit: ScratchpadDocument.maximumBytes)
        } catch {
            errorMessage = "\(fileName) must be a regular file you own, at most 64 KB, in a folder that isn't a symbolic link."
            return false
        }
        guard let data, let text = String(data: data, encoding: .utf8) else {
            errorMessage = data == nil ? "\(fileName) no longer exists." : "\(fileName) isn't UTF-8 text."
            await refreshScratchpadFiles()
            return false
        }
        let language = ScratchpadLanguage.detect(fileName: fileName, text: text) ?? .bash
        let document = ScratchpadDocument(name: (fileName as NSString).deletingPathExtension, language: language, text: text)
        scratchpad = document
        scratchpadSaved = document
        scratchpadCheck = nil
        scratchpadSavedPaths.insert(url.path)
        scratchpadFocusRequest &+= 1
        return true
    }

    /// The buffer has text that isn't in its saved script (FR-SP09).
    public var scratchpadHasUnsavedChanges: Bool {
        guard !scratchpad.isEmpty else { return false }
        return scratchpadSaved.map { $0.text != scratchpad.text || $0.language != scratchpad.language } ?? true
    }

    /// Starts a new, empty buffer in the same language. The saved script and its task stay; the view confirms first
    /// when there are unsaved changes.
    public func clearScratchpad() {
        scratchpad = ScratchpadDocument(language: scratchpad.language)
        scratchpadSaved = nil
        scratchpadCheck = nil
        scratchpadFocusRequest &+= 1
    }

    /// Saves, then runs the saved task, which asks for review first if launch.json isn't trusted (FR-TK06).
    public func saveScratchpadAndRun(name: String, scriptName: String? = nil, group: TaskGroup?) async {
        guard let task = await saveScratchpadAsTask(name: name, scriptName: scriptName, group: group) else { return }
        runTask(task, fromFile: true)
    }
}
