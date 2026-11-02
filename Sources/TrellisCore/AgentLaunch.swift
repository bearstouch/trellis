import Foundation

/// A pane that runs an agent (FR-AG04). Only the agent's ID and the directory are kept; its command line is rebuilt
/// from the current definition at every start, so nothing typed or secret is ever saved.
public struct AgentLaunch: Codable, Equatable, Sendable {
    public var agentID: String
    public var directory: String?
    /// Set in a remote workspace: the agent runs on this saved host (FR-AG12).
    public var hostID: UUID?
    /// Start with the agent's resume arguments (FR-AG06). Never saved: a restored pane starts fresh unless asked.
    public var resume: Bool

    public init(agentID: String, directory: String?, hostID: UUID? = nil, resume: Bool = false) {
        self.agentID = agentID; self.directory = directory; self.hostID = hostID; self.resume = resume
    }
}

/// The text a login shell runs with `-c` to start an agent with Trellis's state wiring (FR-AG08). The words are
/// single-quoted, which reads the same in sh, bash, zsh, ksh and fish; the agent runs through `env`, so a missing agent
/// exits 127 (`notInstalledStatus`) without any shell-specific syntax.
public struct AgentCommand: Equatable, Sendable {
    public static let notInstalledStatus: Int32 = 127
    public static let piExtensionName = "trellis-pi-extension.ts"
    public static let hookVariable = "TRELLIS_AGENT_HOOK"

    public var definition: AgentDefinition
    public var resume: Bool
    /// Absolute path of `trellis-broker` on the machine the agent runs on; nil runs the agent without live state.
    public var hookHelper: String?
    /// The pi extension's absolute path on that machine.
    public var piExtension: String?
    /// The pi extension's text, written beside the helper first on a remote host, which has no copy of the bundle.
    public var piExtensionSource: String?
    public var extraArguments: [String]

    public init(definition: AgentDefinition, resume: Bool = false, hookHelper: String? = nil, piExtension: String? = nil, piExtensionSource: String? = nil, extraArguments: [String] = []) {
        self.definition = definition; self.resume = resume; self.hookHelper = hookHelper; self.piExtension = piExtension
        self.piExtensionSource = piExtensionSource; self.extraArguments = extraArguments
    }

    /// `env [TRELLIS_AGENT_HOOK=…] <executable> <wiring…> <arguments…> [resume…] [extra…]`.
    public var words: [String] {
        var words = ["env"]
        var wiring: [String] = []
        if let helper = hookHelper {
            switch definition.integration {
            case .claudeHooks: wiring = ["--settings", Self.claudeSettings(helper: helper)]
            case .codexNotify: wiring = ["-c", "notify=" + Self.tomlArray([helper, "agent-hook", "done"])]
            case .piExtension:
                if let piExtension {
                    words.append(Self.hookVariable + "=" + helper)
                    wiring = ["-e", piExtension]
                }
            case .none: break
            }
        }
        words.append(definition.executable)
        // pi takes `-e` before its own flags; Claude Code and Codex accept their wiring anywhere before a prompt.
        words += wiring + definition.arguments + (resume ? definition.resumeArguments : []) + extraArguments
        return words
    }

    public var line: String {
        let command = "exec " + words.map(Self.quote).joined(separator: " ")
        guard let source = piExtensionSource, let piExtension, definition.integration == .piExtension, hookHelper != nil else { return command }
        // `;` and `>` read the same in every shell this runs in; a failed write only costs pi its live state.
        let folder = (piExtension as NSString).deletingLastPathComponent
        return "mkdir -p \(Self.quote(folder)); printf '%s' \(Self.quote(source)) > \(Self.quote(piExtension)); \(command)"
    }

    /// Hooks only report: they print nothing and always exit 0, so they never decide or block anything.
    static func claudeSettings(helper: String) -> String {
        func hook(_ event: String, matcher: String? = nil) -> [String: Any] {
            var entry: [String: Any] = ["hooks": [["type": "command", "command": quote(helper) + " agent-hook " + event, "timeout": 5]]]
            if let matcher { entry["matcher"] = matcher }
            return entry
        }
        let hooks: [String: Any] = [
            "SessionStart": [hook("start")],
            "UserPromptSubmit": [hook("working")],
            "PreToolUse": [hook("working", matcher: "*")],
            "PostToolUse": [hook("working", matcher: "*")],
            "PermissionRequest": [hook("needs-input", matcher: "*")],
            "Notification": [hook("needs-input", matcher: "permission_prompt|elicitation_dialog")],
            "Stop": [hook("done")],
            "StopFailure": [hook("error")],
            "SessionEnd": [hook("end")]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func tomlArray(_ values: [String]) -> String {
        "[" + values.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: ",") + "]"
    }

    /// One shell word: plain safe characters as is, anything else single-quoted (`'` becomes `'\''`).
    public static func quote(_ word: String) -> String {
        guard word.isEmpty || word.utf8.contains(where: { !isPlain($0) }) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isPlain(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || [0x2f, 0x2e, 0x5f, 0x2d, 0x2b, 0x3d, 0x3a, 0x2c, 0x40].contains(byte)
    }
}

/// How a login shell runs an agent's command line. zsh and bash read their interactive files only with `-i`, and those
/// files are often where version managers put agents on PATH; csh and tcsh take `-l` only alone, so a POSIX shell runs
/// the line instead.
public enum AgentShell {
    public static func arguments(shell: String, line: String) -> (executable: String, arguments: [String]) {
        switch (shell as NSString).lastPathComponent {
        case "zsh", "bash", "fish": (shell, ["-l", "-i", "-c", line])
        case "csh", "tcsh": ("/bin/sh", ["-l", "-c", line])
        default: (shell, ["-l", "-c", line])
        }
    }

    /// A remote helper already runs `<shell> -l -c <command>`; this adds the interactive files for zsh, bash and fish.
    public static func remoteCommand(shell: String?, line: String) -> String {
        guard let shell, ["zsh", "bash", "fish"].contains((shell as NSString).lastPathComponent) else { return line }
        return "exec " + AgentCommand.quote(shell) + " -i -c " + AgentCommand.quote(line)
    }
}

/// Finds agents on the PATH a login shell would give them (FR-AG07), so the Agent menu can say "Not installed" before
/// anything runs. The shell's own startup output is skipped: only the marked line counts.
public enum AgentPathProbe {
    static let marker = "TRELLIS-PATH:"
    /// Runs a program with stdin closed and returns its stdout, or nil on failure or after `timeout` seconds.
    public typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> String?

    public static func loginPath(shell: String, run: Runner = runProcess) -> [String]? {
        let line = "printf '\\n\(marker)%s\\n' \"$PATH\""
        let (executable, arguments) = AgentShell.arguments(shell: shell, line: line)
        guard let output = run(executable, arguments, 5) else { return nil }
        guard let found = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(marker) }) else { return nil }
        let path = found.dropFirst(marker.count).split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        return path.isEmpty ? nil : path
    }

    public static func resolve(_ executable: String, path: [String]?, files: any LaunchFileAccess = SystemLaunchFileAccess()) -> String? {
        if executable.hasPrefix("/") { return files.isExecutableFile(executable) ? executable : nil }
        return path?.lazy.map { ($0.hasSuffix("/") ? $0 : $0 + "/") + executable }.first(where: files.isExecutableFile)
    }

    public static let runProcess: Runner = { executable, arguments, timeout in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let reader = DispatchQueue(label: "com.bearstouch.trellis.agent-path")
        nonisolated(unsafe) var data = Data()
        let done = DispatchSemaphore(value: 0)
        reader.async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            // An interactive startup file that waits for input never blocks the menu. Interactive bash and zsh ignore
            // SIGTERM, so the shell is killed outright and the reader ends with the pipe.
            process.terminate()
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        process.waitUntilExit()
        return String(decoding: data.prefix(1_048_576), as: UTF8.self)
    }
}
