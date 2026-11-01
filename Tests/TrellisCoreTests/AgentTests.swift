import Foundation
import XCTest

@testable import TrellisCore

/// FR-AG01–FR-AG03: the agent catalog, bundled and from the user's Agents folder.
final class AgentCatalogTests: XCTestCase {
    func testTheBundledAgentsAreClaudeCodePiAndCodex() {
        let agents = AgentCatalog.bundled()
        XCTAssertEqual(agents.map(\.id), ["trellis-claude-code", "trellis-pi", "trellis-codex"])
        XCTAssertEqual(agents.map(\.executable), ["claude", "pi", "codex"])
        XCTAssertEqual(agents.map(\.integration), [.claudeHooks, .piExtension, .codexNotify])
        XCTAssertTrue(agents.allSatisfy { $0.isBuiltIn && $0.install["darwin"] != nil && $0.install["linux"] != nil && !$0.resumeArguments.isEmpty })
        XCTAssertNotNil(AgentCatalog.bundledFile(AgentCommand.piExtensionName), "The pi extension ships beside the definitions")
    }

    func testUserDefinitionsAreValidatedAndAnUnusableFileNeverHidesTheOthers() throws {
        let good = AgentDefinition(id: "aider", name: "Aider", executable: "aider", integration: .none, icon: .monogram("A"))
        let files = FakeFiles(files: [
            "aider.agent.json": try JSONEncoder().encode(good),
            "wrong-name.agent.json": try JSONEncoder().encode(AgentDefinition(id: "other", name: "Other", executable: "other")),
            "trellis-mine.agent.json": try JSONEncoder().encode(AgentDefinition(id: "trellis-mine", name: "Mine", executable: "mine")),
            "broken.agent.json": Data("{".utf8),
            "path.agent.json": try JSONEncoder().encode(AgentDefinition(id: "path", name: "Path", executable: "../../bin/sh"))
        ])
        let snapshot = AgentCatalog.load(userDirectory: URL(fileURLWithPath: "/agents"), bundled: AgentCatalog.bundled(), files: files)
        XCTAssertEqual(snapshot.definitions.map(\.id), ["trellis-claude-code", "trellis-pi", "trellis-codex", "aider"])
        XCTAssertEqual(snapshot.iconDirectories["aider"], URL(fileURLWithPath: "/agents"))
        XCTAssertEqual(Set(snapshot.issues.map(\.filename)), ["wrong-name.agent.json", "trellis-mine.agent.json", "broken.agent.json", "path.agent.json"])
        XCTAssertTrue(snapshot.issues.first { $0.filename == "trellis-mine.agent.json" }!.message.contains("reserved"))
    }

    func testTheValidatorRefusesWhatCouldRunSomethingElse() {
        func refused(_ change: (inout AgentDefinition) -> Void) -> Bool {
            var definition = AgentDefinition(id: "ok", name: "OK", executable: "ok")
            change(&definition)
            return (try? AgentDefinitionValidator.validate(definition)) == nil
        }
        XCTAssertFalse(refused { _ in })
        XCTAssertFalse(refused { $0.executable = "/opt/homebrew/bin/codex" })
        XCTAssertTrue(refused { $0.executable = "claude; rm -rf ~" })
        XCTAssertTrue(refused { $0.executable = "-c" })
        XCTAssertTrue(refused { $0.executable = "/opt/../bin/sh" })
        XCTAssertTrue(refused { $0.arguments = ["--x\nrm"] })
        XCTAssertTrue(refused { $0.id = "Has Spaces" })
        XCTAssertTrue(refused { $0.name = "" })
        XCTAssertTrue(refused { $0.install = ["windows": AgentInstallRecipe(command: "x")] })
        XCTAssertTrue(refused { $0.install = ["linux": AgentInstallRecipe(command: "a\nb")] })
        XCTAssertTrue(refused { $0.install = ["linux": AgentInstallRecipe(command: "x", requires: ["npm; curl"])] })
        XCTAssertTrue(refused { $0.icon = .image("../logo.svg") })
        XCTAssertTrue(refused { $0.icon = .image("logo.exe") })
        XCTAssertTrue(refused { $0.icon = .monogram("ABC") })
        XCTAssertTrue(refused { $0.homepage = "http://example.com" })
        XCTAssertTrue(refused { $0.version = 2 })
        XCTAssertThrowsError(try AgentDefinitionValidator.validate(Data(count: AgentDefinitionValidator.maximumBytes + 1)))
    }

    func testAnUnknownIntegrationOrIconFromANewerBuildDegradesInsteadOfFailing() throws {
        let json = #"{"version":1,"id":"new","name":"New","executable":"new","integration":"future-hooks","icon":{"emoji":"x"}}"#
        let definition = try AgentDefinitionValidator.validate(Data(json.utf8))
        XCTAssertEqual(definition.integration, AgentIntegration.none)
        XCTAssertEqual(definition.icon, .fallback)
    }

    func testANewerSchemaIsRefusedWithItsVersionEvenWhenItsShapeChanged() {
        let json = #"{"version":2,"id":"new","name":{"en":"New"},"run":["new"]}"#
        XCTAssertThrowsError(try AgentDefinitionValidator.validate(Data(json.utf8))) { XCTAssertEqual($0 as? AgentDefinitionError, .unsupportedVersion(2)) }
    }

    private struct FakeFiles: AgentCatalogFiles {
        let files: [String: Data]
        func filenames(in directory: URL) throws -> [String] { files.keys.sorted() }
        func read(_ file: URL) throws -> Data { try files[file.lastPathComponent].orThrow() }
    }
}

/// FR-AG04, FR-AG08: the command line an agent starts with, and its hook wiring.
final class AgentCommandTests: XCTestCase {
    private let helper = "/Applications/Trellis Beta.app/Contents/Helpers/trellis-broker"
    private func agent(_ id: String) throws -> AgentDefinition { try XCTUnwrap(AgentCatalog.bundled().first { $0.id == id }) }

    func testClaudeCodeGetsItsHooksThroughSettingsWithoutTouchingTheUsersFiles() throws {
        let command = AgentCommand(definition: try agent("trellis-claude-code"), hookHelper: helper)
        XCTAssertEqual(command.words.prefix(3), ["env", "claude", "--settings"])
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(command.words[3].utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(
            Set(hooks.keys), ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"])
        let stop = try XCTUnwrap((hooks["Stop"]?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertEqual(stop, "'\(helper)' agent-hook done", "A helper path with spaces stays one word")
        XCTAssertEqual(hooks["Notification"]?.first?["matcher"] as? String, "permission_prompt|elicitation_dialog", "The idle reminder never reads as Needs you")
        XCTAssertTrue(command.line.hasPrefix("exec env claude --settings '{"))
    }

    func testCodexReportsTurnsThroughNotifyAndPiThroughItsExtension() throws {
        let codex = AgentCommand(definition: try agent("trellis-codex"), resume: true, hookHelper: helper)
        XCTAssertEqual(codex.words, ["env", "codex", "-c", #"notify=["\#(helper)","agent-hook","done"]"#, "resume", "--last"])
        let pi = AgentCommand(definition: try agent("trellis-pi"), hookHelper: helper, piExtension: "/b/trellis-pi-extension.ts")
        XCTAssertEqual(pi.words, ["env", "TRELLIS_AGENT_HOOK=" + helper, "pi", "-e", "/b/trellis-pi-extension.ts"])
        XCTAssertEqual(AgentCommand(definition: try agent("trellis-pi")).words, ["env", "pi"], "Without the helper the agent runs plain")
    }

    func testARemotePiWritesItsExtensionFirstAndEveryWordIsQuoted() throws {
        let command = AgentCommand(
            definition: try agent("trellis-pi"), hookHelper: "/home/me/.trellis/remote/abc/trellis-broker", piExtension: "/home/me/.trellis/agents/x.ts",
            piExtensionSource: "a 'quoted' $HOME")
        XCTAssertEqual(
            command.line,
            "mkdir -p /home/me/.trellis/agents; printf '%s' 'a '\\''quoted'\\'' $HOME' > /home/me/.trellis/agents/x.ts; exec env TRELLIS_AGENT_HOOK=/home/me/.trellis/remote/abc/trellis-broker pi -e /home/me/.trellis/agents/x.ts"
        )
        XCTAssertEqual(AgentCommand.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(AgentCommand.quote(""), "''")
        XCTAssertEqual(AgentCommand.quote("--continue"), "--continue")
    }

    func testTheLoginShellReadsItsInteractiveFilesWhereAgentsUsuallyGetOnPath() {
        XCTAssertEqual(AgentShell.arguments(shell: "/bin/zsh", line: "exec env claude").arguments, ["-l", "-i", "-c", "exec env claude"])
        XCTAssertEqual(AgentShell.arguments(shell: "/opt/homebrew/bin/fish", line: "x").arguments, ["-l", "-i", "-c", "x"])
        XCTAssertEqual(AgentShell.arguments(shell: "/bin/tcsh", line: "x").executable, "/bin/sh", "csh and tcsh take -l only alone")
        XCTAssertEqual(AgentShell.arguments(shell: "/bin/dash", line: "x").arguments, ["-l", "-c", "x"])
        XCTAssertEqual(AgentShell.remoteCommand(shell: "/usr/bin/bash", line: "exec env pi"), "exec /usr/bin/bash -i -c 'exec env pi'")
        XCTAssertEqual(AgentShell.remoteCommand(shell: "/bin/sh", line: "exec env pi"), "exec env pi")
    }

    func testTheLaunchLineParsesTheSameInPosixShells() throws {
        let command = AgentCommand(definition: try agent("trellis-claude-code"), hookHelper: helper)
        for shell in ["/bin/sh", "/bin/zsh", "/bin/bash"] {
            // `printf` stands in for `exec env`: each word must arrive intact.
            let line = command.line.replacingOccurrences(of: "exec env ", with: "printf '%s\\n' ")
            let output = try run(shell, ["-c", line])
            XCTAssertEqual(output.split(separator: "\n").map(String.init), Array(command.words.dropFirst()), shell)
        }
    }

    func testTheLoginPathProbeReadsOnlyItsMarkedLine() {
        let path = AgentPathProbe.loginPath(shell: "/bin/zsh") { executable, arguments, _ in
            XCTAssertEqual(executable, "/bin/zsh")
            XCTAssertEqual(arguments.prefix(3), ["-l", "-i", "-c"])
            return "Welcome!\nTRELLIS-PATH:fake\n\nTRELLIS-PATH:/usr/bin:relative:/opt/homebrew/bin\n"
        }
        XCTAssertEqual(path, ["/usr/bin", "/opt/homebrew/bin"])
        XCTAssertNil(AgentPathProbe.loginPath(shell: "/bin/zsh") { _, _, _ in "no marker" })
        XCTAssertNil(AgentPathProbe.loginPath(shell: "/bin/zsh") { _, _, _ in nil }, "A timed-out shell says nothing, never 'missing'")
        XCTAssertEqual(AgentPathProbe.resolve("sh", path: ["/nonexistent", "/bin"]), "/bin/sh")
        XCTAssertNil(AgentPathProbe.resolve("definitely-not-an-agent", path: ["/bin"]))
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// FR-AG10, FR-AG11: what a tab shows for its agent.
final class AgentStateReducerTests: XCTestCase {
    func testHooksDriveTheStateAndDoneShowsUntilSeen() {
        var reducer = AgentStateReducer(integration: .claudeHooks)
        XCTAssertNil(reducer.badge, "Ready shows no badge")
        XCTAssertTrue(reducer.apply(.hook(.working)))
        XCTAssertEqual(reducer.badge, .working)
        reducer.apply(.hook(.needsInput))
        XCTAssertEqual(reducer.badge, .needsInput)
        reducer.apply(.hook(.done))
        XCTAssertEqual(reducer.badge, .done)
        XCTAssertTrue(reducer.apply(.viewed))
        XCTAssertNil(reducer.badge, "Seen, Done goes quiet")
        XCTAssertEqual(reducer.state, .done)
        reducer.apply(.hook(.done), visible: true)
        reducer.apply(.hook(.working), visible: true)
        reducer.apply(.hook(.done), visible: true)
        XCTAssertNil(reducer.badge, "Finishing in view needs no badge")
    }

    func testABellNeverTurnsAFinishedTurnBackIntoAQuestion() {
        var codex = AgentStateReducer(integration: .codexNotify)
        codex.apply(.inputSubmitted)
        XCTAssertEqual(codex.state, .working, "Codex has no prompt hook: Return means working")
        codex.apply(.attention)
        XCTAssertEqual(codex.state, .needsInput, "An approval rings the bell")
        codex.apply(.inputSubmitted)
        codex.apply(.hook(.done))
        codex.apply(.attention)
        XCTAssertEqual(codex.state, .done, "Its own turn-complete notification follows notify")
    }

    func testReturnInAHookedAgentWaitsForTheAgentToSaySo() {
        var claude = AgentStateReducer(integration: .claudeHooks)
        claude.apply(.hook(.start))
        claude.apply(.inputSubmitted)
        XCTAssertEqual(claude.state, .ready, "Return in a menu isn't a prompt")
        claude.apply(.hook(.working))
        XCTAssertEqual(claude.state, .working)
    }

    func testAnAgentWithoutHooksStillReadsProgressAndBells() {
        var plain = AgentStateReducer(integration: .none)
        plain.apply(.progress(active: true))
        XCTAssertEqual(plain.state, .working)
        plain.apply(.progress(active: false))
        XCTAssertEqual(plain.state, .done)
        plain.apply(.inputSubmitted)
        plain.apply(.attention)
        XCTAssertEqual(plain.badge, .needsInput)
        plain.apply(.progress(active: true))
        XCTAssertEqual(plain.state, .needsInput, "Progress doesn't answer a question")
    }
}

/// FR-AG04, FR-AG06: agent panes in the workspace and on disk.
final class AgentWorkspaceTests: XCTestCase {
    func testAnAgentPaneIsSavedByIDAndDirectoryAndRestoresStoppedAndFresh() async throws {
        let store = try WorkspaceStore()
        let made = try await store.execute(.createWindow(name: "Agents")).snapshot
        let pane = try XCTUnwrap(made.panes.keys.first)
        _ = try await store.execute(
            .configureStoppedSession(paneID: pane, launch: .agent(AgentLaunch(agentID: "trellis-claude-code", directory: "/tmp", resume: true))))
        let snapshot = await store.snapshot()
        let data = try WorkspaceSnapshotCodec.encode(snapshot, settings: WorkspaceSettings())
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(header["schemaVersion"] as? Int, 3, "Older builds open it read-only")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("resume"), "A restored agent never continues a conversation by itself")
        let restored = try WorkspaceSnapshotCodec.decode(data).snapshot
        let session = try XCTUnwrap(restored.panes[pane].flatMap { restored.sessions[$0.sessionID] })
        XCTAssertEqual(session.state, .stopped)
        XCTAssertEqual(session.launch, .agent(AgentLaunch(agentID: "trellis-claude-code", directory: "/tmp")))
    }

    func testAnAgentRunsOnlyWhereItsWindowRuns() async throws {
        let host = UUID()
        let store = try WorkspaceStore()
        let remote = try await store.execute(.createRemoteWindow(name: "box", hostID: host)).snapshot
        let remotePane = try XCTUnwrap(remote.panes.keys.first)
        let localAgent = SessionLaunch.agent(AgentLaunch(agentID: "trellis-pi", directory: nil))
        let result = try? await store.execute(.configureStoppedSession(paneID: remotePane, launch: localAgent))
        XCTAssertNil(result, "A local agent in a remote window")
        _ = try await store.execute(.configureStoppedSession(paneID: remotePane, launch: .agent(AgentLaunch(agentID: "trellis-pi", directory: "/srv", hostID: host))))
        let local = try await store.execute(.createWindow(name: "Local")).snapshot
        let localPane = try XCTUnwrap(local.panes.keys.first { $0 != remotePane })
        let misplaced = try? await store.execute(.configureStoppedSession(paneID: localPane, launch: .agent(AgentLaunch(agentID: "trellis-pi", directory: nil, hostID: host))))
        XCTAssertNil(misplaced, "A remote agent in a local window")
    }

    func testOnlyTheAppPlannedHookVariablesReachAnAgent() throws {
        let files = AllowAll()
        var configuration = LocalLaunchConfiguration(
            executable: "/bin/zsh", arguments: ["-l"], directory: "/tmp",
            inheritedEnvironment: ["TRELLIS_AGENT_NONCE": "stale", "TRELLIS_AGENT_SOCKET": "/stale", "HOME": "/Users/me"])
        configuration.agentHook = AgentHookEnvironment(socket: "/tmp/b/agent.sock", nonce: "0123456789abcdef0123456789abcdef")
        let launch = try LocalLaunchValidator(files: files).validate(configuration)
        XCTAssertEqual(launch.environment["TRELLIS_AGENT_SOCKET"], "/tmp/b/agent.sock")
        XCTAssertEqual(launch.environment["TRELLIS_AGENT_NONCE"], "0123456789abcdef0123456789abcdef")
        configuration.agentHook = nil
        XCTAssertNil(try LocalLaunchValidator(files: files).validate(configuration).environment["TRELLIS_AGENT_NONCE"], "An inherited nonce never leaks into a session")
        configuration.environmentOverrides = ["TRELLIS_AGENT_NONCE": "forged"]
        XCTAssertThrowsError(try LocalLaunchValidator(files: files).validate(configuration), "Automation can't name a session's nonce")
        XCTAssertEqual(AgentHookEnvironment.socketVariable, "TRELLIS_AGENT_SOCKET")
        XCTAssertEqual(AgentHookEnvironment.nonceVariable, "TRELLIS_AGENT_NONCE")
    }

    private struct AllowAll: LaunchFileAccess {
        func isExecutableFile(_ path: String) -> Bool { true }
        func isAccessibleDirectory(_ path: String) -> Bool { true }
    }
}

extension Optional {
    fileprivate func orThrow() throws -> Wrapped {
        guard let value = self else { throw CocoaError(.fileNoSuchFile) }
        return value
    }
}

/// FR-PL10: agent panes in library projects.
final class ProjectAgentTests: XCTestCase {
    private func project(_ pane: ProjectPane) -> ProjectDefinition {
        ProjectDefinition(name: "Shop", tabs: [ProjectTab(title: "API", directory: "api", root: .split(axis: .x, ratio: 0.5, first: .pane(pane), second: .pane(ProjectPane())))])
    }

    func testAnAgentPaneRoundTripsAndIsValidatedLikeTheCatalog() throws {
        let stored = project(ProjectPane(title: "Claude", agent: "trellis-claude-code"))
        let decoded = try JSONDecoder().decode(ProjectDefinition.self, from: JSONEncoder().encode(stored))
        XCTAssertEqual(decoded, stored)
        XCTAssertTrue(stored.issues.isEmpty)
        XCTAssertEqual(stored.agentCount, 1)
        XCTAssertEqual(project(ProjectPane(agent: "  trellis-pi ")).normalized.tabs[0].root.panes[0].pane.agent, "trellis-pi")
        XCTAssertEqual(project(ProjectPane(agent: "Not An ID")).issues.map(\.field), [.agent])
        XCTAssertEqual(project(ProjectPane(command: "make dev", agent: "trellis-pi")).issues.map(\.field), [.command], "An agent or a command, not both")
    }

    func testOnlyALibraryWithAnAgentPaneIsSavedAsVersionTwo() throws {
        func version(_ data: Data) throws -> Int? { (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int }
        let plain = try ProjectLibraryCodec.encode([project(ProjectPane(command: "make dev"))], revision: 1)
        XCTAssertEqual(try version(plain), 1, "Older builds keep reading it")
        let agents = try ProjectLibraryCodec.encode([project(ProjectPane(agent: "trellis-codex"))], revision: 1)
        XCTAssertEqual(try version(agents), 2, "Older builds open it read-only instead of dropping the agent")
        XCTAssertEqual(try ProjectLibraryCodec.decode(plain).projects.count, 1)
        XCTAssertEqual(try ProjectLibraryCodec.decode(agents).projects.first?.agentCount, 1)
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: agents) as? [String: Any])
        future["schemaVersion"] = ProjectLibraryCodec.currentVersion + 1
        XCTAssertThrowsError(try ProjectLibraryCodec.decode(JSONSerialization.data(withJSONObject: future)))
    }

    func testALaunchNamesItsAgentPanesAndTypesNoCommandIntoThem() throws {
        let launch = try XCTUnwrap(ProjectLaunch.resolve(project(ProjectPane(agent: "trellis-pi")), target: .local, folder: "/tmp/shop", home: "/Users/me"))
        XCTAssertEqual(launch.agents, ["t1-1": "trellis-pi"])
        XCTAssertTrue(launch.commands.isEmpty)
    }

    func testCapturingAWindowKeepsItsAgentPanes() async throws {
        let store = try WorkspaceStore()
        let made = try await store.execute(.createWindow(name: "Agents")).snapshot
        let window = try XCTUnwrap(made.windows.first)
        let pane = try XCTUnwrap(made.panes.keys.first)
        _ = try await store.execute(.configureStoppedSession(paneID: pane, launch: .agent(AgentLaunch(agentID: "trellis-claude-code", directory: "/tmp/shop"))))
        let snapshot = await store.snapshot()
        let capture = try XCTUnwrap(ProjectCapture.capture(window: window.id, snapshot: snapshot, home: "/Users/me") { _ in "/tmp/shop" })
        XCTAssertEqual(capture.project.tabs.first?.root.panes.first?.pane.agent, "trellis-claude-code")
        XCTAssertTrue(capture.warnings.isEmpty)
    }
}
