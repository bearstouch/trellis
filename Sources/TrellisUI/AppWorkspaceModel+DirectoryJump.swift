import AppKit
import Foundation
import TrellisCore

/// Directory jump (FR-DJ01–FR-DJ09): remembers where shells have been, and goes back there. Every new pane takes the
/// path `connect` and `launchAgent` use, so a jump adds no mutation of its own.
extension AppWorkspaceModel {
    /// Reads the history in, dropping entries of deleted hosts. `hosts` nil: the host library couldn't be read, so no
    /// entry is known to be stale and none is dropped (FR-DJ08).
    public func loadDirectoryHistory(hosts: [SavedHost]?) async {
        guard let directoryHistory else { return }
        directoryEntries = if let hosts { await directoryHistory.retain(hosts: Set(hosts.map(\.id))) } else { await directoryHistory.all() }
    }

    public func setDirectoryHistoryEnabled(_ enabled: Bool) {
        guard enabled != directoryHistoryEnabled else { return }
        directoryHistoryEnabled = enabled
        preferences.set(enabled, forKey: "terminal.directoryHistory")
    }

    /// Asks first (FR-DJ08). A file that can't be deleted, or a newer version's, is reported rather than hidden.
    public func clearDirectoryHistory() async {
        guard confirmClearDirectoryHistory() else { return }
        directoryEntries = []
        guard let directoryHistory else { return }
        // What each session last reported is kept, so the folder a shell is sitting in doesn't come straight back.
        let cleared = await directoryHistory.clear()
        // Read back: a visit recorded just before the clear may have published its older list meanwhile.
        directoryEntries = await directoryHistory.all()
        if !cleared { errorMessage = L("The directory history file could not be deleted, so its entries will return at the next launch.") }
    }

    func showClearDirectoryHistoryConfirmation() -> Bool {
        let alert = NSAlert()
        alert.messageText = L("Clear the directory history?")
        alert.informativeText = L("Trellis forgets every directory it remembers, on this Mac and on your hosts. This can't be undone.")
        alert.addButton(withTitle: L("Clear History"))
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Called once a pane's shell state has changed. A replayed prompt (FR-R03) updates what the session last reported,
    /// so the first live prompt in the same directory isn't a visit either.
    func recordDirectoryVisit(paneID: UUID) {
        guard let terminal = terminals[paneID] else { return }
        let sessionID = terminal.sessionID
        guard let machine = directoryMachine(paneID: paneID), let path = machine == .local ? currentDirectory(paneID: paneID) : remoteWorkingDirectory(paneID: paneID),
            lastRecordedDirectories[sessionID] != path
        else { return }
        lastRecordedDirectories[sessionID] = path
        guard directoryHistoryEnabled, !terminal.isReplaying, let directoryHistory else { return }
        Task {
            if let entries = await directoryHistory.record(path: path, on: machine) { directoryEntries = entries }
        }
    }

    /// The machine a pane's verified paths belong to; nil for a plain SSH pane, whose paths aren't verified (FR-SI09).
    func directoryMachine(paneID: UUID) -> ProjectTarget? {
        guard let pane = snapshot.panes[paneID], let launch = snapshot.sessions[pane.sessionID]?.launch else { return nil }
        if let host = launch.remoteHostID { return .host(host) }
        return Self.isRemote(launch) ? nil : .local
    }

    /// ⌘J: the palette, already inside Jump to Directory (FR-DJ05).
    public func openDirectoryJump() {
        openCommandPalette()
        enterCommandPaletteScope(.directories)
    }

    // MARK: Rows (FR-DJ05)

    /// Ranked, the focused pane's machine first. A deleted host's rows are hidden until the next launch drops them.
    var directoryPaletteItems: [CommandPaletteItem] {
        let hosts = Dictionary(commandPaletteHosts().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let current = presentation.activePane.flatMap { directoryMachine(paneID: $0.id) }
        let usable = directoryEntries.filter { entry in
            switch entry.target {
            case .local: true
            case .host(let id): remoteHosts != nil && hosts[id] != nil
            case nil: false
            }
        }
        // One time per opening, so rows don't change (and the search cache isn't missed) while typing.
        let now = commandPaletteOpenedAt ?? activityNow()
        // Ranked again: the copy was ranked at the last visit, and scores fall with time.
        let ranked = DirectoryHistoryEntry.ranked(usable, now: now)
        let ordered = ranked.filter { $0.target == current } + ranked.filter { $0.target != current }
        let home = NSHomeDirectory()
        return ordered.enumerated()
            .map { index, entry in
                let machine: String
                if case .host(let id) = entry.target { machine = hosts[id] ?? L("Missing host") } else { machine = L("Local") }
                let local = entry.target == .local
                let title = local && (entry.path == home || entry.path.hasPrefix(home + "/")) ? "~" + entry.path.dropFirst(home.count) : entry.path
                return CommandPaletteItem(
                    target: .directory(machine: entry.machine, path: entry.path), kind: .directory, title: title,
                    subtitle: "\(machine) · " + (entry.visits == 1 ? L("1 visit") : L("%d visits", entry.visits)) + " · \(entry.lastVisitDescription(now: now))",
                    keywords: [entry.path], groupID: entry.machine, groupTitle: machine, boost: max(0, 10 - index))
            }
    }

    // MARK: Jumping (FR-DJ06, FR-DJ07)

    func jumpToDirectory(path: String, machine key: String, modifier: CommandPaletteModifier) async {
        guard !isRestoring, recoveryMessage == nil, !shuttingDown, let target = ProjectTarget(key: key) else { return }
        switch target {
        case .local:
            // Only local paths are ever looked at here (FR-DJ07).
            switch await localDirectoryAnswer(path) {
            case true?: break
            case false?:
                errorMessage = L("“%@” is no longer available, so it was removed from the directory history.", path)
                if let directoryHistory { directoryEntries = await directoryHistory.remove(path: path, on: .local) }
                return
            case nil:
                errorMessage = L("“%@” isn't responding, so nothing was opened.", path)
                return
            }
        case .host(let id):
            guard remoteHosts != nil, commandPaletteHosts().contains(where: { $0.id == id }) else {
                errorMessage = L("That directory's host is no longer saved.")
                return
            }
        }
        // Read after the check, which can take a while: the focus may have moved.
        if let focused = presentation.activePane?.id, directoryMachine(paneID: focused) == target {
            switch modifier {
            case .none: if typeChangeDirectory(path, paneID: focused) { return }
            case .option:
                await splitForDirectory(path, target: target, beside: focused)
                return
            case .command: break
            }
        }
        await openTabForDirectory(path, target: target)
    }

    /// Off the main thread and bounded, because a row can lead to a dead share (a symbolic link is recorded as it reads,
    /// FR-DJ04) and a look at one never returns. Nil when there's no answer in time. On a dispatch queue, as a blocked
    /// thread must not take one from the concurrency pool.
    private func localDirectoryAnswer(_ path: String) async -> Bool? {
        let files = directoryJumpFiles, timeout = directoryJumpTimeout
        let (answers, answer) = AsyncStream.makeStream(of: Bool?.self)
        DispatchQueue.global(qos: .userInitiated).async {
            answer.yield(files.isAccessibleDirectory(path)); answer.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            answer.yield(nil); answer.finish()
        }
        defer { timer.cancel() }
        for await first in answers { return first }
        return nil
    }

    /// Types `cd` only when the shell is verified idle at a prompt (FR-TK05). False sends nothing and the caller opens a
    /// tab instead. Unlike a task, a `cd` isn't followed as a run: it isn't something to watch or stop.
    private func typeChangeDirectory(_ path: String, paneID: UUID) -> Bool {
        guard taskAvailability(paneID: paneID) == .ready, let terminal = terminals[paneID], let shell = taskShell(paneID: paneID),
            let line = TaskCommand.changeDirectoryLine(path, kind: shell.kind)
        else { return false }
        // Already there: a Return that changes nothing shouldn't clear what's half-typed at the prompt.
        let here = shellStates[paneID]?.currentDirectory.map(DirectorySkipRules.normalized)
        if here == path { return true }
        do { try terminal.adapter.send(Data(("\u{05}\u{15}" + line + "\r").utf8)) } catch { return false }
        return true
    }

    private func splitForDirectory(_ path: String, target: ProjectTarget, beside focused: UUID) async {
        // Match the pane split controls: a hidden split would hide the new shell.
        guard let tab = presentation.selectedTab, maximizedPanes[tab.id] == nil else {
            errorMessage = L("Restore panes before opening a directory in a split.")
            return
        }
        guard let paneID = await splitPane(focused, axis: .x, startSession: false) else { return }
        await startDirectoryPane(paneID, path: path, target: target)
    }

    /// In the space that runs on the row's machine, never one whose new panes would start elsewhere (FR-DJ07).
    func openTabForDirectory(_ path: String, target: ProjectTarget) async {
        let hostID: UUID? = if case .host(let id) = target { id } else { nil }
        let matching = snapshot.spaces.filter { $0.remoteHostID == hostID && !closingSpaceIDs.contains($0.id) }
        guard let space = matching.first(where: { $0.id == snapshot.activeSpaceID }) ?? matching.first else {
            if let hostID {
                guard let host = commandPaletteHosts().first(where: { $0.id == hostID }) else { return }
                await openRemoteWorkspace(host: host, directory: path)
            } else if let created = await createSpace(startSession: false), let space = snapshot.spaces.first(where: { $0.id == created }),
                let paneID = snapshot.tabs[space.activeTabID]?.activePaneID
            {
                await startDirectoryPane(paneID, path: path, target: target)
            }
            return
        }
        if space.id != snapshot.activeSpaceID { await selectSpace(space.id) }
        guard let tabID = await createTab(spaceID: space.id, startSessions: false), let paneID = snapshot.tabs[tabID]?.activePaneID else { return }
        await startDirectoryPane(paneID, path: path, target: target)
    }

    private func startDirectoryPane(_ paneID: UUID, path: String, target: ProjectTarget) async {
        guard snapshot.panes[paneID] != nil, !isClosing(paneID: paneID), !shuttingDown else { return }
        let launch: SessionLaunch =
            switch target {
            case .local: .shell(directory: path)
            case .host(let id): .remoteShell(hostID: id, directory: path)
            }
        do {
            publish(try await service.execute(.configureStoppedSession(paneID: paneID, launch: launch)).snapshot)
        } catch {
            errorMessage = L("The new pane could not be prepared.")
            return
        }
        await start(paneID: paneID)
    }
}
