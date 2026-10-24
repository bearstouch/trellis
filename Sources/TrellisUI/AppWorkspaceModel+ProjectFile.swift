import AppKit
import Foundation
import TrellisControl
import TrellisCore

/// A project file found at or above a pane's directory (FR-WF02).
public struct ProjectFileOffer: Equatable, Sendable {
    /// The canonical project folder (the parent of `.trellis`).
    public let root: String
    public let name: String
    /// The file that was found: `project.json`, or the legacy `workspace.json` (FR-WF07).
    public let path: String
}

/// A parsed file waiting for the user to review its commands (FR-WF03). Opening uses exactly these bytes'
/// contents, never a later read, so what was reviewed is what runs.
public struct ProjectFileReview: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let root: String
    public let file: ProjectFile
    public let digest: String
    /// Another version of this folder's file was trusted before.
    public let changedSinceTrusted: Bool
    public let warnings: [String]
    /// The file these bytes were read from.
    public let path: String
}

/// The window as a project file, edited as JSON before it is written (FR-WF06).
public struct ProjectFileDraft: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let windowID: UUID
    public let root: String
    /// The window as exported; `text` starts as its encoding.
    public let file: ProjectFile
    /// One per file tab: the live tab it is bound to.
    public let tabIDs: [UUID]
    public let paneIDs: [UUID]
    public let warnings: [String]
    public let replacesExisting: Bool
    /// The JSON the user edits; written byte for byte once it checks out.
    public var text: String
    public var path: String { ProjectFile.url(projectRoot: root).path }
}

/// A project file open for editing as JSON (FR-WF08), with the bytes it was read from.
public struct ProjectFileEdit: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// The canonical project folder.
    public let root: String
    /// The file that was read and is written back: `project.json`, or the legacy `workspace.json`.
    public let path: String
    public let original: Data
    public var text: String
}

/// What checking a draft's text found: errors block saving, warnings don't.
public struct ProjectFileCheck: Equatable, Sendable {
    public let errors: [String], warnings: [String]
    public var isValid: Bool { errors.isEmpty }
}

/// Folder pickers for project files; injected so tests never show a panel.
@MainActor
public enum ProjectFilePanels {
    public static func chooseFolder(message: String, directory: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.allowedContentTypes = [.json, .folder]
        panel.message = message
        panel.prompt = "Choose"
        if let directory { panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return projectRoot(forSelection: url.path)
    }

    /// The project folder for a chosen folder, `.trellis` folder, or `project.json` (or legacy `workspace.json`) file.
    public static func projectRoot(forSelection path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        if [ProjectFile.fileName, ProjectFile.legacyFileName].contains(url.lastPathComponent),
            url.deletingLastPathComponent().lastPathComponent == ProjectFile.directoryName
        {
            url = url.deletingLastPathComponent()
        }
        if url.lastPathComponent == ProjectFile.directoryName { url = url.deletingLastPathComponent() }
        return url.path
    }
}

extension AppWorkspaceModel {
    /// API namespaces match the layout key pattern, which has no `:`, so these never collide with them. The prefix
    /// predates the rename to project files and is persisted with the bindings, so it stays.
    static func projectNamespace(_ root: String) -> String { "workspace-file:" + root }
    nonisolated static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    /// The file a project is read from. Existence doesn't follow symbolic links, so a linked `project.json` is
    /// picked and then refused rather than silently falling back to the legacy file.
    nonisolated static func projectFileURL(_ root: String) -> URL? {
        ProjectFile.existingURL(projectRoot: root) { (try? FileManager.default.attributesOfItem(atPath: $0)) != nil }
    }

    // MARK: Detection (FR-WF02)

    /// Looks for a project file above a local shell's new directory, off the main actor; a newer directory wins.
    func detectProjectFile(paneID: UUID, directory: String) {
        guard projectFileLookups[paneID] != directory else { return }
        pruneProjectFileState()
        projectFileLookups[paneID] = directory
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        Task { [weak self] in
            let offer = await Task.detached(priority: .utility) { () -> ProjectFileOffer? in
                guard let found = ProjectFileLocator.projectRoot(containing: directory, home: home, fileExists: { FileManager.default.fileExists(atPath: $0) })
                else { return nil }
                let root = Self.canonical(found)
                // Only a regular file the user owns is offered (a shared folder such as /tmp could hold anyone's); a file
                // that doesn't parse is still offered, so opening it explains why.
                guard let url = Self.projectFileURL(root), let data = try? OwnerOnlyFile.read(url, limit: ProjectFile.maximumBytes) else { return nil }
                let name = try? ProjectFileJSON.parse(data).get().name
                return ProjectFileOffer(root: root, name: name ?? URL(fileURLWithPath: root).lastPathComponent, path: url.path)
            }.value
            guard let self, self.projectFileLookups[paneID] == directory else { return }
            if self.projectFileOffers[paneID] != offer { self.projectFileOffers[paneID] = offer }
        }
    }

    /// The offer a tab shows: its active pane's, else any pane's. Never for the project's own window or a
    /// folder the user declined.
    public func projectFileOffer(tabID: UUID) -> ProjectFileOffer? {
        guard let tab = snapshot.tabs[tabID] else { return nil }
        let candidates = [tab.activePaneID] + tab.root.paneIDs.filter { $0 != tab.activePaneID }
        guard let offer = candidates.lazy.compactMap({ self.projectFileOffers[$0] }).first else { return nil }
        if (try? projectTrustList())?.isIgnored(offer.root) == true { return nil }
        if (try? layoutBindings(Self.projectNamespace(offer.root)))?[ProjectFile.windowKey]?.id == tab.windowID { return nil }
        return offer
    }

    public func stopOfferingProjectFile(root: String) {
        do {
            var list = try projectTrustList()
            list.setIgnored(root, true)
            try saveProjectTrust(list)
            objectWillChange.send()
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Trust (FR-WF03)

    private var projectTrustURL: URL? { persistence?.directory.appendingPathComponent("workspace-trust.json") }

    /// An unreadable trust file fails closed: nothing is trusted and it is never overwritten.
    func projectTrustList() throws -> ProjectTrustList {
        if let projectTrust { return projectTrust }
        let list = try Self.readTrustList(projectTrustURL, failure: "Trusted project files could not be read, so project file commands can't run.")
        projectTrust = list
        return list
    }

    private func saveProjectTrust(_ list: ProjectTrustList) throws {
        try Self.writeTrustList(list, to: projectTrustURL, failure: "Trusted project files could not be saved.")
        projectTrust = list
    }

    /// A stored trust list, or an empty one when there is none. Unreadable, invalid or newer lists throw `failure`:
    /// rewriting a newer one would drop what this version doesn't know.
    static func readTrustList(_ url: URL?, failure: String) throws -> ProjectTrustList {
        do {
            let stored = try url.flatMap { try OwnerOnlyFile.read($0, limit: 4_194_304) }
            let list = try stored.map { try JSONDecoder().decode(ProjectTrustList.self, from: $0) } ?? ProjectTrustList()
            guard list.version == ProjectTrustList().version else { throw ProjectFileFailure(failure) }
            return list
        } catch { throw ProjectFileFailure(failure) }
    }

    static func writeTrustList(_ list: ProjectTrustList, to url: URL?, failure: String) throws {
        guard let url else { return }
        do { try OwnerOnlyFile.publish(try JSONEncoder().encode(list), to: url) } catch { throw ProjectFileFailure(failure) }
    }

    // MARK: Opening (FR-WF04)

    /// Reads and checks a project's file, then opens it at once when it has no commands or this exact version
    /// is trusted; otherwise it waits for review in `pendingProjectReview`.
    public func loadProjectFile(root: String) async {
        guard projectFileCanOpen() else { return }
        let root = Self.canonical(root)
        let data: Data
        guard let url = Self.projectFileURL(root) else {
            errorMessage = "There is no \(ProjectFile.directoryName)/\(ProjectFile.fileName) in \(root)."
            return
        }
        do {
            guard let read = try OwnerOnlyFile.read(url, limit: ProjectFile.maximumBytes) else {
                errorMessage = "There is no \(ProjectFile.directoryName)/\(ProjectFile.fileName) in \(root)."
                return
            }
            data = read
        } catch {
            errorMessage = "\(ProjectFile.directoryName)/\(url.lastPathComponent) must be a regular file you own, at most 256 KB, and not a symbolic link."
            return
        }
        let file: ProjectFile
        switch ProjectFileJSON.parse(data) {
        case .success(let parsed): file = parsed
        case .failure(let error):
            errorMessage = "The project file can't be opened: " + error.text
            return
        }
        let plan: LayoutPlan
        do { plan = try planProjectFile(file, root: root) } catch {
            errorMessage = error.localizedDescription
            return
        }
        let digest = ProjectTrustList.digest(data)
        let trust = try? projectTrustList()
        let review = ProjectFileReview(
            root: root, file: file, digest: digest, changedSinceTrusted: trust?.trustedOtherVersion(root: root, digest: digest) ?? false,
            warnings: plan.warnings.map(\.message), path: url.path)
        guard file.hasCommands, trust?.isTrusted(root: root, digest: digest) != true else {
            await openReviewedProjectFile(review, runCommands: file.hasCommands)
            return
        }
        pendingProjectReview = review
    }

    public enum ProjectReviewDecision: Sendable { case cancel, openWithoutCommands, trustAndOpen }

    /// A project opens only into a usable workspace: not while it is restoring or showing recovery.
    private func projectFileCanOpen() -> Bool {
        guard isRestoring || recoveryMessage != nil || shuttingDown else { return true }
        errorMessage = "The workspace isn't available yet, so the project wasn't opened. Try again once it has loaded."
        return false
    }

    public func resolveProjectReview(_ id: UUID, _ decision: ProjectReviewDecision) async {
        guard let review = pendingProjectReview, review.id == id else { return }
        pendingProjectReview = nil
        switch decision {
        case .cancel: return
        case .openWithoutCommands: await openReviewedProjectFile(review, runCommands: false)
        case .trustAndOpen:
            // Trust is recorded only when the window can open now; a later open would run the commands unreviewed.
            guard projectFileCanOpen() else { return }
            do {
                var list = try projectTrustList()
                list.trust(root: review.root, digest: review.digest)
                try saveProjectTrust(list)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            await openReviewedProjectFile(review, runCommands: true)
        }
    }

    private func planProjectFile(_ file: ProjectFile, root: String) throws -> LayoutPlan {
        let bindings: [String: LayoutBinding]
        do { bindings = try layoutBindings(Self.projectNamespace(root)) } catch {
            throw ProjectFileFailure("Saved layout bindings could not be read, so the project file can't be opened.")
        }
        let plan = LayoutPlanner.plan(
            file.resolve(projectRoot: root).layout, bindings: bindings, snapshot: snapshot, home: FileManager.default.homeDirectoryForCurrentUser.path,
            hostExists: { _ in false },
            directoryExists: { path in
                var isDirectory: ObjCBool = false; return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }, keepLiveLaunches: true, keepOmittedPanes: true)
        guard plan.canApply else {
            throw ProjectFileFailure(
                "The project file can't be opened: " + (plan.errors + plan.conflicts).map(\.text).joined(separator: " "))
        }
        return plan
    }

    /// Creates or reconciles the project's window, starts only the panes this open created, and queues their
    /// commands when allowed. Reopening never restarts a pane or runs a command again.
    @discardableResult
    func openReviewedProjectFile(_ review: ProjectFileReview, runCommands: Bool) async -> UUID? {
        let namespace = Self.projectNamespace(review.root)
        let resolved = review.file.resolve(projectRoot: review.root)
        let plan: LayoutPlan
        do { plan = try planProjectFile(review.file, root: review.root) } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        do { _ = try await automationApplyLayout(plan, namespace: namespace) } catch {
            errorMessage = "The workspace changed or is busy, so the project file wasn't opened. Try again."
            return nil
        }
        guard let windowID = plan.bindings[ProjectFile.windowKey]?.id else { return nil }
        pruneProjectFileState()
        for (key, paneID) in plan.createdPanes {
            if let command = resolved.commands[key] {
                projectFileCommands[paneID] = command
                if runCommands, let sessionID = snapshot.panes[paneID]?.sessionID { pendingProjectCommands[sessionID] = command }
            }
        }
        await selectWindow(windowID)
        for (_, paneID) in plan.createdPanes {
            let sessionID = snapshot.panes[paneID]?.sessionID
            try? await automationStartSession(paneID, launch: nil, environment: [:])
            // A start that was refused or skipped (restoring, closing, shutting down) drops the command, so a later
            // manual start never types it (FR-WF05).
            if let sessionID, ![.starting, .running].contains(snapshot.sessions[sessionID]?.state) { pendingProjectCommands.removeValue(forKey: sessionID) }
            // Without integration there is no prompt mark to wait for; the PTY holds the command until the shell reads it.
            if !shellGetsIntegration { submitProjectCommand(paneID: paneID) }
        }
        return windowID
    }

    /// Drops state for closed panes and sessions. Kept out of `publish`: pruning there makes Swift 6.3.3 (Xcode 26.6)
    /// emit code that corrupts the task allocator in later async calls ("freed pointer was not the last allocation").
    func pruneProjectFileState() {
        let panes = snapshot.panes, sessions = snapshot.sessions
        pendingProjectCommands = pendingProjectCommands.filter { sessions[$0.key] != nil }
        projectFileCommands = projectFileCommands.filter { panes[$0.key] != nil }
        projectFileLookups = projectFileLookups.filter { panes[$0.key] != nil }
        if projectFileOffers.keys.contains(where: { panes[$0] == nil }) { projectFileOffers = projectFileOffers.filter { panes[$0.key] != nil } }
        if taskRuns.keys.contains(where: { panes[$0] == nil }) { taskRuns = taskRuns.filter { panes[$0.key] != nil } }
    }

    // MARK: Commands (FR-WF05)

    /// Whether a new local shell pane gets integration, and so reports its first prompt (FR-SI01).
    var shellGetsIntegration: Bool {
        shellIntegrationEnabled && shellIntegrationDirectory != nil && ShellIntegrationKind(executable: defaultShell) != nil
    }

    /// Types a queued command into its shell, once; it is dropped if the shell is no longer running.
    func submitProjectCommand(paneID: UUID) {
        guard let terminal = terminals[paneID], let command = pendingProjectCommands.removeValue(forKey: terminal.sessionID),
            terminal.sessionState == .running
        else { return }
        try? terminal.adapter.send(Data((command + "\r").utf8))
    }

    // MARK: Saving (FR-WF06)

    /// Asks for the project folder and prepares the window's file for review in `pendingProjectSave`.
    public func beginSaveProjectFile(windowID: UUID) {
        guard let window = snapshot.windows.first(where: { $0.id == windowID }) else { return }
        let active = snapshot.tabs[window.activeTabID].flatMap { paneDirectory($0.activePaneID) }
        let suggestion = active.map { directory in
            ProjectFileLocator.projectRoot(containing: directory, home: FileManager.default.homeDirectoryForCurrentUser.path) {
                FileManager.default.fileExists(atPath: $0)
            } ?? directory
        }
        guard let root = chooseProjectFolder("Choose the project folder. The layout is saved to .trellis/project.json inside it.", suggestion) else { return }
        do { pendingProjectSave = try projectFileDraft(windowID: windowID, root: root) } catch { errorMessage = error.localizedDescription }
    }

    /// Asks for a project folder or project file and opens it.
    public func beginOpenProjectFile() async {
        let directory = presentation.activePane.flatMap { paneDirectory($0.id) }
        guard let root = chooseProjectFolder("Choose a project folder with a .trellis/project.json, or the file itself.", directory) else { return }
        await loadProjectFile(root: root)
    }

    /// A pane's current local directory, else the folder it was started in.
    func paneDirectory(_ paneID: UUID) -> String? {
        if let directory = currentDirectory(paneID: paneID) { return directory }
        switch snapshot.panes[paneID].flatMap({ snapshot.sessions[$0.sessionID] })?.launch {
        case .shell(let directory)?: return directory
        case .process(_, let arguments, let directory)? where arguments == ["-l"]: return directory
        default: return nil
        }
    }

    /// `paneDirectory` as seen from a canonical project root: a shell's `$PWD` keeps the logical path it was reached by,
    /// so it is resolved, unless it is already inside the root (a linked folder in the project stays where it is).
    func projectPaneDirectory(_ paneID: UUID, root: String) -> String? {
        guard let path = paneDirectory(paneID) else { return nil }
        let logical = URL(fileURLWithPath: path).standardizedFileURL.path
        return logical == root || logical.hasPrefix(root + "/") ? logical : Self.canonical(path)
    }

    /// A shell's directory for comparing with a task's folder under a canonical root, by the same rule.
    func taskCurrentDirectory(paneID: UUID, directory: String) -> String? {
        guard let path = currentDirectory(paneID: paneID) else { return nil }
        let logical = URL(fileURLWithPath: path).standardizedFileURL.path
        return logical == URL(fileURLWithPath: directory).standardizedFileURL.path ? logical : Self.canonical(path)
    }

    public func projectFileDraft(windowID: UUID, root: String) throws -> ProjectFileDraft {
        let root = Self.canonical(root)
        guard let window = snapshot.windows.first(where: { $0.id == windowID }) else { throw ProjectFileFailure("The window no longer exists.") }
        let url = ProjectFile.url(projectRoot: root)
        // Keys and commands the current file (or the legacy one, when it's the only one) carry over to the panes they are bound to.
        let existing = Self.projectFileURL(root).flatMap { try? OwnerOnlyFile.read($0, limit: ProjectFile.maximumBytes) }.flatMap { try? ProjectFileJSON.parse($0).get() }
        // The legacy file is never deleted: it is the user's repository file, so they remove it themselves.
        let legacy = FileManager.default.fileExists(atPath: ProjectFile.legacyURL(projectRoot: root).path)
        let legacyWarning =
            "Trellis now reads \(ProjectFile.directoryName)/\(ProjectFile.fileName). \(ProjectFile.directoryName)/\(ProjectFile.legacyFileName) is no longer used once this is saved; remove it from the project."
        let bindings = (try? layoutBindings(Self.projectNamespace(root))) ?? [:]
        var keys: [UUID: String] = [:], commands: [UUID: String] = [:]
        if let existing {
            let declared = Set(existing.tabs.compactMap(\.key) + existing.entries.compactMap(\.pane.key))
            for (key, binding) in bindings where declared.contains(key) { keys[binding.id] = key }
            for entry in existing.entries { if let command = entry.pane.command, let id = bindings[entry.key]?.id { commands[id] = command } }
        }
        var exported = ProjectFile.export(
            window: window, snapshot: snapshot, projectRoot: root, directory: { self.projectPaneDirectory($0, root: root) }, command: { self.projectFileCommands[$0] ?? commands[$0] },
            key: { keys[$0] })
        exported.file.schema = existing?.schema
        guard !exported.file.tabs.isEmpty else {
            throw ProjectFileFailure("No pane is in \(root), so there is nothing to save. cd into the project in a pane first.")
        }
        return ProjectFileDraft(
            windowID: windowID, root: root, file: exported.file, tabIDs: exported.tabIDs, paneIDs: exported.paneIDs, warnings: exported.warnings + (legacy ? [legacyWarning] : []),
            replacesExisting: FileManager.default.fileExists(atPath: url.path), text: String(decoding: ProjectFileJSON.encode(exported.file), as: UTF8.self))
    }

    /// Checks the draft's text with the same strict parse, keys and limits as `loadProjectFile`.
    public func checkProjectFile(_ draft: ProjectFileDraft) -> ProjectFileCheck { checkedProjectFile(draft).check }

    /// Whether saving would replace a file, asked when Save is pressed rather than when the sheet opened.
    public func projectFileExists(_ draft: ProjectFileDraft) -> Bool { FileManager.default.fileExists(atPath: draft.path) }

    /// The parsed file, and the bindings that make the draft's window the project's window when the edited layout
    /// still has the window's shape.
    private func checkedProjectFile(_ draft: ProjectFileDraft) -> (check: ProjectFileCheck, file: ProjectFile?, bindings: [String: LayoutBinding]?) {
        let parsed = Self.parsedProjectText(draft.text, root: draft.root)
        guard let file = parsed.file else { return (ProjectFileCheck(errors: parsed.errors, warnings: []), nil, nil) }
        let bindings = snapshot.windows.first { $0.id == draft.windowID }.flatMap {
            file.bindings(window: $0, tabIDs: draft.tabIDs, paneIDs: draft.paneIDs, snapshot: snapshot)
        }
        let unbound = "The tabs or splits no longer match this window, so opening the file creates a new window instead of using this one."
        return (ProjectFileCheck(errors: [], warnings: bindings == nil ? [unbound] : []), file, bindings)
    }

    public func cancelProjectSave() { pendingProjectSave = nil; errorMessage = nil }

    /// Project file text parsed with the same strict rules, keys and limits as `loadProjectFile`; nil with the problems.
    nonisolated static func parsedProjectText(_ text: String, root: String) -> (file: ProjectFile?, errors: [String]) {
        func describe(_ issue: LayoutIssue) -> String { issue.key.map { "\($0): \(issue.text)" } ?? issue.text }
        let file: ProjectFile
        switch ProjectFileJSON.parse(Data(text.utf8)) {
        case .failure(let error): return (nil, error.issues.map(describe))
        case .success(let parsed): file = parsed
        }
        let issues =
            file.issues.isEmpty
            ? LayoutPlanner.plan(
                file.resolve(projectRoot: root).layout, bindings: [:], snapshot: WorkspaceSnapshot(), home: "/", hostExists: { _ in false },
                directoryExists: { _ in true }
            ).errors : file.issues
        return issues.isEmpty ? (file, []) : (nil, issues.map(describe))
    }

    // MARK: Editing (FR-WF08)

    /// Opens the project file found for the pane's directory in the JSON editor.
    public func beginEditProjectFile(paneID: UUID) {
        guard let offer = projectFileOffers[paneID] else { return }
        let url = URL(fileURLWithPath: offer.path)
        guard let data = try? OwnerOnlyFile.read(url, limit: ProjectFile.maximumBytes) else {
            errorMessage = "\(offer.path) could not be read. It must be a regular file you own, at most 256 KB."
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            errorMessage = "\(offer.path) isn't UTF-8 text, so it can't be edited here."
            return
        }
        pendingProjectEdit = ProjectFileEdit(root: offer.root, path: offer.path, original: data, text: text)
    }

    public func cancelProjectEdit() { pendingProjectEdit = nil; errorMessage = nil }

    /// While a project file sheet is open it shows `errorMessage` itself.
    public var showsProjectSheet: Bool { pendingProjectSave != nil || pendingProjectEdit != nil }

    public func checkProjectFileEdit(_ edit: ProjectFileEdit) -> ProjectFileCheck {
        ProjectFileCheck(errors: Self.parsedProjectText(edit.text, root: edit.root).errors, warnings: [])
    }

    /// Whether the file on disk is no longer what the editor opened, so saving would replace someone else's change.
    /// Read like opening (no links, FIFOs or oversized files, which could hang or flood the main thread); anything that
    /// can't be read that way counts as changed.
    public func projectFileEditChangedOnDisk(_ edit: ProjectFileEdit) -> Bool {
        (try? OwnerOnlyFile.read(URL(fileURLWithPath: edit.path), limit: ProjectFile.maximumBytes)) != edit.original
    }

    /// Writes the edited text byte for byte. The new bytes are trusted only when the opened version was trusted or ran
    /// nothing, so editing a file whose commands were never reviewed can't skip the review (FR-WF03).
    @discardableResult
    public func writeProjectFileEdit(_ edit: ProjectFileEdit) -> Bool {
        let parsed = Self.parsedProjectText(edit.text, root: edit.root)
        guard let file = parsed.file else {
            errorMessage = "The project file can't be saved: " + (parsed.errors.first ?? "it isn't valid.")
            return false
        }
        let list = try? projectTrustList()
        let openedWithoutCommands = (try? ProjectFileJSON.parse(edit.original).get()).map { !$0.hasCommands } ?? false
        let keepsTrust = openedWithoutCommands || list?.isTrusted(root: edit.root, digest: ProjectTrustList.digest(edit.original)) == true
        let data = Data(edit.text.utf8)
        guard writeRepositoryFile(data, to: URL(fileURLWithPath: edit.path)) else { return false }
        if keepsTrust, file.hasCommands, var list {
            list.trust(root: edit.root, digest: ProjectTrustList.digest(data))
            try? saveProjectTrust(list)
        }
        for (paneID, offer) in projectFileOffers where offer.path == edit.path {
            projectFileOffers[paneID] = ProjectFileOffer(root: offer.root, name: file.name, path: offer.path)
        }
        pendingProjectEdit = nil
        return true
    }

    /// Writes a `.trellis/` repository file, not Trellis state: readable by the project's tools like any other source
    /// file. A linked `.trellis` folder or file is refused, since it could point the write outside the project.
    func writeRepositoryFile(_ data: Data, to url: URL) -> Bool {
        let manager = FileManager.default
        guard ![url.deletingLastPathComponent(), url].contains(where: { (try? manager.destinationOfSymbolicLink(atPath: $0.path)) != nil }) else {
            errorMessage = "\(url.path) or its folder is a symbolic link, so nothing was written."
            return false
        }
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            return true
        } catch {
            errorMessage = "\(url.path) could not be written. Check the folder's permissions and try again."
            return false
        }
    }

    /// Writes the edited text byte for byte, trusts those bytes and, when the layout still fits the window, makes it
    /// the project's window. A failure leaves the file, trust and bindings as they were.
    @discardableResult
    public func writeProjectFile(_ draft: ProjectFileDraft) -> Bool {
        let checked = checkedProjectFile(draft)
        guard let file = checked.file else {
            errorMessage = "The project file can't be saved: " + (checked.check.errors.first ?? "it isn't valid.")
            return false
        }
        guard !layoutApplyInFlight else {
            errorMessage = "A layout is being applied. Nothing was written; try again."
            return false
        }
        guard let window = snapshot.windows.first(where: { $0.id == draft.windowID }),
            case let current = ProjectFile.export(
                window: window, snapshot: snapshot, projectRoot: draft.root, directory: { self.projectPaneDirectory($0, root: draft.root) }, command: { _ in nil }),
            current.tabIDs == draft.tabIDs, current.paneIDs == draft.paneIDs,
            // The same panes regrouped while the sheet was open would otherwise read as an edit that unbinds the window.
            draft.file.bindings(window: window, tabIDs: draft.tabIDs, paneIDs: draft.paneIDs, snapshot: snapshot) != nil
        else {
            errorMessage = "The window changed while saving. Nothing was written; try again."
            return false
        }
        let data = Data(draft.text.utf8)
        guard writeRepositoryFile(data, to: ProjectFile.url(projectRoot: draft.root)) else { return false }
        // The user wrote these commands, so this version is trusted; failures here only mean a later review.
        if var list = try? projectTrustList() {
            list.trust(root: draft.root, digest: ProjectTrustList.digest(data))
            try? saveProjectTrust(list)
        }
        // A layout that no longer fits the window unbinds it, so the old bindings can't half-match the new file.
        if (try? layoutBindings(Self.projectNamespace(draft.root))) != nil { try? saveLayoutBindings(Self.projectNamespace(draft.root), checked.bindings ?? [:]) }
        // Unbound panes no longer belong to the file, so a later save mustn't prefill the old file's commands into them.
        if checked.bindings != nil {
            for (entry, paneID) in zip(file.entries, draft.paneIDs) { projectFileCommands[paneID] = entry.pane.command }
        } else {
            for paneID in draft.paneIDs { projectFileCommands.removeValue(forKey: paneID) }
        }
        pruneProjectFileState()
        pendingProjectSave = nil
        return true
    }
}

struct ProjectFileFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
