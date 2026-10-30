import Foundation
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
