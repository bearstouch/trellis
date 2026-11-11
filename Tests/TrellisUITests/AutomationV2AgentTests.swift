import AppKit
import XCTest
import TrellisControl
import TrellisCore
@testable import TrellisUI

/// Protocol 2 agents over the real model (API2-05, methods.md#agents): `agent.*` drive the same panes, launches, installer
/// and input path as the app. The login shell is a stand-in that runs its `-c` line with /bin/sh; the agent is a script
/// that prints each byte it reads as `[hex]`, so the exact keys `agent.respond` sends are visible in the pane.
@MainActor
final class AutomationV2AgentTests: XCTestCase {
    private var scratch: URL!
    private var project = "", work = "", shell = "", echoAgent = "", installed = ""

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-v2ag-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let manager = FileManager.default
        for folder in ["bin", "project", "work"] { try manager.createDirectory(at: scratch.appendingPathComponent(folder), withIntermediateDirectories: true) }
        project = scratch.appendingPathComponent("project").path
        work = scratch.appendingPathComponent("work").path
        shell = scratch.appendingPathComponent("bin/sh").path
        try "#!/bin/sh\nprintf 'SHELL-UP\\n'\n[ \"$2\" = -c ] && exec /bin/sh -c \"$3\"\nexec /bin/cat\n".write(toFile: shell, atomically: true, encoding: .utf8)
        echoAgent = scratch.appendingPathComponent("bin/echo-agent").path
        try """
        #!/bin/sh
        printf 'FAKE-AGENT-UP %s %s\\n' "$PWD" "$*"
        stty raw -echo
        while :; do
          b=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \\n')
          [ -n "$b" ] || exit 0
          printf '[%s]' "$b"
        done
        """.write(toFile: echoAgent, atomically: true, encoding: .utf8)
        for file in [shell, echoAgent] { try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file) }
        // Created only by the installer below.
        installed = scratch.appendingPathComponent("bin/installed-agent").path
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    private var echo: AgentDefinition {
        AgentDefinition(
            id: "echo", name: "Echo", executable: echoAgent, resumeArguments: ["--continue"], integration: .none, icon: .monogram("E"),
            install: ["darwin": AgentInstallRecipe(command: "true")])
    }
    /// Missing until its installer copies the echo agent into place.
    private var installable: AgentDefinition {
        AgentDefinition(
            id: "installable", name: "Installable", executable: installed,
            install: ["darwin": AgentInstallRecipe(command: "printf 'INSTALLER-RAN\\n'; cp \(AgentCommand.quote(echoAgent)) \(AgentCommand.quote(installed))")])
    }
    private var manual: AgentDefinition { AgentDefinition(id: "manual", name: "Manual", executable: scratch.appendingPathComponent("bin/manual").path) }

    private static let everything = GrantSettings(name: "", capabilities: Set(CapabilityV2.allCases))

    /// A v2 client with every capability, the fake shell, the agents, and one space with a stopped pane.
    private func makeHarness(_ v: HarnessV2? = nil) async throws -> (HarnessV2, space: String, pane: String) {
        let v = try v ?? HarnessV2()
        v.model.workspaceIsFrontmost = { true }
        let saved = await v.model.saveLaunchSettings(shell: shell, directory: project)
        XCTAssertTrue(saved)
        v.model.agentCatalog = AgentCatalogSnapshot(definitions: [echo, installable, manual])
        try await v.grant("full", settings: Self.everything)
        let created = try await v.ok("space.create", ["name": "Agents"])
        let space = try XCTUnwrap(object(created, "space")["id"] as? String)
        let pane = try XCTUnwrap((created["panes"] as? [[String: Any]])?.first?["id"] as? String)
        return (v, space, pane)
    }

    private func text(_ v: HarnessV2, _ pane: String) -> String {
        guard let id = UUID(uuidString: pane) else { return "" }
        return (try? v.model.terminals[id]?.adapter.read(.retainedText)) ?? ""
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out: \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func paneID(_ value: String) throws -> UUID { try XCTUnwrap(UUID(uuidString: value)) }

    // MARK: Start, runs, respond, restart

    func testStartRespondAndRestartDriveTheRealAgentPane() async throws {
        let (v, space, source) = try await makeHarness()
        defer { v.cleanUp() }
        let tabsBefore = v.model.snapshot.tabs.count

        // agent.start in a new tab: the run, its pane and the tab; the agent inherits the space's folder.
        let started = try await v.ok("agent.start", ["agentId": "echo", "placement": ["kind": "tab", "spaceId": space]])
        let run = object(started, "run"), pane = object(started, "pane")
        let agentPane = try XCTUnwrap(pane["id"] as? String)
        let session = try XCTUnwrap(run["sessionId"] as? String)
        XCTAssertEqual(run["agentId"] as? String, "echo")
        XCTAssertEqual(run["origin"] as? String, "managed")
        XCTAssertEqual(run["state"] as? String, "ready")
        XCTAssertEqual(run["paneId"] as? String, agentPane)
        XCTAssertNotNil(run["since"] as? String)
        XCTAssertEqual(object(started, "tab")["paneIds"] as? [String], [agentPane])
        XCTAssertEqual(object(started, "session")["launch"].map { ($0 as? [String: Any])?["agentId"] as? String }, "echo")
        XCTAssertEqual(v.model.snapshot.tabs.count, tabsBefore + 1)
        XCTAssertEqual(v.model.agentLaunch(paneID: try paneID(agentPane))?.agentID, "echo")
        try await waitFor("the agent runs") { self.text(v, agentPane).contains("FAKE-AGENT-UP") }
        XCTAssertTrue(text(v, agentPane).contains("/project "), "It starts in the space's folder: \(text(v, agentPane))")

        // Runs: listed in workspace.get and agent.runs, filtered by state.
        let workspace = try await v.ok("workspace.get", ["include": ["agents"]])
        XCTAssertEqual((workspace["agentRuns"] as? [[String: Any]])?.compactMap { $0["sessionId"] as? String }, [session])
        let waiting = try await v.ok("agent.runs", ["state": "needsInput"])
        XCTAssertEqual((waiting["runs"] as? [Any])?.count, 0)
        let id = try XCTUnwrap(UUID(uuidString: session))
        v.model.receiveAgentEvent(sessionID: id, event: "needs-input")
        let needs = try await v.ok("agent.runs", ["spaceId": space, "state": "needsInput"])
        XCTAssertEqual((needs["runs"] as? [[String: Any]])?.first?["sessionId"] as? String, session)
        let paneRead = try await v.ok("pane.get", ["id": agentPane])
        XCTAssertEqual(object(paneRead, "pane")["agent"] as? [String: String], ["agentId": "echo", "state": "needsInput"])

        // agent.respond: approve is exactly `1` + Return; the answer moves an agent without hooks to working.
        let approved = try await v.ok("agent.respond", ["sessionId": session, "action": "approve"])
        XCTAssertEqual(approved["acceptedBytes"] as? Int, 2)
        XCTAssertEqual(object(approved, "run")["state"] as? String, "working")
        try await waitFor("the approval arrives") { self.text(v, agentPane).contains("[31][0d]") }
        // Stale: the run moved on, so nothing is sent.
        let stale = try await v.call("agent.respond", ["sessionId": session, "action": "approve"])
        XCTAssertEqual(errorCode(stale), "INVALID_STATE")
        XCTAssertEqual(details(stale)?["state"] as? String, "working")
        // expectedState answers another state on purpose; reject is exactly Escape.
        _ = try await v.ok("agent.respond", ["sessionId": session, "action": "reject", "expectedState": "working"])
        try await waitFor("the rejection arrives") { self.text(v, agentPane).contains("[31][0d][1b]") }
        v.model.receiveAgentEvent(sessionID: id, event: "needs-input")
        _ = try await v.ok("agent.respond", ["sessionId": session, "action": "reply", "text": "yes é"])
        try await waitFor("the reply arrives") { self.text(v, agentPane).contains("[31][0d][1b][79][65][73][20][c3][a9][0d]") }
        v.model.receiveAgentEvent(sessionID: id, event: "needs-input")
        let screen = text(v, agentPane)
        for bad: [String: Any] in [
            ["action": "reply", "text": "yes\rno"], ["action": "reply", "text": "\u{1b}[A"], ["action": "reply"], ["action": "approve", "text": "1"]
        ] {
            let refused = try await v.call("agent.respond", bad.merging(["sessionId": session]) { $1 })
            XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? Int, -32602, "\(bad)")
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(text(v, agentPane), screen, "Refused answers send nothing")

        // agent.restart refuses a running agent, then restarts a finished one with a new session and resume.
        let running = try await v.call("agent.restart", ["sessionId": session])
        XCTAssertEqual(errorCode(running), "INVALID_STATE")
        XCTAssertEqual(details(running)?["state"] as? String, "running")
        v.model.terminals[try paneID(agentPane)]?.requestTermination(force: true)
        let agentPaneID = try paneID(agentPane)
        try await waitFor("the agent exits") { [.exited, .failed].contains(v.model.terminals[agentPaneID]?.sessionState) }
        await v.model.waitForUpdates()
        let finished = try await v.ok("agent.runs")
        XCTAssertEqual((finished["runs"] as? [Any])?.count, 0, "A finished agent has no run")
        let restarted = try await v.ok("agent.restart", ["sessionId": session, "resume": true])
        let newSession = try XCTUnwrap(object(restarted, "run")["sessionId"] as? String)
        XCTAssertNotEqual(newSession, session)
        XCTAssertEqual(object(restarted, "pane")["id"] as? String, agentPane, "The same pane")
        try await waitFor("resume passes the resume arguments") { self.text(v, agentPane).contains("--continue") }
        let gone = try await v.code("agent.restart", ["sessionId": session])
        XCTAssertEqual(gone, "NOT_FOUND", "The old session is no longer the pane's")

        // Placement split: beside the source pane, in a chosen folder (needs session.execute).
        let split = try await v.ok("agent.start", ["agentId": "echo", "placement": ["kind": "split", "paneId": source, "axis": "y"], "directory": work])
        let splitPane = try XCTUnwrap(object(split, "pane")["id"] as? String)
        XCTAssertEqual(object(split, "tab")["paneIds"] as? [String], [source, splitPane])
        try await waitFor("the split agent runs in the chosen folder") { self.text(v, splitPane).contains("/work ") }
        let missingFolder = try await v.call("agent.start", ["agentId": "echo", "placement": ["kind": "tab", "spaceId": space], "directory": work + "/nope"])
        XCTAssertEqual((missingFolder["error"] as? [String: Any])?["code"] as? Int, -32602)

        // Placement pane: only a pane that isn't running; the source pane (stopped) takes the agent.
        let busy = try await v.call("agent.start", ["agentId": "echo", "placement": ["kind": "pane", "paneId": splitPane]])
        XCTAssertEqual(errorCode(busy), "INVALID_STATE")
        XCTAssertEqual(details(busy)?["state"] as? String, "running")
        let inPlace = try await v.ok("agent.start", ["agentId": "echo", "placement": ["kind": "pane", "paneId": source]])
        XCTAssertEqual(object(inPlace, "pane")["id"] as? String, source)
        XCTAssertNil(inPlace["tab"])
        try await waitFor("the agent runs in the pane") { self.text(v, source).contains("FAKE-AGENT-UP") }
    }

    // MARK: Permissions, scope, revisions

    func testAgentMethodsFollowCapabilitiesScopesAndRevisions() async throws {
        let (v, space, pane) = try await makeHarness()
        defer { v.cleanUp() }
        let tab: [String: Any] = ["agentId": "echo", "placement": ["kind": "tab", "spaceId": space]]
        let committed = v.model.snapshot

        var noControl = Self.everything
        noControl.capabilities.remove(.agentControl)
        try await v.grant("noControl", settings: noControl)
        let denied = try await v.call("agent.start", tab, as: "noControl")
        XCTAssertEqual(errorCode(denied), "PERMISSION_DENIED")
        XCTAssertEqual(details(denied)?["missing"] as? [String], ["agent.control"])

        var noExecute = Self.everything
        noExecute.capabilities.remove(.sessionExecute)
        try await v.grant("noExecute", settings: noExecute)
        let folder = try await v.call("agent.start", tab.merging(["directory": work]) { $1 }, as: "noExecute")
        XCTAssertEqual(details(folder)?["missing"] as? [String], ["session.execute"])
        let install = try await v.call("agent.install", ["agentId": "installable", "placement": ["kind": "tab", "spaceId": space]], as: "noExecute")
        XCTAssertEqual(details(install)?["missing"] as? [String], ["session.execute"])
        // Definitions stay readable without session.execute, minus what runs.
        let plain = try await v.ok("agent.get", ["id": "echo"], as: "noExecute")
        XCTAssertNil(object(plain, "agent")["executable"])
        XCTAssertNil(object(plain, "agent")["install"])
        let full = object(try await v.ok("agent.get", ["id": "echo"]), "agent")
        XCTAssertEqual(full["executable"] as? String, echoAgent)
        XCTAssertEqual(full["builtIn"] as? Bool, false)
        XCTAssertEqual((full["availability"] as? [[String: Any]])?.first?["status"] as? String, "unknown")
        let outcome1 = try await v.code("agent.get", ["id": "nope"])
        XCTAssertEqual(outcome1, "NOT_FOUND")
        let listed = try await v.ok("agent.list", ["limit": 2])
        XCTAssertEqual((listed["agents"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["echo", "installable"])
        XCTAssertNotNil(listed["nextCursor"])

        // Agent scope: another agent looks missing for starting and restarting; its runs stay readable.
        var otherAgents = Self.everything
        otherAgents.scope.agents = .agents(["installable"])
        try await v.grant("otherAgents", settings: otherAgents)
        let outcome2 = try await v.code("agent.start", tab, as: "otherAgents")
        XCTAssertEqual(outcome2, "NOT_FOUND")
        // Space scope: a space outside it is NOT_FOUND.
        var otherSpaces = Self.everything
        otherSpaces.scope.spaces = .spaces([UUID()])
        try await v.grant("otherSpaces", settings: otherSpaces)
        let outcome3 = try await v.code("agent.start", tab, as: "otherSpaces")
        XCTAssertEqual(outcome3, "NOT_FOUND")
        XCTAssertEqual(v.model.snapshot, committed, "Refusals change nothing")

        // expectedRevision on a new tab is the space's: a stale one is CONFLICT and leaves no tab behind.
        let spaceRead = try await v.ok("space.get", ["id": space])
        let revision = try XCTUnwrap(object(spaceRead, "space")["revision"] as? Int)
        let conflict = try await v.call("agent.start", tab.merging(["expectedRevision": revision + 1]) { $1 })
        XCTAssertEqual(errorCode(conflict), "CONFLICT")
        XCTAssertEqual(v.model.snapshot, committed)
        let started = try await v.ok("agent.start", tab.merging(["expectedRevision": revision, "idempotencyKey": "start-1"]) { $1 })
        let session = try XCTUnwrap(object(started, "run")["sessionId"] as? String)
        let replay = try await v.ok("agent.start", tab.merging(["expectedRevision": revision, "idempotencyKey": "start-1"]) { $1 })
        XCTAssertEqual(object(replay, "run")["sessionId"] as? String, session, "A retry replays instead of starting twice")

        let runs = try await v.ok("agent.runs", as: "otherAgents")
        XCTAssertEqual((runs["runs"] as? [[String: Any]])?.first?["agentId"] as? String, "echo", "Runs of agents outside scope stay readable")
        let id = try XCTUnwrap(UUID(uuidString: session))
        let agentPane = try XCTUnwrap(object(started, "pane")["id"] as? String)
        try await waitFor("the agent runs") { self.text(v, agentPane).contains("FAKE-AGENT-UP") }
        v.model.terminals[try paneID(agentPane)]?.requestTermination(force: true)
        let agentPaneID = try paneID(agentPane)
        try await waitFor("the agent exits") { [.exited, .failed].contains(v.model.terminals[agentPaneID]?.sessionState) }
        let outcome4 = try await v.code("agent.restart", ["sessionId": session], as: "otherAgents")
        XCTAssertEqual(outcome4, "NOT_FOUND")
        let outcome5 = try await v.code("agent.restart", ["sessionId": session], as: "otherSpaces")
        XCTAssertEqual(outcome5, "NOT_FOUND")
        XCTAssertEqual(v.model.snapshot.panes[try paneID(agentPane)]?.sessionID, id, "Nothing restarted")

        // agent.respond needs agent.respond or session.input (the first real anyOf); either alone is enough.
        _ = try await v.ok("agent.restart", ["sessionId": session])
        try await waitFor("the agent runs again") { v.model.agentStates[agentPaneID] != nil }
        let current = try XCTUnwrap(v.model.snapshot.panes[try paneID(agentPane)]?.sessionID)
        var neither = Self.everything
        neither.capabilities.subtract([.agentRespond, .sessionInput])
        try await v.grant("neither", settings: neither)
        let answer: [String: Any] = ["sessionId": current.uuidString, "action": "reject", "expectedState": "ready"]
        let refused = try await v.call("agent.respond", answer, as: "neither")
        XCTAssertEqual(errorCode(refused), "PERMISSION_DENIED")
        XCTAssertEqual(details(refused)?["missing"] as? [String], ["agent.respond"])
        try await v.grant("inputOnly", settings: GrantSettings(name: "", capabilities: [.sessionInput]))
        _ = try await v.ok("agent.respond", answer, as: "inputOnly")
        try await v.grant("respondOnly", settings: GrantSettings(name: "", capabilities: [.agentRespond]))
        _ = try await v.ok("agent.respond", answer, as: "respondOnly")
        try await waitFor("both rejections arrive") { self.text(v, agentPane).contains("[1b][1b]") }
        // A session that runs no agent has nothing to answer.
        let shell = try await v.call("agent.respond", ["sessionId": try XCTUnwrap(v.model.snapshot.panes[try paneID(pane)]?.sessionID.uuidString), "action": "approve"])
        XCTAssertEqual(details(shell)?["state"] as? String, "noAgent")
    }

    // MARK: Availability and install

    func testAMissingAgentIsUnavailableAndInstallRunsItsInstallerThenTheAgent() async throws {
        let (v, space, _) = try await makeHarness()
        defer { v.cleanUp() }
        let committed = v.model.snapshot
        let tab: [String: Any] = ["kind": "tab", "spaceId": space]

        // Known missing on this Mac (a PATH check or a launch said so): AGENT_UNAVAILABLE, and nothing is created.
        v.model.agentAvailability["installable"] = .missing
        v.model.agentAvailability["manual"] = .missing
        let missing = try await v.call("agent.start", ["agentId": "installable", "placement": tab])
        XCTAssertEqual(errorCode(missing), "AGENT_UNAVAILABLE")
        XCTAssertEqual(details(missing)?["install"] as? Bool, true)
        XCTAssertEqual(details(missing)?["machine"] as? [String: String], ["kind": "local"])
        let manual = try await v.call("agent.start", ["agentId": "manual", "placement": tab])
        XCTAssertEqual(details(manual)?["install"] as? Bool, false, "No installer for this Mac")
        let outcome6 = try await v.code("agent.install", ["agentId": "manual", "placement": tab])
        XCTAssertEqual(outcome6, "AGENT_UNAVAILABLE")
        XCTAssertEqual(v.model.snapshot, committed)
        let listed = try await v.ok("agent.get", ["id": "installable"])
        let local = try XCTUnwrap((object(listed, "agent")["availability"] as? [[String: Any]])?.first)
        XCTAssertEqual(local["status"] as? String, "missing")
        XCTAssertEqual(local["installable"] as? Bool, true)

        // An installer whose requirements this Mac's login PATH lacks can't run; the names need session.execute to read.
        v.model.agentCatalog = AgentCatalogSnapshot(
            definitions: v.model.agentCatalog.definitions + [
                AgentDefinition(id: "needs-npm", name: "Needs npm", executable: installed + "-npm", install: ["darwin": AgentInstallRecipe(command: "npm i -g x", requires: ["npm"])])
            ])
        v.model.agentLoginPath = [scratch.appendingPathComponent("bin").path]
        let npm = try await v.call("agent.install", ["agentId": "needs-npm", "placement": tab])
        XCTAssertEqual(errorCode(npm), "AGENT_UNAVAILABLE")
        XCTAssertEqual(details(npm)?["install"] as? Bool, false)
        XCTAssertEqual(details(npm)?["requires"] as? [String], ["npm"])
        v.model.agentLoginPath = nil
        XCTAssertEqual(v.model.snapshot, committed)

        // agent.install: the installer runs in a visible pane, then the agent, as Install and Launch does.
        let result = try await v.ok("agent.install", ["agentId": "installable", "placement": tab])
        let pane = try XCTUnwrap(object(result, "pane")["id"] as? String)
        XCTAssertEqual(object(result, "session")["launch"].map { ($0 as? [String: Any])?["agentId"] as? String }, "installable")
        try await waitFor("the installer then the agent run") { self.text(v, pane).contains("INSTALLER-RAN") && self.text(v, pane).contains("FAKE-AGENT-UP") }
        XCTAssertNil(v.model.agentAvailability["installable"], "The missing mark is gone; the next PATH check decides")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed))
        XCTAssertNil(v.model.agentInstallOffer)
        XCTAssertFalse(v.model.agentInstallPanes.contains(try paneID(pane)), "The installer runs once")

        // An agent not known to be missing starts; exit 127 then marks it missing, as in the app (FR-AG12).
        v.model.agentAvailability.removeValue(forKey: "manual")
        let tried = try await v.ok("agent.start", ["agentId": "manual", "placement": tab])
        XCTAssertNotNil(tried["session"])
        try await waitFor("the launch finds it missing") { v.model.agentAvailability["manual"] == .missing }
        let again = try await v.call("agent.start", ["agentId": "manual", "placement": tab])
        XCTAssertEqual(errorCode(again), "AGENT_UNAVAILABLE")
        v.model.agentInstallOffer = nil
    }

    // MARK: Typed agents and remote workspaces

    func testATypedAgentIsADetectedRunThatCanBeAnsweredButNotRestarted() async throws {
        let (v, _, pane) = try await makeHarness()
        defer { v.cleanUp() }
        let id = try paneID(pane)
        _ = try await v.ok("session.start", ["paneId": pane, "launch": ["kind": "process", "executable": "/bin/sleep", "arguments": ["30"], "directory": "/tmp"]])
        let terminal = try XCTUnwrap(v.model.terminals[id])
        try await waitFor("the shell runs") { terminal.sessionState == .running }
        terminal.onShellIntegrationEvent?(.promptStart(directory: project))
        terminal.onShellIntegrationEvent?(.commandStart(commandLine: "echo-agent --flag"))
        v.model.receiveAgentEvent(sessionID: terminal.sessionID, event: "needs-input")
        let runs = try await v.ok("agent.runs")
        let run = try XCTUnwrap((runs["runs"] as? [[String: Any]])?.first)
        XCTAssertEqual(run["origin"] as? String, "detected")
        XCTAssertEqual(run["state"] as? String, "needsInput")
        let restart = try await v.call("agent.restart", ["sessionId": terminal.sessionID.uuidString])
        XCTAssertEqual(errorCode(restart), "INVALID_STATE")
        XCTAssertEqual(details(restart)?["state"] as? String, "detected")
        XCTAssertEqual(terminal.sessionState, .running, "Nothing was restarted")
        _ = try await v.ok("agent.respond", ["sessionId": terminal.sessionID.uuidString, "action": "reject"])
    }

    /// A remote workspace runs agents on its host: the host must be in scope, a known-missing agent is AGENT_UNAVAILABLE with
    /// the host's installer, and an answer is never queued while the link is down (FR-RW15).
    func testRemoteWorkspaceAgentsNeedTheHostAndAConnectedLink() async throws {
        let (v, _, _) = try await makeHarness()
        defer { v.cleanUp() }
        guard case .success(let host) = await v.base.hosts.save(HostDraft(name: "build-box", destination: "build-box"), editing: nil) else { return XCTFail("No host") }
        let created = try await v.model.service.execute(.createRemoteSpace(name: "Remote", hostID: host.id))
        v.model.publish(created.snapshot)
        let space = try XCTUnwrap(created.snapshot.spaces.first { $0.id == created.createdSpaceID })
        let pane = try XCTUnwrap(created.snapshot.tabs[space.activeTabID].flatMap { created.snapshot.panes[$0.activePaneID] })
        let tab: [String: Any] = ["agentId": "echo", "placement": ["kind": "tab", "spaceId": space.id.uuidString]]

        var noHosts = Self.everything
        noHosts.scope.hosts = .approved([])
        try await v.grant("noHosts", settings: noHosts)
        let outcome7 = try await v.code("agent.start", tab, as: "noHosts")
        XCTAssertEqual(outcome7, "PERMISSION_DENIED")
        v.model.remoteMissingAgents[host.id] = ["echo"]
        let missing = try await v.call("agent.start", tab)
        XCTAssertEqual(errorCode(missing), "AGENT_UNAVAILABLE")
        XCTAssertEqual(details(missing)?["machine"] as? [String: String], ["kind": "remote", "hostId": host.id.uuidString.lowercased()])
        XCTAssertEqual(details(missing)?["install"] as? Bool, false, "echo has no Linux installer")
        let listed = object(try await v.ok("agent.get", ["id": "echo"]), "agent")
        let remote = try XCTUnwrap((listed["availability"] as? [[String: Any]])?.last)
        XCTAssertEqual(remote["machine"] as? [String: String], ["kind": "remote", "hostId": host.id.uuidString.lowercased()])
        XCTAssertEqual(remote["status"] as? String, "missing")
        let onlyHost = try await v.ok("agent.list", ["machine": ["kind": "remote", "hostId": host.id.uuidString]])
        XCTAssertEqual(((onlyHost["agents"] as? [[String: Any]])?.first?["availability"] as? [Any])?.count, 1)
        let outcome8 = try await v.code("agent.list", ["machine": ["kind": "remote", "hostId": host.id.uuidString]], as: "noHosts")
        XCTAssertEqual(outcome8, "NOT_FOUND")
        let hidden = object(try await v.ok("agent.get", ["id": "echo"], as: "noHosts"), "agent")
        XCTAssertEqual((hidden["availability"] as? [Any])?.count, 1, "Only this Mac without the host in scope")

        // An install whose launch fails before its command is built (no link here) leaves no installer mark behind, so a
        // later start of that pane, perhaps by a grant without agent.install, never runs the installer.
        v.model.agentCatalog = AgentCatalogSnapshot(
            definitions: v.model.agentCatalog.definitions + [
                AgentDefinition(id: "linux-only", name: "Linux only", executable: "linux-only", install: ["linux": AgentInstallRecipe(command: "true")])
            ])
        let failed = try await v.call("agent.install", ["agentId": "linux-only", "placement": ["kind": "tab", "spaceId": space.id.uuidString]])
        XCTAssertEqual(errorCode(failed), "LAUNCH_FAILED")
        XCTAssertTrue(v.model.agentInstallPanes.isEmpty, "No stale installer mark")

        // An agent pane running on the host while its link is down: the answer is refused, never queued.
        _ = try await v.model.service.execute(.configureStoppedSession(paneID: pane.id, launch: .agent(AgentLaunch(agentID: "echo", directory: nil, hostID: host.id))))
        v.model.publish(try await v.model.service.execute(.adoptRunningSession(sessionID: pane.sessionID, processID: 4242)).snapshot)
        var reducer = AgentStateReducer(integration: .none)
        reducer.apply(.hook(.needsInput))
        v.model.agentStates[pane.id] = reducer
        v.model.remoteLinks[host.id] = .reconnecting(attempt: 1, at: Date())
        let answer: [String: Any] = ["sessionId": pane.sessionID.uuidString, "action": "approve"]
        let outcome9 = try await v.code("agent.respond", answer, as: "noHosts")
        XCTAssertEqual(outcome9, "PERMISSION_DENIED")
        let outcome10 = try await v.code("agent.respond", answer)
        XCTAssertEqual(outcome10, "REMOTE_DISCONNECTED")
        XCTAssertEqual(v.model.agentStates[pane.id]?.state, .needsInput, "Nothing was answered")
    }

    // MARK: Events (API2-07)

    /// API-started agents report through the same sources as the app's: started, state, settings, ended, availability.
    func testAgentsStartedThroughTheAPIEmitAgentEvents() async throws {
        let events = try await EventsHarness()
        defer { events.cleanUp() }
        let (v, space, _) = try await makeHarness(HarnessV2(base: events.base))
        let (grant, _) = try await events.grant()
        let after = await events.sequence
        let since = ContinuousClock.now
        let started = try await v.ok("agent.start", ["agentId": "echo", "placement": ["kind": "tab", "spaceId": space]])
        let session = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(object(started, "run")["sessionId"] as? String)))
        let first = try await events.first("agent.started", grant, after: after, since: since)
        XCTAssertEqual(data(first.event)["agentId"] as? String, "echo")
        v.model.receiveAgentEvent(sessionID: session, event: "needs-input")
        let state = try await events.first("agent.state", grant, after: after, since: since)
        XCTAssertEqual(data(state.event)["state"] as? String, "needsInput")
        v.model.terminals.values.first { $0.sessionID == session }?.requestTermination(force: true)
        let ended = try await events.first("agent.ended", grant, after: after, since: since)
        XCTAssertEqual(data(ended.event)["agentId"] as? String, "echo")

        let tried = try await v.ok("agent.start", ["agentId": "manual", "placement": ["kind": "tab", "spaceId": space]])
        XCTAssertNotNil(tried["session"])
        let availability = try await events.first("agent.availability", grant, after: after, since: since, timeout: .seconds(5))
        XCTAssertEqual((availability.event["resource"] as? [String: Any])?["id"] as? String, "manual")
        XCTAssertEqual(data(availability.event)["status"] as? String, "missing")
        v.model.agentInstallOffer = nil
    }
}
