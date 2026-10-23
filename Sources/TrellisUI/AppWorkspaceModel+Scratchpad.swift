import AppKit
import Foundation
import TrellisControl
import TrellisCore

/// The command scratchpad (FR-SP01–FR-SP08): write a script beside the panes, check it, run it in the focused pane or
/// save it as a project task.
extension AppWorkspaceModel {
    /// The pane Run types into: the focused one.
    public var scratchpadPaneID: UUID? { presentation.activePane?.id }

    /// Private state, not the project, so trying a script never changes the repository.
    var scratchpadRunDirectory: URL {
        scratchpadDirectory ?? (persistence?.directory ?? FileManager.default.temporaryDirectory).appendingPathComponent("scratch", isDirectory: true)
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
        guard let paneID = scratchpadPaneID else { return false }
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
        if let issue = document.issues.first {
            errorMessage = issue.message
            return nil
        }
        if let problem = LaunchFile.taskNameProblem(name) {
            errorMessage = problem
            return nil
        }
        guard let paneID = scratchpadPaneID else { return nil }
        await refreshTaskCatalog(paneID: paneID)
        guard let catalog = taskCatalog, catalog.paneID == paneID else {
            errorMessage = "Save as Task needs a project: a local pane in a folder with .git or .trellis."
            return nil
        }
        let root = URL(fileURLWithPath: catalog.root, isDirectory: true)
        let folder = root.appendingPathComponent(ScratchpadDocument.projectDirectory, isDirectory: true)
        let url = folder.appendingPathComponent(document.fileName)
        let manager = FileManager.default
        // Through a symbolic link the script could land outside the project.
        let linked = [root.appendingPathComponent(ProjectFile.directoryName), folder, url].contains { (try? manager.destinationOfSymbolicLink(atPath: $0.path)) != nil }
        guard !linked else {
            errorMessage = "\(url.path) or one of its folders is a symbolic link, so nothing was saved."
            return nil
        }
        // Only a file this scratchpad saved, and can read back for restoring, is replaced.
        let exists = manager.fileExists(atPath: url.path)
        let previous = exists && scratchpadSavedPaths.contains(url.path) ? try? Data(contentsOf: url) : nil
        guard !exists || previous != nil else {
            errorMessage = "\(ScratchpadDocument.projectDirectory)/\(document.fileName) already exists. Rename the script to save it."
            return nil
        }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(document.text.utf8).write(to: url, options: .atomic)
            // A repository file, like launch.json.
            try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        } catch {
            errorMessage = "\(url.path) could not be written. Check the folder's permissions and try again."
            return nil
        }
        guard let task = await addTask(LaunchTask(name: name, command: document.taskCommand, group: group)) else {
            if let previous { try? previous.write(to: url, options: .atomic) } else { try? manager.removeItem(at: url) }
            return nil
        }
        scratchpadSavedPaths.insert(url.path)
        // Keep any edit made while saving; it shows as unsaved.
        if scratchpad.text == document.text, scratchpad.language == document.language { scratchpad.name = document.name }
        scratchpadSaved = document
        return task
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
