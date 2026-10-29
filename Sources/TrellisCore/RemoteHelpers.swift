import CryptoKit
import Foundation

/// The helpers this build can install (FR-RW02): Linux builds listed in `remote/remote-helpers.json` beside the bundled
/// helpers, and the macOS one, which is the bundled `trellis-broker` itself.
public struct RemoteArtifactCatalog: Equatable, Sendable {
    public static let manifestName = "remote-helpers.json"
    public var artifacts: [String: RemoteArtifact]
    public init(artifacts: [String: RemoteArtifact]) { self.artifacts = artifacts }

    private struct Manifest: Codable {
        struct Entry: Codable { var platform: String; var file: String; var digest: String; var fileDigest: String; var fileSize: Int; var compressed: Bool }
        var helpers: [Entry]
    }

    /// Entries naming a file outside `remoteDirectory`, or with malformed digests, are ignored.
    public static func load(remoteDirectory: URL?, macHelper: String?) -> RemoteArtifactCatalog {
        var artifacts: [String: RemoteArtifact] = [:]
        if let remoteDirectory, let data = try? Data(contentsOf: remoteDirectory.appendingPathComponent(manifestName)),
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        {
            for entry in manifest.helpers
            where !entry.file.contains("/") && !entry.file.hasPrefix(".") && RemoteArtifact.isDigest(entry.digest) && RemoteArtifact.isDigest(entry.fileDigest) {
                artifacts[entry.platform] = RemoteArtifact(
                    platform: entry.platform, path: remoteDirectory.appendingPathComponent(entry.file).path, digest: entry.digest,
                    fileDigest: entry.fileDigest, fileSize: entry.fileSize, compressed: entry.compressed)
            }
        }
        if let macHelper, let digest = sha256(file: macHelper), let size = (try? FileManager.default.attributesOfItem(atPath: macHelper)[.size]) as? Int {
            artifacts["darwin"] = RemoteArtifact(platform: "darwin", path: macHelper, digest: digest, fileDigest: digest, fileSize: size, compressed: false)
        }
        return RemoteArtifactCatalog(artifacts: artifacts)
    }

    public func artifact(for probe: RemoteProbe) -> RemoteArtifact? { probe.platform.flatMap { artifacts[$0] } }

    /// The file still has the size and digest recorded for it; read once, right before upload.
    public static func payload(_ artifact: RemoteArtifact) -> Data? {
        guard let data = FileManager.default.contents(atPath: artifact.path), data.count == artifact.fileSize, hex(SHA256.hash(data: data)) == artifact.fileDigest else {
            return nil
        }
        return data
    }

    public static func sha256(file: String) -> String? { FileManager.default.contents(atPath: file).map { hex(SHA256.hash(data: $0)) } }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}

/// What Trellis last observed about a host's helper (FR-RW17). Recorded only from a probe, never inferred.
public struct RemoteHelperRecord: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// The helper this build installs.
        case current
        /// Only other builds are installed.
        case outdated
        case missing
        /// No helper for this platform, or no way to check a digest there.
        case unsupported
    }
    public var state: State
    public var system: String
    public var machine: String
    public var checkedAt: Date
    public init(state: State, system: String, machine: String, checkedAt: Date) {
        self.state = state; self.system = system; self.machine = machine; self.checkedAt = checkedAt
    }

    public init(probe: RemoteProbe, catalog: RemoteArtifactCatalog, checkedAt: Date) {
        let state: State
        if let artifact = catalog.artifact(for: probe), probe.checksumTool != nil {
            state = probe.installed.contains(artifact.directory) ? .current : (probe.installed.isEmpty ? .missing : .outdated)
        } else {
            state = .unsupported
        }
        self.init(state: state, system: probe.system, machine: probe.machine, checkedAt: checkedAt)
    }

    public var summary: String {
        let platform = RemotePlatform.displayName(system: system, machine: machine)
        return switch state {
        case .current: "Installed, up to date (\(platform))"
        case .outdated: "Update available (\(platform))"
        case .missing: "Not installed (\(platform))"
        case .unsupported: "Not available for \(platform)"
        }
    }
}

public struct RemoteHostPreferences: Codable, Equatable, Sendable {
    /// Install or update the helper without asking when opening a remote workspace. Off by default.
    public var autoInstall = false
    public var helper: RemoteHelperRecord?
    public init(autoInstall: Bool = false, helper: RemoteHelperRecord? = nil) { self.autoInstall = autoInstall; self.helper = helper }
}

/// `remote-hosts.json` in the state directory: per saved host, the helper status and the auto-install choice. Owner-only,
/// replaced atomically, never holds a secret; an unreadable file reads as empty and is replaced on the next change.
public actor RemoteHostSettings {
    public static let fileName = "remote-hosts.json"
    private let url: URL?
    private var hosts: [UUID: RemoteHostPreferences] = [:]
    private var loaded = false

    public init(stateDirectory: URL?) { url = stateDirectory?.appendingPathComponent(Self.fileName) }

    private struct Document: Codable {
        var version = 1
        var hosts: [String: RemoteHostPreferences]
    }

    public func all() -> [UUID: RemoteHostPreferences] {
        load()
        return hosts
    }

    public func preferences(_ host: UUID) -> RemoteHostPreferences {
        load()
        return hosts[host] ?? .init()
    }

    @discardableResult
    public func update(_ host: UUID, _ change: @Sendable (inout RemoteHostPreferences) -> Void) -> RemoteHostPreferences {
        load()
        var value = hosts[host] ?? .init()
        change(&value)
        hosts[host] = value == .init() ? nil : value
        save()
        return value
    }

    /// Drops entries for hosts that no longer exist.
    public func retain(_ ids: Set<UUID>) {
        load()
        guard hosts.keys.contains(where: { !ids.contains($0) }) else { return }
        hosts = hosts.filter { ids.contains($0.key) }
        save()
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let url, let data = try? Data(contentsOf: url), let document = try? Self.decoder.decode(Document.self, from: data), document.version == 1 else { return }
        hosts = Dictionary(uniqueKeysWithValues: document.hosts.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private func save() {
        guard let url else { return }
        let document = Document(hosts: Dictionary(uniqueKeysWithValues: hosts.map { ($0.key.uuidString, $0.value) }))
        guard let data = try? Self.encoder.encode(document) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
