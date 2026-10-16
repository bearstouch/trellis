import Foundation
import TrellisCore
import TrellisTerminal

public enum AutomationModelError: Error, Equatable, Sendable {
    /// Restoring, recovering, shutting down, or another closure is in progress.
    case unavailable
    case store(WorkspaceError)
}

public enum AutomationCloseResult: Equatable, Sendable {
    case closed
    case confirmationRequired(sessionIDs: [UUID])
    case closePending(sessionIDs: [UUID])
}

/// Non-interactive entry points for automation. They use the same command
/// service, terminal attachment, and closure policy as the UI, but never show
/// alerts or confirmation dialogs; failures are returned to the caller.
extension AppWorkspaceModel {
    private func requireAvailable() throws(AutomationModelError) {
        guard !isRestoring, recoveryMessage == nil, !shuttingDown else { throw .unavailable }
    }

    /// Executes one command (plus an optional follow-up, rolled back together)
    /// atomically with an optional revision expectation, materializes terminals
    /// for created panes, and publishes the result.
    public func automationExecute(
        _ command: WorkspaceCommand, expecting: ResourceExpectation? = nil, then follow: (@Sendable (WorkspaceCommandResult) -> WorkspaceCommand?)? = nil
    ) async throws(AutomationModelError) -> WorkspaceCommandResult {
        try requireAvailable()
        // Same gates as the UI: nothing new is added inside a closing hierarchy.
        switch command {
        case .createTab(let windowID): guard !closingWindowIDs.contains(windowID) else { throw .unavailable }
        case .splitPane(let id, _, _): guard !isClosing(paneID: id) else { throw .unavailable }
        default: break
        }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        let result: WorkspaceCommandResult
        do {
            if let follow { result = try await service.execute(command, expecting: expecting, then: follow) } else { result = try await service.execute(command, expecting: expecting) }
        } catch let error as WorkspaceError {
            throw .store(error)
        } catch {
            throw .store(.invalidState("Command failed"))
        }
        publish(result.snapshot)
        // Attach from the published state: an out-of-order older result must not
        // resurrect terminals for panes that a newer closure already removed.
        for pane in snapshot.panes.values where terminals[pane.id] == nil { attachTerminal(pane) }
        return result
    }

    /// Closes panes, tabs, or windows for automation. Running sessions require
    /// `allowRunning`; force is honored only after the graceful window, exactly
    /// as in the UI. Nothing here blocks on a dialog.
    public func automationClose(_ command: WorkspaceCommand, allowRunning: Bool, force: Bool, expecting: ResourceExpectation? = nil) async throws(AutomationModelError) -> AutomationCloseResult {
        try requireAvailable()
        guard !closureInProgress else { throw .unavailable }
        var windowGate: UUID?, tabGate: UUID?, paneGate: UUID?
        switch command {
        case .deletePane(let id):
            guard snapshot.panes[id] != nil, !isClosing(paneID: id) else { throw .store(.notFound) }
            paneGate = id
        case .deleteTab(let id):
            guard snapshot.tabs[id] != nil else { throw .store(.notFound) }
            tabGate = id
        case .deleteWindow(let id):
            guard snapshot.windows.contains(where: { $0.id == id }) else { throw .store(.notFound) }
            windowGate = id
        default: throw .store(.invalidTransition)
        }
        // Mirror the UI closure: set gates first, let committed creations and
        // launches settle, then compute the affected panes from current state.
        closureInProgress = true
        defer { closureInProgress = false }
        if let windowGate { closingWindowIDs.insert(windowGate) }
        if let tabGate { closingTabIDs.insert(tabGate) }
        if let paneGate { closingPaneIDs.insert(paneGate) }
        defer {
            if let windowGate { closingWindowIDs.remove(windowGate) }
            if let tabGate { closingTabIDs.remove(tabGate) }
            if let paneGate { closingPaneIDs.remove(paneGate) }
        }
        guard await settlePendingOperations() else { throw .unavailable }
        await waitForUpdates()
        let current = await service.store.snapshot()
        publish(current)
        // A stale revision must fail before any session is signaled.
        do { try expecting?.verify(in: current) } catch let error as WorkspaceError { throw .store(error) } catch { throw .store(.invalidState("Close failed")) }
        let panes: Set<UUID>
        switch command {
        case .deleteWindow(let id):
            guard let window = current.windows.first(where: { $0.id == id }) else { throw .store(.notFound) }
            panes = Set(window.tabIDs.flatMap { current.tabs[$0]?.root.paneIDs ?? [] })
        case .deleteTab(let id):
            guard let tab = current.tabs[id] else { throw .store(.notFound) }
            panes = Set(tab.root.paneIDs)
        default:
            guard let id = paneGate, current.panes[id] != nil else { throw .store(.notFound) }
            panes = [id]
        }
        let live = panes.compactMap { terminals[$0] }.filter(\.isRunning)
        let liveIDs = live.map(\.sessionID).sorted { $0.uuidString < $1.uuidString }
        guard live.isEmpty || allowRunning else { return .confirmationRequired(sessionIDs: liveIDs) }
        if let paste = pendingPaste, panes.contains(paste.target.paneID) { cancelPaste() }
        let affected: [any ClosableSession] = panes.compactMap { terminals[$0] }
        var outcome = await closureCoordinator.close(affected, allowRunning: true, force: force)
        // The children exited; allow bounded I/O cleanup, as the UI does.
        if case .closePending = outcome, !affected.contains(where: \.requiresTermination) {
            outcome = await closureCoordinator.close(affected, allowRunning: true)
        }
        guard outcome == .closed else { return .closePending(sessionIDs: liveIDs) }
        guard await settlePendingOperations(), !shuttingDown else { return .closePending(sessionIDs: liveIDs) }
        await waitForUpdates()
        do {
            publish(try await service.execute(command, expecting: expecting).snapshot)
        } catch let error as WorkspaceError {
            throw .store(error)
        } catch {
            throw .store(.invalidState("Close failed"))
        }
        for id in panes where snapshot.panes[id] == nil { terminals[id]?.adapter.detach() }
        terminals = terminals.filter { snapshot.panes[$0.key] != nil }
        return .closed
    }

    /// Waits up to two seconds for in-flight store and launch work.
    private func settlePendingOperations() async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while pendingOperations > 0, ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return pendingOperations == 0
    }

    /// The live terminal size, used by the domain split-size rules.
    public func automationTerminalSize(_ paneID: UUID) -> TerminalSize? {
        guard let size = terminals[paneID]?.getWindowSize() else { return nil }
        return try? TerminalSize(columns: Int(size.ws_col), rows: Int(size.ws_row))
    }

    /// The canvas used for divider limits; a generous default when the tab has
    /// never been laid out (for example, an API-only background tab).
    public func automationCanvas(_ tabID: UUID) -> CanvasDimensions {
        canvasSizes[tabID] ?? snapshot.tabs[tabID].map { CanvasDimensions.minimum(for: $0.root).fitting(width: 4096, height: 4096) }
            ?? CanvasDimensions(width: 4096, height: 4096)
    }

    /// Like the UI toggle, a maximized pane is also the focused pane.
    public func automationSetMaximized(_ paneID: UUID, _ maximized: Bool) async throws(AutomationModelError) {
        try requireAvailable()
        guard let pane = snapshot.panes[paneID], !isClosing(paneID: paneID) else { throw .store(.notFound) }
        guard maximized else {
            if maximizedPanes[pane.tabID] == paneID { maximizedPanes.removeValue(forKey: pane.tabID) }
            return
        }
        _ = try await automationExecute(.selectPane(id: paneID))
        guard snapshot.panes[paneID] != nil, !isClosing(paneID: paneID) else { throw .store(.notFound) }
        maximizedPanes[pane.tabID] = paneID
    }

    /// Starts stopped panes created by automation (only after authorization).
    public func automationStart(_ paneIDs: [UUID]) async {
        for id in paneIDs { await start(paneID: id, quietly: true) }
    }
}
