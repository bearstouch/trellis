import AppKit
import XCTest
import TrellisControl
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// The command scratchpad end to end (FR-SP01, FR-SP05–FR-SP07), with the fake echoing `zsh` of `TaskRunnerTests` and an
/// injected syntax check.
final class ScratchpadTests: XCTestCase {
    private var scratch: URL!
    private var project: String!
    private var shell: String!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-sp-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let manager = FileManager.default
        try manager.createDirectory(at: scratch.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try manager.createDirectory(at: scratch.appendingPathComponent("state"), withIntermediateDirectories: true)
        try manager.createDirectory(at: scratch.appendingPathComponent("project/.git"), withIntermediateDirectories: true)
        project = scratch.appendingPathComponent("project").path
        shell = scratch.appendingPathComponent("bin/zsh").path
        try "#!/bin/sh\n/bin/stty raw -echo\nprintf 'SHELL-UP\\n'\nexec /bin/cat -uv\n".write(toFile: shell, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private final class Checks: @unchecked Sendable {
        let lock = NSLock()
        var result = ScratchpadProcessResult(status: 0, output: "")
        var count = 0
        func next() -> ScratchpadProcessResult {
            lock.withLock {
                count += 1; return result
            }
        }
    }

    @MainActor
    private func makeModel(checks: Checks = Checks(), directory: String? = nil) async throws -> (AppWorkspaceModel, UUID) {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-sp-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        model.confirmCloseSessions = { _ in true }
        model.scratchpadDirectory = scratch.appendingPathComponent("run")
        model.scratchpadProcessRunner = { _, _, _ in checks.next() }
        let saved = await model.saveLaunchSettings(shell: shell, directory: directory ?? project)
        XCTAssertTrue(saved)
        _ = await model.createWindow(name: "W")
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        try await waitFor { self.text(model, pane).contains("SHELL-UP") }
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

    private func launchFile() -> String? { try? String(contentsOfFile: project + "/.trellis/launch.json", encoding: .utf8) }

    @MainActor
    func testRunChecksWritesAPrivateCopyAndTypesTheInterpreterLine() async throws {
        let checks = Checks()
        let (model, pane) = try await makeModel(checks: checks)
        defer { cleanUp(model) }
        try mark(model, pane, .promptStart(directory: project))
        model.scratchpad = ScratchpadDocument(name: "hello", language: .bash, text: "for a in 1 2; do\n  echo \"$a\"\ndone\n")
        XCTAssertNil(model.scratchpadRunBlocker)
        let ran = await model.runScratchpad()
        XCTAssertTrue(ran)
        XCTAssertEqual(checks.count, 1, "Run checks first")
        XCTAssertEqual(model.scratchpadCheck?.outcome, .passed)
        let file = scratch.appendingPathComponent("run/hello.sh").path
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), model.scratchpad.text)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int, 0o600)
        try await typed(model, pane, "\u{05}\u{15}bash '\(file)'\r")
        XCTAssertEqual(model.taskRuns[pane]?.name, "hello.sh", "Followed like a task")
        XCTAssertEqual(model.taskAvailability(paneID: pane), .taskActive)
        XCTAssertEqual(model.scratchpadRunBlocker, TaskRunAvailability.taskActive.reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project + "/.trellis"), "Running never touches the project")
    }

    @MainActor
    func testRunIsBlockedWithAReasonWhenThePaneIsBusyOrTheCheckFails() async throws {
        let checks = Checks()
        let (model, pane) = try await makeModel(checks: checks)
        defer { cleanUp(model) }
        XCTAssertEqual(model.scratchpadRunBlocker, "Write a command or script first.")
        model.scratchpad.text = "echo hi"
        XCTAssertEqual(model.scratchpadRunBlocker, TaskRunAvailability.noIntegration.reason, "No prompt mark yet")
        try mark(model, pane, .promptStart(directory: project))
        try mark(model, pane, .commandStart(commandLine: "vim"))
        XCTAssertEqual(model.scratchpadRunBlocker, TaskRunAvailability.busy.reason)
        let busy = await model.runScratchpad()
        XCTAssertFalse(busy)
        XCTAssertEqual(checks.count, 0, "Nothing is checked or written while busy")
        try mark(model, pane, .commandFinished(exitCode: 0))
        try mark(model, pane, .promptStart(directory: project))

        checks.result = ScratchpadProcessResult(status: 2, output: "x: line 1: syntax error near unexpected token `fi'\n")
        let failed = await model.runScratchpad()
        XCTAssertFalse(failed)
        XCTAssertEqual(model.scratchpadCheck?.issues, [ScratchpadIssue(line: 1, "syntax error near unexpected token `fi'")])
        XCTAssertEqual(model.scratchpadRunBlocker, "Fix 1 error to run.")
        XCTAssertNil(model.taskRuns[pane])
        XCTAssertFalse(text(model, pane).contains("^E^U"), "Nothing typed")
        model.scratchpad.text = "echo fixed"
        XCTAssertNil(model.scratchpadCheck, "Editing clears a stale result")
        model.scratchpad.text = "echo \u{202E}x"
        let hidden = await model.validateScratchpad()
        XCTAssertEqual(hidden.outcome, .failed)
        XCTAssertEqual(checks.count, 1, "Hidden characters are rejected before any interpreter runs")
    }

    @MainActor
    func testSaveAsTaskWritesTheScriptAndAppendsATaskThatStaysTrusted() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        try mark(model, pane, .promptStart(directory: project))
        model.scratchpad = ScratchpadDocument(name: "deploy", language: .bash, text: "echo one\n")
        let task = await model.saveScratchpadAsTask(name: "Deploy preview", group: .run)
        XCTAssertEqual(task, LaunchTask(name: "Deploy preview", command: "bash .trellis/scratch/deploy.sh", group: .run))
        let script = project + "/.trellis/scratch/deploy.sh"
        XCTAssertEqual(try String(contentsOfFile: script, encoding: .utf8), "echo one\n")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: script)[.posixPermissions] as? Int, 0o644)
        XCTAssertEqual(model.taskCatalog?.tasks, [try XCTUnwrap(task)])
        XCTAssertTrue(launchFile()?.contains(#""command": "bash .trellis/scratch/deploy.sh""#) == true)

        // Saving again updates the script it saved and doesn't add a second task.
        model.scratchpad.text = "echo two\n"
        let again = await model.saveScratchpadAsTask(name: "Other name", group: nil)
        XCTAssertEqual(again?.name, "Deploy preview", "The existing task with the same command")
        XCTAssertEqual(try String(contentsOfFile: script, encoding: .utf8), "echo two\n")
        XCTAssertEqual(model.taskCatalog?.tasks.count, 1)

        // A new file was trusted with the task, so Save & Run runs without review.
        model.scratchpad = ScratchpadDocument(name: "check", language: .javascript, text: "console.log(1)\n")
        await model.saveScratchpadAndRun(name: "check", group: .test)
        XCTAssertNil(model.pendingTaskReview)
        try await typed(model, pane, "\u{05}\u{15}node .trellis/scratch/check.js\r")
        XCTAssertEqual(model.taskRuns[pane]?.name, "check")
    }

    @MainActor
    func testSaveNeverReplacesAnotherScriptAndRestoresTheFileWhenTheTaskCantBeAdded() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        try mark(model, pane, .promptStart(directory: project))
        let folder = project + "/.trellis/scratch"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "teammate\n".write(toFile: folder + "/build.sh", atomically: true, encoding: .utf8)
        model.scratchpad = ScratchpadDocument(name: "build", language: .sh, text: "mine\n")
        let replaced = await model.saveScratchpadAsTask(name: "build", group: nil)
        XCTAssertNil(replaced)
        XCTAssertTrue(model.errorMessage?.contains("already exists") == true)
        XCTAssertEqual(try String(contentsOfFile: folder + "/build.sh", encoding: .utf8), "teammate\n")
        XCTAssertNil(launchFile())

        // launch.json that doesn't parse: nothing is added and the new script is removed again.
        try "{".write(toFile: project + "/.trellis/launch.json", atomically: true, encoding: .utf8)
        model.scratchpad.name = "fresh"
        let invalid = await model.saveScratchpadAsTask(name: "fresh", group: nil)
        XCTAssertNil(invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder + "/fresh.sh"))
        XCTAssertEqual(launchFile(), "{")

        let badName = await model.saveScratchpadAsTask(name: "  ", group: nil)
        XCTAssertNil(badName)
    }

    @MainActor
    func testSaveNeverReplacesAnUnreadableScriptAndCanReplaceEveryScriptItSaved() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        try mark(model, pane, .promptStart(directory: project))
        let folder = project + "/.trellis/scratch"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "secret\n".write(toFile: folder + "/locked.sh", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder + "/locked.sh")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder + "/locked.sh") }
        model.scratchpad = ScratchpadDocument(name: "locked", language: .sh, text: "mine\n")
        let locked = await model.saveScratchpadAsTask(name: "locked", group: nil)
        XCTAssertNil(locked, "A file that can't be read back is never replaced")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder + "/locked.sh")
        XCTAssertEqual(try String(contentsOfFile: folder + "/locked.sh", encoding: .utf8), "secret\n")

        model.scratchpad = ScratchpadDocument(name: "a", language: .sh, text: "a1\n")
        let first = await model.saveScratchpadAsTask(name: "a", group: nil)
        XCTAssertNotNil(first)
        model.scratchpad = ScratchpadDocument(name: "b", language: .sh, text: "b1\n")
        let second = await model.saveScratchpadAsTask(name: "b", group: nil)
        XCTAssertNotNil(second)
        model.scratchpad = ScratchpadDocument(name: "a", language: .sh, text: "a2\n")
        let again = await model.saveScratchpadAsTask(name: "a", group: nil)
        XCTAssertEqual(again?.name, "a", "Any script this scratchpad saved can be replaced, not only the last one")
        XCTAssertEqual(try String(contentsOfFile: folder + "/a.sh", encoding: .utf8), "a2\n")
    }

    @MainActor
    func testEditorRefusesInputBeyond64KBButAllowsShrinking() {
        let limit = ScratchpadDocument.maximumBytes
        XCTAssertFalse(ScratchpadEditor.allowsChange(of: "", in: NSRange(location: 0, length: 0), to: String(repeating: "x", count: limit + 1)), "A paste into an empty editor too")
        XCTAssertTrue(ScratchpadEditor.allowsChange(of: "", in: NSRange(location: 0, length: 0), to: String(repeating: "x", count: limit)))
        let full = String(repeating: "x", count: limit)
        XCTAssertFalse(ScratchpadEditor.allowsChange(of: full, in: NSRange(location: limit, length: 0), to: "é"))
        XCTAssertTrue(ScratchpadEditor.allowsChange(of: full, in: NSRange(location: 0, length: 2), to: "é"), "Replacing two bytes with two")
        let over = String(repeating: "x", count: limit + 10)
        XCTAssertTrue(ScratchpadEditor.allowsChange(of: over, in: NSRange(location: 0, length: 1), to: ""), "Deleting from an oversized buffer")
    }

    @MainActor
    func testReplacingWithShorterTextKeepsASelection() {
        // AppKit raises on an empty selection array: Clear and opening a shorter file used to crash the app.
        let clamp = ScratchpadEditor.Coordinator.clamped
        XCTAssertEqual(clamp([NSRange(location: 40, length: 3)], 0), [NSRange(location: 0, length: 0)])
        XCTAssertEqual(clamp([NSRange(location: 3, length: 9)], 5), [NSRange(location: 3, length: 2)])
        XCTAssertEqual(clamp([], 4), [NSRange(location: 4, length: 0)])
        let textView = NSTextView()
        textView.string = String(repeating: "line\n", count: 20)
        textView.setSelectedRange(NSRange(location: 60, length: 4))
        let selection = textView.selectedRanges.map(\.rangeValue)
        textView.string = ""
        textView.selectedRanges = clamp(selection, 0).map { NSValue(range: $0) }
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    @MainActor
    func testSaveAndRunOfAnUntrustedFileAsksForReview() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        try mark(model, pane, .promptStart(directory: project))
        try FileManager.default.createDirectory(atPath: project + "/.trellis", withIntermediateDirectories: true)
        try #"{"version": 1, "tasks": [{"name": "theirs", "command": "make"}]}"#.write(toFile: project + "/.trellis/launch.json", atomically: true, encoding: .utf8)
        model.scratchpad = ScratchpadDocument(name: "mine", language: .bash, text: "echo mine\n")
        await model.saveScratchpadAndRun(name: "mine", group: nil)
        XCTAssertEqual(model.pendingTaskReview?.taskName, "mine", "Adding never trusts someone else's tasks")
        XCTAssertNil(model.taskRuns[pane])
    }

    @MainActor
    func testToggleFocusesThePaneAndNeverChangesTheWorkspace() async throws {
        let (model, first) = try await makeModel()
        defer { cleanUp(model) }
        let split = await model.splitPane(first, axis: .x, startSession: false)
        let second = try XCTUnwrap(split)
        XCTAssertEqual(model.presentation.activePane?.id, second)
        let before = model.snapshot
        await model.toggleScratchpad()
        XCTAssertTrue(model.scratchpadVisible)
        XCTAssertEqual(model.snapshot, before, "Opening the panel isn't a workspace change")
        await model.toggleScratchpad(paneID: first)
        XCTAssertTrue(model.scratchpadVisible, "Another pane's button keeps the panel open")
        XCTAssertEqual(model.scratchpadPaneID, first)
        await model.toggleScratchpad(paneID: first)
        XCTAssertFalse(model.scratchpadVisible)
        let request = model.scratchpadFocusRequest
        await model.toggleScratchpad()
        XCTAssertEqual(model.scratchpadFocusRequest, request + 1, "Opening focuses the editor")
    }

    @MainActor
    func testSavingNamesTheFileAndClearingTracksUnsavedChanges() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        try mark(model, pane, .promptStart(directory: project))
        XCTAssertFalse(model.scratchpadHasUnsavedChanges, "An empty buffer has nothing to lose")
        model.scratchpad.text = "echo one\n"
        XCTAssertTrue(model.scratchpadHasUnsavedChanges)
        XCTAssertNil(model.scratchpadSaved, "No file name until saved")

        let task = await model.saveScratchpadAsTask(name: "Ship it", scriptName: "ship-it", group: nil)
        XCTAssertEqual(task?.command, "bash .trellis/scratch/ship-it.sh")
        XCTAssertEqual(model.scratchpadSaved?.fileName, "ship-it.sh")
        XCTAssertEqual(model.scratchpad.name, "ship-it")
        XCTAssertFalse(model.scratchpadHasUnsavedChanges)
        model.scratchpad.text = "echo two\n"
        XCTAssertTrue(model.scratchpadHasUnsavedChanges, "Edited since saving")
        model.scratchpad.language = .sh
        model.scratchpad.text = "echo one\n"
        XCTAssertTrue(model.scratchpadHasUnsavedChanges, "A different language is a change")
        model.scratchpad.language = .bash
        XCTAssertFalse(model.scratchpadHasUnsavedChanges)

        let badName = await model.saveScratchpadAsTask(name: "Other", scriptName: "has space", group: nil)
        XCTAssertNil(badName)
        XCTAssertEqual(model.scratchpadSaved?.fileName, "ship-it.sh", "A failed save keeps the saved state")

        model.scratchpad.language = .javascript
        model.clearScratchpad()
        XCTAssertEqual(model.scratchpad, ScratchpadDocument(language: .javascript), "A new buffer in the same language")
        XCTAssertNil(model.scratchpadSaved)
        XCTAssertNil(model.scratchpadCheck)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project + "/.trellis/scratch/ship-it.sh"), "The saved script and task stay")
        XCTAssertEqual(model.taskCatalog?.tasks.map(\.name), ["Ship it"])
    }

    @MainActor
    func testTheSelectorListsSavedScratchpadsAndOpensThem() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        try mark(model, pane, .promptStart(directory: project))
        await model.refreshScratchpadFiles()
        XCTAssertEqual(model.scratchpadFiles, ScratchpadFileList(root: project, files: []))
        let folder = project + "/.trellis/scratch"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "#!/bin/sh\necho old\n".write(toFile: folder + "/build.sh", atomically: true, encoding: .utf8)
        try "console.log(1)\n".write(toFile: folder + "/check.js", atomically: true, encoding: .utf8)
        try "# Notes\n".write(toFile: folder + "/Notes 2.md", atomically: true, encoding: .utf8)
        try "x".write(toFile: folder + "/tool.py", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: folder + "/linked.sh", withDestinationPath: "/etc/hosts")
        await model.refreshScratchpadFiles()
        XCTAssertEqual(model.scratchpadFiles?.files, ["build.sh", "check.js"], "Only scripts it could have saved; no links")

        let opened = await model.openScratchpadFile("build.sh")
        XCTAssertTrue(opened)
        XCTAssertEqual(model.scratchpad, ScratchpadDocument(name: "build", language: .sh, text: "#!/bin/sh\necho old\n"))
        XCTAssertEqual(model.scratchpadSaved?.fileName, "build.sh")
        XCTAssertFalse(model.scratchpadHasUnsavedChanges)
        model.scratchpad.text += "echo new\n"
        let task = await model.saveScratchpadAsTask(name: "build", group: .build)
        XCTAssertEqual(task?.command, "sh .trellis/scratch/build.sh", "An opened script can be saved over")
        XCTAssertEqual(try String(contentsOfFile: folder + "/build.sh", encoding: .utf8), "#!/bin/sh\necho old\necho new\n")

        let link = await model.openScratchpadFile("linked.sh")
        XCTAssertFalse(link, "Links are never read")
        let missing = await model.openScratchpadFile("gone.sh")
        XCTAssertFalse(missing)
        XCTAssertEqual(model.scratchpadSaved?.fileName, "build.sh", "A failed open keeps the buffer")
    }

    @MainActor
    func testMarkdownIsSavedAsAFileWithoutATaskAndNeverRuns() async throws {
        let checks = Checks()
        let (model, pane) = try await makeModel(checks: checks)
        defer { cleanUp(model) }
        try mark(model, pane, .promptStart(directory: project))
        model.scratchpad = ScratchpadDocument(language: .markdown, text: "# Plan\n- ship 👨\u{200D}👩\u{200D}👧\n")
        XCTAssertEqual(model.scratchpadRunBlocker, "Markdown isn't run.")
        let ran = await model.runScratchpad()
        XCTAssertFalse(ran)
        XCTAssertEqual(checks.count, 0)
        let asTask = await model.saveScratchpadAsTask(name: "plan", group: nil)
        XCTAssertNil(asTask)
        let saved = await model.saveScratchpadFile(scriptName: "plan")
        XCTAssertTrue(saved)
        XCTAssertEqual(try String(contentsOfFile: project + "/.trellis/scratch/plan.md", encoding: .utf8), model.scratchpad.text)
        XCTAssertNil(launchFile(), "No task for notes")
        XCTAssertEqual(model.scratchpadSaved?.fileName, "plan.md")
        XCTAssertEqual(model.scratchpadFiles?.files, ["plan.md"])
    }

    @MainActor
    func testSavingOutsideAProjectCreatesTheScratchFolderThere() async throws {
        let plain = scratch.appendingPathComponent("plain").path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let (model, pane) = try await makeModel(directory: plain)
        defer { cleanUp(model) }
        try mark(model, pane, .promptStart(directory: plain))
        await model.refreshScratchpadFiles()
        XCTAssertNil(model.scratchpadFiles, "Not a project yet")
        model.scratchpad = ScratchpadDocument(language: .bash, text: "echo hi\n")
        let task = await model.saveScratchpadAsTask(name: "hi", scriptName: "hi", group: nil)
        XCTAssertEqual(task?.command, "bash .trellis/scratch/hi.sh")
        XCTAssertEqual(try String(contentsOfFile: plain + "/.trellis/scratch/hi.sh", encoding: .utf8), "echo hi\n")
        XCTAssertTrue((try? String(contentsOfFile: plain + "/.trellis/launch.json", encoding: .utf8))?.contains("hi.sh") == true)
        XCTAssertEqual(model.scratchpadFiles, ScratchpadFileList(root: plain, files: ["hi.sh"]), "The folder is a project now")
    }
}
