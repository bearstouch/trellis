import AppKit
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// Editor tabs (FR-ED01, FR-ED04–FR-ED09, FR-ED11) at the model level: a real shell pane in a temporary project, with apps
/// and alerts injected so nothing outside the test is touched.
final class EditorTabTests: XCTestCase {
    private var scratch: URL!
    private var project: String!
    private var shell: String!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-et-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let manager = FileManager.default
        project = scratch.appendingPathComponent("project").path
        for folder in ["bin", "state", "project/.git", "project/Sources", "project/lib", "other"] {
            try manager.createDirectory(at: scratch.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try "# Read me\n".write(toFile: project + "/README.md", atomically: true, encoding: .utf8)
        try "let a = 1\nlet b = 2\nlet c = 3\n".write(toFile: project + "/Sources/App.swift", atomically: true, encoding: .utf8)
        try "x\n".write(toFile: project + "/lib/App.swift", atomically: true, encoding: .utf8)
        try "outside\n".write(toFile: scratch.appendingPathComponent("other/x.txt").path, atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: URL(fileURLWithPath: project + "/logo.png"))
        shell = scratch.appendingPathComponent("bin/sh").path
        try "#!/bin/sh\nprintf 'SHELL-UP\\n'\nexec /bin/cat\n".write(toFile: shell, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private final class Recorder: @unchecked Sendable {
        var opened: [(URL, URL?)] = []
        var asked: [[String]] = []
        var answer = UnsavedEditorsChoice.cancel
        var overwrite = false
    }

    @MainActor
    private func makeModel() async throws -> (AppWorkspaceModel, UUID, Recorder) {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-et-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        model.confirmCloseSessions = { _ in true }
        model.workspaceIsFrontmost = { true }
        let recorder = Recorder()
        model.openFileInApp = { recorder.opened.append(($0, $1)) }
        model.revealFiles = { _ in }
        model.confirmUnsavedEditors = {
            recorder.asked.append($0); return recorder.answer
        }
        model.confirmOverwriteChangedFile = { _ in recorder.overwrite }
        let saved = await model.saveLaunchSettings(shell: shell, directory: project + "/Sources")
        XCTAssertTrue(saved)
        _ = await model.createSpace(name: "W")
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        try await waitFor { ((try? model.terminals[pane]?.adapter.read(.retainedText)) ?? "").contains("SHELL-UP") }
        return (model, pane, recorder)
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
    func testOpeningAddsAnEditorTabAndReusesIt() async throws {
        let (model, _, _) = try await makeModel()
        defer { cleanUp(model) }
        let tabs = model.snapshot.tabs.count
        let openedFirst = await model.openInEditor(path: project + "/Sources/App.swift", projectRoot: project)
        XCTAssertTrue(openedFirst)
        let first = try XCTUnwrap(model.shownEditor)
        XCTAssertEqual(first.text, "let a = 1\nlet b = 2\nlet c = 3\n")
        XCTAssertEqual(first.language.id, "swift")
        XCTAssertEqual(first.displayPath, "Sources/App.swift")
        XCTAssertEqual(model.snapshot.tabs.count, tabs, "An editor tab is not a workspace tab (FR-ED08)")
        XCTAssertTrue(model.editorVisible)

        await model.openInEditor(path: project + "/Sources/App.swift", line: 3)
        XCTAssertEqual(model.currentEditors.count, 1, "The same file focuses its tab")
        XCTAssertEqual(model.shownEditor?.jump?.line, 3)

        await model.openInEditor(path: project + "/README.md")
        await model.openInEditor(path: project + "/lib/App.swift")
        XCTAssertEqual(model.currentEditors.map(\.fileName), ["App.swift", "README.md", "App.swift"], "A new tab opens after the shown one")
        XCTAssertEqual(model.editorTitle(model.currentEditors[0]), "App.swift — Sources", "Two files with one name show their folder")
        XCTAssertEqual(model.editorTitle(model.currentEditors[1]), "README.md")
    }

    @MainActor
    func testTabsSwitchBetweenTerminalsAndEditorsAndReviewStaysApart() async throws {
        let (model, _, _) = try await makeModel()
        defer { cleanUp(model) }
        await model.openInEditor(path: project + "/README.md")
        let editor = try XCTUnwrap(model.shownEditor?.id)
        let terminalTab = try XCTUnwrap(model.presentation.selectedTab?.id)
        await model.selectTab(terminalTab)
        XCTAssertNil(model.shownEditor, "Selecting a space tab shows the terminals")
        XCTAssertEqual(model.currentEditors.count, 1, "…and keeps the editor tab")
        await model.selectAdjacentTab(1)
        XCTAssertEqual(model.shownEditor?.id, editor, "Next tab moves from the space's tabs to its editor tabs")
        await model.selectAdjacentTab(1)
        XCTAssertNil(model.shownEditor, "…and around")
        model.selectEditor(editor)
        model.revealTerminalsForPaneAction(.splitLeftRight)
        XCTAssertNil(model.shownEditor, "A pane command shows the pane it acts on")
        model.selectEditor(editor)
        model.revealTerminalsForPaneAction(.findInPane)
        XCTAssertEqual(model.shownEditor?.id, editor, "Find searches the editor instead")
        await model.createTab()
        XCTAssertNil(model.shownEditor, "A new tab is shown")
    }

    @MainActor
    func testSavingWritesTheFileAndAFailureKeepsTheText() async throws {
        let (model, _, _) = try await makeModel()
        defer { cleanUp(model) }
        let path = project + "/Sources/App.swift"
        await model.openInEditor(path: path)
        let id = try XCTUnwrap(model.shownEditor?.id)
        model.updateEditorText(id, "let a = 10\n")
        XCTAssertTrue(try XCTUnwrap(model.shownEditor).isDirty)
        XCTAssertTrue(model.hasUnsavedEditors)
        let savedFirst = await model.saveEditor(id)
        XCTAssertTrue(savedFirst)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "let a = 10\n")
        XCTAssertFalse(try XCTUnwrap(model.shownEditor).isDirty)

        var failing = EditorFileSystem.live
        failing.write = { _, _ in throw EditorFileError.writeFailed("read-only volume") }
        model.editorFileSystem = failing
        model.updateEditorText(id, "let a = 11\n")
        let savedFailing = await model.saveEditor(id)
        XCTAssertFalse(savedFailing)
        XCTAssertEqual(model.shownEditor?.text, "let a = 11\n", "The text stays")
        XCTAssertTrue(try XCTUnwrap(model.shownEditor).isDirty, "…and so does the unsaved mark")
        guard case .saveFailed? = model.shownEditor?.banner else { return XCTFail("The failure is shown") }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "let a = 10\n", "The file is as it was")
    }

    @MainActor
    func testClosingAnUnsavedTabAsksFirst() async throws {
        let (model, _, recorder) = try await makeModel()
        defer { cleanUp(model) }
        let path = project + "/README.md"
        await model.openInEditor(path: path)
        let id = try XCTUnwrap(model.shownEditor?.id)
        await model.closeEditor(id)
        XCTAssertTrue(model.currentEditors.isEmpty, "A clean tab closes without asking")
        XCTAssertEqual(recorder.asked, [])

        await model.openInEditor(path: path)
        let dirty = try XCTUnwrap(model.shownEditor?.id)
        model.updateEditorText(dirty, "# Changed\n")
        recorder.answer = .cancel
        await model.closeEditor(dirty)
        XCTAssertEqual(recorder.asked, [["README.md"]])
        XCTAssertEqual(model.currentEditors.count, 1, "Cancel keeps it")
        recorder.answer = .save
        await model.closeEditor(dirty)
        XCTAssertTrue(model.currentEditors.isEmpty)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "# Changed\n", "Save writes before closing")

        await model.openInEditor(path: path)
        let discarded = try XCTUnwrap(model.shownEditor?.id)
        model.updateEditorText(discarded, "# Lost\n")
        recorder.answer = .discard
        await model.closeEditor(discarded)
        XCTAssertTrue(model.currentEditors.isEmpty)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "# Changed\n", "Don't Save leaves the file")
    }

    @MainActor
    func testClosingASpaceAsksAboutItsUnsavedEditorsAndTheyAreNeverSaved() async throws {
        let (model, _, recorder) = try await makeModel()
        defer { cleanUp(model) }
        await model.openInEditor(path: project + "/README.md")
        let id = try XCTUnwrap(model.shownEditor?.id)
        model.updateEditorText(id, "# Draft\n")
        _ = await model.flushWorkspaceSave()
        let saved = try String(contentsOf: scratch.appendingPathComponent("state").appendingPathComponent("workspace.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains("README.md"), "Editor tabs are never in the saved workspace (FR-ED08)")

        let space = try XCTUnwrap(model.presentation.selectedSpace?.id)
        recorder.answer = .cancel
        await model.deleteSpace(space)
        XCTAssertTrue(model.snapshot.spaces.contains { $0.id == space }, "Cancel keeps the space")
        XCTAssertEqual(model.currentEditors.count, 1)
        recorder.answer = .discard
        await model.deleteSpace(space)
        XCTAssertFalse(model.snapshot.spaces.contains { $0.id == space })
        XCTAssertTrue(model.editorTabs.isEmpty, "Its editor tabs close with it")
        XCTAssertEqual(try String(contentsOfFile: project + "/README.md", encoding: .utf8), "# Read me\n")
    }

    @MainActor
    func testFilesOpensTextInTheEditorAndHandsOtherFilesToTheDefaultApp() async throws {
        let (model, pane, recorder) = try await makeModel()
        defer { cleanUp(model) }
        await model.refreshFiles(paneID: pane)
        XCTAssertEqual(model.files.editor, .trellisEditor, "The default (FR-ED09)")
        await model.openFile(FileEntry(path: project + "/README.md", isDirectory: false))
        XCTAssertEqual(model.shownEditor?.fileName, "README.md")
        XCTAssertEqual(model.shownEditor?.displayPath, "README.md", "Shown below the project")

        await model.openFile(FileEntry(path: project + "/logo.png", isDirectory: false))
        XCTAssertEqual(recorder.opened.map(\.0.path), [project + "/logo.png"], "A binary file goes to the default app")
        XCTAssertEqual(model.currentEditors.count, 1)
        XCTAssertNotNil(model.errorMessage, "…saying why")
        XCTAssertEqual(model.files.editor, .trellisEditor, "The fallback isn't remembered")
    }

    @MainActor
    func testDiskChangesReloadACleanTabAndWarnAnEditedOne() async throws {
        let (model, _, recorder) = try await makeModel()
        defer { cleanUp(model) }
        let path = project + "/README.md"
        await model.openInEditor(path: path)
        let id = try XCTUnwrap(model.shownEditor?.id)
        try await Task.sleep(for: .milliseconds(20))
        try "# Elsewhere\n".write(toFile: path, atomically: true, encoding: .utf8)
        model.checkEditorOnDisk(id)
        try await waitFor { model.shownEditor?.text == "# Elsewhere\n" }
        XCTAssertEqual(model.shownEditor?.text, "# Elsewhere\n", "A clean tab reloads quietly")

        model.updateEditorText(id, "# Mine\n")
        try "# Theirs, longer\n".write(toFile: path, atomically: true, encoding: .utf8)
        model.checkEditorOnDisk(id)
        try await waitFor { model.shownEditor?.banner != nil }
        XCTAssertEqual(model.shownEditor?.banner, .changedOnDisk)
        XCTAssertEqual(model.shownEditor?.text, "# Mine\n", "Unsaved text is never replaced")
        recorder.overwrite = false
        let refused = await model.saveEditor(id)
        XCTAssertFalse(refused, "Saving over the change asks first")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "# Theirs, longer\n")
        model.keepEditorChanges(id)
        XCTAssertNil(model.shownEditor?.banner)
        let kept = await model.saveEditor(id)
        XCTAssertTrue(kept, "Keep Mine accepts the change on disk")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "# Mine\n")

        try FileManager.default.removeItem(atPath: path)
        model.checkEditorOnDisk(id)
        try await waitFor { model.shownEditor?.banner != nil }
        XCTAssertEqual(model.shownEditor?.banner, .deleted)
    }

    @MainActor
    func testTerminalLinksOpenProjectFilesAtTheirLine() async throws {
        let (model, pane, _) = try await makeModel()
        defer { cleanUp(model) }
        let context = try XCTUnwrap(model.fileLinkContext(paneID: pane))
        XCTAssertEqual(context.projectRoot, project, "The pane's project, as Files roots it")
        let opened = await model.openLinkInEditor(paneID: pane, path: project + "/Sources/App.swift", line: 2, column: 5)
        XCTAssertTrue(opened)
        XCTAssertEqual(model.shownEditor?.jump?.line, 2)
        XCTAssertEqual(model.shownEditor?.jump?.column, 5)
        let outside = await model.openLinkInEditor(paneID: pane, path: scratch.appendingPathComponent("other/x.txt").path, line: nil, column: nil)
        XCTAssertFalse(outside, "Outside the project, the link opens as before")
        XCTAssertEqual(model.currentEditors.count, 1)
    }

    @MainActor
    func testTheEditorFollowsTheTheme() async throws {
        let (model, _, _) = try await makeModel()
        defer { cleanUp(model) }
        let dracula = try XCTUnwrap(model.allThemes.first { $0.id == "trellis-dracula-dark" })
        // The committed theme as resolved for this Mac's appearance.
        model.previewThemeInWorkspace(try ThemeValidator.validate(dracula.encoded()))
        model.cancelThemePreview()
        let before = model.effectiveTheme.terminal
        model.previewThemeInWorkspace(try ThemeValidator.validate(dracula.encoded()))
        let previewed = model.effectiveTheme.terminal
        XCTAssertNotEqual(previewed, before, "The palette the editor is given follows the preview")
        XCTAssertEqual(ScratchpadEditor.Coordinator.color(.keyword, palette: previewed), NSColor(rgb: previewed.ansi[5]), "Syntax colors are the theme's")
        XCTAssertEqual(ScratchpadEditor.Coordinator.color(.type, palette: previewed), NSColor(rgb: previewed.ansi[12]))
        model.cancelThemePreview()
        XCTAssertEqual(model.effectiveTheme.terminal, before, "Cancel restores exactly")
    }

    @MainActor
    func testASpaceClosedByAutomationHandsItsUnsavedEditorsOn() async throws {
        let (model, _, recorder) = try await makeModel()
        defer { cleanUp(model) }
        let first = try XCTUnwrap(model.presentation.selectedSpace?.id)
        await model.openInEditor(path: project + "/README.md")
        let id = try XCTUnwrap(model.shownEditor?.id)
        model.updateEditorText(id, "# Unsaved\n")
        await model.openInEditor(path: project + "/Sources/App.swift")
        _ = await model.createSpace(name: "Second")
        let second = try XCTUnwrap(model.presentation.selectedSpace?.id)
        XCTAssertNotEqual(first, second)
        // The space goes away without Trellis asking, as when automation closes it: only the workspace change is seen.
        var next = model.snapshot
        next.spaces.removeAll { $0.id == first }
        model.pruneEditors(previous: model.snapshot, next: next)
        XCTAssertEqual(recorder.asked, [], "Nothing is asked")
        XCTAssertEqual(model.editorTabs[second]?.map(\.fileName), ["README.md"], "The unsaved tab moves to the selected space; the clean one closes")
        XCTAssertEqual(model.editorTabs[second]?.first?.text, "# Unsaved\n")
        XCTAssertNil(model.editorTabs[first])
    }
}
