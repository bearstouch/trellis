import XCTest
import TrellisControl
import TrellisCore
@testable import TrellisMCP

/// Protocol 2 MCP tools are generated from the method catalog (served from the switch, phase 8).
final class MCPToolsV2Tests: XCTestCase {
    func testToolsAreGeneratedFromTheCatalog() throws {
        XCTAssertEqual(MCPTools.v2.map(\.method), MethodCatalogV2.methods.map(\.name))
        XCTAssertEqual(Set(MCPTools.v2.map(\.name)).count, MCPTools.v2.count, "Tool names are unique")
        for tool in MCPTools.v2 {
            let spec = try XCTUnwrap(MethodCatalogV2.spec(tool.method))
            XCTAssertEqual(tool.name, MCPTools.toolName(tool.method), "v1 and v2 name tools the same way")
            XCTAssertTrue(tool.name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" } && tool.name.count <= 64, tool.name)
            XCTAssertEqual(tool.inputSchema, spec.inputSchema)
            XCTAssertEqual(tool.json["annotations"], spec.toolAnnotations, "MCPTool and the catalog agree on annotations")
            XCTAssertEqual(tool.description, spec.toolDescription)
        }
        let grantGet = try XCTUnwrap(MCPTools.v2.first { $0.name == "grant_get" })
        XCTAssertTrue(grantGet.readOnly)
        XCTAssertEqual(grantGet.inputSchema, .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))
        XCTAssertNil(MCPTools.byName["grant_get"], "v1 tools/list is unchanged until the switch")
    }

    func testVisibilityFollowsTheGrant() async throws {
        let store = GrantStore(url: nil, secrets: NoopSecrets())
        let (grant, _) = try await store.create(name: "Reader", capabilities: [.themeRead], spaceScope: .spaces([]), hostScope: .all, lifetime: 3600)
        XCTAssertEqual(MCPTools.v2Visible(to: grant).map(\.name), ["system_info", "grant_get"], "Methods that need no capability are always listed")
    }
}

private final class NoopSecrets: GrantSecretStore, @unchecked Sendable {
    func store(_ token: String, grantID: UUID) throws {}
    func remove(grantID: UUID) {}
}
