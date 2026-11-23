import Foundation
import TrellisCore

/// FR-LK: the lock screen. The model owns the state; the root view draws it and the app keeps keys away from the panes.
extension AppWorkspaceModel {
    /// Why Lock can't be used now, for the button's tooltip; nil when it can.
    public var lockUnavailableReason: String? {
        if isLocked { return L("Trellis is already locked.") }
        guard lockGate != nil, lockAvailable() else { return L("This Mac can't ask for Touch ID or a password.") }
        if welcomeTourVisible { return L("Finish or skip the welcome tour first.") }
        if isRestoring || recoveryMessage != nil { return L("The workspace is still loading.") }
        return nil
    }

    /// Covers the workspace (FR-LK01, FR-LK02). Closes the command palette and takes away a showing screensaver.
    @discardableResult
    public func lockWorkspace() -> Bool {
        guard lockUnavailableReason == nil else { return false }
        if commandPaletteVisible { closeCommandPalette() }
        dismissScreensaver()
        isLocked = true
        onLockChanged?(true)
        return true
    }

    /// A click or key on the lock screen (FR-LK04): asks for Touch ID or the password, once at a time, and unlocks on success.
    public func requestUnlock() {
        guard isLocked, !unlockInProgress, let gate = lockGate else { return }
        unlockInProgress = true
        Task { [weak self] in
            let allowed = await gate.authorize(reason: L("unlock the workspace"))
            guard let self else { return }
            unlockInProgress = false
            guard allowed, isLocked else { return }
            isLocked = false
            // Coming back counts as activity, so the screensaver doesn't start the moment the lock goes away.
            screensaverClock.noteActivity(at: activityNow())
            onLockChanged?(false)
        }
    }

    /// The count on the lock screen; names nothing from the workspace.
    public var runningSessionCount: Int { terminals.values.filter { $0.sessionState == .running }.count }
}
