#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif
import TrellisPOSIX

/// A work tree's state for a pane header (FR-PL09): the branch or detached commit and counts only, never file names.
public struct BrokerGitStatus: Codable, Equatable, Sendable {
    public var branch: String?
    /// The short commit when HEAD is detached.
    public var commit: String?
    public var changes: Int
    public var ahead: Int
    public var behind: Int
    public init(branch: String?, commit: String?, changes: Int, ahead: Int, behind: Int) {
        self.branch = branch; self.commit = commit; self.changes = changes; self.ahead = ahead; self.behind = behind
    }
}

/// `git status` with a fixed argument list, never through a shell, on this Mac or by a host's helper (FR-PL09, FR-RW12).
public enum BrokerGit {
    /// Runs in whatever folder a shell enters, so repository settings that run programs are switched off where that leaves the
    /// output unchanged: no fsmonitor hook, no hooks, and no transport (a partial clone's lazy fetch could run `core.sshCommand`).
    public static let arguments = [
        "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "protocol.allow=never", "status", "--porcelain=v2", "--branch"
    ]
    public static let timeoutMilliseconds: Int32 = 2000
    static let outputLimit = 1_048_576
    static let searchPath = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "/bin"]

    /// `--porcelain=v2 --branch` output as counts; file names are counted, never kept.
    public static func parse(_ output: String) -> BrokerGitStatus {
        var status = BrokerGitStatus(branch: nil, commit: nil, changes: 0, ahead: 0, behind: 0)
        var oid: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.oid ") {
                let value = line.dropFirst("# branch.oid ".count)
                oid = value == "(initial)" ? nil : String(value.prefix(7))
            } else if line.hasPrefix("# branch.head ") {
                let value = line.dropFirst("# branch.head ".count)
                status.branch = value == "(detached)" ? nil : String(value.prefix(255))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                if parts.count == 2 { status.ahead = Int(parts[0].dropFirst()) ?? 0; status.behind = Int(parts[1].dropFirst()) ?? 0 }
            } else if let kind = line.first, "12u?".contains(kind) {
                status.changes += 1
            }
        }
        if status.branch == nil { status.commit = oid }
        return status
    }

    /// Nil outside a work tree, when git isn't found, fails or takes longer than the limit.
    public static func status(directory: String, environment: [String: String]) -> BrokerGitStatus? {
        guard directory.hasPrefix("/"), !directory.contains("\0"), let git = locate(environment["PATH"]) else { return nil }
        var variables = environment.filter { ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR"].contains($0.key) }
        variables["LC_ALL"] = "C"; variables["GIT_OPTIONAL_LOCKS"] = "0"; variables["GIT_TERMINAL_PROMPT"] = "0"; variables["GIT_NO_LAZY_FETCH"] = "1"
        let argv = ([git] + arguments).map { strdup($0) } + [nil]
        let envp = variables.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var buffer = [CChar](repeating: 0, count: outputLimit)
        var length = 0
        let result = argv.withUnsafeBufferPointer { arguments in
            envp.withUnsafeBufferPointer { environment in
                buffer.withUnsafeMutableBufferPointer { output in
                    trellis_run_capture(git, arguments.baseAddress, environment.baseAddress, directory, output.baseAddress, output.count, &length, timeoutMilliseconds)
                }
            }
        }
        // Exited normally with status 0: (status & 0x7f) == 0 and the exit code in bits 8–15.
        guard result >= 0, result & 0x7f == 0, (result >> 8) & 0xff == 0 else { return nil }
        let bytes = buffer.prefix(length).map { UInt8(bitPattern: $0) }
        return parse(String(decoding: bytes, as: UTF8.self))
    }

    static func locate(_ path: String?, developerDirectories: [String]? = nil) -> String? {
        let folders = (path?.split(separator: ":").map(String.init) ?? []) + searchPath
        return folders.lazy.filter { $0.hasPrefix("/") }.map { $0 + "/git" }.first {
            guard access($0, X_OK) == 0 else { return false }
            #if canImport(Darwin)
                // macOS's /usr/bin/git is a shim that asks to install the developer tools when there are none: never at a prompt.
                if $0 == "/usr/bin/git" { return (developerDirectories ?? Self.developerDirectories()).contains { access($0 + "/usr/bin/git", X_OK) == 0 } }
            #endif
            return true
        }
    }

    #if canImport(Darwin)
        /// Where the shim finds git: `xcode-select`'s choice, else Xcode or the Command Line Tools.
        static func developerDirectories() -> [String] {
            var selected = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlink("/var/db/xcode_select_link", &selected, selected.count - 1)
            guard length > 0 else { return ["/Applications/Xcode.app/Contents/Developer", "/Library/Developer/CommandLineTools"] }
            return [String(decoding: selected.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)]
        }
    #endif
}
