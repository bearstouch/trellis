import Foundation
import TrellisControl
import TrellisCore

/// Protocol 2 live-state events (docs/api/events.md), built where the state the UI shows changes: input waits,
/// progress, busy tabs, agent states, shell marks, task runs, remote links and project launches. Each emitter runs only
/// when the state actually changed and `onLiveEvents` is set, so nothing here runs per output chunk; the hub coalesces
/// live status per resource. An event whose pane is already gone isn't built (pane.deleted covers it), so nothing is
/// sent without the space that scopes it.
extension AppWorkspaceModel {
    private func emitLive(_ events: [EventDraftV2]) {
        guard !events.isEmpty, let onLiveEvents else { return }
        onLiveEvents(events)
    }

    private func liveRef(_ paneID: UUID) -> PaneRefV2? { PaneRefV2(pane: paneID, in: snapshot) }

    /// Changed keys in a stable order, so a batch reads the same every time.
    private static func changedKeys<Value: Equatable>(_ old: [UUID: Value], _ new: [UUID: Value]) -> [UUID] {
        Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.sorted { $0.uuidString < $1.uuidString }
    }

    // MARK: Attention (FR-T05, FR-T06, FR-T09)

    func liveInputWaitsChanged(from old: [UUID: InputWaitReason]) {
        guard onLiveEvents != nil else { return }
        emitLive(Self.changedKeys(old, inputWaits).compactMap { id in liveRef(id).map { .needsInput($0, reason: inputWaits[id]) } })
    }

    func liveProgressChanged(from old: [UUID: TerminalProgress]) {
        guard onLiveEvents != nil else { return }
        emitLive(Self.changedKeys(old, progress).compactMap { id in liveRef(id).map { .progress($0, progress[id]) } })
    }

    func liveBusyChanged(from old: Set<UUID>) {
        guard onLiveEvents != nil else { return }
        let changed = old.symmetricDifference(busyTabIDs).sorted { $0.uuidString < $1.uuidString }
        emitLive(changed.compactMap { id in snapshot.tabs[id].map { .tabBusy(tab: id, space: $0.spaceID, busy: busyTabIDs.contains(id)) } })
    }

    /// Maximizing changes a pane (its revision moves) but not the snapshot, so it is reported here.
    func liveMaximizedChanged(from old: [UUID: UUID]) {
        guard onLiveEvents != nil else { return }
        let panes = Set(old.values).symmetricDifference(Set(maximizedPanes.values)).sorted { $0.uuidString < $1.uuidString }
        emitLive(
            panes.compactMap { id in
                liveRef(id).map {
                    EventDraftV2(
                        "pane.updated", kind: "pane", id: id, spaceID: $0.space, data: ["tabId": ConventionsV2.idJSON($0.tab), "changed": .array([.string("maximized")])],
                        related: [$0.session, $0.tab])
                }
            })
    }

    // MARK: Shell integration (FR-SI)

    /// One event per mark: a command started or finished, or the folder changed. Never the command line or program name.
    /// Replayed marks (FR-R03) describe what happened while Trellis was closed, so they aren't reported.
    func liveShellChanged(paneID: UUID, event: ShellIntegrationEvent, from before: ShellIntegrationState?, to state: ShellIntegrationState) {
        guard onLiveEvents != nil, terminals[paneID]?.isReplaying != true, let ref = liveRef(paneID) else { return }
        var events: [EventDraftV2] = []
        let wasRunning = before?.commandRunning ?? false
        if wasRunning, event.isCommandStart {
            // A new command started without a finish mark: the previous one ended, its status unknown.
            events.append(.commandFinished(ref, exitCode: nil, duration: before?.commandStartedAt.map { activityNow().timeIntervalSince($0) }))
        } else if wasRunning, !state.commandRunning {
            events.append(.commandFinished(ref, exitCode: state.lastExitCode, duration: state.lastDuration))
        }
        if event.isCommandStart, state.commandRunning { events.append(.commandStarted(ref)) }
        if let directory = state.currentDirectory, directory != before?.currentDirectory { events.append(.folderChanged(ref, path: directory)) }
        emitLive(events)
    }

    // MARK: Agents (FR-AG)

    func liveAgentsChanged(from old: [UUID: AgentStateReducer]) {
        guard onLiveEvents != nil else { return }
        var events: [EventDraftV2] = []
        for id in Self.changedKeys(old, agentStates) {
            let before = old[id], after = agentStates[id]
            guard let after else {
                if before != nil, let agent = liveAgentIDs.removeValue(forKey: id), let ref = liveRef(id) { events.append(.agentEnded(ref, agentID: agent)) }
                continue
            }
            guard let ref = liveRef(id), let agent = paneAgent(paneID: id)?.id ?? liveAgentIDs[id] else { continue }
            if before == nil {
                liveAgentIDs[id] = agent
                events.append(.agentStarted(ref, agentID: agent))
            }
            if after.state != (before?.state ?? .ready) { events.append(.agentState(ref, agentID: agent, state: after.state, previous: before?.state ?? .ready)) }
            if after.settings != before?.settings ?? AgentSettings() { events.append(.agentSettings(ref, agentID: agent, settings: after.settings)) }
        }
        liveAgentIDs = liveAgentIDs.filter { agentStates[$0.key] != nil }
        emitLive(events)
    }

    func liveAvailabilityChanged(from old: [String: AgentAvailability]) {
        guard onLiveEvents != nil else { return }
        let changed = Set(old.keys).union(agentAvailability.keys).filter { old[$0] != agentAvailability[$0] }.sorted()
        emitLive(
            changed.map { id in
                let status =
                    switch agentAvailability[id] {
                    case .installed?: "installed"
                    case .missing?: "missing"
                    case .checking?: "checking"
                    case nil: "unknown"
                    }
                // The path it was found at is this Mac's file system layout; only the status is reported.
                return .agentAvailability(agentID: id, status: status)
            })
    }

    func liveRemoteMissingChanged(from old: [UUID: Set<String>]) {
        guard onLiveEvents != nil else { return }
        var events: [EventDraftV2] = []
        for host in Self.changedKeys(old, remoteMissingAgents) {
            let before = old[host] ?? [], after = remoteMissingAgents[host] ?? []
            let ref = liveHost(host)
            for agent in after.subtracting(before).sorted() { events.append(.agentAvailability(agentID: agent, status: "missing", host: ref)) }
            for agent in before.subtracting(after).sorted() { events.append(.agentAvailability(agentID: agent, status: "unknown", host: ref)) }
        }
        emitLive(events)
    }

    // MARK: Remote workspaces (FR-RW07)

    /// Remote events need host.read and the host approved at its current connection.
    private func liveHost(_ id: UUID) -> EventHostV2 {
        EventHostV2(id: id, connectionRevision: commandPaletteHosts().first { $0.id == id }?.connectionRevision)
    }

    func liveRemoteLinksChanged(from old: [UUID: RemoteLinkDisplay]) {
        guard onLiveEvents != nil else { return }
        emitLive(
            Self.changedKeys(old, remoteLinks).compactMap { id in
                let host = liveHost(id)
                switch remoteLinks[id] {
                case .connecting?: return .remoteLink(host: host, state: "connecting")
                case .connected?: return .remoteLink(host: host, state: "connected")
                case .reconnecting(let attempt, let at)?: return .remoteLink(host: host, state: "reconnecting", attempt: attempt, nextAttemptAt: at)
                case .offline?: return .remoteLink(host: host, state: "offline")
                case .needsInput(_, let reason)?: return .remoteLink(host: host, state: "needsInput", reason: reason)
                case .disconnected(_, let reason)?: return .remoteLink(host: host, state: "disconnected", reason: reason ?? .unknown)
                case nil: return nil
                }
            })
    }

    // MARK: Tasks and projects (FR-TK07, FR-PL)

    func liveTaskRunsChanged(from old: [UUID: TaskRun]) {
        guard onLiveEvents != nil else { return }
        var events: [EventDraftV2] = []
        for id in Self.changedKeys(old, taskRuns) {
            guard let ref = liveRef(id) else { continue }
            let before = old[id], after = taskRuns[id]
            if let before, before.isActive, after?.taskID != before.taskID { events.append(.taskRun(ref, taskID: before.taskID, run: nil)) }
            if let after, after.taskID != before?.taskID || after.phase != before?.phase { events.append(.taskRun(ref, taskID: after.taskID, run: after)) }
        }
        emitLive(events)
    }

    func liveProjectLaunched(_ id: UUID, space: UUID, target: ProjectTarget, folder: String) {
        guard onLiveEvents != nil else { return }
        var revision: UInt64?
        if case .host(let host) = target { revision = commandPaletteHosts().first { $0.id == host }?.connectionRevision }
        emitLive([.projectLaunched(id: id, space: space, target: target, folder: folder, hostConnectionRevision: revision)])
    }
}

extension ShellIntegrationEvent {
    var isCommandStart: Bool {
        if case .commandStart = self { return true }
        return false
    }
}
