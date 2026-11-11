import Foundation
import TrellisControl
import TrellisCore

/// `agent.*` (methods.md#agents). Starting, restarting and installing use the store commands and start path the app's
/// Agents view, Restart and Install and Launch use (FR-AG04–FR-AG12), so an agent pane started here is the same pane the
/// UI would make; answering writes fixed keys through the same input path as `session.sendInput`.
extension AutomationServiceV2 {
    @MainActor func performAgents(_ call: CallV2) async throws -> JSONValue {
        let p = call.params
        switch call.spec.name {
        case "agent.list":
            let filter = try machineFilter(p)
            let projection = projection(call, spaces: [])
            let page = try PageV2(p, method: call.spec.name).slice(model.agentCatalog.definitions)
            return ConventionsV2.list("agents", page.items.map { agent($0, projection, only: filter) }, revision: nil, nextCursor: page.nextCursor)
        case "agent.get":
            guard let definition = model.agentCatalog.definition(try p.string("id")) else { throw Self.notFound }
            return ConventionsV2.resource("agent", agent(definition, projection(call, spaces: []), only: nil))
        case "agent.runs":
            let spaceID = try p.optionalUUID("spaceId")
            let state = try p.optionalString("state").flatMap(AgentState.init(rawValue:))
            let projection = projection(call, spaces: spaceID.map { [$0] })
            return .object(["runs": .array(projection.agentRuns(space: spaceID, state: state))])
        case "agent.start": return try await startAgent(call, install: false)
        case "agent.install": return try await startAgent(call, install: true)
        case "agent.restart": return try await restartAgent(call)
        case "agent.respond": return try respond(call)
        default: throw ControlError.methodNotFound
        }
    }

    // MARK: Definitions and availability

    /// `machine`: nil lists every machine; `.some(nil)` only this Mac; `.some(host)` only that host.
    @MainActor private func machineFilter(_ p: ParamsV2) throws -> UUID?? {
        guard let machine = try p.optionalObject("machine") else { return nil }
        return try machine.string("kind") == "remote" ? .some(try machine.uuid("hostId")) : .some(nil)
    }

    @MainActor private func agent(_ definition: AgentDefinition, _ projection: ProjectionV2, only filter: UUID??) -> JSONValue {
        let machines: [UUID?]
        switch filter {
        case .some(let host): machines = [host]
        case nil: machines = [nil] + remoteAgentHosts().map(Optional.some)
        }
        let availability = machines.map { availability(definition, hostID: $0) }
        return projection.agent(definition, revision: model.automationRevisions.agents[definition.id] ?? 0, availability: availability)
    }

    /// Hosts used as remote workspaces: with an open space, a helper check or an agent found missing there, in library order.
    @MainActor private func remoteAgentHosts() -> [UUID] {
        var used = Set(model.snapshot.spaces.compactMap(\.remoteHostID)).union(model.remoteMissingAgents.keys)
        if let remote = model.remoteHosts { used.formUnion(remote.preferences.filter { $0.value.helper != nil }.keys) }
        return hosts.hosts.map(\.id).filter(used.contains)
    }

    /// This Mac from its login PATH check (FR-AG07); a host only from a launch that didn't find the agent (FR-AG12).
    @MainActor func availability(_ definition: AgentDefinition, hostID: UUID?) -> AgentAvailabilityV2 {
        let installer = model.agentInstaller(definition, hostID: hostID)
        let installable = installer.recipe != nil && installer.missingRequirements.isEmpty
        guard let hostID else {
            let status: AgentAvailabilityV2.Status =
                switch model.agentAvailability[definition.id] {
                case .installed?: .installed
                case .missing?: .missing
                case .checking?: .checking
                case nil: .unknown
                }
            return AgentAvailabilityV2(status: status, installable: installable)
        }
        if model.remoteHosts?.preferences[hostID]?.helper?.state == .unsupported { return AgentAvailabilityV2(hostID: hostID, status: .unsupported, installable: false) }
        let missing = model.remoteMissingAgents[hostID]?.contains(definition.id) == true
        return AgentAvailabilityV2(hostID: hostID, status: missing ? .missing : .unknown, installable: installable)
    }

    /// AGENT_UNAVAILABLE when the agent is known to be missing on the machine (a launch then would only exit 127), or, for
    /// an install, when the machine has no installer it can run; `details.install` says whether agent.install can fix it.
    @MainActor private func requireAgentAvailable(_ definition: AgentDefinition, hostID: UUID?, installing: Bool, _ call: CallV2) throws {
        let installer = model.agentInstaller(definition, hostID: hostID)
        let installable = installer.recipe != nil && installer.missingRequirements.isEmpty
        var details: [String: JSONValue] = [
            "agentId": .string(definition.id), "machine": projection(call, spaces: []).machine(kind: hostID == nil ? "local" : "remote", hostID: hostID),
            "install": .bool(installable)
        ]
        // What the installer needs says what it runs, which session.execute reads (resources.md#agent-definition).
        if !installer.missingRequirements.isEmpty, call.access.grant.holds(.sessionExecute) {
            details["requires"] = .array(installer.missingRequirements.map(JSONValue.string))
        }
        if installing {
            guard !installable else { return }
            let message =
                installer.recipe == nil
                ? "This agent has no installer for that machine's system. Install it there yourself, then start it."
                : "The installer needs programs this Mac's login shell can't find (details.requires). Install them first."
            throw ControlError.api(.agentUnavailable, message, details: .object(details))
        }
        let missing = hostID.map { model.remoteMissingAgents[$0]?.contains(definition.id) == true } ?? (model.agentAvailability[definition.id] == .missing)
        guard missing else { return }
        throw ControlError.api(
            .agentUnavailable, "The agent isn't installed on that machine. details.install says whether agent.install can install it.", details: .object(details))
    }

    // MARK: Start and install

    /// agent.start, and agent.install (the installer runs first in the same pane, then the agent, as Install and Launch
    /// does). The tab or split and its agent launch are created in one store transaction, so a refusal leaves nothing.
    @MainActor private func startAgent(_ call: CallV2, install: Bool) async throws -> JSONValue {
        let p = call.params
        guard let definition = model.agentCatalog.definition(try p.string("agentId")), let placement = try p.optionalObject("placement") else { throw Self.notFound }
        let kind = try placement.string("kind")
        let snapshot = model.snapshot
        // The pane whose folder the agent inherits (the space's focused pane for a new tab), and the space whose machine runs it.
        let source: UUID, spaceID: UUID
        if kind == "tab" {
            spaceID = try placement.uuid("spaceId")
            guard let space = snapshot.spaces.first(where: { $0.id == spaceID }), let tab = snapshot.tabs[space.activeTabID] else { throw Self.notFound }
            source = tab.activePaneID
        } else {
            source = try placement.uuid("paneId")
            guard let pane = snapshot.panes[source], let tab = snapshot.tabs[pane.tabID] else { throw Self.notFound }
            spaceID = tab.spaceID
        }
        guard let space = snapshot.spaces.first(where: { $0.id == spaceID }) else { throw Self.notFound }
        let hostID = space.remoteHostID
        // What starting a saved agent pane needs: agent.control, the agent in scope and a remote workspace's host.
        try requireLaunchAccess(.agent(AgentLaunch(agentID: definition.id, directory: nil, hostID: hostID)), call)
        try requireAgentAvailable(definition, hostID: hostID, installing: install, call)
        let directory: String?
        if let requested = try p.optionalString("directory") {
            guard requested.hasPrefix("/"), !requested.contains("\0") else { throw ControlError.invalidParams("directory must be an absolute path.", fields: ["directory": "absolute path"]) }
            // A host's folders can't be checked from here; the agent starts in its home there if this one is gone.
            if hostID == nil, !SystemLaunchFileAccess().isAccessibleDirectory(requested) {
                throw ControlError.invalidParams("directory isn't a folder this Mac can open.", fields: ["directory": "existing folder"])
            }
            directory = requested
        } else {
            directory = model.inheritedDirectory(from: source, remote: hostID != nil)
        }
        let launch = SessionLaunch.agent(AgentLaunch(agentID: definition.id, directory: directory, hostID: hostID, resume: try p.optionalBool("resume") == true))
        // A remote workspace's link, and a helper that can run agents, before anything is created.
        if let hostID { try await readyAgentHost(hostID, call) }

        let paneID: UUID
        var tabID: UUID?
        switch kind {
        case "tab":
            let result = try await run(
                .createTab(spaceID: spaceID), expecting: p.expectedRevision.map { .space(spaceID, revision: $0) },
                then: { created in created.createdTabID.flatMap { created.snapshot.tabs[$0] }.map { .configureStoppedSession(paneID: $0.activePaneID, launch: launch) } })
            guard let created = result.createdTabID, let pane = result.snapshot.tabs[created]?.activePaneID else { throw ControlError.internalError }
            paneID = pane; tabID = created
        case "split":
            guard let size = model.automationTerminalSize(source), let tab = snapshot.panes[source]?.tabID else { throw Self.notFound }
            // Same rule as the app: an agent opened behind a maximized pane would hide its first questions.
            guard model.maximizedPanes[tab] == nil else { throw Self.invalidState("Restore the maximized pane (pane.maximize false) before splitting this tab.", state: "maximized") }
            let axis: SplitAxis = try placement.optionalString("axis") == "y" ? .y : .x
            let result = try await run(.splitPane(id: source, axis: axis, availableSize: size), then: { $0.createdPaneID.map { .configureStoppedSession(paneID: $0, launch: launch) } })
            guard let created = result.createdPaneID else { throw ControlError.internalError }
            paneID = created; tabID = tab
        default:
            paneID = source
            try await clearForAgent(source)
        }
        // The pane's own launch is set while starting (and a restored pane's need for one cleared); new panes got theirs above.
        try await startAgentPane(paneID, launch: kind == "pane" ? launch : nil, agentID: definition.id, hostID: hostID, install: install)
        return try await agentLaunched(call, paneID: paneID, tabID: tabID)
    }

    /// A pane takes an agent only while nothing runs in it: a finished session is replaced by a fresh stopped one first,
    /// as the app's This Tab does; a running one is never ended for it.
    @MainActor private func clearForAgent(_ paneID: UUID) async throws {
        guard let pane = model.snapshot.panes[paneID], let terminal = model.terminals[paneID] else { throw Self.notFound }
        let state = terminal.sessionID == pane.sessionID ? terminal.sessionState : model.snapshot.sessions[pane.sessionID]?.state ?? .stopped
        switch state {
        case .stopped: return
        case .exited, .failed:
            let outcome: AutomationCloseResult
            do { outcome = try await model.automationRestart(paneID, allowRunning: false, force: false) } catch { throw Self.map(error) }
            if let failure = Self.closeFailure(outcome) { throw failure }
        default:
            throw Self.invalidState("Something runs in this pane. Use a pane that is stopped or finished, a new tab or a split.", state: state.rawValue)
        }
    }

    /// Starts a stopped agent pane; with `install` its installer runs first (FR-AG12). A refusal before the start leaves the
    /// installer request and the missing marks as they were.
    @MainActor private func startAgentPane(_ paneID: UUID, launch: SessionLaunch?, agentID: String, hostID: UUID?, install: Bool) async throws {
        let availability = model.agentAvailability[agentID], missing = hostID.flatMap { model.remoteMissingAgents[$0] }
        if install {
            model.agentInstallPanes.insert(paneID)
            // As Install and Launch: the installer is about to change whether the agent is there.
            model.forgetMissingAgent(agentID, hostID: hostID)
        }
        // An offer still on screen for this pane is about a run this one replaces.
        if model.agentInstallOffer?.paneID == paneID { model.agentInstallOffer = nil }
        do {
            try await model.automationStartSession(paneID, launch: launch, environment: [:])
            // The launch built its command (taking the mark) or failed before it; a later start, perhaps by a grant
            // without agent.install, must never run the installer.
            if install { model.agentInstallPanes.remove(paneID) }
        } catch {
            if install {
                model.agentInstallPanes.remove(paneID)
                if let hostID { model.remoteMissingAgents[hostID] = missing } else { model.agentAvailability[agentID] = availability }
            }
            throw Self.map(error)
        }
    }

    /// `{run?, session, pane, tab?, workspaceRevision}`; a launch that failed is LAUNCH_FAILED with the failed session. `run`
    /// is omitted when the agent already ended (the session says how, for example exit 127: not installed).
    @MainActor private func agentLaunched(_ call: CallV2, paneID: UUID, tabID: UUID?) async throws -> JSONValue {
        // The launch outcome reaches the store asynchronously; let it land so the records have their start time.
        await model.waitForUpdates()
        guard let pane = model.snapshot.panes[paneID] else { throw Self.notFound }
        let projection = projection(call, spaces: spaceOf(pane: paneID))
        guard let record = projection.snapshot.sessions[pane.sessionID].map({ projection.session($0, paneID: paneID) }) else { throw Self.notFound }
        if model.terminals[paneID]?.sessionState == .failed || model.snapshot.sessions[pane.sessionID]?.state == .failed {
            throw ControlError.api(.launchFailed, "The agent could not be started.", details: .object(["session": record]))
        }
        var object: [String: JSONValue] = [
            "session": record, "pane": projection.pane(pane), "workspaceRevision": ConventionsV2.number(projection.snapshot.revision)
        ]
        if let run = projection.agentRun(paneID: paneID) { object["run"] = run }
        if let tabID, let tab = projection.snapshot.tabs[tabID] { object["tab"] = projection.tab(tab, layout: true) }
        return .object(object)
    }

    // MARK: Restart

    /// Restart or Resume (FR-AG06) of an agent pane whose agent ended, or that was restored stopped: a new session in the
    /// same pane. Agents typed in a shell have no saved launch to start again.
    @MainActor private func restartAgent(_ call: CallV2) async throws -> JSONValue {
        let p = call.params
        let sessionID = try p.uuid("sessionId")
        guard let pane = model.snapshot.panes.values.first(where: { $0.sessionID == sessionID }) else { throw Self.notFound }
        guard var launch = model.agentLaunch(paneID: pane.id) else {
            let detected = model.detectedAgent(paneID: pane.id) != nil
            throw Self.invalidState(
                detected ? "This agent was typed in a shell; only agent panes restart. Restart the shell with session.restart." : "This session doesn't run an agent.",
                state: detected ? "detected" : "noAgent")
        }
        // Agent scope: an agent outside it looks missing, as for agent.start.
        guard call.access.canUse(agent: launch.agentID) else { throw Self.notFound }
        guard let definition = model.agentCatalog.definition(launch.agentID) else {
            throw Self.invalidState("This agent is no longer in the agent catalog.", state: "noDefinition")
        }
        try requireLaunchAccess(.agent(launch), call)
        try requireAgentAvailable(definition, hostID: launch.hostID, installing: false, call)
        if let hostID = launch.hostID { try await readyAgentHost(hostID, call) }
        try await clearForAgent(pane.id)
        launch.resume = try p.optionalBool("resume") == true
        try await startAgentPane(pane.id, launch: .agent(launch), agentID: definition.id, hostID: launch.hostID, install: false)
        return try await agentLaunched(call, paneID: pane.id, tabID: nil)
    }

    // MARK: Respond

    /// The fixed answers (methods.md#agents, the user's chosen default): approve is `1` + Return, reject is Escape, reply is
    /// the text + Return. Sent only while the run is in the expected state, so a stale answer never reaches a later prompt.
    /// The reply text is input: it is never logged, and only kept in memory for idempotent replay like session.sendInput's.
    @MainActor private func respond(_ call: CallV2) throws -> JSONValue {
        let p = call.params
        let sessionID = try p.uuid("sessionId")
        let action = try p.string("action"), text = try p.optionalString("text")
        let data: Data
        switch action {
        case "approve": data = Data("1\r".utf8)
        case "reject": data = Data([0x1b])
        default:
            // One line of plain text: no Return, Escape or other control bytes, so a reply can't answer more than it says.
            guard let text, !text.isEmpty, !text.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }) else {
                throw ControlError.invalidParams("reply needs one line of text without control characters.", fields: ["text": "non-empty text without control characters"])
            }
            data = Data((text + "\r").utf8)
        }
        if action != "reply", text != nil { throw ControlError.invalidParams("Only reply takes text.", fields: ["text": "reply only"]) }
        guard let pane = model.snapshot.panes.values.first(where: { $0.sessionID == sessionID }) else { throw Self.notFound }
        try requireRemoteHostAccess(sessionID, call)
        guard let reducer = model.agentStates[pane.id], model.paneAgent(paneID: pane.id) != nil else {
            throw Self.invalidState("This session isn't running an agent with a known state.", state: "noAgent")
        }
        let expected = try p.optionalString("expectedState") ?? AgentState.needsInput.rawValue
        guard reducer.state.rawValue == expected else {
            throw Self.invalidState("The agent is \(reducer.state.rawValue), not \(expected), so nothing was sent. Read the run again.", state: reducer.state.rawValue)
        }
        try send(sessionID, data, paste: false)
        // Return answers as the user's own Return would (FR-AG11); Escape only dismisses.
        if action != "reject" { model.applyAgentSignal(.inputSubmitted, paneID: pane.id) }
        let projection = projection(call, spaces: spaceOf(pane: pane.id))
        var object: [String: JSONValue] = ["acceptedBytes": ConventionsV2.number(data.count)]
        if let run = projection.agentRun(paneID: pane.id) { object["run"] = run }
        return .object(object)
    }
}
