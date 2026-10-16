import AppKit
import Combine
import UTermCore
import UTermTerminal

@MainActor
public final class AppWorkspaceModel: ObservableObject {
    @Published public private(set) var snapshot = WorkspaceSnapshot()
    @Published public private(set) var terminals: [UUID: NativeTerminal] = [:]
    @Published public var errorMessage: String?
    @Published public private(set) var defaultShell: String
    @Published public private(set) var defaultDirectory: String
    public var openSettings: (() -> Void)?
    private let service: WorkspaceCommandService
    private var updates: Task<Void, Never>?
    private let preferences: UserDefaults
    private var shuttingDown = false
    private var pendingOperations = 0

    public init(store: WorkspaceStore, preferences: UserDefaults = .standard) {
        service = WorkspaceCommandService(store: store)
        self.preferences = preferences
        defaultShell = preferences.string(forKey: "terminal.shell") ?? LocalLaunchConfiguration.loginShell().executable
        defaultDirectory = preferences.string(forKey: "terminal.directory") ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    public var presentation: WorkspacePresentation { WorkspacePresentation(snapshot: snapshot) }
    public var activeTerminal: NativeTerminal? { presentation.activePane.flatMap { terminals[$0.id] } }
    public var runningTerminals: [NativeTerminal] { terminals.values.filter(\.isRunning) }

    public func refresh() async { snapshot = await service.store.snapshot() }

    public func createWindow(name: String? = nil, startSession: Bool = true, fixture: Bool = false) async {
        guard !shuttingDown, !Task.isCancelled else { return }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        do {
            let result = try await service.execute(.createWindow(name: name ?? "Window \(snapshot.windows.count + 1)"))
            guard !shuttingDown, !Task.isCancelled else { return }
            guard let id = result.createdWindowID, let window = result.snapshot.windows.first(where: { $0.id == id }),
                  let tab = result.snapshot.tabs[window.activeTabID], let pane = result.snapshot.panes[tab.activePaneID] else { return }
            let terminal = NativeTerminal(sessionID: pane.sessionID)
            terminal.view.setAccessibilityIdentifier("terminal.\(pane.id.uuidString)")
            terminals[pane.id] = terminal
            snapshot = result.snapshot
            if startSession { await start(paneID: pane.id, fixture: fixture) }
        } catch { errorMessage = "The window could not be created." }
    }

    public func selectWindow(_ id: UUID) async {
        do { snapshot = try await service.execute(.selectWindow(id: id)).snapshot }
        catch { errorMessage = "The window could not be selected." }
    }

    public func start(paneID: UUID, fixture: Bool = false) async {
        guard !shuttingDown, !Task.isCancelled, let terminal = terminals[paneID], terminal.sessionState == .stopped else { return }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        do {
            let result = try await service.execute(.startSession(paneID: paneID))
            snapshot = result.snapshot
            guard case .start(let request) = result.effects.first else { return }
            guard !shuttingDown, !Task.isCancelled else {
                snapshot = try await service.execute(.completeLaunch(sessionID: request.sessionID, attemptID: request.attemptID,
                    outcome: .failed(message: "Session launch was cancelled."))).snapshot
                return
            }
            terminal.onInputError = { [weak self] _ in self?.errorMessage = "Terminal input could not be sent. Check the session or try a smaller paste." }
            var launchCompleted = false
            terminal.onStateChanged = { [weak self, weak terminal] state in
                guard !launchCompleted, state == .running || state == .closing,
                      let pid = terminal?.processID else { return }
                launchCompleted = true
                self?.enqueue(.completeLaunch(sessionID: request.sessionID, attemptID: request.attemptID, outcome: .started(processID: pid)))
            }
            terminal.onExit = { [weak self, weak terminal] code in
                guard let self, let terminal else { return }
                let command: WorkspaceCommand = !launchCompleted
                    ? .completeLaunch(sessionID: request.sessionID, attemptID: request.attemptID, outcome: .failed(message: terminal.sessionState == .failed
                        ? "The executable, directory, or environment could not be used." : "Session launch was cancelled."))
                    : .recordSessionExit(sessionID: request.sessionID, code: code)
                self.enqueue(command)
            }
            if fixture { await terminal.startFixture() }
            else { await terminal.start(configuration: .loginShell(executable: defaultShell, directory: defaultDirectory)) }
        } catch { errorMessage = "The terminal session could not be started." }
    }

    /// Preserve callback order across async store calls, including fast exits.
    private func enqueue(_ command: WorkspaceCommand) {
        let previous = updates
        updates = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do { self.snapshot = try await self.service.execute(command).snapshot }
            catch { self.errorMessage = "The terminal state could not be updated." }
        }
    }

    public func waitForUpdates() async { await updates?.value }

    public func saveLaunchSettings(shell: String, directory: String) async -> Bool {
        let configuration = LocalLaunchConfiguration.loginShell(executable: shell, directory: directory)
        do {
            _ = try await Task.detached { try LocalLaunchValidator().validate(configuration) }.value
            defaultShell = shell; defaultDirectory = directory
            preferences.set(shell, forKey: "terminal.shell")
            preferences.set(directory, forKey: "terminal.directory")
            return true
        } catch { return false }
    }

    public func stopAll() {
        shuttingDown = true
        runningTerminals.forEach { $0.stop() }
    }

    public func shutdown() async {
        stopAll()
        while pendingOperations > 0 || !runningTerminals.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await waitForUpdates()
    }

    public func closeAllWorkspaces() async {
        await shutdown()
        do {
            snapshot = try await service.execute(.closeAllWindows).snapshot
            terminals.removeAll()
            shuttingDown = false
        } catch { errorMessage = "The workspaces could not be closed." }
    }
}
