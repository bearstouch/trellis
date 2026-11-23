import Foundation
import TrellisCore

/// FR-SS: the idle screensaver over the focused pane. The model only decides when it shows; the pane draws it.
extension AppWorkspaceModel {
    /// Polls once a second while a style is chosen; Off cancels the timer and clears a showing screensaver.
    func syncScreensaverTimer() {
        guard appearance.idleScreensaver != .off else {
            screensaverTask?.cancel(); screensaverTask = nil; dismissScreensaver()
            return
        }
        guard screensaverTask == nil else { return }
        screensaverClock = IdleScreensaverClock(now: activityNow())
        screensaverTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let sleep = self?.activitySleep else { return }
                await sleep(1)
                guard !Task.isCancelled else { return }
                self?.tickScreensaver()
            }
        }
    }

    /// Starts the screensaver once the watched pane has been idle long enough, and takes it away when that pane stops
    /// being the one in view.
    func tickScreensaver() {
        let now = activityNow(), pane = screensaverEligiblePane
        screensaverClock.watch(pane, at: now)
        if let showing = screensaverPaneID {
            if showing != pane { screensaverPaneID = nil }
            return
        }
        guard appearance.idleScreensaver != .off, let pane,
            screensaverClock.isIdle(at: now, delay: TimeInterval(appearance.idleScreensaverDelaySeconds))
        else { return }
        screensaverPaneID = pane
    }

    /// The focused pane of the active tab, while the window shows and nothing modal sits over the workspace.
    var screensaverEligiblePane: UUID? {
        guard !isLocked, workspaceIsVisible(), !welcomeTourVisible, !commandPaletteVisible, editingTabID == nil, !isRestoring, recoveryMessage == nil,
            let id = presentation.activePane?.id, terminals[id] != nil
        else { return nil }
        return id
    }

    /// Any key, click or scroll anywhere in the app (FR-SS03): restarts the countdown and dismisses a showing screensaver.
    public func noteUserActivity() {
        screensaverClock.noteActivity(at: activityNow())
        dismissScreensaver()
    }

    /// A key, click or scroll seen by the app's event monitor (FR-SS03). True when it is a key press in the workspace window
    /// that wakes a showing screensaver: the caller drops it, so it never reaches the pane (shortcuts included).
    public func noteUserEvent(keyInWorkspaceWindow: Bool) -> Bool {
        let showing = screensaverPaneID != nil
        noteUserActivity()
        return showing && keyInWorkspaceWindow
    }

    /// Input or output in a pane counts only for the pane being watched; output elsewhere never dismisses it.
    func notePaneActivity(_ paneID: UUID) {
        guard paneID == screensaverClock.paneID else { return }
        screensaverClock.noteActivity(at: activityNow())
        dismissScreensaver()
    }

    public func dismissScreensaver() { if screensaverPaneID != nil { screensaverPaneID = nil } }
}
