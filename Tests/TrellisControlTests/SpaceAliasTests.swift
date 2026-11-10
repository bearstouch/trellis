import XCTest
import TrellisCore
@testable import TrellisControl

/// Windows were renamed spaces: the API answers to the old names for now, and saved grants keep working.
final class SpaceAliasTests: XCTestCase {
    func testDeprecatedWindowMethodsAndParamsMapToSpaces() {
        let id = UUID().uuidString
        let mapped = ControlMethods.canonical("window.get", params: .object(["id": .string(id)]))
        XCTAssertEqual(mapped.method, "space.get")
        XCTAssertEqual(ControlMethods.canonical("tab.list", params: .object(["windowId": .string(id)])).params, .object(["spaceId": .string(id)]))
        XCTAssertEqual(
            ControlMethods.canonical("layout.export", params: .object(["windowIds": .array([.string(id)])])).params, .object(["spaceIds": .array([.string(id)])]))
        // The new name wins when both are given; the old one is dropped either way.
        XCTAssertEqual(ControlMethods.canonical("tab.list", params: .object(["windowId": .string("old"), "spaceId": .string(id)])).params, .object(["spaceId": .string(id)]))
        XCTAssertEqual(ControlMethods.canonical("space.list", params: nil).method, "space.list")
        XCTAssertEqual(ControlMethods.canonical("windowing.x", params: nil).method, "windowing.x", "Only the window. prefix is an alias")
        XCTAssertFalse(ControlMethods.isMutating("window.list"), "A read through the old name is still a read")
        XCTAssertTrue(ControlMethods.isMutating("window.close"))
        XCTAssertNotNil(AuthorizationPolicy.requirements["space.list"])
        XCTAssertNil(AuthorizationPolicy.requirements["window.list"], "Aliases are resolved before the catalog, never listed in it")
    }

    /// grants.json keeps the stored names it had before the rename, so a grant reads the same in older and newer builds.
    func testGrantsKeepTheirStoredScopeNames() throws {
        let space = UUID()
        let json = #"""
            {"id":"\#(UUID().uuidString)","name":"ci","tokenHash":"abc","capabilities":["metadata.read"],
             "windowScope":{"windows":{"_0":["\#(space.uuidString)"]}},"hostScope":{"all":{}},
             "createdAt":"2026-01-01T00:00:00Z","expiresAt":"2027-01-01T00:00:00Z"}
            """#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let grant = try decoder.decode(AutomationGrant.self, from: Data(json.utf8))
        XCTAssertEqual(grant.spaceScope, .spaces([space]))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let written = String(decoding: try encoder.encode(grant), as: UTF8.self)
        XCTAssertTrue(written.contains("\"windowScope\"") && written.contains("\"windows\""), written)
        XCTAssertFalse(written.contains("spaceScope"))
        let all = try decoder.decode(AutomationGrant.self, from: Data(json.replacingOccurrences(of: #"{"windows":{"_0":["\#(space.uuidString)"]}}"#, with: #"{"all":{}}"#).utf8))
        XCTAssertEqual(all.spaceScope, .all)
    }

    func testLayoutVersionOneNamesWindowsAndVersionTwoNamesSpaces() {
        func document(_ version: Int, _ list: String) -> JSONValue {
            .object([
                "version": .number(Double(version)),
                list: .array([
                    .object([
                        "key": .string("w"), "name": .string("W"),
                        "tabs": .array([.object(["key": .string("t"), "title": .string("T"), "root": .object(["type": .string("pane"), "key": .string("p"), "launch": .object(["kind": .string("shell")])])])])
                    ])
                ])
            ])
        }
        guard case .success(let old) = LayoutJSON.parse(document(1, "windows")), case .success(let new) = LayoutJSON.parse(document(2, "spaces")) else {
            return XCTFail("A supported layout was refused")
        }
        XCTAssertEqual(old, new)
        // Only version 1 exports could bind a window to a host; API layouts never can (FR-RW15).
        guard case .object(var bound) = document(2, "spaces"), case .array(var spaces)? = bound["spaces"], case .object(var space) = spaces[0] else { return XCTFail() }
        space["remoteHostId"] = .string(UUID().uuidString); spaces[0] = .object(space); bound["spaces"] = .array(spaces)
        guard case .failure = LayoutJSON.parse(.object(bound)) else { return XCTFail("An API layout bound a space to a host") }
        for (version, list) in [(1, "spaces"), (2, "windows"), (3, "spaces")] {
            guard case .failure = LayoutJSON.parse(document(version, list)) else { return XCTFail("Accepted version \(version) with \(list)") }
        }
    }
}
