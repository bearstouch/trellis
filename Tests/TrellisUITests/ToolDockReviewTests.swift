import AppKit
import Combine
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// Review-driven checks of the tool dock: Insert Path's control characters, automation closes, Edited marks and
/// Open in Default App (FR-TD10, FR-TD14, FR-TD15).
final class ToolDockReviewTests: XCTestCase {
    private var scratch: URL!
    private var project: String!
    private var shell: String!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-tdr-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
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

    @MainActor
    private func makeModel() async throws -> (AppWorkspaceModel, UUID) {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-tdr-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch.appendingPathComponent("state")))
        _ = await model.loadWorkspace()
        model.confirmCloseSessions = { _ in true }
        model.confirmUnsavedEdits = { _ in
            XCTFail("Unexpected unsaved-edits prompt"); return .cancel
        }
        model.editorFileWatcher = { _, _ in nil }
        let saved = await model.saveLaunchSettings(shell: shell, directory: project)
        XCTAssertTrue(saved)
        _ = await model.createWindow(name: "W")
        let pane = try XCTUnwrap(model.presentation.activePane?.id)
        let deadline = Date().addingTimeInterval(5)
        while !text(model, pane).contains("SHELL-UP"), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try XCTUnwrap(model.terminals[pane]).onShellIntegrationEvent?(.promptStart(directory: project))
        return (model, pane)
    }

    @MainActor
    private func cleanUp(_ model: AppWorkspaceModel) {
        model.terminals.values.forEach {
            $0.requestTermination(force: true); $0.adapter.detach()
        }
    }

    @MainActor
    private func text(_ model: AppWorkspaceModel, _ pane: UUID) -> String { (try? model.terminals[pane]?.adapter.read(.retainedText)) ?? "" }

    @MainActor
    func testInsertPathNeverTypesAPathWithControlCharacters() async throws {
        let (model, pane) = try await makeModel()
        defer { cleanUp(model) }
        XCTAssertNil(model.insertPathBlockedReason)
        // Typed, Ctrl-U would erase the opening quote and Return would run what follows.
        XCTAssertFalse(model.insertPath(project + "/a\u{15}touch pwned\r.swift"))
        XCTAssertNotNil(model.errorMessage)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(text(model, pane).contains("pwned"), "Nothing was typed")
    }

    @MainActor
    func testAutomationCantCloseATabWhoseDockHasUnsavedEdits() async throws {
        let (model, _) = try await makeModel()
        defer { cleanUp(model) }
        let tab = try XCTUnwrap(model.presentation.selectedTab?.id)
        let path = project + "/notes.md"
        try "# Notes\n".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(model.openFileInToolDock(path))
        try XCTUnwrap(model.buffer(tab, path)).text = "# Notes\nmine\n"
        do {
            _ = try await model.automationClose(.deleteTab(id: tab), allowRunning: true, force: false)
            XCTFail("The close went through")
        } catch {
            guard case .store(.invalidState(let reason)) = error else { return XCTFail("\(error)") }
            XCTAssertFalse(reason.contains("notes.md"), "File names stay private (FR-TD16)")
        }
        XCTAssertNotNil(model.snapshot.tabs[tab], "Nothing closed")
        XCTAssertEqual(model.buffer(tab, path)?.text, "# Notes\nmine\n")
        XCTAssertNotNil(model.terminals.values.first(where: \.isRunning), "No session was signalled")
        // Once saved, the edits no longer stop it: the usual running-session rule applies.
        XCTAssertTrue(model.saveFile(path, tabID: tab))
        let outcome = try await model.automationClose(.deleteTab(id: tab), allowRunning: false, force: false)
        guard case .confirmationRequired = outcome else { return XCTFail("\(outcome)") }
    }

    @MainActor
    func testTheModelPublishesWhenABufferBecomesEditedOrSaved() async throws {
        let (model, _) = try await makeModel()
        defer { cleanUp(model) }
        let tab = try XCTUnwrap(model.presentation.selectedTab?.id)
        let path = project + "/a.txt"
        try "a\n".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(model.openFileInToolDock(path))
        let buffer = try XCTUnwrap(model.buffer(tab, path))
        var published = 0
        let subscription = model.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }
        buffer.text = "ab\n"
        XCTAssertEqual(published, 1, "The rail and the tree mark Edited as soon as the buffer is")
        buffer.text = "abc\n"
        XCTAssertEqual(published, 1, "Typing more doesn't re-render the workspace")
        XCTAssertTrue(model.saveFile(path, tabID: tab))
        XCTAssertGreaterThanOrEqual(published, 2, "Saving clears the marks")
    }

    func testOpenInDefaultAppRevealsExecutablesAndLeavesNetworkPathsAlone() throws {
        let binary = project + "/tool"
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0]).write(to: URL(fileURLWithPath: binary))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)
        guard case .reveal = AppWorkspaceModel.defaultAppAction(for: binary) else { return XCTFail("An executable must never be opened (FR-L03)") }
        let image = project + "/logo.png"
        try Data([0x89, 0x50, 0x00]).write(to: URL(fileURLWithPath: image))
        guard case .open = AppWorkspaceModel.defaultAppAction(for: image) else { return XCTFail("A document opens in its app") }
        XCTAssertNil(AppWorkspaceModel.defaultAppAction(for: "/net/host/file.bin"), "FR-L04")
        XCTAssertNil(AppWorkspaceModel.defaultAppAction(for: "/Network/Servers/x/file.bin"), "FR-L04")
    }
}
