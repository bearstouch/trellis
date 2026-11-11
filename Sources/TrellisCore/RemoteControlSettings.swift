import Darwin
import Foundation

/// MCP server settings (FR-RC01–FR-RC03, FR-RC05–FR-RC09). Off by default; the address is an
/// IP literal, never a hostname, so binding cannot depend on name resolution.
public struct RemoteControlSettings: Codable, Equatable, Sendable {
    public static let defaultPort: UInt16 = 7777
    public static let portRange: ClosedRange<UInt16> = 1024...65_535
    /// The HTTPS ports `tailscale serve` accepts.
    public static let tailscalePorts: [UInt16] = [443, 8443, 10_000]
    public static let maximumAllowedDevices = 64
    public var mcpEnabled = false
    public var bindAddress = "127.0.0.1"
    public var port = Self.defaultPort
    /// FR-RC06: publish the loopback endpoint to the tailnet through `tailscale serve`.
    public var tailscaleShare = false
    public var tailscalePort: UInt16 = 8443
    /// FR-RC09: empty allows any device in the tailnet.
    public var allowedDevices: [TailnetDevice] = []
    public init(
        mcpEnabled: Bool = false, bindAddress: String = "127.0.0.1", port: UInt16 = Self.defaultPort, tailscaleShare: Bool = false, tailscalePort: UInt16 = 8443,
        allowedDevices: [TailnetDevice] = []
    ) {
        self.mcpEnabled = mcpEnabled; self.bindAddress = bindAddress; self.port = port
        self.tailscaleShare = tailscaleShare; self.tailscalePort = tailscalePort; self.allowedDevices = allowedDevices
    }
    private enum CodingKeys: String, CodingKey { case mcpEnabled, bindAddress, port, tailscaleShare, tailscalePort, allowedDevices }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mcpEnabled = try c.decodeIfPresent(Bool.self, forKey: .mcpEnabled) ?? false
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? "127.0.0.1"
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? Self.defaultPort
        tailscaleShare = try c.decodeIfPresent(Bool.self, forKey: .tailscaleShare) ?? false
        tailscalePort = try c.decodeIfPresent(UInt16.self, forKey: .tailscalePort) ?? 8443
        allowedDevices = try c.decodeIfPresent([TailnetDevice].self, forKey: .allowedDevices) ?? []
    }

    /// Sharing proxies to `127.0.0.1`/`::1`, so it needs a loopback bind; a device list needs real addresses.
    public var isValid: Bool {
        Self.portRange.contains(port) && IPAddressLiteral(bindAddress) != nil && Self.tailscalePorts.contains(tailscalePort)
            && (!tailscaleShare || isLoopback) && allowedDevices.count <= Self.maximumAllowedDevices && allowedDevices.allSatisfy(\.isValid)
    }
    /// Only loopback binds are reachable without an explicit network confirmation (FR-RC03).
    public var isLoopback: Bool { IPAddressLiteral(bindAddress)?.isLoopback ?? false }
    /// Sharing is in effect only while the server itself is on.
    public var sharesOverTailscale: Bool { mcpEnabled && tailscaleShare }
    /// `http://127.0.0.1:7777/mcp`; IPv6 literals are bracketed.
    public var endpointURL: String { Self.endpointURL(address: bindAddress, port: port) }
    public static func endpointURL(address: String, port: UInt16) -> String {
        "\(origin(address: address, port: port))/mcp"
    }
    /// The `tailscale serve` proxy target: `http://127.0.0.1:7777`.
    public var serveTarget: String { Self.origin(address: bindAddress, port: port) }
    static func origin(address: String, port: UInt16) -> String {
        let host = address.contains(":") ? "[\(address)]" : address
        return "http://\(host):\(port)"
    }
}

/// A tailnet device allowed to reach a shared endpoint (FR-RC09). The addresses are
/// kept so the list still works while Tailscale's status can't be read.
public struct TailnetDevice: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var addresses: [String]
    public init(id: String, name: String, addresses: [String]) { self.id = id; self.name = name; self.addresses = addresses }
    public var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 128 && name.utf8.count <= 256 && !addresses.isEmpty && addresses.count <= 8
            && addresses.allSatisfy { IPAddressLiteral($0)?.isTailnet ?? false }
    }
}

/// A parsed IPv4 or IPv6 literal.
public enum IPAddressLiteral: Equatable, Sendable {
    case v4(in_addr_t)
    case v6([UInt8])

    public init?(_ text: String) {
        guard !text.isEmpty, text.utf8.count <= 45, !text.contains("%") else { return nil }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            self = .v4(v4.s_addr)
        } else if inet_pton(AF_INET6, text, &v6) == 1 {
            self = .v6(withUnsafeBytes(of: &v6) { Array($0) })
        } else {
            return nil
        }
    }

    public var isLoopback: Bool {
        switch self {
        case .v4(let address): UInt32(bigEndian: address) >> 24 == 127
        case .v6(let bytes): bytes == [UInt8](repeating: 0, count: 15) + [1]
        }
    }

    /// Tailscale's ranges: `100.64.0.0/10` and `fd7a:115c:a1e0::/48` (FR-RC05).
    public var isTailnet: Bool {
        switch self {
        case .v4(let address): UInt32(bigEndian: address) >> 22 == (100 << 2 | 1)
        case .v6(let bytes): Array(bytes.prefix(6)) == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
        }
    }
}

/// What the MCP server is doing now, shown in Settings → Remote Control (FR-RC04).
public enum RemoteControlStatus: Equatable, Sendable {
    case stopped
    case running(url: String)
    case failed(reason: String)
}

/// What sharing over Tailscale is doing now (FR-RC06), shown in Settings → Remote Control.
public enum TailscaleShareState: Equatable, Sendable {
    case off
    case starting
    case shared(url: String)
    /// Tailscale isn't running or connected; retried without another Apply.
    case waiting
    case failed(TailscaleShareError)

    public var sharedURL: String? { if case .shared(let url) = self { url } else { nil } }
}

/// A local interface address offered in the bind picker.
public struct NetworkInterfaceAddress: Equatable, Hashable, Sendable {
    public let interface: String
    public let address: String
    public init(interface: String, address: String) { self.interface = interface; self.address = address }

    /// Up, non-loopback IPv4/IPv6 addresses; IPv6 link-local addresses need a
    /// scope ID, which settings do not store, so they are left out.
    public static func current() -> [Self] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [Self] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !text.contains("%"), !text.lowercased().hasPrefix("fe80") else { continue }
            result.append(Self(interface: String(cString: entry.pointee.ifa_name), address: text))
        }
        return Array(Set(result)).sorted { ($0.interface, $0.address) < ($1.interface, $1.address) }
    }
}

extension RemoteControlSettings {
    /// FR-RC06/FR-RC09: Apply asks first when this change lets more tailnet devices in:
    /// sharing turned on, the list cleared to "any device", or a device added.
    public func widensTailnetAccess(from old: RemoteControlSettings) -> Bool {
        guard sharesOverTailscale else { return false }
        guard old.sharesOverTailscale else { return true }
        if old.allowedDevices.isEmpty { return false }
        return allowedDevices.isEmpty || !Set(allowedDevices.map(\.id)).isSubset(of: Set(old.allowedDevices.map(\.id)))
    }
}

/// Ready-to-paste client configuration for the Remote Control endpoint. A snippet
/// never holds a real token: a `<TOKEN>` placeholder or an environment variable name.
public enum MCPClientSetup: String, CaseIterable, Sendable {
    case claudeCode, codex, json

    public static let tokenVariable = "TRELLIS_TOKEN"

    public func snippet(url: String) -> String {
        switch self {
        case .claudeCode: "claude mcp add --transport http trellis \(url) --header \"Authorization: Bearer <TOKEN>\""
        case .codex: "[mcp_servers.trellis]\nurl = \"\(url)\"\nbearer_token_env_var = \"\(Self.tokenVariable)\"\n"
        case .json:
            """
            {
              "mcpServers": {
                "trellis": {
                  "type": "http",
                  "url": "\(url)",
                  "headers": { "Authorization": "Bearer <TOKEN>" }
                }
              }
            }

            """
        }
    }
}
