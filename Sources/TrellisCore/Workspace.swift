import Foundation

public enum SplitAxis: String, Codable, Sendable { case x, y }

/// Arrays allow malformed imported trees to be decoded and rejected explicitly;
/// WorkspaceSnapshot.validate() enforces exactly two children at every branch.
public indirect enum PaneLayout: Equatable, Codable, Sendable {
    case pane(UUID)
    case split(id: UUID, axis: SplitAxis, ratio: Double, children: [PaneLayout])

    public var paneIDs: [UUID] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, _, _, let children): return children.flatMap(\.paneIDs)
        }
    }
}

public enum SessionLaunch: Equatable, Codable, Sendable {
    case shell(directory: String?)
    case host(UUID)
    case process(executable: String, arguments: [String], directory: String?)
    /// The account's login shell on a saved host, run by its remote helper (FR-RW04); `directory` is a remote path.
    case remoteShell(hostID: UUID, directory: String?)
    /// A coding agent from the agent catalog (FR-AG04), locally or on a remote workspace's host.
    case agent(AgentLaunch)

    /// The host whose remote helper owns this session, for remote workspace sessions only.
    public var remoteHostID: UUID? {
        switch self {
        case .remoteShell(let id, _): id
        case .agent(let agent): agent.hostID
        default: nil
        }
    }

    public var agent: AgentLaunch? { if case .agent(let agent) = self { agent } else { nil } }
}

public enum SessionState: String, Codable, Sendable {
    case stopped, starting, running, closing, exited, failed
}

public struct Space: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var tabIDs: [UUID]
    public var activeTabID: UUID
    public var revision: UInt64
    /// A remote workspace (FR-RW01): every session in it is a `.remoteShell` on this saved host.
    public var remoteHostID: UUID?
    /// The library project this space was loaded from (FR-W08); nil for a plain space. Never resolved here: a deleted
    /// project leaves the space as it is.
    public var projectID: UUID?

    public init(id: UUID, name: String, tabIDs: [UUID], activeTabID: UUID, revision: UInt64 = 0, remoteHostID: UUID? = nil, projectID: UUID? = nil) {
        self.id = id; self.name = name; self.tabIDs = tabIDs
        self.activeTabID = activeTabID; self.revision = revision; self.remoteHostID = remoteHostID; self.projectID = projectID
    }

    /// What a new pane in this space runs.
    public var defaultLaunch: SessionLaunch { remoteHostID.map { .remoteShell(hostID: $0, directory: nil) } ?? .shell(directory: nil) }
}

/// Fixed color labels for tabs (FR-T04), named like Finder tags so they read the
/// same everywhere; views map them to adaptive system colors.
public enum TabColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, gray

    public var displayName: String {
        switch self {
        case .red: L("Red")
        case .orange: L("Orange")
        case .yellow: L("Yellow")
        case .green: L("Green")
        case .blue: L("Blue")
        case .purple: L("Purple")
        case .gray: L("Gray")
        }
    }
}

public struct WorkspaceTab: Identifiable, Equatable, Codable, Sendable {
    /// A tab with this title shows an automatic title from shell integration (FR-SI05).
    public static let defaultTitle = "Terminal"
    public let id: UUID
    public let spaceID: UUID
    public var title: String
    public var color: TabColor?
    public var root: PaneLayout
    public var activePaneID: UUID
    public var revision: UInt64
    /// The tab's key in its space's project layout (FR-W08). Nil is a temporary tab: one the project doesn't define.
    public var projectKey: String?

    public init(
        id: UUID, spaceID: UUID, title: String, color: TabColor? = nil, root: PaneLayout, activePaneID: UUID, revision: UInt64 = 0, projectKey: String? = nil
    ) {
        self.id = id; self.spaceID = spaceID; self.title = title; self.color = color
        self.root = root; self.activePaneID = activePaneID; self.revision = revision; self.projectKey = projectKey
    }

    private enum CodingKeys: String, CodingKey { case id, spaceID, title, color, root, activePaneID, revision, projectKey }
    /// Workspace schema 3 and older named the owner `windowID`.
    private enum LegacyKeys: String, CodingKey { case windowID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        if let space = try values.decodeIfPresent(UUID.self, forKey: .spaceID) {
            spaceID = space
        } else {
            spaceID = try decoder.container(keyedBy: LegacyKeys.self).decode(UUID.self, forKey: .windowID)
        }
        projectKey = try values.decodeIfPresent(String.self, forKey: .projectKey)
        title = try values.decode(String.self, forKey: .title)
        // A label from a newer build is dropped, never a reason to treat the workspace as corrupt.
        color = (try? values.decodeIfPresent(String.self, forKey: .color)).flatMap { $0.flatMap(TabColor.init(rawValue:)) }
        root = try values.decode(PaneLayout.self, forKey: .root)
        activePaneID = try values.decode(UUID.self, forKey: .activePaneID)
        revision = try values.decode(UInt64.self, forKey: .revision)
    }
}

public struct WorkspacePane: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let tabID: UUID
    public var sessionID: UUID
    public var profileID: String
    public var title: String?

    public init(id: UUID, tabID: UUID, sessionID: UUID, profileID: String = "default", title: String? = nil) {
        self.id = id; self.tabID = tabID; self.sessionID = sessionID
        self.profileID = profileID; self.title = title
    }
}

/// In-memory state, not a persistence format. Persistence encodes a safe snapshot
/// that excludes runtime PID/attempt/status and restores stopped sessions.
public struct WorkspaceSession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var launch: SessionLaunch
    public var state: SessionState
    public var createdAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var processID: Int32?
    public var exitCode: Int32?
    public var failureMessage: String?
    public var launchAttemptID: UUID?

    public init(id: UUID, launch: SessionLaunch = .shell(directory: nil), createdAt: Date = Date()) {
        self.id = id; self.launch = launch; self.state = .stopped
        self.createdAt = createdAt
    }
}

public enum WorkspaceError: Error, Equatable, Sendable {
    case invalidState(String)
    case notFound
    case conflict(expected: UInt64, actual: UInt64)
    case invalidTransition
    case staleLaunch
    case revisionExhausted
}

public struct WorkspaceSnapshot: Equatable, Sendable {
    public var revision: UInt64 = 0
    public var spaces: [Space] = []
    public var activeSpaceID: UUID?
    public var tabs: [UUID: WorkspaceTab] = [:]
    public var panes: [UUID: WorkspacePane] = [:]
    public var sessions: [UUID: WorkspaceSession] = [:]

    public init() {}

    public func validate() throws {
        var ids = Set<UUID>()
        var referencedTabs = Set<UUID>()
        var referencedPanes = Set<UUID>()
        var referencedSessions = Set<UUID>()
        // PIDs are unique per machine: a remote session's PID belongs to its host's namespace.
        struct Owner: Hashable { var host: UUID?; var pid: Int32 }
        var ownedProcessIDs = Set<Owner>()
        func insert(_ id: UUID) throws {
            guard ids.insert(id).inserted else { throw WorkspaceError.invalidState("Duplicate resource ID") }
        }
        func nameIsValid(_ name: String) -> Bool {
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 200
        }
        func visit(_ tree: PaneLayout, tabID: UUID, remoteHostID: UUID?, depth: Int) throws {
            guard depth <= 16 else { throw WorkspaceError.invalidState("Split nesting exceeds 16") }
            switch tree {
            case .pane(let id):
                guard let pane = panes[id], pane.id == id, pane.tabID == tabID,
                    referencedPanes.insert(id).inserted
                else {
                    throw WorkspaceError.invalidState("Missing, duplicate, or incorrectly owned pane")
                }
                try insert(id)
                guard let session = sessions[pane.sessionID], session.id == pane.sessionID,
                    referencedSessions.insert(session.id).inserted
                else {
                    throw WorkspaceError.invalidState("Missing or shared session")
                }
                try insert(session.id)
                guard session.launch.remoteHostID == remoteHostID else {
                    throw WorkspaceError.invalidState("A remote workspace runs only remote shells on its host, and only it does")
                }
                if let pid = session.processID, pid <= 0 { throw WorkspaceError.invalidState("Invalid process ID") }
                switch session.state {
                case .starting:
                    guard session.launchAttemptID != nil, session.processID == nil else {
                        throw WorkspaceError.invalidState("Starting session needs an attempt, not a PID")
                    }
                case .running, .closing:
                    guard let pid = session.processID, session.launchAttemptID == nil else {
                        throw WorkspaceError.invalidState("Running session needs a PID")
                    }
                    guard ownedProcessIDs.insert(Owner(host: remoteHostID, pid: pid)).inserted else {
                        throw WorkspaceError.invalidState("Process is already owned by another session")
                    }
                case .stopped, .exited, .failed:
                    guard session.processID == nil, session.launchAttemptID == nil else {
                        throw WorkspaceError.invalidState("Inactive session contains runtime ownership")
                    }
                }
            case .split(let id, _, let ratio, let children):
                try insert(id)
                guard children.count == 2, ratio.isFinite, (0.1...0.9).contains(ratio) else {
                    throw WorkspaceError.invalidState("Split requires two children and a finite ratio in 0.1...0.9")
                }
                for child in children { try visit(child, tabID: tabID, remoteHostID: remoteHostID, depth: depth + 1) }
            }
        }
        if spaces.isEmpty {
            guard activeSpaceID == nil else { throw WorkspaceError.invalidState("Empty workspace has selection") }
        } else {
            guard spaces.contains(where: { $0.id == activeSpaceID }) else {
                throw WorkspaceError.invalidState("Missing active space")
            }
        }
        guard panes.count <= 100 else { throw WorkspaceError.invalidState("Pane capacity exceeds 100") }
        for space in spaces {
            try insert(space.id)
            guard nameIsValid(space.name), !space.tabIDs.isEmpty,
                space.tabIDs.contains(space.activeTabID), space.revision <= revision
            else {
                throw WorkspaceError.invalidState("Invalid space metadata or selection")
            }
            for id in space.tabIDs {
                guard let tab = tabs[id], tab.id == id, tab.spaceID == space.id,
                    referencedTabs.insert(id).inserted
                else {
                    throw WorkspaceError.invalidState("Missing, duplicate, or incorrectly owned tab")
                }
                try insert(id)
                guard nameIsValid(tab.title), tab.revision <= revision else {
                    throw WorkspaceError.invalidState("Invalid tab metadata")
                }
                try visit(tab.root, tabID: id, remoteHostID: space.remoteHostID, depth: 0)
                guard tab.root.paneIDs.contains(tab.activePaneID) else {
                    throw WorkspaceError.invalidState("Missing active pane")
                }
            }
        }
        guard referencedTabs == Set(tabs.keys), referencedPanes == Set(panes.keys),
            referencedSessions == Set(sessions.keys)
        else {
            throw WorkspaceError.invalidState("Orphan resources")
        }
    }
}
