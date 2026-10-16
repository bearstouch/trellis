import AppKit
import Combine
import UTermCore
import UTermTerminal

public enum TabRenameAction: Sendable { case commit, cancel }

public struct WindowActivity: Equatable, Sendable {
    public var hasOutput = false
    public var hasExit = false
    public init() {}
}

@MainActor
public final class AppWorkspaceModel: ObservableObject {
    @Published public private(set) var snapshot = WorkspaceSnapshot()
    @Published public private(set) var terminals: [UUID: NativeTerminal] = [:]
    @Published public var errorMessage: String?
    @Published public private(set) var defaultShell: String
    @Published public private(set) var defaultDirectory: String
    @Published public private(set) var activity: [UUID: WindowActivity] = [:]
    public var confirmCloseSessions: (Int) -> Bool = { count in
        guard count > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = "Close \(count) terminal session(s)?"
        alert.informativeText = "Their local processes will stop."
        alert.addButton(withTitle: "Close Sessions")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private var closingWindowIDs = Set<UUID>()
    private var closingTabIDs = Set<UUID>()
    @Published public var tabRenameRequest: UUID?
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

    public func refresh() async { publish(await service.store.snapshot()) }

    /// Async command replies can resume out of order; never regress visible state.
    func publish(_ next: WorkspaceSnapshot) {
        guard next.revision >= snapshot.revision else { return }
        snapshot = next
        if let selected = next.activeWindowID { activity.removeValue(forKey: selected) }
    }

    public func createWindow(name: String? = nil, startSession: Bool = true, fixture: Bool = false) async {
        guard !shuttingDown, !Task.isCancelled else { return }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        do {
            let result = try await service.execute(.createWindow(name: name ?? "Window \(snapshot.windows.count + 1)"))
            guard !shuttingDown, !Task.isCancelled else { return }
            guard let id = result.createdWindowID, let window = result.snapshot.windows.first(where: { $0.id == id }),
                  let tab = result.snapshot.tabs[window.activeTabID], let pane = result.snapshot.panes[tab.activePaneID] else { return }
            attachTerminal(pane)
            publish(result.snapshot)
            if startSession { await start(paneID: pane.id, fixture: fixture) }
        } catch { errorMessage = "The window could not be created." }
    }

    public func selectWindow(_ id: UUID) async {
        do {
            publish(try await service.execute(.selectWindow(id: id)).snapshot)
        }
        catch { errorMessage = "The window could not be selected." }
    }

    public func start(paneID: UUID, fixture: Bool = false) async {
        guard !isClosing(paneID: paneID), !shuttingDown, !Task.isCancelled, let terminal = terminals[paneID], terminal.sessionState == .stopped else { return }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        do {
            // Freeze the actual local launch configuration before starting. A duplicate
            // must reuse this session's shell and directory even after Settings change.
            let resolvedLaunch: SessionLaunch?
            if let pane = snapshot.panes[paneID], let session = snapshot.sessions[pane.sessionID] {
                switch session.launch {
                case .shell(let directory):
                    resolvedLaunch = .process(executable: defaultShell, arguments: ["-l"], directory: directory ?? defaultDirectory)
                case .process(let executable, let arguments, let directory):
                    resolvedLaunch = .process(executable: executable, arguments: arguments, directory: directory ?? defaultDirectory)
                case .host: resolvedLaunch = nil
                }
            } else { resolvedLaunch = nil }
            let result = try await service.execute(.startSession(paneID: paneID, resolvedLaunch: resolvedLaunch))
            publish(result.snapshot)
            guard case .start(let request) = result.effects.first else { return }
            guard !isClosing(paneID: paneID), !shuttingDown, !Task.isCancelled else {
                publish(try await service.execute(.completeLaunch(sessionID: request.sessionID, attemptID: request.attemptID,
                    outcome: .failed(message: "Session launch was cancelled."))).snapshot)
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
                self.recordActivity(paneID: paneID, exited: true)
                self.enqueue(command)
            }
            if fixture { await terminal.startFixture() }
            else {
                let configuration: LocalLaunchConfiguration
                switch request.launch {
                case .shell(let directory):
                    configuration = .loginShell(executable: defaultShell, directory: directory ?? defaultDirectory)
                case .process(let executable, let arguments, let directory):
                    configuration = LocalLaunchConfiguration(executable: executable, arguments: arguments, directory: directory ?? defaultDirectory)
                case .host:
                    publish(try await service.execute(.completeLaunch(sessionID: request.sessionID, attemptID: request.attemptID,
                        outcome: .failed(message: "Saved host connections require SSH integration."))).snapshot)
                    return
                }
                await terminal.start(configuration: configuration)
            }
        } catch { errorMessage = "The terminal session could not be started." }
    }

    private func isClosing(paneID: UUID) -> Bool {
        guard let pane = snapshot.panes[paneID], let tab = snapshot.tabs[pane.tabID] else { return false }
        return closingWindowIDs.contains(tab.windowID) || closingTabIDs.contains(tab.id)
    }

    public func recordActivity(paneID: UUID, exited: Bool = false) {
        guard let pane = snapshot.panes[paneID], let tab = snapshot.tabs[pane.tabID],
              tab.windowID != snapshot.activeWindowID else { return }
        var indicator = activity[tab.windowID] ?? WindowActivity()
        if exited { indicator.hasExit = true } else { indicator.hasOutput = true }
        if indicator != activity[tab.windowID] { activity[tab.windowID] = indicator }
    }

    public func renameWindow(_ id: UUID, name: String) async {
        do { publish(try await service.execute(.renameWindow(id: id, name: name)).snapshot) }
        catch { errorMessage = "Use a window name between 1 and 200 characters." }
    }

    public func moveWindow(_ id: UUID, offset: Int) async {
        var order = snapshot.windows.map(\.id)
        guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        do { publish(try await service.execute(.reorderWindows(ids: order)).snapshot) }
        catch { errorMessage = "The window order could not be changed." }
    }

    private func attachTerminal(_ pane: WorkspacePane) {
        let terminal = NativeTerminal(sessionID: pane.sessionID)
        terminal.view.setAccessibilityIdentifier("terminal.\(pane.id.uuidString)")
        terminal.onOutput = { [weak self] in self?.recordActivity(paneID: pane.id) }
        terminals[pane.id] = terminal
    }

    public func createTab(windowID: UUID? = nil, duplicate id: UUID? = nil, startSessions: Bool = true) async {
        guard !shuttingDown, !Task.isCancelled,
              let windowID = windowID ?? presentation.selectedWindow?.id,
              !closingWindowIDs.contains(windowID) else { return }
        if let id {
            guard snapshot.tabs[id]?.windowID == windowID, !closingTabIDs.contains(id) else { return }
        }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        do {
            let result = try await service.execute(id.map { .duplicateTab(id: $0) } ?? .createTab(windowID: windowID))
            guard !shuttingDown, !Task.isCancelled, !closingWindowIDs.contains(windowID) else { return }
            guard let tabID = result.createdTabID, let tab = result.snapshot.tabs[tabID] else { return }
            for paneID in tab.root.paneIDs {
                if let pane = result.snapshot.panes[paneID] { attachTerminal(pane) }
            }
            publish(result.snapshot)
            if startSessions {
                for paneID in tab.root.paneIDs { await start(paneID: paneID) }
            }
        } catch { errorMessage = "The tab could not be created." }
    }

    public func selectTab(_ id: UUID) async {
        do { publish(try await service.execute(.selectTab(id: id)).snapshot) }
        catch { errorMessage = "The tab could not be selected." }
    }

    public func finishTabRename(_ id: UUID, draft: String, action: TabRenameAction) async {
        guard case .commit = action else { return }
        await renameTab(id, title: draft)
    }

    public func renameTab(_ id: UUID, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do { publish(try await service.execute(.renameTab(id: id, title: trimmed)).snapshot) }
        catch { errorMessage = "Use a tab name between 1 and 200 characters." }
    }

    public func moveTab(_ id: UUID, offset: Int) async {
        guard let tab = snapshot.tabs[id], let window = snapshot.windows.first(where: { $0.id == tab.windowID }) else { return }
        var order = window.tabIDs
        guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        do { publish(try await service.execute(.reorderTabs(windowID: tab.windowID, ids: order)).snapshot) }
        catch { errorMessage = "The tab order could not be changed." }
    }

    public func deleteWindow(_ id: UUID) async {
        guard !shuttingDown, !closingWindowIDs.contains(id),
              let window = snapshot.windows.first(where: { $0.id == id }) else { return }
        closingWindowIDs.insert(id)
        defer { closingWindowIDs.remove(id) }
        let panes = Set(window.tabIDs.flatMap { snapshot.tabs[$0]?.root.paneIDs ?? [] })
        await closeResources(panes: panes, command: .deleteWindow(id: id))
        if !snapshot.windows.contains(where: { $0.id == id }) { activity.removeValue(forKey: id) }
    }

    public func closeTab(_ id: UUID) async {
        guard !shuttingDown, let tab = snapshot.tabs[id], !closingTabIDs.contains(id),
              !closingWindowIDs.contains(tab.windowID) else { return }
        closingTabIDs.insert(id)
        defer { closingTabIDs.remove(id) }
        await closeResources(panes: Set(tab.root.paneIDs), command: .deleteTab(id: id))
        if !snapshot.windows.contains(where: { $0.id == tab.windowID }) { activity.removeValue(forKey: tab.windowID) }
    }

    private func closeResources(panes: Set<UUID>, command: WorkspaceCommand) async {
        let live = panes.compactMap { terminals[$0] }.filter(\.isRunning)
        guard live.isEmpty || confirmCloseSessions(live.count) else { return }
        // Modal dialogs run a nested event loop, so recheck after confirmation.
        panes.compactMap { terminals[$0] }.filter(\.isRunning).forEach { $0.stop() }
        while pendingOperations > 0 || panes.contains(where: { terminals[$0]?.isRunning == true }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await waitForUpdates()
        guard !shuttingDown else { return }
        do {
            publish(try await service.execute(command).snapshot)
            for pane in panes { terminals.removeValue(forKey: pane) }
        } catch { errorMessage = "The sessions could not be closed." }
    }

    /// Preserve callback order across async store calls, including fast exits.
    private func enqueue(_ command: WorkspaceCommand) {
        let previous = updates
        updates = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do { self.publish(try await self.service.execute(command).snapshot) }
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
            publish(try await service.execute(.closeAllWindows).snapshot)
            terminals.removeAll()
            activity.removeAll()
            shuttingDown = false
        } catch { errorMessage = "The workspaces could not be closed." }
    }
}
