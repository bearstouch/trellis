import AppKit
import TrellisControl
import TrellisCore
import TrellisTerminal
import XCTest

@testable import TrellisUI

/// Protocol 2 tasks and `session.execute {wait}` over the real model (methods.md#tasks, #sessions; FR-TK, FR-SI). As in
/// TaskRunnerTests, the fake `zsh` gets shell integration injected but echoes every typed byte visibly (`cat -v` in raw
/// mode), and each test sends the shell's marks itself.
@MainActor
final class AutomationV2TaskTests: XCTestCase {
    private var scratch: URL!
    private var project: String!
    private var v: HarnessV2!
    private var pane: UUID!
    private var events: [EventDraftV2] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-v2tk-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let manager = FileManager.default
        try manager.createDirectory(at: scratch.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try manager.createDirectory(at: scratch.appendingPathComponent("project/.git"), withIntermediateDirectories: true)
        project = scratch.appendingPathComponent("project").path
        let shell = scratch.appendingPathComponent("bin/zsh").path
        try "#!/bin/sh\n/bin/stty raw -echo\nprintf 'SHELL-UP\\n'\nexec /bin/cat -uv\n".write(toFile: shell, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)
        try "// swift-tools-version:6.0\n".write(toFile: project + "/Package.swift", atomically: true, encoding: .utf8)

        v = try HarnessV2()
        let saved = await v.model.saveLaunchSettings(shell: shell, directory: project)
        XCTAssertTrue(saved)
        v.model.onLiveEvents = { [weak self] in self?.events.append(contentsOf: $0) }
        try await v.grant("full", settings: GrantSettings(name: "full", capabilities: Set(CapabilityV2.allCases)))
        let created = try await v.ok("space.create", ["name": "Tasks", "start": true])
        pane = try XCTUnwrap(UUID(uuidString: try XCTUnwrap((created["panes"] as? [[String: Any]])?.first?["id"] as? String)))
        try await until("the shell is up") { self.text.contains("SHELL-UP") }
    }

    override func tearDown() async throws {
        v?.cleanUp()
        v = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    private func grant(_ name: String, _ capabilities: Set<CapabilityV2>, scope: GrantScope = GrantScope()) async throws {
        try await v.grant(name, settings: GrantSettings(name: name, capabilities: capabilities, scope: scope))
    }

    private func until(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out: \(what)\n\(text)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private var text: String { (try? v.model.terminals[pane]?.adapter.read(.retainedText)) ?? "" }
    private var paneID: String { pane.uuidString.lowercased() }
    private var sessionID: String { (v.model.snapshot.panes[pane]?.sessionID.uuidString.lowercased())! }

    private func mark(_ event: ShellIntegrationEvent) throws { try XCTUnwrap(v.model.terminals[pane]).onShellIntegrationEvent?(event) }

    private func typed(_ line: String) async throws {
        let shown = line.replacingOccurrences(of: "\u{05}", with: "^E").replacingOccurrences(of: "\u{15}", with: "^U").replacingOccurrences(of: "\r", with: "^M")
        try await until("\(shown) was typed") { self.text.contains(shown) }
    }

    private func writeLaunchFile(_ text: String) throws {
        try FileManager.default.createDirectory(atPath: project + "/.trellis", withIntermediateDirectories: true)
        try text.write(toFile: project + "/.trellis/launch.json", atomically: true, encoding: .utf8)
    }

    // MARK: Tasks

    func testListAndRunTypeATaskAsRunDoesAndFollowItsRun() async throws {
        try await grant("reader", [.taskRead, .workspaceRead])
        try await grant("elsewhere", Set(CapabilityV2.allCases), scope: GrantScope(spaces: .spaces([UUID()])))
        let listed = try await v.ok("task.list", ["paneId": paneID])
        let tasks = try XCTUnwrap(listed["tasks"] as? [[String: Any]])
        XCTAssertEqual(tasks.map { $0["id"] as? String }, ["detected:swift: build", "detected:swift: test"])
        XCTAssertEqual(tasks.first?["source"] as? String, "swift")
        XCTAssertEqual(tasks.first?["trusted"] as? Bool, true, "Detected tasks come from fixed templates")
        XCTAssertEqual(tasks.first?["command"] as? String, "swift build")
        XCTAssertEqual(listed["folder"] as? String, project)
        XCTAssertEqual(listed["file"] as? String, "missing")
        let read = try await v.ok("task.list", ["paneId": paneID], as: "reader")
        XCTAssertNil((read["tasks"] as? [[String: Any]])?.first?["command"], "Commands need session.execute")
        XCTAssertNil(read["folder"])
        let hidden = try await v.code("task.list", ["paneId": paneID], as: "elsewhere")
        XCTAssertEqual(hidden, "NOT_FOUND")

        // Run types only at an idle prompt the shell reported (FR-TK05).
        let early = try await v.call("task.run", ["paneId": paneID, "taskId": "detected:swift: build"])
        XCTAssertEqual(errorCode(early), "INVALID_STATE")
        XCTAssertEqual(details(early)?["state"] as? String, "noIntegration")
        XCTAssertTrue(v.model.taskRuns.isEmpty)
        try mark(.promptStart(directory: project))
        let denied = try await v.code("task.run", ["paneId": paneID, "taskId": "detected:swift: build"], as: "reader")
        XCTAssertEqual(denied, "PERMISSION_DENIED")
        let missing = try await v.code("task.run", ["paneId": paneID, "taskId": "detected:nope"])
        XCTAssertEqual(missing, "NOT_FOUND")

        let ran = object(try await v.ok("task.run", ["paneId": paneID, "taskId": "detected:swift: build"]), "run")
        XCTAssertEqual(ran["phase"] as? String, "submitted")
        XCTAssertEqual(ran["taskId"] as? String, "detected:swift: build")
        try await typed("\u{05}\u{15}swift build\r")
        let busy = try await v.call("task.run", ["paneId": paneID, "taskId": "detected:swift: test"])
        XCTAssertEqual(details(busy)?["state"] as? String, "taskActive")
        let pane = object(try await v.ok("pane.get", ["id": paneID]), "pane")
        XCTAssertEqual(pane["task"] as? [String: String], ["taskId": "detected:swift: build", "phase": "submitted"])

        try mark(.commandStart(commandLine: "swift build"))
        let value1 = try await v.ok("task.get", ["paneId": paneID])
        XCTAssertEqual(object(value1, "run")["phase"] as? String, "running")
        try mark(.commandFinished(exitCode: 2))
        try mark(.promptStart(directory: project))
        let finished = object(try await v.ok("task.get", ["paneId": paneID], as: "reader"), "run")
        XCTAssertEqual(finished["phase"] as? String, "finished")
        XCTAssertEqual(finished["exitCode"] as? Int, 2)
        // The API's run is the app's run: one taskRuns entry, reported by the same task.run events.
        XCTAssertEqual(v.model.taskRuns[self.pane]?.taskID, "detected:swift: build")
        let phases = events.filter { $0.type == "task.run" && $0.resourceID == "detected:swift: build" }.compactMap { $0.data["phase"] }
        XCTAssertEqual(phases, [.string("submitted"), .string("running"), .string("finished")])
    }

    func testAnUntrustedLaunchFileTaskIsRefusedUntilTrustedInTheApp() async throws {
        let file = #"{"version": 1, "tasks": [{"name": "unit", "command": "make test"}]}"#
        try writeLaunchFile(file)
        try mark(.promptStart(directory: project))
        let firstList = try await v.ok("task.list", ["paneId": paneID])
        let tasks = try XCTUnwrap(firstList["tasks"] as? [[String: Any]])
        XCTAssertEqual(tasks.first?["id"] as? String, "file:unit")
        XCTAssertEqual(tasks.first?["trusted"] as? Bool, false)
        let refused = try await v.call("task.run", ["paneId": paneID, "taskId": "file:unit"])
        XCTAssertEqual(errorCode(refused), "TASK_UNTRUSTED")
        XCTAssertEqual(details(refused)?["taskId"] as? String, "file:unit")
        XCTAssertEqual(details(refused)?["changedSinceTrusted"] as? Bool, false)
        XCTAssertNil(v.model.pendingTaskReview, "The API never opens the app's review")
        XCTAssertTrue(v.model.taskRuns.isEmpty, "Nothing was typed")

        // Trusting is the app's (FR-TK06): the reviewed bytes become trusted, and the API may then run them.
        var trust = try v.model.launchTrustList()
        trust.trust(root: project, digest: ProjectTrustList.digest(Data(file.utf8)))
        v.model.launchTrust = trust
        let value2 = try await v.ok("task.list", ["paneId": paneID])
        XCTAssertEqual((value2["tasks"] as? [[String: Any]])?.first?["trusted"] as? Bool, true)
        _ = try await v.ok("task.run", ["paneId": paneID, "taskId": "file:unit"])
        try await typed("\u{05}\u{15}make test\r")
        try mark(.commandStart(commandLine: nil))
        try mark(.promptStart(directory: project))

        // One changed byte is another version: refused again, and said to have changed.
        try writeLaunchFile(file + " ")
        let changed = try await v.call("task.run", ["paneId": paneID, "taskId": "file:unit"])
        XCTAssertEqual(errorCode(changed), "TASK_UNTRUSTED")
        XCTAssertEqual(details(changed)?["changedSinceTrusted"] as? Bool, true)
    }

    func testStopSendsCtrlCAndForceOnlyAfterTheWait() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        v.model.activityNow = { now }
        let value3 = try await v.code("task.stop", ["paneId": paneID])
        XCTAssertEqual(value3, "INVALID_STATE", "Nothing to stop")
        try mark(.promptStart(directory: project))
        _ = try await v.ok("task.run", ["paneId": paneID, "taskId": "detected:swift: test"])
        try mark(.commandStart(commandLine: "swift test"))
        let early = try await v.call("task.stop", ["paneId": paneID, "force": true])
        XCTAssertEqual(errorCode(early), "CLOSE_PENDING", "Force waits for the first stop to be 2 s old")
        try await typed("^C")
        now += 2
        let forced = object(try await v.ok("task.stop", ["paneId": paneID, "force": true]), "run")
        XCTAssertEqual(forced["stopRequested"] as? Bool, true)
        try await typed("^\\")
        try mark(.commandFinished(exitCode: 131))
        let value4 = try await v.ok("task.get", ["paneId": paneID])
        XCTAssertEqual(object(value4, "run")["exitCode"] as? Int, 131)
    }

    // MARK: session.execute {wait}

    func testExecuteWaitReturnsTheExitCodeOrTimesOutAndNeedsIntegration() async throws {
        let wait: [String: Any] = ["until": "finished", "timeoutMs": 10_000]
        let early = try await v.call("session.execute", ["id": sessionID, "command": "make", "wait": wait])
        XCTAssertEqual(errorCode(early), "INVALID_STATE")
        XCTAssertEqual(details(early)?["state"] as? String, "noIntegration")
        XCTAssertFalse(text.contains("make^M"), "Nothing was typed")

        try mark(.promptStart(directory: project))
        let harness = v!, session = sessionID
        // The reply crosses back as JSON: the call waits while this test sends the marks.
        let finished = Task { @MainActor in
            try JSONSerialization.data(withJSONObject: try await harness.ok("session.execute", ["id": session, "command": "make", "wait": ["until": "finished", "timeoutMs": 10_000]]))
        }
        try await typed("make\r")
        // A second wait before the first line started would take the same marks.
        let second = try await v.call("session.execute", ["id": sessionID, "command": "ls", "wait": wait])
        XCTAssertEqual(details(second)?["state"] as? String, "busy", "One wait at a time per pane")
        try mark(.commandStart(commandLine: "make"))
        try mark(.commandFinished(exitCode: 3))
        let reply = try await finished.value
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        XCTAssertEqual(result["submitted"] as? Bool, true)
        XCTAssertEqual(result["exitCode"] as? Int, 3)
        XCTAssertEqual(result["timedOut"] as? Bool, false)
        XCTAssertNotNil(result["durationMs"] as? Int)
        try mark(.promptStart(directory: project))

        // A running command would make the next finish someone else's.
        try mark(.commandStart(commandLine: "vim"))
        let busy = try await v.call("session.execute", ["id": sessionID, "command": "ls", "wait": wait])
        XCTAssertEqual(details(busy)?["state"] as? String, "busy")
        try mark(.commandFinished(exitCode: 0))
        try mark(.promptStart(directory: project))

        let started = ContinuousClock.now
        let timedOut = try await v.ok("session.execute", ["id": sessionID, "command": "sleep 9", "wait": ["until": "finished", "timeoutMs": 300]])
        XCTAssertEqual(timedOut["timedOut"] as? Bool, true)
        XCTAssertNil(timedOut["exitCode"])
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        XCTAssertTrue(v.model.commandWaits.isEmpty, "A finished wait leaves nothing behind")

        let plain = try await v.ok("session.execute", ["id": sessionID, "command": "pwd"])
        XCTAssertEqual(plain.keys.sorted(), ["acceptedBytes", "submitted"], "Without wait it returns once typed")
    }
}
