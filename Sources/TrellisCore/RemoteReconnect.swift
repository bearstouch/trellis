import Foundation

/// Why an automatic (`BatchMode`) ssh attempt failed, from its exit and what it wrote to its terminal (FR-RW07). Only a
/// network failure is retried on its own; anything that needs the person (a password, a passphrase, a changed host key)
/// stops automatic attempts, so a credential is never retried in a loop (INT-05).
public enum RemoteSSHDiagnosis: Equatable, Sendable {
    case unreachable(String)
    case needsInput(String)

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
            return .needsInput(line.isEmpty ? "The host needs your password or a decision about its key." : line)
        }
        if networkMarkers.contains(where: text.contains) { return .unreachable(line) }
        // ssh's own failures exit 255; without a recognizable reason, ask rather than retry blindly.
        return exitCode == 255 ? .needsInput(line.isEmpty ? "ssh couldn't connect without asking you something." : line) : .unreachable(line)
    }
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
