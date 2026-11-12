import Foundation

/// Capabilities (docs/api/permissions.md, API2-06). Grants store them (grants.json schema 2); a migrated v1 grant holds
/// exactly the mapped set.
public enum CapabilityV2: String, CaseIterable, Codable, Sendable, Comparable {
    case workspaceRead = "workspace.read"
    case workspaceWrite = "workspace.write"
    case sessionStart = "session.start"
    case sessionExecute = "session.execute"
    case sessionInput = "session.input"
    case sessionOutputRead = "session.output.read"
    case sessionClose = "session.close"
    case agentControl = "agent.control"
    case agentRespond = "agent.respond"
    case agentInstall = "agent.install"
    case hostRead = "host.read"
    case hostWrite = "host.write"
    case remoteConnect = "remote.connect"
    case remoteManage = "remote.manage"
    case projectRead = "project.read"
    case projectWrite = "project.write"
    case projectLaunch = "project.launch"
    case taskRead = "task.read"
    case taskRun = "task.run"
    case themeRead = "theme.read"
    case themeWrite = "theme.write"

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The v2 name of a v1 capability (migration.md, Capabilities).
    init(_ v1: CapabilityV1) {
        switch v1 {
        case .metadataRead: self = .workspaceRead
        case .layoutWrite: self = .workspaceWrite
        case .sessionStart: self = .sessionStart
        case .sessionInput: self = .sessionInput
        case .sessionExecute: self = .sessionExecute
        case .sessionOutputRead: self = .sessionOutputRead
        case .sessionClose: self = .sessionClose
        case .themeRead: self = .themeRead
        case .themeWrite: self = .themeWrite
        case .hostRead: self = .hostRead
        case .hostWrite: self = .hostWrite
        }
    }

    /// What a stored grant allows under protocol 2.
    public static func granted(by grant: AutomationGrant) -> Set<Self> { grant.capabilitiesV2 }

    /// The area a capability belongs to, for grouping in the grant sheet (permissions.md#presets).
    public var area: Area {
        switch self {
        case .workspaceRead, .workspaceWrite: .workspace
        case .sessionStart, .sessionExecute, .sessionInput, .sessionOutputRead, .sessionClose: .sessions
        case .agentControl, .agentRespond, .agentInstall: .agents
        case .hostRead, .hostWrite, .remoteConnect, .remoteManage: .hosts
        case .projectRead, .projectWrite, .projectLaunch, .taskRead, .taskRun: .projects
        case .themeRead, .themeWrite: .appearance
        }
    }

    public enum Area: String, CaseIterable, Sendable { case workspace, sessions, agents, hosts, projects, appearance }
}
