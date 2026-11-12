import AppKit
import Darwin
import XCTest
import TrellisControl
import TrellisCore
@testable import TrellisUI

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

final class NoSecrets: GrantSecretStore, @unchecked Sendable {
    func store(_ token: String, grantID: UUID) throws {}
    func remove(grantID: UUID) {}
}

final class MemoryHosts: HostStorage, @unchecked Sendable {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
    func preserveUnreadable() throws {}
}

/// An RPC client wired to a real model through the authorizing handler.
@MainActor
final class Harness {
    let model: AppWorkspaceModel
    let hosts: HostListModel
    let grants: GrantStore
    let clock: Clock
    var handler: AuthorizingControlHandler
    private var sessions: [String: ControlSession] = [:]
    private var tokens: [String: String] = [:]
    private var nextID = 1

    /// Isolated preferences so tests never touch the user's settings.
    let preferences: UserDefaults
    private let suite = "trellis.tests.harness.\(UUID().uuidString)"

    init(clock: Clock = Clock(), themeDirectory: URL? = nil) throws {
        _ = NSApplication.shared
        self.clock = clock
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        model = AppWorkspaceModel(
            store: try WorkspaceStore(), preferences: preferences, themeLibrary: themeDirectory.map { ThemeLibrary(directory: $0) })
        // API calls must never present the UI's modal confirmations.
        model.confirmCloseSessions = { _ in
            XCTFail("Automation showed a close dialog"); return false
        }
        model.confirmForceSessions = { _ in
            XCTFail("Automation showed a force dialog"); return false
        }
        hosts = HostListModel(library: HostLibrary(storage: MemoryHosts()))
        grants = GrantStore(url: nil, secrets: NoSecrets(), now: { [clock] in clock.now })
        // An event hub as the app has (events.poll answers), though nothing feeds it here; EventsHarness wires one that is.
        handler = AuthorizingControlHandler(
            grants: grants, domain: AutomationServiceV2(model: model, hosts: hosts), idempotency: IdempotencyCache(now: { [clock] in clock.now }),
            events: EventHubV2(instanceID: UUID(), grants: grants))
    }

    func discardPreferences() { preferences.removePersistentDomain(forName: suite) }

    func grant(_ name: String, _ capabilities: Set<CapabilityV2> = Set(CapabilityV2.allCases), scope: SpaceScope = .all) async throws {
        tokens[name] = try await grants.create(name: name, capabilities: capabilities, spaceScope: scope, hostScope: .all, lifetime: 3600).token
        sessions[name] = nil
    }

    /// Fresh handler state (same grants), as after an app relaunch.
    func restartInstance() {
        handler = AuthorizingControlHandler(
            grants: grants, domain: AutomationServiceV2(model: model, hosts: hosts), idempotency: IdempotencyCache(now: { [clock] in clock.now }))
        sessions = [:]
    }

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:], as name: String = "full") async throws -> [String: Any] {
        if sessions[name] == nil {
            let session = ControlSession(peerUID: geteuid(), handler: handler)
            sessions[name] = session
            _ = try await send(session, "auth.authenticate", ["protocolVersion": 2, "token": tokens[name]!])
        }
        return try await send(sessions[name]!, method, params)
    }

    /// The API-06 data.code of a failed call, or "OK" on success.
    func code(_ method: String, _ params: [String: Any] = [:], as name: String = "full") async throws -> String {
        let response = try await call(method, params, as: name)
        return response["result"] != nil ? "OK" : (errorCode(response) ?? "\(response)")
    }

    /// The `key` field of a successful call's result.
    func value<T>(_ key: String, _ method: String, _ params: [String: Any] = [:], as name: String = "full") async throws -> T {
        let response = try await call(method, params, as: name)
        return try XCTUnwrap((response["result"] as? [String: Any])?[key] as? T, "\(response)")
    }

    private func send(_ session: ControlSession, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        nextID += 1
        var data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": nextID, "method": method, "params": params])
        data.append(0x0A)
        let output = await session.receive(data).output
        return try XCTUnwrap(JSONSerialization.jsonObject(with: output.prefix { $0 != 0x0A }) as? [String: Any])
    }
}

func result(_ response: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
    try XCTUnwrap(response["result"] as? [String: Any], "\(response)", file: file, line: line)
}

func errorCode(_ response: [String: Any]) -> String? {
    ((response["error"] as? [String: Any])?["data"] as? [String: Any])?["code"] as? String
}

/// IDs in protocol 2 results are lowercase.
func lower(_ id: UUID) -> String { id.uuidString.lowercased() }

/// `space.create`'s space, tab and first pane IDs.
@MainActor
func createdIDs(_ result: [String: Any]) throws -> (space: String, tab: String, pane: String) {
    let space = try XCTUnwrap((result["space"] as? [String: Any])?["id"] as? String)
    let tab = try XCTUnwrap((result["tab"] as? [String: Any])?["id"] as? String)
    let pane = try XCTUnwrap((result["panes"] as? [[String: Any]])?.first?["id"] as? String)
    return (space, tab, pane)
}

final class AutomationResourceTests: XCTestCase {
    @MainActor
    func testApiCreatesStoppedHierarchy() async throws {
        let h = try Harness()
        try await h.grant("full")
        let space = try result(try await h.call("space.create", ["name": "Project"]))
        let (spaceID, _, firstPane) = try createdIDs(space)
        XCTAssertEqual(h.model.snapshot.panes[try XCTUnwrap(UUID(uuidString: firstPane))].flatMap { h.model.snapshot.sessions[$0.sessionID] }?.state, .stopped)
        let tab: [String: Any] = try await h.value("tab", "tab.create", ["spaceId": spaceID, "title": "Logs"])
        XCTAssertEqual(tab["spaceId"] as? String, spaceID)
        XCTAssertEqual(tab["title"] as? String, "Logs")
        let tabPane = try XCTUnwrap((tab["paneIds"] as? [String])?.first)
        let split = try result(try await h.call("pane.split", ["id": tabPane, "axis": "x", "ratio": 0.3]))
        let newPane = try XCTUnwrap((split["pane"] as? [String: Any])?["id"] as? String)
        let layout = try XCTUnwrap((split["tab"] as? [String: Any])?["layout"] as? [String: Any])
        XCTAssertEqual(layout["type"] as? String, "split")
        XCTAssertEqual(layout["axis"] as? String, "x")
        XCTAssertEqual(try XCTUnwrap(layout["ratio"] as? Double), 0.3, accuracy: 0.0001)
        XCTAssertEqual((layout["children"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [tabPane, newPane], "The existing pane is the first child")

        let detail: [String: Any] = try await h.value("space", "space.get", ["id": spaceID])
        XCTAssertEqual((detail["tabIds"] as? [String])?.count, 2)
        // Zero spawns: every session is stopped and owns no process.
        let snapshot = h.model.snapshot
        try snapshot.validate()
        XCTAssertEqual(snapshot.panes.count, 3)
        XCTAssertTrue(snapshot.sessions.values.allSatisfy { $0.state == .stopped && $0.processID == nil })
        XCTAssertTrue(h.model.terminals.values.allSatisfy { $0.processID == nil && !$0.isRunning })
        XCTAssertEqual(h.model.terminals.count, 3, "UI terminals exist for API-created panes")
        h.model.terminals.values.forEach { $0.adapter.detach() }
    }

    @MainActor
    func testStaleMutationHasNoEffects() async throws {
        let h = try Harness()
        try await h.grant("full")
        let (spaceID, tabID, _) = try createdIDs(try result(try await h.call("space.create", ["name": "One"])))
        defer { h.model.terminals.values.forEach { $0.adapter.detach() } }
        let space: [String: Any] = try await h.value("space", "space.get", ["id": spaceID])
        let revision = try XCTUnwrap(space["revision"] as? Int)
        let renamed: [String: Any] = try await h.value("space", "space.update", ["id": spaceID, "name": "Two", "expectedRevision": revision])
        XCTAssertGreaterThan(try XCTUnwrap(renamed["revision"] as? Int), revision)
        let committed = h.model.snapshot
        let stale = try await h.call("space.update", ["id": spaceID, "name": "Three", "expectedRevision": revision])
        XCTAssertEqual(errorCode(stale), "CONFLICT")
        let details = (((stale["error"] as? [String: Any])?["data"] as? [String: Any])?["details"] as? [String: Any])
        XCTAssertEqual(details?["currentRevision"] as? Int, renamed["revision"] as? Int)
        XCTAssertEqual(h.model.snapshot, committed, "A rejected mutation changes nothing")
        let code1 = try await h.code("tab.update", ["id": tabID, "title": "X", "expectedRevision": 0])
        XCTAssertEqual(code1, "CONFLICT")
        let code2 = try await h.code("space.reorder", ["ids": [spaceID], "expectedRevision": 0])
        XCTAssertEqual(code2, "CONFLICT")
        XCTAssertEqual(h.model.snapshot, committed)
        // Omitting the revision targets the latest state.
        _ = try result(try await h.call("space.update", ["id": spaceID, "name": "Latest"]))
        XCTAssertEqual(h.model.snapshot.spaces.first?.name, "Latest")
    }

    @MainActor
    func testTabUpdateSetsAndClearsColorAtomically() async throws {
        let h = try Harness()
        try await h.grant("full")
        let (_, tabID, _) = try createdIDs(try result(try await h.call("space.create", ["name": "One"])))
        let id = try XCTUnwrap(UUID(uuidString: tabID))
        defer { h.model.terminals.values.forEach { $0.adapter.detach() } }
        let colored: [String: Any] = try await h.value("tab", "tab.update", ["id": tabID, "color": "blue"])
        XCTAssertEqual(colored["color"] as? String, "blue")
        XCTAssertEqual(h.model.snapshot.tabs[id]?.color, .blue)
        let both: [String: Any] = try await h.value("tab", "tab.update", ["id": tabID, "title": "Deploy", "color": "orange"])
        XCTAssertEqual(both["title"] as? String, "Deploy")
        XCTAssertEqual(both["color"] as? String, "orange")
        let committed = h.model.snapshot
        let badColor = try await h.call("tab.update", ["id": tabID, "title": "Other", "color": "teal"])
        XCTAssertEqual((badColor["error"] as? [String: Any])?["code"] as? Int, -32602)
        let badTitle = try await h.call("tab.update", ["id": tabID, "title": "  ", "color": "red"])
        XCTAssertNotNil(badTitle["error"])
        let neither = try await h.call("tab.update", ["id": tabID])
        XCTAssertEqual((neither["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual(h.model.snapshot, committed, "A rejected update applies neither the title nor the color")
        let cleared: [String: Any] = try await h.value("tab", "tab.update", ["id": tabID, "color": NSNull()])
        XCTAssertNil(cleared["color"])
        XCTAssertNil(h.model.snapshot.tabs[id]?.color)
        XCTAssertEqual(h.model.snapshot.tabs[id]?.title, "Deploy")
    }

    @MainActor
    func testIdempotencyKeyScopeAndExpiry() async throws {
        let h = try Harness()
        try await h.grant("full")
        try await h.grant("other")
        defer { h.model.terminals.values.forEach { $0.adapter.detach() } }
        let first = try result(try await h.call("space.create", ["name": "A", "idempotencyKey": "k1"]))
        let replay = try result(try await h.call("space.create", ["name": "A", "idempotencyKey": "k1"]))
        XCTAssertEqual(try createdIDs(replay).space, try createdIDs(first).space)
        XCTAssertEqual(h.model.snapshot.spaces.count, 1, "The duplicate executed once")
        let code3 = try await h.code("space.create", ["name": "B", "idempotencyKey": "k1"])
        XCTAssertEqual(code3, "CONFLICT")
        XCTAssertEqual(h.model.snapshot.spaces.count, 1)

        // Another grant has its own key space.
        _ = try result(try await h.call("space.create", ["name": "A", "idempotencyKey": "k1"], as: "other"))
        XCTAssertEqual(h.model.snapshot.spaces.count, 2)

        // After ten minutes the key is forgotten.
        h.clock.advance(601)
        _ = try result(try await h.call("space.create", ["name": "A", "idempotencyKey": "k1"]))
        XCTAssertEqual(h.model.snapshot.spaces.count, 3)

        // A new app instance does not promise deduplication.
        _ = try result(try await h.call("space.create", ["name": "C", "idempotencyKey": "k2"]))
        h.restartInstance()
        _ = try result(try await h.call("space.create", ["name": "C", "idempotencyKey": "k2"]))
        XCTAssertEqual(h.model.snapshot.spaces.count, 5)
        let oversizedKey = try await h.call("space.create", ["name": "D", "idempotencyKey": String(repeating: "x", count: 200)])
        XCTAssertEqual((oversizedKey["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual(h.model.snapshot.spaces.count, 5)
    }

    @MainActor
    func testApiUiDomainEquivalence() async throws {
        // UI path.
        let ui = try Harness()
        await ui.model.createSpace(name: "Project", startSession: false)
        let uiSpace = try XCTUnwrap(ui.model.presentation.selectedSpace?.id)
        let createdTab = await ui.model.createTab(spaceID: uiSpace, startSessions: false)
        let uiTab = try XCTUnwrap(createdTab)
        await ui.model.renameTab(uiTab, title: "Logs")
        let uiPane = try XCTUnwrap(ui.model.snapshot.tabs[uiTab]?.activePaneID)
        _ = await ui.model.splitPane(uiPane, axis: .y, startSession: false)
        await ui.model.renameSpace(uiSpace, name: "Renamed")
        defer { ui.model.terminals.values.forEach { $0.adapter.detach() } }

        // API path.
        let api = try Harness()
        try await api.grant("full")
        defer { api.model.terminals.values.forEach { $0.adapter.detach() } }
        let space = try createdIDs(try result(try await api.call("space.create", ["name": "Project"]))).space
        let tab: [String: Any] = try await api.value("tab", "tab.create", ["spaceId": space, "title": "Logs"])
        let pane = try XCTUnwrap((tab["paneIds"] as? [String])?.first)
        _ = try result(try await api.call("pane.split", ["id": pane, "axis": "y"]))
        _ = try result(try await api.call("space.update", ["id": space, "name": "Renamed"]))

        XCTAssertEqual(Self.normalized(ui.model.snapshot), Self.normalized(api.model.snapshot))
        try ui.model.snapshot.validate()
        try api.model.snapshot.validate()
    }

    @MainActor
    func testClosingRunningContainersNeedsAllowRunningAndCloseCapability() async throws {
        let h = try Harness()
        try await h.grant("full")
        try await h.grant("layout", [.workspaceRead, .workspaceWrite])
        let (spaceID, _, pane) = try createdIDs(try result(try await h.call("space.create", ["name": "Live"])))
        let paneID = try XCTUnwrap(UUID(uuidString: pane))
        _ = try await h.model.service.execute(
            .configureStoppedSession(paneID: paneID, launch: .process(executable: "/bin/sleep", arguments: ["30"], directory: "/tmp")))
        await h.model.refresh()
        await h.model.start(paneID: paneID)
        let terminal = try XCTUnwrap(h.model.terminals[paneID])
        defer { terminal.requestTermination(force: true); terminal.adapter.detach() }
        XCTAssertTrue(terminal.isRunning)

        let unconfirmed = try await h.call("space.close", ["id": spaceID])
        XCTAssertEqual(errorCode(unconfirmed), "CONFIRMATION_REQUIRED")
        let details = ((unconfirmed["error"] as? [String: Any])?["data"] as? [String: Any])?["details"] as? [String: Any]
        XCTAssertEqual(details?["sessionIds"] as? [String], [lower(terminal.sessionID)])
        XCTAssertEqual(details?["reason"] as? String, "runningSessions")
        let code4 = try await h.code("space.close", ["id": spaceID, "allowRunning": true], as: "layout")
        XCTAssertEqual(code4, "PERMISSION_DENIED")
        XCTAssertTrue(terminal.isRunning, "Denied closes send no signal")

        // Launch details are redacted without session.execute.
        let redacted: [String: Any] = try await h.value("session", "session.get", ["id": lower(terminal.sessionID)], as: "layout")
        XCTAssertEqual((redacted["launch"] as? [String: Any])?["kind"] as? String, "process")
        XCTAssertNil((redacted["launch"] as? [String: Any])?["executable"])
        XCTAssertNil((redacted["launch"] as? [String: Any])?["arguments"])
        let full: [String: Any] = try await h.value("session", "session.get", ["id": lower(terminal.sessionID)])
        XCTAssertEqual((full["launch"] as? [String: Any])?["executable"] as? String, "/bin/sleep")

        // A stale revision is rejected before any session is signaled.
        let space: [String: Any] = try await h.value("space", "space.get", ["id": spaceID])
        let spaceRevision = try XCTUnwrap(space["revision"] as? Int)
        _ = try result(try await h.call("space.update", ["id": spaceID, "name": "Renamed"]))
        let stale = try await h.code("space.close", ["id": spaceID, "allowRunning": true, "expectedRevision": spaceRevision])
        XCTAssertEqual(stale, "CONFLICT")
        XCTAssertTrue(terminal.isRunning, "A conflicting close sends no signal")

        let closed = try result(try await h.call("space.close", ["id": spaceID, "allowRunning": true]))
        XCTAssertEqual((closed["deleted"] as? [String: Any])?["id"] as? String, spaceID)
        XCTAssertFalse(terminal.isRunning)
        XCTAssertTrue(h.model.snapshot.spaces.isEmpty)
    }

    @MainActor
    func testSpaceScopedGrantSeesOnlyItsSpacesAndHostFieldsValidate() async throws {
        let h = try Harness()
        try await h.grant("full")
        defer { h.model.terminals.values.forEach { $0.adapter.detach() } }
        let a = try createdIDs(try result(try await h.call("space.create", ["name": "A"]))).space
        let b = try createdIDs(try result(try await h.call("space.create", ["name": "B"]))).space
        try await h.grant("scoped", [.workspaceRead, .workspaceWrite], scope: .spaces([UUID(uuidString: a)!]))
        let listed = try result(try await h.call("space.list", as: "scoped"))
        XCTAssertEqual((listed["spaces"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [a])
        let code5 = try await h.code("space.update", ["id": b, "name": "x"], as: "scoped")
        XCTAssertEqual(code5, "NOT_FOUND")
        // The CLI's name filter is applied within scope.
        let named = try result(try await h.call("space.list", ["name": "B"], as: "scoped"))
        XCTAssertEqual((named["spaces"] as? [[String: Any]])?.count, 0)
        let byName = try result(try await h.call("space.list", ["name": "B"]))
        XCTAssertEqual((byName["spaces"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [b])

        let invalid = try await h.call("host.create", ["name": "Prod", "destination": "-oProxyCommand=x", "port": 70000])
        let fields = (((invalid["error"] as? [String: Any])?["data"] as? [String: Any])?["fields"] as? [String: String]) ?? [:]
        XCTAssertFalse(fields.isEmpty, "Bad host fields are named")
        let host: [String: Any] = try await h.value("host", "host.create", ["name": "Prod", "destination": "prod", "port": 2222, "tags": ["a", "b"]])
        let hostID = try XCTUnwrap(host["id"] as? String)
        let revision = try XCTUnwrap(host["revision"] as? Int)
        _ = try result(try await h.call("host.update", ["id": hostID, "name": "Production", "expectedRevision": revision]))
        let code6 = try await h.code("host.update", ["id": hostID, "name": "Stale", "expectedRevision": revision])
        XCTAssertEqual(code6, "CONFLICT")
        let listedHosts = try result(try await h.call("host.list", ["query": "prod"]))
        XCTAssertEqual((listedHosts["hosts"] as? [[String: Any]])?.first?["name"] as? String, "Production")
        _ = try result(try await h.call("host.delete", ["id": hostID]))
        let code7 = try await h.code("host.get", ["id": hostID])
        XCTAssertEqual(code7, "NOT_FOUND")
    }

    @MainActor
    func testFailedFollowUpsAndInvalidRevisionsLeaveNoPartialEffects() async throws {
        let h = try Harness()
        try await h.grant("full")
        defer { h.model.terminals.values.forEach { $0.adapter.detach() } }
        let (spaceID, tab, _) = try createdIDs(try result(try await h.call("space.create", ["name": "One"])))
        let tabID = try XCTUnwrap(UUID(uuidString: tab))
        let paneID = try XCTUnwrap(h.model.snapshot.tabs[tabID]?.activePaneID)
        // Just wide enough for an even split, so a 0.1 ratio breaks the size rules.
        h.model.setCanvasSize(CanvasDimensions.minimum(for: .split(id: UUID(), axis: .x, ratio: 0.5, children: [.pane(UUID()), .pane(UUID())])), tabID: tabID)
        let before = h.model.snapshot
        let narrow = try await h.code("pane.split", ["id": lower(paneID), "axis": "x", "ratio": 0.1])
        XCTAssertEqual(narrow, "INVALID_STATE")
        XCTAssertEqual(h.model.snapshot, before, "A rejected ratio leaves no half-made split")
        XCTAssertEqual(h.model.terminals.count, 1)
        for bad: Any in ["1", 1.5, -1, true] {
            let response = try await h.call("space.update", ["id": spaceID, "name": "Two", "expectedRevision": bad])
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602, "\(bad)")
        }
        XCTAssertEqual(h.model.snapshot, before, "Invalid revisions are never treated as omitted")

        // Maximizing also focuses the pane, exactly as in the UI.
        let split = try result(try await h.call("pane.split", ["id": lower(paneID), "axis": "x"]))
        XCTAssertEqual(lower(try XCTUnwrap(h.model.snapshot.tabs[tabID]?.activePaneID)), (split["pane"] as? [String: Any])?["id"] as? String)
        _ = try result(try await h.call("pane.maximize", ["id": lower(paneID), "maximized": true]))
        XCTAssertEqual(h.model.snapshot.tabs[tabID]?.activePaneID, paneID)
        XCTAssertEqual(h.model.maximizedPanes[tabID], paneID)
        XCTAssertNil(h.model.errorMessage, "Automation never raises UI alerts")
    }

    func testIdempotencyReleasesRetryableFailuresAndBoundsKeysPerGrant() async {
        let cache = IdempotencyCache()
        let grant = UUID(), other = UUID()
        guard case .execute = await cache.begin(grant: grant, key: "k", method: "tab.close", params: nil) else { return XCTFail("first use executes") }
        await cache.finish(grant: grant, key: "k", result: .failure(.application("CLOSE_PENDING", "busy", retryable: true)))
        guard case .execute = await cache.begin(grant: grant, key: "k", method: "tab.close", params: nil) else { return XCTFail("retryable failures are not replayed") }
        await cache.finish(grant: grant, key: "k", result: .failure(.notFound))
        guard case .replay(.failure(.notFound)) = await cache.begin(grant: grant, key: "k", method: "tab.close", params: nil) else { return XCTFail("final outcomes replay") }
        for index in 1..<1_000 { _ = await cache.begin(grant: grant, key: "\(index)", method: "tab.close", params: nil) }
        guard case .limited = await cache.begin(grant: grant, key: "overflow", method: "tab.close", params: nil) else { return XCTFail("keys are bounded") }
        guard case .execute = await cache.begin(grant: other, key: "overflow", method: "tab.close", params: nil) else { return XCTFail("bound is per grant") }
    }

    /// Structure without generated IDs: names, order, tree shape, selection, states.
    @MainActor
    static func normalized(_ snapshot: WorkspaceSnapshot) -> String {
        func layout(_ node: PaneLayout, _ tab: WorkspaceTab) -> String {
            switch node {
            case .pane(let id):
                let state = snapshot.panes[id].flatMap { snapshot.sessions[$0.sessionID] }?.state.rawValue ?? "?"
                return "pane(\(state)\(tab.activePaneID == id ? ",active" : ""))"
            case .split(_, let axis, let ratio, let children):
                return "split(\(axis.rawValue),\(ratio),[\(children.map { layout($0, tab) }.joined(separator: ","))])"
            }
        }
        return snapshot.spaces.map { space in
            let tabs = space.tabIDs.compactMap { snapshot.tabs[$0] }.map { "\($0.title)\($0.id == space.activeTabID ? "*" : ""):\(layout($0.root, $0))" }
            return "\(space.name)\(space.id == snapshot.activeSpaceID ? "*" : "")[\(tabs.joined(separator: ";"))]"
        }.joined(separator: "|")
    }
}
