import Darwin
import Foundation

/// Wire contract between the app's askpass broker and the `trellis-askpass` helper (FR-H08).
/// One request per connection: the nonce line; one reply: `P` + password bytes, or `I`.
public enum AskpassProtocol {
    /// Not `TRELLIS_`-prefixed: launch validation reserves that prefix for the app itself.
    public static let socketVariable = "SSH_ASKPASS_TRELLIS_SOCKET"
    public static let nonceVariable = "SSH_ASKPASS_TRELLIS_NONCE"
    public static let helperName = "trellis-askpass"
    public static let requestLimit = 128
    public static let replyLimit = 4096
    public static let password: UInt8 = 0x50  // "P"
    public static let interactive: UInt8 = 0x49  // "I"

    public static func request(nonce: String) -> Data { Data("\(nonce)\n".utf8) }

    public static func nonce(from request: Data) -> String? {
        guard request.count <= requestLimit, request.last == 0x0A else { return nil }
        let nonce = String(decoding: request.dropLast(), as: UTF8.self)
        return isValidNonce(nonce) ? nonce : nil
    }

    public static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String(format: "%016llx", generator.next() as UInt64) }.joined()
    }

    static func isValidNonce(_ nonce: String) -> Bool {
        nonce.utf8.count == 64 && nonce.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public enum AskpassPrompt: Equatable, Sendable {
    /// The only kind ever answered from the Keychain.
    case password
    /// Host-key trust, key passphrases, one-time codes: always typed by the person.
    case typed(echo: Bool)
    /// `SSH_ASKPASS_PROMPT=confirm`, answered by exit status.
    case confirm
    /// `SSH_ASKPASS_PROMPT=none`: an informational notice, no answer.
    case notice

    public static func classify(_ prompt: String, kind: String?) -> AskpassPrompt {
        switch kind {
        case "confirm": return .confirm
        case "none": return .notice
        default: break
        }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.contains("yes/no") { return .typed(echo: true) }
        // "user@host's password:" and keyboard-interactive "Password:"; never a new-password or passphrase prompt.
        if text.hasSuffix("password:"), !text.contains("new password"), !text.contains("passphrase") { return .password }
        return .typed(echo: false)
    }
}

/// The helper ssh runs as `SSH_ASKPASS`. Anything it cannot answer from the broker is
/// asked on the session's own terminal, so ssh's prompts keep working (FR-H04).
public struct AskpassHelper {
    public var arguments: [String]
    public var environment: [String: String]
    /// Sends a request to the broker socket and returns its reply; nil on any failure.
    public var exchange: (String, Data) -> Data? = AskpassHelper.exchange
    public var terminal: AskpassTerminal = DeviceTerminal()
    public var write: (Data) -> Void = { data in FileHandle.standardOutput.write(data) }

    public init(arguments: [String], environment: [String: String]) { self.arguments = arguments; self.environment = environment }

    public func run() -> Int32 {
        let prompt = arguments.count > 1 ? arguments[1] : ""
        switch AskpassPrompt.classify(prompt, kind: environment["SSH_ASKPASS_PROMPT"]) {
        case .notice:
            terminal.show(prompt)
            return 0
        case .confirm:
            guard let answer = terminal.ask(prompt + " (yes/no) ", echo: true) else { return 1 }
            return answer.trimmingCharacters(in: .whitespaces).lowercased() == "yes" ? 0 : 1
        case .password:
            if let socket = environment[AskpassProtocol.socketVariable], let nonce = environment[AskpassProtocol.nonceVariable],
                AskpassProtocol.isValidNonce(nonce), var reply = exchange(socket, AskpassProtocol.request(nonce: nonce)),
                reply.first == AskpassProtocol.password
            {
                write(reply.dropFirst() + Data([0x0A]))
                reply.resetBytes(in: 0..<reply.count)
                return 0
            }
            return typed(prompt, echo: false)
        case .typed(let echo):
            return typed(prompt, echo: echo)
        }
    }

    private func typed(_ prompt: String, echo: Bool) -> Int32 {
        guard let answer = terminal.ask(prompt, echo: echo) else { return 1 }
        write(Data((answer + "\n").utf8))
        return 0
    }

    public static func exchange(_ path: String, _ request: Data) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 120, tv_usec: 0)  // Touch ID may be on screen meanwhile.
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes); raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, request.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == request.count else { return nil }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        while reply.count <= AskpassProtocol.replyLimit {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return reply.isEmpty ? nil : reply }
            reply.append(contentsOf: buffer.prefix(count))
        }
        return nil
    }
}

public protocol AskpassTerminal {
    func show(_ text: String)
    /// Nil when there is no terminal or input ended.
    func ask(_ prompt: String, echo: Bool) -> String?
}

/// The controlling terminal ssh shares with the session pane.
public struct DeviceTerminal: AskpassTerminal {
    public init() {}

    public func show(_ text: String) {
        let fd = open("/dev/tty", O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        put(fd, text + "\r\n")
    }

    public func ask(_ prompt: String, echo: Bool) -> String? {
        let fd = open("/dev/tty", O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var saved = termios()
        let restore = !echo && tcgetattr(fd, &saved) == 0
        if restore {
            var silent = saved
            silent.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(fd, TCSAFLUSH, &silent)
        }
        defer { if restore { tcsetattr(fd, TCSAFLUSH, &saved); put(fd, "\r\n") } }
        put(fd, prompt)
        var line = [UInt8]()
        var byte: UInt8 = 0
        while line.count < 4096 {
            let count = read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return line.isEmpty ? nil : String(decoding: line, as: UTF8.self) }
            if byte == 0x0A || byte == 0x0D { break }
            line.append(byte)
        }
        defer { line.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return String(decoding: line, as: UTF8.self)
    }

    private func put(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
}
