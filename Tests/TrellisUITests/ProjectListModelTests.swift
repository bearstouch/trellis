import Foundation
import TrellisBroker
import TrellisControl
import TrellisCore
import XCTest

@testable import TrellisUI

/// The project library's view model (FR-PL01–FR-PL05): search, saving new and stored projects, import and capture.
@MainActor
final class ProjectListModelTests: XCTestCase {
    private func model() throws -> ProjectListModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-plm-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ProjectListModel(library: ProjectLibrary(storage: ProjectFileStorage(directory: directory)))
    }

    func testSavingCreatesThenUpdatesAndSearchMatchesRepositories() async throws {
        let model = try model()
        await model.load()
        var project = ProjectDefinition(name: "Shop", tabs: [ProjectTab(title: "API", directory: "api", repository: ProjectRepository(url: "git@github.com:acme/api.git"))])
        guard case .success(let created) = await model.save(project) else { return XCTFail("Not created") }
        XCTAssertNotEqual(created.id, project.id, "A new project gets the library's identity")
        project = created
        project.name = "Shop 2"
        guard case .success(let updated) = await model.save(project) else { return XCTFail("Not updated") }
        XCTAssertEqual(model.projects, [updated])
        let stale = await model.save(project)
        XCTAssertEqual(stale.failure, .conflict, "A second save from the old revision is refused")

        model.query = "acme/api"
        XCTAssertEqual(model.visibleProjects.map(\.id), [updated.id])
        model.query = "nothing"
        XCTAssertTrue(model.visibleProjects.isEmpty)
        XCTAssertEqual(model.summary(updated), "1 tab · 1 repository")
        XCTAssertNil(model.lastLaunched(updated))
        await model.recordLaunch(updated.id, target: .local, folder: "/tmp/shop")
        XCTAssertEqual(model.projects.first.flatMap(model.lastLaunched), "Last: This Mac")
        let deleted = await model.delete(updated)
        XCTAssertNil(deleted, "The stored revision didn't change, so deleting still matches")
        XCTAssertTrue(model.projects.isEmpty)
    }

    func testAnExportedProjectImportsBackWithoutItsHistory() throws {
        let model = try model()
        let project = ProjectDefinition(
            name: "My/Shop", tabs: [ProjectTab(title: "API", directory: "api", repository: ProjectRepository(url: "git@github.com:acme/api.git"))],
            lastFolders: ["local": "/Users/me/private"])
        let data = model.exportJSON(project)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private"), "Where it was launched stays on this Mac")
        XCTAssertEqual(try model.importJSON(data).get().tabs, project.tabs)
        XCTAssertEqual(ProjectListModel.exportFileName(project), "My-Shop.json")
    }

    func testImportReadsOnlyValidProjects() throws {
        let model = try model()
        XCTAssertNotNil(try? model.importJSON(Data(#"{"name":"P","tabs":[{"title":"T","root":{"type":"pane","command":"ls"}}]}"#.utf8)).get())
        guard case .failure(let error) = model.importJSON(Data(#"{"name":"P","tabs":[]}"#.utf8)) else { return XCTFail("An empty project was accepted") }
        XCTAssertFalse(error.problems.isEmpty)
    }

    func testTheCloseFlowRequestsASaveOrADiscardFromTheEditor() throws {
        let model = try model()
        var closed = 0
        model.editorDirty = true
        model.requestSave { closed += 1 }
        XCTAssertEqual(model.saveRequests, 1)
        model.takeAfterRequestedSave()?()
        XCTAssertEqual(closed, 1)
        XCTAssertNil(model.takeAfterRequestedSave(), "The close runs once, after the save it was asked with")
        model.discardEditor()
        XCTAssertEqual(model.discardRequests, 1)
        XCTAssertFalse(model.editorDirty, "Discarding lets the window close and reopen clean")
    }
}

extension Result {
    fileprivate var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

/// The pane header's git status (FR-PL09): text and symbols, and words for VoiceOver.
final class GitStatusTextTests: XCTestCase {
    func testStatusReadsAsTextAndSpeech() {
        let busy = BrokerGitStatus(branch: "main", commit: nil, changes: 2, ahead: 1, behind: 3)
        XCTAssertEqual(AppWorkspaceModel.gitStatusText(busy), "main ●2 ↑1 ↓3")
        XCTAssertEqual(AppWorkspaceModel.gitStatusSpoken(busy), "Git branch main, 2 changes, 1 ahead, 3 behind")
        let detached = BrokerGitStatus(branch: nil, commit: "89abcde", changes: 1, ahead: 0, behind: 0)
        XCTAssertEqual(AppWorkspaceModel.gitStatusText(detached), "(89abcde) ●1")
        XCTAssertEqual(AppWorkspaceModel.gitStatusSpoken(detached), "Git commit 89abcde, detached, 1 change")
    }
}

/// When pane headers look at git (FR-PL09): at each prompt, in the directory that prompt reports, never for a closed pane.
final class GitStatusRefreshTests: XCTestCase {
    private final class Runs: @unchecked Sendable {
        private let lock = NSLock()
        private var folders: [String] = []
        func record(_ folder: String) { lock.withLock { folders.append(folder) } }
        var all: [String] { lock.withLock { folders } }
    }

    @MainActor
    func testThePromptsDirectoryIsLookedAtAndAFolderOutsideAWorkTreeClearsTheStatus() async throws {
        let h = try Harness()
        let runs = Runs()
        h.model.gitStatusEnabled = true
        h.model.gitStatusRunner = { folder in
            runs.record(folder)
            return folder == "/repo" ? BrokerGitStatus(branch: "main", commit: nil, changes: 1, ahead: 0, behind: 0) : nil
        }
        let created = await h.model.createWindow(name: "W", startSession: false)
        _ = try XCTUnwrap(created)
        let pane = try XCTUnwrap(h.model.presentation.activePane?.id)
        _ = try await h.model.service.execute(.configureStoppedSession(paneID: pane, launch: .process(executable: "/bin/sleep", arguments: ["30"], directory: "/tmp")))
        await h.model.refresh()
        await h.model.start(paneID: pane)
        defer {
            h.model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        let terminal = try XCTUnwrap(h.model.terminals[pane])

        terminal.onShellIntegrationEvent?(.promptStart(directory: "/repo"))
        for _ in 0..<200 where h.model.gitStatuses[pane] == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runs.all.first, "/repo", "The directory the prompt just reported, not the one before it")
        XCTAssertEqual(h.model.gitStatuses[pane]?.branch, "main")

        terminal.onShellIntegrationEvent?(.promptStart(directory: "/elsewhere"))
        for _ in 0..<200 where h.model.gitStatuses[pane] != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(h.model.gitStatuses[pane])
        XCTAssertEqual(runs.all.last, "/elsewhere")
    }
}
