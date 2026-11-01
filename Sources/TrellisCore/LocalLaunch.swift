import Darwin
import Foundation

public struct LocalLaunchConfiguration: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var directory: String
    public var inheritedEnvironment: [String: String]
    public var environmentOverrides: [String: String]
    /// Trusted, app-planned rewrite; never derived from automation input.
    public var shellIntegration: ShellIntegrationInjection?
    /// Trusted, app-planned agent hook channel (FR-AG08): the only control variables a launch carries.
    public var agentHook: AgentHookEnvironment?

    public init(
        executable: String, arguments: [String] = [], directory: String,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        environmentOverrides: [String: String] = [:], shellIntegration: ShellIntegrationInjection? = nil
    ) {
        self.executable = executable; self.arguments = arguments; self.directory = directory
        self.inheritedEnvironment = inheritedEnvironment; self.environmentOverrides = environmentOverrides
        self.shellIntegration = shellIntegration
    }

    public static func loginShell(
        executable: String? = nil, directory: String? = nil,
        environmentOverrides: [String: String] = [:]
    ) -> Self {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: max(16_384, Int(sysconf(_SC_GETPW_R_SIZE_MAX))))
        let accountShell: String? = buffer.withUnsafeMutableBufferPointer { bytes in
            guard getpwuid_r(getuid(), &record, bytes.baseAddress, bytes.count, &result) == 0,
                result != nil, let path = record.pw_shell
            else { return nil }
            return String(cString: path)
        }
        return Self(
            executable: executable ?? accountShell ?? "/bin/zsh", arguments: ["-l"],
            directory: directory ?? FileManager.default.homeDirectoryForCurrentUser.path,
            environmentOverrides: environmentOverrides)
    }
}

/// Where an agent session's hooks report and the nonce that names it (FR-AG08). The names match `BrokerProtocol`'s, which
/// Core can't import.
public struct AgentHookEnvironment: Equatable, Sendable {
    public static let socketVariable = "TRELLIS_AGENT_SOCKET"
    public static let nonceVariable = "TRELLIS_AGENT_NONCE"
    public var socket: String
    public var nonce: String
    public init(socket: String, nonce: String) { self.socket = socket; self.nonce = nonce }
    var isValid: Bool { socket.hasPrefix("/") && !socket.contains("\0") && !nonce.isEmpty && nonce.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

public enum LocalLaunchError: Error, Equatable, Sendable {
    case invalidExecutable
    case inaccessibleDirectory
    case invalidArgument
    case invalidEnvironment
    case reservedEnvironmentKey
    case spawnFailed(Int32)
    case alreadyStarted
    case cancelled
}

public protocol LaunchFileAccess: Sendable {
    func isExecutableFile(_ path: String) -> Bool
    func isAccessibleDirectory(_ path: String) -> Bool
    func isReadableFile(_ path: String) -> Bool
}

extension LaunchFileAccess {
    public func isReadableFile(_ path: String) -> Bool { FileManager.default.isReadableFile(atPath: path) }
}

public struct SystemLaunchFileAccess: LaunchFileAccess {
    public init() {}
    public func isExecutableFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
    public func isAccessibleDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && directory.boolValue && access(path, R_OK | X_OK) == 0
    }
}

/// Only validators construct this value. Runtime environment is never Codable.
public struct ValidatedLocalLaunch: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let directory: String
    public let environment: [String: String]
    public var environmentArray: [String] { environment.keys.sorted().map { "\($0)=\(environment[$0]!)" } }
}

public struct LocalLaunchValidator: Sendable {
    private let files: any LaunchFileAccess
    public init(files: any LaunchFileAccess = SystemLaunchFileAccess()) { self.files = files }

    public func validate(_ configuration: LocalLaunchConfiguration) throws -> ValidatedLocalLaunch {
        guard configuration.executable.hasPrefix("/"), !configuration.executable.contains("\0"),
            files.isExecutableFile(configuration.executable)
        else { throw LocalLaunchError.invalidExecutable }
        guard configuration.directory.hasPrefix("/"), !configuration.directory.contains("\0"),
            files.isAccessibleDirectory(configuration.directory)
        else { throw LocalLaunchError.inaccessibleDirectory }
        guard configuration.arguments.allSatisfy({ !$0.contains("\0") }) else { throw LocalLaunchError.invalidArgument }
        func valid(_ pair: (key: String, value: String)) -> Bool {
            !pair.key.isEmpty && !pair.key.contains("=") && !pair.key.contains("\0") && !pair.value.contains("\0")
        }
        guard configuration.environmentOverrides.allSatisfy(valid) else { throw LocalLaunchError.invalidEnvironment }
        guard !configuration.environmentOverrides.keys.contains(where: Self.isControlKey) else {
            throw LocalLaunchError.reservedEnvironmentKey
        }
        var environment = configuration.inheritedEnvironment.filter { !Self.isControlKey($0.key) && valid($0) }
        environment.merge(configuration.environmentOverrides) { _, override in override }
        environment.merge(Self.terminalEnvironment) { _, terminal in terminal }
        if let hook = configuration.agentHook, hook.isValid {
            environment[AgentHookEnvironment.socketVariable] = hook.socket
            environment[AgentHookEnvironment.nonceVariable] = hook.nonce
        }
        environment.removeValue(forKey: "ITERM_SESSION_ID")
        environment.removeValue(forKey: "TERM_SESSION_ID")
        var arguments = configuration.arguments
        // A missing script launches the plain shell: basic use never depends on integration (INT-01).
        if let injection = configuration.shellIntegration, injection.kind == ShellIntegrationKind(executable: configuration.executable),
            files.isReadableFile(injection.scriptPath), injection.environment.allSatisfy(valid),
            injection.arguments.allSatisfy({ !$0.contains("\0") })
        {
            environment.merge(injection.environment) { _, injected in injected }
            arguments = injection.arguments
        }
        return ValidatedLocalLaunch(
            executable: configuration.executable, arguments: arguments,
            directory: configuration.directory, environment: environment)
    }

    /// What every Trellis session advertises, local or remote (FR-RW04). Image tools look for iTerm2 in `LC_TERMINAL`
    /// before using its inline image protocol (FR-IM05).
    public static let terminalEnvironment = [
        "TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "Trellis", "LC_TERMINAL": "iTerm2", "LC_TERMINAL_VERSION": "3.5.0"
    ]

    private static func isControlKey(_ key: String) -> Bool {
        let name = key.uppercased()
        return name.hasPrefix("TRELLIS_") || name.hasPrefix("__TRELLIS_")
            || name.hasPrefix("UTERM_") || name.hasPrefix("__UTERM_")
    }
}
