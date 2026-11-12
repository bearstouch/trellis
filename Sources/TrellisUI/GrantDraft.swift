import Foundation
import TrellisControl
import TrellisCore

/// The grant sheet's form state (permissions.md#presets): a preset fills in capabilities and default scopes, changing a
/// capability makes it Custom. Pure, so the sheet's rules are tested without rendering.
struct GrantDraft: Equatable {
    enum SpaceChoice: Hashable { case all, created, chosen }

    var name = ""
    private(set) var preset: GrantPreset = .observer
    private(set) var capabilities: Set<CapabilityV2> = []
    var spaceChoice = SpaceChoice.all
    var spaces = Set<UUID>()
    var allProjects = true
    var projects = Set<UUID>()
    var allHosts = true
    var hosts = Set<UUID>()
    var allAgents = true
    var agents = Set<String>()
    /// Seconds from now; nil keeps the current expiry (editing only).
    var lifetime: TimeInterval? = GrantDraft.defaultLifetime
    static let defaultLifetime: TimeInterval = 7 * 86_400

    init(preset: GrantPreset = .observer) { choose(preset) }

    /// The form for editing `grant`; its expiry is kept until another is chosen.
    init(grant: AutomationGrant) {
        name = grant.name; preset = grant.preset; capabilities = grant.capabilitiesV2; lifetime = nil
        switch grant.spaceScope {
        case .all: spaceChoice = .all
        case .created: spaceChoice = .created
        case .spaces(let ids): spaceChoice = .chosen; spaces = ids
        }
        if case .projects(let ids) = grant.projectScope { allProjects = false; projects = ids }
        if case .approved(let approvals) = grant.hostScope { allHosts = false; hosts = Set(approvals.map(\.hostID)) }
        if case .agents(let ids) = grant.agentScope { allAgents = false; agents = ids }
    }

    /// A preset sets exactly its capabilities and its default scopes; chosen spaces, projects, hosts and agents are kept
    /// for when a scope is switched back to them. Custom keeps everything as it is.
    mutating func choose(_ preset: GrantPreset) {
        self.preset = preset
        guard let capabilities = preset.capabilities else { return }
        self.capabilities = capabilities
        let scope = preset.defaultScope
        switch scope.spaces {
        case .all: spaceChoice = .all
        case .created: spaceChoice = .created
        case .spaces: spaceChoice = .chosen
        }
        allProjects = scope.projects == .all
        allHosts = scope.hosts == .all
        allAgents = scope.agents == .all
    }

    /// Whether the sheet opens Advanced by itself: a Custom grant, or projects, hosts or agents scoped differently from
    /// its role's default, would otherwise hide part of what it can do.
    var needsAdvanced: Bool {
        guard preset != .custom else { return true }
        // A role's default is "all" or "none chosen yet", so any chosen project, host or agent is a choice made in Advanced.
        let scope = preset.defaultScope
        let projectsChanged = allProjects != (scope.projects == .all) || (!allProjects && !projects.isEmpty)
        let hostsChanged = allHosts != (scope.hosts == .all) || (!allHosts && !hosts.isEmpty)
        let agentsChanged = allAgents != (scope.agents == .all) || (!allAgents && !agents.isEmpty)
        return projectsChanged || hostsChanged || agentsChanged
    }

    /// Any capability change makes the grant Custom.
    mutating func set(_ capability: CapabilityV2, _ on: Bool) {
        guard on != capabilities.contains(capability) else { return }
        if on { capabilities.insert(capability) } else { capabilities.remove(capability) }
        preset = .custom
    }

    /// The settings to save. A host that stays approved keeps the connection revision it was approved at; a newly chosen
    /// one is approved at its current revision.
    func settings(savedHosts: [SavedHost], existing: HostScope? = nil) -> GrantSettings {
        var approvals = Set<HostApproval>()
        if !allHosts {
            var previous: [UUID: UInt64] = [:]
            if case .approved(let old)? = existing { for approval in old { previous[approval.hostID] = approval.connectionRevision } }
            for id in hosts {
                if let revision = previous[id] {
                    approvals.insert(HostApproval(hostID: id, connectionRevision: revision))
                } else if let host = savedHosts.first(where: { $0.id == id }) {
                    approvals.insert(HostApproval(hostID: id, connectionRevision: host.connectionRevision))
                }
            }
        }
        let spaceScope: SpaceScope =
            switch spaceChoice {
            case .all: .all
            case .created: .created
            case .chosen: .spaces(spaces)
            }
        return GrantSettings(
            name: name, preset: preset, capabilities: capabilities,
            scope: GrantScope(
                spaces: spaceScope, projects: allProjects ? .all : .projects(projects), hosts: allHosts ? .all : .approved(approvals),
                agents: allAgents ? .all : .agents(agents)))
    }

    /// Whether saving over `grant` widens it (the sheet confirms first) or narrows it (applies at once).
    func change(from grant: AutomationGrant, savedHosts: [SavedHost], now: Date) -> GrantChange {
        GrantChange(
            from: grant, to: settings(savedHosts: savedHosts, existing: grant.hostScope), expiresAt: lifetime.map { now.addingTimeInterval($0) } ?? grant.expiresAt)
    }
}
