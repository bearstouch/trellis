import Foundation
import TrellisControl
import TrellisCore
import TrellisTerminal

/// `project.*` (methods.md#projects): the project library through the same list model as its window (so its events and
/// the window stay current), and launches through the `ProjectLauncher` the launch sheet uses (FR-PL06–FR-PL08). A
/// definition is untrusted: what it runs (commands, agents, repositories, folders) needs session.execute to read or
/// change, and launching needs what each of those needs, checked before anything runs.
extension AutomationServiceV2 {
    @MainActor func performProjects(_ call: CallV2) async throws -> JSONValue {
        let p = call.params
        guard let library = projects, library.isLoaded else {
            throw Self.invalidState("The project library isn't available: it hasn't loaded, or it couldn't be read (reset it in the app).", state: "unavailable", retryable: true)
        }
        switch call.spec.name {
        case "project.list":
            let terms = (try p.optionalString("query") ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            let visible = library.projects.filter { project in
                guard call.access.reaches(project: project.id) else { return false }
                // Repository URLs need session.execute to read, so they are searched only with it.
                let fields = [project.name, project.notes ?? ""] + (call.grant.holds(.sessionExecute) ? project.checkouts.map(\.repository.url) : [])
                return terms.allSatisfy { term in fields.contains { $0.lowercased().contains(term) } }
            }
            let page = try PageV2(p, method: call.spec.name).slice(visible)
            let projection = projection(call)
            return ConventionsV2.list("projects", page.items.map(projection.project), revision: library.revision, nextCursor: page.nextCursor)
        case "project.get": return ConventionsV2.resource("project", projection(call).project(try project(p)))
        case "project.create":
            let created = try await save(try Self.document(p), in: library)
            return ConventionsV2.resource("project", projection(call).project(created))
        case "project.update":
            let current = try project(p)
            var next = try Self.document(p)
            // A grant that can't read what runs can't change it either (permissions.md, composition).
            if !call.grant.holds(.sessionExecute), Self.whatRuns(next) != Self.whatRuns(current) {
                throw ControlError.api(
                    .permissionDenied, "Changing a project's commands, agents, repositories or folders needs session.execute.",
                    details: .object(["missing": .array([.string(CapabilityV2.sessionExecute.rawValue)])]))
            }
            next.id = current.id
            next.revision = p.expectedRevision ?? current.revision
            return ConventionsV2.resource("project", projection(call).project(try await save(next, in: library)))
        case "project.delete":
            var current = try project(p)
            current.revision = p.expectedRevision ?? current.revision
            if let failure = await library.delete(current) { throw Self.map(failure, library) }
            return ConventionsV2.deleted(kind: "project", id: current.id, workspaceRevision: nil)
        case "project.capture":
            let spaceID = try p.uuid("spaceId")
            guard let name = try Self.name(p, "name") else { throw ControlError.invalidParams("name is required.", fields: ["name": "1–200 characters"]) }
            // Warnings name the panes that became shells in the app's words, so they're made in English.
            guard let capture = Localization.$sourceTextOnly.withValue(true, operation: { model.captureProject(spaceID: spaceID) }) else { throw Self.notFound }
            var definition = capture.project
            definition.name = name
            let created = try await save(definition, in: library)
            var object: [String: JSONValue] = ["project": projection(call).project(created)]
            if !capture.warnings.isEmpty { object["warnings"] = .array(capture.warnings.map(JSONValue.string)) }
            return .object(object)
        case "project.check":
            let (project, target, folder) = try launchContext(call)
            if case .host(let hostID) = target { try await readyRemoteLink(hostID, call) }
            let launch = try await plan(project, target: target, folder: folder, call)
            return .object(["plan": projection(call).plan(launch)])
        case "project.launch": return try await launchProject(call, library)
        default: throw ControlError.methodNotFound
        }
    }

    // MARK: Library

    /// The stored project the call names; outside the grant's scope it was already NOT_FOUND.
    @MainActor private func project(_ p: ParamsV2) throws -> ProjectDefinition {
        let id = try p.uuid("id")
        guard let project = projects?.projects.first(where: { $0.id == id }) else { throw Self.notFound }
        return project
    }

    /// The `document` parameter in the library's JSON form, checked as the editor's JSON mode checks it (FR-PL03).
    static func document(_ p: ParamsV2) throws -> ProjectDefinition {
        guard let document = p["document"], let data = try? JSONEncoder().encode(document) else { throw ControlError.invalidParams }
        switch ProjectJSON.parse(data) {
        case .success(let project): return project
        case .failure(let error):
            throw ControlError.invalidParams("The project document isn't valid: " + error.problems.joined(separator: " "), fields: ["document": "a valid project (FR-PL03)"])
        }
    }

    /// Everything that says what runs and where, as a multiset, so reordering tabs or renaming is not a change.
    static func whatRuns(_ project: ProjectDefinition) -> [String] {
        let normalized = project.normalized
        func repository(_ repository: ProjectRepository?) -> String { repository.map { $0.url + "#" + ($0.branch ?? "") } ?? "" }
        var entries = ["project|" + repository(normalized.repository)]
        for tab in normalized.tabs {
            entries.append("tab|" + (tab.directory ?? "") + "|" + repository(tab.repository))
            for entry in tab.root.panes {
                let pane = entry.pane
                entries.append(
                    ["pane", ProjectDefinition.folder(of: pane, in: tab), pane.command ?? "", pane.agent ?? "", repository(pane.repository)].joined(separator: "|"))
            }
        }
        return entries.sorted()
    }

    /// Creates a project that isn't stored yet, else updates it from its revision, through the window's list model.
    @MainActor private func save(_ project: ProjectDefinition, in library: ProjectListModel) async throws -> ProjectDefinition {
        switch await library.save(project) {
        case .success(let saved): return saved
        case .failure(let failure): throw Self.map(failure, library, id: project.id)
        }
    }

    @MainActor private static func map(_ error: ProjectLibraryError, _ library: ProjectListModel, id: UUID? = nil) -> ControlError {
        switch error {
        case .invalid(let issues):
            .invalidParams("The project document isn't valid: " + issues.map(\.message).joined(separator: " "), fields: ["document": "a valid project (FR-PL03)"])
        case .notFound: notFound
        case .conflict:
            .api(
                .conflict, "The project changed since that revision. Read it again and retry.",
                details: library.projects.first { $0.id == id }.map { .object(["currentRevision": ConventionsV2.number($0.revision)]) })
        case .readOnly: invalidState("Saved projects could not be read, so changes are not saved. Reset the project library in the app.", state: "readOnly")
        case .io: invalidState("Saved projects could not be written.", retryable: true)
        }
    }

    // MARK: Launching (FR-PL06–FR-PL08)

    /// The project, target and folder a check or launch is for; the folder defaults to the last one used on that target,
    /// else `~/<name>`, as the sheet prefills it.
    @MainActor private func launchContext(_ call: CallV2) throws -> (ProjectDefinition, ProjectTarget, String) {
        let p = call.params
        let project = try project(p)
        guard let target = try p.optionalObject("target") else { throw ControlError.invalidParams }
        let kind: ProjectTarget = try target.string("kind") == "host" ? .host(try target.uuid("hostId")) : .local
        if case .host(let hostID) = kind, !hosts.hosts.contains(where: { $0.id == hostID }) { throw Self.notFound }
        let folder = try p.optionalString("folder") ?? ProjectLaunch.suggestedFolder(project, target: kind)
        guard !folder.contains("\0") else { throw ControlError.invalidParams("folder can't hold NUL.", fields: ["folder": "a folder"]) }
        return (project, kind, folder)
    }

    /// The API's launcher: a host target's link was made ready first (connect-first, the helperInstall rule), so it only
    /// takes the link that is there and never asks in the app.
    @MainActor private var launcher: ProjectLauncher { ProjectLauncher(model: model) { [model] in model.remoteHosts?.workspaceConnection($0) } }

    @MainActor private func plan(_ project: ProjectDefinition, target: ProjectTarget, folder: String, _ call: CallV2) async throws -> ProjectLaunch {
        // Checking only reads the target, so its messages can be made in English without touching anything the app shows.
        let result = await Localization.$sourceTextOnly.withValue(true) { await launcher.plan(project, target: target, folder: folder) }
        switch result {
        case .success(let launch): return launch
        case .failure(let failure): throw launchFailure(failure, target, message: failure.message)
        }
    }

    /// A launcher failure as a protocol 2 error. `message` is English: the plan's own, or a fixed one per reason.
    @MainActor private func launchFailure(_ failure: ProjectSupportFailure, _ target: ProjectTarget, message: String) -> ControlError {
        let hostID: UUID? = if case .host(let id) = target { id } else { nil }
        switch failure.reason {
        case .folder: return .invalidParams(message, fields: ["folder": hostID == nil ? "absolute folder (or ~/…), not home" : "folder relative to home on the host"])
        case .disconnected:
            return .api(.remoteDisconnected, message, retryable: true, details: hostID.flatMap(linkDetails) ?? .object(["reason": .string(RemoteLinkReason.lost.rawValue)]))
        case .helperOutdated: return Self.helperTooOld
        case .unavailable: return Self.invalidState(message, state: "busy", retryable: true)
        case .layout, .other: return Self.invalidState(message, state: "layout")
        }
    }

    static let helperTooOld = ControlError.api(
        .invalidState, "The helper on this host is too old to run setup or agents. Update it with remote.helper.install, or Hosts → Update Helper… in the app.",
        details: .object(["state": .string("helperOutdated"), "reason": .string(RemoteLinkReason.helperTooOldForAgents.rawValue)]))

    /// project.launch: everything a launch needs is checked before anything runs (capabilities from what the definition
    /// runs, agent scope, the host's link), then the target is checked; setup runs only with `setup: true`, and the space
    /// opens from the definition that was checked, or the call is CONFLICT.
    @MainActor private func launchProject(_ call: CallV2, _ library: ProjectListModel) async throws -> JSONValue {
        let (project, target, folder) = try launchContext(call)
        let hostID: UUID? = if case .host(let id) = target { id } else { nil }
        let agents = project.tabs.flatMap { $0.root.panes.compactMap(\.pane.agent) }
        var missing: Set<CapabilityV2> = []
        if project.commandCount > 0, !call.grant.holds(.sessionExecute) { missing.insert(.sessionExecute) }
        if !agents.isEmpty, !call.grant.holds(.agentControl) { missing.insert(.agentControl) }
        guard missing.isEmpty else {
            throw ControlError.api(
                .permissionDenied, "This project runs commands or agents, which this grant doesn't allow.",
                details: .object(["missing": .array(missing.sorted().map { .string($0.rawValue) })]))
        }
        // Agent panes are agent launches: agent.control and each agent in the grant's agent scope, as session.start checks.
        for agent in Set(agents).sorted() { try requireLaunchAccess(.agent(AgentLaunch(agentID: agent, directory: nil, hostID: hostID)), call) }
        if let hostID {
            try await readyRemoteLink(hostID, call)
            if !agents.isEmpty, model.remoteHosts?.workspaceConnection(hostID).map({ $0.protocolVersion < 3 }) == true { throw Self.helperTooOld }
        }
        var launch = try await plan(project, target: target, folder: folder, call)
        // A project already open in a space this grant can't see isn't reconciled through it: checked before setup runs,
        // and again just before the change, since the app may open it meanwhile (the apply then fails on its revision).
        let namespace = launch.namespace
        let outsideScope = { [model] () -> Bool in
            guard let existing = (try? model.layoutBindings(namespace))?[ProjectLaunch.spaceKey()]?.id, model.snapshot.spaces.contains(where: { $0.id == existing })
            else { return false }
            return !self.projection(call, spaces: []).access.canSee(space: existing)
        }
        let outsideScopeError = ControlError.api(.permissionDenied, "This project is open in a space outside this grant's scope; launch it from the app instead.")
        if outsideScope() { throw outsideScopeError }
        if launch.needsSetup {
            guard try call.params.optionalBool("setup") == true else {
                throw ControlError.api(
                    .setupRequired, "The project needs setup on that target (its folder or repositories are missing). Check the plan, then launch with setup: true.",
                    details: .object(["plan": projection(call, spaces: []).plan(launch)]))
            }
            try await runSetup(launch)
            launch = try await plan(project, target: target, folder: folder, call)
        }
        // What opens must be what was checked, and what the permissions above were checked against.
        guard let current = library.projects.first(where: { $0.id == project.id }) else { throw Self.notFound }
        guard current.revision == project.revision else {
            throw ControlError.api(
                .conflict, "The project changed during the launch. Check it again and retry.", details: .object(["currentRevision": ConventionsV2.number(current.revision)]))
        }
        var refused = false
        let opened = await launcher.open(
            launch,
            stillWanted: {
                refused = outsideScope()
                return !refused
            }, created: { call.recordCreatedSpace($0) })
        switch opened {
        case .failure where refused: throw outsideScopeError
        case .failure(let failure): throw launchFailure(failure, target, message: Self.openMessage(failure.reason))
        case .success(let opened): return try await launched(call, launch, opened)
        }
    }

    /// The launcher's own messages are in the user's language; these say the same in English.
    private static func openMessage(_ reason: ProjectSupportFailure.Reason) -> String {
        switch reason {
        case .disconnected: "The host isn't connected. Reconnect, then try again."
        case .unavailable: "The workspace changed or is busy, so the project wasn't opened. Try again."
        case .helperOutdated: "The helper on this host is too old. Update it, then try again."
        case .folder, .layout, .other: "The project can't open: its saved layout bindings can't be read, or its layout conflicts with the open space."
        }
    }

    /// `{space, launches, workspaceRevision}`: each pane this launch created and started, by its layout key.
    @MainActor private func launched(_ call: CallV2, _ launch: ProjectLaunch, _ opened: ProjectLauncher.Opened) async throws -> JSONValue {
        // Start outcomes reach the store asynchronously; let them land so the records have their states.
        await model.waitForUpdates()
        let projection = projection(call, spaces: [opened.spaceID])
        guard let space = projection.snapshot.spaces.first(where: { $0.id == opened.spaceID }), projection.access.canSee(space: space.id) else { throw Self.notFound }
        let launches: [JSONValue] = opened.createdPanes.compactMap { key, paneID in
            guard let pane = projection.snapshot.panes[paneID], let session = projection.snapshot.sessions[pane.sessionID] else { return nil }
            var object = ResultObjectV2()
            object.set("paneKey", key)
            object.set("paneId", paneID)
            object.set("tabId", pane.tabID)
            object.set("session", projection.session(session, paneID: paneID))
            object.set("agentId", launch.agents[key])
            if launch.commands[key] != nil { object.set("command", true) }
            return object.json
        }
        return .object(["space": projection.space(space), "launches": .array(launches), "workspaceRevision": ConventionsV2.number(projection.snapshot.revision)])
    }

    /// Runs the setup in a terminal no one sees (FR-PL07): git's credential prompts are off, an ssh prompt can't be
    /// answered, so a setup that waits is ended after `automationSetupLimit`, or when the call is cancelled (its
    /// connection closed). Nothing opens unless it exits 0.
    @MainActor private func runSetup(_ launch: ProjectLaunch) async throws {
        let terminal = NativeTerminal()
        model.automationSetupTerminals.append(terminal)
        defer { model.automationSetupTerminals.removeAll { $0 === terminal } }
        let exit = SetupExit()
        terminal.onExit = { status in
            exit.ended = true; exit.code = status
        }
        if let failure = await launcher.startSetup(launch, in: terminal, environment: ["GIT_TERMINAL_PROMPT": "0"]) {
            throw launchFailure(failure, launch.target, message: Self.openMessage(failure.reason))
        }
        let deadline = ContinuousClock.now + model.automationSetupLimit
        var stopping: ContinuousClock.Instant?, forced = false
        while !exit.ended, ![.exited, .failed].contains(terminal.sessionState) {
            if stopping == nil, ContinuousClock.now >= deadline || Task.isCancelled {
                // A hangup lets git remove a partial clone (a kill would leave a broken checkout); a kill follows 2 s later.
                stopping = .now
                terminal.requestTermination(force: false)
            } else if let since = stopping, !forced, ContinuousClock.now - since >= .seconds(2) {
                forced = true
                terminal.requestTermination(force: true)
            } else if let since = stopping, ContinuousClock.now - since >= .seconds(10) {
                // A host whose link dropped may never report the exit; the call doesn't wait for it forever.
                break
            }
            // Detached, so a cancelled call still paces this loop while the setup ends instead of spinning.
            await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
        }
        let timedOut = stopping != nil
        let status = exit.code ?? terminal.exitCode
        guard status == 0, !timedOut else {
            var details: [String: JSONValue] = ["timedOut": .bool(timedOut)]
            if let status { details["exitCode"] = ConventionsV2.number(status) }
            throw ControlError.api(
                .launchFailed,
                timedOut
                    ? "The project's setup didn't finish in time (it may be waiting for a prompt no one can answer here); nothing was opened. Set it up from the app, or make its keys work without a prompt."
                    : "The project's setup failed; nothing was opened. Launch it from the app to see the output, then retry.",
                details: .object(["setup": .object(details)]))
        }
    }
}

/// An API setup's exit, set by its terminal on the main actor.
@MainActor
private final class SetupExit {
    var ended = false
    var code: Int32?
}
