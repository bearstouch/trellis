import Foundation
import TrellisCore

/// One authorized, validated protocol 2 call.
public struct CallV2: Sendable {
    public let spec: MethodSpecV2
    public let params: ParamsV2
    public let access: GrantAccess
    public let identity: ControlIdentity
    /// The `created` scope's membership; nil only in tests without a grant store, where creations aren't recorded.
    let ledger: CreatedSpaceLedger?

    public init(spec: MethodSpecV2, params: ParamsV2, access: GrantAccess, identity: ControlIdentity, ledger: CreatedSpaceLedger? = nil) {
        self.spec = spec; self.params = params; self.access = access; self.identity = identity; self.ledger = ledger
    }

    /// Adds a space this call created to its grant's `created` scope. Call it from inside the store transaction that
    /// creates the space (a `then` follow-up), so nothing sees the space before the grant does. UI-created spaces never
    /// come through here.
    public func recordCreatedSpace(_ id: UUID) { ledger?.record(id, grant: access.grant.id) }

    /// The call's grant with every space it has created so far, including during this call: what projections of the
    /// call's own results must use.
    public var grant: AutomationGrant {
        var grant = access.grant
        if let ledger { grant.createdSpaces.formUnion(ledger.spaces(of: grant.id)) }
        return grant
    }
}

/// What an `expectedRevision` is compared with.
public enum RevisionSubjectV2: Sendable, Equatable, Hashable {
    case workspace
    /// A branch answers with its tab's revision.
    case resource(ResourceKind, UUID)

    /// What the snapshot alone can answer: the workspace, spaces, tabs and branches (`.some(nil)` when missing). Panes,
    /// sessions and hosts aren't versioned in the snapshot, so they are `nil` here and the domain answers.
    public func revision(in snapshot: WorkspaceSnapshot) -> UInt64?? {
        switch self {
        case .workspace: return .some(snapshot.revision)
        case .resource(.space, let id): return .some(snapshot.spaces.first { $0.id == id }?.revision)
        case .resource(.tab, let id): return .some(snapshot.tabs[id]?.revision)
        case .resource(.branch, let id): return .some(snapshot.tabs.values.first { $0.root.contains(branch: id) }?.revision)
        default: return nil
        }
    }

    /// The subject a call's `expectedRevision` names, from the method's declared revision target.
    public static func of(_ spec: MethodSpecV2, _ params: ParamsV2) -> Self? {
        func resource(_ param: String) -> Self? {
            guard let kind = spec.resources.first(where: { $0.param == param && !$0.list })?.kind, let id = try? params.optionalUUID(param) else { return nil }
            return .resource(kind, id)
        }
        switch spec.revisionTarget {
        case .resource(let param)?: return resource(param)
        case .container("workspace", nil)?: return .workspace
        case .container(_, let param?)?: return resource(param)
        default: return nil
        }
    }
}

extension PaneLayout {
    public func contains(branch id: UUID) -> Bool {
        guard case .split(let branch, _, _, let children) = self else { return false }
        return branch == id || children.contains { $0.contains(branch: id) }
    }
}

/// The app side of protocol 2. The adapter implements it area by area (`Automation/V2/` in TrellisUI); it only sees
/// calls that passed validation and authorization, and still filters and redacts what it returns by `access`.
public protocol ControlDomainV2: Sendable {
    func snapshot() async -> WorkspaceSnapshot
    func host(_ id: UUID) async -> SavedHost?
    /// The current revision of what an `expectedRevision` names; nil when it doesn't exist.
    func revision(of subject: RevisionSubjectV2) async -> UInt64?
    func perform(_ call: CallV2) async -> Result<JSONValue, ControlError>
}

/// Protocol 2 results built from TrellisControl's own facts.
public enum ResultsV2 {
    /// `system.info`: no `apiVersion` (v1) and no capabilities (`grant.get` has them).
    public static func systemInfo(appVersion: String, instanceID: UUID) -> JSONValue {
        .object([
            "appVersion": .string(appVersion), "protocolVersion": .number(2), "instanceId": ConventionsV2.idJSON(instanceID),
            "limits": .object([
                "maxFrameBytes": ConventionsV2.number(ControlFramer.maximumFrame), "maxJsonDepth": ConventionsV2.number(ControlSession.maximumNesting),
                "maxConnections": ConventionsV2.number(ControlServer.maximumConnections), "maxPageSize": ConventionsV2.number(PageV2.maximumLimit),
                "maxPanes": ConventionsV2.number(LayoutPlanner.maxPanes)
            ])
        ])
    }

    /// The caller's own grant (permissions.md#grant-view): preset, revision, capabilities, every scope and the times.
    /// Approved hosts say whether their approval still matches the host's connection (`current`).
    public static func grantView(_ grant: AutomationGrant, hosts: [UUID: SavedHost]) -> JSONValue {
        var view = ResultObjectV2()
        view.set("id", grant.id)
        view.set("name", grant.name)
        view.set("preset", grant.preset.rawValue)
        view.set("revision", grant.revision)
        view.set("capabilities", JSONValue.array(grant.capabilitiesV2.sorted().map { .string($0.rawValue) }))
        var scope: [String: JSONValue] = [:]
        func ids(_ ids: Set<UUID>) -> JSONValue { .array(ids.map(ConventionsV2.id).sorted().map(JSONValue.string)) }
        switch grant.spaceScope {
        case .all: scope["spaces"] = .string("all")
        case .created: scope["spaces"] = .string("created")
        case .spaces(let set): scope["spaces"] = ids(set)
        }
        switch grant.projectScope {
        case .all: scope["projects"] = .string("all")
        case .projects(let set): scope["projects"] = ids(set)
        }
        switch grant.hostScope {
        case .all: scope["hosts"] = .string("all")
        case .approved(let approvals):
            scope["hosts"] = .array(
                approvals.sorted { ConventionsV2.id($0.hostID) < ConventionsV2.id($1.hostID) }.map { approval in
                    .object([
                        "hostId": ConventionsV2.idJSON(approval.hostID), "connectionRevision": ConventionsV2.number(approval.connectionRevision),
                        "current": .bool(hosts[approval.hostID]?.connectionRevision == approval.connectionRevision)
                    ])
                })
        }
        switch grant.agentScope {
        case .all: scope["agents"] = .string("all")
        case .agents(let set): scope["agents"] = .array(set.sorted().map(JSONValue.string))
        }
        view.set("scope", JSONValue.object(scope))
        view.set("createdAt", grant.createdAt)
        view.set("expiresAt", grant.expiresAt)
        return view.json
    }
}

/// Protocol 2 dispatch: catalog lookup, schema validation, authorization derived from the method's declaration,
/// idempotency, then the built-in method or the domain. v1 names and aliases never resolve here.
struct DispatcherV2: Sendable {
    let domain: any ControlDomainV2
    let idempotency: IdempotencyCache
    /// The real catalog; tests pass declarations of later phases' shapes to exercise authorization and idempotency.
    var catalog: [String: MethodSpecV2] = MethodCatalogV2.byName
    /// Where calls record the spaces they create (`created` scope); the grant store's.
    var ledger: CreatedSpaceLedger?
    /// The typed event stream (`events.*`); nil answers them with -32601.
    var events: EventHubV2?

    func authenticationResult(grant: AutomationGrant, connectionID: UUID) async -> JSONValue {
        .object([
            "connectionId": ConventionsV2.idJSON(connectionID), "protocolVersion": .number(2), "grant": ResultsV2.grantView(grant, hosts: await hosts(of: grant))
        ])
    }

    func dispatch(_ method: String, params raw: JSONValue?, grant: AutomationGrant, identity: ControlIdentity) async -> Result<JSONValue, ControlError> {
        guard let spec = catalog[method] else { return .failure(.methodNotFound) }
        let params: ParamsV2
        switch spec.validate(raw) {
        case .failure(let error): return .failure(error)
        case .success(let valid): params = valid
        }
        let access = GrantAccess(grant: grant, snapshot: await domain.snapshot())
        if case .failure(let error) = await authorize(spec, params, access) { return .failure(error) }
        let call = CallV2(spec: spec, params: params, access: access, identity: identity, ledger: ledger)
        guard spec.isMutating, let key = params.idempotencyKey else { return await run(call) }
        // Namespaced so a key used on a v1 connection never replays into v2, or the reverse.
        switch await idempotency.begin(grant: grant.id, key: key, method: "v2:" + spec.name, params: .object(params.values)) {
        case .replay(let result): return result
        case .conflict: return .failure(.api(.conflict, "This idempotencyKey was already used with a different method or parameters."))
        case .inProgress: return .failure(.api(.conflict, "A request with this idempotencyKey is still running. Inspect state before retrying.", retryable: true))
        case .limited: return .failure(.api(.limitExceeded, "Too many idempotency keys are active for this grant. Retry later."))
        case .execute:
            let result = await run(call)
            await idempotency.finish(grant: grant.id, key: key, result: result)
            return result
        }
    }

    private func run(_ call: CallV2) async -> Result<JSONValue, ControlError> {
        // Every mutating method honours expectedRevision from its declaration, so none can forget it. Checked inside the
        // idempotent execution: a replay returns the first result although that call moved the revision on.
        if let expected = call.params.expectedRevision, let subject = RevisionSubjectV2.of(call.spec, call.params) {
            guard let current = await domain.revision(of: subject) else { return .failure(.api(.notFound, "No such resource is available to this grant.")) }
            do { try ConventionsV2.checkRevision(expected: expected, current: current) } catch { return .failure(error) }
        }
        switch call.spec.name {
        case "grant.get":
            let hosts = await hosts(of: call.access.grant)
            return .success(ConventionsV2.resource("grant", ResultsV2.grantView(call.grant, hosts: hosts)))
        case "events.subscribe", "events.unsubscribe", "events.poll":
            guard let events else { return .failure(.methodNotFound) }
            return await Self.events(call, hub: events)
        default: return await domain.perform(call)
        }
    }

    /// `events.*` (events.md). Topic capabilities and the resource and space filters were checked from the declaration.
    static func events(_ call: CallV2, hub: EventHubV2) async -> Result<JSONValue, ControlError> {
        let params = call.params
        func ids(_ key: String) -> Set<UUID> {
            guard case .array(let items)? = params[key] else { return [] }
            return Set(items.compactMap { if case .string(let text) = $0 { ConventionsV2.parseID(text) } else { nil } })
        }
        func integer(_ key: String) -> Int64? { if case .number(let value)? = params[key] { ConventionsV2.integer(value) } else { nil } }
        if call.spec.name == "events.unsubscribe" {
            guard let id = try? params.uuid("subscriptionId") else { return .failure(.invalidParams) }
            guard await hub.unsubscribe(id, connectionID: call.identity.connectionID) else { return .failure(.api(.notFound, "No such subscription on this connection.")) }
            return .success(.object(["deleted": .object(["kind": .string("subscription"), "id": ConventionsV2.idJSON(id)])]))
        }
        guard case .array(let raw)? = params["topics"], !raw.isEmpty else {
            return .failure(.invalidParams("Name at least one topic.", fields: ["topics": "non-empty array of topics"]))
        }
        let topics = Set(raw.compactMap { if case .string(let name) = $0 { EventTopicV2(rawValue: name) } else { nil } })
        let after = integer("afterSequence").map { UInt64(max(0, $0)) }
        let instance = try? params.optionalUUID("instanceId")
        if call.spec.name == "events.poll" {
            let filter = EventFilterV2(topics: topics, spaceIDs: ids("spaceIds"))
            return await hub.poll(
                grantID: call.access.grant.id, filter: filter, afterSequence: after, instanceID: instance ?? nil, timeoutMs: Int(integer("timeoutMs") ?? 0),
                limit: Int(integer("limit") ?? Int64(EventHubV2.defaultPollLimit)))
        }
        let filter = EventFilterV2(topics: topics, resourceIDs: ids("resourceIds"), spaceIDs: ids("spaceIds"))
        switch await hub.subscribe(connectionID: call.identity.connectionID, grant: call.grant, filter: filter, afterSequence: after, instanceID: instance ?? nil) {
        case .success(let (id, sequence)):
            return .success(.object(["subscriptionId": ConventionsV2.idJSON(id), "sequence": .number(Double(sequence)), "instanceId": ConventionsV2.idJSON(hub.instanceID)]))
        case .failure(let error): return .failure(error)
        }
    }

    private func hosts(of grant: AutomationGrant) async -> [UUID: SavedHost] {
        guard case .approved(let approvals) = grant.hostScope else { return [:] }
        var hosts: [UUID: SavedHost] = [:]
        for approval in approvals { hosts[approval.hostID] = await domain.host(approval.hostID) }
        return hosts
    }

    /// Visibility first (out-of-scope IDs look exactly like missing ones), then scope width, then capabilities.
    private func authorize(_ spec: MethodSpecV2, _ params: ParamsV2, _ access: GrantAccess) async -> Result<Void, ControlError> {
        let hidden = ControlError.api(.notFound, "No such resource is available to this grant.")
        for rule in spec.resources {
            let values: [String]
            switch ConditionV2.value(at: rule.param, in: params.values) {
            case nil, .null?: continue
            case .string(let text)?: values = [text]
            case .array(let items)?: values = items.compactMap { if case .string(let text) = $0 { text } else { nil } }
            default: return .failure(.invalidParams)
            }
            if rule.kind == .agent {
                guard values.allSatisfy(access.canUse(agent:)) else { return .failure(hidden) }
                continue
            }
            for id in values.compactMap(ConventionsV2.parseID) {
                switch rule.kind {
                case .host:
                    switch access.hostAccess(await domain.host(id)) {
                    case .allowed: continue
                    case .hidden: return .failure(hidden)
                    case .needsReapproval:
                        return .failure(.api(.permissionDenied, "This host's connection changed after it was approved. Reapprove it in Settings → Automation."))
                    }
                // Whether the project exists is the domain's answer; outside the scope it looks the same.
                case .project: guard access.reaches(project: id) else { return .failure(hidden) }
                default: guard let space = access.owningSpace(rule.kind, id), access.canSee(space: space) else { return .failure(hidden) }
                }
            }
        }
        if spec.needsAllSpaces(for: params.values), access.grant.spaceScope != .all {
            return .failure(.api(.permissionDenied, "This operation needs access to all spaces."))
        }
        if spec.createsSpace(for: params.values), !access.grant.mayCreateSpaces {
            return .failure(.api(.permissionDenied, "Creating a space needs access to all spaces, or to the spaces this grant creates."))
        }
        let missing = spec.missingCapabilities(for: params.values, granted: access.grant.capabilitiesV2)
        guard missing.isEmpty else {
            return .failure(
                .api(.permissionDenied, "This grant does not allow that operation.", details: .object(["missing": .array(missing.sorted().map { .string($0.rawValue) })])))
        }
        return .success(())
    }
}
