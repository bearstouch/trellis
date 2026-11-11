import XCTest
import TrellisCore
@testable import TrellisControl

/// API2-04: resource projections over a hand-built workspace and runtime: every machine kind, every launch kind,
/// redaction by capability and host scope, and omission of absent values.
final class ProjectionV2Tests: XCTestCase {
    private let host = SavedHost(
        id: UUID(), draft: try! HostDraft(name: "Build", destination: "build", user: "ci", port: "2222", identityFile: "/Users/me/.ssh/id", tags: "work").validated { _ in true },
        revision: 5, connectionRevision: 2, savedPassword: SavedPasswordPolicy(requiresUserPresence: true))
    private let other = SavedHost(id: UUID(), draft: try! HostDraft(name: "Other", destination: "other").validated { _ in false }, revision: 1)
    private let local = UUID(), remote = UUID(), project = UUID(), gone = UUID()
    private let projectTab = UUID(), temporaryTab = UUID(), remoteTab = UUID(), orphanTab = UUID()
    private let shell = UUID(), login = UUID(), process = UUID(), ssh = UUID(), agent = UUID(), remoteShell = UUID(), remoteAgent = UUID(), branch = UUID(), split = UUID()
    private let started = Date(timeIntervalSince1970: 1_800_000_000.25)

    private func snapshot() -> WorkspaceSnapshot {
        var s = WorkspaceSnapshot()
        s.revision = 40
        s.spaces = [
            Space(id: local, name: "Local", tabIDs: [projectTab, temporaryTab], activeTabID: projectTab, revision: 3, projectID: project),
            Space(id: remote, name: "Remote", tabIDs: [remoteTab], activeTabID: remoteTab, revision: 4, remoteHostID: host.id),
            Space(id: gone, name: "Gone", tabIDs: [orphanTab], activeTabID: orphanTab, revision: 5, projectID: UUID())
        ]
        s.activeSpaceID = local
        s.tabs[projectTab] = WorkspaceTab(
            id: projectTab, spaceID: local, title: "Editor", color: .blue,
            root: .split(id: branch, axis: .x, ratio: 0.5, children: [.pane(shell), .split(id: split, axis: .y, ratio: 0.3, children: [.pane(login), .pane(process)])]), activePaneID: shell,
            revision: 7, projectKey: "t1")
        s.tabs[temporaryTab] = WorkspaceTab(
            id: temporaryTab, spaceID: local, title: WorkspaceTab.defaultTitle, root: .split(id: UUID(), axis: .x, ratio: 0.5, children: [.pane(ssh), .pane(agent)]), activePaneID: ssh,
            revision: 8)
        s.tabs[remoteTab] = WorkspaceTab(
            id: remoteTab, spaceID: remote, title: WorkspaceTab.defaultTitle, root: .split(id: UUID(), axis: .x, ratio: 0.5, children: [.pane(remoteShell), .pane(remoteAgent)]),
            activePaneID: remoteShell, revision: 9)
        s.tabs[orphanTab] = WorkspaceTab(id: orphanTab, spaceID: gone, title: "Old", root: .pane(UUID()), activePaneID: UUID(), revision: 1)
        let launches: [(UUID, UUID, SessionLaunch)] = [
            (shell, projectTab, .shell(directory: "/Users/me/src")), (login, projectTab, .process(executable: "/bin/zsh", arguments: ["-l"], directory: "/tmp")),
            (process, projectTab, .process(executable: "/usr/bin/top", arguments: ["-o", "cpu"], directory: "/var")), (ssh, temporaryTab, .host(host.id)),
            (agent, temporaryTab, .agent(AgentLaunch(agentID: "trellis-claude-code", directory: "/Users/me/src/lotus"))),
            (remoteShell, remoteTab, .remoteShell(hostID: host.id, directory: "/srv/app")),
            (remoteAgent, remoteTab, .agent(AgentLaunch(agentID: "trellis-codex", directory: "/srv", hostID: host.id)))
        ]
        for (pane, tab, launch) in launches {
            let session = UUID()
            s.panes[pane] = WorkspacePane(id: pane, tabID: tab, sessionID: session, title: pane == shell ? "server" : nil)
            var record = WorkspaceSession(id: session, launch: launch, createdAt: started)
            if pane == process { record.state = .exited; record.exitCode = 0; record.startedAt = started; record.endedAt = started.addingTimeInterval(1) }
            if pane == login { record.state = .failed; record.failureMessage = "No such directory" }
            s.sessions[session] = record
        }
        return s
    }

    private func runtime() -> RuntimeV2 {
        var runtime = RuntimeV2()
        var shellState = ShellIntegrationState()
        shellState.apply(.promptStart(directory: "/Users/me/src/app"), at: started)
        shellState.apply(.commandStart(commandLine: "make"), at: started)
        shellState.apply(.commandFinished(exitCode: 2), at: started.addingTimeInterval(5.23))
        var running = PaneRuntimeV2()
        running.revision = 11; running.sessionRevision = 12; running.liveState = .running; running.kept = true; running.folder = "/Users/me/src/app"; running.shell = shellState
        running.needsInput = .password; running.progress = TerminalProgress(state: .indeterminate); running.maximized = true
        runtime.panes[shell] = running
        var agentState = PaneRuntimeV2()
        agentState.agent = AgentSummaryV2(agentID: "trellis-claude-code", state: .needsInput)
        agentState.shell = ShellIntegrationState(origin: .remote)
        runtime.panes[agent] = agentState
        var tab = TabRuntimeV2(title: "Editor")
        tab.busy = true; tab.progress = TerminalProgress(state: .normal, percent: 40); tab.needsInput = .password; tab.agent = .needsInput; tab.maximizedPaneID = shell
        runtime.tabs[projectTab] = tab
        runtime.tabs[temporaryTab] = TabRuntimeV2(title: "claude · lotus")
        var linkDown = TabRuntimeV2(title: "app")
        linkDown.linkDown = true
        runtime.tabs[remoteTab] = linkDown
        var goneSpace = SpaceRuntimeV2()
        goneSpace.projectMissing = true; goneSpace.activity = .exit
        runtime.spaces[gone] = goneSpace
        var remoteSpace = SpaceRuntimeV2()
        remoteSpace.activity = .output
        runtime.spaces[remote] = remoteSpace
        var localSpace = SpaceRuntimeV2()
        localSpace.activity = .output
        runtime.spaces[local] = localSpace
        return runtime
    }

    private func projection(_ capabilities: Set<Capability>, hosts: HostScope = .all, spaces: SpaceScope = .all) -> ProjectionV2 {
        let grant = AutomationGrant(
            id: UUID(), name: "Test", tokenHash: "", capabilities: capabilities, spaceScope: spaces, hostScope: hosts, createdAt: started, expiresAt: started.addingTimeInterval(60))
        return ProjectionV2(snapshot: snapshot(), runtime: runtime(), hosts: [host.id: host, other.id: other], grant: grant)
    }

    private let everything: Set<Capability> = [.metadataRead, .sessionExecute, .hostRead]

    private func object(_ value: JSONValue) -> [String: JSONValue] { if case .object(let object) = value { object } else { [:] } }
    private func pane(_ projection: ProjectionV2, _ id: UUID) -> [String: JSONValue] { object(projection.pane(projection.snapshot.panes[id]!)) }
    private func session(_ projection: ProjectionV2, _ pane: UUID) -> [String: JSONValue] {
        let record = projection.snapshot.panes[pane]!
        return object(projection.session(projection.snapshot.sessions[record.sessionID]!, paneID: pane))
    }

    // MARK: Machine and space

    func testSpacesShowTheirMachineProjectAndAttention() {
        let full = projection(everything)
        let spaces = full.visibleSpaces().map { object(full.space($0)) }
        XCTAssertEqual(spaces[0]["machine"], .object(["kind": .string("local")]))
        XCTAssertEqual(spaces[0]["project"], .object(["id": .string(project.uuidString.lowercased())]), "name, target and folder wait for project.read")
        XCTAssertEqual(spaces[0]["attention"], .object(["needsInput": .number(1)]), "The active space shows no activity dot")
        XCTAssertEqual(spaces[0]["active"], .bool(true))
        XCTAssertEqual(spaces[0]["revision"], .number(3))
        XCTAssertEqual(spaces[1]["machine"], .object(["kind": .string("remote"), "hostId": .string(host.id.uuidString.lowercased())]))
        XCTAssertEqual(spaces[1]["attention"], .object(["activity": .string("output")]))
        XCTAssertEqual(object(spaces[2]["project"] ?? .null)["missing"], .bool(true))
        XCTAssertEqual(spaces[2]["attention"], .object(["activity": .string("exit")]))

        let reader = projection([.metadataRead])
        XCTAssertEqual(object(reader.space(reader.snapshot.spaces[1]))["machine"], .object(["kind": .string("remote")]), "hostId needs host.read")
        let approved = projection(everything, hosts: .approved([HostApproval(hostID: other.id, connectionRevision: 1)]))
        XCTAssertEqual(object(approved.space(approved.snapshot.spaces[1]))["machine"], .object(["kind": .string("remote")]), "…and the host in scope")
        let scoped = projection(everything, spaces: .spaces([remote]))
        XCTAssertEqual(scoped.visibleSpaces().map(\.id), [remote])
        XCTAssertFalse(scoped.canSee(.pane, shell))
    }

    // MARK: Tab

    func testTabsShowRoleTitleStatusAndLayoutOnlyWhenAsked() {
        let full = projection(everything)
        let project = object(full.tab(full.snapshot.tabs[projectTab]!, layout: false))
        XCTAssertEqual(project["role"], .string("project"))
        XCTAssertEqual(project["projectKey"], .string("t1"))
        XCTAssertEqual(project["customTitle"], .bool(true))
        XCTAssertEqual(project["color"], .string("blue"))
        XCTAssertEqual(project["maximizedPaneId"], .string(shell.uuidString.lowercased()))
        XCTAssertEqual(
            project["status"],
            .object([
                "busy": .bool(true), "progress": .object(["state": .string("normal"), "percent": .number(40)]), "needsInput": .string("password"), "agent": .string("needsInput")
            ]))
        XCTAssertNil(project["layout"])
        let temporary = object(full.tab(full.snapshot.tabs[temporaryTab]!, layout: true))
        XCTAssertEqual(temporary["role"], .string("temporary"))
        XCTAssertEqual(temporary["title"], .string("claude · lotus"))
        XCTAssertEqual(temporary["customTitle"], .bool(false))
        XCTAssertNil(temporary["color"])
        XCTAssertNil(temporary["projectKey"])
        XCTAssertEqual(temporary["status"], .object([:]), "Omitted members are false or none")
        XCTAssertEqual(object(temporary["layout"] ?? .null)["type"], .string("split"))
        XCTAssertEqual(object(full.tab(full.snapshot.tabs[remoteTab]!, layout: false))["role"], .string("standard"))
        XCTAssertEqual(object(full.tab(full.snapshot.tabs[remoteTab]!, layout: false))["status"], .object(["linkDown": .bool(true)]))
        XCTAssertEqual(object(full.tab(full.snapshot.tabs[orphanTab]!, layout: false))["role"], .string("standard"), "A deleted project leaves standard tabs")
        XCTAssertEqual(
            full.layout(full.snapshot.tabs[projectTab]!.root),
            .object([
                "type": .string("split"), "id": .string(branch.uuidString.lowercased()), "axis": .string("x"), "ratio": .number(0.5),
                "children": .array([
                    .object(["type": .string("pane"), "id": .string(shell.uuidString.lowercased())]),
                    .object([
                        "type": .string("split"), "id": .string(split.uuidString.lowercased()), "axis": .string("y"), "ratio": .number(0.3),
                        "children": .array([
                            .object(["type": .string("pane"), "id": .string(login.uuidString.lowercased())]), .object(["type": .string("pane"), "id": .string(process.uuidString.lowercased())])
                        ])
                    ])
                ])
            ]))
    }

    // MARK: Pane

    func testPanesShowMachineShellAttentionAndAgent() {
        let full = projection(everything)
        let running = pane(full, shell)
        XCTAssertEqual(running["title"], .string("server"))
        XCTAssertEqual(running["revision"], .number(11))
        XCTAssertEqual(running["focused"], .bool(true))
        XCTAssertEqual(running["maximized"], .bool(true))
        XCTAssertEqual(running["folder"], .string("/Users/me/src/app"))
        XCTAssertEqual(running["machine"], .object(["kind": .string("local")]))
        XCTAssertEqual(
            running["shell"], .object(["integration": .string("authenticated"), "commandRunning": .bool(false), "lastExitCode": .number(2), "lastDurationMs": .number(5230)]),
            "Command text is never exposed")
        XCTAssertEqual(running["attention"], .object(["needsInput": .string("password"), "progress": .object(["state": .string("indeterminate")])]))
        XCTAssertNil(running["agent"])
        XCTAssertEqual(running["spaceId"], .string(local.uuidString.lowercased()))

        XCTAssertEqual(pane(full, process)["folder"], .string("/var"), "Without integration, the launch directory")
        XCTAssertEqual(pane(full, process)["shell"], .object(["integration": .string("none")]))
        XCTAssertEqual(pane(full, process)["attention"], .object([:]))
        XCTAssertNil(pane(full, process)["title"])
        XCTAssertEqual(pane(full, ssh)["machine"], .object(["kind": .string("ssh"), "hostId": .string(host.id.uuidString.lowercased())]))
        XCTAssertNil(pane(full, ssh)["folder"], "An ssh pane names no local folder")
        XCTAssertEqual(pane(full, agent)["agent"], .object(["agentId": .string("trellis-claude-code"), "state": .string("needsInput")]))
        XCTAssertEqual(object(pane(full, agent)["shell"] ?? .null)["integration"], .string("remote"))
        XCTAssertEqual(pane(full, remoteShell)["machine"], .object(["kind": .string("remote"), "hostId": .string(host.id.uuidString.lowercased())]))
        XCTAssertEqual(pane(full, remoteAgent)["machine"], .object(["kind": .string("remote"), "hostId": .string(host.id.uuidString.lowercased())]))
        XCTAssertEqual(pane(full, agent)["machine"], .object(["kind": .string("local")]))

        let reader = projection([.metadataRead])
        XCTAssertNil(pane(reader, shell)["folder"], "folder needs session.execute")
        XCTAssertEqual(pane(reader, ssh)["machine"], .object(["kind": .string("ssh")]))
    }

    // MARK: Session

    func testSessionsReportEveryLaunchKindWithRedaction() {
        let full = projection(everything), reader = projection([.metadataRead])
        let hostID = JSONValue.string(host.id.uuidString.lowercased())
        let expected: [(UUID, JSONValue, JSONValue)] = [
            (shell, .object(["kind": .string("shell"), "directory": .string("/Users/me/src")]), .object(["kind": .string("shell")])),
            (login, .object(["kind": .string("shell"), "directory": .string("/tmp")]), .object(["kind": .string("shell")])),
            (
                process, .object(["kind": .string("process"), "executable": .string("/usr/bin/top"), "arguments": .array([.string("-o"), .string("cpu")]), "directory": .string("/var")]),
                .object(["kind": .string("process")])
            ),
            (ssh, .object(["kind": .string("ssh"), "hostId": hostID]), .object(["kind": .string("ssh")])),
            (
                agent, .object(["kind": .string("agent"), "agentId": .string("trellis-claude-code"), "machine": .object(["kind": .string("local")]), "directory": .string("/Users/me/src/lotus")]),
                .object(["kind": .string("agent"), "agentId": .string("trellis-claude-code"), "machine": .object(["kind": .string("local")])])
            ),
            (remoteShell, .object(["kind": .string("remoteShell"), "hostId": hostID, "directory": .string("/srv/app")]), .object(["kind": .string("remoteShell")])),
            (
                remoteAgent,
                .object(["kind": .string("agent"), "agentId": .string("trellis-codex"), "machine": .object(["kind": .string("remote"), "hostId": hostID]), "directory": .string("/srv")]),
                .object(["kind": .string("agent"), "agentId": .string("trellis-codex"), "machine": .object(["kind": .string("remote")])])
            )
        ]
        for (pane, withExecute, redacted) in expected {
            XCTAssertEqual(session(full, pane)["launch"], withExecute, "\(pane)")
            XCTAssertEqual(session(reader, pane)["launch"], redacted, "\(pane)")
        }
        let live = session(full, shell)
        XCTAssertEqual(live["state"], .string("running"), "The terminal's live state wins")
        XCTAssertEqual(live["kept"], .bool(true))
        XCTAssertEqual(live["revision"], .number(12))
        XCTAssertEqual(live["createdAt"], .string("2027-01-15T08:00:00.250Z"))
        XCTAssertNil(live["exitCode"])
        XCTAssertNil(live["startedAt"])
        let exited = session(full, process)
        XCTAssertEqual(exited["state"], .string("exited"))
        XCTAssertEqual(exited["exitCode"], .number(0), "A real zero stays")
        XCTAssertEqual(exited["endedAt"], .string("2027-01-15T08:00:01.250Z"))
        XCTAssertEqual(exited["kept"], .bool(false))
        XCTAssertEqual(session(full, login)["failureMessage"], .string("No such directory"))
        XCTAssertEqual(session(full, login)["state"], .string("failed"))
    }

    // MARK: Host

    func testHostsShowPasswordPolicyAndRemoteStateNeverSecrets() {
        let full = projection(everything)
        let checked = Date(timeIntervalSince1970: 1_800_000_100)
        let used = object(
            full.host(
                host,
                remote: HostRuntimeV2(
                    helper: RemoteHelperRecord(state: .outdated, system: "Linux", machine: "x86_64", checkedAt: checked), autoInstall: true,
                    link: .reconnecting(attempt: 2, at: checked.addingTimeInterval(30)))))
        XCTAssertEqual(used["password"], .object(["saved": .bool(true), "requiresUserPresence": .bool(true)]))
        XCTAssertEqual(used["port"], .number(2222))
        XCTAssertEqual(used["tags"], .array([.string("work")]))
        XCTAssertEqual(used["connectionRevision"], .number(2))
        XCTAssertEqual(
            used["remote"],
            .object([
                "helper": .string("outdated"), "checkedAt": .string("2027-01-15T08:01:40.000Z"), "autoInstall": .bool(true),
                "link": .object(["state": .string("reconnecting"), "attempt": .number(2), "nextAttemptAt": .string("2027-01-15T08:02:10.000Z")])
            ]))
        let unused = object(full.host(other, remote: HostRuntimeV2()))
        XCTAssertEqual(unused["password"], .object(["saved": .bool(false)]))
        XCTAssertNil(unused["remote"], "Only once used as a remote workspace")
        XCTAssertNil(unused["user"])
        XCTAssertNil(unused["port"])
        XCTAssertEqual(object(full.host(other, remote: HostRuntimeV2(link: .needsInput)))["remote"], .object(["autoInstall": .bool(false), "link": .object(["state": .string("needsInput")])]))
    }

    // MARK: Agents (resources.md#agent-definition, #agent-run)

    func testAgentDefinitionsRedactWhatRunsAndHostsOutsideScope() {
        let definition = AgentDefinition(
            id: "trellis-codex", name: "Codex", executable: "codex", resumeArguments: ["resume", "--last"], integration: .codexNotify,
            install: ["darwin": AgentInstallRecipe(command: "npm i -g @openai/codex", requires: ["npm"])])
        let availability = [
            AgentAvailabilityV2(status: .installed, installable: true), AgentAvailabilityV2(hostID: host.id, status: .missing, installable: true),
            AgentAvailabilityV2(hostID: other.id, status: .unknown, installable: false)
        ]
        let full = object(projection(everything, hosts: .approved([HostApproval(hostID: host.id, connectionRevision: 2)])).agent(definition, revision: 3, availability: availability))
        XCTAssertEqual(full["id"], .string("trellis-codex"))
        XCTAssertEqual(full["builtIn"], .bool(true))
        XCTAssertEqual(full["revision"], .number(3))
        XCTAssertEqual(full["integration"], .string("codex-notify"))
        XCTAssertEqual(full["resumable"], .bool(true))
        XCTAssertEqual(full["executable"], .string("codex"))
        XCTAssertEqual(full["install"], .object(["darwin": .object(["command": .string("npm i -g @openai/codex"), "requires": .array([.string("npm")])])]))
        XCTAssertEqual(
            full["availability"],
            .array([
                .object(["machine": .object(["kind": .string("local")]), "status": .string("installed")]),
                .object(["machine": .object(["kind": .string("remote"), "hostId": .string(host.id.uuidString.lowercased())]), "status": .string("missing"), "installable": .bool(true)])
            ]), "A host outside scope isn't listed; installed needs no installable flag")
        // Without session.execute nothing says what runs; without host.read no host is listed.
        let plain = object(projection([.metadataRead]).agent(definition, revision: 3, availability: availability))
        XCTAssertNil(plain["executable"])
        XCTAssertNil(plain["install"])
        XCTAssertEqual(plain["availability"], .array([.object(["machine": .object(["kind": .string("local")]), "status": .string("installed")])]))
    }

    func testAgentRunsFollowSpaceScopeWithUntrustedSettings() {
        var live = runtime()
        let since = started.addingTimeInterval(3)
        live.panes[agent] = {
            var state = PaneRuntimeV2()
            state.agent = AgentSummaryV2(
                agentID: "trellis-claude-code", state: .needsInput, managed: true, since: since, unseen: false, settings: AgentSettings(model: "claude-opus-5-5", effort: "high"))
            return state
        }()
        live.panes[shell]?.agent = AgentSummaryV2(agentID: "trellis-codex", state: .working, managed: false)
        let grant = AutomationGrant(
            id: UUID(), name: "Test", tokenHash: "", capabilities: everything, spaceScope: .all, hostScope: .all, createdAt: started, expiresAt: started.addingTimeInterval(60))
        let full = ProjectionV2(snapshot: snapshot(), runtime: live, hosts: [host.id: host], grant: grant)
        let runs = full.agentRuns().map(object)
        XCTAssertEqual(runs.map { $0["paneId"] }, [.string(shell.uuidString.lowercased()), .string(agent.uuidString.lowercased())], "Sidebar order")
        let run = runs[1]
        XCTAssertEqual(run["sessionId"], .string(full.snapshot.panes[agent]!.sessionID.uuidString.lowercased()))
        XCTAssertEqual(run["spaceId"], .string(local.uuidString.lowercased()))
        XCTAssertEqual(run["origin"], .string("managed"))
        XCTAssertEqual(run["state"], .string("needsInput"))
        XCTAssertEqual(run["since"], .string(ConventionsV2.timestamp(since)))
        XCTAssertEqual(run["unseen"], .bool(false))
        XCTAssertEqual(run["settings"], .object(["model": .string("claude-opus-5-5"), "effort": .string("high")]))
        XCTAssertEqual(runs[0]["origin"], .string("detected"))
        XCTAssertNil(runs[0]["settings"], "Nothing reported, nothing shown")
        XCTAssertEqual(full.agentRuns(state: .working).count, 1)
        XCTAssertEqual(full.agentRuns(space: remote).count, 0)
        let scoped = AutomationGrant(
            id: UUID(), name: "Test", tokenHash: "", capabilities: everything, spaceScope: .spaces([remote]), hostScope: .all, createdAt: started,
            expiresAt: started.addingTimeInterval(60))
        XCTAssertEqual(ProjectionV2(snapshot: snapshot(), runtime: live, hosts: [:], grant: scoped).agentRuns(), [], "Runs outside the space scope don't appear")
        XCTAssertNil(full.agentRun(paneID: process), "A pane without an agent has no run")
    }

    func testEveryIDIsLowercase() throws {
        let full = projection(everything)
        var values = full.visibleSpaces().map(full.space)
        values += full.snapshot.tabs.values.map { full.tab($0, layout: true) }
        values += full.snapshot.panes.values.map(full.pane)
        values += full.snapshot.panes.values.map { full.session(full.snapshot.sessions[$0.sessionID]!, paneID: $0.id) }
        let text = String(decoding: try JSONEncoder().encode(JSONValue.array(values)), as: UTF8.self)
        XCTAssertNil(text.firstMatch(of: /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/), "UUIDs are written lowercase")
        XCTAssertFalse(text.contains("\"\""), "No empty-string placeholders")
    }
}
