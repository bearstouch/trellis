import AppKit
import Foundation
import TrellisControl
import TrellisCore
import TrellisTerminal

/// The Tasks menu's view of one project (FR-TK02), read when the menu opens.
public struct TaskCatalog: Equatable, Sendable {
    public enum FileState: Equatable, Sendable {
        case missing
        case loaded(LaunchFile)
        /// Unreadable or invalid; the text says why.
        case invalid(String)
    }

    /// The canonical project folder.
    public let root: String
    /// The pane Run types into: the one whose menu was opened.
    public let paneID: UUID
    public let file: FileState
    /// The bytes listed, so Add never overwrites a newer file and trust covers exactly what was shown.
    let data: Data?
    public let detected: [DetectedTask]
    /// A project on a remote workspace's host (FR-RW11): Run types into that host's shell; nothing is written there.
    public let hostID: UUID?
    /// What trust is recorded under: the folder, or for a host its ID, machine and folder.
    let trustKey: String

    init(root: String, paneID: UUID, file: FileState, data: Data?, detected: [DetectedTask], hostID: UUID? = nil, trustKey: String? = nil) {
        self.root = root; self.paneID = paneID; self.file = file; self.data = data; self.detected = detected
        self.hostID = hostID; self.trustKey = trustKey ?? root
    }

    public var name: String { URL(fileURLWithPath: root).lastPathComponent }
    public var path: String { LaunchFile.url(projectRoot: root).path }
    var digest: String? { data.map(ProjectTrustList.digest) }

    public var tasks: [LaunchTask] {
        guard case .loaded(let launch) = file else { return [] }
        return launch.tasks
    }

    /// The file already has a task with this command and folder.
    public func contains(_ task: LaunchTask) -> Bool { tasks.contains { $0.command == task.command && $0.cwd == task.cwd } }
}

/// A file task waiting for the user to review the file's tasks (FR-TK06). Running uses this parsed copy, never a
/// later read, so what was reviewed is what runs.
public struct TaskReview: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let root: String
    public let paneID: UUID
    public let file: LaunchFile
    public let digest: String
    public let taskName: String
    /// Another version of this folder's file was trusted before.
    public let changedSinceTrusted: Bool
    public var path: String { LaunchFile.url(projectRoot: root).path }
    /// A remote project's host, named in the review (FR-RW11).
    public var hostName: String? = nil
    var trustKey: String? = nil
}

/// Why Run can't type into a pane right now (FR-TK05).
public enum TaskRunAvailability: Equatable, Sendable {
    case ready, notRunning, remote, noIntegration, busy, taskActive

    public var reason: String? {
        switch self {
        case .ready: nil
        case .notRunning: "The pane's shell isn't running."
        case .remote: "Tasks run in local shells and remote workspace shells, not in SSH panes."
        case .noIntegration: "Run needs shell integration, so Trellis knows the shell is waiting at its prompt."
        case .busy: "The shell is running a command. Wait for its prompt, or stop the command."
        case .taskActive: "A task is already running in this pane."
        }
    }
}

extension AppWorkspaceModel {
    static func taskID(_ task: LaunchTask, detected: Bool) -> String { (detected ? "detected:" : "file:") + task.name }

    // MARK: Catalog (FR-TK02, FR-TK03)

    /// Finds a pane's project and reads its tasks off the main actor; a newer refresh wins. Without `paneID` it
    /// rereads the menu's current pane, else the active one.
    public func refreshTaskCatalog(paneID: UUID? = nil) async {
        taskCatalogGeneration &+= 1
        let generation = taskCatalogGeneration
        let target = [paneID, taskCatalog?.paneID, presentation.activePane?.id].lazy.compactMap { $0 }.first { self.snapshot.panes[$0] != nil }
        guard let pane = target.flatMap({ snapshot.panes[$0] }), let launch = snapshot.sessions[pane.sessionID]?.launch else {
            taskCatalog = nil
            return
        }
        // FR-RW11: a remote workspace pane's project is read on its host, from the shell's authenticated directory.
        if let hostID = launch.remoteHostID {
            var catalog: TaskCatalog?
            if let directory = remoteWorkingDirectory(paneID: pane.id) { catalog = await loadRemoteTaskCatalog(directory: directory, hostID: hostID, paneID: pane.id) }
            guard generation == taskCatalogGeneration else { return }
            if taskCatalog != catalog { taskCatalog = catalog }
            return
        }
        guard !Self.isRemote(launch), let directory = paneDirectory(pane.id) else {
            taskCatalog = nil
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paneID = pane.id
        let catalog = await Task.detached(priority: .utility) { Self.loadTaskCatalog(directory: directory, home: home, paneID: paneID) }.value
        guard generation == taskCatalogGeneration else { return }
        if taskCatalog != catalog { taskCatalog = catalog }
    }

    nonisolated static func loadTaskCatalog(directory: String, home: String, paneID: UUID) -> TaskCatalog? {
        let manager = FileManager.default
        guard let found = ProjectFileLocator.taskRoot(containing: directory, home: home, exists: { manager.fileExists(atPath: $0) }) else { return nil }
        let root = canonical(found)
        let state: TaskCatalog.FileState
        var data: Data?
        do {
            // Only a regular file the user owns, like a project file: a shared folder could hold anyone's.
            data = try OwnerOnlyFile.read(LaunchFile.url(projectRoot: root), limit: LaunchFile.maximumBytes)
            switch data.map(LaunchFileJSON.parse) {
            case nil: state = .missing
            case .success(let file)?: state = .loaded(file)
            case .failure(let error)?: state = .invalid(LaunchFileJSON.describe(error))
            }
        } catch {
            state = .invalid("launch.json must be a regular file you own, at most 64 KB, and not a symbolic link.")
        }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let detected = TaskDetector.detect(
            read: { name, limit in (try? OwnerOnlyFile.read(rootURL.appendingPathComponent(name), limit: limit)) ?? nil },
            exists: { manager.fileExists(atPath: root + "/" + $0) })
        return TaskCatalog(root: root, paneID: paneID, file: state, data: data, detected: detected)
    }

    // MARK: Running (FR-TK05, FR-TK09)

    public func taskAvailability(paneID: UUID) -> TaskRunAvailability {
        guard let pane = snapshot.panes[paneID], let terminal = terminals[paneID], terminal.sessionID == pane.sessionID, terminal.sessionState == .running,
            !isClosing(paneID: paneID), !shuttingDown
        else { return .notRunning }
        guard let launch = snapshot.sessions[pane.sessionID]?.launch, !Self.isRemote(launch) || launch.remoteHostID != nil else { return .remote }
        if taskRuns[paneID]?.isActive == true { return .taskActive }
        guard terminal.shellMarkOrigin == .authenticated, let state = shellStates[paneID], taskShell(paneID: paneID) != nil else { return .noIntegration }
        return state.commandRunning || terminal.isReplaying ? .busy : .ready
    }

    /// The pane's own login shell; integration (and so Run) only exists for the bundled kinds.
    func taskShell(paneID: UUID) -> (path: String, kind: ShellIntegrationKind)? {
        // A remote workspace shell is the host account's login shell, as its helper reports it.
        if let pane = snapshot.panes[paneID], let hostID = snapshot.sessions[pane.sessionID]?.launch.remoteHostID {
            guard let shell = remoteHosts?.workspaceConnection(hostID)?.hostInfo?.shell, let kind = ShellIntegrationKind(executable: shell) else { return nil }
            return (shell, kind)
        }
        guard let pane = snapshot.panes[paneID], case .process(let executable, _, _)? = snapshot.sessions[pane.sessionID]?.launch,
            let kind = ShellIntegrationKind(executable: executable)
        else { return nil }
        return (executable, kind)
    }

    /// Exactly what Run would type for `task` now, for the menu; nil when it can't be typed (not a bundled shell, or a
    /// folder, shell or value that can't be quoted).
    public func taskLine(_ task: LaunchTask, fromFile: Bool) -> String? {
        guard let catalog = taskCatalog, let shell = taskShell(paneID: catalog.paneID) else { return nil }
        var environment: [(name: String, value: String)] = []
        if fromFile, case .loaded(let file) = catalog.file { environment = file.environment(for: task) }
        return TaskCommand.compose(
            command: task.command, directory: task.directory(projectRoot: catalog.root),
            currentDirectory: taskCurrentDirectory(paneID: catalog.paneID, directory: task.directory(projectRoot: catalog.root)),
            environment: environment, shell: shell.path, kind: shell.kind)
    }

    /// Types a task into the catalog's pane. A file task from a version that isn't trusted waits for review in
    /// `pendingTaskReview` first (FR-TK06); detected tasks come from fixed templates and run at once.
    public func runTask(_ task: LaunchTask, fromFile: Bool) {
        guard let catalog = taskCatalog else { return }
        if let reason = taskAvailability(paneID: catalog.paneID).reason {
            errorMessage = reason
            return
        }
        guard fromFile else {
            typeTask(task, file: nil, root: catalog.root, paneID: catalog.paneID, taskID: Self.taskID(task, detected: true))
            return
        }
        guard case .loaded(let file) = catalog.file, let digest = catalog.digest, let task = file.task(named: task.name) else { return }
        let trust: ProjectTrustList
        do { trust = try launchTrustList() } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard trust.isTrusted(root: catalog.trustKey, digest: digest) else {
            pendingTaskReview = TaskReview(
                root: catalog.root, paneID: catalog.paneID, file: file, digest: digest, taskName: task.name,
                changedSinceTrusted: trust.trustedOtherVersion(root: catalog.trustKey, digest: digest), hostName: catalog.hostID.map(remoteHostName),
                trustKey: catalog.trustKey)
            return
        }
        typeTask(task, file: file, root: catalog.root, paneID: catalog.paneID, taskID: Self.taskID(task, detected: false))
    }

    public func resolveTaskReview(_ id: UUID, trust: Bool) {
        guard let review = pendingTaskReview, review.id == id else { return }
        pendingTaskReview = nil
        guard trust, let task = review.file.task(named: review.taskName) else { return }
        do {
            var list = try launchTrustList()
            list.trust(root: review.trustKey ?? review.root, digest: review.digest)
            try saveLaunchTrust(list)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        typeTask(task, file: review.file, root: review.root, paneID: review.paneID, taskID: Self.taskID(task, detected: false))
    }

    /// Ctrl-E then Ctrl-U first clear anything half-typed at the prompt, so the line runs as shown: bash and fish bind
    /// Ctrl-U to kill only what is left of the cursor.
    @discardableResult
    func typeTask(_ task: LaunchTask, file: LaunchFile?, root: String, paneID: UUID, taskID: String) -> Bool {
        let availability = taskAvailability(paneID: paneID)
        guard availability == .ready, let terminal = terminals[paneID], let shell = taskShell(paneID: paneID) else {
            errorMessage = availability.reason ?? TaskRunAvailability.noIntegration.reason
            return false
        }
        guard
            let line = TaskCommand.compose(
                command: task.command, directory: task.directory(projectRoot: root),
                currentDirectory: taskCurrentDirectory(paneID: paneID, directory: task.directory(projectRoot: root)),
                environment: file?.environment(for: task) ?? [], shell: shell.path, kind: shell.kind)
        else {
            errorMessage = "“\(task.name)” can't be typed safely: its folder or shell has characters that can't be quoted, or the line is too long."
            return false
        }
        return sendTaskLine(line, to: terminal, paneID: paneID, taskID: taskID, name: task.name)
    }

    /// Types `line` after Ctrl-E Ctrl-U and follows it as a task run. Callers check `taskAvailability` first.
    func sendTaskLine(_ line: String, to terminal: NativeTerminal, paneID: UUID, taskID: String, name: String) -> Bool {
        do { try terminal.adapter.send(Data(("\u{05}\u{15}" + line + "\r").utf8)) } catch {
            errorMessage = "The task could not be typed. The session may have stopped."
            return false
        }
        taskRuns[paneID] = TaskRun(taskID: taskID, name: name, at: activityNow())
        return true
    }

    // MARK: State and stopping (FR-TK07, FR-TK08)

    /// Follows the pane's run through its shell marks; replayed marks (FR-R03) describe older commands.
    func updateTaskRun(paneID: UUID, event: ShellIntegrationEvent) {
        guard var run = taskRuns[paneID], terminals[paneID]?.isReplaying != true else { return }
        if !run.apply(event, now: activityNow()) {
            taskRuns.removeValue(forKey: paneID)
        } else if run != taskRuns[paneID] {
            taskRuns[paneID] = run
        }
    }

    /// The tab's run for the Tasks button: its active pane's, else any pane's active one.
    public func taskRun(tabID: UUID) -> (paneID: UUID, run: TaskRun)? {
        guard let tab = snapshot.tabs[tabID] else { return nil }
        if let run = taskRuns[tab.activePaneID] { return (tab.activePaneID, run) }
        return tab.root.paneIDs.lazy.compactMap { id in self.taskRuns[id].flatMap { $0.isActive ? (id, $0) : nil } }.first
    }

    /// Ctrl-C: the terminal sends SIGINT to the foreground job. Can be repeated.
    public func stopTask(paneID: UUID) {
        guard var run = taskRuns[paneID], run.isActive, let terminal = terminals[paneID] else { return }
        do { try terminal.adapter.send(Data([0x03])) } catch {
            errorMessage = "Stop could not be sent. The session may have stopped."
            return
        }
        if run.stopRequestedAt == nil {
            run.stopRequestedAt = activityNow()
            taskRuns[paneID] = run
        }
    }

    /// Offered once the task outlived the first Stop by `taskStopEscalation`.
    public func canForceStop(paneID: UUID) -> Bool {
        guard let run = taskRuns[paneID], run.isActive, let requested = run.stopRequestedAt else { return false }
        return activityNow().timeIntervalSince(requested) >= taskStopEscalation
    }

    /// Ctrl-\: SIGQUIT to the foreground job, which most programs don't catch.
    public func forceStopTask(paneID: UUID) {
        guard canForceStop(paneID: paneID), let terminal = terminals[paneID] else { return }
        do { try terminal.adapter.send(Data([0x1C])) } catch { errorMessage = "Force Stop could not be sent. The session may have stopped." }
    }

    // MARK: Editing launch.json (FR-TK04)

    /// Appends a detected task, unless the file changed since the menu read it or doesn't parse.
    @discardableResult
    public func addDetectedTask(_ detected: DetectedTask) async -> Bool { await addTask(detected.task) != nil }

    /// Appends `task` to the catalog's launch.json and returns it as stored (renamed if its name was taken), or the
    /// task already there with the same command. Nothing is written if the file changed since the catalog read it or
    /// doesn't parse. The new version is trusted only when the old one was, or there was none, so adding never trusts
    /// someone else's tasks.
    func addTask(_ task: LaunchTask) async -> LaunchTask? {
        guard let catalog = taskCatalog else { return nil }
        // Trellis never writes a host's files in this version (FR-RW11).
        guard catalog.hostID == nil else { errorMessage = "launch.json on a remote host is read-only in Trellis. Add the task on the host."; return nil }
        if case .invalid(let reason) = catalog.file {
            errorMessage = "launch.json wasn't changed. " + reason
            return nil
        }
        let url = LaunchFile.url(projectRoot: catalog.root)
        let current: Data?
        do { current = try OwnerOnlyFile.read(url, limit: LaunchFile.maximumBytes) } catch {
            errorMessage = "launch.json wasn't changed. It must be a regular file you own, at most 64 KB, and not a symbolic link."
            return nil
        }
        guard current == catalog.data else {
            errorMessage = "launch.json changed since the Tasks menu read it. Nothing was written; check the file and try again."
            await refreshTaskCatalog()
            return nil
        }
        var existing = LaunchFile()
        if case .loaded(let file) = catalog.file { existing = file }
        let (updated, added) = existing.adding(task)
        let stored = updated.tasks.last { $0.command == task.command && $0.cwd == task.cwd }
        guard added else { return stored }
        let data = LaunchFileJSON.encode(updated)
        if case .failure(let error) = LaunchFileJSON.parse(data) {
            errorMessage = "The task can't be added: " + LaunchFileJSON.describe(error)
            return nil
        }
        guard writeRepositoryFile(data, to: url) else { return nil }
        if var list = try? launchTrustList(), catalog.data == nil || catalog.digest.map({ list.isTrusted(root: catalog.root, digest: $0) }) == true {
            list.trust(root: catalog.root, digest: ProjectTrustList.digest(data))
            try? saveLaunchTrust(list)
        }
        await refreshTaskCatalog()
        return stored
    }

    /// Opens launch.json in the user's editor, creating an empty one first when there is none.
    public func editLaunchFile() async {
        guard let catalog = taskCatalog else { return }
        guard catalog.hostID == nil else { errorMessage = "launch.json on a remote host is read-only in Trellis. Edit it on the host."; return }
        let url = LaunchFile.url(projectRoot: catalog.root)
        if case .missing = catalog.file, !FileManager.default.fileExists(atPath: url.path), !isSymbolicLink(url) {
            let data = LaunchFileJSON.encode(LaunchFile())
            guard writeRepositoryFile(data, to: url) else { return }
            // No tasks, nothing to review.
            if var list = try? launchTrustList() {
                list.trust(root: catalog.root, digest: ProjectTrustList.digest(data))
                try? saveLaunchTrust(list)
            }
            await refreshTaskCatalog()
        }
        openLaunchFile(url)
    }

    private func isSymbolicLink(_ url: URL) -> Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil }

    // MARK: Trust (FR-TK06)

    private var launchTrustURL: URL? { persistence?.directory.appendingPathComponent("launch-trust.json") }

    /// Separate from project file trust, which holds one digest per folder. An unreadable list fails closed:
    /// nothing is trusted and it is never overwritten.
    func launchTrustList() throws -> ProjectTrustList {
        if let launchTrust { return launchTrust }
        let list = try Self.readTrustList(launchTrustURL, failure: "Trusted launch.json files could not be read, so launch.json tasks can't run.")
        launchTrust = list
        return list
    }

    private func saveLaunchTrust(_ list: ProjectTrustList) throws {
        try Self.writeTrustList(list, to: launchTrustURL, failure: "Trusted launch.json files could not be saved.")
        launchTrust = list
    }
}
