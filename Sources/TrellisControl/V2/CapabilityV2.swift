import Foundation

/// Protocol 2 capabilities (docs/api/v2/permissions.md, API2-06). Grants still store v1 capabilities until phase 3;
/// `granted(by:)` maps them as migration.md does, so a grant can do exactly what it could under v1 and nothing more.
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
    public init(_ v1: Capability) {
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

    /// What a stored grant allows under protocol 2. Capabilities v1 had no equivalent for are never added.
    public static func granted(by grant: AutomationGrant) -> Set<Self> { Set(grant.capabilities.map(Self.init)) }
}
