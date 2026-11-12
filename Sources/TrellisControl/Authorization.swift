import Darwin
import Foundation
import TrellisCore

/// `anyLayout` accepts a space, tab, pane, branch, or session ID (event filters). `project` (a UUID) and `agent` (a
/// definition ID string) are scoped by the grant's project and agent scopes, not by space.
public enum ResourceKind: Sendable { case space, tab, pane, branch, session, host, anyLayout, project, agent }

/// A grant's view of the workspace. Domain methods use it to filter lists so
/// hidden resources are never enumerated.
public struct GrantAccess: Sendable {
    public let grant: AutomationGrant
    public let snapshot: WorkspaceSnapshot

    public func allows(_ capability: CapabilityV2) -> Bool { grant.holds(capability) }

    public func canSee(space id: UUID) -> Bool {
        guard snapshot.spaces.contains(where: { $0.id == id }) else { return false }
        return grant.reaches(space: id)
    }

    /// Whether the project is in the grant's project scope; whether it exists is the domain's answer.
    public func reaches(project id: UUID) -> Bool {
        switch grant.projectScope {
        case .all: true
        case .projects(let ids): ids.contains(id)
        }
    }

    /// Whether the grant may start or install this agent definition; runs of other agents stay readable.
    public func canUse(agent id: String) -> Bool {
        switch grant.agentScope {
        case .all: true
        case .agents(let ids): ids.contains(id)
        }
    }

    /// The space owning a resource, or nil when it does not exist.
    public func owningSpace(_ kind: ResourceKind, _ id: UUID) -> UUID? {
        switch kind {
        case .space: return snapshot.spaces.contains { $0.id == id } ? id : nil
        case .tab: return snapshot.tabs[id]?.spaceID
        case .pane: return snapshot.panes[id].flatMap { snapshot.tabs[$0.tabID]?.spaceID }
        case .session: return snapshot.panes.values.first { $0.sessionID == id }.flatMap { snapshot.tabs[$0.tabID]?.spaceID }
        case .branch:
            return snapshot.tabs.values.first { tab in Self.branchIDs(tab.root).contains(id) }?.spaceID
        case .host, .project, .agent: return nil
        case .anyLayout: return [ResourceKind.space, .tab, .pane, .session, .branch].lazy.compactMap { owningSpace($0, id) }.first
        }
    }

    public enum HostAccess: Equatable, Sendable { case allowed, hidden, needsReapproval }

    /// Approved-host grants bind to the connection revision they approved.
    public func hostAccess(_ host: SavedHost?) -> HostAccess {
        guard let host else { return .hidden }
        switch grant.hostScope {
        case .all: return .allowed
        case .approved(let approvals):
            guard let approval = approvals.first(where: { $0.hostID == host.id }) else { return .hidden }
            return approval.connectionRevision == host.connectionRevision ? .allowed : .needsReapproval
        }
    }

    private static func branchIDs(_ layout: PaneLayout) -> [UUID] {
        guard case .split(let id, _, _, let children) = layout else { return [] }
        return [id] + children.flatMap(branchIDs)
    }
}

/// Counts failed authentications across all connections (all share one user).
public actor AuthenticationRateLimiter {
    public let limit: Int
    public let window: TimeInterval
    private var failures: [Date] = []
    private let now: @Sendable () -> Date

    public init(limit: Int = 5, window: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.limit = limit; self.window = window; self.now = now
    }

    public func isLimited() -> Bool {
        let cutoff = now().addingTimeInterval(-window)
        failures.removeAll { $0 <= cutoff }
        return failures.count >= limit
    }

    public func recordFailure() { failures.append(now()) }
}

/// API-04: same grant + same key + same method/params replays the first result
/// for ten minutes in this app instance; a different payload is a conflict.
/// Nothing persists across restarts, so a new instance executes again.
public actor IdempotencyCache {
    public static let lifetime: TimeInterval = 600
    private struct Entry {
        let method: String
        let params: JSONValue?
        let stored: Date
        var result: Result<JSONValue, ControlError>?
    }
    private var entries: [String: Entry] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    public enum Lookup: Sendable {
        case execute
        case replay(Result<JSONValue, ControlError>)
        case conflict
        case inProgress
        case limited
    }

    /// Reserves the key when it is new; the caller must `finish` it.
    public func begin(grant: UUID, key: String, method: String, params: JSONValue?) -> Lookup {
        let cutoff = now().addingTimeInterval(-Self.lifetime)
        entries = entries.filter { $0.value.stored > cutoff }
        let id = grant.uuidString + "\u{0}" + key
        if let entry = entries[id] {
            guard entry.method == method, entry.params == params else { return .conflict }
            return entry.result.map(Lookup.replay) ?? .inProgress
        }
        // Bound memory per grant: one client cannot exhaust the cache for others.
        let prefix = grant.uuidString + "\u{0}"
        guard entries.keys.lazy.filter({ $0.hasPrefix(prefix) }).count < 1_000 else { return .limited }
        entries[id] = Entry(method: method, params: params, stored: now(), result: nil)
        return .execute
    }

    /// Retryable failures release the key, so the documented retry can run;
    /// every other outcome is replayed for the rest of the lifetime.
    public func finish(grant: UUID, key: String, result: Result<JSONValue, ControlError>) {
        let id = grant.uuidString + "\u{0}" + key
        if case .failure(let error) = result, error.retryable { entries.removeValue(forKey: id) } else { entries[id]?.result = result }
    }
}

/// API-02/API-03 authorization at the service boundary (protocol 2, the only protocol). Every call is re-checked against
/// the stored grant, so revocation, expiry and narrowing edits apply at once.
public actor AuthorizingControlHandler: ControlHandler {
    private let grants: GrantStore
    private let limiter: AuthenticationRateLimiter
    /// Network (MCP) failures are counted apart, so a LAN client cannot lock out the local socket.
    private let networkLimiter: AuthenticationRateLimiter
    private let events: EventHubV2?
    private let dispatcher: DispatcherV2
    private var connections: [UUID: UUID] = [:]

    public init(
        grants: GrantStore, domain: any ControlDomainV2, limiter: AuthenticationRateLimiter = AuthenticationRateLimiter(),
        networkLimiter: AuthenticationRateLimiter = AuthenticationRateLimiter(), idempotency: IdempotencyCache = IdempotencyCache(), events: EventHubV2? = nil
    ) {
        self.grants = grants; self.limiter = limiter; self.networkLimiter = networkLimiter; self.events = events
        dispatcher = DispatcherV2(domain: domain, idempotency: idempotency, ledger: grants.createdSpaceLedger, events: events)
    }

    /// Connections currently authenticated with `grantID`, for revocation.
    public func connections(for grantID: UUID) -> Set<UUID> { Set(connections.filter { $0.value == grantID }.keys) }

    public func authenticate(_ params: JSONValue?, connectionID: UUID, peerUID: uid_t) async -> Result<(ControlIdentity, JSONValue), ControlError> {
        connections.removeValue(forKey: connectionID)
        guard peerUID == geteuid() else { return .failure(.authenticationFailed) }
        await grants.ensureLoaded()
        guard !(await limiter.isLimited()) else { return .failure(.rateLimited) }
        // There is no fallback: protocol 1 (and anything else) is refused, naming the version on offer. No credential was
        // tested, so an outdated client run over and over never locks the socket for the others.
        guard params?["protocolVersion"] == .number(Double(ControlDiscovery.currentProtocolVersion)) else { return .failure(.unsupportedVersion) }
        guard case .string(let token)? = params?["token"], (1...512).contains(token.utf8.count),
            let grant = await grants.activeGrant(token: token)
        else {
            await limiter.recordFailure()
            return .failure(.authenticationFailed)
        }
        connections[connectionID] = grant.id
        let identity = ControlIdentity(connectionID: connectionID, peerUID: peerUID, grantID: grant.id, grantRevision: grant.revision)
        return .success((identity, await dispatcher.authenticationResult(grant: grant, connectionID: connectionID)))
    }

    /// Bearer-token authentication for the MCP transport (API-07). A network
    /// peer has no UID to check, so the token is the whole credential; grant
    /// lookup, expiry, revocation and scope are exactly as on the socket.
    public func authenticate(bearer token: String, connectionID: UUID) async -> Result<ControlIdentity, ControlError> {
        connections.removeValue(forKey: connectionID)
        await grants.ensureLoaded()
        guard !(await networkLimiter.isLimited()) else { return .failure(.rateLimited) }
        guard (1...512).contains(token.utf8.count), let grant = await grants.activeGrant(token: token) else {
            await networkLimiter.recordFailure()
            return .failure(.authenticationFailed)
        }
        connections[connectionID] = grant.id
        return .success(ControlIdentity(connectionID: connectionID, peerUID: geteuid(), grantID: grant.id, grantRevision: grant.revision))
    }

    /// The identity's grant while it is still active; nil after expiry, revocation, or a narrowing edit since it
    /// authenticated (as `dispatch` answers AUTH_REQUIRED then).
    public func activeGrant(for identity: ControlIdentity) async -> AutomationGrant? {
        guard let id = identity.grantID, let grant = await grants.activeGrant(id: id) else { return nil }
        if let revision = identity.grantRevision, revision < grant.reauthenticateBelow { return nil }
        return grant
    }

    public func dispatch(_ method: String, params: JSONValue?, identity: ControlIdentity) async -> Result<JSONValue, ControlError> {
        guard let grantID = identity.grantID, let grant = await grants.activeGrant(id: grantID) else {
            connections.removeValue(forKey: identity.connectionID)
            return .failure(.api(.authRequired, "This grant expired or was revoked. Authenticate again with a valid grant."))
        }
        // An edit that narrowed the grant ends this authentication, so the client re-reads what it may do.
        if let revision = identity.grantRevision, revision < grant.reauthenticateBelow {
            connections.removeValue(forKey: identity.connectionID)
            return .failure(.api(.authRequired, "This grant was changed. Authenticate again to read what it allows."))
        }
        return await dispatcher.dispatch(method, params: params, grant: grant, identity: identity)
    }

    public func disconnected(connectionID: UUID) async {
        connections.removeValue(forKey: connectionID)
        await events?.removeConnection(connectionID)
    }
}
