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
    public var confirmCloseSessions: (Int) -> Bool = { _ in true }
    public var confirmForceSessions: (Int) -> Bool = { _ in false }
    private var closeSummary: [String] = []
    private let closureCoordinator = SessionClosureCoordinator()
    private var closureInProgress = false
    private var closingWindowIDs = Set<UUID>()
    private var closingTabIDs = Set<UUID>()
    private var closingPaneIDs = Set<UUID>()
    @Published public private(set) var maximizedPanes: [UUID: UUID] = [:]
    private var pendingDividerResize: (splitID: UUID, ratio: Double, tabID: UUID)?
    private var dividerResizeTask: Task<Void, Never>?
    private var canvasSizes: [UUID: CanvasDimensions] = [:]
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
        confirmCloseSessions = { [weak self] in self?.showClosureConfirmation(count: $0, force: false) ?? false }
        confirmForceSessions = { [weak self] in self?.showClosureConfirmation(count: $0, force: true) ?? false }
    }

    public var presentation: WorkspacePresentation { WorkspacePresentation(snapshot: snapshot) }
    public var activeTerminal: NativeTerminal? { presentation.activePane.flatMap { terminals[$0.id] } }
    public var runningTerminals: [NativeTerminal] { terminals.values.filter(\.isRunning) }

    public func refresh() async { publish(await service.store.snapshot()) }

    /// Async command replies can resume out of order; never regress visible state.
    func publish(_ next: WorkspaceSnapshot) {
        guard next.revision >= snapshot.revision else { return }
        snapshot = next
        maximizedPanes = maximizedPanes.filter { tabID, paneID in next.tabs[tabID]?.root.paneIDs.contains(paneID) == true }
        canvasSizes = canvasSizes.filter { next.tabs[$0.key] != nil }
        if let selected = next.activeWindowID { activity.removeValue(forKey: selected) }
    }

    public func createWindow(name: String? = nil, startSession: Bool = true, fixture: Bool = false) async {
        guard !shuttingDown, !Task.isCancelled else { return }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        do {
            let result = try await service.execute(.createWindow(name: name ?? "Window \(snapshot.windows.count + 1)"))
            // Always materialize a committed result, including during a native
            // confirmation loop. Shutdown gates only the process launch.
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
                if !launchCompleted, state == .running || state == .closing, let pid = terminal?.processID {
                    launchCompleted = true
                    self?.enqueue(.completeLaunch(sessionID: request.sessionID, attemptID: request.attemptID, outcome: .started(processID: pid)))
                }
                if launchCompleted, state == .closing { self?.enqueue(.markSessionClosing(sessionID: request.sessionID)) }
            }
            terminal.onExit = { [weak self, weak terminal] code in
                guard let self, let terminal else { return }
                let command: WorkspaceCommand = !launchCompleted
                    ? .completeLaunch(sessionID: request.sessionID, attemptID: request.attemptID, outcome: .failed(message: terminal.sessionState == .failed
                        ? "The executable, directory, or environment could not be used." : "Session launch was cancelled."))
                    : .recordSessionExit(sessionID: request.sessionID, code: code)
                self.closureCoordinator.forget(sessionID: request.sessionID)
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
        return closingWindowIDs.contains(tab.windowID) || closingTabIDs.contains(tab.id) || closingPaneIDs.contains(paneID)
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
        terminal.onFocused = { [weak self] in Task { await self?.selectPane(pane.id) } }
        terminals[pane.id] = terminal
    }

    public func setCanvasSize(_ size: CanvasDimensions, tabID: UUID) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        canvasSizes[tabID] = size
    }

    public func toggleMaximize(_ paneID: UUID) async {
        guard !shuttingDown, let pane = snapshot.panes[paneID], !isClosing(paneID: paneID) else { return }
        guard await selectPane(paneID), !shuttingDown, !isClosing(paneID: paneID),
              presentation.selectedTab?.id == pane.tabID,
              snapshot.tabs[pane.tabID]?.activePaneID == paneID else { return }
        if maximizedPanes[pane.tabID] == paneID { maximizedPanes.removeValue(forKey: pane.tabID) }
        else { maximizedPanes[pane.tabID] = paneID }
    }

    public func focusPane(_ direction: PaneDirection) async {
        guard let tab = presentation.selectedTab, let canvas = canvasSizes[tab.id],
              let next = PaneGeometry(layout: tab.root, canvas: canvas).neighbor(of: tab.activePaneID, direction: direction) else { return }
        let wasMaximized = maximizedPanes[tab.id] != nil
        guard await selectPane(next), !shuttingDown, !isClosing(paneID: next),
              presentation.selectedTab?.id == tab.id,
              snapshot.tabs[tab.id]?.activePaneID == next else { return }
        if wasMaximized, maximizedPanes[tab.id] != nil { maximizedPanes[tab.id] = next }
    }

    /// Coalesce rapid pointer events while preserving the final requested position.
    public func queueDividerResize(_ splitID: UUID, ratio: Double, tabID: UUID) {
        pendingDividerResize = (splitID, ratio, tabID)
        guard dividerResizeTask == nil else { return }
        dividerResizeTask = Task { [weak self] in
            guard let self else { return }
            while let request = pendingDividerResize {
                pendingDividerResize = nil
                await resizeSplit(request.splitID, ratio: request.ratio, tabID: request.tabID, quietly: true)
            }
            dividerResizeTask = nil
        }
    }

    public func resizeSplit(_ splitID: UUID, ratio: Double, tabID: UUID, quietly: Bool = false) async {
        guard !shuttingDown, maximizedPanes[tabID] == nil, let canvas = canvasSizes[tabID] else { return }
        do { publish(try await service.execute(.resizeSplit(tabID: tabID, splitID: splitID, ratio: ratio, canvas: canvas)).snapshot) }
        catch { if !quietly { errorMessage = "This divider would make a pane too small." } }
    }

    public func resizeFocusedPane(_ direction: PaneDirection) async {
        guard let tab = presentation.selectedTab else { return }
        let axis: SplitAxis = direction == .left || direction == .right ? .x : .y
        guard let split = tab.root.enclosingSplit(paneID: tab.activePaneID, axis: axis) else { return }
        let delta = direction == .left || direction == .up ? -0.05 : 0.05
        await resizeSplit(split.id, ratio: split.ratio + delta, tabID: tab.id)
    }

    public func restartPane(_ id: UUID, startSession: Bool = true) async {
        guard !shuttingDown, !isClosing(paneID: id), let terminal = terminals[id],
              terminal.sessionState == .exited || terminal.sessionState == .failed else { return }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        await waitForUpdates()
        guard !shuttingDown, !isClosing(paneID: id), terminals[id] === terminal else { return }
        do {
            let result = try await service.execute(.restartSession(paneID: id))
            guard let pane = result.snapshot.panes[id] else { return }
            terminal.adapter.detach()
            attachTerminal(pane)
            publish(result.snapshot)
            if startSession { await start(paneID: id) }
        } catch { errorMessage = "The session could not be restarted." }
    }

    public func selectPane(_ id: UUID) async -> Bool {
        guard !shuttingDown, !isClosing(paneID: id), snapshot.panes[id] != nil else { return false }
        do {
            publish(try await service.execute(.selectPane(id: id)).snapshot)
            guard let pane = snapshot.panes[id], !isClosing(paneID: id) else { return false }
            return snapshot.tabs[pane.tabID]?.activePaneID == id
        } catch {
            if snapshot.panes[id] != nil, !isClosing(paneID: id) { errorMessage = "The pane could not be selected." }
            return false
        }
    }

    public func splitPane(_ id: UUID, axis: SplitAxis, availableCanvas: CanvasDimensions? = nil, startSession: Bool = true) async {
        guard !shuttingDown, !isClosing(paneID: id), let terminal = terminals[id] else { return }
        if let canvas = availableCanvas {
            let minimum = CanvasDimensions.minimum(for: .split(id: UUID(), axis: axis, ratio: 0.5, children: [.pane(UUID()), .pane(UUID())]))
            guard canvas.width >= minimum.width, canvas.height >= minimum.height else {
                errorMessage = "Enlarge this pane before splitting it."
                return
            }
        }
        let dimensions = terminal.getWindowSize()
        guard let size = try? TerminalSize(columns: Int(dimensions.ws_col), rows: Int(dimensions.ws_row)) else { return }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        do {
            let result = try await service.execute(.splitPane(id: id, axis: axis, availableSize: size))
            guard let newID = result.createdPaneID, let pane = result.snapshot.panes[newID] else { return }
            attachTerminal(pane)
            publish(result.snapshot)
            // The store may have committed while a close operation began. Keep
            // its surviving pane materialized, but do not launch a new process
            // inside a hierarchy that is already closing.
            if startSession, !isClosing(paneID: id), !isClosing(paneID: newID) { await start(paneID: newID) }
        } catch { errorMessage = "This pane cannot be split further. Check its size and the layout limits." }
    }

    public func closePane(_ id: UUID) async {
        guard !shuttingDown, !closureInProgress, !isClosing(paneID: id), let pane = snapshot.panes[id], let tab = snapshot.tabs[pane.tabID] else { return }
        closureInProgress = true
        defer { closureInProgress = false }
        closingPaneIDs.insert(id)
        defer { closingPaneIDs.remove(id) }
        await closeResources(panes: [id], command: .deletePane(id: id))
        if !snapshot.windows.contains(where: { $0.id == tab.windowID }) { activity.removeValue(forKey: tab.windowID) }
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
        guard !shuttingDown, !closureInProgress, !closingWindowIDs.contains(id),
              let window = snapshot.windows.first(where: { $0.id == id }) else { return }
        closureInProgress = true
        defer { closureInProgress = false }
        closingWindowIDs.insert(id)
        defer { closingWindowIDs.remove(id) }
        let panes = Set(window.tabIDs.flatMap { snapshot.tabs[$0]?.root.paneIDs ?? [] })
        await closeResources(panes: panes, command: .deleteWindow(id: id))
        if !snapshot.windows.contains(where: { $0.id == id }) { activity.removeValue(forKey: id) }
    }

    public func closeTab(_ id: UUID) async {
        guard !shuttingDown, !closureInProgress, let tab = snapshot.tabs[id], !closingTabIDs.contains(id),
              !closingWindowIDs.contains(tab.windowID) else { return }
        closureInProgress = true
        defer { closureInProgress = false }
        closingTabIDs.insert(id)
        defer { closingTabIDs.remove(id) }
        await closeResources(panes: Set(tab.root.paneIDs), command: .deleteTab(id: id))
        if !snapshot.windows.contains(where: { $0.id == tab.windowID }) { activity.removeValue(forKey: tab.windowID) }
    }

    private func prepareCloseSummary(_ panes: Set<UUID>) {
        closeSummary = panes.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            guard terminals[id]?.isRunning == true, let pane = snapshot.panes[id], let tab = snapshot.tabs[pane.tabID],
                  let window = snapshot.windows.first(where: { $0.id == tab.windowID }) else { return nil }
            return "\(window.name) / \(tab.title) / \(pane.title ?? "Terminal")"
        }
    }

    private func showClosureConfirmation(count: Int, force: Bool) -> Bool {
        guard count > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = force ? "Force stop \(count) session(s)?" : "Close \(count) terminal session(s)?"
        let summary = closeSummary.prefix(8).joined(separator: "\n")
        let more = closeSummary.count > 8 ? "\n…and \(closeSummary.count - 8) more" : ""
        alert.informativeText = (force ? "These sessions have not finished closing after two seconds.\n\n" : "Their owned local processes will stop.\n\n")
            + summary + more + "\n\nDetached or remote processes may continue running."
        alert.addButton(withTitle: force ? "Force Stop" : "Close Sessions")
        alert.addButton(withTitle: force ? "Keep Waiting" : "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func confirmAllSessionClosure() -> Bool {
        guard !shuttingDown, !closureInProgress else { return false }
        // Freeze creation before entering the native modal loop. Cancel restores
        // the gate without sending any signal or changing the workspace.
        shuttingDown = true
        prepareCloseSummary(Set(terminals.keys))
        let accepted = confirmCloseSessions(runningTerminals.count)
        if !accepted { shuttingDown = false }
        return accepted
    }

    private func finishClosure(_ panes: Set<UUID>) async -> Bool {
        let affected: [any ClosableSession] = panes.compactMap { terminals[$0] }
        var result = await closureCoordinator.close(affected, allowRunning: true)
        if case .closePending = result {
            let live = affected.filter(\.requiresTermination)
            guard !Task.isCancelled else { return false }
            if live.isEmpty {
                // The child has exited; allow bounded I/O cleanup without
                // asking the user to force-stop an already dead process.
                result = await closureCoordinator.close(affected, allowRunning: true)
            } else {
                prepareCloseSummary(Set(panes.filter { terminals[$0]?.requiresTermination == true }))
                guard confirmForceSessions(live.count) else { return false }
                result = await closureCoordinator.close(affected, allowRunning: true, force: true)
            }
        }
        guard result == .closed else { errorMessage = "Some sessions are still closing. Try Close again when they are ready."; return false }
        // Pending store/start work must complete before deleting its hierarchy.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while pendingOperations > 0, ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard pendingOperations == 0 else { errorMessage = "A session launch is still finishing. Try Close again shortly."; return false }
        await waitForUpdates()
        return !Task.isCancelled
    }

    private func closeResources(panes initialPanes: Set<UUID>, command: WorkspaceCommand) async {
        // Close gates are already set. Let operations that committed just before
        // the gate materialize their stopped panes before computing the summary.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while pendingOperations > 0, ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard pendingOperations == 0, !Task.isCancelled else {
            errorMessage = "A session launch is still finishing. Try Close again shortly."
            return
        }
        await waitForUpdates()
        let panes: Set<UUID>
        switch command {
        case .deleteWindow(let id):
            panes = Set(snapshot.windows.first(where: { $0.id == id })?.tabIDs.flatMap { snapshot.tabs[$0]?.root.paneIDs ?? [] } ?? [])
        case .deleteTab(let id): panes = Set(snapshot.tabs[id]?.root.paneIDs ?? [])
        default: panes = initialPanes
        }
        prepareCloseSummary(panes)
        let live = panes.compactMap { terminals[$0] }.filter(\.isRunning)
        guard live.isEmpty || confirmCloseSessions(live.count) else { return }
        guard await finishClosure(panes), !shuttingDown else { return }
        do {
            publish(try await service.execute(command).snapshot)
            terminals = terminals.filter { snapshot.panes[$0.key] != nil }
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

    @discardableResult
    public func shutdown() async -> Bool {
        prepareCloseSummary(Set(terminals.keys))
        stopAll()
        let closed = await finishClosure(Set(terminals.keys))
        if !closed { shuttingDown = false }
        return closed
    }

    @discardableResult
    public func closeAllWorkspaces() async -> Bool {
        guard await shutdown() else { return false }
        do {
            publish(try await service.execute(.closeAllWindows).snapshot)
            terminals.removeAll()
            activity.removeAll()
            shuttingDown = false
            return true
        } catch { errorMessage = "The workspaces could not be closed."; shuttingDown = false; return false }
    }
}
