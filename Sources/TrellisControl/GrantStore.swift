import Foundation

/// Membership of the `created` space scope: the spaces each grant created through protocol 2. It is written
/// synchronously inside the store transaction that creates the space, so no later call, projection or event can see the
/// space before its grant does; the grant store saves it with the grants.
public final class CreatedSpaceLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var spaces: [UUID: Set<UUID>] = [:]
    private var changed: @Sendable () -> Void = {}

    public init() {}

    public func record(_ space: UUID, grant: UUID) {
        let inserted = lock.withLock { spaces[grant, default: []].insert(space).inserted }
        if inserted { lock.withLock { changed }() }
    }

    public func spaces(of grant: UUID) -> Set<UUID> { lock.withLock { spaces[grant] ?? [] } }

    /// The grants that created this space (protocol 2 stamps each event with them, so a closed space's last events stay
    /// visible to its `created` grants after the space left their scope).
    public func grants(creating space: UUID) -> Set<UUID> { lock.withLock { Set(spaces.filter { $0.value.contains(space) }.keys) } }

    /// Drops closed spaces; true when anything was removed.
    func forget(_ removed: Set<UUID>) -> Bool {
        lock.withLock {
            var any = false
            for (grant, ids) in spaces where !ids.isDisjoint(with: removed) {
                spaces[grant] = ids.subtracting(removed)
                any = true
            }
            return any
        }
    }

    func reset(_ grants: [AutomationGrant], onChange: @escaping @Sendable () -> Void) {
        lock.withLock {
            spaces = Dictionary(grants.filter { !$0.createdSpaces.isEmpty }.map { ($0.id, $0.createdSpaces) }, uniquingKeysWith: { $0.union($1) })
            changed = onChange
        }
    }
}

/// One saved edit, for observers: what the grant was, what it is, and how its reach changed.
public struct GrantEdit: Sendable {
    public let old: AutomationGrant
    public let new: AutomationGrant
    public let change: GrantChange
}

/// Owner-only, atomically published `grants.json` (schema 2, permissions.md#storage). Revoked and expired grants
/// remain listed (inactive) so their status stays visible. The actor is the file's single writer.
public actor GrantStore {
    public static let schemaVersion = 2
    /// Records as stored; `createdSpaces` is current in `createdSpaceLedger`, merged into every grant handed out.
    private var records: [AutomationGrant] = []
    private let url: URL?
    private let secrets: any GrantSecretStore
    private let now: @Sendable () -> Date
    private var revocationObservers: [@Sendable (UUID) -> Void] = []
    private var editObservers: [@Sendable (GrantEdit) -> Void] = []
    /// Set when the stored file cannot be used: no grant is active and nothing is written.
    public private(set) var loadFailed = false
    /// The schema 1 file, until its backup is written: every write saves it first, so the migration never loses it.
    private var pendingBackup: Data?
    public nonisolated let createdSpaceLedger = CreatedSpaceLedger()

    /// `url == nil` keeps grants in memory only (tests).
    public init(url: URL?, secrets: any GrantSecretStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url; self.secrets = secrets; self.now = now
    }

    /// Every grant, with its current created spaces.
    public var grants: [AutomationGrant] { records.map(merged) }

    private var loaded = false

    /// Loads once before the first authentication, so a client connecting during
    /// app startup is never rejected (or rate limited) for an unloaded store.
    public func ensureLoaded() {
        if !loaded { load() }
    }

    /// Reads schema 2, or migrates schema 1 once (backup `grants.json.v1.bak`, then an atomic replace). An unreadable or
    /// newer file is preserved: no grant is active and nothing is written.
    public func load() {
        loaded = true
        defer { createdSpaceLedger.reset(records) { [weak self] in Task { await self?.saveCreatedSpaces() } } }
        guard let url else { return }
        do {
            guard let data = try OwnerOnlyFile.read(url, limit: 1_048_576) else { records = []; loadFailed = false; return }
            if data.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) == UInt8(ascii: "[") {
                records = try JSONDecoder.grants.decode([LegacyGrantV1].self, from: data).map(\.migrated)
                loadFailed = false
                pendingBackup = data
                // A failed write keeps the migrated grants usable; the next write tries again, backup first.
                createdSpaceLedger.reset(records) {}
                try? persist(records)
                return
            }
            struct Header: Decodable { let schemaVersion: Int }
            guard try JSONDecoder.grants.decode(Header.self, from: data).schemaVersion == Self.schemaVersion else { throw GrantError.readOnly }
            records = try JSONDecoder.grants.decode(GrantFile.self, from: data).grants
            loadFailed = false
        } catch {
            records = []; loadFailed = true
        }
    }

    /// Called with the grant ID whenever a grant is revoked.
    public func onRevocation(_ observer: @escaping @Sendable (UUID) -> Void) { revocationObservers.append(observer) }

    /// Called after every saved edit (including host reapproval). Phase 4 emits `grant.changed` from here.
    public func onEdit(_ observer: @escaping @Sendable (GrantEdit) -> Void) { editObservers.append(observer) }

    /// Protocol 1's create: v1 capabilities mapped to v2, preset Custom, every project and agent.
    public func create(
        name: String, capabilities: Set<Capability>, spaceScope: SpaceScope, hostScope: HostScope, lifetime: TimeInterval
    ) throws(GrantError) -> (grant: AutomationGrant, token: String) {
        try create(
            GrantSettings(name: name, capabilities: Set(capabilities.map(CapabilityV2.init)), scope: GrantScope(spaces: spaceScope, hosts: hostScope)), lifetime: lifetime)
    }

    /// Returns the grant and its token. The token is not retrievable later.
    public func create(_ settings: GrantSettings, lifetime: TimeInterval) throws(GrantError) -> (grant: AutomationGrant, token: String) {
        let settings = try Self.validated(settings)
        try Self.validate(lifetime: lifetime)
        // Never publish a list built from an unloaded store: it would drop the saved grants.
        ensureLoaded()
        guard !loadFailed else { throw .readOnly }
        let token = GrantToken.generate()
        let created = now()
        let grant = AutomationGrant(
            id: UUID(), tokenHash: GrantToken.hash(token), settings: settings, createdAt: created, expiresAt: created.addingTimeInterval(lifetime))
        do { try secrets.store(token, grantID: grant.id) } catch { throw .secretStore }
        do {
            try persist(records + [grant])
        } catch {
            secrets.remove(grantID: grant.id)
            throw error
        }
        records.append(grant)
        return (grant, token)
    }

    /// Changes name, capabilities, preset, scopes and (with `lifetime`, counted from now) expiry; never the token. Every
    /// edit raises the revision. A widening edit needs `confirmedWidening` (the UI asks first) and is saved before it
    /// applies; a narrowing one applies at once, even if saving then fails, and makes open connections authenticate again.
    @discardableResult
    public func update(
        _ id: UUID, to settings: GrantSettings, lifetime: TimeInterval? = nil, expectedRevision: UInt64, confirmedWidening: Bool
    ) throws(GrantError) -> AutomationGrant {
        let settings = try Self.validated(settings)
        if let lifetime { try Self.validate(lifetime: lifetime) }
        guard !loadFailed else { throw .readOnly }
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].isActive(at: now()) else { throw .notFound }
        let old = merged(records[index])
        guard old.revision == expectedRevision else { throw .conflict }
        let expiresAt = lifetime.map { now().addingTimeInterval($0) } ?? old.expiresAt
        guard settings != old.settings || expiresAt != old.expiresAt else { return old }
        let change = GrantChange(from: old, to: settings, expiresAt: expiresAt)
        if change.widens && !confirmedWidening { throw .confirmationRequired }
        var grant = AutomationGrant(
            id: old.id, tokenHash: old.tokenHash, settings: settings, createdAt: old.createdAt, expiresAt: expiresAt, revision: old.revision + 1,
            createdSpaces: old.createdSpaces)
        grant.reauthenticateBelow = change.narrows ? grant.revision : old.reauthenticateBelow
        var next = records
        next[index] = grant
        try apply(next, edit: GrantEdit(old: old, new: grant, change: change))
        return grant
    }

    public func revoke(_ id: UUID) throws(GrantError) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw .notFound }
        guard records[index].revokedAt == nil else { return }
        var next = records
        next[index].revokedAt = now()
        // Block use immediately, even if the file write then fails.
        records = next
        secrets.remove(grantID: id)
        for observer in revocationObservers { observer(id) }
        try persist(next)
    }

    /// Replaces host approvals with the hosts' current connection revisions (reapproval needs no further confirmation:
    /// the user approves exactly these hosts again). Hosts the grant hadn't approved are ignored: adding one widens the
    /// grant, which only a confirmed `update` may do.
    public func approveHosts(_ grantID: UUID, hosts: [SavedHostApprovalInput]) throws(GrantError) {
        guard let index = records.firstIndex(where: { $0.id == grantID }), records[index].revokedAt == nil else { throw .notFound }
        let old = merged(records[index])
        var hosts = hosts
        if case .approved(let approved) = old.hostScope { hosts = hosts.filter { host in approved.contains { $0.hostID == host.id } } }
        var settings = old.settings
        settings.scope.hosts = .approved(Set(hosts.map { HostApproval(hostID: $0.id, connectionRevision: $0.connectionRevision) }))
        let change = GrantChange(from: old, to: settings, expiresAt: old.expiresAt)
        var grant = old
        grant.hostScope = settings.scope.hosts
        grant.revision += 1
        if change.narrows { grant.reauthenticateBelow = grant.revision }
        var next = records
        next[index] = grant
        try apply(next, edit: GrantEdit(old: old, new: grant, change: change))
    }

    /// Matching active grant for a presented token, if any.
    public func activeGrant(token: String) -> AutomationGrant? {
        records.first { GrantToken.matches(token, hash: $0.tokenHash) && $0.isActive(at: now()) }.map(merged)
    }

    public func activeGrant(id: UUID) -> AutomationGrant? { records.first { $0.id == id && $0.isActive(at: now()) }.map(merged) }

    public func currentDate() -> Date { now() }

    /// Adds a space a grant created to its `created` scope, at once and without waiting for the actor: called from inside
    /// the workspace transaction that creates it. Saved in the background.
    public nonisolated func recordCreatedSpace(_ space: UUID, grant: UUID) { createdSpaceLedger.record(space, grant: grant) }

    /// Closed spaces leave every grant's `created` scope.
    public func forgetCreatedSpaces(_ spaces: Set<UUID>) {
        if createdSpaceLedger.forget(spaces) { saveCreatedSpaces() }
    }

    private func saveCreatedSpaces() {
        guard !loadFailed, url != nil else { return }
        let next = records.map(merged)
        guard next != records else { return }
        // Runtime membership stays in the ledger if this fails; the next write saves it.
        if (try? persist(next)) != nil { records = next }
    }

    private func merged(_ grant: AutomationGrant) -> AutomationGrant {
        var grant = grant
        grant.createdSpaces = createdSpaceLedger.spaces(of: grant.id)
        return grant
    }

    /// Narrowing-only edits apply before saving (like revocation); anything that widens is saved first, so a failed write
    /// changes nothing.
    private func apply(_ next: [AutomationGrant], edit: GrantEdit) throws(GrantError) {
        if edit.change.widens {
            try persist(next)
            records = next
            for observer in editObservers { observer(edit) }
        } else {
            records = next
            // Observers end what lost access even when the write fails: the narrowing already applies.
            for observer in editObservers { observer(edit) }
            try persist(next)
        }
    }

    private static func validated(_ settings: GrantSettings) throws(GrantError) -> GrantSettings {
        var settings = settings
        let trimmed = settings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100, !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw .invalidName
        }
        guard !settings.capabilities.isEmpty else { throw .noCapabilities }
        settings.name = trimmed
        return settings
    }

    private static func validate(lifetime: TimeInterval) throws(GrantError) {
        guard lifetime.isFinite, (60...(90 * 86_400)).contains(lifetime) else { throw .invalidExpiry }
    }

    private func persist(_ next: [AutomationGrant]) throws(GrantError) {
        guard !loadFailed else { throw .readOnly }
        guard let url else { return }
        let merged = next.map(merged)
        guard let data = try? JSONEncoder.grants.encode(GrantFile(schemaVersion: Self.schemaVersion, grants: merged)) else { throw .io }
        if let backup = pendingBackup {
            do { try OwnerOnlyFile.publish(backup, to: url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".v1.bak")) } catch { throw .io }
            pendingBackup = nil
        }
        do { try OwnerOnlyFile.publish(data, to: url) } catch { throw .io }
    }
}

private struct GrantFile: Codable {
    let schemaVersion: Int
    let grants: [AutomationGrant]
}

extension JSONEncoder {
    fileprivate static var grants: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var grants: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
