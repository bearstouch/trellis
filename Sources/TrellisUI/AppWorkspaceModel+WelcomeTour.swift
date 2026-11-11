import AppKit
import Foundation
import TrellisCore
import TrellisTerminal

public enum WelcomeTourStep: Int, CaseIterable, Sendable {
    case welcome, workspace, sessions, projects, remote, agents, keyboard, setup
    public var title: String {
        switch self {
        case .welcome: L("Welcome to Trellis")
        case .workspace: L("Spaces, tabs and splits")
        case .sessions: L("Sessions keep running")
        case .projects: L("Start a project in one step")
        case .remote: L("Remote work that holds on")
        case .agents: L("Coding agents, built in")
        case .keyboard: L("Everything, from the keyboard")
        case .setup: L("Make it yours")
        }
    }
    var previous: Self? { Self(rawValue: rawValue - 1) }
    var next: Self? { Self(rawValue: rawValue + 1) }
    /// "1 of 8", as the dialog shows it.
    var counter: String { L("%1$d of %2$d", rawValue + 1, Self.allCases.count) }
}

/// The MAC-15 offer as the tour's last step shows it (FR-ON07).
public enum WelcomeTourCLIStatus: Sendable { case unavailable, available, installed }

public enum WelcomeTourKey: Sendable, Equatable {
    case close, confirm, previous, next
    /// Modified keys stay menu shortcuts, and arrows on a focused control stay with that control (FR-ON05).
    static func from(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, controlFocused: Bool) -> Self? {
        guard modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        switch keyCode {
        case 53: return .close
        case 36, 76: return .confirm
        case 123: return controlFocused ? nil : .previous
        case 124: return controlFocused ? nil : .next
        default: return nil
        }
    }
}

/// The welcome tour (FR-ON01–FR-ON10): modal like the command palette. It owns no settings of its own; the last step
/// changes the same ones the Settings window does.
extension AppWorkspaceModel {
    static let welcomeTourSeenKey = "welcomeTour.seen"

    public var welcomeTourVisible: Bool { welcomeTourStep != nil }
    public var canOpenWelcomeTour: Bool { !isRestoring && recoveryMessage == nil && !shuttingDown }
    /// Whether a pane must ignore typing right now, whichever overlay asks.
    var terminalInputBlocked: Bool { editingTabID != nil || commandPaletteVisible || welcomeTourVisible }

    /// FR-ON01: the launch's one decision. Recorded even when it says no, so an upgrade that later loses its workspace
    /// doesn't look like a fresh install, and recorded before showing, so quitting midway doesn't bring it back.
    @discardableResult public func offerWelcomeTour(workspaceExisted: Bool) -> Bool {
        guard canOpenWelcomeTour else { return false }
        let seen = preferences.bool(forKey: Self.welcomeTourSeenKey)
        preferences.set(true, forKey: Self.welcomeTourSeenKey)
        guard !seen, !workspaceExisted else { return false }
        openWelcomeTour()
        return welcomeTourVisible
    }

    public func openWelcomeTour() {
        guard canOpenWelcomeTour, !welcomeTourVisible else { return }
        closeCommandPalette()
        NativeTerminalFont.registerBundledFonts()
        welcomeTourReachedSetup = false
        welcomeTourStep = .welcome
        refreshWelcomeTourCLIStatus()
        terminals.values.forEach { $0.inputSuspended = true }
        // Keys are read by the dialog's monitor; this only stops a pane looking focused behind it.
        _ = (activeTerminal?.view.window ?? NSApp.keyWindow)?.makeFirstResponder(nil)
    }

    /// Esc, Skip Tour or Start Using Trellis. The launch's callback runs once; replays have none.
    public func closeWelcomeTour() {
        guard welcomeTourVisible else { return }
        welcomeTourStep = nil
        terminals.values.forEach { $0.inputSuspended = terminalInputBlocked }
        if editingTabID != nil { tabRenameFocusRequest &+= 1 } else { focusActiveTerminal() }
        let closed = onWelcomeTourClosed
        onWelcomeTourClosed = nil
        onWelcomeTourReachedSetup = nil
        closed?(welcomeTourReachedSetup)
    }

    public func goToWelcomeTourStep(_ step: WelcomeTourStep) {
        guard welcomeTourVisible else { return }
        welcomeTourStep = step
        guard step == .setup else { return }
        refreshWelcomeTourCLIStatus()
        if !welcomeTourReachedSetup { welcomeTourReachedSetup = true; onWelcomeTourReachedSetup?() }
    }

    public func advanceWelcomeTour() {
        guard let step = welcomeTourStep else { return }
        if let next = step.next { goToWelcomeTourStep(next) } else { closeWelcomeTour() }
    }

    public func retreatWelcomeTour() {
        if let previous = welcomeTourStep?.previous { goToWelcomeTourStep(previous) }
    }

    func handleWelcomeTourKey(_ key: WelcomeTourKey) {
        switch key {
        case .close: closeWelcomeTour()
        case .confirm: advanceWelcomeTour()
        case .previous: retreatWelcomeTour()
        // The last step's Next closes the tour, which an arrow key must not do by accident.
        case .next: if welcomeTourStep?.next != nil { advanceWelcomeTour() }
        }
    }

    /// The dialog's key monitor. False leaves the event alone, as during the fade-out after closing, when panes take input again.
    func handleWelcomeTourKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, firstResponder: NSResponder?) -> Bool {
        guard welcomeTourVisible, let key = WelcomeTourKey.from(keyCode: keyCode, modifiers: modifiers, controlFocused: firstResponder is NSControl) else { return false }
        handleWelcomeTourKey(key)
        return true
    }

    /// The dialog has no text of its own, so a text view or pane holding focus is behind it (FR-ON04). A pane answers ⌘V and
    /// ⌘F itself, ahead of the disabled menu, and the scratchpad editor takes typing, which only panes suspend.
    func welcomeTourMustTakeFocus(from responder: NSResponder?) -> Bool {
        responder is NSText || terminals.values.contains { $0.view === responder }
    }

    public func setChromeModeFromWelcomeTour(_ mode: ChromeMode) {
        guard mode != appearance.chromeMode else { return }
        var settings = appearance
        settings.chromeMode = mode
        _ = applyAppearance(settings)
    }

    public func installCLIFromWelcomeTour() {
        guard let install = welcomeTourInstallCLI, !welcomeTourCLIInstalling else { return }
        welcomeTourCLIInstalling = true
        Task {
            await install()
            welcomeTourCLIInstalling = false
            refreshWelcomeTourCLIStatus()
        }
    }

    private func refreshWelcomeTourCLIStatus() { welcomeTourCLIStatus = welcomeTourCLIProbe?() ?? .unavailable }

    /// FR-ON08: the bound chord, which a replay may find rebound or unbound.
    func welcomeTourChord(_ action: ShortcutAction) -> String? { keyboard.shortcuts[action]?.description }

    /// The keyboard step's Files row names the other dock views' chords, or the dock itself when any of them is unbound.
    var welcomeTourSidebarDetail: String {
        let chords = [SidebarView.scratchpad, .tasks, .agents].compactMap { welcomeTourChord($0.shortcut) }
        guard chords.count == 3 else { return L("Browse the focused pane’s project in the right sidebar. The dock on the window’s edge also opens the scratchpad, tasks and agents.") }
        return L("Browse the focused pane’s project in the right sidebar. %1$@, %2$@ and %3$@ open the scratchpad, tasks and agents.", chords[0], chords[1], chords[2])
    }
}
