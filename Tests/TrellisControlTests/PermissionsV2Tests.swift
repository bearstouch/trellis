import Darwin
import XCTest
import TrellisCore
@testable import TrellisControl

/// API2-06 at the service boundary: the capability and composition tables (each row allowed and denied), the `created`
/// scope, project and agent scopes, editing a grant under live connections, and the grant view.
final class PermissionsV2Tests: XCTestCase {
    private let clock = TestClock()
    private let domain = FakeDomain()
    private lazy var domainV2 = FakeDomainV2(base: domain)
    private lazy var store = GrantStore(url: nil, secrets: MemorySecrets(), now: { [clock] in clock.now })

    private func grant(_ capabilities: Set<CapabilityV2>, _ scope: GrantScope = GrantScope()) async throws -> (AutomationGrant, String) {
        try await store.create(GrantSettings(name: "Bot", capabilities: capabilities, scope: scope), lifetime: 3600)
    }

    private func dispatcher(_ specs: [MethodSpecV2]) -> DispatcherV2 {
        DispatcherV2(
            domain: domainV2, idempotency: IdempotencyCache(now: { [clock] in clock.now }), catalog: Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0) }),
            ledger: store.createdSpaceLedger)
    }

    private func call(_ dispatcher: DispatcherV2, _ method: String, _ params: [String: JSONValue], _ grant: AutomationGrant) async -> Result<JSONValue, ControlError> {
        // Every call reads the grant afresh, as the handler does.
        let current = await store.activeGrant(id: grant.id) ?? grant
        return await dispatcher.dispatch(
            method, params: .object(params), grant: current, identity: ControlIdentity(connectionID: UUID(), peerUID: geteuid(), grantID: grant.id))
    }

    private func outcome(_ result: Result<JSONValue, ControlError>) -> String {
        switch result {
        case .success: "OK"
        case .failure(let error): error.appCode ?? String(error.code)
        }
    }

    private func missing(_ result: Result<JSONValue, ControlError>) -> [String]? {
        guard case .failure(let error) = result, case .object(let details)? = error.details, case .array(let names)? = details["missing"] else { return nil }
        return names.compactMap { if case .string(let name) = $0 { name } else { nil } }
    }

    private var pane: JSONValue { .string(domain.paneA.uuidString) }

    // MARK: - Capabilities (API2-06a, first table)

    /// Every capability, alone, allows a method that needs only it and nothing that needs another.
    func testEachCapabilityAllowsItsOwnMethodsOnly() async throws {
        let probes = CapabilityV2.allCases.map { capability in
            MethodSpecV2(
                "probe.\(capability.rawValue.replacingOccurrences(of: ".", with: "_").split(separator: "_").enumerated().map { $0 == 0 ? String($1) : $1.capitalized }.joined())", "Probe.", capabilities: [capability])
        }
        let dispatcher = dispatcher(probes)
        for (capability, probe) in zip(CapabilityV2.allCases, probes) {
            let (holder, _) = try await grant([capability])
            let allowed = await call(dispatcher, probe.name, [:], holder)
            XCTAssertEqual(outcome(allowed), "OK", capability.rawValue)
            let others = Set(CapabilityV2.allCases).subtracting([capability])
            let (lacking, _) = try await grant(others)
            let denied = await call(dispatcher, probe.name, [:], lacking)
            XCTAssertEqual(missing(denied), [capability.rawValue], capability.rawValue)
        }
        XCTAssertEqual(MethodCatalogV2.problems(in: probes), [])
    }

    // MARK: - Composition (API2-06a, second table)

    /// The real declarations (phases 5–7), and one sample pane.close. What a project runs (its commands and agents) is
    /// known only from its definition, so those rows are checked over the real model (AutomationV2ProjectTests).
    static let composed: [MethodSpecV2] = [
        MethodCatalogV2.spec("agent.start")!, MethodCatalogV2.spec("agent.respond")!, MethodCatalogV2.spec("agent.install")!, MethodCatalogV2.spec("agent.runs")!,
        MethodCatalogV2.spec("task.run")!, MethodCatalogV2.spec("project.launch")!, MethodCatalogV2.spec("project.update")!,
        MethodCatalogV2.spec("remote.open")!, MethodCatalogV2.spec("remote.helper.install")!, MethodCatalogV2.spec("remote.helper.remove")!,
        MethodSpecV2(
            "pane.close", "Close a pane.", params: [ParamV2("id", .uuid, required: true, "Pane."), ParamV2("allowRunning", .boolean, "Stop sessions.")],
            capabilities: [.workspaceWrite], conditional: [ConditionalCapabilityV2(.sessionClose, if: .present("allowRunning"))], resources: [ResourceRuleV2(.pane, "id")],
            effect: .mutating(revision: .resource(param: "id"), destructive: true)),
        MethodCatalogV2.spec("project.create")!
    ]

    func testCompositionRowsAllowAndDeny() async throws {
        XCTAssertEqual(MethodCatalogV2.problems(in: Self.composed), [], "The sample declarations are valid")
        let host = SavedHost(id: UUID(), draft: try HostDraft(name: "Prod", destination: "prod").validated { _ in false }, revision: 1)
        domain.setHost(host)
        let dispatcher = dispatcher(Self.composed)
        let project = JSONValue.string(UUID().uuidString)
        let local = JSONValue.object(["kind": .string("local")])
        let onHost = JSONValue.object(["kind": .string("host"), "hostId": .string(host.id.uuidString)])
        let agent: [String: JSONValue] = ["agentId": .string("trellis-codex"), "placement": .object(["kind": .string("pane"), "paneId": pane])]
        let answer: [String: JSONValue] = ["sessionId": .string(domain.sessionA.uuidString), "action": .string("approve")]
        // (row, method, params, enough, one short, what the short grant misses)
        let rows: [(String, String, [String: JSONValue], Set<CapabilityV2>, Set<CapabilityV2>, [String])] = [
            ("agent in the pane's folder", "agent.start", agent, [.agentControl, .workspaceWrite], [.agentControl], ["workspace.write"]),
            (
                "agent in a chosen directory", "agent.start", agent.merging(["directory": .string("/tmp")]) { $1 }, [.agentControl, .workspaceWrite, .sessionExecute],
                [.agentControl, .workspaceWrite], ["session.execute"]
            ),
            ("answer with agent.respond", "agent.respond", answer, [.agentRespond], [.workspaceRead], ["agent.respond"]),
            ("answer with session.input", "agent.respond", answer, [.sessionInput], [.sessionExecute], ["agent.respond"]),
            // The installer then starts the agent in a pane, as Install and Launch does, so it also needs what agent.start needs.
            (
                "install an agent", "agent.install", agent, [.agentInstall, .sessionExecute, .agentControl, .workspaceWrite], [.agentInstall, .agentControl, .workspaceWrite],
                ["session.execute"]
            ),
            ("run a trusted task", "task.run", ["paneId": pane, "taskId": .string("file:build")], [.taskRun], [.taskRead], ["task.run"]),
            ("launch a project", "project.launch", ["id": project, "target": local], [.projectLaunch, .sessionStart], [.projectLaunch], ["session.start"]),
            (
                "…running its setup", "project.launch", ["id": project, "target": local, "setup": .bool(true)], [.projectLaunch, .sessionStart, .sessionExecute],
                [.projectLaunch, .sessionStart], ["session.execute"]
            ),
            (
                "…in a chosen folder", "project.launch", ["id": project, "target": local, "folder": .string("~/shop")], [.projectLaunch, .sessionStart, .sessionExecute],
                [.projectLaunch, .sessionStart], ["session.execute"]
            ),
            (
                "…on a host", "project.launch", ["id": project, "target": onHost], [.projectLaunch, .sessionStart, .remoteConnect], [.projectLaunch, .sessionStart],
                ["remote.connect"]
            ),
            ("create a project", "project.create", ["document": .object([:])], [.projectWrite, .sessionExecute], [.projectWrite], ["session.execute"]),
            ("edit a project", "project.update", ["id": project, "document": .object([:])], [.projectWrite], [.projectRead], ["project.write"]),
            ("open a remote workspace", "remote.open", ["hostId": .string(host.id.uuidString)], [.remoteConnect, .workspaceWrite], [.remoteConnect], ["workspace.write"]),
            // Installing a missing helper on the way needs remote.manage too; that is decided once the host is probed, so the
            // real model covers it (AutomationV2RemoteTests: CONFIRMATION_REQUIRED with reason helperInstall).
            (
                "…starting its shell", "remote.open", ["hostId": .string(host.id.uuidString), "start": .bool(true)], [.remoteConnect, .workspaceWrite, .sessionStart],
                [.remoteConnect, .workspaceWrite], ["session.start"]
            ),
            ("install the helper", "remote.helper.install", ["hostId": .string(host.id.uuidString)], [.remoteManage], [.remoteConnect], ["remote.manage"]),
            (
                "remove it, stopping sessions", "remote.helper.remove", ["hostId": .string(host.id.uuidString), "stopSessions": .bool(true)], [.remoteManage, .sessionClose],
                [.remoteManage], ["session.close"]
            ),
            ("close running sessions", "pane.close", ["id": pane, "allowRunning": .bool(true)], [.workspaceWrite, .sessionClose], [.workspaceWrite], ["session.close"])
        ]
        for (row, method, params, enough, short, lacks) in rows {
            let (allowed, _) = try await grant(enough)
            let ok = await call(dispatcher, method, params, allowed)
            XCTAssertEqual(outcome(ok), "OK", row)
            let (denied, _) = try await grant(short)
            let refused = await call(dispatcher, method, params, denied)
            XCTAssertEqual(outcome(refused), "PERMISSION_DENIED", row)
            XCTAssertEqual(missing(refused), lacks, row)
        }
        // A project launch onto a host needs the host in scope too, and creating its space needs all or created scope.
        let (unapproved, _) = try await grant([.projectLaunch, .sessionStart, .sessionExecute, .remoteConnect], GrantScope(hosts: .approved([])))
        let hidden = await call(dispatcher, "project.launch", ["id": project, "target": onHost], unapproved)
        XCTAssertEqual(outcome(hidden), "NOT_FOUND")
        let (narrow, _) = try await grant([.remoteConnect, .workspaceWrite], GrantScope(spaces: .spaces([domain.spaceA])))
        let refusedSpace = await call(dispatcher, "remote.open", ["hostId": .string(host.id.uuidString)], narrow)
        XCTAssertEqual(outcome(refusedSpace), "PERMISSION_DENIED")
        let (created, _) = try await grant([.remoteConnect, .workspaceWrite], GrantScope(spaces: .created))
        let createdOK = await call(dispatcher, "remote.open", ["hostId": .string(host.id.uuidString)], created)
        XCTAssertEqual(outcome(createdOK), "OK")
    }

    func testAnyOfGroupsAreDeclaredAndSummarized() {
        let respond = Self.composed[1]
        XCTAssertEqual(respond.requirementSummary, "agent.respond or session.input")
        XCTAssertTrue(respond.isReachable(with: [.sessionInput]))
        XCTAssertFalse(respond.isReachable(with: [.sessionExecute]))
        XCTAssertTrue(respond.errors.contains(.permissionDenied))
        let bad = MethodSpecV2("agent.respond", "Bad.", capabilities: [.sessionInput], anyOf: [[.sessionInput, .agentRespond], [.agentRespond]])
        XCTAssertEqual(
            MethodCatalogV2.problems(in: [bad]), ["agent.respond: an anyOf group overlaps the required capabilities", "agent.respond: an anyOf group needs two or more different capabilities"])
        let agentAsUUID = MethodSpecV2("agent.get", "Bad.", params: [ParamV2("agentId", .uuid, required: true, "Agent.")], resources: [ResourceRuleV2(.agent, "agentId")])
        XCTAssertEqual(MethodCatalogV2.problems(in: [agentAsUUID]), ["agent.get: agent parameter agentId must be declared as a string"])
        XCTAssertEqual(Self.composed[7].requirementSummary, "remote.connect + workspace.write (+session.start if start), all or created spaces")
    }

    // MARK: - Created scope (API2-06b)

    func testCreatedScopeReachesOnlyWhatTheGrantCreated() async throws {
        let (orchestrator, _) = try await grant(GrantPreset.agentOrchestrator.capabilities!, GrantScope(spaces: .created))
        let (other, _) = try await grant([.workspaceRead, .workspaceWrite], GrantScope(spaces: .created))
        let core = dispatcher(MethodCatalogV2.methods)
        let before = await call(core, "space.get", ["id": .string(domain.spaceA.uuidString)], orchestrator)
        XCTAssertEqual(outcome(before), "NOT_FOUND", "Nothing is in a new created scope")
        // The adapter records the space inside the creating transaction; here the fake creates nothing, so record it as it would.
        let made = await call(core, "space.create", ["name": .string("Mine")], orchestrator)
        XCTAssertEqual(outcome(made), "OK", "Creating a space needs all or created scope")
        store.recordCreatedSpace(domain.spaceA, grant: orchestrator.id)
        for (method, params) in [
            ("space.get", ["id": JSONValue.string(domain.spaceA.uuidString)]), ("tab.get", ["id": .string(domain.tabA.uuidString)]), ("pane.get", ["id": pane]),
            ("session.get", ["id": .string(domain.sessionA.uuidString)]), ("pane.resize", ["branchId": .string(domain.branchA.uuidString), "ratio": .number(0.4)])
        ] {
            let mine = await call(core, method, params, orchestrator)
            XCTAssertEqual(outcome(mine), "OK", "\(method): its own space and everything in it")
            let theirs = await call(core, method, params, other)
            XCTAssertEqual(outcome(theirs), "NOT_FOUND", "\(method): another grant's created space looks missing")
        }
        let elsewhere = await call(core, "tab.get", ["id": .string(domain.tabB.uuidString)], orchestrator)
        XCTAssertEqual(outcome(elsewhere), "NOT_FOUND", "A space it didn't create")
        let reorder = await call(core, "space.reorder", ["ids": .array([.string(domain.spaceA.uuidString)])], orchestrator)
        XCTAssertEqual(outcome(reorder), "PERMISSION_DENIED", "Reordering still needs all spaces")
        let (setScoped, _) = try await grant([.workspaceWrite], GrantScope(spaces: .spaces([domain.spaceA])))
        let refused = await call(core, "space.create", ["name": .string("X")], setScoped)
        XCTAssertEqual(outcome(refused), "PERMISSION_DENIED", "A set of spaces can't create more")
        let connect = await call(core, "host.connect", ["hostId": .string(UUID().uuidString), "placement": .object(["kind": .string("space")])], setScoped)
        XCTAssertEqual(outcome(connect), "NOT_FOUND", "Visibility comes first")

        // The grant view says `created`, on the socket's authentication result too.
        let view = await call(core, "grant.get", [:], orchestrator)
        guard case .success(.object(let result)) = view, case .object(let grantView)? = result["grant"], case .object(let scope)? = grantView["scope"] else { return XCTFail() }
        XCTAssertEqual(scope["spaces"], .string("created"))
        let handler = AuthorizingControlHandler(grants: store, domain: domainV2, limiter: AuthenticationRateLimiter(now: { [clock] in clock.now }))
        let (_, token) = try await grant([.workspaceRead, .workspaceWrite], GrantScope(spaces: .created))
        let session = ControlSession(peerUID: geteuid(), handler: handler)
        let auth = try await lastReply(session, request(1, "auth.authenticate", ["protocolVersion": .number(2), "token": .string(token)]))
        let authScope = ((auth["result"] as? [String: Any])?["grant"] as? [String: Any])?["scope"] as? [String: Any]
        XCTAssertEqual(authScope?["spaces"] as? String, "created")
        let hidden = try await lastReply(session, request(3, "space.get", ["id": .string(domain.spaceA.uuidString)]))
        XCTAssertEqual(appCode(hidden), "NOT_FOUND", "A created grant sees nothing it didn't create")
    }

    func testCreatedSpaceEventsReachTheirGrantOnly() async throws {
        let hub = EventHubV2(instanceID: UUID(), grants: store, now: { [clock] in clock.now })
        let sink = DeliverySink()
        await hub.setDelivery { connection, data in
            sink.append(connection, data); return true
        }
        let (mine, _) = try await grant([.workspaceRead], GrantScope(spaces: .created))
        let (theirs, _) = try await grant([.workspaceRead], GrantScope(spaces: .created))
        let mineConnection = UUID(), theirConnection = UUID()
        _ = await hub.subscribe(connectionID: mineConnection, grant: mine, filter: EventFilterV2(topics: [.workspace]), afterSequence: nil, instanceID: nil)
        _ = await hub.subscribe(connectionID: theirConnection, grant: theirs, filter: EventFilterV2(topics: [.workspace]), afterSequence: nil, instanceID: nil)
        let space = UUID()
        store.recordCreatedSpace(space, grant: mine.id)
        await hub.publish([
            EventDraftV2("space.created", kind: "space", id: space, spaceID: space), EventDraftV2("tab.created", kind: "tab", id: UUID(), spaceID: UUID())
        ])
        XCTAssertEqual(sink.count(mineConnection), 1, "The creating grant gets its space's event")
        XCTAssertEqual(sink.count(theirConnection), 0)
    }

    /// Delivery re-checks the capabilities per event, so nothing reaches a narrowed grant before `grantEdited` runs.
    func testANarrowedGrantGetsNoEventsBeforeRevalidation() async throws {
        let hub = EventHubV2(instanceID: UUID(), grants: store, now: { [clock] in clock.now })
        let sink = DeliverySink()
        await hub.setDelivery { connection, data in
            sink.append(connection, data); return true
        }
        let (grant, _) = try await grant([.workspaceRead, .sessionOutputRead, .themeRead])
        let connection = UUID()
        _ = await hub.subscribe(connectionID: connection, grant: grant, filter: EventFilterV2(topics: [.workspace, .output]), afterSequence: nil, instanceID: nil)
        await hub.publish([EventDraftV2("space.created", kind: "space", id: domain.spaceA, spaceID: domain.spaceA)])
        XCTAssertEqual(sink.count(connection), 1)
        var narrower = grant.settings
        narrower.capabilities = [.themeRead]
        try await store.update(grant.id, to: narrower, expectedRevision: grant.revision, confirmedWidening: false)
        await hub.publish([EventDraftV2("space.updated", kind: "space", id: domain.spaceA, spaceID: domain.spaceA)])
        await hub.publishOutput(
            session: domain.sessionA, spaceID: domain.spaceA, data: Data("x".utf8), next: OutputCursor(instanceID: UUID(), sessionID: domain.sessionA, offset: 1))
        XCTAssertEqual(sink.count(connection), 1, "No workspace events or output after workspace.read and session.output.read were removed")
    }

    // MARK: - Agent and project scopes (API2-06e)

    func testAgentAndProjectScopes() async throws {
        let dispatcher = dispatcher(Self.composed)
        let (codexOnly, _) = try await grant([.agentControl, .workspaceWrite, .workspaceRead, .projectLaunch, .sessionStart, .sessionExecute], GrantScope(agents: .agents(["trellis-codex"])))
        let placement = JSONValue.object(["kind": .string("pane"), "paneId": pane])
        let claude = await call(dispatcher, "agent.start", ["placement": placement, "agentId": .string("trellis-claude-code")], codexOnly)
        XCTAssertEqual(outcome(claude), "NOT_FOUND", "An agent outside scope looks missing")
        let codex = await call(dispatcher, "agent.start", ["placement": placement, "agentId": .string("trellis-codex")], codexOnly)
        XCTAssertEqual(outcome(codex), "OK")
        let runs = await call(dispatcher, "agent.runs", [:], codexOnly)
        XCTAssertEqual(outcome(runs), "OK", "Runs of other agents stay readable")

        let inScope = UUID(), outside = UUID()
        let (oneProject, _) = try await grant([.projectLaunch, .sessionStart, .sessionExecute], GrantScope(projects: .projects([inScope])))
        let local = JSONValue.object(["kind": .string("local")])
        let launch = await call(dispatcher, "project.launch", ["id": .string(outside.uuidString), "target": local], oneProject)
        XCTAssertEqual(outcome(launch), "NOT_FOUND", "A project outside scope is NOT_FOUND for launch")
        let allowed = await call(dispatcher, "project.launch", ["id": .string(inScope.uuidString.uppercased()), "target": local], oneProject)
        XCTAssertEqual(outcome(allowed), "OK")

        let access = GrantAccess(grant: codexOnly, snapshot: await domain.snapshot())
        XCTAssertTrue(access.canUse(agent: "trellis-codex"))
        XCTAssertFalse(access.canUse(agent: "trellis-claude-code"))
        XCTAssertTrue(access.reaches(project: UUID()), "All projects")
        XCTAssertNil(access.owningSpace(.project, inScope), "Projects and agents live outside spaces")
        XCTAssertEqual(domainV2.performed, ["agent.start", "agent.runs", "project.launch"])
    }

    // MARK: - Editing (API2-06d)

    /// Removing capabilities ends a subscription that needed them; open connections get AUTH_REQUIRED once, then the
    /// re-read grant answers PERMISSION_DENIED. Widening needs the UI's confirmation and doesn't end anything.
    func testNarrowingEndsSubscriptionsAndReauthenticatesWideningAsksFirst() async throws {
        let hub = EventHubV2(instanceID: UUID(), grants: store, now: { [clock] in clock.now })
        await hub.setDelivery { _, _ in true }
        let handler = AuthorizingControlHandler(
            grants: store, domain: domainV2, limiter: AuthenticationRateLimiter(now: { [clock] in clock.now }), idempotency: IdempotencyCache(now: { [clock] in clock.now }),
            events: hub)
        await store.onEdit { edit in Task { await hub.grantEdited(edit.new, narrowed: edit.change.narrows) } }
        let (grant, token) = try await grant([.workspaceRead, .sessionInput, .sessionOutputRead])
        // Two connections of the same grant: one follows events, the other types.
        let v1 = ControlSession(peerUID: geteuid(), handler: handler), v2 = ControlSession(peerUID: geteuid(), handler: handler)
        func send(_ session: ControlSession, _ method: String, _ params: [String: JSONValue] = [:]) async throws -> String {
            let response = try await lastReply(session, request(1, method, params))
            return response["result"] != nil ? "OK" : appCode(response) ?? "?"
        }
        let authV1 = try await send(v1, "auth.authenticate", ["protocolVersion": .number(2), "token": .string(token)])
        let authV2 = try await send(v2, "auth.authenticate", ["protocolVersion": .number(2), "token": .string(token)])
        XCTAssertEqual([authV1, authV2], ["OK", "OK"])
        let subscribed = try await send(v1, "events.subscribe", ["topics": .array([.string("output"), .string("workspace")])])
        let metadataOnly = try await send(v1, "events.subscribe", ["topics": .array([.string("workspace")])])
        XCTAssertEqual([subscribed, metadataOnly], ["OK", "OK"])
        let input: [String: JSONValue] = ["id": .string(domain.sessionA.uuidString), "text": .string("ls\n")]
        let typed = try await send(v2, "session.sendInput", input)
        XCTAssertEqual(typed, "OK")

        // Widening without confirmation changes nothing and ends nothing.
        var wider = grant.settings
        wider.capabilities.insert(.sessionClose)
        do {
            try await store.update(grant.id, to: wider, expectedRevision: grant.revision, confirmedWidening: false)
            XCTFail("Widened without confirmation")
        } catch { XCTAssertEqual(error, .confirmationRequired) }
        let stillAuthenticated = try await send(v2, "session.sendInput", input)
        XCTAssertEqual(stillAuthenticated, "OK")

        var narrower = grant.settings
        narrower.capabilities = [.workspaceRead]
        try await store.update(grant.id, to: narrower, expectedRevision: grant.revision, confirmedWidening: false)
        for _ in 0..<200 where await hub.subscriptionCount != 1 { try await Task.sleep(nanoseconds: 5_000_000) }
        let remaining = await hub.subscriptionCount
        XCTAssertEqual(remaining, 1, "The output subscription ended; the metadata one is still allowed")
        for session in [v1, v2] {
            let first = try await send(session, "session.sendInput", input)
            XCTAssertEqual(first, "AUTH_REQUIRED", "The next call re-reads the grant")
        }
        _ = try await send(v2, "auth.authenticate", ["protocolVersion": .number(2), "token": .string(token)])
        let denied = try await send(v2, "session.sendInput", input)
        XCTAssertEqual(denied, "PERMISSION_DENIED")
        let reading = try await send(v2, "space.list")
        XCTAssertEqual(reading, "OK", "Re-authenticated at the new revision")
        _ = try await send(v1, "auth.authenticate", ["protocolVersion": .number(2), "token": .string(token)])
        let v1Input = try await send(v1, "session.sendInput", input)
        XCTAssertEqual(v1Input, "PERMISSION_DENIED")
    }

    // MARK: - Grant view

    func testGrantGetShowsPresetRevisionAndEveryScope() async throws {
        let project = UUID(), host = UUID()
        let settings = GrantSettings(
            name: "Grok bot", preset: .agentOrchestrator, capabilities: GrantPreset.agentOrchestrator.capabilities!,
            scope: GrantScope(spaces: .created, projects: .projects([project]), hosts: .approved([HostApproval(hostID: host, connectionRevision: 2)]), agents: .agents(["trellis-codex"])))
        let (grant, _) = try await store.create(settings, lifetime: 3600)
        var narrower = settings
        narrower.capabilities.remove(.remoteConnect); narrower.preset = .custom
        try await store.update(grant.id, to: narrower, expectedRevision: 1, confirmedWidening: false)
        let result = await call(dispatcher(MethodCatalogV2.methods), "grant.get", [:], grant)
        guard case .success(.object(let object)) = result, case .object(let view)? = object["grant"] else { return XCTFail("\(result)") }
        XCTAssertEqual(Set(view.keys), ["id", "name", "preset", "revision", "capabilities", "scope", "createdAt", "expiresAt"])
        XCTAssertEqual(view["preset"], .string("custom"))
        XCTAssertEqual(view["revision"], .number(2))
        XCTAssertEqual(view["capabilities"], .array(narrower.capabilities.sorted().map { .string($0.rawValue) }))
        XCTAssertEqual(
            view["scope"],
            .object([
                "spaces": .string("created"), "projects": .array([.string(project.uuidString.lowercased())]),
                "hosts": .array([.object(["hostId": .string(host.uuidString.lowercased()), "connectionRevision": .number(2), "current": .bool(false)])]),
                "agents": .array([.string("trellis-codex")])
            ]))
    }
}

final class DeliverySink: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [UUID: Int] = [:]
    func append(_ connection: UUID, _ data: Data) { lock.withLock { counts[connection, default: 0] += 1 } }
    func count(_ connection: UUID) -> Int { lock.withLock { counts[connection] ?? 0 } }
}

/// The last JSON-RPC reply a session wrote for one request frame.
func lastReply(_ session: ControlSession, _ data: Data) async throws -> [String: Any] {
    let output = await session.receive(data).output
    return try XCTUnwrap(try responses(output).last)
}
