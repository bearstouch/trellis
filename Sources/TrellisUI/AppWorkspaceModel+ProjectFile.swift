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

/// The window as a project file, with editable commands, before it is written (FR-WF06).
public struct ProjectFileDraft: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let windowID: UUID
    public let root: String
    public let file: ProjectFile
    public let paneIDs: [UUID]
    public let warnings: [String]
    public let replacesExisting: Bool
    /// One per pane, in `file.entries` order.
    public var commands: [String]
    public var path: String { ProjectFile.url(projectRoot: root).path }
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
        do {
            let stored = try projectTrustURL.flatMap { try OwnerOnlyFile.read($0, limit: 4_194_304) }
            let list = try stored.map { try JSONDecoder().decode(ProjectTrustList.self, from: $0) } ?? ProjectTrustList()
            // A newer format is unreadable too: rewriting it would drop what this version doesn't know.
            guard list.version == ProjectTrustList().version else { throw ProjectFileFailure("") }
            projectTrust = list
            return list
        } catch { throw ProjectFileFailure("Trusted project files could not be read, so project file commands can't run.") }
    }

    private func saveProjectTrust(_ list: ProjectTrustList) throws {
        if let url = projectTrustURL {
            do { try OwnerOnlyFile.publish(try JSONEncoder().encode(list), to: url) } catch { throw ProjectFileFailure("Trusted project files could not be saved.") }
        }
        projectTrust = list
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
            errorMessage = "The project file can't be opened: " + error.issues.map { ($0.key.map { "\($0): " } ?? "") + $0.message }.joined(separator: " ")
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
            }, keepLiveLaunches: true)
        guard plan.canApply else {
            throw ProjectFileFailure(
                "The project file can't be opened: " + (plan.errors + plan.conflicts).map { ($0.key.map { "\($0): " } ?? "") + $0.message }.joined(separator: " "))
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
        return ProjectFileDraft(
            windowID: windowID, root: root, file: exported.file, paneIDs: exported.paneIDs, warnings: exported.warnings + (legacy ? [legacyWarning] : []),
            replacesExisting: FileManager.default.fileExists(atPath: url.path), commands: exported.file.entries.map { $0.pane.command ?? "" })
    }

    public func cancelProjectSave() { pendingProjectSave = nil }

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

    /// Writes the reviewed file, trusts its bytes and makes the window the project's window. A failure leaves the
    /// file, trust and bindings as they were.
    @discardableResult
    public func writeProjectFile(_ draft: ProjectFileDraft) -> Bool {
        let file = draft.file.settingCommands(draft.commands)
        if let issue = file.issues.first {
            errorMessage = (issue.key.map { "\($0): " } ?? "") + issue.message
            return false
        }
        // What is written must open again: the same strict parse, keys and limits as `loadProjectFile`.
        let data = ProjectFileJSON.encode(file)
        let reread = ProjectFileJSON.parse(data).map { $0.resolve(projectRoot: draft.root).layout }
        let problems: [LayoutIssue]
        switch reread {
        case .failure(let error): problems = error.issues
        case .success(let layout):
            problems =
                LayoutPlanner.plan(layout, bindings: [:], snapshot: WorkspaceSnapshot(), home: "/", hostExists: { _ in false }, directoryExists: { _ in true })
                .errors
        }
        if let issue = problems.first {
            errorMessage = "The window can't be saved as a project file: " + (issue.key.map { "\($0): " } ?? "") + issue.message
            return false
        }
        guard !layoutApplyInFlight else {
            errorMessage = "A layout is being applied. Nothing was written; try again."
            return false
        }
        guard let window = snapshot.windows.first(where: { $0.id == draft.windowID }), let bindings = file.bindings(window: window, snapshot: snapshot),
            ProjectFile.export(window: window, snapshot: snapshot, projectRoot: draft.root, directory: { self.projectPaneDirectory($0, root: draft.root) }, command: { _ in nil }).paneIDs == draft.paneIDs
        else {
            errorMessage = "The window changed while saving. Nothing was written; try again."
            return false
        }
        guard writeRepositoryFile(data, to: ProjectFile.url(projectRoot: draft.root)) else { return false }
        // The user wrote these commands, so this version is trusted; failures here only mean a later review.
        if var list = try? projectTrustList() {
            list.trust(root: draft.root, digest: ProjectTrustList.digest(data))
            try? saveProjectTrust(list)
        }
        if (try? layoutBindings(Self.projectNamespace(draft.root))) != nil { try? saveLayoutBindings(Self.projectNamespace(draft.root), bindings) }
        for (entry, paneID) in zip(file.entries, draft.paneIDs) { projectFileCommands[paneID] = entry.pane.command }
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
