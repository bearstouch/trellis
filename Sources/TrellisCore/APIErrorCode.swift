import Foundation

/// API2-03: the one list of application error codes (`data.code` on JSON-RPC -32000 errors). Diagnostics'
/// `knownErrorCodes`, the CLI exit-code map and the MCP mapping derive from it, and a test compares it with the error
/// table in `docs/api/v2/index.md`.
public enum APIErrorCode: String, CaseIterable, Codable, Sendable {
    case authRequired = "AUTH_REQUIRED"
    case permissionDenied = "PERMISSION_DENIED"
    case notFound = "NOT_FOUND"
    case conflict = "CONFLICT"
    case invalidState = "INVALID_STATE"
    case confirmationRequired = "CONFIRMATION_REQUIRED"
    case closePending = "CLOSE_PENDING"
    case limitExceeded = "LIMIT_EXCEEDED"
    case launchFailed = "LAUNCH_FAILED"
    case remoteDisconnected = "REMOTE_DISCONNECTED"
    case agentUnavailable = "AGENT_UNAVAILABLE"
    case taskUntrusted = "TASK_UNTRUSTED"
    case setupRequired = "SETUP_REQUIRED"
    case invalidCursor = "INVALID_CURSOR"
    case unsupportedVersion = "UNSUPPORTED_VERSION"

    public enum Retryability: String, Sendable { case no, yes, sometimes }

    /// Whether retrying the same call can succeed. `sometimes` codes decide per error (an `INVALID_STATE` for a session
    /// still starting is retryable; one for an exited session is not).
    public var retryability: Retryability {
        switch self {
        case .closePending, .limitExceeded, .remoteDisconnected: .yes
        case .invalidState: .sometimes
        default: .no
        }
    }

    /// The `retryable` flag sent when the call site doesn't decide.
    public var defaultRetryable: Bool { retryability == .yes }

    /// The protocol 2 CLI exit status: 2 arguments, schema or version · 3 not found · 4 auth, permission or trust ·
    /// 5 conflict or state · 6 launch · 7 app or link unavailable · 8 limits and anything else.
    public var cliExitStatus: Int32 {
        switch self {
        case .invalidCursor, .unsupportedVersion: 2
        case .notFound: 3
        case .authRequired, .permissionDenied, .taskUntrusted: 4
        case .conflict, .invalidState, .confirmationRequired, .closePending, .setupRequired: 5
        case .launchFailed, .agentUnavailable: 6
        case .remoteDisconnected: 7
        case .limitExceeded: 8
        }
    }

    /// How MCP reports the code: every application error is a tool error (`isError`) carrying the code, so an agent
    /// can recover; `AUTH_REQUIRED` also ends the MCP session, as it ends a socket's authentication.
    public enum MCPDisposition: Sendable, Equatable { case toolError, toolErrorEndingSession }
    public var mcpDisposition: MCPDisposition { self == .authRequired ? .toolErrorEndingSession : .toolError }

    /// The protocol 2 CLI exit status for any error reply: application codes from the registry, JSON-RPC codes as in v1.
    public static func cliExitStatus(appCode: String?, rpcCode: Int) -> Int32 {
        if let appCode { return Self(rawValue: appCode)?.cliExitStatus ?? 8 }
        return [-32700, -32600, -32602].contains(rpcCode) ? 2 : rpcCode == -32601 ? 3 : 8
    }
}
