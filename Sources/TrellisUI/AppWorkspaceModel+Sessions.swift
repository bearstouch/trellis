import AppKit
import TrellisCore
import TrellisTerminal

/// Sessions that outlive the app (FR-R03) and the opt-in scrollback file (FR-R04, FR-R05).
extension AppWorkspaceModel {
    public func setKeepSessionsRunning(_ enabled: Bool) {
        guard enabled != keepSessionsRunning else { return }
        keepSessionsRunning = enabled
        scheduleWorkspaceSave()
    }

    /// Settings showed the note about the new default (FR-R07).
    public func dismissSessionDefaultNotice() {
        guard sessionDefaultNoticePending else { return }
        sessionDefaultNoticePending = false
        scheduleWorkspaceSave()
    }

    /// Turning it off deletes every saved file at once.
    public func setRestoreScrollback(_ enabled: Bool) {
        guard enabled != restoreScrollback else { return }
        restoreScrollback = enabled
        if !enabled, let scrollbackStore { Task { await scrollbackStore.deleteAll() } }
        scheduleWorkspaceSave()
    }

    /// Runs on every launch, whatever the setting, so a kept session is never orphaned silently. Restored panes
    /// adopt their sessions by session UUID; an ended one shows its replay; the rest are offered Stop Them / Leave Running.
    /// Returns the panes that received broker output.
    func reattachBrokerSessions() async -> Set<UUID> {
        guard let sessionBroker, let listing = await sessionBroker.existingSessions() else { return [] }
        guard case .sessions(let records) = listing else {
            if confirmStopOrphans(0) { await sessionBroker.stopIncompatibleBroker() }
            return []
        }
        var replayed = Set<UUID>(), orphans: [BrokerSessionSummary] = []
        let panes = Dictionary(snapshot.panes.values.map { ($0.sessionID, $0.id) }, uniquingKeysWith: { first, _ in first })
        for record in records {
            guard let paneID = panes[record.sessionID], let terminal = terminals[paneID], terminal.sessionID == record.sessionID, terminal.sessionState == .stopped,
                await adoptBrokerSession(record, paneID: paneID, terminal: terminal, broker: sessionBroker)
            else { orphans.append(record); continue }
            replayed.insert(paneID)
        }
        for record in orphans where !record.running { sessionBroker.release(sessionID: record.sessionID) }
        let running = orphans.filter(\.running).map(\.sessionID)
        if !running.isEmpty, confirmStopOrphans(running.count) { sessionBroker.hangUp(sessionIDs: running) }
        return replayed
    }

    private func adoptBrokerSession(_ record: BrokerSessionSummary, paneID: UUID, terminal: NativeTerminal, broker: any SessionBrokerClient) async -> Bool {
        let window = terminal.getWindowSize()
        guard let size = try? TerminalSize(columns: Int(window.ws_col), rows: Int(window.ws_row)),
            let adoption = await broker.adopt(sessionID: record.sessionID, size: size),
            terminals[paneID] === terminal, terminal.sessionState == .stopped, let launch = snapshot.sessions[record.sessionID]?.launch
        else { return false }
        guard let pid = adoption.processID else {
            terminal.showEndedSession(replay: adoption.replay, exitCode: adoption.exitCode)
            broker.release(sessionID: record.sessionID)
            return true
        }
        do { publish(try await service.execute(.adoptRunningSession(sessionID: record.sessionID, processID: pid)).snapshot) } catch { return false }
        installLifecycle(terminal, paneID: paneID, sessionID: record.sessionID, attemptID: nil)
        // An SSH pane observes its unverified marks again; a local shell gets its nonce back from the broker.
        if shellIntegrationEnabled, Self.isRemote(launch) { terminal.observeRemoteShellMarks() }
        guard terminals[paneID] === terminal, terminal.adopt(adoption) else {
            enqueue(.recordSessionExit(sessionID: record.sessionID, code: nil))
            return false
        }
        return true
    }

    /// Shows each stopped pane's saved text; files of other sessions are deleted.
    func restoreScrollbackText(skipping panes: Set<UUID>) async {
        guard let scrollbackStore else { return }
        guard restoreScrollback else { await scrollbackStore.deleteAll(); return }
        var kept = Set<UUID>()
        // Remote workspace panes get their host helper's replay instead (FR-RW09), so their saved text would show twice.
        for pane in snapshot.panes.values where !panes.contains(pane.id) && snapshot.sessions[pane.sessionID]?.launch.remoteHostID == nil {
            guard let terminal = terminals[pane.id], terminal.sessionID == pane.sessionID, terminal.sessionState == .stopped,
                let saved = await scrollbackStore.load(sessionID: pane.sessionID)
            else { continue }
            terminal.showRestoredOutput(saved.text, savedAt: saved.savedAt)
            kept.insert(pane.sessionID)
        }
        await scrollbackStore.retain(kept)
    }

    /// FR-R04: every pane's retained plain text, redacted, in window and tab order. Never journaled or exported.
    public func saveScrollback() async {
        guard restoreScrollback, let scrollbackStore, !persistenceReadOnly, recoveryMessage == nil else { return }
        var texts: [(sessionID: UUID, text: String)] = []
        for window in snapshot.windows {
            for paneID in window.tabIDs.flatMap({ snapshot.tabs[$0]?.root.paneIDs ?? [] }) {
                guard let pane = snapshot.panes[paneID], let terminal = terminals[paneID], terminal.sessionID == pane.sessionID else { continue }
                var text = terminal.retainedText
                while let last = text.last, last.isWhitespace { text.removeLast() }
                if !text.isEmpty { texts.append((pane.sessionID, text)) }
            }
        }
        await scrollbackStore.replaceAll(texts)
    }

    /// ⌘Q. With the setting on (the default) and every running session in the broker, quits without asking: nothing
    /// stops. With some sessions outside the broker, offers Keep Running; with the setting off, the usual confirmation.
    public func confirmQuit() -> QuitChoice {
        guard !shuttingDown, !closureInProgress else { return .cancel }
        let running = runningTerminals
        let kept = running.filter(\.survivesQuit).count
        guard keepsSessionsAtQuit, kept > 0 else { return confirmAllSessionClosure() ? .stopSessions : .cancel }
        cancelPaste()
        shuttingDown = true
        if kept == running.count { return .keepRunning }
        let choice = confirmKeepRunning(kept, running.count - kept)
        if choice == .cancel { shuttingDown = false }
        return choice
    }

    /// Keep Running: broker sessions get no signal at all; local ones close as usual. Then the scrollback and the
    /// workspace are saved and the broker connection is detached. False cancels the quit and restores signalling.
    public func detachForQuit() async -> Bool {
        cancelPaste()
        shuttingDown = true
        let kept = terminals.values.filter { $0.isRunning && $0.survivesQuit }
        kept.forEach { $0.prepareForKeepRunning() }
        let local = Set(terminals.filter { $0.value.isRunning && !$0.value.survivesQuit }.keys)
        prepareCloseSummary(local)
        for id in local { terminals[id]?.stop() }
        func cancel() -> Bool {
            kept.forEach { $0.prepareForKeepRunning(false) }
            shuttingDown = false
            return false
        }
        guard await finishClosure(local) else { return cancel() }
        await saveScrollback()
        guard await flushWorkspaceSave() else { return cancel() }
        await sessionBroker?.detach()
        remoteReconnector.cancelAll()
        remoteHosts?.closeWorkspaceLinks()
        return true
    }

    func showKeepRunningConfirmation(kept: Int, stopping: Int) -> QuitChoice {
        let alert = NSAlert()
        alert.messageText = "Keep \(kept) session(s) running after Trellis quits?"
        alert.informativeText =
            "Kept sessions continue in the background and reconnect when Trellis opens again. They end if you log out or restart your Mac."
            + (stopping > 0 ? "\n\n\(stopping) session(s) started before Keep Running was turned on will stop." : "")
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Stop Sessions")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .keepRunning
        case .alertSecondButtonReturn: return .stopSessions
        default: return .cancel
        }
    }

    func showOrphanConfirmation(count: Int) -> Bool {
        let alert = NSAlert()
        if count == 0 {
            alert.messageText = "A session broker from another Trellis version is still running."
            alert.informativeText = "Its sessions can't be reconnected. Stop them, or leave them running in the background."
        } else {
            alert.messageText = "\(count) session(s) from an earlier run are still running."
            alert.informativeText = "They aren't part of the restored workspace. Stop them, or leave them running in the background; Trellis asks again next time."
        }
        alert.addButton(withTitle: "Stop Them")
        alert.addButton(withTitle: "Leave Running")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
