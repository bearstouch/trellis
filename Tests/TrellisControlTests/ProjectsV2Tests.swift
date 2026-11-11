import Darwin
import XCTest
import TrellisCore
@testable import TrellisControl

/// Phase 7 in the control layer: the project and task declarations, `session.execute`'s wait answered out of order, and
/// the project, plan, task and space projections with their redaction. The model side is `AutomationV2ProjectTests`,
/// `AutomationV2TaskTests` and `AutomationV2RemoteProjectTests`.
final class ProjectsV2Tests: XCTestCase {
    private let clock = TestClock()
    private let domain = FakeDomain()
    private lazy var domainV2 = FakeDomainV2(base: domain)
    private lazy var store = GrantStore(url: nil, secrets: MemorySecrets(), now: { [clock] in clock.now })
    private let host = SavedHost(id: UUID(), draft: try! HostDraft(name: "Build", destination: "build").validated { _ in false }, revision: 3, connectionRevision: 2)

    private func spec(_ name: String) throws -> MethodSpecV2 { try XCTUnwrap(MethodCatalogV2.spec(name), name) }

    func testDeclarations() throws {
        // Only the remote methods always wait; the others wait only with the parameters that make them.
        XCTAssertEqual(MethodCatalogV2.methods.filter(\.waits).map(\.name), ["remote.open", "remote.reconnect", "remote.helper.install", "remote.helper.remove"])
        let execute = try spec("session.execute")
        XCTAssertFalse(execute.waits(for: ["id": .string(UUID().uuidString), "command": .string("ls")]))
        XCTAssertTrue(execute.waits(for: ["wait": .object(["until": .string("finished")])]))
        let launch = try spec("project.launch")
        XCTAssertFalse(launch.waits(for: ["target": .object(["kind": .string("local")])]), "A local launch without setup is quick")
        XCTAssertTrue(launch.waits(for: ["target": .object(["kind": .string("host")])]))
        XCTAssertTrue(launch.waits(for: ["target": .object(["kind": .string("local")]), "setup": .bool(true)]))
        XCTAssertTrue(launch.createsSpace)
        XCTAssertEqual(launch.revisionTarget, .resource(param: "id"), "expectedRevision is the project's: the revision project.check returned")
        XCTAssertEqual(
            launch.requirementSummary, "project.launch + session.start (+session.execute if setup or folder, +remote.connect if target.kind is host), all or created spaces")
        XCTAssertTrue(launch.errors.isSuperset(of: [.setupRequired, .conflict, .launchFailed, .remoteDisconnected, .confirmationRequired, .notFound]))
        XCTAssertEqual(try spec("project.check").requirementSummary, "project.read (+remote.connect if target.kind is host)")
        XCTAssertTrue(try spec("project.check").waits(for: ["target": .object(["kind": .string("host")])]))
        XCTAssertEqual(try spec("project.create").requirementSummary, "project.write + session.execute")
        XCTAssertEqual(try spec("project.capture").requirementSummary, "project.write + workspace.read")
        XCTAssertTrue(try spec("project.delete").isDestructive)
        XCTAssertEqual(try spec("task.run").errors.intersection([.taskUntrusted, .invalidState]), [.taskUntrusted, .invalidState])
        XCTAssertEqual(try spec("task.run").revisionTarget, .resource(param: "paneId"))
        XCTAssertTrue(try spec("task.stop").isDestructive)
        XCTAssertTrue(try spec("task.list").paginated)
        XCTAssertEqual(
            MethodCatalogV2.problems(in: [MethodSpecV2("a.b", "Bad.", waits: true, waitsIf: .present("x"))]).sorted(),
            [
                "a.b: condition depends on undeclared x", "a.b: waits and waitsIf are exclusive"
            ])
    }

    /// session.execute with `wait` may wait for a long command, so the socket answers it out of order like a remote call
    /// (sharing the 16-call budget); without `wait` it keeps its place in the connection's order.
    func testExecuteWithWaitIsAnsweredOutOfOrder() async throws {
        domainV2.hold(["session.execute"])
        let handler = AuthorizingControlHandler(grants: store, domain: domain, v2Domain: domainV2)
        let (_, token) = try await store.create(GrantSettings(name: "Bot", capabilities: Set(CapabilityV2.allCases)), lifetime: 3600)
        let replies = DeliveryLog()
        let session = ControlSession(peerUID: geteuid(), handler: handler, reply: { replies.deliver($0) })
        _ = await session.receive(request(1, "auth.authenticate", ["protocolVersion": .number(2), "token": .string(token)]))
        let params: [String: JSONValue] = [
            "id": .string(domain.sessionA.uuidString), "command": .string("make"), "wait": .object(["until": .string("finished"), "timeoutMs": .number(5_000)])
        ]
        let deferred = await session.receive(request(7, "session.execute", params)).output
        XCTAssertTrue(deferred.isEmpty, "Answered later")
        let info = try responses(await session.receive(request(8, "system.info")).output)
        XCTAssertNotNil(info.last?["result"], "Later frames are served while it waits")
        domainV2.release()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while replies.messages.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(replies.messages.first?["id"] as? Int, 7)
        let plain = try responses(await session.receive(request(9, "session.execute", ["id": .string(domain.sessionA.uuidString), "command": .string("ls")])).output)
        XCTAssertEqual(plain.last?["id"] as? Int, 9, "Without wait: answered in order")
        _ = await session.receive(request(10, "session.execute", params.merging(["wait": .object(["until": .string("started")])]) { $1 }))
        while !replies.messages.contains(where: { $0["id"] as? Int == 10 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let bad = replies.messages.first { $0["id"] as? Int == 10 }
        XCTAssertEqual((bad?["error"] as? [String: Any])?["code"] as? Int, -32602, "until is finished only")
        await session.connectionClosed()
    }

    // MARK: Projections

    private func grant(_ capabilities: Set<CapabilityV2>, hosts: HostScope = .all) async throws -> AutomationGrant {
        try await store.create(GrantSettings(name: "Bot", capabilities: capabilities, scope: GrantScope(hosts: hosts)), lifetime: 3600).grant
    }

    private func object(_ value: JSONValue?) -> [String: JSONValue] { if case .object(let object)? = value { object } else { [:] } }
    private func array(_ value: JSONValue?) -> [JSONValue] { if case .array(let items)? = value { items } else { [] } }

    private let definition = ProjectDefinition(
        name: "Shop", notes: "Checkout", repository: ProjectRepository(url: "git@github.com:acme/shop.git"),
        tabs: [
            ProjectTab(
                title: "API", color: .green, directory: "api", repository: ProjectRepository(url: "https://github.com/acme/api.git", branch: "main"),
                root: .split(axis: .x, ratio: 0.6, first: .pane(ProjectPane(title: "Server", command: "make dev")), second: .pane(ProjectPane(agent: "trellis-codex"))))
        ], lastFolders: ["local": "/Users/me/shop"], revision: 4)

    func testProjectAndPlanRedactWhatRunsWithoutSessionExecute() async throws {
        var snapshot = await domain.snapshot()
        snapshot.spaces[0].projectID = definition.id
        let full = ProjectionV2(snapshot: snapshot, runtime: RuntimeV2(), hosts: [:], grant: try await grant([.projectRead, .sessionExecute]))
        let reader = ProjectionV2(snapshot: snapshot, runtime: RuntimeV2(), hosts: [:], grant: try await grant([.projectRead]))

        let shown = object(full.project(definition))
        XCTAssertEqual(shown["repository"], .object(["url": .string("git@github.com:acme/shop.git")]))
        XCTAssertEqual(shown["revision"], .number(4))
        XCTAssertEqual(array(shown["spaces"]), [.string(domain.spaceA.uuidString.lowercased())])
        XCTAssertEqual(array(shown["lastFolders"]), [.object(["target": .object(["kind": .string("local")]), "folder": .string("/Users/me/shop")])])
        let tab = object(array(shown["tabs"]).first)
        XCTAssertEqual(tab["key"], .string("t1"))
        XCTAssertEqual(tab["directory"], .string("api"))
        let panes = array(object(tab["layout"])["children"]).map(object)
        XCTAssertEqual(panes[0]["key"], .string("t1-1"))
        XCTAssertEqual(panes[0]["command"], .string("make dev"))
        XCTAssertEqual(panes[1]["agent"], .string("trellis-codex"))

        let hidden = object(reader.project(definition))
        XCTAssertNil(hidden["repository"])
        XCTAssertNil(hidden["lastFolders"])
        let hiddenTab = object(array(hidden["tabs"]).first)
        XCTAssertNil(hiddenTab["directory"])
        XCTAssertNil(hiddenTab["repository"])
        let hiddenPanes = array(object(hiddenTab["layout"])["children"]).map(object)
        XCTAssertNil(hiddenPanes[0]["command"], "Commands need session.execute")
        XCTAssertEqual(hiddenPanes[0]["title"], .string("Server"))
        XCTAssertEqual(hiddenPanes[1]["agent"], .string("trellis-codex"), "Which agent runs is readable")

        var launch = try XCTUnwrap(ProjectLaunch.resolve(definition, target: .local, folder: "/Users/me/shop", home: "/Users/me"))
        launch.check(exists: { $0 == "/Users/me/shop/.git" }, isDirectory: { $0 == "/Users/me/shop" })
        let plan = object(full.plan(launch))
        XCTAssertEqual(plan["revision"], .number(4))
        XCTAssertEqual(plan["needsSetup"], .bool(true))
        XCTAssertEqual(plan["folderExists"], .bool(true))
        XCTAssertEqual(plan["folder"], .string("/Users/me/shop"))
        XCTAssertEqual(array(plan["checkouts"]).map { object($0)["state"] }, [.string("present"), .string("clone")])
        XCTAssertEqual(object(array(plan["checkouts"])[1])["folder"], .string("api"))
        XCTAssertEqual(array(plan["commands"]), [.object(["paneKey": .string("t1-1"), "command": .string("make dev")])])
        XCTAssertEqual(array(plan["agents"]), [.object(["paneKey": .string("t1-2"), "agentId": .string("trellis-codex")])])
        let redacted = object(reader.plan(launch))
        XCTAssertNil(redacted["folder"])
        XCTAssertNil(object(array(redacted["checkouts"])[1])["folder"])
        XCTAssertNil(object(array(redacted["checkouts"])[1])["repository"])
        XCTAssertEqual(array(redacted["commands"]), [.object(["paneKey": .string("t1-1")])], "Which pane runs a command, not what")
    }

    func testASpacesProjectFieldsFollowProjectReadAndSessionExecute() async throws {
        var snapshot = await domain.snapshot()
        snapshot.spaces[0].projectID = definition.id
        snapshot.spaces[1].projectID = definition.id
        snapshot.spaces[1].remoteHostID = host.id
        var runtime = RuntimeV2()
        for space in snapshot.spaces.prefix(2) {
            var live = SpaceRuntimeV2()
            live.projectName = "Shop"; live.projectFolder = space.remoteHostID == nil ? "/Users/me/shop" : "code/shop"
            runtime.spaces[space.id] = live
        }
        func project(_ capabilities: Set<CapabilityV2>, space: Int, hosts: HostScope = .all) async throws -> [String: JSONValue] {
            let projection = ProjectionV2(snapshot: snapshot, runtime: runtime, hosts: [host.id: host], grant: try await grant(capabilities, hosts: hosts))
            return object(object(projection.space(snapshot.spaces[space]))["project"])
        }
        let id = JSONValue.string(definition.id.uuidString.lowercased())
        let plain = try await project([.workspaceRead], space: 0)
        XCTAssertEqual(plain, ["id": id])
        let named = try await project([.workspaceRead, .projectRead], space: 0)
        XCTAssertEqual(named, ["id": id, "name": .string("Shop"), "target": .object(["kind": .string("local")])])
        let full = try await project([.workspaceRead, .projectRead, .sessionExecute], space: 0)
        XCTAssertEqual(full, ["id": id, "name": .string("Shop"), "target": .object(["kind": .string("local")]), "folder": .string("/Users/me/shop")])
        let remote = try await project([.workspaceRead, .projectRead, .sessionExecute, .hostRead], space: 1)
        XCTAssertEqual(remote["target"], .object(["kind": .string("host"), "hostId": .string(host.id.uuidString.lowercased())]))
        XCTAssertEqual(remote["folder"], .string("code/shop"))
        let unapproved = try await project([.workspaceRead, .projectRead, .hostRead], space: 1, hosts: .approved([]))
        XCTAssertEqual(unapproved["target"], .object(["kind": .string("host")]))
    }

    func testTasksAndRunsRedactCommandsWithoutSessionExecute() async throws {
        let entry = TaskEntryV2(id: "file:build", task: LaunchTask(name: "build", command: "swift build", cwd: "app", group: .build), source: .file, trusted: false, environment: ["CI"])
        let snapshot = await domain.snapshot()
        let full = ProjectionV2(snapshot: snapshot, runtime: RuntimeV2(), hosts: [:], grant: try await grant([.taskRead, .sessionExecute]))
        let reader = ProjectionV2(snapshot: snapshot, runtime: RuntimeV2(), hosts: [:], grant: try await grant([.taskRead]))
        XCTAssertEqual(
            full.task(entry),
            .object([
                "id": .string("file:build"), "name": .string("build"), "source": .string("file"), "group": .string("build"), "trusted": .bool(false),
                "command": .string("swift build"), "cwd": .string("app"), "env": .array([.string("CI")])
            ]))
        XCTAssertEqual(
            reader.task(entry), .object(["id": .string("file:build"), "name": .string("build"), "source": .string("file"), "group": .string("build"), "trusted": .bool(false)]))
        let pane = domain.paneA
        var run = TaskRun(taskID: "detected:swift: build", name: "swift: build", at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(object(full.taskRun(run, paneID: pane))["phase"], .string("submitted"))
        _ = run.apply(.commandStart(commandLine: "swift build"), now: Date(timeIntervalSince1970: 1_800_000_001))
        _ = run.apply(.commandFinished(exitCode: 2), now: Date(timeIntervalSince1970: 1_800_000_003.5))
        XCTAssertEqual(
            full.taskRun(run, paneID: pane),
            .object([
                "paneId": .string(pane.uuidString.lowercased()), "taskId": .string("detected:swift: build"), "name": .string("swift: build"), "phase": .string("finished"),
                "exitCode": .number(2), "durationMs": .number(2_500), "stopRequested": .bool(false)
            ]))
    }
}
