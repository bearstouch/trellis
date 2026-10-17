import Darwin
import Foundation

/// MCP server settings (FR-RC01–FR-RC03). Off by default; the address is an
/// IP literal, never a hostname, so binding cannot depend on name resolution.
public struct RemoteControlSettings: Codable, Equatable, Sendable {
    public static let defaultPort: UInt16 = 7777
    public static let portRange: ClosedRange<UInt16> = 1024...65_535
    public var mcpEnabled = false
    public var bindAddress = "127.0.0.1"
    public var port = Self.defaultPort
    public init(mcpEnabled: Bool = false, bindAddress: String = "127.0.0.1", port: UInt16 = Self.defaultPort) {
        self.mcpEnabled = mcpEnabled; self.bindAddress = bindAddress; self.port = port
    }
    private enum CodingKeys: String, CodingKey { case mcpEnabled, bindAddress, port }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mcpEnabled = try c.decodeIfPresent(Bool.self, forKey: .mcpEnabled) ?? false
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? "127.0.0.1"
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? Self.defaultPort
    }

    public var isValid: Bool { Self.portRange.contains(port) && IPAddressLiteral(bindAddress) != nil }
    /// Only loopback binds are reachable without an explicit network confirmation (FR-RC03).
    public var isLoopback: Bool { IPAddressLiteral(bindAddress)?.isLoopback ?? false }
    /// `http://127.0.0.1:7777/mcp`; IPv6 literals are bracketed.
    public var endpointURL: String { Self.endpointURL(address: bindAddress, port: port) }
    public static func endpointURL(address: String, port: UInt16) -> String {
        let host = address.contains(":") ? "[\(address)]" : address
        return "http://\(host):\(port)/mcp"
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
}

/// What the MCP server is doing now, shown in Settings → Remote Control (FR-RC04).
public enum RemoteControlStatus: Equatable, Sendable {
    case stopped
    case running(url: String)
    case failed(reason: String)
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
