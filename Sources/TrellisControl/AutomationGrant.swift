import CryptoKit
import Darwin
import Foundation
import Security

public enum Capability: String, Codable, CaseIterable, Sendable, Comparable {
    case metadataRead = "metadata.read"
    case layoutWrite = "layout.write"
    case sessionStart = "session.start"
    case sessionInput = "session.input"
    case sessionExecute = "session.execute"
    case sessionOutputRead = "session.output.read"
    case sessionClose = "session.close"
    case themeRead = "theme.read"
    case themeWrite = "theme.write"
    case hostRead = "host.read"
    case hostWrite = "host.write"

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The v1 name of a stored v2 capability (migration.md, Capabilities); nil for the areas v1 has no capability for, which
    /// protocol 1 never sees.
    public init?(_ v2: CapabilityV2) {
        switch v2 {
        case .workspaceRead: self = .metadataRead
        case .workspaceWrite: self = .layoutWrite
        case .sessionStart: self = .sessionStart
        case .sessionInput: self = .sessionInput
        case .sessionExecute: self = .sessionExecute
        case .sessionOutputRead: self = .sessionOutputRead
        case .sessionClose: self = .sessionClose
        case .themeRead: self = .themeRead
        case .themeWrite: self = .themeWrite
        case .hostRead: self = .hostRead
        case .hostWrite: self = .hostWrite
        case .agentControl, .agentRespond, .agentInstall, .remoteConnect, .remoteManage, .projectRead, .projectWrite, .projectLaunch, .taskRead, .taskRun: return nil
        }
    }

    /// Plain-language description shown when creating a grant.
    public var summary: String {
        switch self {
        case .metadataRead: "List spaces, tabs, panes, and session states"
        case .layoutWrite: "Create, rename, split, resize, and focus layout (new panes stay stopped)"
        case .sessionStart: "Start stopped sessions with the default shell or an approved host"
        case .sessionInput: "Type into terminals, including control keys (can run commands)"
        case .sessionExecute: "Run arbitrary programs and shell commands"
        case .sessionOutputRead: "Read terminal screens, scrollback, and output"
        case .sessionClose: "Terminate running sessions"
        case .themeRead: "Read themes and appearance (global)"
        case .themeWrite: "Change themes and appearance for every space (global)"
        case .hostRead: "Read saved hosts, aliases, and identity-file paths"
        case .hostWrite: "Create, edit, and delete saved hosts"
        }
    }
}

/// The spaces a grant reaches (permissions.md#scopes), and with them their tabs, panes and sessions.
public enum SpaceScope: Equatable, Sendable {
    case all
    /// Only the spaces this grant created through protocol 2 (`AutomationGrant.createdSpaces`). Protocol 1 treats it as
    /// that set of spaces, so it can't create spaces (that needs all spaces there).
    case created
    case spaces(Set<UUID>)
}

public enum ProjectScope: Equatable, Sendable {
    case all
    case projects(Set<UUID>)
}

/// Agent definition IDs (`trellis-claude-code`). Limits starting and installing; runs of other agents stay readable.
public enum AgentScope: Equatable, Sendable {
    case all
    case agents(Set<String>)
}

/// A host approved for this grant at a specific connection revision.
public struct HostApproval: Codable, Equatable, Hashable, Sendable {
    public let hostID: UUID
    public let connectionRevision: UInt64
    public init(hostID: UUID, connectionRevision: UInt64) { self.hostID = hostID; self.connectionRevision = connectionRevision }
}

public enum HostScope: Equatable, Sendable {
    case all
    case approved(Set<HostApproval>)
}

public struct GrantScope: Equatable, Sendable {
    public var spaces: SpaceScope
    public var projects: ProjectScope
    public var hosts: HostScope
    public var agents: AgentScope
    public init(spaces: SpaceScope = .all, projects: ProjectScope = .all, hosts: HostScope = .all, agents: AgentScope = .all) {
        self.spaces = spaces; self.projects = projects; self.hosts = hosts; self.agents = agents
    }
}

/// The grant sheet's presets (permissions.md#presets). A grant stores its capabilities, which are what is enforced, and
/// the preset they came from, for display; changing a capability makes it Custom.
public enum GrantPreset: String, Codable, CaseIterable, Sendable {
    case observer, `operator`, agentOrchestrator, fullControl, custom

    /// Exactly the preset's capabilities; nil for Custom.
    public var capabilities: Set<CapabilityV2>? {
        switch self {
        case .observer: [.workspaceRead, .sessionOutputRead, .hostRead, .projectRead, .taskRead, .themeRead]
        case .operator: Self.observer.capabilities!.union([.workspaceWrite, .sessionStart, .sessionInput, .sessionClose, .taskRun])
        case .agentOrchestrator: Self.operator.capabilities!.union([.agentControl, .agentRespond, .projectLaunch, .remoteConnect])
        case .fullControl: Set(CapabilityV2.allCases)
        case .custom: nil
        }
    }

    /// The scope the sheet starts from. Host access stays opt-in (approved hosts) wherever the preset can start sessions,
    /// except Full control; an orchestrator sees only the spaces it creates.
    public var defaultScope: GrantScope {
        switch self {
        case .observer, .fullControl, .custom: GrantScope()
        case .operator: GrantScope(hosts: .approved([]))
        case .agentOrchestrator: GrantScope(spaces: .created, hosts: .approved([]))
        }
    }
}

/// Everything the user chooses for a grant: all but its token, times and runtime state.
public struct GrantSettings: Equatable, Sendable {
    public var name: String
    public var preset: GrantPreset
    public var capabilities: Set<CapabilityV2>
    public var scope: GrantScope
    public init(name: String, preset: GrantPreset = .custom, capabilities: Set<CapabilityV2>, scope: GrantScope = GrantScope()) {
        self.name = name; self.preset = preset; self.capabilities = capabilities; self.scope = scope
    }
}

/// Grant metadata, stored as a `grants.json` schema 2 record. The token itself is never stored here, only its SHA-256.
public struct AutomationGrant: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let tokenHash: String
    public var preset: GrantPreset
    /// Increases on every edit (permissions.md#editing-grants).
    public var revision: UInt64
    /// Protocol 2 capabilities: what is enforced. Protocol 1 sees them through `capabilities`.
    public var capabilitiesV2: Set<CapabilityV2>
    public var spaceScope: SpaceScope
    public var hostScope: HostScope
    public var projectScope: ProjectScope
    public var agentScope: AgentScope
    /// Spaces this grant created through protocol 2: the members of the `created` scope. Kept whatever the scope, so a
    /// grant narrowed to `created` keeps what it made; IDs of closed spaces are pruned and grant nothing anyway.
    public var createdSpaces: Set<UUID>
    public let createdAt: Date
    public var expiresAt: Date
    public var revokedAt: Date?
    /// Connections that authenticated at an older revision must authenticate again. Raised by an edit that narrows the
    /// grant; never stored, since no connection outlives the app.
    public var reauthenticateBelow: UInt64 = 0

    public init(
        id: UUID, tokenHash: String, settings: GrantSettings, createdAt: Date, expiresAt: Date, revision: UInt64 = 1, createdSpaces: Set<UUID> = [],
        revokedAt: Date? = nil
    ) {
        self.id = id; name = settings.name; self.tokenHash = tokenHash; preset = settings.preset; self.revision = revision
        capabilitiesV2 = settings.capabilities; spaceScope = settings.scope.spaces; hostScope = settings.scope.hosts; projectScope = settings.scope.projects
        agentScope = settings.scope.agents; self.createdSpaces = createdSpaces; self.createdAt = createdAt; self.expiresAt = expiresAt; self.revokedAt = revokedAt
    }

    /// A grant as protocol 1 describes it: v1 capabilities mapped to v2, Custom, every project and agent (which the mapped
    /// capabilities can't use).
    public init(
        id: UUID, name: String, tokenHash: String, capabilities: Set<Capability>, spaceScope: SpaceScope, hostScope: HostScope, createdAt: Date, expiresAt: Date,
        revokedAt: Date? = nil
    ) {
        self.init(
            id: id, tokenHash: tokenHash,
            settings: GrantSettings(name: name, capabilities: Set(capabilities.map(CapabilityV2.init)), scope: GrantScope(spaces: spaceScope, hosts: hostScope)),
            createdAt: createdAt, expiresAt: expiresAt, revokedAt: revokedAt)
    }

    /// Protocol 1's view: v2 capabilities under their v1 names; capabilities of new areas are invisible.
    public var capabilities: Set<Capability> { Set(capabilitiesV2.compactMap(Capability.init)) }

    public var scope: GrantScope { GrantScope(spaces: spaceScope, projects: projectScope, hosts: hostScope, agents: agentScope) }
    public var settings: GrantSettings { GrantSettings(name: name, preset: preset, capabilities: capabilitiesV2, scope: scope) }

    public func isActive(at now: Date) -> Bool { revokedAt == nil && now < expiresAt }
    public func allows(_ capability: Capability) -> Bool { capabilitiesV2.contains(CapabilityV2(capability)) }
    public func holds(_ capability: CapabilityV2) -> Bool { capabilitiesV2.contains(capability) }

    /// Whether the space scope includes this space ID (existence is the caller's check).
    public func reaches(space id: UUID) -> Bool {
        switch spaceScope {
        case .all: true
        case .created: createdSpaces.contains(id)
        case .spaces(let ids): ids.contains(id)
        }
    }

    /// Creating a top-level space needs `all` or `created` space scope; with `created` the new space joins it.
    public var mayCreateSpaces: Bool { spaceScope == .all || spaceScope == .created }

    // MARK: Schema 2 record

    private enum CodingKeys: String, CodingKey { case id, name, tokenHash, preset, revision, capabilities, scope, createdSpaces, createdAt, expiresAt, revokedAt }
    private enum ScopeKeys: String, CodingKey { case spaces, projects, hosts, agents }
    private struct HostRecord: Codable {
        let hostId: UUID
        let connectionRevision: UInt64
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        tokenHash = try c.decode(String.self, forKey: .tokenHash)
        preset = try c.decode(GrantPreset.self, forKey: .preset)
        revision = try c.decode(UInt64.self, forKey: .revision)
        // An unknown capability (from a newer build) fails the load, so nothing is overwritten.
        capabilitiesV2 = try c.decode(Set<CapabilityV2>.self, forKey: .capabilities)
        let s = try c.nestedContainer(keyedBy: ScopeKeys.self, forKey: .scope)
        spaceScope = try Self.scope(s, .spaces, words: ["all": .all, "created": .created]) { .spaces(Set(try $0.map(Self.uuid))) }
        projectScope = try Self.scope(s, .projects, words: ["all": .all]) { .projects(Set(try $0.map(Self.uuid))) }
        agentScope = try Self.scope(s, .agents, words: ["all": .all]) { .agents(Set($0)) }
        if (try? s.decode(String.self, forKey: .hosts)) == "all" {
            hostScope = .all
        } else {
            hostScope = .approved(Set(try s.decode([HostRecord].self, forKey: .hosts).map { HostApproval(hostID: $0.hostId, connectionRevision: $0.connectionRevision) }))
        }
        createdSpaces = try c.decodeIfPresent(Set<UUID>.self, forKey: .createdSpaces) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        revokedAt = try c.decodeIfPresent(Date.self, forKey: .revokedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(tokenHash, forKey: .tokenHash)
        try c.encode(preset, forKey: .preset)
        try c.encode(revision, forKey: .revision)
        try c.encode(capabilitiesV2.sorted(), forKey: .capabilities)
        var s = c.nestedContainer(keyedBy: ScopeKeys.self, forKey: .scope)
        switch spaceScope {
        case .all: try s.encode("all", forKey: .spaces)
        case .created: try s.encode("created", forKey: .spaces)
        case .spaces(let ids): try s.encode(Self.sorted(ids), forKey: .spaces)
        }
        switch projectScope {
        case .all: try s.encode("all", forKey: .projects)
        case .projects(let ids): try s.encode(Self.sorted(ids), forKey: .projects)
        }
        switch hostScope {
        case .all: try s.encode("all", forKey: .hosts)
        case .approved(let approvals):
            try s.encode(
                approvals.sorted { $0.hostID.uuidString < $1.hostID.uuidString }.map { HostRecord(hostId: $0.hostID, connectionRevision: $0.connectionRevision) },
                forKey: .hosts)
        }
        switch agentScope {
        case .all: try s.encode("all", forKey: .agents)
        case .agents(let ids): try s.encode(ids.sorted(), forKey: .agents)
        }
        if !createdSpaces.isEmpty { try c.encode(Self.sorted(createdSpaces), forKey: .createdSpaces) }
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encodeIfPresent(revokedAt, forKey: .revokedAt)
    }

    private static func sorted(_ ids: Set<UUID>) -> [String] { ids.map { $0.uuidString.lowercased() }.sorted() }

    private static func uuid(_ text: String) throws -> UUID {
        guard let id = UUID(uuidString: text) else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not a UUID")) }
        return id
    }

    /// A scope stored as a word (`all`, `created`) or a list of IDs.
    private static func scope<T>(_ c: KeyedDecodingContainer<ScopeKeys>, _ key: ScopeKeys, words: [String: T], list: ([String]) throws -> T) throws -> T {
        if let word = try? c.decode(String.self, forKey: key) {
            guard let value = words[word] else { throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Unknown scope") }
            return value
        }
        return try list(try c.decode([String].self, forKey: key))
    }
}

/// A `grants.json` record as protocol 1 builds wrote it (schema 1: a bare array). Read once, by the migration; its
/// `windowScope`/`windows` names are never written again.
struct LegacyGrantV1: Decodable {
    enum SpaceScopeV1: Decodable {
        case all
        case spaces(Set<UUID>)
        private enum CodingKeys: String, CodingKey { case all, spaces = "windows" }
    }
    enum HostScopeV1: Decodable {
        case all
        case approved(Set<HostApproval>)
    }
    let id: UUID
    let name: String
    let tokenHash: String
    let capabilities: Set<Capability>
    let windowScope: SpaceScopeV1
    let hostScope: HostScopeV1
    let createdAt: Date
    let expiresAt: Date
    let revokedAt: Date?

    /// Exactly the mapped capabilities, never more (migration.md); Custom, with every project and agent.
    var migrated: AutomationGrant {
        let spaces: SpaceScope =
            switch windowScope {
            case .all: .all
            case .spaces(let ids): .spaces(ids)
            }
        let hosts: HostScope =
            switch hostScope {
            case .all: .all
            case .approved(let approvals): .approved(approvals)
            }
        return AutomationGrant(
            id: id, name: name, tokenHash: tokenHash, capabilities: capabilities, spaceScope: spaces, hostScope: hosts, createdAt: createdAt, expiresAt: expiresAt,
            revokedAt: revokedAt)
    }
}

/// How an edit changes what a grant reaches. Widening (a capability or scope added, a later expiry) needs the user's
/// confirmation; narrowing applies at once and makes open connections authenticate again. An edit can do both.
public struct GrantChange: Equatable, Sendable {
    public var widens = false
    public var narrows = false
    public init(widens: Bool = false, narrows: Bool = false) { self.widens = widens; self.narrows = narrows }

    public init(from old: AutomationGrant, to settings: GrantSettings, expiresAt: Date) {
        func add(_ change: (widens: Bool, narrows: Bool)) { widens = widens || change.widens; narrows = narrows || change.narrows }
        add((!settings.capabilities.isSubset(of: old.capabilitiesV2), !old.capabilitiesV2.isSubset(of: settings.capabilities)))
        add(Self.compare(old.spaceScope, settings.scope.spaces, created: old.createdSpaces))
        add(Self.compare(old.projectScope.ids, settings.scope.projects.ids))
        add(Self.compare(old.agentScope.ids, settings.scope.agents.ids))
        add(Self.compare(old.hostScope, settings.scope.hosts))
        add((expiresAt > old.expiresAt, expiresAt < old.expiresAt))
    }

    /// nil means all.
    static func compare<T>(_ old: Set<T>?, _ new: Set<T>?) -> (widens: Bool, narrows: Bool) {
        switch (old, new) {
        case (nil, nil): (false, false)
        case (nil, _?): (false, true)
        case (_?, nil): (true, false)
        case (let old?, let new?): (!new.isSubset(of: old), !old.isSubset(of: new))
        }
    }

    /// `created` reaches the spaces created so far and may create more, so moving to it from a set widens.
    static func compare(_ old: SpaceScope, _ new: SpaceScope, created: Set<UUID>) -> (widens: Bool, narrows: Bool) {
        switch (old, new) {
        case (.all, .all), (.created, .created): (false, false)
        case (.all, _): (false, true)
        case (_, .all): (true, false)
        case (.created, .spaces(let ids)): (!ids.isSubset(of: created), true)
        case (.spaces(let ids), .created): (true, !ids.isSubset(of: created))
        case (.spaces(let old), .spaces(let new)): compare(Optional(old), Optional(new))
        }
    }

    /// Approvals compare by host; approving a host at a newer connection revision widens (it was unusable before).
    static func compare(_ old: HostScope, _ new: HostScope) -> (widens: Bool, narrows: Bool) {
        switch (old, new) {
        case (.all, .all): return (false, false)
        case (.all, .approved): return (false, true)
        case (.approved, .all): return (true, false)
        case (.approved(let old), .approved(let new)):
            let before = Dictionary(old.map { ($0.hostID, $0.connectionRevision) }, uniquingKeysWith: max)
            let after = Dictionary(new.map { ($0.hostID, $0.connectionRevision) }, uniquingKeysWith: max)
            return (after.contains { before[$0.key] != $0.value }, before.keys.contains { after[$0] == nil })
        }
    }
}

extension ProjectScope {
    var ids: Set<UUID>? { if case .projects(let ids) = self { ids } else { nil } }
}

extension AgentScope {
    var ids: Set<String>? { if case .agents(let ids) = self { ids } else { nil } }
}

/// The identity and connection revision of a host being approved.
public struct SavedHostApprovalInput: Sendable {
    public let id: UUID
    public let connectionRevision: UInt64
    public init(id: UUID, connectionRevision: UInt64) { self.id = id; self.connectionRevision = connectionRevision }
}

public enum GrantError: Error, Equatable, Sendable {
    case invalidName, noCapabilities, invalidExpiry, notFound, io, secretStore
    /// `grants.json` exists but is unreadable or newer; it is preserved, not overwritten.
    case readOnly
    /// The edit widens the grant and wasn't confirmed; nothing changed.
    case confirmationRequired
    /// The grant changed since the edit started; nothing changed.
    case conflict
}

/// Where the token secret lives so the CLI can use a Keychain credential reference.
public protocol GrantSecretStore: Sendable {
    func store(_ token: String, grantID: UUID) throws
    func remove(grantID: UUID)
}

/// Generic-password items in the login Keychain, one per grant.
public struct KeychainGrantSecretStore: GrantSecretStore {
    public static let service = "Trellis Automation"
    public init() {}

    public func store(_ token: String, grantID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
            kSecAttrAccount as String: grantID.uuidString, kSecValueData as String: Data(token.utf8),
            kSecAttrLabel as String: "Trellis automation grant", kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw GrantError.secretStore }
    }

    public func remove(grantID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: grantID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public enum GrantToken {
    /// 256 random bits, URL-safe, with a recognizable prefix for leak scanning.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        return "trl_"
            + Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func hash(_ token: String) -> String {
        "sha256:" + SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Compares every byte regardless of where the first difference is.
    static func matches(_ token: String, hash expected: String) -> Bool {
        let actual = Array(hash(token).utf8), wanted = Array(expected.utf8)
        guard actual.count == wanted.count else { return false }
        return zip(actual, wanted).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Bounded no-follow reads and fsync + rename publication with mode 0600.
public enum OwnerOnlyFile {
    public static func read(_ url: URL, limit: Int) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return nil }; throw POSIXError(.EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_size <= limit else { throw POSIXError(.EINVAL) }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= limit else { throw POSIXError(.EFBIG) }
        }
    }

    public static func publish(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var ok = true
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { ok = false; return }
                offset += written
            }
        }
        ok = ok && fsync(fd) == 0
        ok = close(fd) == 0 && ok
        guard ok, rename(temporary, url.path) == 0 else {
            unlink(temporary)
            throw POSIXError(.EIO)
        }
    }
}
