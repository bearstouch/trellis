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

/// Facts a remote broker reports about its host and account (protocol v2).
public enum BrokerHost {
    public struct Account: Equatable, Sendable {
        public var user: String, home: String, shell: String
    }

    /// The effective user's passwd entry; `HOME` wins over the entry's home only when it is an absolute directory.
    public static func account(environment: [String: String] = ProcessInfo.processInfo.environment) -> Account {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 65_536)
        let entry: Account? = buffer.withUnsafeMutableBufferPointer { bytes in
            guard getpwuid_r(geteuid(), &record, bytes.baseAddress!, bytes.count, &result) == 0, result != nil else { return nil }
            func text(_ pointer: UnsafeMutablePointer<CChar>?) -> String { pointer.map { String(cString: $0) } ?? "" }
            return Account(user: text(record.pw_name), home: text(record.pw_dir), shell: text(record.pw_shell))
        }
        var account = entry ?? Account(user: environment["USER"] ?? "", home: "", shell: "")
        if let home = environment["HOME"], home.hasPrefix("/"), BrokerFiles.entry(home)?.kind == .directory { account.home = home }
        if account.home.isEmpty { account.home = "/" }
        if !isExecutableFile(account.shell) { account.shell = "/bin/sh" }
        return account
    }

    public static func isExecutableFile(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        var info = stat()
        return stat(path, &info) == 0 && BrokerFiles.kind(info.st_mode) == .file && access(path, X_OK) == 0
    }

    public static func isUsableDirectory(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        var info = stat()
        return stat(path, &info) == 0 && BrokerFiles.kind(info.st_mode) == .directory && access(path, X_OK) == 0
    }

    public static func isReadableFile(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        var info = stat()
        return stat(path, &info) == 0 && BrokerFiles.kind(info.st_mode) == .file && access(path, R_OK) == 0
    }

    public static func info(account: Account = account()) -> BrokerHostInfo {
        var system = [CChar](repeating: 0, count: 256), machine = [CChar](repeating: 0, count: 256)
        let named = trellis_uname(&system, system.count, &machine, machine.count) == 0
        var identifier = [CChar](repeating: 0, count: 128)
        let length = trellis_machine_id(&identifier, identifier.count)
        func text(_ chars: [CChar]) -> String { String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        return BrokerHostInfo(
            os: named ? text(system).lowercased() : "unknown", arch: named ? text(machine) : "unknown", user: account.user, home: account.home, shell: account.shell,
            machineID: length > 0 ? text(identifier) : nil, executable: BrokerFiles.executablePath(pid: getpid()) ?? "",
            sessionsEndAtLogout: killsUserProcesses(user: account.user))
    }

    /// Best effort: systemd-logind's `KillUserProcesses=yes` (main file, then drop-ins in name order) without lingering.
    public static func killsUserProcesses(user: String, root: String = "") -> Bool {
        guard !user.isEmpty, BrokerFiles.entry(root + "/var/lib/systemd/linger/" + user) == nil else { return false }
        var files = [root + "/etc/systemd/logind.conf"]
        for directory in [root + "/etc/systemd/logind.conf.d", root + "/usr/lib/systemd/logind.conf.d"] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            files += names.filter { $0.hasSuffix(".conf") }.sorted().map { directory + "/" + $0 }
        }
        var kills = false
        for file in files {
            guard let data = FileManager.default.contents(atPath: file), data.count <= 65_536 else { continue }
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                let text = trimmed(line)
                guard text.hasPrefix("KillUserProcesses=") else { continue }
                kills = ["yes", "true", "1", "on"].contains(trimmed(text.dropFirst("KillUserProcesses=".count)).lowercased())
            }
        }
        return kills
    }

    private static func trimmed(_ text: Substring) -> Substring {
        let blank: Set<Character> = [" ", "\t", "\r"]
        guard let start = text.firstIndex(where: { !blank.contains($0) }), let end = text.lastIndex(where: { !blank.contains($0) }) else { return "" }
        return text[start...end]
    }
}
