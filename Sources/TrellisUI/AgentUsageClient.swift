import Foundation
import TrellisCore

/// What the usage endpoint answered (FR-AG23).
public enum AgentUsageHTTP: Equatable, Sendable {
    case ok(Data)
    case status(Int)
    case failed
}

/// What `codex app-server` answered (FR-AG23).
public enum CodexUsageOutcome: Equatable, Sendable {
    case reply(CodexUsage.Reply)
    case failed
}

/// Reads the agents' own sign-ins and asks for their limits (FR-AG22, FR-AG23); tests inject fakes.
public struct AgentUsageClient: Sendable {
    /// Claude Code's sign-in from its Keychain item; nil when there is none or it can't be read.
    public var claudeCredential: @Sendable () async -> ClaudeCredential?
    public var claudeUsage: @Sendable (_ accessToken: String) async -> AgentUsageHTTP
    /// Runs `<executable> app-server` with the login PATH and reads `account/rateLimits/read`.
    public var codexRateLimits: @Sendable (_ executable: String, _ path: [String]?) async -> CodexUsageOutcome

    public init(
        claudeCredential: @escaping @Sendable () async -> ClaudeCredential?, claudeUsage: @escaping @Sendable (String) async -> AgentUsageHTTP,
        codexRateLimits: @escaping @Sendable (String, [String]?) async -> CodexUsageOutcome
    ) {
        self.claudeCredential = claudeCredential; self.claudeUsage = claudeUsage; self.codexRateLimits = codexRateLimits
    }

    public static let live = AgentUsageClient(
        claudeCredential: {
            // Through /usr/bin/security, as Claude Code itself reads and writes the item: the macOS access prompt, if any,
            // names that tool. A minute leaves time to answer it.
            // It can wait that long on the prompt, so it blocks a thread of its own, not one of Swift's shared pool.
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                AgentUsageClient.keychainQueue.async {
                    continuation.resume(returning: AgentPathProbe.runProcess("/usr/bin/security", ["find-generic-password", "-s", ClaudeUsage.keychainService, "-w"], 60))
                }
            }.flatMap { ClaudeUsage.parseCredential(Data($0.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) }
        },
        claudeUsage: { token in
            var request = URLRequest(url: ClaudeUsage.endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(ClaudeUsage.betaHeader, forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            // The token goes to the endpoint only (FR-AG23): a redirect is refused, so its 3xx comes back as a failure.
            guard let (data, response) = try? await session.data(for: request, delegate: NoRedirects()), let http = response as? HTTPURLResponse,
                AgentUsageClient.isEndpoint(http.url)
            else { return .failed }
            guard http.statusCode == 200 else { return (300..<400).contains(http.statusCode) ? .failed : .status(http.statusCode) }
            return data.count <= 1_048_576 ? .ok(data) : .failed
        },
        codexRateLimits: { executable, path in await CodexAppServer.readRateLimits(executable: executable, path: path, timeout: 10) }
    )

    static let keychainQueue = DispatchQueue(label: "com.bearstouch.trellis.agent-usage-keychain")

    static func isEndpoint(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == ClaudeUsage.endpoint.scheme && url.host == ClaudeUsage.endpoint.host && url.path == ClaudeUsage.endpoint.path
    }
}

/// Refuses every redirect, so the Authorization header never follows one.
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// One short-lived `codex app-server`: three lines in, read until the limits reply, then ended.
enum CodexAppServer {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var reader = CodexUsage.LineReader()
        private var finished = false
        func append(_ data: Data) -> CodexUsage.Reply? { lock.withLock { finished ? nil : reader.append(data) } }
        /// A reply on the last line without a newline.
        func end() -> CodexUsage.Reply? { lock.withLock { finished ? nil : reader.finish() } }
        func claim() -> Bool {
            lock.withLock {
                defer { finished = true }; return !finished
            }
        }
    }

    static func readRateLimits(executable: String, path: [String]?, timeout: TimeInterval) async -> CodexUsageOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        // An npm-installed codex is a node script: it needs the login shell's PATH, not a Finder-launched app's.
        if let path, !path.isEmpty { environment["PATH"] = path.joined(separator: ":") }
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let state = State()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return await withCheckedContinuation { (continuation: CheckedContinuation<CodexUsageOutcome, Never>) in
            @Sendable func finish(_ outcome: CodexUsageOutcome) {
                guard state.claim() else { return }
                output.fileHandleForReading.readabilityHandler = nil
                // End of input makes app-server exit; SIGTERM covers one that doesn't read it. No SIGKILL by PID later: by
                // then Foundation may have reaped it and the PID may belong to another process.
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                continuation.resume(returning: outcome)
            }
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return finish(state.end().map { .reply($0) } ?? .failed) }
                if let reply = state.append(data) { finish(.reply(reply)) }
            }
            process.terminationHandler = { _ in
                // Lines still in the pipe are read by the handler first; a process gone without a reply failed.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { finish(.failed) }
            }
            // A codex that exits before reading must fail the write, not raise SIGPIPE in the app.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            do { try process.run() } catch { return finish(.failed) }
            try? input.fileHandleForWriting.write(contentsOf: CodexUsage.requestLines(version: version))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.failed) }
        }
    }
}
