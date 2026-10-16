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

    /// Plain-language description shown when creating a grant.
    public var summary: String {
        switch self {
        case .metadataRead: "List windows, tabs, panes, and session states"
        case .layoutWrite: "Create, rename, split, resize, and focus layout (new panes stay stopped)"
        case .sessionStart: "Start stopped sessions with the default shell or an approved host"
        case .sessionInput: "Type into terminals, including control keys (can run commands)"
        case .sessionExecute: "Run arbitrary programs and shell commands"
        case .sessionOutputRead: "Read terminal screens, scrollback, and output"
        case .sessionClose: "Terminate running sessions"
        case .themeRead: "Read themes and appearance (global)"
        case .themeWrite: "Change themes and appearance for every window (global)"
        case .hostRead: "Read saved hosts, aliases, and identity-file paths"
        case .hostWrite: "Create, edit, and delete saved hosts"
        }
    }
}

public enum WindowScope: Codable, Equatable, Sendable {
    case all
    case windows(Set<UUID>)
}

/// A host approved for this grant at a specific connection revision.
public struct HostApproval: Codable, Equatable, Hashable, Sendable {
    public let hostID: UUID
    public let connectionRevision: UInt64
    public init(hostID: UUID, connectionRevision: UInt64) { self.hostID = hostID; self.connectionRevision = connectionRevision }
}

public enum HostScope: Codable, Equatable, Sendable {
    case all
    case approved(Set<HostApproval>)
}

/// Grant metadata. The token itself is never stored here, only its SHA-256.
public struct AutomationGrant: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let tokenHash: String
    public var capabilities: Set<Capability>
    public var windowScope: WindowScope
    public var hostScope: HostScope
    public let createdAt: Date
    public let expiresAt: Date
    public var revokedAt: Date?

    public func isActive(at now: Date) -> Bool { revokedAt == nil && now < expiresAt }
    public func allows(_ capability: Capability) -> Bool { capabilities.contains(capability) }
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

/// Owner-only, atomically published `grants.json`. Revoked and expired grants
/// remain listed (inactive) so their status stays visible.
public actor GrantStore {
    public private(set) var grants: [AutomationGrant] = []
    private let url: URL?
    private let secrets: any GrantSecretStore
    private let now: @Sendable () -> Date
    private var revocationObservers: [@Sendable (UUID) -> Void] = []
    /// Set when the stored file cannot be used: no grant is active and nothing is written.
    public private(set) var loadFailed = false

    /// `url == nil` keeps grants in memory only (tests).
    public init(url: URL?, secrets: any GrantSecretStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url; self.secrets = secrets; self.now = now
    }

    public func load() {
        guard let url else { return }
        do {
            guard let data = try OwnerOnlyFile.read(url, limit: 1_048_576) else { grants = []; loadFailed = false; return }
            grants = try JSONDecoder.grants.decode([AutomationGrant].self, from: data)
            loadFailed = false
        } catch {
            grants = []; loadFailed = true
        }
    }

    /// Called with the grant ID whenever a grant is revoked.
    public func onRevocation(_ observer: @escaping @Sendable (UUID) -> Void) { revocationObservers.append(observer) }

    /// Returns the grant and its token. The token is not retrievable later.
    public func create(
        name: String, capabilities: Set<Capability>, windowScope: WindowScope, hostScope: HostScope, lifetime: TimeInterval
    ) throws(GrantError) -> (grant: AutomationGrant, token: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100, !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw .invalidName
        }
        guard !capabilities.isEmpty else { throw .noCapabilities }
        guard lifetime.isFinite, (60...(90 * 86_400)).contains(lifetime) else { throw .invalidExpiry }
        guard !loadFailed else { throw .readOnly }
        let token = GrantToken.generate()
        let created = now()
        let grant = AutomationGrant(
            id: UUID(), name: trimmed, tokenHash: GrantToken.hash(token), capabilities: capabilities, windowScope: windowScope,
            hostScope: hostScope, createdAt: created, expiresAt: created.addingTimeInterval(lifetime), revokedAt: nil)
        do { try secrets.store(token, grantID: grant.id) } catch { throw .secretStore }
        do {
            try persist(grants + [grant])
        } catch {
            secrets.remove(grantID: grant.id)
            throw error
        }
        grants.append(grant)
        return (grant, token)
    }

    public func revoke(_ id: UUID) throws(GrantError) {
        guard let index = grants.firstIndex(where: { $0.id == id }) else { throw .notFound }
        guard grants[index].revokedAt == nil else { return }
        var next = grants
        next[index].revokedAt = now()
        // Block use immediately, even if the file write then fails.
        grants = next
        secrets.remove(grantID: id)
        for observer in revocationObservers { observer(id) }
        try persist(next)
    }

    /// Replaces host approvals with the hosts' current connection revisions.
    public func approveHosts(_ grantID: UUID, hosts: [SavedHostApprovalInput]) throws(GrantError) {
        guard let index = grants.firstIndex(where: { $0.id == grantID }), grants[index].revokedAt == nil else { throw .notFound }
        var next = grants
        next[index].hostScope = .approved(Set(hosts.map { HostApproval(hostID: $0.id, connectionRevision: $0.connectionRevision) }))
        try persist(next)
        grants = next
    }

    /// Matching active grant for a presented token, if any.
    public func activeGrant(token: String) -> AutomationGrant? {
        grants.first { GrantToken.matches(token, hash: $0.tokenHash) && $0.isActive(at: now()) }
    }

    public func activeGrant(id: UUID) -> AutomationGrant? { grants.first { $0.id == id && $0.isActive(at: now()) } }

    public func currentDate() -> Date { now() }

    private func persist(_ next: [AutomationGrant]) throws(GrantError) {
        guard !loadFailed else { throw .readOnly }
        guard let url else { return }
        guard let data = try? JSONEncoder.grants.encode(next) else { throw .io }
        do { try OwnerOnlyFile.publish(data, to: url) } catch { throw .io }
    }
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
