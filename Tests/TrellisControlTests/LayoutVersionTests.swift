import XCTest
import TrellisCore
@testable import TrellisControl

/// Windows were renamed spaces, and layouts reached version 3 (docs/api/layouts.md, migration.md): API layouts read
/// versions 1–3 with `spaces`, refuse a `windows` list, and saved grants under the old scope names still migrate.
final class LayoutVersionTests: XCTestCase {
    /// A grants.json written before the rename (schema 1, `windowScope`/`windows`) still reads, once: the migration to
    /// schema 2 keeps the scope and never writes the old names again.
    func testGrantsStoredUnderTheOldScopeNamesMigrate() async throws {
        let space = UUID()
        let json = #"""
            [{"id":"\#(UUID().uuidString)","name":"ci","tokenHash":"abc","capabilities":["metadata.read"],
             "windowScope":{"windows":{"_0":["\#(space.uuidString)"]}},"hostScope":{"all":{}},
             "createdAt":"2026-01-01T00:00:00Z","expiresAt":"2027-01-01T00:00:00Z"},
             {"id":"\#(UUID().uuidString)","name":"all","tokenHash":"def","capabilities":["metadata.read"],
             "windowScope":{"all":{}},"hostScope":{"all":{}},"createdAt":"2026-01-01T00:00:00Z","expiresAt":"2027-01-01T00:00:00Z"}]
            """#
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tsa-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("grants.json")
        try OwnerOnlyFile.publish(Data(json.utf8), to: url)
        let store = GrantStore(url: url, secrets: NoSecretsStore())
        await store.load()
        let grants = await store.grants
        XCTAssertEqual(grants.map(\.spaceScope), [.spaces([space]), .all])
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.contains("\"spaces\" : ["), written)
        XCTAssertFalse(written.contains("windowScope") || written.contains("\"windows\"") || written.contains("spaceScope"), written)
    }

    private func document(_ version: Int, _ list: String = "spaces", launch: JSONValue = .object(["kind": .string("shell")]), pane: [String: JSONValue] = [:], space: [String: JSONValue] = [:])
        -> JSONValue
    {
        var paneObject: [String: JSONValue] = ["type": .string("pane"), "key": .string("p"), "launch": launch]
        paneObject.merge(pane) { $1 }
        var spaceObject: [String: JSONValue] = [
            "key": .string("w"), "name": .string("W"), "tabs": .array([.object(["key": .string("t"), "title": .string("T"), "root": .object(paneObject)])])
        ]
        spaceObject.merge(space) { $1 }
        return .object(["version": .number(Double(version)), list: .array([.object(spaceObject)])])
    }

    private func issues(_ result: Result<LayoutDocument, LayoutParseError>) -> LayoutParseError? {
        if case .failure(let error) = result { error } else { nil }
    }

    func testLayoutVersionsOneAndTwoAreReadAsThreeAndWindowsIsRefused() throws {
        let host = UUID()
        guard case .success(let one) = LayoutJSON.parse(document(1)), case .success(let two) = LayoutJSON.parse(document(2)),
            case .success(let three) = LayoutJSON.parse(document(3))
        else { return XCTFail("A supported layout was refused") }
        XCTAssertEqual(one, three)
        XCTAssertEqual(two, three)
        XCTAssertEqual(LayoutJSON.declaredVersion(document(1)), 1)
        XCTAssertEqual(LayoutJSON.declaredVersion(document(4)), nil)
        // Versions 1 and 2 name a saved-host launch `host`, version 3 `ssh`; both read as the same launch.
        let old = LayoutJSON.parse(document(2, launch: .object(["kind": .string("host"), "hostId": .string(host.uuidString)])))
        let new = LayoutJSON.parse(document(3, launch: .object(["kind": .string("ssh"), "hostId": .string(host.uuidString)])))
        XCTAssertEqual(try old.get(), try new.get())
        XCTAssertEqual(try new.get().spaces[0].tabs[0].root, .pane(key: "p", title: nil, launch: .host(host)))
        XCTAssertNotNil(issues(LayoutJSON.parse(document(3, launch: .object(["kind": .string("host"), "hostId": .string(host.uuidString)])))), "v3 says ssh")
        XCTAssertNotNil(issues(LayoutJSON.parse(document(2, launch: .object(["kind": .string("ssh"), "hostId": .string(host.uuidString)])))), "v2 said host")

        // A `windows` list (layout version 1 before the rename) is an invalid document, whatever version it names.
        for version in [1, 2, 3] {
            let refused = try XCTUnwrap(issues(LayoutJSON.parse(document(version, "windows"))), "Accepted windows in version \(version)")
            XCTAssertFalse(refused.unsupportedVersion)
            XCTAssertTrue(refused.text.contains("spaces"), refused.text)
        }
        for version in [0, 4] {
            let refused = try XCTUnwrap(issues(LayoutJSON.parse(document(version))))
            XCTAssertTrue(refused.unsupportedVersion, "version \(version) is UNSUPPORTED_VERSION, not an invalid document")
        }
        XCTAssertFalse(try XCTUnwrap(issues(LayoutJSON.parse(.object(["spaces": .array([])])))).unsupportedVersion, "No version is an invalid document")
    }

    func testVersionThreeCarriesMachineProjectAndAgent() throws {
        let host = UUID(), project = UUID()
        let parsed = try LayoutJSON.parse(
            document(
                3, launch: .object(["kind": .string("shell"), "directory": .string("~/code")]), pane: ["agent": .string("trellis-claude-code")],
                space: ["machine": .object(["kind": .string("remote"), "hostId": .string(host.uuidString)]), "projectId": .string(project.uuidString)])
        ).get()
        let space = try XCTUnwrap(parsed.spaces.first)
        XCTAssertEqual(space.remoteHostID, host)
        XCTAssertEqual(space.projectID, project)
        XCTAssertEqual(space.tabs[0].root, .pane(key: "p", title: nil, launch: .agent("trellis-claude-code", directory: "~/code")))
        let local = try LayoutJSON.parse(document(3, space: ["machine": .object(["kind": .string("local")])])).get()
        XCTAssertNil(local.spaces[0].remoteHostID)

        let refused: [(JSONValue, String)] = [
            (document(2, pane: ["agent": .string("trellis-claude-code")]), "agent is version 3"),
            (document(2, space: ["projectId": .string(project.uuidString)]), "projectId is version 3"),
            (document(3, space: ["machine": .object(["kind": .string("remote")])]), "a remote machine names its host"),
            (document(3, space: ["machine": .object(["kind": .string("local"), "hostId": .string(host.uuidString)])]), "a local machine has no host"),
            (document(3, space: ["machine": .object(["kind": .string("mars")])]), "unknown machine kind"),
            (document(3, space: ["projectId": .string("nope")]), "projectId is a UUID"),
            (
                document(3, launch: .object(["kind": .string("ssh"), "hostId": .string(host.uuidString)]), pane: ["agent": .string("trellis-claude-code")]),
                "only a shell launch carries an agent"
            ),
            (document(3, launch: .object(["kind": .string("process"), "executable": .string("/bin/sh")])), "no processes")
        ]
        for (value, reason) in refused { XCTAssertNotNil(issues(LayoutJSON.parse(value)), reason) }
    }

    func testPortableExportsStillReadWindowsAndRemoteHosts() throws {
        let host = UUID()
        guard case .success(let windows) = LayoutJSON.parse(document(1, "windows"), allowRemoteHosts: true) else { return XCTFail("Portable version 1 refused") }
        XCTAssertEqual(windows.spaces.count, 1)
        let bound = document(2, space: ["remoteHostId": .string(host.uuidString)])
        XCTAssertEqual(try LayoutJSON.parse(bound, allowRemoteHosts: true).get().spaces[0].remoteHostID, host)
        // Only exports could bind a space with remoteHostId; API layouts use version 3's machine (FR-RW15).
        XCTAssertNotNil(issues(LayoutJSON.parse(bound)), "An API layout bound a space to a host through remoteHostId")
        XCTAssertNotNil(issues(LayoutJSON.parse(document(3), allowRemoteHosts: true)), "Portable exports are versions 1 and 2")
    }

    /// Resuming an agent's conversation (FR-AG06) doesn't change its pane's launch, so reapplying a layout matches it.
    func testAResumedAgentPaneStillMatchesItsLayout() {
        let wanted = SessionLaunch.agent(AgentLaunch(agentID: "trellis-claude-code", directory: "/tmp"))
        XCTAssertTrue(LayoutPlanner.sameLaunch(.agent(AgentLaunch(agentID: "trellis-claude-code", directory: "/tmp", resume: true)), wanted))
        XCTAssertFalse(LayoutPlanner.sameLaunch(.agent(AgentLaunch(agentID: "trellis-codex", directory: "/tmp", resume: true)), wanted))
        XCTAssertFalse(LayoutPlanner.sameLaunch(.agent(AgentLaunch(agentID: "trellis-claude-code", directory: "/var")), wanted))
    }
}

private struct NoSecretsStore: GrantSecretStore {
    func store(_ token: String, grantID: UUID) throws {}
    func remove(grantID: UUID) {}
}
