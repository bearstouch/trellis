import AppKit
import XCTest
import TrellisControl
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

final class PortableTransferTests: XCTestCase {
    /// Every key a portable export may contain.
    static let allowedKeys: Set<String> = [
        "format", "version", "layout", "hosts", "windows", "key", "name", "tabs", "title", "root", "type", "axis", "ratio", "children", "launch",
        "kind", "directory", "hostId", "id", "destination", "user", "port", "identityFile", "tags"
    ]

    private func keys(_ value: Any) -> Set<String> {
        if let object = value as? [String: Any] { return Set(object.keys).union(object.values.flatMap { keys($0) }) }
        if let array = value as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(keys($1)) } }
        return []
    }

    @MainActor
    private func document(hosts: [[String: Any]], panes: [[String: Any]], version: Int = 1) throws -> Data {
        let root: [String: Any] =
            panes.count == 1 ? panes[0] : ["type": "split", "key": "s", "axis": "x", "ratio": 0.5, "children": Array(panes.prefix(2))]
        let object: [String: Any] = [
            "format": "trellis.portable", "version": version, "hosts": hosts,
            "layout": ["version": 1, "windows": [["key": "w", "name": "Imported", "tabs": [["key": "t", "title": "Main", "root": root]]]]]
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    @MainActor
    func testS028_UT01_exportOmitsSensitiveState() async throws {
        let h = try Harness()
        try await h.grant("full")
        defer {
            h.model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }; h.discardPreferences()
        }
        let host = try result(try await h.call("host.create", ["name": "Prod", "destination": "prod", "user": "deploy", "port": 2222]))
        let hostID = try XCTUnwrap(host["id"] as? String)
        await h.hosts.load()
        let window: String = try await h.value("windowId", "window.create", ["name": "Project"])
        let pane = try XCTUnwrap(h.model.presentation.activePane?.id)
        let script = "printf 'OUTPUT-SECRET\\n'; exec /bin/sleep 30"
        _ = try await h.call(
            "session.start",
            ["paneId": pane.uuidString, "launch": ["kind": "process", "executable": "/bin/sh", "arguments": ["-c", script, "--password=hunter2"], "directory": "/tmp", "environment": ["API_KEY": "s3cr3t-env"]]])
        let terminal = NativeTerminalHandle(try XCTUnwrap(h.model.terminals[pane]))
        try await terminal.waitFor("OUTPUT-SECRET")
        let split = try result(try await h.call("pane.split", ["paneId": pane.uuidString, "axis": "x"]))
        let second = try XCTUnwrap((split["pane"] as? [String: Any])?["paneId"] as? String)
        _ = try await h.model.service.execute(.configureStoppedSession(paneID: UUID(uuidString: second)!, launch: .host(UUID(uuidString: hostID)!)))
        await h.model.refresh()

        let (data, converted) = await PortableTransfer(model: h.model, hosts: h.hosts).exportData()
        XCTAssertEqual(converted, 1, "The custom command pane becomes a plain shell")
        let text = String(decoding: data, as: UTF8.self)
        let snapshot = h.model.snapshot
        let runtimeIDs = snapshot.windows.map(\.id) + Array(snapshot.tabs.keys) + Array(snapshot.panes.keys) + Array(snapshot.sessions.keys)
        for forbidden in runtimeIDs.map(\.uuidString) + [hostID, window, "hunter2", "s3cr3t-env", "OUTPUT-SECRET", "/bin/sh", "trl_"] {
            XCTAssertFalse(text.contains(forbidden), "Export contains \(forbidden)")
        }
        if let pid = terminal.native.processID { XCTAssertFalse(text.contains("\"\(pid)\"")) }
        let object = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(keys(object).isSubset(of: Self.allowedKeys), "Unexpected keys: \(keys(object).subtracting(Self.allowedKeys))")
        XCTAssertTrue(text.contains("deploy") && text.contains("2222"), "Portable host metadata is kept")
        // The export round-trips: host references resolve inside the document itself.
        guard case .success(let (_, preview)) = await PortableTransfer(model: h.model, hosts: h.hosts).preview(data) else { return XCTFail("Export does not parse") }
        XCTAssertEqual(preview.errors, [])
        XCTAssertEqual([preview.windows, preview.panes, preview.hosts], [1, 2, 1])
    }

    @MainActor
    func testS028_UT02_interactiveImportRemapsIds() async throws {
        let h = try Harness()
        defer { h.model.terminals.values.forEach { $0.adapter.detach() }; h.discardPreferences() }
        let transfer = PortableTransfer(model: h.model, hosts: h.hosts)
        let data = try document(
            hosts: [["id": UUID().uuidString, "name": "Lab", "destination": "lab"]],
            panes: [["type": "pane", "key": "a", "launch": ["kind": "shell", "directory": "/tmp"]], ["type": "pane", "key": "b", "launch": ["kind": "shell"]]])
        var windowIDs: [Set<UUID>] = []
        for _ in 0..<2 {
            guard case .success(let (parsed, preview)) = await transfer.preview(data) else { return XCTFail("Preview failed") }
            XCTAssertEqual([preview.windows, preview.tabs, preview.panes, preview.hosts], [1, 1, 2, 1])
            XCTAssertEqual(preview.directories, ["/tmp"])
            let before = Set(h.model.snapshot.windows.map(\.id))
            // The second import's host collides with the first; keep both explicitly.
            guard case .success(let summary) = await transfer.commit(parsed, policy: preview.collisions.isEmpty ? nil : .keepBoth) else { return XCTFail("Import failed") }
            XCTAssertEqual(summary.windows, 1)
            windowIDs.append(Set(h.model.snapshot.windows.map(\.id)).subtracting(before))
        }
        XCTAssertEqual(windowIDs.map(\.count), [1, 1])
        XCTAssertTrue(windowIDs[0].isDisjoint(with: windowIDs[1]), "Every interactive import gets fresh IDs")
        XCTAssertEqual(h.model.snapshot.windows.count, 2)
        XCTAssertEqual(h.model.snapshot.panes.count, 4)
        XCTAssertTrue(h.model.snapshot.sessions.values.allSatisfy { $0.state == .stopped }, "Zero launches")
        XCTAssertTrue(h.model.terminals.values.allSatisfy { $0.processID == nil })
        let hosts = await h.hosts.library.hosts
        XCTAssertEqual(hosts.count, 2)
        try h.model.snapshot.validate()
    }

    @MainActor
    func testS028_UT03_hostCollisionNeedsPolicy() async throws {
        let h = try Harness()
        defer { h.model.terminals.values.forEach { $0.adapter.detach() }; h.discardPreferences() }
        let existing = try await h.hosts.library.create(HostDraft(name: "Prod", destination: "prod", user: "ops"))
        await h.hosts.load()
        let transfer = PortableTransfer(model: h.model, hosts: h.hosts)
        let reference = UUID()
        let data = try document(
            hosts: [["id": reference.uuidString, "name": "Production", "destination": "prod", "user": "deploy"]],
            panes: [["type": "pane", "key": "p", "launch": ["kind": "host", "hostId": reference.uuidString]]])
        guard case .success(let (parsed, preview)) = await transfer.preview(data) else { return XCTFail("Preview failed") }
        XCTAssertEqual(preview.collisions.map(\.existing), [existing.id])
        XCTAssertEqual(preview.hostReferences, ["Production"])

        let refused = await transfer.commit(parsed, policy: nil)
        XCTAssertEqual(refused, .failure(.decisionRequired))
        let unchanged = await h.hosts.library.hosts
        XCTAssertEqual(unchanged, [existing], "The existing host is preserved until the user decides")
        XCTAssertTrue(h.model.snapshot.windows.isEmpty)

        _ = await transfer.commit(parsed, policy: .useExisting)
        let paneSession = try XCTUnwrap(h.model.snapshot.sessions.values.first)
        XCTAssertEqual(paneSession.launch, .host(existing.id))
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

        let twice = try document(
            hosts: [["id": UUID().uuidString, "name": "P1", "destination": "PROD"], ["id": UUID().uuidString, "name": "P2", "destination": "prod "]],
            panes: [["type": "pane", "key": "p", "launch": ["kind": "shell"]]])
        guard case .success(let (twiceParsed, twicePreview)) = await transfer.preview(twice) else { return XCTFail("Preview failed") }
        XCTAssertEqual(twicePreview.collisions.count, 2, "Case and surrounding whitespace do not hide a collision")
        XCTAssertEqual(twicePreview.collisionDetails.count, 2)
        guard case .failure(.invalid) = await transfer.commit(twiceParsed, policy: .replaceExisting) else { return XCTFail("Replaced one host twice") }
        let afterTwice = await h.hosts.library.hosts
        XCTAssertEqual(afterTwice, both)
    }

    @MainActor
    func testS028_UT04_invalidImportIsAtomic() async throws {
        let h = try Harness()
        defer { h.model.terminals.values.forEach { $0.adapter.detach() }; h.discardPreferences() }
        let kept = try await h.hosts.library.create(HostDraft(name: "Keep", destination: "keep"))
        await h.hosts.load()
        let transfer = PortableTransfer(model: h.model, hosts: h.hosts)
        let ids = (0..<3).map { _ in UUID().uuidString }
        let invalid = try document(
            hosts: [["id": ids[0], "name": "A", "destination": "a"], ["id": ids[1], "name": "B", "destination": "b", "port": 70000], ["id": ids[2], "name": "C", "destination": "c"]],
            panes: [["type": "pane", "key": "p", "launch": ["kind": "host", "hostId": ids[0]]]])
        guard case .success(let (parsed, preview)) = await transfer.preview(invalid) else { return XCTFail("Preview failed") }
        XCTAssertFalse(preview.errors.isEmpty)
        guard case .failure(.invalid) = await transfer.commit(parsed, policy: .keepBoth) else { return XCTFail("Accepted an invalid host") }
        let afterInvalid = await h.hosts.library.hosts
        XCTAssertEqual(afterInvalid, [kept], "No subset of hosts was installed")
        XCTAssertTrue(h.model.snapshot.windows.isEmpty, "No layout was installed")

        let future = try document(hosts: [], panes: [["type": "pane", "key": "p", "launch": ["kind": "shell"]]], version: 2)
        guard case .failure(let error) = await transfer.preview(future) else { return XCTFail("Accepted version 2") }
        XCTAssertTrue(error.message.contains("unsupported version"))

        // A workspace failure after hosts were staged reverts the host import.
        let valid = try document(hosts: [["id": ids[0], "name": "A", "destination": "a"]], panes: [["type": "pane", "key": "p", "launch": ["kind": "host", "hostId": ids[0]]]])
        guard case .success(let (validParsed, _)) = await transfer.preview(valid) else { return XCTFail("Preview failed") }
        h.model.stopAll()
        guard case .failure(.workspace) = await transfer.commit(validParsed, policy: nil) else { return XCTFail("Expected a workspace failure") }
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

        // Planner-only problems are reported in the preview, before Import is enabled.
        let relative = try document(hosts: [], panes: [["type": "pane", "key": "p", "launch": ["kind": "shell", "directory": "relative/dir"]]])
        guard case .success(let (_, relativePreview)) = await transfer.preview(relative) else { return XCTFail("Preview failed") }
        XCTAssertEqual(relativePreview.errors.count, 1)
    }
}
