import Darwin
import Foundation
import TrellisCore

/// `anyLayout` accepts a window, tab, pane, branch, or session ID (event filters).
public enum ResourceKind: Sendable { case window, tab, pane, branch, session, host, anyLayout }

/// Capabilities and resources a method needs before the domain sees it.
public struct MethodRequirement: Sendable {
    public var capabilities: Set<Capability>
    /// Resource IDs read from params; each must be visible to the grant.
    public var resources: [(kind: ResourceKind, key: String)] = []
    /// Optional arrays of resource IDs; every listed ID must be visible.
    public var resourceLists: [(kind: ResourceKind, key: String)] = []
    public var requiresAllWindows = false
    /// Extra capabilities when the params call for them (fail-safe: unknown shapes require them).
    public var conditional: [(capability: Capability, applies: @Sendable (JSONValue?) -> Bool)] = []
}

public enum AuthorizationPolicy {
    private static func needs(
        _ capabilities: Capability..., resources: [(ResourceKind, String)] = [], lists: [(ResourceKind, String)] = [], allWindows: Bool = false,
        conditional: [(String, Capability)] = [], when: [(Capability, @Sendable (JSONValue?) -> Bool)] = []
    ) -> MethodRequirement {
        MethodRequirement(
            capabilities: Set(capabilities), resources: resources.map { (kind: $0.0, key: $0.1) }, resourceLists: lists.map { (kind: $0.0, key: $0.1) },
            requiresAllWindows: allWindows, conditional: conditional.map { flag($0.0, $0.1) } + when.map { (capability: $0.0, applies: $0.1) })
    }

    /// Required when the param is present and not `false`/`null`.
    private static func flag(_ key: String, _ capability: Capability) -> (capability: Capability, applies: @Sendable (JSONValue?) -> Bool) {
        (
            capability,
            { params in
                switch params?[key] {
                case nil, .null?, .bool(false)?: false
                default: true
                }
            }
        )
    }

    /// Only renames and retags avoid `session.execute`; any other field could change where the host connects.
    private static let hostUpdateMayChangeConnection: @Sendable (JSONValue?) -> Bool = { params in
        guard case .object(let object)? = params else { return false }
        return object.contains { !["id", "name", "tags", "expectedRevision", "idempotencyKey"].contains($0.key) && $0.value != .null }
    }

    /// Output-read unless `topics` explicitly lists only non-output topics.
    private static let subscribesToOutput: @Sendable (JSONValue?) -> Bool = { params in
        guard case .array(let topics)? = params?["topics"] else { return true }
        return topics.contains { if case .string(let topic) = $0 { topic.lowercased().contains("output") } else { true } }
    }

    private static let arbitraryLaunch: @Sendable (JSONValue?) -> Bool = { params in
        switch params?["launch"] {
        case nil, .null?: false
        case .object(let launch)?: launch["kind"] != .string("host") || launch.count > 2
        default: true
        }
    }

    /// Appearance events are global and need theme.read.
    private static let subscribesToAppearance: @Sendable (JSONValue?) -> Bool = { params in
        guard case .array(let topics)? = params?["topics"] else { return false }
        return topics.contains { if case .string(let name) = $0 { name.hasPrefix("appearance") } else { false } }
    }

    /// Every method in the API catalog. Unknown methods are not dispatched.
    public static let requirements: [String: MethodRequirement] = [
        "system.info": needs(),
        "window.list": needs(.metadataRead),
        "window.get": needs(.metadataRead, resources: [(.window, "id")]),
        "window.create": needs(.layoutWrite, allWindows: true, conditional: [("start", .sessionStart)]),
        "window.update": needs(.layoutWrite, resources: [(.window, "id")]),
        "window.reorder": needs(.layoutWrite, allWindows: true),
        "window.focus": needs(.layoutWrite, resources: [(.window, "id")]),
        "window.close": needs(.layoutWrite, resources: [(.window, "id")], conditional: [("allowRunning", .sessionClose), ("force", .sessionClose)]),
        "tab.list": needs(.metadataRead, resources: [(.window, "windowId")]),
        "tab.get": needs(.metadataRead, resources: [(.tab, "id")]),
        "tab.create": needs(.layoutWrite, resources: [(.window, "windowId")], conditional: [("start", .sessionStart)]),
        "tab.update": needs(.layoutWrite, resources: [(.tab, "id")]),
        "tab.reorder": needs(.layoutWrite, resources: [(.window, "windowId")], lists: [(.tab, "ids")]),
        "tab.focus": needs(.layoutWrite, resources: [(.tab, "id")]),
        "tab.close": needs(.layoutWrite, resources: [(.tab, "id")], conditional: [("allowRunning", .sessionClose), ("force", .sessionClose)]),
        "pane.split": needs(.layoutWrite, resources: [(.pane, "paneId")], conditional: [("start", .sessionStart)]),
        "pane.resize": needs(.layoutWrite, resources: [(.branch, "branchId")]),
        "pane.focus": needs(.layoutWrite, resources: [(.pane, "id")]),
        "pane.maximize": needs(.layoutWrite, resources: [(.pane, "id")]),
        "pane.close": needs(.layoutWrite, resources: [(.pane, "id")], conditional: [("allowRunning", .sessionClose), ("force", .sessionClose)]),
        "session.get": needs(.metadataRead, resources: [(.session, "id")]),
        // A saved-host launch needs host access (checked by the domain), not execute;
        // any other launch descriptor is arbitrary execution.
        "session.start": needs(.sessionStart, resources: [(.pane, "paneId")], when: [(.sessionExecute, arbitraryLaunch)]),
        "session.restart": needs(
            .sessionStart, resources: [(.pane, "paneId")], conditional: [("allowRunning", .sessionClose)], when: [(.sessionExecute, arbitraryLaunch)]),
        "session.sendInput": needs(.sessionInput, resources: [(.session, "id")]),
        "session.execute": needs(.sessionExecute, resources: [(.session, "id")]),
        "session.readOutput": needs(.sessionOutputRead, resources: [(.session, "id")]),
        "host.list": needs(.hostRead),
        "host.get": needs(.hostRead, resources: [(.host, "id")]),
        "host.create": needs(.hostWrite),
        "host.update": needs(.hostWrite, resources: [(.host, "id")], when: [(.sessionExecute, hostUpdateMayChangeConnection)]),
        "host.delete": needs(.hostWrite, resources: [(.host, "id")]),
        "host.connect": needs(.sessionStart, .layoutWrite, resources: [(.host, "hostId"), (.window, "windowId")]),
        "layout.validate": needs(.metadataRead),
        "layout.plan": needs(.metadataRead),
        "layout.apply": needs(.layoutWrite, allWindows: true, conditional: [("startNew", .sessionStart)]),
        "layout.export": needs(.metadataRead, lists: [(.window, "windowIds")]),
        "theme.list": needs(.themeRead),
        "theme.get": needs(.themeRead),
        "theme.validate": needs(.themeRead),
        "theme.export": needs(.themeRead),
        // Theme writes change every window, so they need explicitly global scope (S029-AC02).
        "theme.import": needs(.themeWrite, allWindows: true),
        "theme.delete": needs(.themeWrite, allWindows: true),
        "appearance.get": needs(.themeRead),
        "appearance.set": needs(.themeWrite, allWindows: true),
        "events.subscribe": needs(
            .metadataRead, lists: [(.anyLayout, "resourceIds")], when: [(.sessionOutputRead, subscribesToOutput), (.themeRead, subscribesToAppearance)]),
        "events.unsubscribe": needs()
    ]
}

/// A grant's view of the workspace. Domain methods use it to filter lists so
/// hidden resources are never enumerated.
public struct GrantAccess: Sendable {
    public let grant: AutomationGrant
    public let snapshot: WorkspaceSnapshot

    public func allows(_ capability: Capability) -> Bool { grant.allows(capability) }

    public func canSee(window id: UUID) -> Bool {
        guard snapshot.windows.contains(where: { $0.id == id }) else { return false }
        switch grant.windowScope {
        case .all: return true
        case .windows(let ids): return ids.contains(id)
        }
    }

    /// The window owning a resource, or nil when it does not exist.
    public func owningWindow(_ kind: ResourceKind, _ id: UUID) -> UUID? {
        switch kind {
        case .window: return snapshot.windows.contains { $0.id == id } ? id : nil
        case .tab: return snapshot.tabs[id]?.windowID
        case .pane: return snapshot.panes[id].flatMap { snapshot.tabs[$0.tabID]?.windowID }
        case .session: return snapshot.panes.values.first { $0.sessionID == id }.flatMap { snapshot.tabs[$0.tabID]?.windowID }
        case .branch:
            return snapshot.tabs.values.first { tab in Self.branchIDs(tab.root).contains(id) }?.windowID
        case .host: return nil
        case .anyLayout: return [ResourceKind.window, .tab, .pane, .session, .branch].lazy.compactMap { owningWindow($0, id) }.first
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

/// Live state the authorizer reads and the executor for authorized calls.
public protocol ControlDomain: Sendable {
    func snapshot() async -> WorkspaceSnapshot
    func host(_ id: UUID) async -> SavedHost?
    /// Runs an already-authorized method through the shared command service.
    func execute(_ method: String, params: JSONValue?, access: GrantAccess) async -> Result<JSONValue, ControlError>
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

/// API-02/API-03 authorization at the service boundary. Every domain call is
/// re-checked against the stored grant, so revocation and expiry apply at once.
public actor AuthorizingControlHandler: ControlHandler {
    private let grants: GrantStore
    private let domain: any ControlDomain
    private let limiter: AuthenticationRateLimiter
    private let idempotency: IdempotencyCache
    private let events: EventHub?
    private var connections: [UUID: UUID] = [:]

    public init(
        grants: GrantStore, domain: any ControlDomain, limiter: AuthenticationRateLimiter = AuthenticationRateLimiter(),
        idempotency: IdempotencyCache = IdempotencyCache(), events: EventHub? = nil
    ) {
        self.grants = grants; self.domain = domain; self.limiter = limiter; self.idempotency = idempotency; self.events = events
    }

    /// Connections currently authenticated with `grantID`, for revocation.
    public func connections(for grantID: UUID) -> Set<UUID> { Set(connections.filter { $0.value == grantID }.keys) }

    public func authenticate(_ params: JSONValue?, connectionID: UUID, peerUID: uid_t) async -> Result<(ControlIdentity, JSONValue), ControlError> {
        connections.removeValue(forKey: connectionID)
        guard peerUID == geteuid() else { return .failure(.authenticationFailed) }
        guard !(await limiter.isLimited()) else { return .failure(.rateLimited) }
        guard params?["protocolVersion"] == .number(1) else {
            await limiter.recordFailure()
            return .failure(.unsupportedVersion)
        }
        guard case .string(let token)? = params?["token"], (1...512).contains(token.utf8.count),
            let grant = await grants.activeGrant(token: token)
        else {
            await limiter.recordFailure()
            return .failure(.authenticationFailed)
        }
        connections[connectionID] = grant.id
        let identity = ControlIdentity(connectionID: connectionID, peerUID: peerUID, grantID: grant.id)
        let scope: JSONValue =
            switch grant.windowScope {
            case .all: .string("all")
            case .windows(let ids): .array(ids.map(\.uuidString).sorted().map(JSONValue.string))
            }
        return .success(
            (
                identity,
                .object([
                    "connectionId": .string(connectionID.uuidString), "grantId": .string(grant.id.uuidString),
                    "expiresAt": .string(ISO8601DateFormatter().string(from: grant.expiresAt)),
                    "capabilities": .array(grant.capabilities.sorted().map { .string($0.rawValue) }), "windowScope": scope,
                    "protocolVersion": .number(1)
                ])
            ))
    }

    public func dispatch(_ method: String, params: JSONValue?, identity: ControlIdentity) async -> Result<JSONValue, ControlError> {
        guard let grantID = identity.grantID, let grant = await grants.activeGrant(id: grantID) else {
            connections.removeValue(forKey: identity.connectionID)
            return .failure(.application("AUTH_REQUIRED", "This grant expired or was revoked. Authenticate again with a valid grant."))
        }
        guard let requirement = AuthorizationPolicy.requirements[method] else { return .failure(.methodNotFound) }
        let access = GrantAccess(grant: grant, snapshot: await domain.snapshot())
        if case .failure(let error) = await authorize(requirement, params: params, access: access) { return .failure(error) }
        if method == "events.subscribe" || method == "events.unsubscribe" {
            return await subscription(method, params: params, grant: grant, connectionID: identity.connectionID)
        }
        guard ControlMethods.isMutating(method), let keyValue = params?["idempotencyKey"] else {
            return await domain.execute(method, params: params, access: access)
        }
        guard case .string(let key) = keyValue, (1...128).contains(key.utf8.count) else {
            return .failure(.invalidParams("idempotencyKey must be a string of 1–128 bytes.", fields: ["idempotencyKey": "1–128 byte string"]))
        }
        switch await idempotency.begin(grant: grant.id, key: key, method: method, params: params) {
        case .replay(let result): return result
        case .conflict:
            return .failure(.application("CONFLICT", "This idempotencyKey was already used with a different method or parameters."))
        case .inProgress:
            return .failure(.application("CONFLICT", "A request with this idempotencyKey is still running. Inspect state before retrying.", retryable: true))
        case .limited:
            return .failure(.application("LIMIT_EXCEEDED", "Too many idempotency keys are active for this grant. Retry later.", retryable: true))
        case .execute:
            let result = await domain.execute(method, params: params, access: access)
            await idempotency.finish(grant: grant.id, key: key, result: result)
            return result
        }
    }

    public func disconnected(connectionID: UUID) async {
        connections.removeValue(forKey: connectionID)
        await events?.removeConnection(connectionID)
    }

    private func subscription(_ method: String, params: JSONValue?, grant: AutomationGrant, connectionID: UUID) async -> Result<JSONValue, ControlError> {
        guard let events else { return .failure(.methodNotFound) }
        if method == "events.unsubscribe" {
            guard case .string(let raw)? = params?["subscriptionId"], let id = UUID(uuidString: raw) else { return .failure(.invalidParams) }
            return await events.unsubscribe(id, connectionID: connectionID) ? .success(.object(["unsubscribed": .bool(true)])) : .failure(.notFound)
        }
        guard case .array(let rawTopics)? = params?["topics"] else { return .failure(.invalidParams("topics must be an array.", fields: ["topics": "array"])) }
        var topics = Set<String>()
        for topic in rawTopics {
            guard case .string(let name) = topic else { return .failure(.invalidParams("topics must be strings.", fields: ["topics": "array of strings"])) }
            // Fine-grained names from the API catalog map onto hub topics.
            let aliases = ["session.state": "session", "session.exit": "session", "session.output": "output", "resource": "resources", "appearance.changed": "appearance"]
            topics.insert(aliases[name] ?? name)
        }
        var resourceIDs = Set<UUID>()
        switch params?["resourceIds"] {
        case nil, .null?: break
        case .array(let raw)?:
            // A malformed ID must not silently widen the filter to everything.
            for value in raw {
                guard case .string(let text) = value, let id = UUID(uuidString: text) else {
                    return .failure(.invalidParams("resourceIds must be UUID strings.", fields: ["resourceIds": "array of UUIDs"]))
                }
                resourceIDs.insert(id)
            }
        default: return .failure(.invalidParams("resourceIds must be an array.", fields: ["resourceIds": "array of UUIDs"]))
        }
        // Sequences belong to one app instance; replaying another's is an error.
        if case .string(let instance)? = params?["instanceId"], UUID(uuidString: instance) != events.instanceID {
            return .failure(.application("INVALID_CURSOR", "These sequences belong to a previous app instance. Resnapshot and subscribe without afterSequence."))
        }
        var after: UInt64?
        switch params?["afterSequence"] {
        case nil, .null?: after = nil
        case .number(let value)? where value >= 0 && value.rounded() == value && value < 9e15: after = UInt64(value)
        default: return .failure(.invalidParams("afterSequence must be a non-negative integer.", fields: ["afterSequence": "integer"]))
        }
        switch await events.subscribe(connectionID: connectionID, grant: grant, topics: topics, resourceIDs: resourceIDs, afterSequence: after) {
        case .success(let (id, sequence)):
            return .success(.object(["subscriptionId": .string(id.uuidString), "sequence": .number(Double(sequence)), "instanceId": .string(events.instanceID.uuidString)]))
        case .failure(let error): return .failure(error)
        }
    }

    private func authorize(_ requirement: MethodRequirement, params: JSONValue?, access: GrantAccess) async -> Result<Void, ControlError> {
        // Visibility first: out-of-scope IDs look exactly like missing ones.
        for (kind, key) in requirement.resources {
            guard case .string(let raw)? = params?[key], let id = UUID(uuidString: raw) else { return .failure(.invalidParams) }
            if kind == .host {
                switch access.hostAccess(await domain.host(id)) {
                case .allowed: continue
                case .hidden: return .failure(.notFound)
                case .needsReapproval:
                    return .failure(.application("PERMISSION_DENIED", "This host's connection changed after it was approved. Reapprove it in Settings → Automation."))
                }
            }
            guard let window = access.owningWindow(kind, id), access.canSee(window: window) else { return .failure(.notFound) }
        }
        for (kind, key) in requirement.resourceLists {
            let values: [JSONValue]
            switch params?[key] {
            case nil, .null?: continue
            case .array(let items)?: values = items
            default: return .failure(.invalidParams)
            }
            for value in values {
                guard case .string(let raw) = value, let id = UUID(uuidString: raw) else { return .failure(.invalidParams) }
                guard let window = access.owningWindow(kind, id), access.canSee(window: window) else { return .failure(.notFound) }
            }
        }
        if requirement.requiresAllWindows, access.grant.windowScope != .all {
            return .failure(.application("PERMISSION_DENIED", "This operation needs access to all windows."))
        }
        var needed = requirement.capabilities
        for (capability, applies) in requirement.conditional where applies(params) { needed.insert(capability) }
        guard needed.isSubset(of: access.grant.capabilities) else { return .failure(.permissionDenied) }
        return .success(())
    }
}
