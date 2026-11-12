import Foundation
import TrellisBroker
import TrellisCore
import TrellisTerminal

/// One launch of a library project (FR-PL06–FR-PL08): the target and folder chosen, what the target holds, and the
/// setup terminal while it runs. Runtime only.
@MainActor
public final class ProjectLaunchSession: ObservableObject, Identifiable {
    public enum Stage: Equatable {
        case checking
        /// Checked and ready: what setup will do (if anything) and what opens.
        case ready(ProjectLaunch)
        case invalid(String)
        case settingUp(ProjectLaunch)
        case failed(ProjectLaunch, String)
        case opening
    }

    public let id = UUID()
    public let project: ProjectDefinition
    @Published public var target: ProjectTarget
    @Published public var folder: String
    @Published public internal(set) var stage: Stage = .checking
    /// The setup's terminal on the target, while setup runs or after it failed.
    @Published public internal(set) var terminal: NativeTerminal?
    var checkGeneration = 0
    /// The target and folder the shown plan was checked for; the sheet acts only while they still match.
    @Published public internal(set) var checked: (target: ProjectTarget, folder: String)?
    public var isCurrent: Bool { checked.map { $0.target == target && $0.folder == folder } ?? false }

    init(project: ProjectDefinition, target: ProjectTarget) {
        self.project = project; self.target = target
        folder = ProjectLaunch.suggestedFolder(project, target: target)
    }
}

extension AppWorkspaceModel {
    /// Opens the launch sheet for a saved project, on a target it was launched on before: this Mac first, else a saved host.
    public func beginProjectLaunch(_ project: ProjectDefinition) {
        guard projectLaunch == nil else { return }
        let last = project.lastFolders.keys.sorted { a, b in a == "local" || (b != "local" && a < b) }.compactMap(ProjectTarget.init(key:)).first { target in
            if case .host(let id) = target { return commandPaletteHosts().contains { $0.id == id } }
            return true
        }
        let session = ProjectLaunchSession(project: project, target: last ?? .local)
        projectLaunch = session
        Task { await checkProjectLaunch(session) }
    }

    /// Checks the target again after the target or folder changed; a newer check wins. Only while choosing: once setup
    /// or opening started, nothing here changes the stage.
    public func checkProjectLaunch(_ session: ProjectLaunchSession) async {
        guard projectLaunch === session else { return }
        switch session.stage {
        case .checking, .ready, .invalid: break
        default: return
        }
        session.checkGeneration += 1
        let generation = session.checkGeneration
        session.stage = .checking
        let target = session.target, folder = session.folder
        session.checked = (target, folder)
        let result = await projectLauncher.plan(session.project, target: target, folder: folder)
        guard projectLaunch === session, session.checkGeneration == generation else { return }
        switch result {
        case .success(let launch): session.stage = .ready(launch)
        case .failure(let failure): session.stage = .invalid(failure.message)
        }
    }

    public func setProjectLaunchTarget(_ session: ProjectLaunchSession, _ target: ProjectTarget) {
        guard session.target != target else { return }
        session.target = target
        session.folder = ProjectLaunch.suggestedFolder(session.project, target: target)
        Task { await checkProjectLaunch(session) }
    }

    public func cancelProjectLaunch(_ session: ProjectLaunchSession) {
        guard projectLaunch === session else { return }
        // Clones that finished stay. One still running gets a hangup, so git removes its partial folder (a kill would
        // leave a broken checkout the next check takes as present), then a kill after 2 s. The terminal is kept until it
        // ends: dropping it would kill a local setup at once, and a host's helper releases the session only on its exit.
        if let terminal = session.terminal, [.starting, .running].contains(terminal.sessionState) {
            terminal.onExit = { [terminal] _ in terminal.onExit = nil }
            terminal.requestTermination(force: false)
            Task { [terminal] in
                try? await Task.sleep(for: .seconds(2))
                if [.starting, .running, .closing].contains(terminal.sessionState) { terminal.requestTermination(force: true) }
            }
        }
        session.terminal = nil
        projectLaunch = nil
    }

    // MARK: Setup (FR-PL07)

    /// Runs the setup script in a terminal on the target; when it succeeds the space opens.
    public func runProjectSetup(_ session: ProjectLaunchSession) async {
        guard projectLaunch === session else { return }
        let launch: ProjectLaunch
        switch session.stage {
        case .ready(let ready), .failed(let ready, _): launch = ready
        default: return
        }
        // A check still in flight must not put the sheet back to Ready while setup runs.
        session.checkGeneration += 1
        let terminal = NativeTerminal()
        terminal.applyPalette(effectiveTheme.terminal)
        session.terminal = terminal
        session.stage = .settingUp(launch)
        terminal.onExit = { [weak self, weak session] code in
            guard let self, let session, self.projectLaunch === session, case .settingUp(let running) = session.stage else { return }
            if code == 0 {
                Task {
                    // Folders that appeared are looked at again, so the plan reconciles against what is there now. The
                    // sheet stays on Setting Up meanwhile, so the target and folder can't change under it.
                    let result = await self.projectLauncher.plan(running.project, target: running.target, folder: running.folder)
                    guard self.projectLaunch === session, case .settingUp = session.stage else { return }
                    switch result {
                    case .success(let checked): await self.openProjectLaunch(session, checked)
                    case .failure(let failure): session.stage = .failed(running, failure.message)
                    }
                }
            } else {
                session.stage = .failed(running, code.map { L("Setup stopped with exit status %d. Check the output, then retry.", Int($0)) } ?? L("Setup ended without an exit status."))
            }
        }
        if let failure = await projectLauncher.startSetup(launch, in: terminal) { session.stage = .failed(launch, failure.message) }
    }

    // MARK: Opening (FR-PL08)

    /// Creates or reconciles the project's space, starts the panes this launch created and types their commands once.
    public func openProjectLaunch(_ session: ProjectLaunchSession, _ launch: ProjectLaunch) async {
        guard projectLaunch === session else { return }
        session.checkGeneration += 1
        session.stage = .opening
        let opened = await projectLauncher.open(
            launch, stillWanted: { projectLaunch === session },
            applied: {
                // A cancel during the apply may have let another launch begin; its sheet stays.
                if projectLaunch === session { projectLaunch = nil }
            })
        if case .failure(let failure) = opened { session.stage = .failed(launch, failure.message) }
    }
}
