import Darwin
import XCTest
import TrellisCore
@testable import TrellisControl

/// Protocol 2 events (docs/api/v2/events.md, API2-07): the typed stream, redaction, subscriptions, polling and coalescing.
final class EventsV2Tests: XCTestCase {
    private let secrets = MemorySecrets()
    private lazy var store = GrantStore(url: nil, secrets: secrets)
    private let spaceA = UUID(), spaceB = UUID()

    private func grant(_ capabilities: Set<CapabilityV2> = Set(CapabilityV2.allCases), scope: GrantScope = GrantScope()) async throws -> AutomationGrant {
        try await store.create(GrantSettings(name: "Bot", capabilities: capabilities, scope: scope), lifetime: 3600).grant
    }

    private func ref(_ space: UUID? = nil) -> PaneRefV2 { PaneRefV2(pane: UUID(), session: UUID(), tab: UUID(), space: space ?? spaceA) }

    private func events(_ result: Result<JSONValue, ControlError>) throws -> [[String: JSONValue]] {
        guard case .object(let object) = try result.get(), case .array(let items)? = object["events"] else { throw ControlError.internalError }
        return items.compactMap { if case .object(let event) = $0 { event } else { nil } }
    }

    private func value(_ result: Result<JSONValue, ControlError>, _ key: String) throws -> JSONValue? {
        guard case .object(let object) = try result.get() else { return nil }
        return object[key]
    }

    // MARK: Contract

    func testEveryTypeIsInTheContractTable() throws {
        let page = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/api/v2/events.md"), encoding: .utf8)
        for (type, topic) in EventTopicV2.types {
            let row = page.split(separator: "\n").first { $0.hasPrefix("| `\(topic.rawValue)` |") }
            let leaf = type.split(separator: ".").last.map(String.init) ?? type
            XCTAssertTrue(row?.contains(type) == true || row?.contains(leaf) == true, "\(type) is listed under \(topic.rawValue)")
        }
        XCTAssertEqual(Set(EventTopicV2.types.values), Set(EventTopicV2.allCases), "Every topic has types")
        XCTAssertTrue(EventTopicV2.coalescedTypes.isSubset(of: Set(EventTopicV2.types.keys)))
    }

    // MARK: Envelope and ring

    func testPollReturnsTypedEnvelopesInOrder() async throws {
        let hub = EventHubV2(instanceID: UUID(), grants: store)
        let grant = try await grant()
        let pane = ref()
        await hub.publish([.commandFinished(pane, exitCode: 2, duration: 1.5), .tabBusy(tab: pane.tab, space: spaceA, busy: true)])
        let result = await hub.poll(grantID: grant.id, filter: EventFilterV2(topics: [.shell, .attention]), afterSequence: 0, instanceID: nil, timeoutMs: 0, limit: 100)
        let list = try events(result)
        XCTAssertEqual(list.map { $0["type"] }, [.string("command.finished"), .string("tab.busy")])
        let first = list[0]
        XCTAssertEqual(first["sequence"], .number(1))
        XCTAssertEqual(first["topic"], .string("shell"))
        XCTAssertEqual(first["instanceId"], .string(hub.instanceID.uuidString.lowercased()))
        XCTAssertEqual(first["spaceId"], .string(spaceA.uuidString.lowercased()))
        XCTAssertEqual(first["resource"], .object(["kind": .string("session"), "id": .string(pane.session.uuidString.lowercased())]))
        guard case .object(let data)? = first["data"] else { return XCTFail() }
        XCTAssertEqual(data["exitCode"], .number(2), "Numbers are numbers")
        XCTAssertEqual(data["durationMs"], .number(1_500))
        guard case .string(let at)? = first["at"] else { return XCTFail() }
        XCTAssertNotNil(at.wholeMatch(of: /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z/), at)
        XCTAssertEqual(try value(result, "nextSequence"), .number(2))
        // limit, then continue from nextSequence.
        let one = await hub.poll(grantID: grant.id, filter: EventFilterV2(topics: [.shell, .attention]), afterSequence: 0, instanceID: hub.instanceID, timeoutMs: 0, limit: 1)
        XCTAssertEqual(try events(one).count, 1)
        XCTAssertEqual(try value(one, "nextSequence"), .number(1))
        // Events the filter skips still advance nextSequence, so a client never rescans them.
        let none = await hub.poll(grantID: grant.id, filter: EventFilterV2(topics: [.agent]), afterSequence: 0, instanceID: nil, timeoutMs: 0, limit: 10)
        XCTAssertEqual(try events(none).count, 0)
        XCTAssertEqual(try value(none, "nextSequence"), .number(2))
    }

    func testStaleCursorsAreAGapAndAnotherInstanceIsInvalid() async throws {
        let hub = EventHubV2(instanceID: UUID(), grants: store)
        let grant = try await grant()
        let pane = ref()
        await hub.publish((0..<2_001).map { _ in .commandStarted(pane) })
        let gap = await hub.poll(grantID: grant.id, filter: EventFilterV2(topics: [.shell]), afterSequence: 0, instanceID: nil, timeoutMs: 0, limit: 10)
        XCTAssertEqual(try events(gap).count, 0)
        XCTAssertEqual(try value(gap, "gap"), .object(["oldestSequence": .number(2), "action": .string("resnapshot")]))
        XCTAssertEqual(try value(gap, "nextSequence"), .number(2_001))
        let kept = await hub.poll(grantID: grant.id, filter: EventFilterV2(topics: [.shell]), afterSequence: 1, instanceID: nil, timeoutMs: 0, limit: 500)
        XCTAssertNil(try value(kept, "gap"), "The ring keeps the last 2,000")
        XCTAssertEqual(try events(kept).first?["sequence"], .number(2))
        for (after, instance) in [(UInt64(5_000), nil), (UInt64(1), UUID())] {
            guard case .failure(let error) = await hub.poll(grantID: grant.id, filter: EventFilterV2(topics: [.shell]), afterSequence: after, instanceID: instance, timeoutMs: 0, limit: 1)
            else { return XCTFail("Accepted a cursor from the future or another instance") }
            XCTAssertEqual(error.appCode, "INVALID_CURSOR")
        }
        guard case .failure(let refused) = await hub.subscribe(connectionID: UUID(), grant: grant, filter: EventFilterV2(topics: [.shell]), afterSequence: 1, instanceID: UUID())
        else { return XCTFail() }
        XCTAssertEqual(refused.appCode, "INVALID_CURSOR")
    }

    // MARK: Long polling (API2-07c)

    func testPollWaitsForTheFirstEventAndTimesOutEmpty() async throws {
        let hub = EventHubV2(instanceID: UUID(), grants: store)
        let grant = try await grant()
        let pane = ref()
        let started = ContinuousClock.now
        async let waited = hub.poll(grantID: grant.id, filter: EventFilterV2(topics: [.agent]), afterSequence: nil, instanceID: nil, timeoutMs: 2_000, limit: 100)
        try await Task.sleep(for: .milliseconds(500))
        // Other topics and other calls go on while the poll waits.
        await hub.publish([.commandStarted(pane)])
        let other = await hub.poll(grantID: grant.id, filter: EventFilterV2(topics: [.shell]), afterSequence: 0, instanceID: nil, timeoutMs: 0, limit: 1)
        XCTAssertEqual(try events(other).count, 1)
        await hub.publish([.agentState(pane, agentID: "trellis-claude-code", state: .needsInput, previous: .working)])
        let result = await waited
        let elapsed = ContinuousClock.now - started
        XCTAssertEqual(try events(result).map { $0["type"] }, [.string("agent.state")])
        XCTAssertLessThan(elapsed, .milliseconds(1_500), "Returned at the event, not the timeout")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(450))

        let quiet = ContinuousClock.now
        let empty = await hub.poll(grantID: grant.id, filter: EventFilterV2(topics: [.agent]), afterSequence: nil, instanceID: nil, timeoutMs: 2_000, limit: 100)
        let waitedFor = ContinuousClock.now - quiet
        XCTAssertEqual(try events(empty).count, 0)
        XCTAssertGreaterThanOrEqual(waitedFor, .milliseconds(1_950))
        XCTAssertLessThan(waitedFor, .seconds(4))
        let waiting = await hub.waitingPolls
        XCTAssertEqual(waiting, 0)
    }

    func testWaitingPollsAreBoundedPerGrantAndEndOnRevocation() async throws {
        let hub = EventHubV2(instanceID: UUID(), grants: store)
        let grant = try await grant(), other = try await self.grant()
        let filter = EventFilterV2(topics: [.agent])
        let polls = (0..<EventHubV2.maximumPollsPerGrant).map { _ in
            Task { await hub.poll(grantID: grant.id, filter: filter, afterSequence: nil, instanceID: nil, timeoutMs: 10_000, limit: 1) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await hub.waitingPolls < EventHubV2.maximumPollsPerGrant, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard case .failure(let error) = await hub.poll(grantID: grant.id, filter: filter, afterSequence: nil, instanceID: nil, timeoutMs: 1_000, limit: 1) else {
            return XCTFail("A fifth waiting poll was accepted")
        }
        XCTAssertEqual(error.appCode, "LIMIT_EXCEEDED")
        XCTAssertTrue(error.retryable)
        let immediate = await hub.poll(grantID: grant.id, filter: filter, afterSequence: nil, instanceID: nil, timeoutMs: 0, limit: 1)
        XCTAssertNoThrow(try immediate.get(), "A poll that doesn't wait isn't counted")
        let otherGrant = await hub.poll(grantID: other.id, filter: filter, afterSequence: nil, instanceID: nil, timeoutMs: 10, limit: 1)
        XCTAssertNoThrow(try otherGrant.get(), "The bound is per grant")

        // Revocation ends the waiting polls at once with AUTH_REQUIRED.
        try await store.revoke(grant.id)
        await hub.removeGrant(grant.id)
        for poll in polls {
            guard case .failure(let ended) = await poll.value else { return XCTFail("A revoked grant's poll returned events") }
            XCTAssertEqual(ended.appCode, "AUTH_REQUIRED")
        }
    }

    func testACancelledPollReturnsPromptly() async throws {
        let hub = EventHubV2(instanceID: UUID(), grants: store)
        let grant = try await grant()
        let poll = Task { await hub.poll(grantID: grant.id, filter: EventFilterV2(topics: [.agent]), afterSequence: nil, instanceID: nil, timeoutMs: 20_000, limit: 1) }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        poll.cancel()
        _ = await poll.value
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    // MARK: Redaction (API2-07b)

    func testRedactionMatrix() async throws {
        let full = try await grant()
        let noHosts = try await grant(Set(CapabilityV2.allCases).subtracting([.hostRead]))
        let noExecute = try await grant(Set(CapabilityV2.allCases).subtracting([.sessionExecute]))
        let spaceB = try await grant(scope: GrantScope(spaces: .spaces([self.spaceB])))
        let created = try await grant(scope: GrantScope(spaces: .created))
        store.createdSpaceLedger.record(self.spaceB, grant: created.id)
        let current = await store.activeGrant(id: created.id)
        let createdNow = try XCTUnwrap(current)
        let project = UUID(), otherProject = UUID(), host = UUID()
        let projectScoped = try await grant(scope: GrantScope(projects: .projects([project])))
        let approved = try await grant(scope: GrantScope(hosts: .approved([HostApproval(hostID: host, connectionRevision: 2)])))
        let observer = try await grant([.workspaceRead])

        let inA = ref(spaceA)
        let folder = EventDraftV2.folderChanged(inA, path: "/Users/me/secret-project")
        XCTAssertEqual(folder.data(for: full)?["path"], .string("/Users/me/secret-project"))
        XCTAssertNotNil(folder.data(for: noExecute), "folder.changed is delivered…")
        XCTAssertNil(folder.data(for: noExecute)?["path"], "…without its path when the grant can't execute")

        // Space scope, including created scope; space.reordered needs all spaces.
        XCTAssertNil(folder.data(for: spaceB))
        XCTAssertNil(folder.data(for: createdNow), "A created-scope grant gets nothing from other spaces")
        XCTAssertNotNil(EventDraftV2.commandStarted(ref(self.spaceB)).data(for: createdNow))
        var reordered = EventDraftV2("space.reordered", kind: "workspace", id: "", data: ["revision": .number(3)])
        reordered.allSpaces = true
        XCTAssertNotNil(reordered.data(for: full))
        XCTAssertNil(reordered.data(for: spaceB))
        XCTAssertNil(reordered.data(for: createdNow))

        // Remote and host events need host.read and the host in scope; remote ones at its current connection.
        let link = EventDraftV2.remoteLink(host: EventHostV2(id: host, connectionRevision: 2), state: "connected")
        XCTAssertNotNil(link.data(for: full))
        XCTAssertNil(link.data(for: noHosts), "No host.read, no remote.*")
        XCTAssertNotNil(link.data(for: approved))
        XCTAssertNil(EventDraftV2.remoteLink(host: EventHostV2(id: host, connectionRevision: 3), state: "connected").data(for: approved), "A stale approval sees no link")
        XCTAssertNil(EventDraftV2.remoteLink(host: EventHostV2(id: UUID(), connectionRevision: 1), state: "connected").data(for: approved))
        let updated = EventDraftV2.host("host.updated", id: host, revision: 5, connectionRevision: 3, changed: ["destination"])
        XCTAssertNotNil(updated.data(for: approved), "An approved host's own change is visible (it needs reapproval)")
        XCTAssertNil(updated.data(for: noHosts))
        XCTAssertNil(EventDraftV2.agentAvailability(agentID: "trellis-codex", status: "missing", host: EventHostV2(id: UUID(), connectionRevision: 1)).data(for: approved))
        XCTAssertNotNil(EventDraftV2.agentAvailability(agentID: "trellis-codex", status: "installed").data(for: observer), "This Mac's availability needs workspace.read only")

        // Projects need project.read and project scope; a launch's host and folder have their own rules.
        XCTAssertNotNil(EventDraftV2.project("project.created", id: project, revision: 1).data(for: projectScoped))
        XCTAssertNil(EventDraftV2.project("project.created", id: otherProject, revision: 1).data(for: projectScoped))
        XCTAssertNil(EventDraftV2.project("project.created", id: project, revision: 1).data(for: observer))
        let launched = EventDraftV2.projectLaunched(id: project, space: spaceA, target: .host(host), folder: "/srv/app", hostConnectionRevision: 2)
        XCTAssertEqual(launched.data(for: full)?["hostId"], .string(host.uuidString.lowercased()))
        XCTAssertEqual(launched.data(for: full)?["folder"], .string("/srv/app"))
        XCTAssertNil(launched.data(for: noExecute)?["folder"])
        XCTAssertNil(launched.data(for: noHosts)?["hostId"])
        XCTAssertEqual(launched.data(for: noHosts)?["target"], .object(["kind": .string("host")]))

        // Tasks need task.read, appearance theme.read; the grant topic only reaches its own grant.
        let run = EventDraftV2.taskRun(inA, taskID: "swift: build", run: nil)
        XCTAssertNil(run.data(for: observer))
        XCTAssertNotNil(run.data(for: full))
        let appearance = EventDraftV2.appearance(mode: "dark", lightThemeID: "a", darkThemeID: "b", effectiveThemeID: "b", revision: 2)
        XCTAssertNil(appearance.data(for: observer))
        XCTAssertNotNil(appearance.data(for: spaceB), "Appearance is global: theme.read, not space scope")
        XCTAssertNotNil(EventDraftV2.grantChanged(observer).data(for: observer))
        XCTAssertNil(EventDraftV2.grantChanged(observer).data(for: full))
        let themeOnly = try await grant([.themeRead])
        XCTAssertNil(EventDraftV2.commandStarted(inA).data(for: themeOnly), "Workspace topics need workspace.read")
    }

    /// No event carries command text, output, environment values or secrets: builders take none, and what they serialize
    /// is checked as text.
    func testSerializedEventsHoldNoCommandTextOrSecrets() async throws {
        let hub = EventHubV2(instanceID: UUID(), grants: store)
        let grant = try await grant()
        let pane = ref()
        var shell = ShellIntegrationState()
        shell.apply(.commandStart(commandLine: "export TOKEN=hunter2 && make deploy"), at: Date())
        shell.apply(.commandFinished(exitCode: 1), at: Date().addingTimeInterval(2))
        await hub.publish([
            .commandStarted(pane), .commandFinished(pane, exitCode: shell.lastExitCode, duration: shell.lastDuration),
            .agentSettings(pane, agentID: "trellis-claude-code", settings: AgentSettings(model: "opus", effort: "high")),
            .taskRun(pane, taskID: "deploy", run: TaskRun(taskID: "deploy", name: "make deploy", at: Date()))
        ])
        let result = await hub.poll(grantID: grant.id, filter: EventFilterV2(topics: Set(EventTopicV2.allCases)), afterSequence: 0, instanceID: nil, timeoutMs: 0, limit: 100)
        let text = String(decoding: try JSONEncoder().encode(try result.get()), as: UTF8.self)
        XCTAssertEqual(try events(result).count, 4)
        for secret in ["hunter2", "TOKEN", "make", "export"] { XCTAssertFalse(text.contains(secret), "\(secret) in \(text)") }
    }

    // MARK: Subscriptions on the socket

    private func handler(_ hub: EventHubV2) -> AuthorizingControlHandler {
        let domain = FakeDomain()
        return AuthorizingControlHandler(grants: store, domain: domain, v2Domain: FakeDomainV2(base: domain), eventsV2: hub)
    }

    private func session(_ handler: AuthorizingControlHandler, _ token: String, reply: (@Sendable (Data) -> Bool)? = nil) async throws -> ControlSession {
        let session = ControlSession(peerUID: geteuid(), handler: handler, reply: reply)
        let auth = try responses(await session.receive(request(1, "auth.authenticate", ["protocolVersion": .number(2), "token": .string(token)])).output)
        XCTAssertNotNil(auth.last?["result"])
        return session
    }

    private func call(_ session: ControlSession, _ method: String, _ params: [String: JSONValue] = [:]) async throws -> [String: Any] {
        let output = await session.receive(request(2, method, params)).output
        return try XCTUnwrap(try responses(output).last)
    }

    func testSubscriptionsDeliverTypedEventsAndNeedEachTopicsCapability() async throws {
        let hub = EventHubV2(instanceID: UUID(), grants: store)
        let log = DeliveryLog()
        await hub.setDelivery { _, data in log.deliver(data) }
        let handler = handler(hub)
        let (observer, observerToken) = try await store.create(GrantSettings(name: "Observer", capabilities: [.workspaceRead]), lifetime: 3600)
        let session = try await session(handler, observerToken)

        let denied = try await call(session, "events.subscribe", ["topics": .array([.string("agent"), .string("remote"), .string("task")])])
        let error = try XCTUnwrap(denied["error"] as? [String: Any])
        XCTAssertEqual((error["data"] as? [String: Any])?["code"] as? String, "PERMISSION_DENIED")
        XCTAssertEqual(((error["data"] as? [String: Any])?["details"] as? [String: Any])?["missing"] as? [String], ["host.read", "task.read"])
        let empty = try await call(session, "events.subscribe", ["topics": .array([])])
        XCTAssertEqual((empty["error"] as? [String: Any])?["code"] as? Int, -32602)

        let subscribe = try await call(session, "events.subscribe", ["topics": .array([.string("agent"), .string("grant")])])
        let subscribed = try XCTUnwrap(subscribe["result"] as? [String: Any])
        let subscriptionID = try XCTUnwrap(subscribed["subscriptionId"] as? String)
        XCTAssertEqual(subscriptionID, subscriptionID.lowercased())
        XCTAssertEqual(subscribed["instanceId"] as? String, hub.instanceID.uuidString.lowercased())
        let pane = ref()
        await hub.publish([.agentState(pane, agentID: "trellis-codex", state: .working, previous: .ready), .commandStarted(pane)])
        let event = try XCTUnwrap(log.messages.last)
        XCTAssertEqual(event["method"] as? String, "events.event")
        let params = try XCTUnwrap(event["params"] as? [String: Any])
        XCTAssertEqual(params["subscriptionId"] as? String, subscriptionID)
        XCTAssertEqual(params["type"] as? String, "agent.state")
        XCTAssertEqual((params["data"] as? [String: Any])?["previous"] as? String, "ready")
        XCTAssertEqual(log.messages.count, 1, "Only subscribed topics")

        // grant.changed reaches only the edited grant's subscribers.
        let other = try await self.grant()
        await hub.grantEdited(other, narrowed: false)
        XCTAssertEqual(log.messages.count, 1)
        await hub.grantEdited(observer, narrowed: false)
        XCTAssertEqual((log.messages.last?["params"] as? [String: Any])?["type"] as? String, "grant.changed")

        let gone = try await call(session, "events.unsubscribe", ["subscriptionId": .string(subscriptionID)])
        XCTAssertEqual(((gone["result"] as? [String: Any])?["deleted"] as? [String: Any])?["kind"] as? String, "subscription")
        let again = try await call(session, "events.unsubscribe", ["subscriptionId": .string(subscriptionID)])
        XCTAssertEqual(((again["error"] as? [String: Any])?["data"] as? [String: Any])?["code"] as? String, "NOT_FOUND")
    }

    func testANarrowedGrantStopsReceivingAtTheNextEvent() async throws {
        let hub = EventHubV2(instanceID: UUID(), grants: store)
        let log = DeliveryLog()
        await hub.setDelivery { _, data in log.deliver(data) }
        let grant = try await grant([.workspaceRead, .sessionOutputRead])
        _ = await hub.subscribe(connectionID: UUID(), grant: grant, filter: EventFilterV2(topics: [.shell, .grant]), afterSequence: nil, instanceID: nil)
        _ = await hub.subscribe(connectionID: UUID(), grant: grant, filter: EventFilterV2(topics: [.output]), afterSequence: nil, instanceID: nil)
        XCTAssertTrue(hub.hasOutputSubscribers)
        await hub.publish([.commandStarted(ref(spaceA))])
        XCTAssertEqual(log.messages.count, 1)

        // Narrowed to space B: the edit applies to the next event, before any observer runs.
        var settings = grant.settings
        settings.scope.spaces = .spaces([spaceB])
        settings.capabilities = [.workspaceRead]
        let narrowed = try await store.update(grant.id, to: settings, expectedRevision: grant.revision, confirmedWidening: false)
        await hub.publish([.commandStarted(ref(spaceA))])
        XCTAssertEqual(log.messages.count, 1, "Out of scope after the edit")
        await hub.publish([.commandStarted(ref(spaceB))])
        XCTAssertEqual(log.messages.count, 2)

        // The edit's observer: grant.changed first, then the output subscription (no session.output.read) ends.
        await hub.grantEdited(narrowed, narrowed: true)
        XCTAssertEqual((log.messages.last?["params"] as? [String: Any])?["type"] as? String, "grant.changed")
        XCTAssertEqual(((log.messages.last?["params"] as? [String: Any])?["data"] as? [String: Any])?["revision"] as? Int, Int(narrowed.revision))
        let remaining = await hub.subscriptionCount
        XCTAssertEqual(remaining, 1, "The metadata subscription stays")
        XCTAssertFalse(hub.hasOutputSubscribers)
    }

    func testSubscribeReplaysAfterASequenceAndSkipsWhatItCantSee() async throws {
        let hub = EventHubV2(instanceID: UUID(), grants: store)
        let log = DeliveryLog()
        await hub.setDelivery { _, data in log.deliver(data) }
        let scoped = try await grant(scope: GrantScope(spaces: .spaces([spaceA])))
        await hub.publish([.commandStarted(ref(spaceA)), .commandStarted(ref(spaceB)), .commandStarted(ref(spaceA))])
        _ = await hub.subscribe(connectionID: UUID(), grant: scoped, filter: EventFilterV2(topics: [.shell]), afterSequence: 0, instanceID: hub.instanceID)
        XCTAssertEqual(log.messages.compactMap { ($0["params"] as? [String: Any])?["sequence"] as? Int }, [1, 3])
        await hub.publish([.commandStarted(ref(spaceA))])
        XCTAssertEqual(log.messages.compactMap { ($0["params"] as? [String: Any])?["sequence"] as? Int }, [1, 3, 4], "Nothing twice")
        // resourceIds matches the pane, its session or its space.
        let pane = ref(spaceA)
        _ = await hub.subscribe(connectionID: UUID(), grant: scoped, filter: EventFilterV2(topics: [.shell], resourceIDs: [pane.pane]), afterSequence: nil, instanceID: nil)
        let before = log.messages.count
        await hub.publish([.commandStarted(pane), .commandStarted(ref(spaceA))])
        XCTAssertEqual(log.messages.count, before + 3, "The filtered subscription got only its pane's event")
        _ = await hub.subscribe(connectionID: UUID(), grant: scoped, filter: EventFilterV2(topics: [.shell]), afterSequence: 1, instanceID: nil)
        let gapLog = log.messages.count
        await hub.publish((0..<2_100).map { _ in .commandStarted(ref(spaceB)) })
        _ = await hub.subscribe(connectionID: UUID(), grant: scoped, filter: EventFilterV2(topics: [.shell]), afterSequence: 1, instanceID: nil)
        XCTAssertEqual(log.messages.count, gapLog + 1)
        XCTAssertEqual(log.messages.last?["method"] as? String, "events.gap")
    }

    /// `session.output` is pushed to output subscriptions only, never kept in the ring, and checked per chunk.
    func testOutputGoesOnlyToOutputSubscriptionsAndNeverToTheRing() async throws {
        let hub = EventHubV2(instanceID: UUID(), grants: store)
        let log = DeliveryLog()
        await hub.setDelivery { _, data in log.deliver(data) }
        let reader = try await grant([.workspaceRead, .sessionOutputRead], scope: GrantScope(spaces: .spaces([spaceA])))
        XCTAssertFalse(hub.hasOutputSubscribers)
        _ = await hub.subscribe(connectionID: UUID(), grant: reader, filter: EventFilterV2(topics: [.output]), afterSequence: nil, instanceID: nil)
        XCTAssertTrue(hub.hasOutputSubscribers)
        let session = UUID()
        let next = OutputCursor(instanceID: hub.instanceID, sessionID: session, offset: 5)
        await hub.publishOutput(session: session, spaceID: spaceA, data: Data("hello".utf8), next: next)
        await hub.publishOutput(session: UUID(), spaceID: spaceB, data: Data("other".utf8), next: next)
        XCTAssertEqual(log.messages.count, 1, "Only the space in scope")
        let params = try XCTUnwrap(log.messages.first?["params"] as? [String: Any])
        XCTAssertEqual(params["type"] as? String, "session.output")
        XCTAssertNil(params["sequence"], "Output has no sequence: it isn't in the ring")
        let data = try XCTUnwrap(params["data"] as? [String: Any])
        XCTAssertEqual(data["base64"] as? String, Data("hello".utf8).base64EncodedString())
        XCTAssertEqual(data["cursor"] as? String, OutputCursor(instanceID: hub.instanceID, sessionID: session, offset: 0).token)
        XCTAssertEqual(data["nextCursor"] as? String, next.token)
        let sequence = await hub.currentSequence
        XCTAssertEqual(sequence, 0)
    }

    /// A waiting poll on the socket is answered out of order, so the connection keeps serving other calls.
    func testAWaitingPollDoesNotBlockTheConnection() async throws {
        let hub = EventHubV2(instanceID: UUID(), grants: store)
        let handler = handler(hub)
        let (_, token) = try await store.create(GrantSettings(name: "Bot", capabilities: Set(CapabilityV2.allCases)), lifetime: 3600)
        let replies = DeliveryLog()
        let session = try await session(handler, token, reply: { replies.deliver($0) })
        let started = ContinuousClock.now
        let deferred = await session.receive(request(7, "events.poll", ["topics": .array([.string("agent")]), "timeoutMs": .number(5_000)])).output
        XCTAssertTrue(deferred.isEmpty, "The poll is answered later")
        let info = try await call(session, "system.info")
        XCTAssertNotNil(info["result"], "Later frames are served while the poll waits")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        await hub.publish([.agentStarted(ref(), agentID: "trellis-codex")])
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while replies.messages.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let answer = try XCTUnwrap(replies.messages.first)
        XCTAssertEqual(answer["id"] as? Int, 7)
        XCTAssertEqual((((answer["result"] as? [String: Any])?["events"] as? [[String: Any]])?.first)?["type"] as? String, "agent.started")
        // A closed connection cancels what still waits.
        _ = await session.receive(request(8, "events.poll", ["topics": .array([.string("agent")]), "timeoutMs": .number(20_000)]))
        await session.connectionClosed()
        let afterClose = ContinuousClock.now.advanced(by: .seconds(2))
        while await hub.waitingPolls > 0, ContinuousClock.now < afterClose { try await Task.sleep(for: .milliseconds(10)) }
        let waiting = await hub.waitingPolls
        XCTAssertEqual(waiting, 0)
    }

    // MARK: Coalescing (risk table: event volume)

    func testLiveStatusIsCoalescedAndTheFinalStateIsNeverDropped() async throws {
        let hub = EventHubV2(instanceID: UUID(), grants: store)
        let grant = try await grant()
        let pane = ref()
        let started = ContinuousClock.now
        var reports = 0
        // A program reporting progress as fast as it can for about a second: 4 per window at most get through.
        while ContinuousClock.now - started < .seconds(1) {
            reports += 1
            await hub.publish([.progress(pane, TerminalProgress(state: .normal, percent: reports % 100))])
        }
        let last = TerminalProgress(state: .normal, percent: 100)
        await hub.publish([.progress(pane, last)])
        let elapsed = (ContinuousClock.now - started) / .milliseconds(250)
        try await Task.sleep(for: .milliseconds(400))
        let result = await hub.poll(grantID: grant.id, filter: EventFilterV2(topics: [.attention]), afterSequence: 0, instanceID: nil, timeoutMs: 0, limit: 500)
        let list = try events(result)
        XCTAssertGreaterThan(reports, 100)
        XCTAssertLessThanOrEqual(list.count, Int(elapsed.rounded(.up)) + 2, "At most one per 250 ms, plus the final state")
        XCTAssertEqual(list.last?["data"], .object(["state": .string("normal"), "percent": .number(100), "sessionId": .string(pane.session.uuidString.lowercased())]))

        // Agent states: previous is what clients were last told; a bounce back to it within the window is nothing.
        await hub.publish([.agentState(pane, agentID: "a", state: .working, previous: .ready)])
        await hub.publish([.agentState(pane, agentID: "a", state: .needsInput, previous: .working)])
        await hub.publish([.agentState(pane, agentID: "a", state: .done, previous: .needsInput)])
        try await Task.sleep(for: .milliseconds(400))
        let agents = try events(await hub.poll(grantID: grant.id, filter: EventFilterV2(topics: [.agent]), afterSequence: 0, instanceID: nil, timeoutMs: 0, limit: 10))
        func field(_ event: [String: JSONValue], _ key: String) -> JSONValue? { if case .object(let data)? = event["data"] { data[key] } else { nil } }
        XCTAssertEqual(agents.compactMap { field($0, "state") }, [.string("working"), .string("done")])
        XCTAssertEqual(agents.compactMap { field($0, "previous") }, [.string("ready"), .string("working")])
        await hub.publish([.agentState(pane, agentID: "a", state: .working, previous: .done)])
        await hub.publish([.agentState(pane, agentID: "a", state: .needsInput, previous: .working)])
        await hub.publish([.agentState(pane, agentID: "a", state: .working, previous: .needsInput)])
        try await Task.sleep(for: .milliseconds(400))
        let bounced = try events(await hub.poll(grantID: grant.id, filter: EventFilterV2(topics: [.agent]), afterSequence: 0, instanceID: nil, timeoutMs: 0, limit: 10))
        XCTAssertEqual(bounced.count, 3, "working, then back to working within the window: only the first change")

        // Shell marks are never coalesced: one event per mark.
        for _ in 0..<50 { await hub.publish([.commandStarted(pane), .commandFinished(pane, exitCode: 0, duration: 0.01)]) }
        let shell = try events(await hub.poll(grantID: grant.id, filter: EventFilterV2(topics: [.shell]), afterSequence: 0, instanceID: nil, timeoutMs: 0, limit: 500))
        XCTAssertEqual(shell.count, 100)
    }

    // MARK: Workspace diff (API2-07d)

    func testRestartsReconfiguresAndUpdatesAreReported() throws {
        let domain = FakeDomain()
        let old = domain.snapshotValue
        var new = old
        // Restart: the pane gets a new session; reconfigure: same session, new launch; rename: tab.updated with changed.
        let restarted = UUID()
        new.sessions.removeValue(forKey: domain.sessionA)
        new.sessions[restarted] = WorkspaceSession(id: restarted)
        new.panes[domain.paneA]?.sessionID = restarted
        new.sessions[domain.sessionB]?.launch = .agent(AgentLaunch(agentID: "trellis-codex", directory: "/tmp"))
        new.tabs[domain.tabB]?.title = "Logs"
        new.tabs[domain.tabB]?.revision += 1
        new.spaces[0].tabIDs = [domain.tabA]
        new.revision += 1
        let events = WorkspaceDiffV2.diff(old, new)
        let replaced = try XCTUnwrap(events.first { $0.type == "session.replaced" })
        XCTAssertEqual(replaced.resourceID, restarted.uuidString.lowercased())
        XCTAssertEqual(replaced.data["previousId"], .string(domain.sessionA.uuidString.lowercased()))
        XCTAssertEqual(replaced.data["paneId"], .string(domain.paneA.uuidString.lowercased()))
        let launch = try XCTUnwrap(events.first { $0.type == "session.launchChanged" })
        XCTAssertEqual(launch.data["launch"], .object(["kind": .string("agent")]))
        XCTAssertEqual(launch.spaceID, domain.spaceB)
        XCTAssertFalse(String(describing: launch.data).contains("/tmp"), "Only the kind: the directory needs session.execute")
        let renamed = try XCTUnwrap(events.first { $0.type == "tab.updated" })
        XCTAssertEqual(renamed.data["changed"], .array([.string("title")]))
        XCTAssertEqual(renamed.data["revision"], .number(Double(new.tabs[domain.tabB]!.revision)))
        let pane = try XCTUnwrap(events.first { $0.type == "pane.updated" })
        XCTAssertEqual(pane.data["changed"], .array([.string("sessionId")]))
        XCTAssertNil(events.first { $0.type.hasPrefix("session.state") }, "A replaced stopped session has no state transition")

        // Exits carry a numeric exit code; reorders of tabs and spaces are reported; removals come first.
        var exited = new
        exited.sessions[restarted]?.state = .exited
        exited.sessions[restarted]?.exitCode = 3
        let exit = WorkspaceDiffV2.diff(new, exited)
        XCTAssertEqual(exit.map(\.type), ["session.state", "session.exited"])
        XCTAssertEqual(exit[1].data["exitCode"], .number(3))
        XCTAssertEqual(exit[0].data["previous"], .string("stopped"))
        var reordered = new
        reordered.spaces.reverse()
        reordered.revision += 1
        let spaces = WorkspaceDiffV2.diff(new, reordered)
        XCTAssertEqual(spaces.map(\.type), ["space.reordered"])
        XCTAssertTrue(spaces[0].allSpaces)
        var closed = new
        closed.spaces.removeLast()
        closed.tabs.removeValue(forKey: domain.tabB)
        closed.panes.removeValue(forKey: domain.paneB)
        closed.sessions.removeValue(forKey: domain.sessionB)
        XCTAssertEqual(WorkspaceDiffV2.diff(new, closed).map(\.type), ["space.deleted", "tab.deleted", "pane.deleted"])
    }

    func testHostAndProjectLibraryChanges() {
        let draft = try! HostDraft(name: "Prod", destination: "prod").validated { _ in false }
        let host = SavedHost(id: UUID(), draft: draft, revision: 1)
        var moved = host
        moved.destination = "prod2"; moved.revision = 2; moved.connectionRevision = 2
        let gone = SavedHost(id: UUID(), draft: draft, revision: 4)
        let events = EventDraftV2.hostChanges([host, gone], [moved])
        XCTAssertEqual(events.map(\.type), ["host.deleted", "host.updated"])
        XCTAssertEqual(events[1].data["changed"], .array([.string("destination")]))
        XCTAssertEqual(events[1].data["connectionRevision"], .number(2))
        let project = ProjectDefinition(name: "Shop", revision: 1)
        var launched = project
        launched.lastFolders = ["local": "/srv/shop"]; launched.revision = 2
        let projects = EventDraftV2.projectChanges([], [project]) + EventDraftV2.projectChanges([project], [launched]) + EventDraftV2.projectChanges([launched], [])
        XCTAssertEqual(projects.map(\.type), ["project.created", "project.updated", "project.deleted"])
        XCTAssertEqual(projects[1].data["changed"], .array([.string("lastFolders")]))
        XCTAssertFalse(String(describing: projects.map(\.data)).contains("/srv/shop"), "Never the folders themselves")
    }
}
