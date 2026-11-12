import Foundation
import TrellisCore

/// One `session.execute` waiting for its command (methods.md#sessions). Trellis types only at an idle prompt, so the next
/// command the shell starts is the typed one; it is followed to its finish mark by order, as a task run is (FR-TK07),
/// since bash reports only a line's first command. Runtime only: never persisted or logged.
@MainActor
final class CommandWait {
    enum Outcome: Equatable {
        case finished(exitCode: Int32?, duration: TimeInterval)
        /// The session ended (or the pane was closed) before the command finished.
        case sessionEnded
        case timedOut
    }

    let sessionID: UUID
    private(set) var startedAt: Date?
    fileprivate(set) var outcome: Outcome? { didSet { if outcome != nil { wake() } } }
    /// The waiter, parked until a mark settles the outcome or its next liveness check is due.
    private var waiter: CheckedContinuation<Void, Never>?

    init(sessionID: UUID) { self.sessionID = sessionID }

    /// Parks until `apply` settles the outcome or `interval` passes, whichever is first.
    fileprivate func signal(within interval: Duration) async {
        guard outcome == nil else { return }
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: interval)
            self?.wake()
        }
        await withCheckedContinuation { waiter = $0 }
        timer.cancel()
    }

    private func wake() {
        waiter?.resume()
        waiter = nil
    }

    /// Advances on a shell mark, as `TaskRun.apply` does.
    fileprivate func apply(_ event: ShellIntegrationEvent, now: Date) {
        guard outcome == nil else { return }
        switch (startedAt, event) {
        case (nil, .commandStart): startedAt = now
        // The line ran no command (empty, or rejected by the shell): it is done at once, its status unknown.
        case (nil, .promptStart): outcome = .finished(exitCode: nil, duration: 0)
        case (let since?, .commandFinished(let code)): outcome = .finished(exitCode: code, duration: now.timeIntervalSince(since))
        case (let since?, .promptStart): outcome = .finished(exitCode: nil, duration: now.timeIntervalSince(since))
        default: break
        }
    }
}

extension AppWorkspaceModel {
    /// Why a pane's shell can't report when a typed command finishes, or nil when it can: it needs authenticated
    /// integration (FR-SI02) and must be at its prompt, so the next command it starts is the one typed.
    func commandWaitRefusal(paneID: UUID, sessionID: UUID) -> String? {
        guard let terminal = terminals[paneID], terminal.sessionID == sessionID, terminal.sessionState == .running, !isClosing(paneID: paneID), !shuttingDown
        else { return "notRunning" }
        guard terminal.shellMarkOrigin == .authenticated, let state = shellStates[paneID] else { return "noIntegration" }
        // Another wait's line may not have started yet: both would take its marks, so one waits at a time per pane.
        if state.commandRunning || terminal.isReplaying || taskRuns[paneID]?.isActive == true || commandWaits[paneID]?.isEmpty == false { return "busy" }
        return nil
    }

    /// Registers a wait before the command is typed, so a quick command's marks are never missed.
    func beginCommandWait(paneID: UUID, sessionID: UUID) -> CommandWait {
        let wait = CommandWait(sessionID: sessionID)
        commandWaits[paneID, default: []].append(wait)
        return wait
    }

    /// Waits for the command's finish mark, the session's end or the timeout, whichever comes first. Marks arrive through
    /// `updateCommandWaits` and wake the waiter at once; the session's end, the deadline and cancellation are checked at
    /// least every 250 ms, a few comparisons on the main actor.
    func awaitCommand(_ wait: CommandWait, paneID: UUID, timeout: Duration) async -> CommandWait.Outcome {
        let deadline = ContinuousClock.now + timeout
        defer { endCommandWait(wait, paneID: paneID) }
        while wait.outcome == nil {
            let terminal = terminals[paneID]
            if terminal?.sessionID != wait.sessionID || terminal?.isRunning != true {
                wait.outcome = .sessionEnded
            } else if ContinuousClock.now >= deadline || Task.isCancelled {
                wait.outcome = .timedOut
            } else {
                await wait.signal(within: min(.milliseconds(250), deadline - .now))
            }
        }
        return wait.outcome ?? .timedOut
    }

    func endCommandWait(_ wait: CommandWait, paneID: UUID) {
        commandWaits[paneID]?.removeAll { $0 === wait }
        if commandWaits[paneID]?.isEmpty == true { commandWaits.removeValue(forKey: paneID) }
    }

    /// Replayed marks (FR-R03) describe commands that finished while Trellis was closed, never the one typed now.
    func updateCommandWaits(paneID: UUID, event: ShellIntegrationEvent) {
        guard let waits = commandWaits[paneID], terminals[paneID]?.isReplaying != true else { return }
        let now = activityNow()
        for wait in waits { wait.apply(event, now: now) }
    }
}
