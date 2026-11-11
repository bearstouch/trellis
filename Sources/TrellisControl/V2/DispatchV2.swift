import Foundation
import TrellisCore

/// One authorized, validated protocol 2 call.
public struct CallV2: Sendable {
    public let spec: MethodSpecV2
    public let params: ParamsV2
    public let access: GrantAccess
    public let identity: ControlIdentity
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

    /// The caller's own grant (permissions.md#grant-view). `preset`, `revision` and the project and agent scopes come
    /// with grant schema 2 (phase 3) and are omitted until then.
    public static func grantView(_ grant: AutomationGrant, hosts: [UUID: SavedHost]) -> JSONValue {
        var view = ResultObjectV2()
        view.set("id", grant.id)
        view.set("name", grant.name)
        view.set("capabilities", JSONValue.array(CapabilityV2.granted(by: grant).sorted().map { .string($0.rawValue) }))
        var scope: [String: JSONValue] = [:]
        switch grant.spaceScope {
        case .all: scope["spaces"] = .string("all")
        case .spaces(let ids): scope["spaces"] = .array(ids.map(ConventionsV2.id).sorted().map(JSONValue.string))
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
        let call = CallV2(spec: spec, params: params, access: access, identity: identity)
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
            return .success(ConventionsV2.resource("grant", ResultsV2.grantView(call.access.grant, hosts: hosts)))
        default: return await domain.perform(call)
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
        for rule in spec.resources {
            let ids: [UUID]
            switch ConditionV2.value(at: rule.param, in: params.values) {
            case nil, .null?: continue
            case .string(let text)?: ids = ConventionsV2.parseID(text).map { [$0] } ?? []
            case .array(let items)?: ids = items.compactMap { if case .string(let text) = $0 { ConventionsV2.parseID(text) } else { nil } }
            default: return .failure(.invalidParams)
            }
            for id in ids {
                if rule.kind == .host {
                    switch access.hostAccess(await domain.host(id)) {
                    case .allowed: continue
                    case .hidden: return .failure(.api(.notFound, "No such resource is available to this grant."))
                    case .needsReapproval:
                        return .failure(.api(.permissionDenied, "This host's connection changed after it was approved. Reapprove it in Settings → Automation."))
                    }
                }
                guard let space = access.owningSpace(rule.kind, id), access.canSee(space: space) else {
                    return .failure(.api(.notFound, "No such resource is available to this grant."))
                }
            }
        }
        if spec.needsAllSpaces(for: params.values), access.grant.spaceScope != .all {
            return .failure(.api(.permissionDenied, "This operation needs access to all spaces."))
        }
        let missing = spec.requiredCapabilities(for: params.values).subtracting(CapabilityV2.granted(by: access.grant))
        guard missing.isEmpty else {
            return .failure(
                .api(.permissionDenied, "This grant does not allow that operation.", details: .object(["missing": .array(missing.sorted().map { .string($0.rawValue) })])))
        }
        return .success(())
    }
}
