import Foundation
import TrellisControl

extension MCPTools {
    /// Protocol 2 tools, one per catalog method, with schemas and annotations generated from the catalog so they can't
    /// drift from what the server validates. Served from the switch (phase 8); until then `tools/list` stays v1.
    public static let v2: [MCPTool] = MethodCatalogV2.methods.map { spec in
        MCPTool(
            name: spec.toolName, method: spec.name, description: spec.toolDescription, inputSchema: spec.inputSchema, readOnly: !spec.isMutating,
            destructive: spec.isDestructive)
    }

    /// v2 tools whose base requirements this grant can ever satisfy; conditional capabilities and scope are checked per call.
    public static func v2Visible(to grant: AutomationGrant) -> [MCPTool] {
        let granted = CapabilityV2.granted(by: grant)
        return v2.filter { tool in
            guard let spec = MethodCatalogV2.spec(tool.method) else { return false }
            return spec.capabilities.isSubset(of: granted) && (!spec.requiresAllSpaces || grant.spaceScope == .all)
        }
    }
}
