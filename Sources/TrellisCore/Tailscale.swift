import Darwin
import Foundation

// FR-RC05–FR-RC07: Trellis reads Tailscale's state and publishes the loopback MCP endpoint
// with `tailscale serve`, through the official CLI only, with fixed arguments and no shell.

public enum TailscaleBackend: String, Equatable, Sendable {
    case notInstalled, stopped, needsLogin, connected
}

public struct TailscalePeer: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var os: String
    public var online: Bool
    public var addresses: [String]
    public init(id: String, name: String, os: String = "", online: Bool = true, addresses: [String]) {
        self.id = id; self.name = name; self.os = os; self.online = online; self.addresses = addresses
    }
    public var device: TailnetDevice { TailnetDevice(id: id, name: name, addresses: addresses) }
}

/// The parts of `tailscale status --json` Trellis uses.
public struct TailscaleStatus: Equatable, Sendable {
    public var backend: TailscaleBackend
    /// MagicDNS name, lowercased, without the trailing dot.
    public var dnsName: String?
    public var addresses: [String]
    /// The tailnet can issue HTTPS certificates (`CertDomains` is not empty) and MagicDNS names this Mac.
    public var httpsEnabled: Bool
    public var peers: [TailscalePeer]
    public init(backend: TailscaleBackend, dnsName: String? = nil, addresses: [String] = [], httpsEnabled: Bool = false, peers: [TailscalePeer] = []) {
        self.backend = backend; self.dnsName = dnsName; self.addresses = addresses; self.httpsEnabled = httpsEnabled; self.peers = peers
    }

    private struct Wire: Decodable {
        struct Node: Decodable {
            var ID: String?
            var HostName: String?
            var DNSName: String?
            var OS: String?
            var Online: Bool?
            var TailscaleIPs: [String]?
        }
        var BackendState: String?
        var `Self`: Node?
        var Peer: [String: Node]?
        var CertDomains: [String]?
    }

    public init(json: Data) throws(TailscaleError) {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: json) else { throw .malformed }
        backend =
            switch wire.BackendState {
            case "Running": .connected
            case "NeedsLogin", "NeedsMachineAuth": .needsLogin
            default: .stopped
            }
        dnsName = wire.Self?.DNSName.flatMap(Self.normalizedName)
        addresses = Self.tailnetAddresses(wire.Self?.TailscaleIPs)
        httpsEnabled = !(wire.CertDomains ?? []).isEmpty && dnsName != nil
        peers = (wire.Peer ?? [:]).values.compactMap { node in
            guard let id = node.ID, !id.isEmpty else { return nil }
            let addresses = Self.tailnetAddresses(node.TailscaleIPs)
            guard !addresses.isEmpty else { return nil }
            let short = node.DNSName.flatMap(Self.normalizedName)?.split(separator: ".").first.map(String.init)
            return TailscalePeer(id: id, name: node.HostName.flatMap { $0.isEmpty ? nil : $0 } ?? short ?? id, os: node.OS ?? "", online: node.Online ?? false, addresses: addresses)
        }
        .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    static func normalizedName(_ name: String) -> String? {
        let trimmed = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.isEmpty, trimmed.utf8.count <= 253, trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else { return nil }
        return trimmed
    }

    static func tailnetAddresses(_ list: [String]?) -> [String] { (list ?? []).filter { IPAddressLiteral($0)?.isTailnet ?? false } }
}

/// The parts of `tailscale serve status --json` (ipn.ServeConfig) Trellis uses.
public struct TailscaleServeConfig: Equatable, Sendable {
    /// Ports with any TCP handler, HTTPS or not.
    public var ports: Set<UInt16>
    /// `host:port` → path → proxy target (nil for a non-proxy handler).
    public var web: [String: [String: String?]]
    public var funnel: Set<String>
    /// Ports a foreground `tailscale serve` session (another terminal) holds: never Trellis's.
    public var foregroundPorts: Set<UInt16>

    private struct Wire: Decodable {
        struct Web: Decodable {
            struct Handler: Decodable { var Proxy: String? }
            var Handlers: [String: Handler]?
        }
        struct Session: Decodable {
            var TCP: [String: AnyDecodable]?
            var Web: [String: AnyDecodable]?
        }
        var TCP: [String: AnyDecodable]?
        var Web: [String: Web]?
        var AllowFunnel: [String: Bool]?
        var Foreground: [String: Session]?
        init() {}
    }
    private struct AnyDecodable: Decodable { init(from decoder: Decoder) throws {} }

    public init(ports: Set<UInt16> = [], web: [String: [String: String?]] = [:], funnel: Set<String> = [], foregroundPorts: Set<UInt16> = []) {
        self.ports = ports; self.web = web; self.funnel = funnel; self.foregroundPorts = foregroundPorts
    }

    public init(json: Data) throws(TailscaleError) {
        let text = String(decoding: json, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // No serve configuration prints nothing or `{}` depending on the version.
        let wire: Wire
        if text.isEmpty || text == "null" {
            wire = Wire()
        } else {
            guard let decoded = try? JSONDecoder().decode(Wire.self, from: json) else { throw .malformed }
            wire = decoded
        }
        ports = Set((wire.TCP ?? [:]).keys.compactMap { UInt16($0) })
        web = (wire.Web ?? [:]).reduce(into: [:]) { result, entry in
            result[entry.key.lowercased()] = (entry.value.Handlers ?? [:]).mapValues { $0.Proxy }
        }
        funnel = Set((wire.AllowFunnel ?? [:]).filter(\.value).keys.map { $0.lowercased() })
        foregroundPorts = (wire.Foreground ?? [:]).values.reduce(into: []) { result, session in
            result.formUnion((session.TCP ?? [:]).keys.compactMap { UInt16($0) })
            result.formUnion((session.Web ?? [:]).keys.compactMap { $0.split(separator: ":").last.flatMap { UInt16($0) } })
        }
    }

    public enum PortUse: Equatable, Sendable {
        case free
        /// Exactly one handler, at `/`, proxying to Trellis's endpoint.
        case trellis
        case other
    }

    /// Whether `port` on `host` is free, Trellis's own proxy to `target`, or someone else's.
    public func use(host: String, port: UInt16, target: String) -> PortUse {
        let key = "\(host.lowercased()):\(port)"
        guard !foregroundPorts.contains(port) else { return .other }
        guard ports.contains(port) || web[key] != nil else { return .free }
        guard let handlers = web[key], handlers.count == 1, let proxy = handlers["/"] ?? nil, Self.sameTarget(proxy, target) else { return .other }
        return .trellis
    }

    public func funnelOn(host: String, port: UInt16) -> Bool { funnel.contains("\(host.lowercased()):\(port)") }

    static func sameTarget(_ a: String, _ b: String) -> Bool {
        func clean(_ s: String) -> String {
            var value = s.lowercased()
            while value.hasSuffix("/") { value.removeLast() }
            return value
        }
        return clean(a) == clean(b)
    }
}

public enum TailscaleError: Error, Equatable, Sendable {
    case notInstalled
    /// The CLI is there but the Tailscale app or daemon isn't running.
    case notRunning
    case timedOut
    case malformed
    /// The CLI failed; `message` is its first line, for display.
    case failed(String)
}

public enum TailscaleShareError: Error, Equatable, Sendable {
    case tailscale(TailscaleError)
    case notConnected(TailscaleBackend)
    case httpsDisabled
    case portInUse(UInt16)
    case funnelOn(UInt16)
    /// Tailscale asks the admin to turn on HTTPS or Serve at this page first.
    case consentRequired(URL)
}

/// Runs the Tailscale CLI with the given arguments and returns its standard output.
public protocol TailscaleCommandRunning: Sendable {
    func run(_ arguments: [String], timeout: TimeInterval) async throws(TailscaleError) -> Data
}

/// Reads status and adds or removes Trellis's own `tailscale serve` entry.
/// A port is never changed unless it is free or already Trellis's proxy.
public actor TailscaleController {
    private let runner: any TailscaleCommandRunning
    public init(runner: any TailscaleCommandRunning) { self.runner = runner }

    public func status() async -> Result<TailscaleStatus, TailscaleError> {
        do throws(TailscaleError) {
            return .success(try TailscaleStatus(json: try await runner.run(["status", "--json"], timeout: 5)))
        } catch .notInstalled {
            return .success(TailscaleStatus(backend: .notInstalled))
        } catch .notRunning {
            return .success(TailscaleStatus(backend: .stopped))
        } catch {
            return .failure(error)
        }
    }

    public func serveConfig() async throws(TailscaleError) -> TailscaleServeConfig {
        try TailscaleServeConfig(json: try await runner.run(["serve", "status", "--json"], timeout: 5))
    }

    /// Publishes `target` (Trellis's loopback origin) at `https://host:port`. Returns the client URL.
    public func share(status: TailscaleStatus, port: UInt16, target: String) async throws(TailscaleShareError) -> String {
        guard status.backend == .connected else { throw .notConnected(status.backend) }
        guard status.httpsEnabled, let host = status.dnsName else { throw .httpsDisabled }
        let config: TailscaleServeConfig
        do throws(TailscaleError) { config = try await serveConfig() } catch { throw .tailscale(error) }
        switch config.use(host: host, port: port, target: target) {
        case .other: throw .portInUse(port)
        case .trellis:
            // FR-RC07: never public. Removing our entry also removes its Funnel.
            if config.funnelOn(host: host, port: port) {
                _ = try? await runner.run(["serve", "--https=\(port)", "off"], timeout: 10)
                throw .funnelOn(port)
            }
        case .free:
            do throws(TailscaleError) {
                _ = try await runner.run(["serve", "--bg", "--https=\(port)", target], timeout: 15)
            } catch .failed(let message) {
                if let url = Self.consentURL(in: message) { throw .consentRequired(url) }
                throw .tailscale(.failed(message))
            } catch {
                throw .tailscale(error)
            }
            // Confirm what was written, so a CLI that ignored the request is caught.
            let written: TailscaleServeConfig
            do throws(TailscaleError) { written = try await serveConfig() } catch { throw .tailscale(error) }
            guard written.use(host: host, port: port, target: target) == .trellis else { throw .tailscale(.failed("tailscale serve did not add the endpoint.")) }
        }
        return "https://\(host)\(port == 443 ? "" : ":\(port)")/mcp"
    }

    /// Removes Trellis's entry. Someone else's configuration on the port is left alone.
    @discardableResult
    public func unshare(host: String, port: UInt16, target: String) async -> Bool {
        guard let config = try? await serveConfig(), config.use(host: host, port: port, target: target) == .trellis else { return false }
        return (try? await runner.run(["serve", "--https=\(port)", "off"], timeout: 10)) != nil
    }

    /// Tailscale's consent page for HTTPS or Serve, only on its own login host.
    static func consentURL(in text: String) -> URL? {
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            guard let url = URL(string: String(word)), url.scheme == "https", url.host == "login.tailscale.com" else { continue }
            return url
        }
        return nil
    }
}

/// The real CLI. It is found only at fixed paths, must be a regular file that
/// isn't group- or world-writable and is owned by root or this user, and runs
/// without a shell, with stdin closed, a timeout and capped output.
public struct TailscaleCLI: TailscaleCommandRunning {
    public static let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
    static let maximumOutput = 1_048_576
    private let candidates: [String]
    public init(candidates: [String] = Self.candidates) { self.candidates = candidates }

    public var executable: String? { candidates.lazy.compactMap(Self.trusted).first }

    /// The resolved path of `path` when it is safe to run.
    static func trusted(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        var info = stat()
        guard stat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o111 != 0, info.st_mode & 0o022 == 0,
            info.st_uid == 0 || info.st_uid == getuid()
        else { return nil }
        return String(cString: resolved)
    }

    public func run(_ arguments: [String], timeout: TimeInterval) async throws(TailscaleError) -> Data {
        guard let executable else { throw .notInstalled }
        let result = await Self.spawn(executable, arguments, timeout: timeout)
        switch result {
        case .launchFailed: throw .notInstalled
        case .timedOut(let output):
            // `serve` waits while it shows a consent link; that link is the useful part.
            let text = String(decoding: output, as: UTF8.self)
            if TailscaleController.consentURL(in: text) != nil { throw .failed(Self.summary(text)) }
            throw .timedOut
        case .exited(let status, let output, let errors):
            guard status == 0 else {
                let text = String(decoding: errors + output, as: UTF8.self)
                let lower = text.lowercased()
                if lower.contains("failed to connect to local tailscale") || lower.contains("is tailscale running") || lower.contains("tailscaled") && lower.contains("not running") {
                    throw .notRunning
                }
                throw .failed(Self.summary(text))
            }
            return output
        }
    }

    /// The consent URL if there is one, otherwise the first non-empty line, bounded.
    static func summary(_ text: String) -> String {
        if let url = TailscaleController.consentURL(in: text) { return url.absoluteString }
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "tailscale failed."
        return String(line.prefix(200))
    }

    enum Outcome { case launchFailed, timedOut(Data), exited(Int32, Data, Data) }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.withLock { if data.count < TailscaleCLI.maximumOutput { data.append(chunk.prefix(TailscaleCLI.maximumOutput - data.count)) } } }
        var value: Data { lock.withLock { data } }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.withLock {
                defer { done = true }; return !done
            }
        }
    }

    static func spawn(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        let output = Buffer(), errors = Buffer()
        out.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { errors.append($0.availableData) }
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            process.terminationHandler = { finished in
                out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
                output.append(out.fileHandleForReading.readDataToEndOfFile()); errors.append(err.fileHandleForReading.readDataToEndOfFile())
                guard once.claim() else { return }
                continuation.resume(returning: .exited(finished.terminationStatus, output.value, errors.value))
            }
            do { try process.run() } catch {
                out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
                guard once.claim() else { return }
                continuation.resume(returning: .launchFailed)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                process.terminate()
                continuation.resume(returning: .timedOut(output.value + errors.value))
            }
        }
    }
}
