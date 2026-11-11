import Foundation
import TrellisControl
import TrellisCore

/// The protocol 2 domain adapter (docs/api/v2/implementation.md). Calls arrive validated and authorized from the
/// catalog; each area lives in its own file here and calls the same `AppWorkspaceModel` actions as the UI, so the UI and
/// the API stay one path. Constructed only when the app runs with `--automation-v2`.
public final class AutomationServiceV2: ControlDomainV2, @unchecked Sendable {
    let model: AppWorkspaceModel
    let hosts: HostListModel
    let instanceID: UUID

    @MainActor public init(model: AppWorkspaceModel, hosts: HostListModel, instanceID: UUID = UUID()) {
        self.model = model; self.hosts = hosts; self.instanceID = instanceID
    }

    public func snapshot() async -> WorkspaceSnapshot { await model.snapshotForAutomation() }
    public func host(_ id: UUID) async -> SavedHost? { await hosts.host(id) }
    public func revision(of subject: RevisionSubjectV2) async -> UInt64? { await currentRevision(subject) }

    public func perform(_ call: CallV2) async -> Result<JSONValue, ControlError> { await performOnMain(call) }

    @MainActor private func performOnMain(_ call: CallV2) async -> Result<JSONValue, ControlError> {
        do {
            // The dispatcher checked expectedRevision; checking again here, on the main actor just before the change,
            // catches a change the UI made in between. Store-versioned targets are also checked atomically by the store.
            if let expected = call.params.expectedRevision, let subject = RevisionSubjectV2.of(call.spec, call.params) {
                guard let current = currentRevision(subject) else { throw Self.notFound }
                try ConventionsV2.checkRevision(expected: expected, current: current)
            }
            switch call.spec.area {
            case "system": return performSystem(call)
            case "workspace", "space": return .success(try await performSpaces(call))
            case "tab": return .success(try await performTabs(call))
            case "pane": return .success(try await performPanes(call))
            case "session": return .success(try await performSessions(call))
            case "host": return .success(try await performHosts(call))
            default: return .failure(.methodNotFound)
            }
        } catch let error as ControlError {
            return .failure(error)
        } catch {
            return .failure(.internalError)
        }
    }

    // MARK: - Revisions

    @MainActor func currentRevision(_ subject: RevisionSubjectV2) -> UInt64? {
        if let answer = subject.revision(in: model.snapshot) { return answer }
        switch subject {
        case .resource(.pane, let id): return model.snapshot.panes[id] == nil ? nil : model.automationRevisions.panes[id] ?? 0
        case .resource(.session, let id): return model.snapshot.sessions[id] == nil ? nil : model.automationRevisions.sessions[id] ?? 0
        case .resource(.host, let id): return hosts.hosts.first { $0.id == id }?.revision
        default: return nil
        }
    }

    // MARK: - Projection

    /// Projections for this call's grant from the model's current state, captured in one main-actor pass. `spaces`
    /// limits the runtime capture to the spaces the result shows; by default, the spaces the grant can see.
    @MainActor func projection(_ call: CallV2, spaces: Set<UUID>? = nil) -> ProjectionV2 {
        let snapshot = model.snapshot
        // The live grant: a space this call just created is already in its `created` scope.
        let grant = call.grant
        var scope = spaces
        if scope == nil {
            switch grant.spaceScope {
            case .all: break
            case .created: scope = grant.createdSpaces
            case .spaces(let ids): scope = ids
            }
        }
        return ProjectionV2(
            snapshot: snapshot, runtime: runtime(spaces: scope), hosts: Dictionary(hosts.hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            grant: grant)
    }

    @MainActor func runtime(spaces spaceIDs: Set<UUID>?) -> RuntimeV2 {
        var runtime = RuntimeV2()
        let snapshot = model.snapshot
        let projects = snapshot.spaces.contains { $0.projectID != nil } ? Set(model.commandPaletteProjects().map(\.id)) : []
        for space in snapshot.spaces where spaceIDs?.contains(space.id) ?? true {
            var spaceState = SpaceRuntimeV2()
            if let project = space.projectID { spaceState.projectMissing = !projects.contains(project) }
            if let activity = model.activity[space.id] { spaceState.activity = activity.hasExit ? .exit : activity.hasOutput ? .output : nil }
            runtime.spaces[space.id] = spaceState
            for tab in space.tabIDs.compactMap({ snapshot.tabs[$0] }) {
                var tabState = TabRuntimeV2(title: model.displayTitle(tab))
                tabState.busy = model.busyTabIDs.contains(tab.id)
                tabState.progress = model.progress(tabID: tab.id)
                tabState.needsInput = model.inputWait(tabID: tab.id)
                tabState.agent = model.agentBadge(tabID: tab.id)?.state
                tabState.linkDown = model.tabLinkDown(tabID: tab.id) != nil
                tabState.maximizedPaneID = model.maximizedPanes[tab.id]
                runtime.tabs[tab.id] = tabState
                for pane in tab.root.paneIDs.compactMap({ snapshot.panes[$0] }) { runtime.panes[pane.id] = paneRuntime(pane) }
            }
        }
        return runtime
    }

    @MainActor private func paneRuntime(_ pane: WorkspacePane) -> PaneRuntimeV2 {
        var state = PaneRuntimeV2()
        state.revision = model.automationRevisions.panes[pane.id] ?? 0
        state.sessionRevision = model.automationRevisions.sessions[pane.sessionID] ?? 0
        state.maximized = model.maximizedPanes[pane.tabID] == pane.id
        if let terminal = model.terminals[pane.id], terminal.sessionID == pane.sessionID {
            state.liveState = terminal.sessionState
            state.liveExitCode = terminal.exitCode
            state.kept = terminal.survivesQuit && terminal.isRunning
            state.shell = model.shellStates[pane.id]
            state.progress = model.progress[pane.id]
            if let agent = model.agentStates[pane.id]?.state, let definition = model.paneAgent(paneID: pane.id) {
                state.agent = AgentSummaryV2(agentID: definition.id, state: agent)
            }
        }
        state.folder = model.currentDirectory(paneID: pane.id) ?? model.remoteWorkingDirectory(paneID: pane.id)
        state.needsInput = model.inputWaits[pane.id]
        return state
    }

    /// The space a resource lives in, for a runtime capture limited to it.
    @MainActor func spaceOf(pane id: UUID) -> Set<UUID> { model.snapshot.panes[id].flatMap { model.snapshot.tabs[$0.tabID] }.map { [$0.spaceID] } ?? [] }

    // MARK: - Shared helpers

    static let notFound = ControlError.api(.notFound, "No such resource is available to this grant.")

    @MainActor func run(
        _ command: WorkspaceCommand, expecting: ResourceExpectation? = nil, then follow: (@Sendable (WorkspaceCommandResult) -> WorkspaceCommand?)? = nil
    ) async throws -> WorkspaceCommandResult {
        do { return try await model.automationExecute(command, expecting: expecting, then: follow) } catch { throw Self.map(error) }
    }

    /// 1–200 characters after trimming, as the store requires; checked first so a bad name changes nothing.
    static func name(_ params: ParamsV2, _ key: String) throws -> String? {
        guard let raw = try params.optionalString(key) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { throw ControlError.invalidParams("Use 1–200 characters.", fields: [key: "1–200 characters"]) }
        return trimmed
    }

    /// Close outcomes as v2 errors; `closed` is success.
    static func closeFailure(_ outcome: AutomationCloseResult) -> ControlError? {
        switch outcome {
        case .closed: nil
        case .confirmationRequired(let ids):
            .api(
                .confirmationRequired, "Running sessions would be stopped. Repeat with allowRunning: true (needs session.close).",
                details: .object(["reason": .string("runningSessions"), "sessionIds": .array(ids.map(ConventionsV2.idJSON))]))
        case .closePending(let ids):
            .api(.closePending, "Sessions are still closing. Retry, or repeat with force: true after two seconds.", details: .object(["sessionIds": .array(ids.map(ConventionsV2.idJSON))]))
        }
    }

    static func invalidState(_ message: String, state: String? = nil, retryable: Bool = false) -> ControlError {
        .api(.invalidState, message, retryable: retryable, details: state.map { .object(["state": .string($0)]) })
    }

    static func map(_ error: AutomationModelError) -> ControlError {
        switch error {
        case .unavailable: invalidState("The workspace is busy, restoring, or shutting down. Retry shortly.", state: "busy", retryable: true)
        case .store(.notFound): notFound
        case .store(.conflict(_, let actual)):
            .api(.conflict, "The resource changed since that revision. Read it again and retry.", details: .object(["currentRevision": ConventionsV2.number(actual)]))
        // Store reasons are fixed strings, never client input.
        case .store(.invalidState(let reason)): invalidState(reason.count <= 200 ? reason : "The request violates a layout rule.")
        case .store(.invalidTransition): invalidState("That change is not allowed in the resource's current state.")
        case .store(.staleLaunch), .store(.revisionExhausted): invalidState("The workspace state changed. Retry the request.", retryable: true)
        }
    }

    static func map(_ error: HostLibraryError) -> ControlError {
        switch error {
        case .invalid(let validation):
            .invalidParams("Check the host fields.", fields: Dictionary(uniqueKeysWithValues: validation.fields.map { ($0.key.rawValue, $0.value) }))
        case .notFound: notFound
        case .conflict(_, let actual):
            .api(.conflict, "The host changed since that revision. Read it again and retry.", details: .object(["currentRevision": ConventionsV2.number(actual)]))
        case .readOnly: invalidState("Saved hosts could not be read, so changes are not saved.", state: "readOnly")
        case .io: invalidState("Saved hosts could not be written.", retryable: true)
        // Automation never sets passwords; mapped for exhaustiveness only.
        case .secretStore: invalidState("The Keychain could not be used.")
        case .notAuthorized: invalidState("The change was not confirmed.")
        }
    }
}
