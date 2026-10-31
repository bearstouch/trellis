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

    /// The host whose remote helper owns this session, for remote workspace sessions only.
    public var remoteHostID: UUID? { if case .remoteShell(let id, _) = self { id } else { nil } }
}

public enum SessionState: String, Codable, Sendable {
    case stopped, starting, running, closing, exited, failed
}

public struct ManagedWindow: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var tabIDs: [UUID]
    public var activeTabID: UUID
    public var revision: UInt64
    /// A remote workspace (FR-RW01): every session in it is a `.remoteShell` on this saved host.
    public var remoteHostID: UUID?

    public init(id: UUID, name: String, tabIDs: [UUID], activeTabID: UUID, revision: UInt64 = 0, remoteHostID: UUID? = nil) {
        self.id = id; self.name = name; self.tabIDs = tabIDs
        self.activeTabID = activeTabID; self.revision = revision; self.remoteHostID = remoteHostID
    }

    /// What a new pane in this window runs.
    public var defaultLaunch: SessionLaunch { remoteHostID.map { .remoteShell(hostID: $0, directory: nil) } ?? .shell(directory: nil) }
}

/// Fixed color labels for tabs (FR-T04), named like Finder tags so they read the
/// same everywhere; views map them to adaptive system colors.
public enum TabColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, gray

    public var displayName: String { rawValue.capitalized }
}

public struct WorkspaceTab: Identifiable, Equatable, Codable, Sendable {
    /// A tab with this title shows an automatic title from shell integration (FR-SI05).
    public static let defaultTitle = "Terminal"
    public let id: UUID
    public let windowID: UUID
    public var title: String
    public var color: TabColor?
    public var root: PaneLayout
    public var activePaneID: UUID
    public var revision: UInt64

    public init(id: UUID, windowID: UUID, title: String, color: TabColor? = nil, root: PaneLayout, activePaneID: UUID, revision: UInt64 = 0) {
        self.id = id; self.windowID = windowID; self.title = title; self.color = color
        self.root = root; self.activePaneID = activePaneID; self.revision = revision
    }

    private enum CodingKeys: String, CodingKey { case id, windowID, title, color, root, activePaneID, revision }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        windowID = try values.decode(UUID.self, forKey: .windowID)
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
    public var windows: [ManagedWindow] = []
    public var activeWindowID: UUID?
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
        if windows.isEmpty {
            guard activeWindowID == nil else { throw WorkspaceError.invalidState("Empty workspace has selection") }
        } else {
            guard windows.contains(where: { $0.id == activeWindowID }) else {
                throw WorkspaceError.invalidState("Missing active window")
            }
        }
        guard panes.count <= 100 else { throw WorkspaceError.invalidState("Pane capacity exceeds 100") }
        for window in windows {
            try insert(window.id)
            guard nameIsValid(window.name), !window.tabIDs.isEmpty,
                window.tabIDs.contains(window.activeTabID), window.revision <= revision
            else {
                throw WorkspaceError.invalidState("Invalid window metadata or selection")
            }
            for id in window.tabIDs {
                guard let tab = tabs[id], tab.id == id, tab.windowID == window.id,
                    referencedTabs.insert(id).inserted
                else {
                    throw WorkspaceError.invalidState("Missing, duplicate, or incorrectly owned tab")
                }
                try insert(id)
                guard nameIsValid(tab.title), tab.revision <= revision else {
                    throw WorkspaceError.invalidState("Invalid tab metadata")
                }
                try visit(tab.root, tabID: id, remoteHostID: window.remoteHostID, depth: 0)
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
