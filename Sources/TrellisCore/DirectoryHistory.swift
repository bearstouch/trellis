import Darwin
import Foundation

/// One remembered directory (FR-DJ02). Machine and path together identify it.
public struct DirectoryHistoryEntry: Codable, Equatable, Sendable {
    public var path: String
    /// `ProjectTarget.key`: `local`, or the saved host's UUID, so renaming a host keeps its history.
    public var machine: String
    public var visits: Int
    public var lastVisit: Date

    public init(path: String, machine: String, visits: Int, lastVisit: Date) {
        self.path = path; self.machine = machine; self.visits = visits; self.lastVisit = lastVisit
    }

    public var target: ProjectTarget? { ProjectTarget(key: machine) }

    /// Visits times a weight for how long ago the last one was (FR-DJ05).
    public func frecency(now: Date) -> Double {
        let age = now.timeIntervalSince(lastVisit)
        let weight: Double = age < 3_600 ? 4 : age < 86_400 ? 2 : age < 604_800 ? 0.5 : 0.25
        return Double(visits) * weight
    }

    /// For the row's subtitle: "just now", "5m ago", "2h ago", "3d ago", "6w ago".
    public func lastVisitDescription(now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(lastVisit))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        if seconds < 604_800 { return "\(seconds / 86_400)d ago" }
        return "\(seconds / 604_800)w ago"
    }

    /// Best first; ties go to the most recent visit, then to the path so the order is stable.
    public static func ranked(_ entries: [Self], now: Date) -> [Self] {
        entries.map { ($0, $0.frecency(now: now)) }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                if $0.0.lastVisit != $1.0.lastVisit { return $0.0.lastVisit > $1.0.lastVisit }
                return $0.0.path < $1.0.path
            }
            .map(\.0)
    }
}

/// A mounted file system, as the mount table reports it.
public struct DirectoryMount: Equatable, Sendable {
    public var path: String
    public var isLocal: Bool
    public init(path: String, isLocal: Bool) { self.path = path; self.isLocal = isLocal }
}

public enum DirectoryMountTable {
    /// `MNT_NOWAIT` answers from the kernel's table without asking any file system, so a dead share can't block it.
    public static func current() -> [DirectoryMount] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        // Room for a mount that appears between the two calls; one that doesn't fit is picked up next time.
        let buffer = UnsafeMutableBufferPointer<statfs>.allocate(capacity: Int(count) + 8)
        defer { buffer.deallocate() }
        let filled = getfsstat(buffer.baseAddress, Int32(buffer.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard filled > 0 else { return [] }
        return (0..<Int(filled))
            .map { index in
                let path = withUnsafeBytes(of: buffer[index].f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                return DirectoryMount(path: path, isLocal: buffer[index].f_flags & UInt32(MNT_LOCAL) != 0)
            }
    }
}

/// Which directories are never remembered (FR-DJ04).
public enum DirectorySkipRules {
    public static let maximumPathBytes = 1024
    private static let trees = [
        "/net", "/network", "/afs",
        "/proc", "/sys", "/dev", "/run", "/boot", "/tmp", "/var/tmp", "/var/run", "/var/lock", "/lost+found", "/snap", "/etc", "/root",
        "/private/tmp", "/private/var", "/private/etc", "/var/folders", "/system"
    ]
    private static let components: Set<String> = [".ssh", ".gnupg", ".aws", ".kube", ".password-store", ".trash"]

    /// `/a/b/` is `/a/b`. Case is kept: only matching ignores it.
    public static func normalized(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// The path rules, which apply on every machine and need no file system. Expects a normalized path.
    public static func allowsPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", path.utf8.count <= maximumPathBytes, !ProjectText.hasHiddenCharacters(path) else { return false }
        let folded = path.lowercased()
        if trees.contains(where: { isInside(folded, $0) }) { return false }
        let parts = folded.split(separator: "/", omittingEmptySubsequences: true)
        if parts.contains(where: { components.contains(String($0)) }) { return false }
        if parts.count == 2, parts[0] == "users" || parts[0] == "home" { return false }
        return true
    }

    /// Whether a path on this Mac is on a mount that isn't local, or under `/Volumes` without a mount of its own.
    public static func isOnNetworkVolume(_ path: String, mounts: [DirectoryMount]) -> Bool {
        if isOnNonLocalMount(path, mounts: mounts) { return true }
        let folded = path.lowercased()
        guard isInside(folded, "/volumes") else { return false }
        return holder(of: folded, mounts: mounts).map { !isInside($0.path.lowercased(), "/volumes") || $0.path.lowercased() == "/volumes" } ?? true
    }

    /// The rule for what's already in the file: a `/Volumes` path with no mount may just be a disk that isn't plugged in,
    /// and looking at it can't block, so only a mount known not to be local drops it.
    public static func isOnNonLocalMount(_ path: String, mounts: [DirectoryMount]) -> Bool {
        holder(of: path.lowercased(), mounts: mounts).map { !$0.isLocal } ?? false
    }

    private static func holder(of folded: String, mounts: [DirectoryMount]) -> DirectoryMount? {
        mounts.filter { isInside(folded, $0.path.lowercased()) }.max { $0.path.utf8.count < $1.path.utf8.count }
    }

    /// `path` is `tree` or below it, on whole segments.
    private static func isInside(_ path: String, _ tree: String) -> Bool {
        tree == "/" ? path.hasPrefix("/") : path == tree || path.hasPrefix(tree + "/")
    }
}

/// The remembered directories (FR-DJ01–FR-DJ09), in `directory-history.json`. Follows `RemoteHostSettings`, except that a
/// `cd` is far more frequent than a settings change and a write fsyncs twice, so writes are batched.
public actor DirectoryHistory {
    public static let fileName = "directory-history.json"
    public static let backupName = "directory-history.backup.json"
    public static let capacity = 100
    public static let saveDelay: TimeInterval = 2
    static let byteLimit = 1_048_576
    static let unreadableName = "directory-history"
    /// A count that absurd can't be earned, and clamping it keeps the rank arithmetic exact.
    static let maximumVisits = 1_000_000

    private let directory: URL?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let mounts: @Sendable () -> [DirectoryMount]
    private var entries: [DirectoryHistoryEntry] = []
    private var loaded = false
    private var readOnly = false
    private var pendingSave: Task<Void, Never>?
    /// The last write failed, so quitting tries again even with nothing new to batch.
    private var saveFailed = false

    private struct Document: Codable {
        var version = 1
        var entries: [DirectoryHistoryEntry]
    }
    private struct Version: Decodable { var version: Int }

    public init(
        stateDirectory: URL?, now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        mounts: @escaping @Sendable () -> [DirectoryMount] = DirectoryMountTable.current
    ) {
        directory = stateDirectory; self.now = now; self.sleep = sleep; self.mounts = mounts
    }

    private var url: URL? { directory?.appendingPathComponent(Self.fileName) }
    private var backupURL: URL? { directory?.appendingPathComponent(Self.backupName) }

    /// Best first.
    public func all() -> [DirectoryHistoryEntry] {
        load()
        return DirectoryHistoryEntry.ranked(entries, now: now())
    }

    /// Counts a visit; nil when the rules skip the directory, so nothing changed.
    @discardableResult
    public func record(path rawPath: String, on machine: ProjectTarget) -> [DirectoryHistoryEntry]? {
        load()
        let path = DirectorySkipRules.normalized(rawPath)
        guard DirectorySkipRules.allowsPath(path) else { return nil }
        // A host's mounts can't be inspected from here, and its paths mean nothing on this Mac (FR-DJ07).
        if machine == .local, DirectorySkipRules.isOnNetworkVolume(path, mounts: mounts()) { return nil }
        let time = now()
        if let index = entries.firstIndex(where: { $0.path == path && $0.machine == machine.key }) {
            entries[index].visits = min(entries[index].visits + 1, Self.maximumVisits)
            entries[index].lastVisit = time
        } else {
            entries.append(DirectoryHistoryEntry(path: path, machine: machine.key, visits: 1, lastVisit: time))
            evict()
        }
        scheduleSave()
        return DirectoryHistoryEntry.ranked(entries, now: time)
    }

    @discardableResult
    public func remove(path: String, on machine: ProjectTarget) -> [DirectoryHistoryEntry] {
        load()
        let before = entries.count
        entries.removeAll { $0.path == path && $0.machine == machine.key }
        if entries.count != before { scheduleSave() }
        return DirectoryHistoryEntry.ranked(entries, now: now())
    }

    /// Drops entries for hosts that no longer exist.
    public func retain(hosts: Set<UUID>) -> [DirectoryHistoryEntry] {
        load()
        let kept = entries.filter { entry in
            switch entry.target {
            case .local: true
            case .host(let id): hosts.contains(id)
            case nil: false
            }
        }
        if kept.count != entries.count {
            entries = kept
            scheduleSave()
        }
        return DirectoryHistoryEntry.ranked(entries, now: now())
    }

    /// Deletes every entry and every file holding one. False when a file remains: a newer version's or an unreadable one,
    /// which is never touched, or one that couldn't be deleted. The list is empty either way for this launch.
    public func clear() -> Bool {
        load()
        pendingSave?.cancel(); pendingSave = nil
        saveFailed = false
        entries = []
        guard let directory else { return true }
        let listed: [String]
        do { listed = try FileManager.default.contentsOfDirectory(atPath: directory.path) } catch { return !FileManager.default.fileExists(atPath: directory.path) }
        // The backup and set-aside copies still go when the main file has to stay: they hold the same paths.
        let names = listed.filter { ($0 == Self.fileName && !readOnly) || $0 == Self.backupName || ($0.hasPrefix(Self.unreadableName + ".unreadable.") && $0.hasSuffix(".json")) }
        var removed = !readOnly
        for name in names where unlink(directory.appendingPathComponent(name).path) != 0 && errno != ENOENT { removed = false }
        return removed
    }

    /// Writes a batched change now, for quitting.
    public func flush() {
        guard pendingSave != nil || saveFailed else { return }
        pendingSave?.cancel(); pendingSave = nil
        save()
    }

    private func evict() {
        while entries.count > Self.capacity, let oldest = entries.indices.min(by: { Self.isOlder(entries[$0], entries[$1]) }) { entries.remove(at: oldest) }
    }

    /// Only the last visit decides (FR-DJ03); the rest makes the choice between equal times stable.
    private static func isOlder(_ a: DirectoryHistoryEntry, _ b: DirectoryHistoryEntry) -> Bool {
        if a.lastVisit != b.lastVisit { return a.lastVisit < b.lastVisit }
        if a.visits != b.visits { return a.visits < b.visits }
        return a.path < b.path
    }

    private func scheduleSave() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [sleep] in
            await sleep(Self.saveDelay)
            guard !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    private func saveNow() {
        pendingSave = nil
        save()
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let url else { return }
        let data: Data?
        do { data = try LibraryFile.read(url, limit: Self.byteLimit) } catch { readOnly = true; return }
        guard let data else { return }
        if let version = try? Self.decoder.decode(Version.self, from: data), version.version > 1 { readOnly = true; return }
        guard let document = Self.decode(data) else {
            if (try? LibraryFile.preserveUnreadable(url, name: Self.unreadableName)) == nil { readOnly = true }
            return
        }
        // The file is only as trustworthy as the disk: a path from here can end up typed into a shell.
        var seen = Set<String>()
        let table = mounts()
        entries = document.entries.filter { entry in
            let path = DirectorySkipRules.normalized(entry.path)
            guard path == entry.path, DirectorySkipRules.allowsPath(path), entry.target != nil, entry.visits > 0 else { return false }
            if entry.target == .local, DirectorySkipRules.isOnNonLocalMount(path, mounts: table) { return false }
            return seen.insert(entry.machine + "\n" + path).inserted
        }
        entries = entries.map {
            var entry = $0; entry.visits = min(entry.visits, Self.maximumVisits); return entry
        }
        evict()
    }

    private static func decode(_ data: Data) -> Document? {
        guard let document = try? decoder.decode(Document.self, from: data), document.version == 1 else { return nil }
        return document
    }

    private func save() {
        guard let url, let backupURL, !readOnly else { return }
        // Stored oldest-visit last and in a fixed order, so an unchanged history encodes to the same bytes.
        let document = Document(entries: entries.sorted { Self.isOlder($1, $0) })
        guard let data = try? Self.encoder.encode(document) else { return }
        do {
            try LibraryFile.write(data, to: url, backup: backupURL, limit: Self.byteLimit) { Self.decode($0) != nil }
            saveFailed = false
        } catch { saveFailed = true }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
