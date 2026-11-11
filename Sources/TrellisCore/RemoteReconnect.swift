import Foundation

/// Why an automatic (`BatchMode`) ssh attempt failed, from its exit and what it wrote to its terminal (FR-RW07). Only a
/// network failure is retried on its own; anything that needs the person (a password, a passphrase, a changed host key)
/// stops automatic attempts, so a credential is never retried in a loop (INT-05).
public enum RemoteSSHDiagnosis: Equatable, Sendable {
    case unreachable(String)
    /// ssh's last line, and what it needs, as a reason code.
    case needsInput(String, RemoteLinkReason)

    /// ssh's wording for network trouble, which a later attempt can get past.
    static let networkMarkers = [
        "connection refused", "connection timed out", "operation timed out", "network is unreachable", "no route to host",
        "could not resolve hostname", "name or service not known", "nodename nor servname", "temporary failure in name resolution",
        "connection reset", "connection closed by", "broken pipe", "kex_exchange_identification", "host is down", "network is down"
    ]
    static let personMarkers = [
        "permission denied", "host key verification failed", "remote host identification has changed", "too many authentication failures",
        "passphrase", "password", "keyboard-interactive", "no matching host key", "authenticity of host"
    ]

    public static func classify(exitCode: Int32?, output: String) -> Self {
        let text = output.lowercased()
        let line = output.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        // A person-only reason wins: "Connection closed by host" after a refused key still needs the person.
        if personMarkers.contains(where: text.contains) {
            return .needsInput(line.isEmpty ? L("The host needs your password or a decision about its key.") : line, inputReason(text))
        }
        if networkMarkers.contains(where: text.contains) { return .unreachable(line) }
        // ssh's own failures exit 255; without a recognizable reason, ask rather than retry blindly.
        return exitCode == 255 ? .needsInput(line.isEmpty ? L("ssh couldn't connect without asking you something.") : line, .needsInput) : .unreachable(line)
    }

    /// What ssh needs from the person, from its lowercased output. A changed key wins over the verification failure ssh
    /// prints after it; a refused key over the password methods it lists ("Permission denied (publickey,password)").
    static func inputReason(_ text: String) -> RemoteLinkReason {
        if text.contains("remote host identification has changed") { return .hostKeyChanged }
        if ["host key verification failed", "authenticity of host", "no matching host key"].contains(where: text.contains) { return .hostKeyUnverified }
        if ["permission denied", "too many authentication failures"].contains(where: text.contains) { return .authFailed }
        if text.contains("passphrase") { return .needsPassphrase }
        if text.contains("password") || text.contains("keyboard-interactive") { return .needsPassword }
        return .needsInput
    }
}

/// Why a remote workspace link is down or needs the person, as a stable code (protocol 2's `Host.remote.link.reason`,
/// `remote.link` events and error details). The app shows words in the user's language; these never change with it.
public enum RemoteLinkReason: String, Sendable, CaseIterable, Codable {
    /// ssh could not be started on this Mac.
    case sshUnavailable
    /// ssh ended before the helper answered; the connection console shows ssh's message.
    case sshExited
    /// The host couldn't be reached (refused, timed out, no route, name not resolved); a later attempt may get through.
    case hostUnreachable
    /// The host refused the keys offered (or too many tried).
    case authFailed
    case needsPassword
    case needsPassphrase
    /// The host's key differs from the one in known_hosts.
    case hostKeyChanged
    /// The host's key isn't known yet, or couldn't be verified.
    case hostKeyUnverified
    /// ssh needs the person for something else.
    case needsInput
    /// The helper isn't installed and installing it wasn't allowed or was declined.
    case helperMissing
    /// The host's system or architecture has no helper.
    case helperUnsupported
    /// This build doesn't include the helper for the host's platform.
    case helperUnavailable
    /// The host has no sha256sum, shasum or openssl, so an upload can't be verified.
    case noChecksumTool
    /// The helper on the host speaks a protocol version this build can't use.
    case helperIncompatible
    /// The connected helper predates agents in remote workspaces (protocol 3); updating it fixes this.
    case helperTooOldForAgents
    /// Installing failed on the host: a digest mismatch, no gzip, or ~/.trellis couldn't be created. Nothing was installed.
    case installFailed
    /// The host's bootstrap refused the request for another reason.
    case hostRefused
    /// An established link went quiet or closed.
    case lost
    /// Trellis closed the link (quit, Close All Workspaces).
    case closed
    /// The attempt was cancelled (Cancel in the app, or quitting).
    case cancelled
    /// The saved host was deleted.
    case hostMissing
    /// Remote workspaces aren't available in this build or state directory.
    case unavailable
    case unknown
}

/// How long to wait before automatic attempt `attempt` (1-based): 1, 2, 4 … 60 s, with ±20 % jitter so many hosts and
/// Macs don't reconnect in step. `random` is in 0…1.
public enum RemoteBackoff {
    public static let maximum: TimeInterval = 60

    public static func delay(attempt: Int, random: Double) -> TimeInterval {
        let base = min(maximum, pow(2, Double(max(0, attempt - 1))))
        return min(maximum, base * (0.8 + 0.4 * min(max(random, 0), 1)))
    }
}
