import Darwin
import XCTest
import TrellisCore
@testable import TrellisControl

/// The dispatcher with the real catalog: expectedRevision enforced from each declaration, nested resource rules,
/// conditional capabilities and scope, and UUID normalization before idempotency.
final class DispatchV2Tests: XCTestCase {
    private let clock = TestClock()
    private let domain = FakeDomain()
    private lazy var domainV2 = FakeDomainV2(base: domain)
    private lazy var store = GrantStore(url: nil, secrets: MemorySecrets(), now: { [clock] in clock.now })
    private lazy var dispatcher = DispatcherV2(domain: domainV2, idempotency: IdempotencyCache(now: { [clock] in clock.now }))
    private lazy var host = SavedHost(id: UUID(), draft: try! HostDraft(name: "Prod", destination: "prod").validated { _ in false }, revision: 4)

    private func grant(_ capabilities: Set<Capability> = Set(Capability.allCases), spaces: SpaceScope = .all, hosts: HostScope = .all) async throws -> AutomationGrant {
        try await store.create(name: "Bot", capabilities: capabilities, spaceScope: spaces, hostScope: hosts, lifetime: 3600).grant
    }

    private func call(_ method: String, _ params: [String: JSONValue], _ grant: AutomationGrant) async -> Result<JSONValue, ControlError> {
        await dispatcher.dispatch(method, params: .object(params), grant: grant, identity: ControlIdentity(connectionID: UUID(), peerUID: geteuid(), grantID: grant.id, protocolVersion: 2))
    }

    /// The fake workspace's ID for a resource kind.
    private func id(_ kind: ResourceKind) -> UUID {
        switch kind {
        case .space: domain.spaceA
        case .tab: domain.tabA
        case .pane: domain.paneA
        case .branch: domain.branchA
        case .session: domain.sessionA
        case .host: host.id
        case .anyLayout, .project, .agent: domain.spaceA
        }
    }

    /// Valid params for any catalog method, built from its declaration.
    private func validParams(_ spec: MethodSpecV2) -> [String: JSONValue] {
        func value(_ param: ParamV2, path: String) -> JSONValue? {
            switch param.type {
            case .uuid: return spec.resources.first { $0.param == path }.map { .string(id($0.kind).uuidString) }
            case .uuidList: return spec.resources.first { $0.param == path }.map { .array([.string(id($0.kind).uuidString)]) }
            case .string(let values?, _): return .string(values[0])
            case .string: return .string(path == "command" ? "ls" : "x")
            case .stringList: return .array([])
            case .integer(let minimum, _): return .number(Double(minimum ?? 1))
            case .number(let minimum, _): return .number(max(minimum ?? 0.5, 0.5))
            case .boolean: return .bool(false)
            case .structure(let schema):
                guard let tag = schema.tag, let variant = schema.variants.first else { return .object([:]) }
                var object: [String: JSONValue] = [tag: .string(variant.value)]
                for field in schema.fields where variant.required.contains(field.name) { object[field.name] = value(field, path: path + "." + field.name) }
                return .object(object)
            default: return nil
            }
        }
        var params: [String: JSONValue] = [:]
        for param in spec.declaredParams where param.required { params[param.name] = value(param, path: param.name) }
        for rule in spec.rules where !rule.names.contains(where: { params[$0] != nil }) {
            if let first = spec.declaredParams.first(where: { $0.name == rule.names[0] }) { params[first.name] = value(first, path: first.name) }
        }
        return params
    }

    func testEveryMutatingMethodRejectsAStaleRevisionBeforeTheDomainSeesIt() async throws {
        domain.setHost(host)
        domainV2.setRevision(domain.paneA, 7)
        domainV2.setRevision(domain.sessionA, 9)
        let grant = try await grant()
        var checked: [String] = []
        for spec in MethodCatalogV2.methods where spec.isMutating {
            guard let subject = RevisionSubjectV2.of(spec, ParamsV2(validParams(spec))) else { continue }
            let answer = await domainV2.revision(of: subject)
            let current = try XCTUnwrap(answer, spec.name)
            var params = validParams(spec)
            params["expectedRevision"] = .number(Double(current + 1))
            guard case .failure(let error) = await call(spec.name, params, grant) else { XCTFail("\(spec.name) accepted a stale revision"); continue }
            XCTAssertEqual(error.appCode, "CONFLICT", spec.name)
            XCTAssertEqual(error.details, .object(["currentRevision": .number(Double(current))]), spec.name)
            params["expectedRevision"] = .number(Double(current))
            guard case .success = await call(spec.name, params, grant) else { XCTFail("\(spec.name) refused its current revision"); continue }
            checked.append(spec.name)
        }
        XCTAssertEqual(domainV2.performed, checked, "Stale calls never reach the domain; current ones do")
        XCTAssertEqual(checked.count, MethodCatalogV2.methods.filter(\.isMutating).count - 2, "Every mutating method but the two exempt ones")
        XCTAssertTrue(checked.contains("pane.resize") && checked.contains("session.sendInput") && checked.contains("host.connect"))
    }

    /// API2-05 for every method: a grant without its capabilities gets PERMISSION_DENIED naming exactly what is missing,
    /// and IDs outside the grant's scope (sent in upper case) are NOT_FOUND; neither reaches the domain.
    func testEveryMethodDeniesMissingCapabilitiesAndHidesOutOfScopeResources() async throws {
        domain.setHost(host)
        let themeOnly = try await grant([.themeRead])
        let otherSpace = try await grant(spaces: .spaces([domain.spaceB]))
        let noHosts = try await grant(hosts: .approved([]))
        var denied = 0, hidden = 0
        for spec in MethodCatalogV2.methods {
            let params = validParams(spec)
            let needed = spec.requiredCapabilities(for: params).map(\.rawValue).sorted()
            if !needed.isEmpty {
                guard case .failure(let error) = await call(spec.name, params, themeOnly) else { XCTFail("\(spec.name) ran without its capabilities"); continue }
                XCTAssertEqual(error.appCode, "PERMISSION_DENIED", spec.name)
                XCTAssertEqual(error.details, .object(["missing": .array(needed.map(JSONValue.string))]), spec.name)
                denied += 1
            }
            let kinds = Set(spec.resources.filter { ConditionV2.value(at: $0.param, in: params) != nil }.map(\.kind))
            guard !kinds.isEmpty else { continue }
            let scoped = kinds == [.host] ? noHosts : otherSpace
            guard case .failure(let error) = await call(spec.name, params, scoped) else { XCTFail("\(spec.name) reached a resource outside scope"); continue }
            XCTAssertEqual(error.appCode, "NOT_FOUND", spec.name)
            hidden += 1
        }
        XCTAssertEqual(domainV2.performed, [])
        XCTAssertEqual(denied, MethodCatalogV2.methods.count - 2, "Every method but system.info and grant.get needs a capability")
        XCTAssertGreaterThanOrEqual(hidden, 30)
    }

    func testARevisionOfAMissingResourceIsNotFound() async throws {
        let grant = try await grant()
        // pane A has no revision in the fake: the domain answers nil, as for a pane closed after authorization.
        guard case .failure(let error) = await call("pane.focus", ["id": .string(domain.paneA.uuidString), "expectedRevision": .number(1)], grant) else { return XCTFail() }
        XCTAssertEqual(error.appCode, "NOT_FOUND")
    }

    func testARetryWithAnotherUUIDCaseReplays() async throws {
        let grant = try await grant()
        let lower = ["id": JSONValue.string(domain.paneA.uuidString.lowercased()), "idempotencyKey": .string("focus-1")]
        let upper = ["id": JSONValue.string(domain.paneA.uuidString.uppercased()), "idempotencyKey": .string("focus-1")]
        guard case .success(let first) = await call("pane.focus", lower, grant), case .success(let again) = await call("pane.focus", upper, grant) else { return XCTFail() }
        XCTAssertEqual(first, again)
        XCTAssertEqual(domainV2.performed, ["pane.focus"], "The retry replayed instead of conflicting")
        XCTAssertEqual(domainV2.performedParams, [.object(lower)], "The domain sees lowercase IDs")
    }

    func testNestedResourceRulesAndConditionalScope() async throws {
        domain.setHost(host)
        let scoped = try await grant(spaces: .spaces([domain.spaceB]))
        let tab: [String: JSONValue] = ["hostId": .string(host.id.uuidString), "placement": .object(["kind": .string("tab"), "spaceId": .string(domain.spaceA.uuidString)])]
        guard case .failure(let hidden) = await call("host.connect", tab, scoped) else { return XCTFail() }
        XCTAssertEqual(hidden.appCode, "NOT_FOUND", "placement.spaceId outside scope looks missing")
        let space: [String: JSONValue] = ["hostId": .string(host.id.uuidString), "placement": .object(["kind": .string("space")])]
        guard case .failure(let narrow) = await call("host.connect", space, scoped) else { return XCTFail() }
        XCTAssertEqual(narrow.appCode, "PERMISSION_DENIED", "A new space needs all-spaces scope")
        guard case .success = await call("host.connect", space, try await grant()) else { return XCTFail() }

        let approved = try await grant(hosts: .approved([]))
        let ssh: [String: JSONValue] = ["paneId": .string(domain.paneA.uuidString), "launch": .object(["kind": .string("ssh"), "hostId": .string(host.id.uuidString)])]
        guard case .failure(let unapproved) = await call("session.start", ssh, approved) else { return XCTFail() }
        XCTAssertEqual(unapproved.appCode, "NOT_FOUND", "launch.hostId is scoped like a top-level ID")

        let starter = try await grant([.metadataRead, .sessionStart])
        guard case .success = await call("session.start", ssh, starter) else { return XCTFail("A saved host needs host scope, not session.execute") }
        let process: [String: JSONValue] = ["paneId": .string(domain.paneA.uuidString), "launch": .object(["kind": .string("process"), "executable": .string("/bin/sh"), "directory": .string("/tmp")])]
        guard case .failure(let denied) = await call("session.start", process, starter) else { return XCTFail() }
        XCTAssertEqual(denied.details, .object(["missing": .array([.string("session.execute")])]))
        XCTAssertEqual(domainV2.performed, ["host.connect", "session.start"])
    }
}
