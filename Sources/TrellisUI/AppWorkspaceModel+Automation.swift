import Foundation
import TrellisControl
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

    /// Starts one stopped pane, optionally reconfiguring its launch first.
    /// Returns once the launch attempt resolves (running or failed).
    public func automationStartSession(_ paneID: UUID, launch: SessionLaunch?, environment: [String: String]) async throws(AutomationModelError) {
        try requireAvailable()
        guard let pane = snapshot.panes[paneID], let terminal = terminals[paneID] else { throw .store(.notFound) }
        guard !isClosing(paneID: paneID), terminal.sessionState == .stopped, snapshot.sessions[pane.sessionID]?.state == .stopped else {
            throw .store(.invalidTransition)
        }
        if let launch {
            _ = try await automationExecute(.configureStoppedSession(paneID: paneID, launch: launch))
            // A fresh descriptor replaces a restored process that needed configuration.
            unconfiguredPaneIDs.remove(paneID)
        } else if unconfiguredPaneIDs.contains(paneID) {
            throw .store(.invalidState("This restored pane needs a launch descriptor before it can start."))
        }
        await start(paneID: paneID, quietly: true, environment: environment)
    }

    /// Replaces a pane's session. A running session needs `allowRunning` and is
    /// closed through the shared closure policy first; nothing is retried.
    public func automationRestart(_ paneID: UUID, allowRunning: Bool, force: Bool) async throws(AutomationModelError) -> AutomationCloseResult {
        try requireAvailable()
        guard snapshot.panes[paneID] != nil, let terminal = terminals[paneID], !isClosing(paneID: paneID) else { throw .store(.notFound) }
        if terminal.isRunning {
            guard allowRunning else { return .confirmationRequired(sessionIDs: [terminal.sessionID]) }
            var outcome = await closureCoordinator.close([terminal], allowRunning: true, force: force)
            if case .closePending = outcome, !terminal.requiresTermination {
                outcome = await closureCoordinator.close([terminal], allowRunning: true)
            }
            guard outcome == .closed else { return .closePending(sessionIDs: [terminal.sessionID]) }
            // The exit is recorded asynchronously; let it reach the store first.
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while snapshot.panes[paneID].flatMap({ snapshot.sessions[$0.sessionID] }).map({ [.exited, .failed].contains($0.state) }) != true,
                ProcessInfo.processInfo.systemUptime < deadline
            {
                await waitForUpdates()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        guard terminal.sessionState == .exited || terminal.sessionState == .failed else { throw .store(.invalidTransition) }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        await waitForUpdates()
        guard !shuttingDown, !isClosing(paneID: paneID), terminals[paneID] === terminal else { throw .unavailable }
        let result: WorkspaceCommandResult
        do {
            result = try await service.execute(.restartSession(paneID: paneID))
        } catch let error as WorkspaceError {
            throw .store(error)
        } catch {
            throw .store(.invalidTransition)
        }
        guard let pane = result.snapshot.panes[paneID] else { throw .store(.notFound) }
        terminal.adapter.detach()
        attachTerminal(pane)
        publish(result.snapshot)
        return .closed
    }

    public enum InputFailure: Error, Equatable, Sendable { case notFound, notRunning, queueFull, failed }

    /// Writes bytes to a running session; `paste` applies negotiated bracketed framing.
    /// Never blocks on UI review: the grant authorizes input.
    public func automationSendInput(sessionID: UUID, data: Data, paste: Bool) throws(InputFailure) {
        guard let terminal = terminals.values.first(where: { $0.sessionID == sessionID }) else { throw .notFound }
        guard terminal.sessionState == .running else { throw .notRunning }
        // Queued bytes can fail after the call returns (e.g. the process exits); the caller inspects state instead.
        automationInputSessionIDs = automationInputSessionIDs.filter { snapshot.sessions[$0] != nil }.union([sessionID])
        do {
            if paste {
                try terminal.paste(TerminalPastePlan(input: .text(String(decoding: data, as: UTF8.self)), shell: nil))
            } else {
                try terminal.adapter.send(data)
            }
        } catch TerminalAdapterError.inputQueueFull {
            throw .queueFull
        } catch TerminalAdapterError.inputClosed {
            throw .notRunning
        } catch {
            throw .failed
        }
    }
}

// MARK: - Declarative layouts (S026)

extension AppWorkspaceModel {
    private var layoutBindingsURL: URL? { persistence?.directory.appendingPathComponent("layout-bindings.json") }

    /// Key bindings for a namespace (empty when the namespace is new). An
    /// unreadable file fails closed: it is never treated as empty or overwritten,
    /// since that would duplicate every managed resource on the next apply.
    public func layoutBindings(_ namespace: String) throws(AutomationModelError) -> [String: LayoutBinding] {
        if layoutNamespaces == nil {
            do {
                let stored = try layoutBindingsURL.flatMap { try OwnerOnlyFile.read($0, limit: 4_194_304) }
                layoutNamespaces = try stored.map { try JSONDecoder().decode([String: [String: LayoutBinding]].self, from: $0) } ?? [:]
            } catch { throw .store(.invalidState("Saved layout bindings could not be read, so layouts cannot be planned or applied.")) }
        }
        return layoutNamespaces?[namespace] ?? [:]
    }

    /// Records the namespace bindings durably, then commits the planned layout
    /// atomically against its base revision, so a committed layout always has
    /// its bindings. Bindings to resources that no longer exist are pruned.
    public func automationApplyLayout(_ plan: LayoutPlan, namespace: String) async throws(AutomationModelError) -> WorkspaceCommandResult {
        guard let target = plan.target else { throw .store(.invalidState("The layout plan cannot be applied")) }
        // One apply at a time, so pruning never drops another apply's uncommitted bindings.
        guard !layoutApplyInFlight else { throw .unavailable }
        // Never add to, or edit inside, a window that is being closed.
        guard target.windows.allSatisfy({ !closingWindowIDs.contains($0.id) }), target.tabs.keys.allSatisfy({ !closingTabIDs.contains($0) }) else {
            throw .unavailable
        }
        layoutApplyInFlight = true
        defer { layoutApplyInFlight = false }
        let previous = try layoutBindings(namespace)
        try saveLayoutBindings(namespace, plan.bindings)
        do { return try await automationExecute(.applyLayout(target: target), expecting: .workspace(revision: plan.baseRevision)) } catch {
            try? saveLayoutBindings(namespace, previous)
            throw error
        }
    }

    private func saveLayoutBindings(_ namespace: String, _ bindings: [String: LayoutBinding]) throws(AutomationModelError) {
        var namespaces = (layoutNamespaces ?? [:]).mapValues { LayoutPlanner.live($0, in: snapshot) }
        namespaces[namespace] = bindings.isEmpty ? nil : bindings
        namespaces = namespaces.filter { !$0.value.isEmpty }
        if let url = layoutBindingsURL {
            do { try OwnerOnlyFile.publish(try JSONEncoder().encode(namespaces), to: url) } catch {
                throw .store(.invalidState("Layout bindings could not be saved, so the layout was not applied."))
            }
        }
        layoutNamespaces = namespaces
    }
}

// MARK: - Theme control (S029)

public enum AutomationThemeError: Error, Equatable, Sendable {
    case invalid(ThemeValidationError)
    case library(ThemeLibraryError)
    case unavailable
    case mismatchedSlot(String)
    case notFound(String)
    case conflict(expected: UInt64, actual: UInt64)
}

extension AppWorkspaceModel {
    /// Installs a validated theme with the library's replacement and built-in
    /// rules. Unlike the UI's Save & Use, it never changes the selection.
    public func automationInstallTheme(_ data: Data, replace: Bool) async throws(AutomationThemeError) -> ThemeDocument {
        guard let themeLibrary, !themeBusy, !isRestoring, !shuttingDown else { throw .unavailable }
        let document: ThemeDocument
        do { document = try ThemeValidator.validate(data) } catch let error as ThemeValidationError { throw .invalid(error) } catch { throw .unavailable }
        themeBusy = true
        pendingOperations += 1
        defer { themeBusy = false; pendingOperations -= 1 }
        do {
            themeCatalog = try await themeLibrary.install(document.encoded(), replace: replace)
        } catch let error as ThemeLibraryError {
            throw .library(error)
        } catch {
            throw .unavailable
        }
        // A replaced theme that is in use recolors terminals (color-only path); a
        // replacement with the other appearance can reset a slot, which must persist.
        reconcileThemeSelections()
        refreshEffectiveTheme()
        scheduleWorkspaceSave()
        return document
    }

    public func automationDeleteTheme(_ id: String) async throws(AutomationThemeError) {
        guard let themeLibrary, !themeBusy, !isRestoring, !shuttingDown else { throw .unavailable }
        themeBusy = true
        pendingOperations += 1
        defer { themeBusy = false; pendingOperations -= 1 }
        do { themeCatalog = try await themeLibrary.delete(id) } catch let error as ThemeLibraryError { throw .library(error) } catch { throw .unavailable }
        if previewedTheme?.id == id { cancelThemePreview() }
        reconcileThemeSelections()
        refreshEffectiveTheme()
        scheduleWorkspaceSave()
    }

    /// Mode and slot selection only; terminals get colors, never a restart.
    public func automationSetAppearance(mode: ChromeMode?, lightThemeID: String?, darkThemeID: String?, expectedRevision: UInt64?) throws(AutomationThemeError) {
        guard !isRestoring, !shuttingDown, !themeBusy else { throw .unavailable }
        if let expectedRevision, expectedRevision != appearanceRevision { throw .conflict(expected: expectedRevision, actual: appearanceRevision) }
        for (id, slot) in [(lightThemeID, ThemeAppearance.light), (darkThemeID, .dark)] {
            guard let id else { continue }
            guard let theme = allThemes.first(where: { $0.id == id }) else { throw .notFound(id) }
            guard theme.appearance == slot else { throw .mismatchedSlot("Theme '\(id)' is a \(theme.appearance.rawValue) theme and cannot be used for the \(slot.rawValue) slot.") }
        }
        var settings = appearance
        if let mode { settings.chromeMode = mode }
        if let lightThemeID { settings.lightThemeID = lightThemeID }
        if let darkThemeID { settings.darkThemeID = darkThemeID }
        guard settings != appearance else { return }
        _ = applyAppearance(settings)
    }
}
