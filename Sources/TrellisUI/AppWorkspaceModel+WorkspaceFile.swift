import AppKit
import Foundation
import TrellisControl
import TrellisCore

/// A project workspace file found at or above a pane's directory (FR-WF02).
public struct WorkspaceFileOffer: Equatable, Sendable {
    /// The canonical project folder (the parent of `.trellis`).
    public let root: String
    public let name: String
    public var path: String { WorkspaceFile.url(projectRoot: root).path }
}

/// A parsed file waiting for the user to review its commands (FR-WF03). Opening uses exactly these bytes'
/// contents, never a later read, so what was reviewed is what runs.
public struct WorkspaceFileReview: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let root: String
    public let file: WorkspaceFile
    public let digest: String
    /// Another version of this folder's file was trusted before.
    public let changedSinceTrusted: Bool
    public let warnings: [String]
    public var path: String { WorkspaceFile.url(projectRoot: root).path }
}

/// The window as a workspace file, with editable commands, before it is written (FR-WF06).
public struct WorkspaceFileDraft: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let windowID: UUID
    public let root: String
    public let file: WorkspaceFile
    public let paneIDs: [UUID]
    public let warnings: [String]
    public let replacesExisting: Bool
    /// One per pane, in `file.entries` order.
    public var commands: [String]
    public var path: String { WorkspaceFile.url(projectRoot: root).path }
}

/// Folder pickers for workspace files; injected so tests never show a panel.
@MainActor
public enum WorkspaceFilePanels {
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

    /// The project folder for a chosen folder, `.trellis` folder or `workspace.json` file.
    public static func projectRoot(forSelection path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        if url.lastPathComponent == WorkspaceFile.fileName, url.deletingLastPathComponent().lastPathComponent == WorkspaceFile.directoryName {
            url = url.deletingLastPathComponent()
        }
        if url.lastPathComponent == WorkspaceFile.directoryName { url = url.deletingLastPathComponent() }
        return url.path
    }
}

extension AppWorkspaceModel {
    /// API namespaces match the layout key pattern, which has no `:`, so these never collide with them.
    static func workspaceNamespace(_ root: String) -> String { "workspace-file:" + root }
    nonisolated private static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    // MARK: Detection (FR-WF02)

    /// Looks for a workspace file above a local shell's new directory, off the main actor; a newer directory wins.
    func detectWorkspaceFile(paneID: UUID, directory: String) {
        guard workspaceFileLookups[paneID] != directory else { return }
        workspaceFileLookups[paneID] = directory
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        Task { [weak self] in
            let offer = await Task.detached(priority: .utility) { () -> WorkspaceFileOffer? in
                guard let found = WorkspaceFileLocator.projectRoot(containing: directory, home: home, fileExists: { FileManager.default.fileExists(atPath: $0) })
                else { return nil }
                let root = Self.canonical(found)
                // Only a regular file the user owns is offered (a shared folder such as /tmp could hold anyone's); a file
                // that doesn't parse is still offered, so opening it explains why.
                guard let data = try? OwnerOnlyFile.read(WorkspaceFile.url(projectRoot: root), limit: WorkspaceFile.maximumBytes) else { return nil }
                let name = try? WorkspaceFileJSON.parse(data).get().name
                return WorkspaceFileOffer(root: root, name: name ?? URL(fileURLWithPath: root).lastPathComponent)
            }.value
            guard let self, self.workspaceFileLookups[paneID] == directory else { return }
            if self.workspaceFileOffers[paneID] != offer { self.workspaceFileOffers[paneID] = offer }
        }
    }

    /// The offer a tab shows: its active pane's, else any pane's. Never for the project's own window or a
    /// folder the user declined.
    public func workspaceFileOffer(tabID: UUID) -> WorkspaceFileOffer? {
        guard let tab = snapshot.tabs[tabID] else { return nil }
        let candidates = [tab.activePaneID] + tab.root.paneIDs.filter { $0 != tab.activePaneID }
        guard let offer = candidates.lazy.compactMap({ self.workspaceFileOffers[$0] }).first else { return nil }
        if (try? workspaceTrustList())?.isIgnored(offer.root) == true { return nil }
        if (try? layoutBindings(Self.workspaceNamespace(offer.root)))?[WorkspaceFile.windowKey]?.id == tab.windowID { return nil }
        return offer
    }

    public func stopOfferingWorkspaceFile(root: String) {
        do {
            var list = try workspaceTrustList()
            list.setIgnored(root, true)
            try saveWorkspaceTrust(list)
            objectWillChange.send()
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Trust (FR-WF03)

    private var workspaceTrustURL: URL? { persistence?.directory.appendingPathComponent("workspace-trust.json") }

    /// An unreadable trust file fails closed: nothing is trusted and it is never overwritten.
    func workspaceTrustList() throws -> WorkspaceTrustList {
        if let workspaceTrust { return workspaceTrust }
        do {
            let stored = try workspaceTrustURL.flatMap { try OwnerOnlyFile.read($0, limit: 4_194_304) }
            let list = try stored.map { try JSONDecoder().decode(WorkspaceTrustList.self, from: $0) } ?? WorkspaceTrustList()
            // A newer format is unreadable too: rewriting it would drop what this version doesn't know.
            guard list.version == WorkspaceTrustList().version else { throw WorkspaceFileFailure("") }
            workspaceTrust = list
            return list
        } catch { throw WorkspaceFileFailure("Trusted workspace files could not be read, so workspace file commands can't run.") }
    }

    private func saveWorkspaceTrust(_ list: WorkspaceTrustList) throws {
        if let url = workspaceTrustURL {
            do { try OwnerOnlyFile.publish(try JSONEncoder().encode(list), to: url) } catch { throw WorkspaceFileFailure("Trusted workspace files could not be saved.") }
        }
        workspaceTrust = list
    }

    // MARK: Opening (FR-WF04)

    /// Reads and checks a project's file, then opens it at once when it has no commands or this exact version
    /// is trusted; otherwise it waits for review in `pendingWorkspaceReview`.
    public func loadWorkspaceFile(root: String) async {
        let root = Self.canonical(root)
        let data: Data
        do {
            guard let read = try OwnerOnlyFile.read(WorkspaceFile.url(projectRoot: root), limit: WorkspaceFile.maximumBytes) else {
                errorMessage = "There is no \(WorkspaceFile.directoryName)/\(WorkspaceFile.fileName) in \(root)."
                return
            }
            data = read
        } catch {
            errorMessage = "\(WorkspaceFile.directoryName)/\(WorkspaceFile.fileName) must be a regular file you own, at most 256 KB, and not a symbolic link."
            return
        }
        let file: WorkspaceFile
        switch WorkspaceFileJSON.parse(data) {
        case .success(let parsed): file = parsed
        case .failure(let error):
            errorMessage = "The workspace file can't be opened: " + error.issues.map { ($0.key.map { "\($0): " } ?? "") + $0.message }.joined(separator: " ")
            return
        }
        let plan: LayoutPlan
        do { plan = try planWorkspaceFile(file, root: root) } catch {
            errorMessage = error.localizedDescription
            return
        }
        let digest = WorkspaceTrustList.digest(data)
        let trust = try? workspaceTrustList()
        let review = WorkspaceFileReview(
            root: root, file: file, digest: digest, changedSinceTrusted: trust?.trustedOtherVersion(root: root, digest: digest) ?? false,
            warnings: plan.warnings.map(\.message))
        guard file.hasCommands, trust?.isTrusted(root: root, digest: digest) != true else {
            await openReviewedWorkspaceFile(review, runCommands: file.hasCommands)
            return
        }
        pendingWorkspaceReview = review
    }

    public enum WorkspaceReviewDecision: Sendable { case cancel, openWithoutCommands, trustAndOpen }

    public func resolveWorkspaceReview(_ id: UUID, _ decision: WorkspaceReviewDecision) async {
        guard let review = pendingWorkspaceReview, review.id == id else { return }
        pendingWorkspaceReview = nil
        switch decision {
        case .cancel: return
        case .openWithoutCommands: await openReviewedWorkspaceFile(review, runCommands: false)
        case .trustAndOpen:
            do {
                var list = try workspaceTrustList()
                list.trust(root: review.root, digest: review.digest)
                try saveWorkspaceTrust(list)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            await openReviewedWorkspaceFile(review, runCommands: true)
        }
    }

    private func planWorkspaceFile(_ file: WorkspaceFile, root: String) throws -> LayoutPlan {
        let bindings: [String: LayoutBinding]
        do { bindings = try layoutBindings(Self.workspaceNamespace(root)) } catch {
            throw WorkspaceFileFailure("Saved layout bindings could not be read, so the workspace file can't be opened.")
        }
        let plan = LayoutPlanner.plan(
            file.resolve(projectRoot: root).layout, bindings: bindings, snapshot: snapshot, home: FileManager.default.homeDirectoryForCurrentUser.path,
            hostExists: { _ in false },
            directoryExists: { path in
                var isDirectory: ObjCBool = false; return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }, keepLiveLaunches: true)
        guard plan.canApply else {
            throw WorkspaceFileFailure(
                "The workspace file can't be opened: " + (plan.errors + plan.conflicts).map { ($0.key.map { "\($0): " } ?? "") + $0.message }.joined(separator: " "))
        }
        return plan
    }

    /// Creates or reconciles the project's window, starts only the panes this open created, and queues their
    /// commands when allowed. Reopening never restarts a pane or runs a command again.
    @discardableResult
    func openReviewedWorkspaceFile(_ review: WorkspaceFileReview, runCommands: Bool) async -> UUID? {
        let namespace = Self.workspaceNamespace(review.root)
        let resolved = review.file.resolve(projectRoot: review.root)
        let plan: LayoutPlan
        do { plan = try planWorkspaceFile(review.file, root: review.root) } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        do { _ = try await automationApplyLayout(plan, namespace: namespace) } catch {
            errorMessage = "The workspace changed or is busy, so the workspace file wasn't opened. Try again."
            return nil
        }
        guard let windowID = plan.bindings[WorkspaceFile.windowKey]?.id else { return nil }
        for (key, paneID) in plan.createdPanes {
            if let command = resolved.commands[key] {
                workspaceFileCommands[paneID] = command
                if runCommands, let sessionID = snapshot.panes[paneID]?.sessionID { pendingWorkspaceCommands[sessionID] = command }
            }
        }
        await selectWindow(windowID)
        for (_, paneID) in plan.createdPanes {
            let sessionID = snapshot.panes[paneID]?.sessionID
            try? await automationStartSession(paneID, launch: nil, environment: [:])
            // A start that was refused or skipped (restoring, closing, shutting down) drops the command, so a later
            // manual start never types it (FR-WF05).
            if let sessionID, ![.starting, .running].contains(snapshot.sessions[sessionID]?.state) { pendingWorkspaceCommands.removeValue(forKey: sessionID) }
            // Without integration there is no prompt mark to wait for; the PTY holds the command until the shell reads it.
            if !shellGetsIntegration { submitWorkspaceCommand(paneID: paneID) }
        }
        return windowID
    }

    // MARK: Commands (FR-WF05)

    /// Whether a new local shell pane gets integration, and so reports its first prompt (FR-SI01).
    var shellGetsIntegration: Bool {
        shellIntegrationEnabled && shellIntegrationDirectory != nil && ShellIntegrationKind(executable: defaultShell) != nil
    }

    /// Types a queued command into its shell, once; it is dropped if the shell is no longer running.
    func submitWorkspaceCommand(paneID: UUID) {
        guard let terminal = terminals[paneID], let command = pendingWorkspaceCommands.removeValue(forKey: terminal.sessionID),
            terminal.sessionState == .running
        else { return }
        try? terminal.adapter.send(Data((command + "\r").utf8))
    }

    // MARK: Saving (FR-WF06)

    /// Asks for the project folder and prepares the window's file for review in `pendingWorkspaceSave`.
    public func beginSaveWorkspaceFile(windowID: UUID) {
        guard let window = snapshot.windows.first(where: { $0.id == windowID }) else { return }
        let active = snapshot.tabs[window.activeTabID].flatMap { paneDirectory($0.activePaneID) }
        let suggestion = active.map { directory in
            WorkspaceFileLocator.projectRoot(containing: directory, home: FileManager.default.homeDirectoryForCurrentUser.path) {
                FileManager.default.fileExists(atPath: $0)
            } ?? directory
        }
        guard let root = chooseWorkspaceFolder("Choose the project folder. The layout is saved to .trellis/workspace.json inside it.", suggestion) else { return }
        do { pendingWorkspaceSave = try workspaceFileDraft(windowID: windowID, root: root) } catch { errorMessage = error.localizedDescription }
    }

    /// Asks for a project folder or workspace file and opens it.
    public func beginOpenWorkspaceFile() async {
        let directory = presentation.activePane.flatMap { paneDirectory($0.id) }
        guard let root = chooseWorkspaceFolder("Choose a project folder with a .trellis/workspace.json, or the file itself.", directory) else { return }
        await loadWorkspaceFile(root: root)
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

    public func workspaceFileDraft(windowID: UUID, root: String) throws -> WorkspaceFileDraft {
        let root = Self.canonical(root)
        guard let window = snapshot.windows.first(where: { $0.id == windowID }) else { throw WorkspaceFileFailure("The window no longer exists.") }
        let url = WorkspaceFile.url(projectRoot: root)
        // Keys and commands the current file declares carry over to the panes they are bound to.
        let existing = (try? OwnerOnlyFile.read(url, limit: WorkspaceFile.maximumBytes)).flatMap { try? WorkspaceFileJSON.parse($0).get() }
        let bindings = (try? layoutBindings(Self.workspaceNamespace(root))) ?? [:]
        var keys: [UUID: String] = [:], commands: [UUID: String] = [:]
        if let existing {
            let declared = Set(existing.tabs.compactMap(\.key) + existing.entries.compactMap(\.pane.key))
            for (key, binding) in bindings where declared.contains(key) { keys[binding.id] = key }
            for entry in existing.entries { if let command = entry.pane.command, let id = bindings[entry.key]?.id { commands[id] = command } }
        }
        let exported = WorkspaceFile.export(
            window: window, snapshot: snapshot, projectRoot: root, directory: paneDirectory, command: { self.workspaceFileCommands[$0] ?? commands[$0] },
            key: { keys[$0] })
        return WorkspaceFileDraft(
            windowID: windowID, root: root, file: exported.file, paneIDs: exported.paneIDs, warnings: exported.warnings,
            replacesExisting: FileManager.default.fileExists(atPath: url.path), commands: exported.file.entries.map { $0.pane.command ?? "" })
    }

    public func cancelWorkspaceSave() { pendingWorkspaceSave = nil }

    /// Writes the reviewed file, trusts its bytes and makes the window the project's window. A failure leaves the
    /// file, trust and bindings as they were.
    @discardableResult
    public func writeWorkspaceFile(_ draft: WorkspaceFileDraft) -> Bool {
        let file = draft.file.settingCommands(draft.commands)
        if let issue = file.issues.first {
            errorMessage = (issue.key.map { "\($0): " } ?? "") + issue.message
            return false
        }
        // What is written must open again: the same strict parse, keys and limits as `loadWorkspaceFile`.
        let data = WorkspaceFileJSON.encode(file)
        let reread = WorkspaceFileJSON.parse(data).map { $0.resolve(projectRoot: draft.root).layout }
        let problems: [LayoutIssue]
        switch reread {
        case .failure(let error): problems = error.issues
        case .success(let layout):
            problems =
                LayoutPlanner.plan(layout, bindings: [:], snapshot: WorkspaceSnapshot(), home: "/", hostExists: { _ in false }, directoryExists: { _ in true })
                .errors
        }
        if let issue = problems.first {
            errorMessage = "The window can't be saved as a workspace file: " + (issue.key.map { "\($0): " } ?? "") + issue.message
            return false
        }
        guard !layoutApplyInFlight else {
            errorMessage = "A layout is being applied. Nothing was written; try again."
            return false
        }
        guard let window = snapshot.windows.first(where: { $0.id == draft.windowID }), let bindings = file.bindings(window: window, snapshot: snapshot),
            WorkspaceFile.export(window: window, snapshot: snapshot, projectRoot: draft.root, directory: paneDirectory, command: { _ in nil }).paneIDs == draft.paneIDs
        else {
            errorMessage = "The window changed while saving. Nothing was written; try again."
            return false
        }
        let url = WorkspaceFile.url(projectRoot: draft.root)
        do {
            // A repository file, not Trellis state: readable by the project's tools like any other source file.
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        } catch {
            errorMessage = "\(url.path) could not be written. Check the folder's permissions and try again."
            return false
        }
        // The user wrote these commands, so this version is trusted; failures here only mean a later review.
        if var list = try? workspaceTrustList() {
            list.trust(root: draft.root, digest: WorkspaceTrustList.digest(data))
            try? saveWorkspaceTrust(list)
        }
        if (try? layoutBindings(Self.workspaceNamespace(draft.root))) != nil { try? saveLayoutBindings(Self.workspaceNamespace(draft.root), bindings) }
        for (entry, paneID) in zip(file.entries, draft.paneIDs) { workspaceFileCommands[paneID] = entry.pane.command }
        pendingWorkspaceSave = nil
        return true
    }
}

struct WorkspaceFileFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
