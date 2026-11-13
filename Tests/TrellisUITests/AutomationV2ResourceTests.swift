import AppKit
import Darwin
import XCTest
import TrellisControl
import TrellisCore
@testable import TrellisUI

/// Protocol 2 clients over the real model and host library (`--automation-v2`), one authenticated session per grant.
@MainActor
final class HarnessV2 {
    let base: Harness
    var model: AppWorkspaceModel { base.model }
    private var sessions: [String: ControlSession] = [:]
    private var tokens: [String: String] = [:]
    private var nextID = 1

    /// `projects` is the project library the adapter and the model's palette read, as the app wires it.
    init(projects: ProjectListModel? = nil) throws {
        base = try Harness()
        base.handler = AuthorizingControlHandler(
            grants: base.grants, domain: AutomationServiceV2(model: base.model, hosts: base.hosts, projects: projects),
            idempotency: IdempotencyCache(now: { [clock = base.clock] in clock.now }))
        if let projects { base.model.commandPaletteProjects = { projects.projects } }
    }

    /// Clients of a harness whose handler is already set up (an `EventsHarness`'s, with its event hub).
    init(base: Harness) { self.base = base }

    func grant(_ name: String, _ capabilities: Set<CapabilityV2> = Set(CapabilityV2.allCases), scope: SpaceScope = .all, hosts: HostScope = .all) async throws {
        tokens[name] = try await base.grants.create(name: name, capabilities: capabilities, spaceScope: scope, hostScope: hosts, lifetime: 3600).token
        sessions[name] = nil
    }

    /// A grant with protocol 2 settings (presets, created scope, agent and project scopes).
    @discardableResult
    func grant(_ name: String, settings: GrantSettings) async throws -> AutomationGrant {
        var settings = settings
        settings.name = name
        let (grant, token) = try await base.grants.create(settings, lifetime: 3600)
        tokens[name] = token
        sessions[name] = nil
        return grant
    }

    func call(_ method: String, _ params: [String: Any] = [:], as name: String = "full") async throws -> [String: Any] {
        if sessions[name] == nil {
            let session = ControlSession(peerUID: geteuid(), handler: base.handler)
            sessions[name] = session
            _ = try await send(session, "auth.authenticate", ["protocolVersion": 2, "token": tokens[name]!])
        }
        return try await send(sessions[name]!, method, params)
    }

    /// The application error code, `-32602` style JSON-RPC codes as text, or "OK".
    func code(_ method: String, _ params: [String: Any] = [:], as name: String = "full") async throws -> String {
        let response = try await call(method, params, as: name)
        if response["result"] != nil { return "OK" }
        return errorCode(response) ?? ((response["error"] as? [String: Any])?["code"] as? Int).map(String.init) ?? "\(response)"
    }

    func ok(_ method: String, _ params: [String: Any] = [:], as name: String = "full", file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        try result(try await call(method, params, as: name), file: file, line: line)
    }

    private func send(_ session: ControlSession, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        nextID += 1
        var data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": nextID, "method": method, "params": params])
        data.append(0x0A)
        let output = await session.receive(data).output
        return try XCTUnwrap(JSONSerialization.jsonObject(with: output.prefix { $0 != 0x0A }) as? [String: Any])
    }

    func cleanUp() {
        model.terminals.values.forEach {
            $0.requestTermination(force: true); $0.adapter.detach()
        }
        base.discardPreferences()
    }
}

func details(_ response: [String: Any]) -> [String: Any]? { ((response["error"] as? [String: Any])?["data"] as? [String: Any])?["details"] as? [String: Any] }
func object(_ value: Any?, _ key: String) -> [String: Any] { (value as? [String: Any])?[key] as? [String: Any] ?? [:] }

final class AutomationV2ResourceTests: XCTestCase {
    @MainActor
    func testSpacesTabsAndPanesDriveTheRealModel() async throws {
        let v = try HarnessV2()
        defer { v.cleanUp() }
        try await v.grant("full")
        let created = try await v.ok("space.create", ["name": "Project"])
        let space = object(created, "space"), firstTab = object(created, "tab")
        let spaceID = try XCTUnwrap(space["id"] as? String), tabID = try XCTUnwrap(firstTab["id"] as? String)
        XCTAssertEqual(spaceID, spaceID.lowercased())
        XCTAssertEqual(space["machine"] as? [String: String], ["kind": "local"])
        XCTAssertEqual(object(firstTab, "layout")["type"] as? String, "pane")
        XCTAssertEqual(firstTab["role"] as? String, "standard")
        let panes = try XCTUnwrap(created["panes"] as? [[String: Any]])
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(object(panes[0], "shell")["integration"] as? String, "none")
        XCTAssertEqual(created["workspaceRevision"] as? Int, Int(v.model.snapshot.revision))
        let firstPane = try XCTUnwrap(panes[0]["id"] as? String)
        let r1 = try await v.ok("session.get", ["id": try XCTUnwrap(panes[0]["sessionId"] as? String)])
        XCTAssertEqual(r1["session"].map { ($0 as? [String: Any])?["state"] as? String }, "stopped")

        // expectedRevision: a stale one is CONFLICT with the current revision, and changes nothing.
        let revision = try XCTUnwrap(space["revision"] as? Int)
        let renamed = object(try await v.ok("space.update", ["id": spaceID, "name": "Renamed", "expectedRevision": revision]), "space")
        XCTAssertEqual(renamed["name"] as? String, "Renamed")
        let current = try XCTUnwrap(renamed["revision"] as? Int)
        XCTAssertGreaterThan(current, revision)
        let committed = v.model.snapshot
        let stale = try await v.call("space.update", ["id": spaceID.uppercased(), "name": "Stale", "expectedRevision": revision])
        XCTAssertEqual(errorCode(stale), "CONFLICT")
        XCTAssertEqual(details(stale)?["currentRevision"] as? Int, current)
        XCTAssertEqual(v.model.snapshot, committed, "A refused change leaves the workspace as it was")

        // Tabs: create with title and color, automatic title on null, duplicate, reorder, focus.
        let logs = object(try await v.ok("tab.create", ["spaceId": spaceID, "title": " Logs ", "color": "green"]), "tab")
        let logsID = try XCTUnwrap(logs["id"] as? String)
        XCTAssertEqual(logs["title"] as? String, "Logs")
        XCTAssertEqual(logs["customTitle"] as? Bool, true)
        XCTAssertEqual(logs["color"] as? String, "green")
        let automatic = object(try await v.ok("tab.update", ["id": logsID, "title": NSNull(), "color": NSNull()]), "tab")
        XCTAssertEqual(automatic["customTitle"] as? Bool, false)
        XCTAssertEqual(automatic["title"] as? String, WorkspaceTab.defaultTitle)
        XCTAssertNil(automatic["color"])
        let missingChange = try await v.call("tab.update", ["id": logsID])
        XCTAssertEqual((missingChange["error"] as? [String: Any])?["code"] as? Int, -32602)
        let duplicate = try await v.ok("tab.duplicate", ["id": logsID])
        let duplicateID = try XCTUnwrap(object(duplicate, "tab")["id"] as? String)
        XCTAssertNotEqual(duplicateID, logsID)
        XCTAssertEqual((duplicate["panes"] as? [Any])?.count, 1)
        let r2 = try await v.ok("space.get", ["id": spaceID])
        let spaceRevision = try XCTUnwrap(object(r2, "space")["revision"] as? Int)
        let order = [duplicateID, logsID, tabID]
        let staleOrder = try await v.code("tab.reorder", ["spaceId": spaceID, "ids": order, "expectedRevision": spaceRevision - 1])
        XCTAssertEqual(staleOrder, "CONFLICT")
        let reordered = try await v.ok("tab.reorder", ["spaceId": spaceID, "ids": order, "expectedRevision": spaceRevision])
        XCTAssertEqual((reordered["tabs"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, order)
        XCTAssertGreaterThan(try XCTUnwrap(reordered["revision"] as? Int), spaceRevision)
        _ = try await v.ok("tab.focus", ["id": tabID])
        XCTAssertEqual(v.model.snapshot.spaces.first?.activeTabID.uuidString.lowercased(), tabID)

        // Panes: split with a ratio, a stale pane revision, resize, maximize, list.
        let r3 = try await v.ok("pane.get", ["id": firstPane])
        let before = try XCTUnwrap(object(r3, "pane")["revision"] as? Int)
        let split = try await v.ok("pane.split", ["id": firstPane.uppercased(), "axis": "x", "ratio": 0.3])
        let newPane = try XCTUnwrap(object(split, "pane")["id"] as? String)
        let layout = object(split["tab"], "layout")
        XCTAssertEqual(layout["type"] as? String, "split")
        XCTAssertEqual(try XCTUnwrap(layout["ratio"] as? Double), 0.3, accuracy: 0.0001)
        XCTAssertEqual((layout["children"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [firstPane, newPane], "The existing pane is the first child")
        let r4 = try await v.ok("pane.get", ["id": firstPane])
        let after = try XCTUnwrap(object(r4, "pane")["revision"] as? Int)
        XCTAssertGreaterThan(after, before, "A pane's revision moves with its place in the tab")
        let paneConflict = try await v.call("pane.focus", ["id": firstPane, "expectedRevision": before])
        XCTAssertEqual(errorCode(paneConflict), "CONFLICT")
        XCTAssertEqual(details(paneConflict)?["currentRevision"] as? Int, after)
        _ = try await v.ok("pane.focus", ["id": firstPane, "expectedRevision": after])
        let r5 = try await v.ok("pane.get", ["id": firstPane])
        XCTAssertEqual(object(r5, "pane")["focused"] as? Bool, true)
        let branch = try XCTUnwrap(layout["id"] as? String)
        let r6 = try await v.ok("tab.get", ["id": tabID])
        let tabRevision = try XCTUnwrap(object(r6, "tab")["revision"] as? Int)
        let resized = object(try await v.ok("pane.resize", ["branchId": branch, "ratio": 0.6, "expectedRevision": tabRevision]), "tab")
        XCTAssertEqual(try XCTUnwrap(object(resized, "layout")["ratio"] as? Double), 0.6, accuracy: 0.0001)
        let maximized = try await v.ok("pane.maximize", ["id": newPane, "maximized": true])
        XCTAssertEqual(object(maximized, "pane")["maximized"] as? Bool, true)
        XCTAssertEqual(object(maximized, "tab")["maximizedPaneId"] as? String, newPane)
        let hidden = try await v.code("pane.split", ["id": firstPane, "axis": "y"])
        XCTAssertEqual(hidden, "INVALID_STATE", "No split hidden behind a maximized pane")
        _ = try await v.ok("pane.maximize", ["id": newPane, "maximized": false])
        let r7 = try await v.ok("pane.list", ["tabId": tabID])
        XCTAssertEqual((r7["panes"] as? [Any])?.count, 2)
        let all = try await v.ok("pane.list", ["spaceId": spaceID])
        XCTAssertEqual((all["panes"] as? [Any])?.count, 4)
        XCTAssertEqual(all["revision"] as? Int, Int(v.model.snapshot.spaces.first?.revision ?? 0))

        // workspace.get: everything in one call.
        let workspace = try await v.ok("workspace.get", ["include": ["tabs", "panes", "sessions", "layout"]])
        XCTAssertEqual(workspace["activeSpaceId"] as? String, spaceID)
        XCTAssertEqual((workspace["tabs"] as? [[String: Any]])?.count, 3)
        XCTAssertNotNil((workspace["tabs"] as? [[String: Any]])?.first?["layout"])
        XCTAssertEqual((workspace["panes"] as? [Any])?.count, 4)
        XCTAssertEqual((workspace["sessions"] as? [Any])?.count, 4)
        let r8 = try await v.ok("workspace.get")
        XCTAssertNil(r8["tabs"], "Collections only when included")

        // Idempotency: a retry spelling the ID in another case replays.
        let first = try await v.ok("tab.create", ["spaceId": spaceID, "idempotencyKey": "make-tab"])
        let retry = try await v.ok("tab.create", ["spaceId": spaceID.uppercased(), "idempotencyKey": "make-tab"])
        XCTAssertEqual(object(first, "tab")["id"] as? String, object(retry, "tab")["id"] as? String)
        XCTAssertEqual(v.model.snapshot.tabs.count, 4)

        // Close: deleted shapes, and the hierarchy is gone.
        let closedPane = try await v.ok("pane.close", ["id": newPane])
        XCTAssertEqual(closedPane["deleted"] as? [String: String], ["kind": "pane", "id": newPane])
        XCTAssertEqual(closedPane["workspaceRevision"] as? Int, Int(v.model.snapshot.revision))
        let r9 = try await v.ok("tab.close", ["id": duplicateID])
        XCTAssertEqual(r9["deleted"] as? [String: String], ["kind": "tab", "id": duplicateID])
        let r10 = try await v.ok("space.close", ["id": spaceID])
        XCTAssertEqual(r10["deleted"] as? [String: String], ["kind": "space", "id": spaceID])
        XCTAssertTrue(v.model.snapshot.spaces.isEmpty)
    }

    @MainActor
    func testPermissionsScopeAndPagingThroughTheRealModel() async throws {
        let v = try HarnessV2()
        defer { v.cleanUp() }
        try await v.grant("full")
        let r11 = try await v.ok("space.create", ["name": "Mine"])
        let mine = try XCTUnwrap(object(r11, "space")["id"] as? String)
        let r12 = try await v.ok("space.create", ["name": "Theirs"])
        let theirs = try XCTUnwrap(object(r12, "space")["id"] as? String)
        let theirTab = try XCTUnwrap(v.model.snapshot.spaces.first { $0.id.uuidString.lowercased() == theirs }?.activeTabID)
        let theirPane = try XCTUnwrap(v.model.snapshot.tabs[theirTab]?.activePaneID)
        try await v.grant("reader", [.workspaceRead])
        try await v.grant("scoped", Set(CapabilityV2.allCases), scope: .spaces([try XCTUnwrap(UUID(uuidString: mine))]))
        let committed = v.model.snapshot

        let denied = try await v.call("tab.create", ["spaceId": mine], as: "reader")
        XCTAssertEqual(errorCode(denied), "PERMISSION_DENIED")
        XCTAssertEqual(details(denied)?["missing"] as? [String], ["workspace.write"])
        let close = try await v.call("space.close", ["id": mine, "allowRunning": true], as: "reader")
        XCTAssertEqual(details(close)?["missing"] as? [String], ["session.close", "workspace.write"])
        for (method, params) in [
            ("space.get", ["id": theirs.uppercased()]), ("tab.update", ["id": theirTab.uuidString, "title": "X"]), ("pane.get", ["id": theirPane.uuidString]),
            ("pane.close", ["id": theirPane.uuidString]), ("tab.list", ["spaceId": theirs])
        ] as [(String, [String: Any])] {
            let code = try await v.code(method, params, as: "scoped")
            XCTAssertEqual(code, "NOT_FOUND", "\(method): out of scope looks missing")
        }
        let narrow = try await v.call("space.create", ["name": "New"], as: "scoped")
        XCTAssertEqual(errorCode(narrow), "PERMISSION_DENIED")
        let visible = try await v.ok("workspace.get", ["include": ["tabs"]], as: "scoped")
        XCTAssertEqual((visible["spaces"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [mine])
        XCTAssertNil(visible["activeSpaceId"], "The active space is out of scope")
        XCTAssertEqual(v.model.snapshot, committed, "Refused calls changed nothing")

        let page = try await v.ok("space.list", ["limit": 1])
        XCTAssertEqual((page["spaces"] as? [[String: Any]])?.first?["id"] as? String, mine)
        let cursor = try XCTUnwrap(page["nextCursor"] as? String)
        let next = try await v.ok("space.list", ["limit": 1, "cursor": cursor])
        XCTAssertEqual((next["spaces"] as? [[String: Any]])?.first?["id"] as? String, theirs)
        XCTAssertNil(next["nextCursor"])
        let foreign = try await v.code("tab.list", ["spaceId": mine, "cursor": cursor])
        XCTAssertEqual(foreign, "INVALID_CURSOR")
    }

    @MainActor
    func testStartingNewPanesNeedsWhatStartingTheirLaunchNeeds() async throws {
        let v = try HarnessV2()
        defer { v.cleanUp() }
        try await v.grant("full", Set(CapabilityV2.allCases).subtracting([.agentControl]))
        let created = try await v.ok("space.create", ["name": "Agents"])
        let tabID = try XCTUnwrap(object(created, "tab")["id"] as? String)
        let paneID = try XCTUnwrap(v.model.snapshot.tabs[try XCTUnwrap(UUID(uuidString: tabID))]?.activePaneID)
        _ = try await v.model.automationExecute(.configureStoppedSession(paneID: paneID, launch: .agent(AgentLaunch(agentID: "trellis-claude-code", directory: nil))))
        let committed = v.model.snapshot
        // A duplicated agent pane would start an agent: that needs agent.control, which this grant doesn't hold.
        let duplicate = try await v.call("tab.duplicate", ["id": tabID, "start": true])
        XCTAssertEqual(errorCode(duplicate), "PERMISSION_DENIED")
        XCTAssertEqual(details(duplicate)?["missing"] as? [String], ["agent.control"])
        XCTAssertEqual(v.model.snapshot, committed, "Refused before anything was created")
        let unstarted = try await v.code("tab.duplicate", ["id": tabID])
        XCTAssertEqual(unstarted, "OK", "Without start the copy stays stopped")

        // A grant limited to approved hosts sees the host it just created, though it can't use it until approved.
        try await v.grant("approved", hosts: .approved([]))
        let host = object(try await v.ok("host.create", ["name": "New", "destination": "new"], as: "approved"), "host")
        let hostID = try XCTUnwrap(host["id"] as? String)
        XCTAssertEqual(host["name"] as? String, "New")
        let hidden = try await v.code("host.get", ["id": hostID], as: "approved")
        XCTAssertEqual(hidden, "NOT_FOUND")
    }

    @MainActor
    func testSessionsStartStopAndTakeInputWithRealProcesses() async throws {
        let v = try HarnessV2()
        defer { v.cleanUp() }
        try await v.grant("full", Set(CapabilityV2.allCases).subtracting([.agentControl]))
        try await v.grant("starter", [.workspaceRead, .sessionStart])
        let created = try await v.ok("space.create", ["name": "Live"])
        let paneID = try XCTUnwrap((created["panes"] as? [[String: Any]])?.first?["id"] as? String)
        let pane = try XCTUnwrap(UUID(uuidString: paneID))
        let echo: [String: Any] = ["kind": "process", "executable": "/bin/zsh", "arguments": ["-f", "-c", AutomationSessionTests.byteEcho], "directory": "/tmp"]

        let agent = try await v.call("session.start", ["paneId": paneID, "launch": ["kind": "agent", "agentId": "trellis-claude-code"]])
        XCTAssertEqual((agent["error"] as? [String: Any])?["code"] as? Int, -32602, "Agents start through agent.start")
        let arbitrary = try await v.call("session.start", ["paneId": paneID, "launch": echo], as: "starter")
        XCTAssertEqual(details(arbitrary)?["missing"] as? [String], ["session.execute"])
        XCTAssertEqual(v.model.terminals[pane]?.sessionState, .stopped, "Nothing was spawned")

        let started = object(try await v.ok("session.start", ["paneId": paneID, "launch": echo]), "session")
        let sessionID = try XCTUnwrap(started["id"] as? String)
        XCTAssertEqual(started["state"] as? String, "running")
        XCTAssertEqual(object(started, "launch")["executable"] as? String, "/bin/zsh")
        XCTAssertNotNil(started["startedAt"] as? String)
        let terminal = NativeTerminalHandle(try XCTUnwrap(v.model.terminals[pane]))
        try await terminal.waitFor("READY")
        let redacted = object(try await v.ok("session.get", ["id": sessionID], as: "starter"), "session")
        XCTAssertEqual(redacted["launch"] as? [String: String], ["kind": "process"], "Launch details need session.execute")
        let r13 = try await v.code("session.start", ["paneId": paneID])
        XCTAssertEqual(r13, "INVALID_STATE")

        let sent = try await v.ok("session.sendInput", ["id": sessionID, "text": "a"])
        XCTAssertEqual(sent["acceptedBytes"] as? Int, 1)
        try await terminal.waitFor("61")
        let r14 = try await v.ok("session.get", ["id": sessionID])
        let revision = try XCTUnwrap(object(r14, "session")["revision"] as? Int)
        let stale = try await v.call("session.sendInput", ["id": sessionID, "text": "z", "expectedRevision": revision + 1])
        XCTAssertEqual(errorCode(stale), "CONFLICT")
        let executed = try await v.ok("session.execute", ["id": sessionID, "command": "b"])
        XCTAssertEqual(executed["submitted"] as? Bool, true)
        try await terminal.waitFor("62 0d")
        XCTAssertFalse(try terminal.output().contains("7a"), "The stale call sent nothing")
        let stream = try await v.ok("session.readOutput", ["id": sessionID, "view": "stream"])
        XCTAssertFalse(try XCTUnwrap(stream["base64"] as? String).isEmpty)
        XCTAssertNotNil(stream["nextCursor"] as? String)

        let stopped = object(try await v.ok("session.stop", ["id": sessionID]), "session")
        XCTAssertTrue(["exited", "failed"].contains(stopped["state"] as? String ?? ""), "\(stopped)")
        XCTAssertNotNil(stopped["endedAt"] as? String)
        let r15 = try await v.code("session.stop", ["id": sessionID])
        XCTAssertEqual(r15, "INVALID_STATE")
        let restarted = object(try await v.ok("session.restart", ["paneId": paneID]), "session")
        XCTAssertNotEqual(restarted["id"] as? String, sessionID, "Restart makes a new session")
        XCTAssertEqual(restarted["state"] as? String, "running")
        let running = try XCTUnwrap(restarted["id"] as? String)
        let unconfirmed = try await v.call("session.restart", ["paneId": paneID])
        XCTAssertEqual(errorCode(unconfirmed), "CONFIRMATION_REQUIRED")
        XCTAssertEqual(details(unconfirmed)?["sessionIds"] as? [String], [running])
        _ = try await v.ok("session.stop", ["id": running])

        // An agent pane's saved launch needs agent.control, which this grant doesn't hold.
        let other = try await v.ok("tab.create", ["spaceId": try XCTUnwrap(object(created, "space")["id"] as? String)])
        let agentPane = try XCTUnwrap(UUID(uuidString: try XCTUnwrap((other["panes"] as? [[String: Any]])?.first?["id"] as? String)))
        _ = try await v.model.service.execute(.configureStoppedSession(paneID: agentPane, launch: .agent(AgentLaunch(agentID: "trellis-claude-code", directory: "/tmp"))))
        await v.model.refresh()
        let refused = try await v.call("session.start", ["paneId": agentPane.uuidString])
        XCTAssertEqual(errorCode(refused), "PERMISSION_DENIED")
        XCTAssertEqual(details(refused)?["missing"] as? [String], ["agent.control"])
        XCTAssertEqual(v.model.terminals[agentPane]?.sessionState, .stopped)
        let agentSession = object(try await v.ok("pane.get", ["id": agentPane.uuidString]), "pane")
        XCTAssertEqual(agentSession["machine"] as? [String: String], ["kind": "local"])
    }

    @MainActor
    func testHostsAndConnectThroughTheRealLibrary() async throws {
        let v = try HarnessV2()
        defer { v.cleanUp() }
        try await v.grant("full")
        try await v.grant("writer", [.hostRead, .hostWrite])
        let refused = try await v.call("host.create", ["name": "Prod", "destination": "prod"], as: "writer")
        XCTAssertEqual(details(refused)?["missing"] as? [String], ["session.execute"])
        let prod = object(try await v.ok("host.create", ["name": "Prod", "destination": "prod", "tags": ["work"], "port": 2222]), "host")
        let prodID = try XCTUnwrap(prod["id"] as? String)
        XCTAssertEqual(prod["password"] as? [String: Bool], ["saved": false])
        XCTAssertEqual(prod["port"] as? Int, 2222)
        XCTAssertNil(prod["remote"])
        let r16 = try await v.ok("host.create", ["name": "Dev", "destination": "dev", "tags": ["home"]])
        let devID = try XCTUnwrap(object(r16, "host")["id"] as? String)
        let r17 = try await v.ok("host.list", ["tags": ["WORK"]])
        XCTAssertEqual((r17["hosts"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [prodID])
        let r18 = try await v.ok("host.list", ["query": "dev"])
        XCTAssertEqual((r18["hosts"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [devID])
        let page = try await v.ok("host.list", ["limit": 1])
        XCTAssertNotNil(page["nextCursor"])
        XCTAssertNil(page["revision"], "The host library has no collection revision")

        let renamed = object(try await v.ok("host.update", ["id": prodID, "name": "Prod 2"], as: "writer"), "host")
        XCTAssertEqual(renamed["name"] as? String, "Prod 2")
        let clearUser = try await v.call("host.update", ["id": prodID, "user": NSNull()], as: "writer")
        XCTAssertEqual(details(clearUser)?["missing"] as? [String], ["session.execute"])
        let stale = try await v.call("host.update", ["id": prodID, "name": "Old", "expectedRevision": try XCTUnwrap(prod["revision"] as? Int)])
        XCTAssertEqual(errorCode(stale), "CONFLICT")
        XCTAssertEqual(details(stale)?["currentRevision"] as? Int, renamed["revision"] as? Int)
        XCTAssertEqual(v.base.hosts.hosts.first { $0.id.uuidString.lowercased() == prodID }?.name, "Prod 2")

        // host.connect: a fake ssh, in a new tab, a split and a new space; never inside a remote workspace.
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ssh-\(UUID().uuidString)")
        try Data("#!/bin/sh\nprintf 'FAKE-SSH %s\\n' \"$*\"\nexec /bin/sleep 30\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        defer { try? FileManager.default.removeItem(at: fake) }
        v.model.sshExecutable = fake.path
        v.model.resolveHost = { [hosts = v.base.hosts] id in await hosts.host(id) }
        let r19 = try await v.ok("space.create", ["name": "Ops"])
        let spaceID = try XCTUnwrap(object(r19, "space")["id"] as? String)
        let connected = try await v.ok("host.connect", ["hostId": prodID, "placement": ["kind": "tab", "spaceId": spaceID]])
        XCTAssertEqual(object(connected, "session")["state"] as? String, "running")
        XCTAssertEqual(object(connected, "session")["launch"] as? [String: String], ["kind": "ssh", "hostId": prodID])
        XCTAssertEqual(object(connected, "pane")["machine"] as? [String: String], ["kind": "ssh", "hostId": prodID])
        let sshPane = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(object(connected, "pane")["id"] as? String)))
        XCTAssertEqual(v.model.snapshot.panes[sshPane].flatMap { v.model.snapshot.tabs[$0.tabID] }?.title, "Prod 2")
        try await NativeTerminalHandle(try XCTUnwrap(v.model.terminals[sshPane])).waitFor("FAKE-SSH -p 2222 -- prod")
        let split = try await v.ok("host.connect", ["hostId": prodID, "placement": ["kind": "split", "paneId": sshPane.uuidString, "axis": "y"]])
        XCTAssertEqual(object(split, "pane")["tabId"] as? String, v.model.snapshot.panes[sshPane]?.tabID.uuidString.lowercased())
        let spaces = v.model.snapshot.spaces.count
        _ = try await v.ok("host.connect", ["hostId": prodID, "placement": ["kind": "space"]])
        XCTAssertEqual(v.model.snapshot.spaces.count, spaces + 1)
        XCTAssertEqual(v.model.snapshot.spaces.last?.name, "Prod 2")
        let host = try XCTUnwrap(UUID(uuidString: prodID))
        _ = try await v.model.service.execute(.createRemoteSpace(name: "Remote", hostID: host))
        await v.model.refresh()
        let remote = try XCTUnwrap(v.model.snapshot.spaces.last)
        let remoteTabs = remote.tabIDs
        let remoteSpace = object(try await v.ok("space.get", ["id": remote.id.uuidString]), "space")
        XCTAssertEqual(remoteSpace["machine"] as? [String: String], ["kind": "remote", "hostId": prodID])
        let r20 = try await v.code("host.connect", ["hostId": prodID, "placement": ["kind": "tab", "spaceId": remote.id.uuidString]])
        XCTAssertEqual(r20, "INVALID_STATE")
        XCTAssertEqual(v.model.snapshot.spaces.last?.tabIDs, remoteTabs, "Nothing was created")

        let deleted = try await v.ok("host.delete", ["id": devID])
        XCTAssertEqual(deleted["deleted"] as? [String: String], ["kind": "host", "id": devID])
        XCTAssertNil(deleted["workspaceRevision"])
        let r21 = try await v.code("host.get", ["id": devID])
        XCTAssertEqual(r21, "NOT_FOUND")
    }

    /// Risk table: workspace.get on a full workspace (100 panes) is built from one snapshot pass. The bound is generous
    /// (the target is 50 ms); the measured time is printed.
    @MainActor
    func testWorkspaceGetWithAHundredPanesStaysFast() async throws {
        let v = try HarnessV2()
        defer { v.cleanUp() }
        try await v.grant("full")
        let space = try await v.model.service.execute(.createSpace(name: "Big"))
        let spaceID = try XCTUnwrap(space.createdSpaceID)
        for _ in 1..<100 { _ = try await v.model.service.execute(.createTab(spaceID: spaceID)) }
        await v.model.refresh()
        XCTAssertEqual(v.model.snapshot.panes.count, 100)
        _ = try await v.ok("workspace.get", ["include": ["tabs", "panes", "sessions", "layout"]])
        let start = Date()
        let workspace = try await v.ok("workspace.get", ["include": ["tabs", "panes", "sessions", "layout"]])
        let elapsed = Date().timeIntervalSince(start)
        print("workspace.get with 100 panes: \(Int(elapsed * 1_000)) ms")
        XCTAssertEqual((workspace["panes"] as? [Any])?.count, 100)
        XCTAssertLessThan(elapsed, 0.5)
    }

    /// A reply that wouldn't fit one frame is LIMIT_EXCEEDED, so the client pages with the list methods instead.
    @MainActor
    func testWorkspaceGetTooLargeForOneFrameIsLimitExceeded() async throws {
        let v = try HarnessV2()
        defer { v.cleanUp() }
        try await v.grant("full")
        try await v.grant("reader", [.workspaceRead])
        let space = try await v.model.service.execute(.createSpace(name: "Huge"))
        let pane = try XCTUnwrap(space.snapshot.tabs.values.first?.activePaneID)
        let argument = String(repeating: "a", count: 60_000)
        _ = try await v.model.service.execute(
            .configureStoppedSession(paneID: pane, launch: .process(executable: "/bin/echo", arguments: Array(repeating: argument, count: 20), directory: "/tmp")))
        await v.model.refresh()
        let response = try await v.call("workspace.get", ["include": ["sessions"]])
        XCTAssertEqual(errorCode(response), "LIMIT_EXCEEDED")
        let r0 = try await v.code("workspace.get", ["include": ["tabs", "panes"]])
        XCTAssertEqual(r0, "OK", "Without the launch details it fits")
        let r1 = try await v.code("workspace.get", ["include": ["sessions"]], as: "reader")
        XCTAssertEqual(r1, "OK", "Redacted launches are small")
    }

    func testPaneAndSessionRevisionsGrowOnEveryChange() throws {
        let space = UUID(), tab = UUID(), a = UUID(), b = UUID(), sa = UUID(), sb = UUID()
        var one = WorkspaceSnapshot()
        one.revision = 1
        one.spaces = [Space(id: space, name: "S", tabIDs: [tab], activeTabID: tab)]
        one.activeSpaceID = space
        one.tabs[tab] = WorkspaceTab(id: tab, spaceID: space, title: "T", root: .pane(a), activePaneID: a)
        one.panes[a] = WorkspacePane(id: a, tabID: tab, sessionID: sa)
        one.sessions[sa] = WorkspaceSession(id: sa)
        var revisions = AutomationRevisions()
        revisions.record(WorkspaceSnapshot(), one)
        let paneA = try XCTUnwrap(revisions.panes[a]), sessionA = try XCTUnwrap(revisions.sessions[sa])

        var two = one
        two.revision = 2
        two.tabs[tab]?.title = "Renamed"
        revisions.record(one, two)
        XCTAssertEqual(revisions.panes[a], paneA, "A tab rename isn't a pane change")
        XCTAssertEqual(revisions.sessions[sa], sessionA)

        var three = two
        three.revision = 3
        three.tabs[tab]?.root = .split(id: UUID(), axis: .x, ratio: 0.5, children: [.pane(a), .pane(b)])
        three.tabs[tab]?.activePaneID = b
        three.panes[b] = WorkspacePane(id: b, tabID: tab, sessionID: sb)
        three.sessions[sb] = WorkspaceSession(id: sb)
        three.sessions[sa]?.state = .exited
        revisions.record(two, three)
        let splitA = try XCTUnwrap(revisions.panes[a])
        XCTAssertGreaterThan(splitA, paneA, "Its place and focus changed")
        XCTAssertGreaterThan(try XCTUnwrap(revisions.sessions[sa]), sessionA)
        XCTAssertNotNil(revisions.panes[b])

        revisions.maximizedChanged(from: [:], to: [tab: b])
        let maximizedB = try XCTUnwrap(revisions.panes[b])
        XCTAssertEqual(revisions.panes[a], splitA)
        revisions.maximizedChanged(from: [tab: b], to: [tab: a])
        XCTAssertGreaterThan(try XCTUnwrap(revisions.panes[a]), splitA)
        XCTAssertGreaterThan(try XCTUnwrap(revisions.panes[b]), maximizedB)

        revisions.record(three, one)
        XCTAssertNil(revisions.panes[b], "Closed panes are forgotten")
        XCTAssertNil(revisions.sessions[sb])
        revisions.maximizedChanged(from: [:], to: [tab: b])
        XCTAssertNil(revisions.panes[b], "A gone pane isn't brought back")
    }
}
