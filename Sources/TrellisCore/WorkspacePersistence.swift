import Darwin
import Foundation

public struct WorkspaceSettings: Codable, Equatable, Sendable {
    public var shell: String
    public var directory: String
    public var windowFrame: String?
    public var appearance: AppearanceSettings
    public var remoteControl: RemoteControlSettings
    /// FR-R03, FR-R07: sessions stay in `trellis-broker` when Trellis quits. On by default, per state directory; saved as
    /// its inverse, `stopSessionsOnQuit`, so files from the opt-in era (`keepSessionsRunning`) adopt the new default.
    public var keepSessionsRunning: Bool
    /// An older file had the opt-in setting off; Settings explains the new default once.
    public var sessionDefaultNoticePending: Bool
    /// FR-R04: quitting saves each pane's redacted plain text for the next launch. Off by default.
    public var restoreScrollback: Bool
    /// FR-R06: the hourly write budget of the workspace file and its backup, in MB (one of `WorkspaceWriteBudget.choices`).
    public var saveBudgetMegabytesPerHour: Int
    public init(
        shell: String = LocalLaunchConfiguration.loginShell().executable,
        directory: String = FileManager.default.homeDirectoryForCurrentUser.path, windowFrame: String? = nil,
        appearance: AppearanceSettings = .init(), remoteControl: RemoteControlSettings = .init(), keepSessionsRunning: Bool = true, restoreScrollback: Bool = false,
        saveBudgetMegabytesPerHour: Int = WorkspaceWriteBudget.defaultMegabytesPerHour
    ) {
        self.shell = shell; self.directory = directory; self.windowFrame = windowFrame
        self.appearance = appearance; self.remoteControl = remoteControl
        self.keepSessionsRunning = keepSessionsRunning; self.restoreScrollback = restoreScrollback
        sessionDefaultNoticePending = false
        self.saveBudgetMegabytesPerHour = WorkspaceWriteBudget(megabytesPerHour: saveBudgetMegabytesPerHour).megabytesPerHour
    }
    private enum CodingKeys: String, CodingKey {
        case shell, directory, windowFrame, appearance, remoteControl, stopSessionsOnQuit, sessionDefaultNoticePending, restoreScrollback, saveBudgetMegabytesPerHour
    }
    private enum LegacyKeys: String, CodingKey { case keepSessionsRunning }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shell = try values.decode(String.self, forKey: .shell)
        directory = try values.decode(String.self, forKey: .directory)
        windowFrame = try values.decodeIfPresent(String.self, forKey: .windowFrame)
        appearance = try values.decodeIfPresent(AppearanceSettings.self, forKey: .appearance) ?? .init()
        appearance.migrateLegacyThemeIDs()
        guard appearance.isValid else {
            throw DecodingError.dataCorruptedError(forKey: .appearance, in: values, debugDescription: "Invalid appearance settings")
        }
        // An unusable value turns the server off instead of failing the whole workspace.
        let remote = try? values.decodeIfPresent(RemoteControlSettings.self, forKey: .remoteControl)
        remoteControl = remote.flatMap { $0 }.flatMap { $0.isValid ? $0 : nil } ?? .init()
        if let stop = (try? values.decodeIfPresent(Bool.self, forKey: .stopSessionsOnQuit)) ?? nil {
            keepSessionsRunning = !stop
            sessionDefaultNoticePending = (try? values.decodeIfPresent(Bool.self, forKey: .sessionDefaultNoticePending)) ?? false
        } else {
            // The opt-in setting is replaced by the new default; only those for whom quitting used to stop sessions are told.
            keepSessionsRunning = true
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            sessionDefaultNoticePending = legacy.contains(.keepSessionsRunning) && (try? legacy.decode(Bool.self, forKey: .keepSessionsRunning)) != true
        }
        restoreScrollback = (try? values.decodeIfPresent(Bool.self, forKey: .restoreScrollback)) ?? false
        // An unknown budget falls back to the default instead of failing the workspace.
        let budget = (try? values.decodeIfPresent(Int.self, forKey: .saveBudgetMegabytesPerHour)) ?? nil
        saveBudgetMegabytesPerHour = WorkspaceWriteBudget(megabytesPerHour: budget ?? WorkspaceWriteBudget.defaultMegabytesPerHour).megabytesPerHour
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(shell, forKey: .shell)
        try values.encode(directory, forKey: .directory)
        try values.encodeIfPresent(windowFrame, forKey: .windowFrame)
        try values.encode(appearance, forKey: .appearance)
        try values.encode(remoteControl, forKey: .remoteControl)
        try values.encode(!keepSessionsRunning, forKey: .stopSessionsOnQuit)
        if sessionDefaultNoticePending { try values.encode(true, forKey: .sessionDefaultNoticePending) }
        try values.encode(restoreScrollback, forKey: .restoreScrollback)
        try values.encode(saveBudgetMegabytesPerHour, forKey: .saveBudgetMegabytesPerHour)
    }
}

public struct RestoredWorkspace: Sendable {
    public let snapshot: WorkspaceSnapshot
    public let settings: WorkspaceSettings
    public let unconfiguredPaneIDs: Set<UUID>
}

public enum WorkspacePersistenceError: Error, Equatable, Sendable {
    case unsupportedVersion(Int), corrupt, readOnly, io(Int32)
}

private enum SavedLaunch: Codable {
    case shell(executable: String, directory: String?)
    case host(UUID)
    case customProcess(directory: String?)
    case remoteShell(hostID: UUID, directory: String?)
    /// Only the agent's ID and where it ran: never its arguments, and never `resume` (FR-AG06).
    case agent(agentID: String, hostID: UUID?, directory: String?)

    init(_ launch: SessionLaunch, settings: WorkspaceSettings) {
        switch launch {
        case .shell(let directory): self = .shell(executable: settings.shell, directory: directory)
        case .host(let id): self = .host(id)
        case .remoteShell(let host, let directory): self = .remoteShell(hostID: host, directory: directory)
        case .agent(let agent): self = .agent(agentID: agent.agentID, hostID: agent.hostID, directory: agent.directory)
        case .process(let executable, let arguments, let directory):
            // Never serialize arbitrary command arguments, which can contain
            // typed commands or credentials. Login shells are safe references.
            self = arguments == ["-l"] ? .shell(executable: executable, directory: directory) : .customProcess(directory: directory)
        }
    }
    var restored: SessionLaunch {
        switch self {
        case .shell(let executable, let directory): .process(executable: executable, arguments: ["-l"], directory: directory)
        case .host(let id): .host(id)
        case .customProcess(let directory): .process(executable: "", arguments: [], directory: directory)
        case .remoteShell(let host, let directory): .remoteShell(hostID: host, directory: directory)
        case .agent(let id, let host, let directory): .agent(AgentLaunch(agentID: id, directory: directory, hostID: host))
        }
    }
    var needsConfiguration: Bool { if case .customProcess = self { return true }; return false }
}

private struct SavedPane: Codable {
    var pane: WorkspacePane
    var launch: SavedLaunch
}

private struct SavedWorkspace: Codable {
    var revision: UInt64
    var windows: [ManagedWindow]
    var activeWindowID: UUID?
    var tabs: [WorkspaceTab]
    var panes: [SavedPane]
}

public enum WorkspaceSnapshotCodec {
    /// 2 adds remote workspaces (FR-RW01), 3 agent panes (FR-AG04). A workspace is written at the lowest version that
    /// holds it, so an older build keeps reading what it can; anything newer is read-only there (unsupported version),
    /// never mistaken for corrupt.
    public static let currentVersion = 3
    private struct Header: Decodable { var schemaVersion: Int }
    private struct Document: Codable {
        var schemaVersion: Int
        var workspace: SavedWorkspace
        var settings: WorkspaceSettings?
    }

    public static func encode(_ snapshot: WorkspaceSnapshot, settings: WorkspaceSettings) throws -> Data {
        try snapshot.validate()
        let panes = try snapshot.panes.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { pane in
            guard let session = snapshot.sessions[pane.sessionID] else { throw WorkspacePersistenceError.corrupt }
            return SavedPane(pane: pane, launch: SavedLaunch(session.launch, settings: settings))
        }
        let saved = SavedWorkspace(
            revision: snapshot.revision, windows: snapshot.windows, activeWindowID: snapshot.activeWindowID,
            tabs: snapshot.tabs.values.sorted { $0.id.uuidString < $1.id.uuidString }, panes: panes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let version =
            snapshot.sessions.values.contains { $0.launch.agent != nil } ? 3 : snapshot.windows.contains { $0.remoteHostID != nil } ? 2 : 1
        let data = try encoder.encode(Document(schemaVersion: version, workspace: saved, settings: settings))
        guard data.count <= 4_194_304 else { throw WorkspacePersistenceError.corrupt }
        return data
    }

    public static func decode(_ data: Data) throws -> RestoredWorkspace {
        guard data.count <= 4_194_304 else { throw WorkspacePersistenceError.corrupt }
        // Bound recursive Codable work before decoding a user-controlled tree.
        var depth = 0, string = false, escaped = false
        for byte in data {
            if string {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { string = false }
            } else if byte == 34 {
                string = true
            } else if byte == 91 || byte == 123 {
                depth += 1; guard depth <= 128 else { throw WorkspacePersistenceError.corrupt }
            } else if byte == 93 || byte == 125 {
                depth -= 1
            }
        }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { throw WorkspacePersistenceError.corrupt }
        guard (0...currentVersion).contains(header.schemaVersion) else { throw WorkspacePersistenceError.unsupportedVersion(header.schemaVersion) }
        do {
            let document = try decoder.decode(Document.self, from: data)
            // Prototype v0 has the same graph and optional settings. Migration
            // supplies defaults in memory; a later atomic save publishes v1.
            let settings = document.settings ?? WorkspaceSettings()
            var result = WorkspaceSnapshot()
            result.revision = document.workspace.revision
            result.windows = document.workspace.windows
            result.activeWindowID = document.workspace.activeWindowID
            for tab in document.workspace.tabs {
                guard result.tabs.updateValue(tab, forKey: tab.id) == nil else { throw WorkspacePersistenceError.corrupt }
            }
            var unconfigured = Set<UUID>()
            for saved in document.workspace.panes {
                guard result.panes.updateValue(saved.pane, forKey: saved.pane.id) == nil,
                    result.sessions[saved.pane.sessionID] == nil
                else { throw WorkspacePersistenceError.corrupt }
                result.sessions[saved.pane.sessionID] = WorkspaceSession(id: saved.pane.sessionID, launch: saved.launch.restored)
                if saved.launch.needsConfiguration { unconfigured.insert(saved.pane.id) }
            }
            try result.validate()
            return RestoredWorkspace(snapshot: result, settings: settings, unconfiguredPaneIDs: unconfigured)
        } catch { throw WorkspacePersistenceError.corrupt }
    }
}

public enum WorkspaceLoadResult: Sendable {
    case missing
    case loaded(RestoredWorkspace)
    case recovery(reason: WorkspacePersistenceError, backup: RestoredWorkspace?)
}

/// Single writer; replacement and backup publication use same-directory rename.
public actor WorkspacePersistence {
    public nonisolated let directory: URL
    public nonisolated var currentURL: URL { directory.appendingPathComponent("workspace.json") }
    public nonisolated var backupURL: URL { directory.appendingPathComponent("workspace.backup.json") }
    private var writable = false
    private var replaceCorrupt = false
    private var lastSequence: UInt64 = 0
    private let beforeReplace: @Sendable (URL) throws -> Void

    public init(directory: URL, beforeReplace: @escaping @Sendable (URL) throws -> Void = { _ in }) {
        self.directory = directory; self.beforeReplace = beforeReplace
    }

    public func load() -> WorkspaceLoadResult {
        do {
            guard let data = try read(currentURL) else { writable = true; return .missing }
            let restored = try WorkspaceSnapshotCodec.decode(data)
            writable = true
            return .loaded(restored)
        } catch {
            writable = false
            let reason = (error as? WorkspacePersistenceError) ?? .corrupt
            let backup = try? read(backupURL).map(WorkspaceSnapshotCodec.decode)
            return .recovery(reason: reason, backup: backup)
        }
    }

    /// Explicit recovery preserves the original bytes before enabling writes.
    /// A newer version always remains read-only, including after recovery choice.
    public func authorizeRecovery() throws {
        if let data = try read(currentURL) {
            do { _ = try WorkspaceSnapshotCodec.decode(data) } catch WorkspacePersistenceError.unsupportedVersion { throw WorkspacePersistenceError.readOnly } catch { /* preserve the malformed source below */  }
            try ensureDirectory()
            try atomicWrite(data, to: directory.appendingPathComponent("workspace.corrupt.\(UUID().uuidString).json"))
        }
        replaceCorrupt = true
        writable = true
    }

    /// Returns the bytes written, counting the backup; 0 when the workspace is unchanged and nothing was written.
    @discardableResult
    public func save(_ snapshot: WorkspaceSnapshot, settings: WorkspaceSettings, sequence: UInt64) throws -> Int {
        guard writable else { throw WorkspacePersistenceError.readOnly }
        guard sequence >= lastSequence else { return 0 }
        let data = try WorkspaceSnapshotCodec.encode(snapshot, settings: settings)
        // Compared with the file itself, not a cached copy, so one deleted or replaced meanwhile is still rewritten (FR-R06).
        let previous = try read(currentURL)
        if previous == data, !replaceCorrupt { lastSequence = sequence; return 0 }
        try ensureDirectory()
        var written = 0
        if let previous {
            if (try? WorkspaceSnapshotCodec.decode(previous)) != nil {
                try atomicWrite(previous, to: backupURL); written += previous.count
            } else if !replaceCorrupt {
                writable = false; throw WorkspacePersistenceError.readOnly
            }
        }
        try atomicWrite(data, to: currentURL)
        replaceCorrupt = false
        lastSequence = sequence
        return written + data.count
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func read(_ url: URL) throws -> Data? { try OwnerOnlyStorage.read(url, limit: 4_194_304) }

    private func atomicWrite(_ data: Data, to target: URL) throws {
        try OwnerOnlyStorage.atomicWrite(data, to: target, temporaryPrefix: ".workspace.", beforeReplace: beforeReplace)
    }
}

/// Owner-only file I/O shared by workspace persistence and the scrollback store: reads never follow
/// symlinks; writes go to an `O_EXCL` 0600 temporary, are synced, renamed over the target, and the directory is synced.
public enum OwnerOnlyStorage {
    public static func read(_ url: URL, limit: Int) throws(WorkspacePersistenceError) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT { return nil }; throw .io(errno) }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { throw .corrupt }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { return result }
            if count < 0 { if errno == EINTR { continue }; throw .io(errno) }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= limit else { throw .corrupt }
        }
    }

    public static func atomicWrite(_ data: Data, to target: URL, temporaryPrefix: String, beforeReplace: (URL) throws -> Void = { _ in }) throws {
        let directory = target.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent("\(temporaryPrefix)\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw WorkspacePersistenceError.io(errno) }
        var openDescriptor = true
        defer { if openDescriptor { _ = close(fd) }; _ = unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw WorkspacePersistenceError.io(errno) }
                guard count > 0 else { throw WorkspacePersistenceError.io(EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw WorkspacePersistenceError.io(errno) }
        guard close(fd) == 0 else { openDescriptor = false; throw WorkspacePersistenceError.io(errno) }
        openDescriptor = false
        try beforeReplace(target)
        guard rename(temporary.path, target.path) == 0 else { throw WorkspacePersistenceError.io(errno) }
        let folder = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard folder >= 0 else { throw WorkspacePersistenceError.io(errno) }
        defer { _ = close(folder) }
        guard fsync(folder) == 0 else { throw WorkspacePersistenceError.io(errno) }
    }
}
