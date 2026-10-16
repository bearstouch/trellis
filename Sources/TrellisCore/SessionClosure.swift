import Foundation

@MainActor
public protocol ClosableSession: AnyObject {
    var sessionID: UUID { get }
    var isRunning: Bool { get }
    /// False after the child exits, even while retained output is draining.
    var requiresTermination: Bool { get }
    func requestTermination(force: Bool)
}

public extension ClosableSession {
    var requiresTermination: Bool { isRunning }
}

public enum SessionClosureResult: Equatable, Sendable {
    case closed
    case confirmationRequired(sessionIDs: [UUID])
    case closePending(sessionIDs: [UUID])

    public var code: String? {
        switch self {
        case .closed: nil
        case .confirmationRequired: "CONFIRMATION_REQUIRED"
        case .closePending: "CLOSE_PENDING"
        }
    }
}

/// UI and future automation adapters share this policy; it never shows dialogs.
/// Force is a separate call after an authorized two-second graceful attempt.
@MainActor
public final class SessionClosureCoordinator {
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async throws -> Void
    private var gracefulSince: [UUID: TimeInterval] = [:]

    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.now = now; self.sleep = sleep
    }

    public func forget(sessionID: UUID) { gracefulSince.removeValue(forKey: sessionID) }

    public func close(_ sessions: [any ClosableSession], allowRunning: Bool, force: Bool = false) async -> SessionClosureResult {
        var live = sessions.filter(\.isRunning)
        guard !live.isEmpty else { sessions.forEach { gracefulSince.removeValue(forKey: $0.sessionID) }; return .closed }
        guard allowRunning else { return .confirmationRequired(sessionIDs: live.map(\.sessionID)) }
        if force {
            guard live.filter(\.requiresTermination).allSatisfy({ gracefulSince[$0.sessionID].map { now() - $0 >= 2 } == true }) else {
                return .closePending(sessionIDs: live.map(\.sessionID))
            }
        }
        for session in live where session.requiresTermination {
            if !force, gracefulSince[session.sessionID] == nil { gracefulSince[session.sessionID] = now() }
            session.requestTermination(force: force)
        }
        live = sessions.filter(\.isRunning)
        let deadline = now() + 2
        while !live.isEmpty, now() < deadline, !Task.isCancelled {
            do { try await sleep(min(0.02, max(0, deadline - now()))) } catch { break }
            live = sessions.filter(\.isRunning)
        }
        for session in sessions where !session.isRunning { gracefulSince.removeValue(forKey: session.sessionID) }
        return live.isEmpty ? .closed : .closePending(sessionIDs: live.map(\.sessionID))
    }
}

/// PID alone is insufficient after another component or the OS reaps a child.
/// Capture launch identity and revalidate it before signaling an owned group.
public struct OwnedProcessIdentity: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let groupID: Int32
    public let startedSeconds: UInt64
    public let startedMicroseconds: UInt64
    public init(pid: Int32, parentPID: Int32, groupID: Int32, startedSeconds: UInt64, startedMicroseconds: UInt64) {
        self.pid = pid; self.parentPID = parentPID; self.groupID = groupID
        self.startedSeconds = startedSeconds; self.startedMicroseconds = startedMicroseconds
    }
    public func permitsSignal(current: Self?, ownerPID: Int32) -> Bool {
        pid > 0 && parentPID == ownerPID && groupID == pid && current == self
    }
}
