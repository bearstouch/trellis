import AppKit
import Darwin
import XCTest
import TrellisControl
import TrellisCore
@testable import TrellisUI

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private final class NoSecrets: GrantSecretStore, @unchecked Sendable {
    func store(_ token: String, grantID: UUID) throws {}
    func remove(grantID: UUID) {}
}

private final class MemoryHosts: HostStorage, @unchecked Sendable {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
    func preserveUnreadable() throws {}
}

/// An RPC client wired to a real model through the authorizing handler.
@MainActor
private final class Harness {
    let model: AppWorkspaceModel
    let hosts: HostListModel
    let grants: GrantStore
    let clock: Clock
    var handler: AuthorizingControlHandler
    private var sessions: [String: ControlSession] = [:]
    private var tokens: [String: String] = [:]
    private var nextID = 1

    init(clock: Clock = Clock()) throws {
        _ = NSApplication.shared
        self.clock = clock
        model = AppWorkspaceModel(store: try WorkspaceStore())
        // API calls must never present the UI's modal confirmations.
        model.confirmCloseSessions = { _ in
            XCTFail("Automation showed a close dialog"); return false
        }
        model.confirmForceSessions = { _ in
            XCTFail("Automation showed a force dialog"); return false
        }
        hosts = HostListModel(library: HostLibrary(storage: MemoryHosts()))
        grants = GrantStore(url: nil, secrets: NoSecrets(), now: { [clock] in clock.now })
        handler = AuthorizingControlHandler(
            grants: grants, domain: AutomationService(model: model, hosts: hosts), idempotency: IdempotencyCache(now: { [clock] in clock.now }))
    }

    func grant(_ name: String, _ capabilities: Set<Capability> = Set(Capability.allCases), scope: WindowScope = .all) async throws {
        tokens[name] = try await grants.create(name: name, capabilities: capabilities, windowScope: scope, hostScope: .all, lifetime: 3600).token
        sessions[name] = nil
    }

    /// Fresh handler state (same grants), as after an app relaunch.
    func restartInstance() {
        handler = AuthorizingControlHandler(
            grants: grants, domain: AutomationService(model: model, hosts: hosts), idempotency: IdempotencyCache(now: { [clock] in clock.now }))
        sessions = [:]
    }

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:], as name: String = "full") async throws -> [String: Any] {
        if sessions[name] == nil {
            let session = ControlSession(peerUID: geteuid(), handler: handler)
            sessions[name] = session
            _ = try await send(session, "auth.authenticate", ["protocolVersion": 1, "token": tokens[name]!])
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

private func result(_ response: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
    try XCTUnwrap(response["result"] as? [String: Any], "\(response)", file: file, line: line)
}

private func errorCode(_ response: [String: Any]) -> String? {
    ((response["error"] as? [String: Any])?["data"] as? [String: Any])?["code"] as? String
}

final class AutomationResourceTests: XCTestCase {
    @MainActor
    func testS023_UT01_apiCreatesStoppedHierarchy() async throws {
        let h = try Harness()
        try await h.grant("full")
        let window = try result(try await h.call("window.create", ["name": "Project"]))
        let windowID = try XCTUnwrap(window["windowId"] as? String)
        let firstPane = try XCTUnwrap((window["panes"] as? [[String: Any]])?.first)
        XCTAssertEqual(firstPane["state"] as? String, "stopped")
        let tab = try result(try await h.call("tab.create", ["windowId": windowID, "title": "Logs"]))
        XCTAssertEqual(tab["windowId"] as? String, windowID)
        XCTAssertEqual(tab["title"] as? String, "Logs")
        let tabPane = try XCTUnwrap((tab["paneIds"] as? [String])?.first)
        let split = try result(try await h.call("pane.split", ["paneId": tabPane, "axis": "x", "ratio": 0.3]))
        let newPane = try XCTUnwrap((split["pane"] as? [String: Any])?["paneId"] as? String)
        let layout = try XCTUnwrap((split["tab"] as? [String: Any])?["layout"] as? [String: Any])
        XCTAssertEqual(layout["type"] as? String, "split")
        XCTAssertEqual(layout["id"] as? String, split["branchId"] as? String)
        XCTAssertEqual(layout["axis"] as? String, "x")
        XCTAssertEqual(try XCTUnwrap(layout["ratio"] as? Double), 0.3, accuracy: 0.0001)
        XCTAssertEqual((layout["children"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [tabPane, newPane], "The existing pane is the first child")

        let detail = try result(try await h.call("window.get", ["id": windowID]))
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
    func testS023_UT02_staleMutationHasNoEffects() async throws {
        let h = try Harness()
        try await h.grant("full")
        let created = try result(try await h.call("window.create", ["name": "One"]))
        let windowID = try XCTUnwrap(created["windowId"] as? String)
        defer { h.model.terminals.values.forEach { $0.adapter.detach() } }
        let revision: Int = try await h.value("revision", "window.get", ["id": windowID])
        let renamed = try result(try await h.call("window.update", ["id": windowID, "name": "Two", "expectedRevision": revision]))
        XCTAssertGreaterThan(try XCTUnwrap(renamed["revision"] as? Int), revision)
        let committed = h.model.snapshot
        let stale = try await h.call("window.update", ["id": windowID, "name": "Three", "expectedRevision": revision])
        XCTAssertEqual(errorCode(stale), "CONFLICT")
        XCTAssertEqual(((stale["error"] as? [String: Any])?["data"] as? [String: Any])?["expectedRevision"] as? Int, revision)
        XCTAssertEqual(h.model.snapshot, committed, "A rejected mutation changes nothing")
        let tabID = try XCTUnwrap(created["tabId"] as? String)
        let code1 = try await h.code("tab.update", ["id": tabID, "title": "X", "expectedRevision": 0])
        XCTAssertEqual(code1, "CONFLICT")
        let code2 = try await h.code("window.reorder", ["ids": [windowID], "expectedRevision": 0])
        XCTAssertEqual(code2, "CONFLICT")
        XCTAssertEqual(h.model.snapshot, committed)
        // Omitting the revision targets the latest state.
        _ = try result(try await h.call("window.update", ["id": windowID, "name": "Latest"]))
        XCTAssertEqual(h.model.snapshot.windows.first?.name, "Latest")
    }

    @MainActor
    func testS023_UT03_idempotencyKeyScopeAndExpiry() async throws {
        let h = try Harness()
        try await h.grant("full")
        try await h.grant("other")
        defer { h.model.terminals.values.forEach { $0.adapter.detach() } }
        let first = try result(try await h.call("window.create", ["name": "A", "idempotencyKey": "k1"]))
        let replay = try result(try await h.call("window.create", ["name": "A", "idempotencyKey": "k1"]))
        XCTAssertEqual(replay["windowId"] as? String, first["windowId"] as? String)
        XCTAssertEqual(h.model.snapshot.windows.count, 1, "The duplicate executed once")
        let code3 = try await h.code("window.create", ["name": "B", "idempotencyKey": "k1"])
        XCTAssertEqual(code3, "CONFLICT")
        XCTAssertEqual(h.model.snapshot.windows.count, 1)

        // Another grant has its own key space.
        _ = try result(try await h.call("window.create", ["name": "A", "idempotencyKey": "k1"], as: "other"))
        XCTAssertEqual(h.model.snapshot.windows.count, 2)

        // After ten minutes the key is forgotten.
        h.clock.advance(601)
        _ = try result(try await h.call("window.create", ["name": "A", "idempotencyKey": "k1"]))
        XCTAssertEqual(h.model.snapshot.windows.count, 3)

        // A new app instance does not promise deduplication.
        _ = try result(try await h.call("window.create", ["name": "C", "idempotencyKey": "k2"]))
        h.restartInstance()
        _ = try result(try await h.call("window.create", ["name": "C", "idempotencyKey": "k2"]))
        XCTAssertEqual(h.model.snapshot.windows.count, 5)
        let oversizedKey = try await h.call("window.create", ["name": "D", "idempotencyKey": String(repeating: "x", count: 200)])
        XCTAssertEqual((oversizedKey["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual(h.model.snapshot.windows.count, 5)
    }

    @MainActor
    func testS023_UT04_apiUiDomainEquivalence() async throws {
        // UI path.
        let ui = try Harness()
        await ui.model.createWindow(name: "Project", startSession: false)
        let uiWindow = try XCTUnwrap(ui.model.presentation.selectedWindow?.id)
        let createdTab = await ui.model.createTab(windowID: uiWindow, startSessions: false)
        let uiTab = try XCTUnwrap(createdTab)
        await ui.model.renameTab(uiTab, title: "Logs")
        let uiPane = try XCTUnwrap(ui.model.snapshot.tabs[uiTab]?.activePaneID)
        _ = await ui.model.splitPane(uiPane, axis: .y, startSession: false)
        await ui.model.renameWindow(uiWindow, name: "Renamed")
        defer { ui.model.terminals.values.forEach { $0.adapter.detach() } }

        // API path.
        let api = try Harness()
        try await api.grant("full")
        defer { api.model.terminals.values.forEach { $0.adapter.detach() } }
        let window: String = try await api.value("windowId", "window.create", ["name": "Project"])
        let tab = try result(try await api.call("tab.create", ["windowId": window, "title": "Logs"]))
        let pane = try XCTUnwrap((tab["paneIds"] as? [String])?.first)
        _ = try result(try await api.call("pane.split", ["paneId": pane, "axis": "y"]))
        _ = try result(try await api.call("window.update", ["id": window, "name": "Renamed"]))

        XCTAssertEqual(Self.normalized(ui.model.snapshot), Self.normalized(api.model.snapshot))
        try ui.model.snapshot.validate()
        try api.model.snapshot.validate()
    }

    @MainActor
    func testClosingRunningContainersNeedsAllowRunningAndCloseCapability() async throws {
        let h = try Harness()
        try await h.grant("full")
        try await h.grant("layout", [.metadataRead, .layoutWrite])
        let created = try result(try await h.call("window.create", ["name": "Live"]))
        let windowID = try XCTUnwrap(created["windowId"] as? String)
        let paneID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap((created["panes"] as? [[String: Any]])?.first?["paneId"] as? String)))
        _ = try await h.model.service.execute(
            .configureStoppedSession(paneID: paneID, launch: .process(executable: "/bin/sleep", arguments: ["30"], directory: "/tmp")))
        await h.model.refresh()
        await h.model.start(paneID: paneID)
        let terminal = try XCTUnwrap(h.model.terminals[paneID])
        defer { terminal.requestTermination(force: true); terminal.adapter.detach() }
        XCTAssertTrue(terminal.isRunning)

        let unconfirmed = try await h.call("window.close", ["id": windowID])
        XCTAssertEqual(errorCode(unconfirmed), "CONFIRMATION_REQUIRED")
        XCTAssertEqual(((unconfirmed["error"] as? [String: Any])?["data"] as? [String: Any])?["sessionIds"] as? [String], [terminal.sessionID.uuidString])
        let code4 = try await h.code("window.close", ["id": windowID, "allowRunning": true], as: "layout")
        XCTAssertEqual(code4, "PERMISSION_DENIED")
        XCTAssertTrue(terminal.isRunning, "Denied closes send no signal")

        // Launch details are redacted without session.execute.
        let redacted = try result(try await h.call("session.get", ["id": terminal.sessionID.uuidString], as: "layout"))
        XCTAssertNil(redacted["executable"])
        XCTAssertNil(redacted["arguments"])
        let full = try result(try await h.call("session.get", ["id": terminal.sessionID.uuidString]))
        XCTAssertEqual(full["executable"] as? String, "/bin/sleep")

        // A stale revision is rejected before any session is signaled.
        let windowRevision: Int = try await h.value("revision", "window.get", ["id": windowID])
        _ = try result(try await h.call("window.update", ["id": windowID, "name": "Renamed"]))
        let stale = try await h.code("window.close", ["id": windowID, "allowRunning": true, "expectedRevision": windowRevision])
        XCTAssertEqual(stale, "CONFLICT")
        XCTAssertTrue(terminal.isRunning, "A conflicting close sends no signal")

        let closed = try result(try await h.call("window.close", ["id": windowID, "allowRunning": true]))
        XCTAssertEqual(closed["closed"] as? Bool, true)
        XCTAssertFalse(terminal.isRunning)
        XCTAssertTrue(h.model.snapshot.windows.isEmpty)
    }

    @MainActor
    func testWindowScopedGrantSeesOnlyItsWindowsAndHostFieldsValidate() async throws {
        let h = try Harness()
        try await h.grant("full")
        defer { h.model.terminals.values.forEach { $0.adapter.detach() } }
        let a: String = try await h.value("windowId", "window.create", ["name": "A"])
        let b: String = try await h.value("windowId", "window.create", ["name": "B"])
        try await h.grant("scoped", [.metadataRead, .layoutWrite], scope: .windows([UUID(uuidString: a)!]))
        let listed = try result(try await h.call("window.list", as: "scoped"))
        XCTAssertEqual((listed["windows"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [a])
        let code5 = try await h.code("window.update", ["id": b, "name": "x"], as: "scoped")
        XCTAssertEqual(code5, "NOT_FOUND")

        let invalid = try await h.call("host.create", ["name": "Prod", "destination": "-oProxyCommand=x", "port": 70000])
        let fields = (((invalid["error"] as? [String: Any])?["data"] as? [String: Any])?["fields"] as? [String: String]) ?? [:]
        XCTAssertEqual(Set(fields.keys), ["destination", "port"])
        let host = try result(try await h.call("host.create", ["name": "Prod", "destination": "prod", "port": 2222, "tags": ["a", "b"]]))
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
        let created = try result(try await h.call("window.create", ["name": "One"]))
        let tabID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created["tabId"] as? String)))
        let paneID = try XCTUnwrap(h.model.snapshot.tabs[tabID]?.activePaneID)
        // Just wide enough for an even split, so a 0.1 ratio breaks the size rules.
        h.model.setCanvasSize(CanvasDimensions.minimum(for: .split(id: UUID(), axis: .x, ratio: 0.5, children: [.pane(UUID()), .pane(UUID())])), tabID: tabID)
        let before = h.model.snapshot
        let narrow = try await h.code("pane.split", ["paneId": paneID.uuidString, "axis": "x", "ratio": 0.1])
        XCTAssertEqual(narrow, "INVALID_STATE")
        XCTAssertEqual(h.model.snapshot, before, "A rejected ratio leaves no half-made split")
        XCTAssertEqual(h.model.terminals.count, 1)
        for bad: Any in ["1", 1.5, -1, true] {
            let response = try await h.call("window.update", ["id": created["windowId"]!, "name": "Two", "expectedRevision": bad])
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602, "\(bad)")
        }
        XCTAssertEqual(h.model.snapshot, before, "Invalid revisions are never treated as omitted")

        // Maximizing also focuses the pane, exactly as in the UI.
        let split = try result(try await h.call("pane.split", ["paneId": paneID.uuidString, "axis": "x"]))
        XCTAssertEqual(h.model.snapshot.tabs[tabID]?.activePaneID.uuidString, (split["pane"] as? [String: Any])?["paneId"] as? String)
        _ = try result(try await h.call("pane.maximize", ["id": paneID.uuidString, "maximized": true]))
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
        return snapshot.windows.map { window in
            let tabs = window.tabIDs.compactMap { snapshot.tabs[$0] }.map { "\($0.title)\($0.id == window.activeTabID ? "*" : ""):\(layout($0.root, $0))" }
            return "\(window.name)\(window.id == snapshot.activeWindowID ? "*" : "")[\(tabs.joined(separator: ";"))]"
        }.joined(separator: "|")
    }
}
