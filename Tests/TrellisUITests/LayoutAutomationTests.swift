import AppKit
import XCTest
import TrellisControl
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

final class LayoutAutomationTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    /// A harness whose "login shell" is a fixture that just stays alive.
    @MainActor
    private func harness() async throws -> Harness {
        let h = try Harness()
        try await h.grant("full")
        let shell = scratch.appendingPathComponent("fake-shell")
        try Data("#!/bin/sh\nprintf 'FAKE-SHELL\\n'\nexec /bin/sleep 30\n".utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        let saved = await h.model.saveLaunchSettings(shell: shell.path, directory: scratch.path)
        XCTAssertTrue(saved)
        return h
    }

    private func example() throws -> Any {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("docs/api/example-layout.json")))
    }

    private func single(_ key: String, launch: [String: Any] = ["kind": "shell"]) -> [String: Any] {
        ["version": 3, "spaces": [["key": key, "name": key, "tabs": [["key": "\(key)-tab", "title": key, "root": ["type": "pane", "key": "\(key)-pane", "launch": launch]]]]]]
    }

    @MainActor
    private func apply(_ h: Harness, _ document: Any, namespace: String = "project", startNew: Bool = false) async throws -> [String: Any] {
        let plan = try result(try await h.call("layout.plan", ["namespace": namespace, "document": document]))
        return try await h.call("layout.apply", ["namespace": namespace, "document": document, "expectedRevision": plan["baseRevision"] as Any, "startNew": startNew])
    }

    /// Each launch's session state, as layout.apply reports it.
    private func states(_ launches: [[String: Any]]) -> [String] { launches.compactMap { ($0["session"] as? [String: Any])?["state"] as? String } }

    // startNew launches are independent of apply, so settle them before snapshot comparisons.
    @MainActor
    private func settleLaunches(_ h: Harness) async throws {
        let deadline = Date().addingTimeInterval(5)
        while h.model.snapshot.sessions.values.contains(where: { $0.state == .starting }), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(h.model.snapshot.sessions.values.contains { $0.state == .starting })
    }

    @MainActor
    func testExampleApplyTwiceIsStable() async throws {
        let h = try await harness()
        defer {
            h.model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }; h.discardPreferences()
        }
        let document = try example()
        let first = try result(try await apply(h, document, startNew: true))
        let launches = try XCTUnwrap(first["launches"] as? [[String: Any]])
        XCTAssertEqual(launches.compactMap { $0["key"] as? String }, ["editor", "server", "checks"])
        XCTAssertEqual(states(launches), ["running", "running", "running"])
        let mapping = try XCTUnwrap(first["mapping"] as? [String: [String: String]])
        XCTAssertEqual(Set(mapping.keys), ["project", "development", "main-split", "editor", "tools-split", "server", "checks"])
        // Launch completion reaches the store asynchronously; compare settled snapshots.
        let deadline = Date().addingTimeInterval(5)
        while h.model.snapshot.sessions.values.contains(where: { $0.state != .running }), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let pids = Set(h.model.terminals.values.compactMap(\.processID))
        let snapshot = h.model.snapshot
        let tab = try XCTUnwrap(snapshot.tabs[try XCTUnwrap(UUID(uuidString: try XCTUnwrap(mapping["development"]?["id"])))])
        guard case .split(let branch, .x, 0.6, let children) = tab.root else { return XCTFail("\(tab.root)") }
        XCTAssertEqual(lower(branch), mapping["main-split"]?["id"])
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(snapshot.panes[try XCTUnwrap(UUID(uuidString: mapping["editor"]!["id"]!))]?.title, "Editor")

        let second = try result(try await apply(h, document, startNew: true))
        XCTAssertEqual(second["mapping"] as? [String: [String: String]], mapping, "Stable IDs on reapply")
        XCTAssertEqual((second["launches"] as? [Any])?.count, 0, "No new launches on reapply")
        XCTAssertEqual(second["changed"] as? Bool, false)
        XCTAssertEqual(h.model.snapshot, snapshot)
        XCTAssertEqual(Set(h.model.terminals.values.compactMap(\.processID)), pids)

        // A shell without a directory resolves to the default one when started; reapply still matches it.
        let plain = single("plain")
        let started = try result(try await apply(h, plain, namespace: "plain", startNew: true))
        XCTAssertEqual(states(started["launches"] as? [[String: Any]] ?? []), ["running"])
        let again = try result(try await apply(h, plain, namespace: "plain", startNew: true))
        XCTAssertEqual(again["changed"] as? Bool, false)
        XCTAssertEqual((again["launches"] as? [Any])?.count, 0)

        // Panes created stopped are never started by a later startNew reapply.
        let idle = single("idle")
        let created = try result(try await apply(h, idle, namespace: "idle"))
        XCTAssertEqual((created["launches"] as? [Any])?.count, 0)
        let paneID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap((created["mapping"] as? [String: [String: String]])?["idle-pane"]?["id"])))
        let reapplied = try result(try await apply(h, idle, namespace: "idle", startNew: true))
        XCTAssertEqual((reapplied["launches"] as? [Any])?.count, 0)
        XCTAssertEqual(h.model.snapshot.panes[paneID].flatMap { h.model.snapshot.sessions[$0.sessionID] }?.state, .stopped)
    }

    @MainActor
    func testSchemaAndSemanticFailuresAreAtomic() async throws {
        let h = try await harness()
        defer {
            h.model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }; h.discardPreferences()
        }
        func pane(_ key: String, _ launch: [String: Any] = ["kind": "shell"]) -> [String: Any] { ["type": "pane", "key": key, "launch": launch] }
        func doc(_ root: [String: Any], space: [String: Any] = [:]) -> [String: Any] {
            ["version": 3, "spaces": [["key": "w", "name": "W", "tabs": [["key": "t", "title": "T", "root": root]]].merging(space) { $1 }]]
        }
        var deep: [String: Any] = pane("leaf0")
        for level in 0..<17 { deep = ["type": "split", "key": "s\(level)", "axis": "x", "ratio": 0.5, "children": [deep, pane("leaf\(level + 1)")]] }
        // A balanced tree keeps JSON nesting shallow while exceeding 100 panes.
        var leaves: [[String: Any]] = (0...100).map { pane("p\($0)") }
        var branch = 0
        while leaves.count > 1 {
            var next: [[String: Any]] = []
            for pair in stride(from: 0, to: leaves.count - 1, by: 2) {
                branch += 1
                next.append(["type": "split", "key": "b\(branch)", "axis": "y", "ratio": 0.5, "children": [leaves[pair], leaves[pair + 1]]])
            }
            if leaves.count % 2 == 1 { next.append(leaves[leaves.count - 1]) }
            leaves = next
        }
        let wide = leaves[0]
        let invalid: [(String, [String: Any])] = [
            ("duplicate keys", doc(["type": "split", "key": "x", "axis": "x", "ratio": 0.5, "children": [pane("a"), pane("a")]])),
            ("depth", doc(deep)),
            ("panes", doc(wide)),
            ("relative", doc(pane("p", ["kind": "shell", "directory": "projects/app"]))),
            ("parent", doc(pane("p", ["kind": "shell", "directory": "/tmp/../etc"]))),
            ("expansion", doc(pane("p", ["kind": "shell", "directory": "$HOME/app"]))),
            ("other user", doc(pane("p", ["kind": "shell", "directory": "~root/app"]))),
            ("unknown host", doc(pane("p", ["kind": "ssh", "hostId": UUID().uuidString]))),
            ("v1 host launch", doc(pane("p", ["kind": "host", "hostId": UUID().uuidString]))),
            ("unknown machine", doc(pane("p"), space: ["machine": ["kind": "remote", "hostId": UUID().uuidString]])),
            ("agent on ssh", doc(pane("p", ["kind": "ssh", "hostId": UUID().uuidString]).merging(["agent": "trellis-claude-code"]) { $1 })),
            ("windows", ["version": 1, "windows": []]),
            ("process", doc(pane("p", ["kind": "process", "executable": "/bin/sh"]))),
            ("command field", doc(pane("p", ["kind": "shell", "command": "rm -rf ~"]))),
            ("bad ratio", doc(["type": "split", "key": "x", "axis": "x", "ratio": 0.95, "children": [pane("a"), pane("b")]])),
            ("bad key", doc(pane("-bad"))),
            ("extra field", doc(pane("p"), space: ["onOpen": "make"]))
        ]
        let before = h.model.snapshot
        for (name, document) in invalid {
            let validated = try result(try await h.call("layout.validate", ["document": document]))
            XCTAssertEqual(validated["valid"] as? Bool, false, name)
            XCTAssertFalse((validated["errors"] as? [Any])?.isEmpty ?? true, name)
            let applied = try await h.call("layout.apply", ["namespace": "n", "document": document, "expectedRevision": before.revision, "startNew": true])
            XCTAssertEqual((applied["error"] as? [String: Any])?["code"] as? Int, -32602, name)
        }
        for version in [0, 4] {
            let document: [String: Any] = ["version": version, "spaces": []]
            let validated = try await h.code("layout.validate", ["document": document])
            XCTAssertEqual(validated, "UNSUPPORTED_VERSION")
            let applied = try await h.code("layout.apply", ["namespace": "n", "document": document, "expectedRevision": before.revision])
            XCTAssertEqual(applied, "UNSUPPORTED_VERSION")
        }
        // Layout namespaces follow the key pattern, so a layout can never reach a project launch's bindings.
        let projectNamespace = try await h.call("layout.plan", ["namespace": "project:\(UUID().uuidString):local:~", "document": doc(pane("p"))])
        XCTAssertEqual((projectNamespace["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual(h.model.snapshot, before, "No model effects")
        XCTAssertTrue(h.model.terminals.values.allSatisfy { !$0.isRunning }, "No process effects")
        let valid = try result(try await h.call("layout.validate", ["document": doc(pane("p", ["kind": "shell", "directory": "~/no-such-dir-\(UUID().uuidString)"]))]))
        XCTAssertEqual(valid["valid"] as? Bool, true)
        XCTAssertEqual((valid["warnings"] as? [Any])?.count, 1, "Missing directories are warnings, checked again at start")
        let control = try result(try await h.call("layout.validate", ["document": doc(pane("p", ["kind": "shell", "directory": "/tmp/a\tb"]))]))
        XCTAssertEqual(control["valid"] as? Bool, false, "Control characters are rejected in paths")

        // Unreadable bindings fail closed instead of being treated as empty and overwritten.
        let persisted = AppWorkspaceModel(store: try WorkspaceStore(), preferences: h.preferences, persistence: WorkspacePersistence(directory: scratch))
        let bindingsFile = scratch.appendingPathComponent("layout-bindings.json")
        try OwnerOnlyFile.publish(Data("not json".utf8), to: bindingsFile)
        XCTAssertThrowsError(try persisted.layoutBindings("project"))
        XCTAssertEqual(try Data(contentsOf: bindingsFile), Data("not json".utf8))
    }

    @MainActor
    func testStalePlanAndLiveChangesConflict() async throws {
        let h = try await harness()
        defer {
            h.model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }; h.discardPreferences()
        }
        let document = try example()
        let plan = try result(try await h.call("layout.plan", ["namespace": "project", "document": document]))
        _ = try await h.code("space.create", ["name": "Racing change"])
        let raced = h.model.snapshot
        let stale = try await h.call("layout.apply", ["namespace": "project", "document": document, "expectedRevision": plan["baseRevision"] as Any])
        XCTAssertEqual(errorCode(stale), "CONFLICT")
        XCTAssertEqual(h.model.snapshot, raced)

        _ = try result(try await apply(h, document, startNew: true))
        try await settleLaunches(h)
        let live = h.model.snapshot
        // Changing a running pane's launch, or moving a pane to another tab, conflicts.
        func retarget(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                if object["key"] as? String == "editor" { object["launch"] = ["kind": "shell", "directory": "/tmp"] }
                return object.mapValues(retarget)
            }
            if let array = value as? [Any] { return array.map(retarget) }
            return value
        }
        let changed = retarget(document)
        let livePlan = try result(try await h.call("layout.plan", ["namespace": "project", "document": changed]))
        XCTAssertEqual(livePlan["applicable"] as? Bool, false)
        XCTAssertTrue(((livePlan["conflicts"] as? [[String: Any]]) ?? []).contains { $0["key"] as? String == "editor" })
        let conflict = try await h.call("layout.apply", ["namespace": "project", "document": changed, "expectedRevision": livePlan["baseRevision"] as Any])
        XCTAssertEqual(errorCode(conflict), "CONFLICT")
        XCTAssertEqual(h.model.snapshot, live, "No partial updates")

        let moved: [String: Any] = [
            "version": 3,
            "spaces": [
                [
                    "key": "project", "name": "Project",
                    "tabs": [["key": "other", "title": "Other", "root": ["type": "pane", "key": "server", "launch": ["kind": "shell", "directory": "~"]]]]
                ]
            ]
        ]
        let movePlan = try result(try await h.call("layout.plan", ["namespace": "project", "document": moved]))
        XCTAssertEqual(movePlan["applicable"] as? Bool, false)
        XCTAssertEqual(h.model.snapshot, live)

        // A grant scoped to another window plans as if hidden bindings did not exist.
        let visible = try XCTUnwrap(live.spaces.first { $0.name == "Racing change" }?.id)
        try await h.grant("scoped", scope: .spaces([visible]))
        let scoped = try result(try await h.call("layout.plan", ["namespace": "project", "document": changed], as: "scoped"))
        XCTAssertEqual((scoped["conflicts"] as? [Any])?.count, 0)
        XCTAssertEqual((scoped["updates"] as? [Any])?.count, 0)
        XCTAssertEqual((scoped["creates"] as? [[String: Any]])?.count, 5, "Hidden managed resources look absent")

        // A split key reused in a new tab (its old tab omitted) gets a new ID rather than a duplicate.
        let reused: [String: Any] = [
            "version": 3,
            "spaces": [
                [
                    "key": "project", "name": "Project",
                    "tabs": [
                        [
                            "key": "other", "title": "Other",
                            "root": [
                                "type": "split", "key": "main-split", "axis": "y", "ratio": 0.5,
                                "children": [["type": "pane", "key": "x", "launch": ["kind": "shell"]], ["type": "pane", "key": "y", "launch": ["kind": "shell"]]]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let reapplied = try result(try await apply(h, reused))
        let mapping = try XCTUnwrap(reapplied["mapping"] as? [String: [String: String]])
        try h.model.snapshot.validate()
        XCTAssertEqual(h.model.snapshot.panes.count, live.panes.count + 2)
        guard case .split(let original, _, _, _) = try XCTUnwrap(live.tabs.values.first { $0.title == "Development" }).root else { return XCTFail() }
        XCTAssertNotEqual(mapping["main-split"]?["id"], lower(original))
    }

    @MainActor
    func testPartialLaunchFailureIsReported() async throws {
        let h = try await harness()
        defer {
            h.model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }; h.discardPreferences()
        }
        let document: [String: Any] = [
            "version": 3,
            "spaces": [
                [
                    "key": "ops", "name": "Ops",
                    "tabs": [
                        [
                            "key": "main", "title": "Main",
                            "root": [
                                "type": "split", "key": "split", "axis": "x", "ratio": 0.5,
                                "children": [
                                    ["type": "pane", "key": "good", "launch": ["kind": "shell", "directory": scratch.path]],
                                    ["type": "pane", "key": "bad", "launch": ["kind": "shell", "directory": "/nonexistent-trellis-\(UUID().uuidString)"]]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let applied = try result(try await apply(h, document, namespace: "ops", startNew: true))
        let launches = try XCTUnwrap(applied["launches"] as? [[String: Any]])
        XCTAssertEqual(launches.compactMap { $0["key"] as? String }, ["good", "bad"])
        XCTAssertEqual(states(launches), ["running", "failed"])
        let snapshot = h.model.snapshot
        try snapshot.validate()
        XCTAssertEqual(snapshot.spaces.map(\.name), ["Ops"])
        XCTAssertEqual(snapshot.panes.count, 2, "The committed layout stays; the running pane is not rolled back")

        // Omitted resources remain and are reported as unmanaged.
        _ = try await h.code("space.create", ["name": "Manual"])
        let replan = try result(try await h.call("layout.plan", ["namespace": "ops", "document": document]))
        XCTAssertEqual((replan["unmanaged"] as? [String])?.count, 1)
        let exported = try result(try await h.call("layout.export"))
        XCTAssertEqual(exported["importable"] as? Bool, true)
        XCTAssertEqual((exported["document"] as? [String: Any])?["version"] as? Int, 3)
        let validated = try result(try await h.call("layout.validate", ["document": exported["document"] as Any]))
        XCTAssertEqual(validated["valid"] as? Bool, true, "Exports validate as layouts")
        XCTAssertNil(validated["upgradedFrom"])
    }
    /// Version 3 (layouts.md): a space's machine and project, agent panes, the capabilities they need, and older versions
    /// read as version 3.
    @MainActor
    func testVersion3BindsMachinesProjectsAndAgents() async throws {
        let h = try await harness()
        defer { h.model.terminals.values.forEach { $0.adapter.detach() }; h.discardPreferences() }
        let host: [String: Any] = try await h.value("host", "host.create", ["name": "Box", "destination": "box"])
        let other: [String: Any] = try await h.value("host", "host.create", ["name": "Other", "destination": "other"])
        let hostID = try XCTUnwrap(host["id"] as? String), otherID = try XCTUnwrap(other["id"] as? String)
        let project = UUID()
        func document(machine: String) -> [String: Any] {
            [
                "version": 3,
                "spaces": [
                    [
                        "key": "app", "name": "App", "projectId": project.uuidString,
                        "tabs": [["key": "code", "title": "Code", "root": ["type": "pane", "key": "claude", "launch": ["kind": "shell", "directory": "/tmp"], "agent": "trellis-claude-code"]]]
                    ],
                    [
                        "key": "box", "name": "Box", "machine": ["kind": "remote", "hostId": machine],
                        "tabs": [["key": "remote", "title": "Remote", "root": ["type": "pane", "key": "shell", "launch": ["kind": "shell", "directory": "~/src"]]]]
                    ]
                ]
            ]
        }
        // What the document's contents need is checked before anything is planned or created.
        try await h.grant("layout", [.workspaceRead, .workspaceWrite])
        let before = h.model.snapshot
        let denied = try await h.call("layout.apply", ["namespace": "v3", "document": document(machine: hostID), "expectedRevision": before.revision], as: "layout")
        XCTAssertEqual(errorCode(denied), "PERMISSION_DENIED")
        let missing = (((denied["error"] as? [String: Any])?["data"] as? [String: Any])?["details"] as? [String: Any])?["missing"] as? [String]
        XCTAssertEqual(missing, ["agent.control", "project.launch", "remote.connect"])
        XCTAssertEqual(h.model.snapshot, before)

        let applied = try result(try await apply(h, document(machine: hostID), namespace: "v3"))
        let mapping = try XCTUnwrap(applied["mapping"] as? [String: [String: String]])
        let snapshot = h.model.snapshot
        let app = try XCTUnwrap(snapshot.spaces.first { lower($0.id) == mapping["app"]?["id"] })
        XCTAssertEqual(app.projectID, project, "projectId binds the space (FR-W08)")
        XCTAssertEqual(snapshot.tabs[app.activeTabID]?.projectKey, "code", "Its declared tabs are project tabs")
        let agentPane = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(mapping["claude"]?["id"])))
        XCTAssertEqual(
            snapshot.panes[agentPane].flatMap { snapshot.sessions[$0.sessionID] }?.launch, .agent(AgentLaunch(agentID: "trellis-claude-code", directory: "/tmp")),
            "An agent pane is the agent's launch, created stopped")
        let box = try XCTUnwrap(snapshot.spaces.first { lower($0.id) == mapping["box"]?["id"] })
        XCTAssertEqual(box.remoteHostID.map(lower), hostID, "machine binds a remote workspace")
        let remotePane = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(mapping["shell"]?["id"])))
        guard case .remoteShell(let paneHost, let directory)? = snapshot.panes[remotePane].flatMap({ snapshot.sessions[$0.sessionID] })?.launch else {
            return XCTFail("Not a remote shell")
        }
        XCTAssertEqual(lower(paneHost), hostID)
        XCTAssertEqual(directory, "~/src", "A remote space's ~ is the host's home, resolved when its link is up")
        XCTAssertEqual(AppWorkspaceModel.hostPath(directory, home: "/home/dev"), "/home/dev/src")
        XCTAssertEqual(AppWorkspaceModel.hostPath("~", home: "/home/dev"), "/home/dev")
        XCTAssertNil(AppWorkspaceModel.hostPath("~/src", home: nil), "Without the host's home the helper starts in it")
        XCTAssertEqual(AppWorkspaceModel.hostPath("/srv/app", home: nil), "/srv/app")
        XCTAssertTrue(h.model.terminals.values.allSatisfy { !$0.isRunning }, "Nothing starts without startNew")

        // A bound space can't change machine.
        let moved = try result(try await h.call("layout.plan", ["namespace": "v3", "document": document(machine: otherID)]))
        XCTAssertEqual(moved["applicable"] as? Bool, false)
        XCTAssertTrue(((moved["conflicts"] as? [[String: Any]]) ?? []).contains { $0["key"] as? String == "box" })

        // Exports write version 3 with what the grant may see.
        let exportResult = try result(try await h.call("layout.export"))
        let exported = try XCTUnwrap(exportResult["document"] as? [String: Any])
        let spaces = try XCTUnwrap(exported["spaces"] as? [[String: Any]])
        XCTAssertEqual(exported["version"] as? Int, 3)
        XCTAssertEqual(spaces.first { $0["name"] as? String == "App" }?["projectId"] as? String, lower(project))
        XCTAssertEqual((spaces.first { $0["name"] as? String == "Box" }?["machine"] as? [String: Any])?["hostId"] as? String, hostID)
        XCTAssertTrue(String(describing: exported).contains("trellis-claude-code"))
        try await h.grant("reader", [.workspaceRead])
        let redacted = try result(try await h.call("layout.export", as: "reader"))
        XCTAssertEqual(redacted["redacted"] as? Bool, true)
        XCTAssertEqual(redacted["importable"] as? Bool, false)
        XCTAssertFalse(String(describing: redacted["document"] ?? "").contains(hostID), "Hosts need host.read")

        // Versions 1 and 2 are read as version 3: `host` launches are ssh ones; a list named windows is refused.
        let hostPane: [String: Any] = ["type": "pane", "key": "ssh", "launch": ["kind": "host", "hostId": hostID]]
        for version in [1, 2] {
            let old: [String: Any] = ["version": version, "spaces": [["key": "old", "name": "Old", "tabs": [["key": "t", "title": "T", "root": hostPane]]]]]
            let validated = try result(try await h.call("layout.validate", ["document": old]))
            XCTAssertEqual(validated["valid"] as? Bool, true, "version \(version)")
            XCTAssertEqual(validated["version"] as? Int, 3)
            XCTAssertEqual(validated["upgradedFrom"] as? Int, version)
        }
        let windows = try result(try await h.call("layout.validate", ["document": ["version": 1, "windows": [] as [Any]]]))
        XCTAssertEqual(windows["valid"] as? Bool, false)
        XCTAssertTrue(String(describing: windows["errors"] ?? "").contains("spaces"))
    }

    @MainActor
    func testReapplyingLayoutKeepsTabColorLabel() async throws {
        let h = try await harness()
        defer { h.model.terminals.values.forEach { $0.adapter.detach() }; h.discardPreferences() }
        let first = try result(try await apply(h, single("a")))
        let tabID = try XCTUnwrap((first["mapping"] as? [String: [String: String]])?["a-tab"]?["id"])
        _ = try result(try await h.call("tab.update", ["id": tabID, "color": "green"]))
        var renamed = single("a")
        if var spaces = renamed["spaces"] as? [[String: Any]], var tabs = spaces[0]["tabs"] as? [[String: Any]] {
            tabs[0]["title"] = "Renamed"; spaces[0]["tabs"] = tabs; renamed["spaces"] = spaces
        }
        _ = try result(try await apply(h, renamed))
        let tab = try XCTUnwrap(h.model.snapshot.tabs[try XCTUnwrap(UUID(uuidString: tabID))])
        XCTAssertEqual(tab.title, "Renamed")
        XCTAssertEqual(tab.color, .green, "Layouts don't declare labels, so applying one never wipes them")
    }
}
