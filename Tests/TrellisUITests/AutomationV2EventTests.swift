import AppKit
import Darwin
import XCTest
import TrellisControl
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// Protocol 2 events from their real sources (API2-07a–d): the model's live-state hooks and published transitions feed an
/// `EventHubV2` through one serial forwarder, as `AppMain`'s `EventForwarder` does.
@MainActor
final class EventsHarness {
    let base: Harness
    let hub: EventHubV2
    var model: AppWorkspaceModel { base.model }
    private let feed: AsyncStream<Item>.Continuation

    private enum Item: Sendable {
        case transition(WorkspaceSnapshot, WorkspaceSnapshot)
        case live([EventDraftV2])
    }

    init() async throws {
        base = try Harness()
        let hub = EventHubV2(instanceID: UUID(), grants: base.grants)
        self.hub = hub
        base.handler = AuthorizingControlHandler(
            grants: base.grants, domain: AutomationService(model: base.model, hosts: base.hosts), idempotency: IdempotencyCache(now: { [clock = base.clock] in clock.now }),
            v2Domain: AutomationServiceV2(model: base.model, hosts: base.hosts, instanceID: hub.instanceID), eventsV2: hub)
        let (stream, feed) = AsyncStream<Item>.makeStream()
        self.feed = feed
        Task.detached {
            for await item in stream {
                switch item {
                case .transition(let old, let new): await hub.publish(WorkspaceDiffV2.diff(old, new))
                case .live(let events): await hub.publish(events)
                }
            }
        }
        model.onWorkspaceTransition = { feed.yield(.transition($0, $1)) }
        model.onLiveEvents = { feed.yield(.live($0)) }
        await base.grants.onEdit { edit in Task { await hub.grantEdited(edit.new, narrowed: edit.change.narrows) } }
    }

    func grant(_ capabilities: Set<CapabilityV2> = Set(CapabilityV2.allCases), scope: GrantScope = GrantScope()) async throws -> (AutomationGrant, String) {
        try await base.grants.create(GrantSettings(name: "Bot", capabilities: capabilities, scope: scope), lifetime: 3600)
    }

    var sequence: UInt64 { get async { await hub.currentSequence } }

    /// Events after `after` that the grant sees, waiting up to `timeoutMs` for the first.
    func poll(_ grant: AutomationGrant, _ topics: Set<EventTopicV2>, after: UInt64, timeoutMs: Int = 0) async throws -> [[String: Any]] {
        let result = try await hub.poll(grantID: grant.id, filter: EventFilterV2(topics: topics), afterSequence: after, instanceID: nil, timeoutMs: timeoutMs, limit: 500).get()
        let data = try JSONEncoder().encode(result)
        return try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["events"] as? [[String: Any]])
    }

    /// Waits for the first event of `type` after `after`, measuring from `since`.
    func first(_ type: String, _ grant: AutomationGrant, after: UInt64, since: ContinuousClock.Instant, timeout: Duration = .seconds(3)) async throws -> (
        event: [String: Any], elapsed: Duration
    ) {
        let topic = try XCTUnwrap(EventTopicV2.types[type])
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var cursor = after
        while ContinuousClock.now < deadline {
            let events = try await poll(grant, [topic], after: cursor, timeoutMs: 200)
            if let event = events.first(where: { $0["type"] as? String == type }) { return (event, ContinuousClock.now - since) }
            if let last = events.last?["sequence"] as? Int { cursor = UInt64(last) }
        }
        XCTFail("No \(type) event")
        throw CancellationError()
    }

    func cleanUp() {
        model.terminals.values.forEach {
            $0.requestTermination(force: true); $0.adapter.detach()
        }
        base.discardPreferences()
    }
}

func data(_ event: [String: Any]) -> [String: Any] { event["data"] as? [String: Any] ?? [:] }

final class AutomationV2EventTests: XCTestCase {
    /// A space with two tabs running `sleep`; tab A is selected, so tab B's pane is out of view.
    @MainActor
    private func makeTabs(_ h: EventsHarness) async throws -> (a: UUID, b: UUID, paneA: UUID, paneB: UUID, space: UUID) {
        let created = await h.model.createSpace(name: "W", startSession: false)
        let spaceID = try XCTUnwrap(created)
        let a = try XCTUnwrap(h.model.presentation.selectedTab?.id)
        let tab = await h.model.createTab(spaceID: spaceID, startSessions: false)
        let b = try XCTUnwrap(tab)
        let paneA = try XCTUnwrap(h.model.snapshot.tabs[a]?.activePaneID), paneB = try XCTUnwrap(h.model.snapshot.tabs[b]?.activePaneID)
        for pane in [paneA, paneB] {
            _ = try await h.model.service.execute(
                .configureStoppedSession(paneID: pane, launch: .process(executable: "/bin/sleep", arguments: ["30"], directory: "/tmp")))
            await h.model.refresh()
            await h.model.start(paneID: pane)
        }
        await h.model.selectTab(a)
        return (a, b, paneA, paneB, spaceID)
    }

    /// API2-07a: each live source produces its event within 250 ms.
    @MainActor
    func testLiveSourcesEmitTheirEventsWithin250Milliseconds() async throws {
        let h = try await EventsHarness()
        defer { h.cleanUp() }
        let (grant, _) = try await h.grant()
        let t = try await makeTabs(h)
        let terminal = try XCTUnwrap(h.model.terminals[t.paneB])
        let session = terminal.sessionID
        func check(_ type: String, _ trigger: () throws -> Void) async throws -> [String: Any] {
            let after = await h.sequence
            let since = ContinuousClock.now
            try trigger()
            let (event, elapsed) = try await h.first(type, grant, after: after, since: since)
            XCTAssertLessThan(elapsed, .milliseconds(250), type)
            return event
        }

        // Input waits (FR-T06): a bell out of view is `attention`; looking at the pane clears it.
        let bell = try await check("pane.needsInput") { terminal.onAttentionRequested?() }
        XCTAssertEqual(data(bell)["reason"] as? String, "attention")
        XCTAssertEqual(bell["spaceId"] as? String, t.space.uuidString.lowercased())
        XCTAssertEqual((bell["resource"] as? [String: Any])?["id"] as? String, t.paneB.uuidString.lowercased())

        // OSC 9;4 progress (FR-T09) and busy tabs (FR-T05).
        let progress = try await check("pane.progress") { terminal.onProgress?(TerminalProgressReport(kind: .set, value: 40)) }
        XCTAssertEqual(data(progress)["percent"] as? Int, 40)
        XCTAssertEqual(data(progress)["state"] as? String, "normal")
        let busy = try await check("tab.busy") { terminal.onOutput?() }
        XCTAssertEqual(data(busy)["busy"] as? Bool, true)

        // Shell-integration marks: one event per mark, with numbers, never the command line.
        let started = try await check("command.started") { terminal.onShellIntegrationEvent?(.commandStart(commandLine: "deploy --token=SECRET-CMD-7")) }
        XCTAssertEqual((started["resource"] as? [String: Any])?["id"] as? String, session.uuidString.lowercased())
        let finished = try await check("command.finished") { terminal.onShellIntegrationEvent?(.commandFinished(exitCode: 3)) }
        XCTAssertEqual(data(finished)["exitCode"] as? Int, 3)
        XCTAssertNotNil(data(finished)["durationMs"] as? Int)
        let folder = try await check("folder.changed") { terminal.onShellIntegrationEvent?(.promptStart(directory: "/private/tmp")) }
        XCTAssertEqual(data(folder)["path"] as? String, "/private/tmp")

        // Agent hooks (FR-AG18): a typed agent's own hooks start it and drive its state.
        try await Task.sleep(for: .milliseconds(300))
        let agentStarted = try await check("agent.started") {
            terminal.onShellIntegrationEvent?(.commandStart(commandLine: "claude"))
            h.model.receiveAgentEvent(sessionID: session, event: "working")
        }
        XCTAssertEqual(data(agentStarted)["agentId"] as? String, "trellis-claude-code")
        try await Task.sleep(for: .milliseconds(300))
        let needs = try await check("agent.state") { h.model.receiveAgentEvent(sessionID: session, event: "needs-input") }
        XCTAssertEqual(data(needs)["state"] as? String, "needsInput")
        XCTAssertEqual(data(needs)["previous"] as? String, "working")
        let settings = try await check("agent.settings") { h.model.receiveAgentEvent(sessionID: session, event: "info model=opus effort=high") }
        XCTAssertEqual(data(settings)["model"] as? String, "opus")
        let ended = try await check("agent.ended") { terminal.onShellIntegrationEvent?(.commandFinished(exitCode: 0)) }
        XCTAssertEqual(data(ended)["agentId"] as? String, "trellis-claude-code")

        // Task runs (FR-TK07) follow the marks: submitted, running, finished.
        try await Task.sleep(for: .milliseconds(300))
        terminal.onShellIntegrationEvent?(.promptStart(directory: "/private/tmp"))
        let submitted = try await check("task.run") { h.model.taskRuns[t.paneB] = TaskRun(taskID: "swift: build", name: "swift: build", at: Date()) }
        XCTAssertEqual(data(submitted)["phase"] as? String, "submitted")
        XCTAssertEqual((submitted["resource"] as? [String: Any])?["id"] as? String, "swift: build")
        let after = await h.sequence
        terminal.onShellIntegrationEvent?(.commandStart(commandLine: "swift build"))
        terminal.onShellIntegrationEvent?(.commandFinished(exitCode: 1))
        try await Task.sleep(for: .milliseconds(100))
        let runs = try await h.poll(grant, [.task], after: after).map { data($0) }
        XCTAssertEqual(runs.compactMap { $0["phase"] as? String }, ["running", "finished"])
        XCTAssertEqual(runs.last?["exitCode"] as? Int, 1)

        // Remote link changes (FR-RW07).
        let host = UUID()
        let at = Date(timeIntervalSince1970: 1_900_000_000.25)
        let link = try await check("remote.link") { h.model.remoteLinks[host] = .reconnecting(attempt: 2, at: at) }
        XCTAssertEqual(data(link)["state"] as? String, "reconnecting")
        XCTAssertEqual(data(link)["attempt"] as? Int, 2)
        XCTAssertEqual(data(link)["nextAttemptAt"] as? String, "2030-03-17T17:46:40.250Z")

        // Maximizing changes the pane.
        let maximized = try await check("pane.updated") { h.model.maximizedPanes[t.a] = t.paneA }
        XCTAssertEqual(data(maximized)["changed"] as? [String], ["maximized"])

        // Nothing serialized carries the command line, its output or environment values.
        let everything = try await h.poll(grant, Set(EventTopicV2.allCases).subtracting([.output]), after: 0)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: everything), as: UTF8.self)
        for secret in ["SECRET-CMD", "deploy", "swift build", "claude\""] { XCTAssertFalse(text.contains(secret), secret) }
    }

    /// API2-07d: a restart replaces the session; reconfiguring a stopped pane changes its launch.
    @MainActor
    func testRestartEmitsReplacedAndReconfiguringEmitsLaunchChanged() async throws {
        let h = try await EventsHarness()
        defer { h.cleanUp() }
        let (grant, _) = try await h.grant()
        let created = await h.model.createSpace(name: "R", startSession: false)
        let space = try XCTUnwrap(created)
        let pane = try XCTUnwrap(h.model.presentation.activePane?.id)
        let first = try XCTUnwrap(h.model.snapshot.panes[pane]?.sessionID)

        var after = await h.sequence
        let configured = try await h.model.service.execute(.configureStoppedSession(paneID: pane, launch: .process(executable: "/usr/bin/true", arguments: [], directory: "/tmp")))
        h.model.publish(configured.snapshot)
        let launch = try await h.first("session.launchChanged", grant, after: after, since: .now)
        XCTAssertEqual((data(launch.event)["launch"] as? [String: Any])?["kind"] as? String, "process")
        XCTAssertEqual(launch.event["spaceId"] as? String, space.uuidString.lowercased())
        XCTAssertFalse(String(describing: launch.event).contains("/usr/bin/true"), "The executable needs session.execute; only the kind is sent")

        after = await h.sequence
        await h.model.start(paneID: pane)
        let exited = try await h.first("session.exited", grant, after: after, since: .now, timeout: .seconds(10))
        XCTAssertEqual(data(exited.event)["exitCode"] as? Int, 0)

        after = await h.sequence
        await h.model.restartPane(pane, startSession: false)
        let replaced = try await h.first("session.replaced", grant, after: after, since: .now)
        let second = try XCTUnwrap(h.model.snapshot.panes[pane]?.sessionID)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual((replaced.event["resource"] as? [String: Any])?["id"] as? String, second.uuidString.lowercased())
        XCTAssertEqual(data(replaced.event)["previousId"] as? String, first.uuidString.lowercased())
        XCTAssertEqual(data(replaced.event)["paneId"] as? String, pane.uuidString.lowercased())
    }

    /// API2-07b through the real model: scope, host and execute redaction.
    @MainActor
    func testEventsAreRedactedByScopeAndCapability() async throws {
        let h = try await EventsHarness()
        defer { h.cleanUp() }
        let (full, _) = try await h.grant()
        let (noHosts, _) = try await h.grant(Set(CapabilityV2.allCases).subtracting([.hostRead, .sessionExecute]))
        let (created, token) = try await h.grant(scope: GrantScope(spaces: .created))
        let t = try await makeTabs(h)
        let start = await h.sequence

        // A created-scope grant makes its own space through protocol 2 and sees only that space's events.
        let session = ControlSession(peerUID: geteuid(), handler: h.base.handler)
        var auth = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "auth.authenticate", "params": ["protocolVersion": 2, "token": token]])
        auth.append(0x0A)
        _ = await session.receive(auth)
        var create = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2, "method": "space.create", "params": ["name": "Mine"]])
        create.append(0x0A)
        let createdOutput = await session.receive(create).output
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: createdOutput.prefix { $0 != 0x0A }) as? [String: Any])
        let mine = try XCTUnwrap(((reply["result"] as? [String: Any])?["space"] as? [String: Any])?["id"] as? String)

        let terminal = try XCTUnwrap(h.model.terminals[t.paneB])
        terminal.onShellIntegrationEvent?(.promptStart(directory: "/private/tmp"))
        h.model.remoteLinks[UUID()] = .connected
        let last = try await h.first("remote.link", full, after: start, since: .now)
        let end = try XCTUnwrap(last.event["sequence"] as? Int)

        let fullEvents = try await h.poll(full, Set(EventTopicV2.allCases).subtracting([.output]), after: start)
        XCTAssertTrue(fullEvents.contains { $0["type"] as? String == "space.created" && ($0["resource"] as? [String: Any])?["id"] as? String == mine })
        let ownEvents = try await h.poll(created, Set(EventTopicV2.allCases).subtracting([.output]), after: start)
        XCTAssertFalse(ownEvents.isEmpty)
        // Host events follow host scope, not space scope (this grant has every host); everything in a space is its own.
        XCTAssertTrue(ownEvents.allSatisfy { $0["spaceId"] as? String == mine || $0["topic"] as? String == "remote" }, "Only its own space: \(ownEvents.map { $0["type"] ?? "" })")
        XCTAssertTrue(ownEvents.contains { $0["type"] as? String == "space.created" }, "It sees the space it created being created")

        let limited = try await h.poll(noHosts, [.shell, .workspace], after: start)
        let remoteTopic = try await h.poll(noHosts, [.remote, .agent], after: start)
        XCTAssertNil(remoteTopic.first { ($0["type"] as? String)?.hasPrefix("remote.") == true }, "No host.read, no remote.*")
        XCTAssertTrue(fullEvents.contains { ($0["type"] as? String) == "remote.link" })
        let folder = try XCTUnwrap(limited.first { $0["type"] as? String == "folder.changed" })
        XCTAssertNil(data(folder)["path"], "No path without session.execute")
        let fullFolder = try XCTUnwrap(fullEvents.first { $0["type"] as? String == "folder.changed" })
        XCTAssertEqual(data(fullFolder)["path"] as? String, "/private/tmp")
        XCTAssertTrue(fullEvents.contains { ($0["sequence"] as? Int) == end })
    }

    /// The risk table's bound: heavy output (`yes`) never turns into a stream of events.
    @MainActor
    func testHeavyOutputProducesAFewEventsNotOnePerChunk() async throws {
        let h = try await EventsHarness()
        defer { h.cleanUp() }
        let (grant, _) = try await h.grant()
        let created = await h.model.createSpace(name: "Y", startSession: false)
        _ = try XCTUnwrap(created)
        let pane = try XCTUnwrap(h.model.presentation.activePane?.id)
        _ = try await h.model.service.execute(.configureStoppedSession(paneID: pane, launch: .process(executable: "/usr/bin/yes", arguments: [], directory: "/tmp")))
        await h.model.refresh()
        let after = await h.sequence
        let started = ContinuousClock.now
        await h.model.start(paneID: pane)
        let terminal = try XCTUnwrap(h.model.terminals[pane])
        // Two seconds of as much output as the terminal takes, with the main actor free to process it.
        while ContinuousClock.now - started < .seconds(2) { try await Task.sleep(for: .milliseconds(50)) }
        let chunks = h.model.outputJournal.end(session: terminal.sessionID)
        terminal.requestTermination(force: true)
        let events = try await h.poll(grant, Set(EventTopicV2.allCases).subtracting([.output]), after: after)
        XCTAssertGreaterThan(chunks, 100_000, "yes produced output")
        XCTAssertLessThanOrEqual(events.count, 12, "A handful of state changes in two seconds, not one per chunk: \(events.map { $0["type"] ?? "" })")
        XCTAssertLessThanOrEqual(events.filter { $0["topic"] as? String == "attention" }.count, 4)
    }

    /// API2-07c on a protocol 2 connection: the poll returns the agent change made 500 ms later.
    @MainActor
    func testEventsPollOverTheSocketReturnsALaterAgentChange() async throws {
        let h = try await EventsHarness()
        defer { h.cleanUp() }
        let (_, token) = try await h.grant([.workspaceRead])
        let t = try await makeTabs(h)
        let terminal = try XCTUnwrap(h.model.terminals[t.paneB])
        terminal.onShellIntegrationEvent?(.commandStart(commandLine: "codex"))
        h.model.receiveAgentEvent(sessionID: terminal.sessionID, event: "working")
        try await Task.sleep(for: .milliseconds(300))

        let session = ControlSession(peerUID: geteuid(), handler: h.base.handler)
        func send(_ id: Int, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            var frame = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            frame.append(0x0A)
            let output = await session.receive(frame).output
            return try XCTUnwrap(JSONSerialization.jsonObject(with: output.prefix { $0 != 0x0A }) as? [String: Any])
        }
        _ = try await send(1, "auth.authenticate", ["protocolVersion": 2, "token": token])
        let first = try await send(2, "events.poll", ["topics": ["agent"]])
        let now = try XCTUnwrap(first["result"] as? [String: Any])
        let cursor = try XCTUnwrap(now["nextSequence"] as? Int)
        let instance = try XCTUnwrap(now["instanceId"] as? String)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            h.model.receiveAgentEvent(sessionID: terminal.sessionID, event: "needs-input")
        }
        let started = ContinuousClock.now
        let waited = try await send(3, "events.poll", ["topics": ["agent"], "afterSequence": cursor, "instanceId": instance, "timeoutMs": 2_000])
        let polled = try XCTUnwrap(waited["result"] as? [String: Any])
        let elapsed = ContinuousClock.now - started
        let events = try XCTUnwrap(polled["events"] as? [[String: Any]])
        XCTAssertEqual(events.map { $0["type"] as? String }, ["agent.state"])
        XCTAssertEqual(data(events[0])["state"] as? String, "needsInput")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(400))
        XCTAssertLessThan(elapsed, .milliseconds(1_500))
        let next = try XCTUnwrap(polled["nextSequence"] as? Int)
        let quiet = try await send(4, "events.poll", ["topics": ["agent"], "afterSequence": next, "timeoutMs": 300])
        let empty = try XCTUnwrap(quiet["result"] as? [String: Any])
        XCTAssertEqual((empty["events"] as? [Any])?.count, 0)
        let output = try await send(5, "events.poll", ["topics": ["output"]])
        XCTAssertEqual((output["error"] as? [String: Any])?["code"] as? Int, -32602, "Polls never return output")
        let other = try await send(6, "events.poll", ["topics": ["agent"], "afterSequence": 1, "instanceId": UUID().uuidString])
        XCTAssertEqual(errorCode(other), "INVALID_CURSOR", "Another instance's sequence means start over")
    }

    /// grant.changed reaches only the edited grant; after a narrowing its connection authenticates again.
    @MainActor
    func testGrantChangedReachesOnlyThatGrant() async throws {
        let h = try await EventsHarness()
        defer { h.cleanUp() }
        let (edited, _) = try await h.grant([.workspaceRead, .themeRead])
        let (other, _) = try await h.grant([.workspaceRead, .themeRead])
        let after = await h.sequence
        var settings = edited.settings
        settings.capabilities = [.workspaceRead]
        let narrowed = try await h.base.grants.update(edited.id, to: settings, expectedRevision: edited.revision, confirmedWidening: false)
        let changed = try await h.first("grant.changed", edited, after: after, since: .now)
        XCTAssertEqual(data(changed.event)["revision"] as? Int, Int(narrowed.revision))
        let seen = try await h.poll(other, [.grant], after: after, timeoutMs: 300)
        XCTAssertTrue(seen.isEmpty)
    }

    /// A project launch reports the space it opened (FR-PL06).
    @MainActor
    func testAProjectLaunchReportsItsSpace() async throws {
        let h = try await EventsHarness()
        defer { h.cleanUp() }
        let (grant, _) = try await h.grant()
        let (noExecute, _) = try await h.grant(Set(CapabilityV2.allCases).subtracting([.sessionExecute]))
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-ev-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("shop"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let saved = await h.model.saveLaunchSettings(shell: "/bin/sh", directory: scratch.path)
        XCTAssertTrue(saved)
        let project = ProjectDefinition(name: "Shop", tabs: [ProjectTab(title: "Shell")])
        h.model.commandPaletteProjects = { [project] }
        let after = await h.sequence
        h.model.beginProjectLaunch(project)
        let launch = try XCTUnwrap(h.model.projectLaunch)
        launch.folder = scratch.appendingPathComponent("shop").path
        await h.model.checkProjectLaunch(launch)
        let deadline = Date().addingTimeInterval(10)
        var ready: ProjectLaunch?
        while ready == nil, Date() < deadline {
            if case .ready(let value) = launch.stage { ready = value } else { try await Task.sleep(for: .milliseconds(20)) }
        }
        await h.model.openProjectLaunch(launch, try XCTUnwrap(ready))
        let space = try XCTUnwrap(h.model.snapshot.spaces.first { $0.projectID == project.id })
        let launched = try await h.first("project.launched", grant, after: after, since: .now)
        XCTAssertEqual(launched.event["spaceId"] as? String, space.id.uuidString.lowercased())
        XCTAssertEqual(data(launched.event)["target"] as? [String: String], ["kind": "local"])
        XCTAssertEqual(data(launched.event)["folder"] as? String, scratch.appendingPathComponent("shop").path)
        let redacted = try await h.first("project.launched", noExecute, after: after, since: .now)
        XCTAssertNil(data(redacted.event)["folder"])
    }
}
