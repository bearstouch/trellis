import Foundation
import TrellisBroker
import TrellisControl
import TrellisCore
import TrellisTerminal

/// `remote.*` (methods.md#remote-workspaces): the app's Open Remote Workspace, Retry Now / Reconnect… and the host
/// library's helper actions, through the same model paths (FR-RW01, FR-RW07, FR-RW17). A connection this API makes
/// installs the helper only as the helperInstall rule allows: the host's own auto-install, or remote.manage on the grant;
/// otherwise a missing helper is CONFIRMATION_REQUIRED and nothing is asked in the app.
extension AutomationServiceV2 {
    @MainActor func performRemote(_ call: CallV2) async throws -> JSONValue {
        let p = call.params
        let hostID = try p.uuid("hostId")
        // The dispatcher checked the host's scope; one deleted since is missing like any other.
        guard let host = hosts.hosts.first(where: { $0.id == hostID }) else { throw Self.notFound }
        if call.spec.name == "remote.status" { return remoteResult(hostID) }
        guard let remote = model.remoteHosts, remote.isAvailable else { throw Self.remoteUnavailable }
        switch call.spec.name {
        case "remote.open": return try await openRemote(call, host)
        case "remote.reconnect":
            guard model.hasRemoteWorkspace(hostID) else {
                throw Self.invalidState("No remote workspace on this Mac uses this host. Open one with remote.open.", state: "noWorkspace")
            }
            // As the space's menu: Retry Now and Reconnect… are offered only while the link is down.
            if let link = model.remoteLinks[hostID], link.isUp {
                throw Self.invalidState("The host is already connected or connecting.", state: link == .connected ? "connected" : "connecting")
            }
            let interactive = try p.optionalBool("interactive") == true
            let failure = await model.reconnectRemote(hostID: hostID, interactive: interactive, install: installPolicy(host, call))
            if failure == .declined { throw Self.helperInstallRequired(host) }
            // Any other outcome is the link's state: connected, needsInput or disconnected with a reason, or reconnecting
            // when automatic attempts go on (remote.link events follow them).
            return remoteResult(hostID)
        case "remote.helper.install":
            try helperAction(await remote.install(host, confirmed: true), hostID)
            return remoteResult(hostID)
        case "remote.helper.remove":
            let outcome = await remote.remove(host, stopSessions: try p.optionalBool("stopSessions") == true)
            if case .sessionsRunning(let count) = outcome {
                throw ControlError.api(
                    .confirmationRequired, "This Mac's sessions still run on the host. Repeat with stopSessions: true (needs session.close) to stop them first.",
                    details: .object(["reason": .string("runningSessions"), "count": ConventionsV2.number(count)]))
            }
            try helperAction(outcome, hostID)
            return remoteResult(hostID)
        default: throw ControlError.methodNotFound
        }
    }

    /// Open Remote Workspace: with `start`, the link first (so a refusal leaves nothing behind), then the space bound to
    /// the host, recorded for a `created` grant inside its transaction, then its shell on the host. Without `start` the
    /// pane stays stopped and nothing connects, as a restored remote workspace.
    @MainActor private func openRemote(_ call: CallV2, _ host: SavedHost) async throws -> JSONValue {
        let p = call.params
        let name = try Self.name(p, "name") ?? host.name
        let start = try p.optionalBool("start") == true
        if start { try await readyRemoteLink(host.id, call, interactive: true) }
        let result = try await run(
            .createRemoteSpace(name: name, hostID: host.id), expecting: p.expectedRevision.map { .workspace(revision: $0) },
            then: { created in
                if let id = created.createdSpaceID { call.recordCreatedSpace(id) }
                return nil
            })
        guard let spaceID = result.createdSpaceID, let space = result.snapshot.spaces.first(where: { $0.id == spaceID }), let tab = result.snapshot.tabs[space.activeTabID]
        else { throw ControlError.internalError }
        if start {
            let paneID = tab.activePaneID
            do { try await model.automationStartSession(paneID, launch: nil, environment: [:]) } catch { throw Self.map(error) }
            await model.waitForUpdates()
            // As the app: the space stays, with the failed pane saying why.
            if let sessionID = model.snapshot.panes[paneID]?.sessionID, model.terminals[paneID]?.sessionState == .failed || model.snapshot.sessions[sessionID]?.state == .failed {
                throw ControlError.api(.launchFailed, "The remote shell could not be started.", details: .object(["session": try session(call, sessionID)]))
            }
        }
        return try created(call, spaceID: spaceID, tabID: tab.id, includeSpace: true)
    }

    /// `{remote}`: the host's helper and link as Host.remote shows them, always present here.
    @MainActor private func remoteResult(_ hostID: UUID) -> JSONValue { .object(["remote": ProjectionV2.remote(remote(hostID))]) }

    // MARK: Connecting for other methods

    /// The helperInstall rule: install without asking only when the host's auto-install is on or the grant holds
    /// remote.manage (the consent the user gave it); otherwise never, and a missing helper is CONFIRMATION_REQUIRED.
    @MainActor private func installPolicy(_ host: SavedHost, _ call: CallV2) -> RemoteHostLink.InstallPolicy {
        (model.remoteHosts?.preferences(host).autoInstall == true || call.grant.holds(.remoteManage)) ? .always : .never
    }

    /// Before a call starts a session on a remote workspace host: its shared link, connected if needed and checked before
    /// anything is created, so a refusal leaves the workspace as it was. Only remote.* methods, which the socket answers
    /// out of order, let ssh ask in the app's console (`interactive`); others connect as an automatic attempt does.
    @MainActor func readyRemoteLink(_ hostID: UUID, _ call: CallV2, interactive: Bool = false) async throws {
        guard let remote = model.remoteHosts, remote.isAvailable else { throw Self.remoteUnavailable }
        guard !model.shuttingDown, !model.isRestoring else { throw Self.map(AutomationModelError.unavailable) }
        if remote.workspaceConnection(hostID) != nil { return }
        guard let host = hosts.hosts.first(where: { $0.id == hostID }) else { throw Self.notFound }
        let (connection, failure) = await model.remoteConnection(host, remoteHosts: remote, interactive: interactive, install: installPolicy(host, call))
        guard connection == nil else { return }
        if failure == .declined { throw Self.helperInstallRequired(host) }
        throw remoteFailure(failure ?? .lost, hostID)
    }

    @MainActor func readyRemoteLink(for launch: SessionLaunch?, _ call: CallV2) async throws {
        if let hostID = launch?.remoteHostID { try await readyRemoteLink(hostID, call) }
    }

    /// Agents on a host need its link and a helper of protocol 3 or later (FR-RW18); an older one is refused before
    /// anything is created, where the app would fail the pane after creating it.
    @MainActor func readyAgentHost(_ hostID: UUID, _ call: CallV2) async throws {
        try await readyRemoteLink(hostID, call)
        guard let connection = model.remoteHosts?.workspaceConnection(hostID), connection.protocolVersion < 3 else { return }
        throw ControlError.api(
            .invalidState, "The helper on this host is too old to run agents. Update it with remote.helper.install, or Hosts → Update Helper… in the app.",
            details: .object(["state": .string("helperOutdated"), "reason": .string(RemoteLinkReason.helperTooOldForAgents.rawValue)]))
    }

    // MARK: Errors

    static let remoteUnavailable = ControlError.api(
        .invalidState, "Remote workspaces aren't available in this app instance.",
        details: .object(["state": .string("unavailable"), "reason": .string(RemoteLinkReason.unavailable.rawValue)]))

    static func helperInstallRequired(_ host: SavedHost) -> ControlError {
        .api(
            .confirmationRequired,
            "The Trellis helper isn't installed on \(host.name), and installing it needs the user's consent: install it in the app (Hosts → Install Trellis Helper…), turn on its automatic install, or use a grant with remote.manage.",
            details: .object(["reason": .string("helperInstall")]))
    }

    /// The link's `state` (and `reason`, when it has one) for REMOTE_DISCONNECTED. The host's ID isn't repeated: the
    /// caller named it, or reads it with host.read.
    @MainActor func linkDetails(_ hostID: UUID) -> JSONValue? {
        guard case .object(let state) = ProjectionV2.remote(remote(hostID)), case .object(let link)? = state["link"] else { return nil }
        return .object(link.filter { $0.key == "state" || $0.key == "reason" })
    }

    /// A connection that failed: reaching or logging in to the host is REMOTE_DISCONNECTED (retryable when a later
    /// attempt may get through); a helper that can't be used there is INVALID_STATE with the helper's status. Both carry
    /// the reason code; the message is the app's own, in English.
    @MainActor func remoteFailure(_ failure: RemoteHostLink.Failure, _ hostID: UUID) -> ControlError {
        let reason = failure.reason
        let message = Localization.$sourceTextOnly.withValue(true) { RemoteHostsModel.message(for: failure) }
        switch failure {
        case .spawn, .exited, .lost, .unreachable, .needsInput:
            let retryable = reason == .hostUnreachable || reason == .lost
            return .api(
                .remoteDisconnected, "The host could not be connected: \(message)", retryable: retryable, details: .object(["reason": .string(reason.rawValue)]))
        case .cancelled:
            return .api(.invalidState, message, details: .object(["state": .string("cancelled"), "reason": .string(reason.rawValue)]))
        case .declined, .unsupported, .noChecksumTool, .artifactUnavailable, .remote, .incompatible:
            let helper = model.remoteHosts?.preferences[hostID]?.helper?.state.rawValue ?? "unknown"
            return .api(.invalidState, message, details: .object(["state": .string(helper), "reason": .string(reason.rawValue)]))
        }
    }

    /// A host-library action's outcome as an error; `done` returns.
    @MainActor private func helperAction(_ outcome: RemoteHostsModel.ActionResult, _ hostID: UUID) throws {
        switch outcome {
        case .done: return
        case .busy: throw Self.invalidState("Another helper action is running on this host. Retry when it ends.", state: "busy", retryable: true)
        case .unavailable: throw Self.remoteUnavailable
        case .failed(let failure): throw remoteFailure(failure, hostID)
        case .sessionsUnknown(let failure):
            throw ControlError.api(
                .invalidState, "The helper was kept: this Mac's sessions there couldn't be counted.",
                details: .object(["state": .string("sessionsUnknown"), "reason": .string((failure?.reason ?? .unknown).rawValue)]))
        // Never returned without a confirmation the API skips; mapped for exhaustiveness.
        case .declined, .sessionsRunning: throw Self.invalidState("The helper was kept.", state: "kept")
        }
    }
}
