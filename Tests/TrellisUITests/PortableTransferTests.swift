import AppKit
import XCTest
import TrellisControl
import TrellisCore
@testable import TrellisUI

/// FR-R02 / INT-09 / FR-PL05: File → Export/Import Projects & Hosts.
final class PortableTransferTests: XCTestCase {
    /// Every key a portable export's top level and host entries may contain.
    static let topLevelKeys: Set<String> = ["format", "version", "hosts", "projects"]
    static let hostKeys: Set<String> = ["name", "destination", "user", "port", "identityFile", "tags"]

    @MainActor
    private func library(at directory: URL? = nil) -> ProjectListModel {
        let directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("trellis-pt-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ProjectListModel(library: ProjectLibrary(storage: ProjectFileStorage(directory: directory)))
    }

    private func document(version: Int = 2, hosts: [[String: Any]] = [], projects: [[String: Any]] = [], layout: [String: Any]? = nil) throws -> Data {
        var object: [String: Any] = ["format": "trellis.portable", "version": version, "hosts": hosts, "projects": projects]
        if let layout { object["layout"] = layout }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static var project: [String: Any] { ["name": "Shop", "tabs": [["title": "API", "root": ["type": "pane"]]]] }

    @MainActor
    func testExportHoldsOnlyProjectsAndHostsAndNothingSensitive() async throws {
        let h = try Harness()
        defer { h.discardPreferences() }
        let host = try await h.hosts.library.create(HostDraft(name: "Prod", destination: "prod", user: "deploy", port: "2222"))
        await h.hosts.load()
        let created = await h.model.createSpace(name: "SECRET-SPACE", startSession: false)
        let space = try XCTUnwrap(created)
        let projects = library()
        await projects.load()
        guard case .success(let saved) = await projects.save(ProjectDefinition(name: "Shop", tabs: [ProjectTab(title: "API", root: .pane(ProjectPane(command: "make dev")))]))
        else { return XCTFail("Not saved") }
        await projects.recordLaunch(saved.id, target: .local, folder: "/Users/me/secret-place")

        let data = await PortableTransfer(hosts: h.hosts, projects: projects).exportData()
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in [host.id.uuidString, space.uuidString, saved.id.uuidString, "SECRET-SPACE", "secret-place", "trl_"] {
            XCTAssertFalse(text.contains(forbidden), "Export contains \(forbidden)")
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Self.topLevelKeys, "Spaces are not exported")
        XCTAssertEqual(object["version"] as? Int, 2)
        let hostEntries = try XCTUnwrap(object["hosts"] as? [[String: Any]])
        XCTAssertTrue(hostEntries.allSatisfy { Set($0.keys).isSubset(of: Self.hostKeys) }, "Hosts carry no IDs, passwords, or revisions")
        XCTAssertTrue(text.contains("deploy") && text.contains("2222") && text.contains("make dev"), "Portable host and project metadata is kept")

        guard case .success(let (_, preview)) = await PortableTransfer(hosts: h.hosts).preview(data) else { return XCTFail("Export does not parse") }
        XCTAssertEqual(preview.errors, [])
        XCTAssertEqual([preview.projects, preview.hosts, preview.skippedSpaces], [1, 1, 0])
    }

    /// Files from before the rename (version 1) still import their hosts and projects; their windows are skipped and
    /// counted, never turned into spaces.
    @MainActor
    func testAVersionOneExportImportsHostsAndProjectsAndSkipsItsWindows() async throws {
        let h = try Harness()
        defer { h.discardPreferences() }
        let projects = library()
        await projects.load()
        let transfer = PortableTransfer(hosts: h.hosts, projects: projects)
        let reference = UUID().uuidString
        let pane: [String: Any] = ["type": "pane", "key": "p", "launch": ["kind": "host", "hostId": reference]]
        let windows: [String: Any] = [
            "version": 1,
            "windows": [
                ["key": "w1", "name": "One", "tabs": [["key": "t1", "title": "Main", "root": pane]]], ["key": "w2", "name": "Two", "remoteHostId": reference, "tabs": []]
            ]
        ]
        let old = try document(version: 1, hosts: [["id": reference, "name": "Lab", "destination": "lab"]], projects: [Self.project], layout: windows)
        guard case .success(let (parsed, preview)) = await transfer.preview(old) else { return XCTFail("Preview failed") }
        XCTAssertEqual([preview.hosts, preview.projects, preview.skippedSpaces], [1, 1, 2])
        guard case .success(let summary) = await transfer.commit(parsed, policy: nil) else { return XCTFail("Import failed") }
        XCTAssertEqual([summary.hostsCreated, summary.projectsCreated, summary.skippedSpaces], [1, 1, 2])
        XCTAssertTrue(h.model.snapshot.spaces.isEmpty, "No space was opened")
        let hosts = await h.hosts.library.hosts
        XCTAssertEqual(hosts.map(\.name), ["Lab"])
        XCTAssertNotEqual(hosts.first?.id.uuidString, reference, "Hosts get this Mac's own IDs")

        // A version 1 file is still checked whole: a malformed layout is refused, not half-read.
        let broken = try document(version: 1, hosts: [], layout: ["version": 1, "windows": "nope"])
        guard case .failure = await transfer.preview(broken) else { return XCTFail("Accepted a malformed version 1 layout") }
        // Version 2 has no layout.
        let mixed = try document(version: 2, layout: ["version": 2, "spaces": []])
        guard case .failure(let error) = await transfer.preview(mixed) else { return XCTFail("Accepted a layout in version 2") }
        XCTAssertTrue(error.message.contains("layout"))
    }

    @MainActor
    func testHostCollisionNeedsPolicy() async throws {
        let h = try Harness()
        defer { h.discardPreferences() }
        let existing = try await h.hosts.library.create(HostDraft(name: "Prod", destination: "prod", user: "ops"))
        await h.hosts.load()
        let transfer = PortableTransfer(hosts: h.hosts)
        let data = try document(hosts: [["name": "Production", "destination": "prod", "user": "deploy"]])
        guard case .success(let (parsed, preview)) = await transfer.preview(data) else { return XCTFail("Preview failed") }
        XCTAssertEqual(preview.collisions.map(\.existing), [existing.id])

        let refused = await transfer.commit(parsed, policy: nil)
        XCTAssertEqual(refused, .failure(.decisionRequired))
        let unchanged = await h.hosts.library.hosts
        XCTAssertEqual(unchanged, [existing], "The existing host is preserved until the user decides")

        guard case .success(let used) = await transfer.commit(parsed, policy: .useExisting) else { return XCTFail("Import failed") }
        XCTAssertEqual([used.hostsCreated, used.hostsReplaced], [0, 0])
        let afterUse = await h.hosts.library.hosts
        XCTAssertEqual(afterUse, [existing])

        _ = await transfer.commit(parsed, policy: .replaceExisting)
        let replaced = await h.hosts.library.hosts
        XCTAssertEqual(replaced.map(\.id), [existing.id])
        XCTAssertEqual(replaced.first?.user, "deploy")
        XCTAssertGreaterThan(replaced[0].connectionRevision, existing.connectionRevision, "Replacing the connection invalidates automation approvals")

        _ = await transfer.commit(parsed, policy: .keepBoth)
        let both = await h.hosts.library.hosts
        XCTAssertEqual(both.count, 2)

        let twice = try document(hosts: [["name": "P1", "destination": "PROD"], ["name": "P2", "destination": "prod "]])
        guard case .success(let (twiceParsed, twicePreview)) = await transfer.preview(twice) else { return XCTFail("Preview failed") }
        XCTAssertEqual(twicePreview.collisions.count, 2, "Case and surrounding whitespace do not hide a collision")
        XCTAssertEqual(twicePreview.collisionDetails.count, 2)
        guard case .failure(.invalid) = await transfer.commit(twiceParsed, policy: .replaceExisting) else { return XCTFail("Replaced one host twice") }
        let afterTwice = await h.hosts.library.hosts
        XCTAssertEqual(afterTwice, both)
    }

    @MainActor
    func testInvalidImportIsAtomic() async throws {
        let h = try Harness()
        defer { h.discardPreferences() }
        let kept = try await h.hosts.library.create(HostDraft(name: "Keep", destination: "keep"))
        await h.hosts.load()
        let transfer = PortableTransfer(hosts: h.hosts)
        let invalid = try document(hosts: [["name": "A", "destination": "a"], ["name": "B", "destination": "b", "port": 70000], ["name": "C", "destination": "c"]])
        guard case .success(let (parsed, preview)) = await transfer.preview(invalid) else { return XCTFail("Preview failed") }
        XCTAssertFalse(preview.errors.isEmpty)
        guard case .failure(.invalid) = await transfer.commit(parsed, policy: .keepBoth) else { return XCTFail("Accepted an invalid host") }
        let afterInvalid = await h.hosts.library.hosts
        XCTAssertEqual(afterInvalid, [kept], "No subset of hosts was installed")

        guard case .failure(let error) = await transfer.preview(try document(version: 3)) else { return XCTFail("Accepted version 3") }
        XCTAssertTrue(error.message.contains("unsupported version"))
        guard case .failure = await transfer.preview(try document(hosts: [["id": "not-a-uuid", "name": "A", "destination": "a"]])) else {
            return XCTFail("Accepted a malformed host reference")
        }

        // The project library can't be written (its folder is a file): the hosts staged by the import are removed again.
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-pt-blocked-\(UUID().uuidString)")
        try Data().write(to: blocked)
        let unwritable = library(at: blocked)
        let failing = PortableTransfer(hosts: h.hosts, projects: unwritable)
        let valid = try document(hosts: [["name": "A", "destination": "a"]], projects: [Self.project])
        guard case .success(let (validParsed, _)) = await failing.preview(valid) else { return XCTFail("Preview failed") }
        guard case .failure(.workspace) = await failing.commit(validParsed, policy: nil) else { return XCTFail("Expected a project library failure") }
        let reverted = await h.hosts.library.hosts
        XCTAssertEqual(reverted, [kept], "Hosts staged by the failed import were removed; others are untouched")

        // A revert undoes only the import's own records, never edits made meanwhile.
        let other = try await h.hosts.library.create(HostDraft(name: "Other", destination: "other"))
        var changes = HostLibrary.ImportChanges()
        changes.creates = [(UUID(), HostDraft(name: "New", destination: "new"))]
        changes.replacements = [(other.id, HostDraft(name: "Other", destination: "other2"), other.revision)]
        let undo = try await h.hosts.library.applyImport(changes)
        _ = try await h.hosts.library.update(id: kept.id, HostDraft(name: "Keep", destination: "keep", user: "me"), expectedRevision: kept.revision)
        try await h.hosts.library.revertImport(undo)
        let afterRevert = await h.hosts.library.hosts
        XCTAssertEqual(Set(afterRevert.map(\.id)), [kept.id, other.id])
        XCTAssertEqual(afterRevert.first { $0.id == kept.id }?.user, "me", "A concurrent edit survives the revert")
        XCTAssertEqual(afterRevert.first { $0.id == other.id }?.destination, "other")
        XCTAssertEqual(afterRevert.first { $0.id == other.id }?.connectionRevision, other.connectionRevision)
    }

    /// FR-PL05: projects travel in the library's JSON form, without launch history, and are added under new identities;
    /// one named like a project you have is added as a copy, never over it.
    @MainActor
    func testProjectsRoundTripWithoutLaunchHistory() async throws {
        let source = try Harness(), sourceProjects = library()
        defer { source.discardPreferences() }
        await sourceProjects.load()
        let project = ProjectDefinition(
            name: "Shop", tabs: [ProjectTab(title: "API", directory: "api", repository: ProjectRepository(url: "git@github.com:acme/api.git"), root: .pane(ProjectPane(command: "make dev")))])
        guard case .success(let saved) = await sourceProjects.save(project) else { return XCTFail("Not saved") }
        await sourceProjects.recordLaunch(saved.id, target: .local, folder: "/Users/me/secret-place")
        let data = await PortableTransfer(hosts: source.hosts, projects: sourceProjects).exportData()

        let target = try Harness(), targetProjects = library()
        defer { target.discardPreferences() }
        await targetProjects.load()
        let transfer = PortableTransfer(hosts: target.hosts, projects: targetProjects)
        guard case .success(let (parsed, preview)) = await transfer.preview(data) else { return XCTFail("Preview failed") }
        XCTAssertEqual(preview.projects, 1)
        XCTAssertEqual(preview.projectCollisions, [])
        guard case .success(let summary) = await transfer.commit(parsed, policy: nil) else { return XCTFail("Import failed") }
        XCTAssertEqual(summary.projectsCreated, 1)
        let imported = try XCTUnwrap(targetProjects.projects.first)
        XCTAssertNotEqual(imported.id, saved.id)
        XCTAssertEqual(imported.lastFolders, [:])
        XCTAssertEqual(imported.tabs, saved.tabs)

        // Imported again: listed in the preview, then added as a copy; the first one is untouched.
        guard case .success(let (again, againPreview)) = await transfer.preview(data) else { return XCTFail("Preview failed") }
        XCTAssertEqual(againPreview.projectCollisions, ["Shop"])
        guard case .success = await transfer.commit(again, policy: nil) else { return XCTFail("Import failed") }
        XCTAssertEqual(Set(targetProjects.projects.map(\.name)), ["Shop", "Shop (imported)"])
        XCTAssertEqual(targetProjects.projects.first { $0.id == imported.id }, imported)

        // A project the library would refuse makes the whole file unreadable before anything is imported.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["projects"] = [["name": "Bad", "tabs": [["title": "T", "root": ["type": "pane", "repository": ["url": "ext::sh -c x"]]]]]]
        guard case .failure = await transfer.preview(try JSONSerialization.data(withJSONObject: object)) else { return XCTFail("An unsafe project was accepted") }
    }

    func testImportedNamesStayUniqueAndWithinTheNameLimit() {
        XCTAssertEqual(PortableDocument.importedName("Shop", taken: []), "Shop")
        XCTAssertEqual(PortableDocument.importedName("Shop", taken: ["shop"]), "Shop (imported)")
        XCTAssertEqual(PortableDocument.importedName("Shop", taken: ["shop", "shop (imported)"]), "Shop (imported 2)")
        let long = String(repeating: "x", count: 200)
        let renamed = PortableDocument.importedName(long, taken: [long])
        XCTAssertEqual(renamed.count, 200)
        XCTAssertTrue(renamed.hasSuffix(" (imported)"))
    }
}
