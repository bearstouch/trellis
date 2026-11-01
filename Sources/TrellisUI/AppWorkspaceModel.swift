import AppKit
import Combine
import TrellisBroker
import TrellisCore
import TrellisTerminal

public enum TabRenameAction: Sendable { case commit, cancel }

/// What ⌘Q does with sessions the broker holds (FR-R03).
public enum QuitChoice: Sendable, Equatable { case keepRunning, stopSessions, cancel }

/// What closing the native window does (MAC-04): hide it while sessions keep running, or end them first.
public enum WindowCloseAction: Sendable, Equatable { case hide, endSessions }

public struct WindowActivity: Equatable, Sendable {
    public var hasOutput = false
    public var hasExit = false
    public init() {}
}

/// One tab in the collapsed rail's hover card (FR-W06): live status, never persisted.
public struct WindowTabPreview: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let color: TabColor?
    public let isActive: Bool
    public let paneCount: Int
    public let isBusy: Bool
    public let inputWait: InputWaitReason?
    public let progress: TerminalProgress?
    public let failedCommandExit: Int32?
    public let hasExitedSession: Bool
    /// FR-AG09/FR-AG10: the tab's running agent, its icon's folder, and its most urgent state.
    public var agent: AgentDefinition? = nil
    public var agentIconDirectory: URL? = nil
    public var agentState: AgentState? = nil
    /// The agent whose state `agentState` is, which can differ from the icon's with several agents in a tab.
    public var agentStateName: String? = nil
}

@MainActor
public final class AppWorkspaceModel: ObservableObject {
    @Published public private(set) var snapshot = WorkspaceSnapshot()
    @Published public internal(set) var terminals: [UUID: NativeTerminal] = [:]
    @Published public var errorMessage: String? {
        // Diagnostics record only that an error was shown, never its text.
        didSet { if errorMessage != nil { diagnosticCodes = Array((diagnosticCodes + ["UI_ERROR"]).suffix(20)) } }
    }
    public private(set) var diagnosticCodes: [String] = []
    @Published public private(set) var appearance = AppearanceSettings()
    /// Narrow initials rail instead of the full window list; a per-user UI preference, not workspace data.
    @Published public private(set) var sidebarCollapsed = false
    /// Advances once per committed settings change; API `expectedRevision` uses it.
    public private(set) var appearanceRevision: UInt64 = 0
    /// Called once per committed change of settings or effective theme, after reconciliation; previews are not commits.
    public var onAppearanceChanged: (() -> Void)?
    private var committedAppearance = (settings: AppearanceSettings(), themeID: ResolvedTheme.builtIn(.light).id)
    @Published public internal(set) var themeCatalog = ThemeLibrarySnapshot()
    @Published public private(set) var effectiveTheme = ResolvedTheme.builtIn(.light)
    @Published public private(set) var previewedTheme: ThemeDocument?
    @Published public private(set) var themeNotice: String?
    @Published public internal(set) var themeBusy = false
    @Published public private(set) var themeReplacementID: String?
    let themeLibrary: ThemeLibrary?
    private(set) var systemIsDark = false
    public var themesDirectory: URL? { themeLibrary?.directory }
    public var effectiveChromeMode: ChromeMode {
        if let previewedTheme { return previewedTheme.appearance == .light ? .light : .dark }
        return appearance.chromeMode
    }
    public var allThemes: [ResolvedTheme] {
        BundledThemes.all + themeCatalog.documents.values.map { $0.resolved() }.sorted { $0.id < $1.id }
    }
    public func availableThemes(for slot: ThemeAppearance) -> [ResolvedTheme] { allThemes.filter { $0.appearance == slot } }
    public func systemAppearanceDidChange(isDark: Bool) {
        guard systemIsDark != isDark else { return }
        systemIsDark = isDark
        if appearance.chromeMode == .system, previewedTheme == nil { refreshEffectiveTheme() }
    }
    func refreshEffectiveTheme() {
        let slot: ThemeAppearance = appearance.chromeMode.isDark(systemIsDark: systemIsDark) ? .dark : .light
        let id = appearance.themeID(systemIsDark: systemIsDark)
        let committed = BundledThemes.theme(id) ?? themeCatalog.documents[id]?.resolved() ?? .builtIn(slot)
        effectiveTheme = previewedTheme?.resolved() ?? committed
        onChromeModeChanged?(effectiveChromeMode)
        for terminal in terminals.values { terminal.applyPalette(effectiveTheme.terminal) }
        // Every commit path ends here, so intermediate reconciliation writes never emit.
        guard appearance != committedAppearance.settings || committed.id != committedAppearance.themeID else { return }
        if appearance != committedAppearance.settings { appearanceRevision &+= 1 }
        committedAppearance = (appearance, committed.id)
        onAppearanceChanged?()
    }
    func reconcileThemeSelections() {
        guard themeLibrary != nil else { return }
        var notices: [String] = []
        for slot in ThemeAppearance.allCases {
            let id = slot == .light ? appearance.lightThemeID : appearance.darkThemeID
            let builtIn = ResolvedTheme.builtIn(slot)
            if (BundledThemes.theme(id)?.appearance ?? themeCatalog.documents[id]?.appearance) != slot {
                if slot == .light { appearance.lightThemeID = builtIn.id } else { appearance.darkThemeID = builtIn.id }
                notices.append("Theme '\(id)' is unavailable. Using \(builtIn.name).")
            }
        }
        notices += themeCatalog.issues.map { "\($0.filename): \($0.message)" }
        themeNotice = notices.isEmpty ? nil : notices.joined(separator: "\n")
    }
    public func previewThemeInWorkspace(_ document: ThemeDocument) {
        guard !isRestoring, !themeBusy, !shuttingDown else { return }
        previewedTheme = document
        refreshEffectiveTheme()
    }
    public func cancelThemePreview() {
        guard previewedTheme != nil else { return }
        previewedTheme = nil
        refreshEffectiveTheme()
    }
    public func useTheme(_ id: String) {
        guard !isRestoring, !themeBusy, !shuttingDown, let theme = allThemes.first(where: { $0.id == id }) else { return }
        var settings = appearance
        if theme.appearance == .light { settings.lightThemeID = id; settings.chromeMode = .light } else { settings.darkThemeID = id; settings.chromeMode = .dark }
        previewedTheme = nil
        commitThemeChoice(settings)
    }
    public func reloadThemes() async {
        guard let themeLibrary, !themeBusy, !isRestoring, !shuttingDown else { return }
        themeBusy = true
        pendingOperations += 1
        defer { themeBusy = false; pendingOperations -= 1 }
        themeCatalog = await themeLibrary.reload()
        reconcileThemeSelections()
        refreshEffectiveTheme()
        scheduleWorkspaceSave()
    }
    @discardableResult public func saveTheme(_ document: ThemeDocument, replace: Bool = false) async -> Bool {
        guard let themeLibrary, !themeBusy, !isRestoring, !shuttingDown else { return false }
        themeBusy = true
        pendingOperations += 1
        defer { themeBusy = false; pendingOperations -= 1 }
        do {
            themeCatalog = try await themeLibrary.install(document.encoded(), replace: replace)
            themeReplacementID = nil
            previewedTheme = nil
            var settings = appearance
            if document.appearance == .light { settings.lightThemeID = document.id; settings.chromeMode = .light } else { settings.darkThemeID = document.id; settings.chromeMode = .dark }
            commitThemeChoice(settings)
            themeNotice = "Saved \(document.name)."
            return true
        } catch {
            if case ThemeLibraryError.duplicateID(let id) = error { themeReplacementID = id }
            themeNotice = error.localizedDescription
            return false
        }
    }
    public func deleteTheme(_ id: String) async {
        guard let themeLibrary, !themeBusy, !isRestoring, !shuttingDown else { return }
        themeBusy = true
        pendingOperations += 1
        defer { themeBusy = false; pendingOperations -= 1 }
        do {
            themeCatalog = try await themeLibrary.delete(id)
            if previewedTheme?.id == id { previewedTheme = nil }
            reconcileThemeSelections()
            refreshEffectiveTheme()
            scheduleWorkspaceSave()
        } catch { themeNotice = error.localizedDescription }
    }
    public func exportTheme(_ id: String, resolved: Bool) async throws -> Data {
        if let theme = BundledThemes.theme(id) { return try theme.encoded() }
        guard let themeLibrary else { throw ThemeLibraryError.notFound }
        return try await themeLibrary.export(id, resolved: resolved)
    }
    public func openThemesFolder() async {
        guard let themeLibrary else { return }
        do {
            let directory = try await themeLibrary.ensureDirectory()
            if !NSWorkspace.shared.open(directory) { themeNotice = "The Themes folder could not be opened." }
        } catch { themeNotice = error.localizedDescription }
    }
    private func commitThemeChoice(_ settings: AppearanceSettings) {
        appearance = settings
        reconcileThemeSelections()
        refreshEffectiveTheme()
        scheduleWorkspaceSave()
    }
    public var onChromeModeChanged: ((ChromeMode) -> Void)?
    /// MCP server settings (FR-RC01); saved with the workspace, applied by the app.
    @Published public private(set) var remoteControl = RemoteControlSettings()
    @Published public var remoteControlStatus: RemoteControlStatus = .stopped
    /// Called after a committed or restored change; the app restarts the server.
    public var onRemoteControlSettingsChanged: ((RemoteControlSettings) -> Void)?
    /// Injected so tests list fixed interfaces.
    public var networkInterfaces: () -> [NetworkInterfaceAddress] = NetworkInterfaceAddress.current

    /// Invalid settings keep the previous ones (and the running server) unchanged.
    @discardableResult
    public func applyRemoteControl(_ settings: RemoteControlSettings) -> Bool {
        guard settings.isValid else { return false }
        remoteControl = settings
        scheduleWorkspaceSave()
        onRemoteControlSettingsChanged?(settings)
        return true
    }
    public var appearanceNotice: String? { NativeTerminalFont.choice(for: appearance.fontName).notice }

    public func applyAppearance(_ settings: AppearanceSettings) -> Bool {
        guard settings.isValid else { return false }
        let previous = appearance
        let terminalSettingsChanged = previous.terminalRenderingDiffers(from: settings)
        appearance = settings
        reconcileThemeSelections()
        if terminalSettingsChanged { for terminal in terminals.values { terminal.applyAppearance(terminalAppearance) } }
        refreshEffectiveTheme()
        scheduleWorkspaceSave()
        return true
    }
    /// The `--renderer` launch choice (true is Metal); overrides the GPU rendering setting without saving it.
    public var rendererOverride: Bool?
    /// Reduce Motion keeps the cursor steady without changing the saved preference.
    var terminalAppearance: AppearanceSettings {
        var settings = appearance
        if reduceMotion { settings.cursorBlinks = false }
        if let rendererOverride { settings.gpuRendering = rendererOverride }
        return settings
    }
    /// How many panes each renderer draws, and the frames they have drawn (FR-TX05).
    public var renderingStats: (metalPanes: Int, coreGraphicsPanes: Int, metalFrames: Int, coreGraphicsFrames: Int) {
        var stats = (metalPanes: 0, coreGraphicsPanes: 0, metalFrames: 0, coreGraphicsFrames: 0)
        for terminal in terminals.values {
            if terminal.isUsingMetalRenderer { stats.metalPanes += 1 } else { stats.coreGraphicsPanes += 1 }
            stats.metalFrames += terminal.renderedFrames.metal
            stats.coreGraphicsFrames += terminal.renderedFrames.coreGraphics
        }
        return stats
    }

    public func accessibilityDisplayOptionsDidChange(increaseContrast: Bool, reduceMotion: Bool) {
        if self.increaseContrast != increaseContrast { self.increaseContrast = increaseContrast }
        guard self.reduceMotion != reduceMotion else { return }
        self.reduceMotion = reduceMotion
        // applyAppearance resets the built-in palette; restore the selected theme colors.
        for terminal in terminals.values {
            terminal.applyAppearance(terminalAppearance)
            terminal.applyPalette(effectiveTheme.terminal)
        }
    }

    private static let keyboardKey = "keyboard.settings"

    private static func loadKeyboardSettings(_ preferences: UserDefaults) -> (KeyboardSettings, String?) {
        guard let data = preferences.data(forKey: keyboardKey) else { return (KeyboardSettings(), nil) }
        guard let saved = try? JSONDecoder().decode(KeyboardSettings.self, from: data) else {
            return (KeyboardSettings(), "Saved keyboard shortcuts could not be read. Using the defaults.")
        }
        // A conflicting stored map could silently disable a command; never apply it.
        guard saved.shortcuts.issues().isEmpty else {
            var fallback = KeyboardSettings()
            fallback.optionAsMeta = saved.optionAsMeta
            return (fallback, "Saved keyboard shortcuts conflict. Using the defaults.")
        }
        return (saved, nil)
    }

    /// Validates the complete map before saving. On any issue the previous
    /// settings stay active and the issues are returned for display.
    @discardableResult
    public func saveKeyboardSettings(_ settings: KeyboardSettings) -> [ShortcutIssue] {
        let issues = settings.shortcuts.issues()
        guard issues.isEmpty else { return issues }
        guard let data = try? JSONEncoder().encode(settings) else { return [] }
        preferences.set(data, forKey: Self.keyboardKey)
        keyboard = settings
        keyboardNotice = nil
        for terminal in terminals.values {
            terminal.optionAsMeta = settings.optionAsMeta
            terminal.searchShortcut = settings.shortcuts[.findInPane]
        }
        onKeyboardSettingsChanged?()
        return []
    }

    public var accessibility: WorkspaceAccessibility {
        WorkspaceAccessibility(
            snapshot: snapshot,
            live: terminals.reduce(into: [:]) { live, entry in
                live[entry.key] = WorkspaceAccessibility.LiveSession(
                    state: entry.value.sessionState, exitCode: entry.value.exitCode, failedCommandExit: failedCommandExit(paneID: entry.key),
                    inputWait: inputWaits[entry.key], progress: progress[entry.key])
            },
            windowsWithOutput: Set(activity.filter(\.value.hasOutput).keys), windowsWithExit: Set(activity.filter(\.value.hasExit).keys),
            windowsNeedingInput: windowsNeedingInput, titles: automaticTitles)
    }

    /// VoiceOver names each terminal by pane and status; its value stays the text.
    func refreshTerminalAccessibility() {
        for pane in accessibility.panes {
            terminals[pane.id]?.view.setAccessibilityLabel("\(pane.label), \(pane.value)")
        }
    }

    public func zoomTerminalFont(by delta: Double, reset: Bool = false) {
        var next = appearance
        next.fontSize = reset ? 13 : min(48, max(8, next.fontSize + delta))
        _ = applyAppearance(next)
    }
    @Published public private(set) var pendingPaste: PendingTerminalPaste?
    private let pasteReview = TerminalPasteReview()
    private var pasteFocusPaneID: UUID?
    private var pasteFocusEpoch: UInt64 = 0
    @Published public private(set) var defaultShell: String
    @Published public private(set) var defaultDirectory: String
    @Published public private(set) var activity: [UUID: WindowActivity] = [:]
    /// Tabs with a pane printing output right now (FR-T05).
    @Published public private(set) var busyTabIDs: Set<UUID> = []
    private var outputActivity = PaneOutputActivity()
    /// Panes whose program waits for the user (FR-T06); runtime-only, never persisted.
    @Published public private(set) var inputWaits: [UUID: InputWaitReason] = [:]
    /// Panes reporting OSC 9;4 progress (FR-T09); runtime-only, never persisted.
    @Published public private(set) var progress: [UUID: TerminalProgress] = [:]
    private var progressTrackers: [UUID: PaneProgressTracker] = [:]
    private var progressExpiryTask: Task<Void, Never>?
    private var busySettleTasks: [UUID: Task<Void, Never>] = [:]
    /// Posts desktop notifications (FR-T08); nil (tests, `swift run`) posts nothing.
    public var desktopNotifier: DesktopNotifier?
    /// Whether the user is looking at the workspace window; the app narrows this to its key window.
    public var workspaceIsFrontmost: () -> Bool = { NSApp.isActive }
    /// Whether the workspace window is on screen at all (not hidden, minimized or covered); for OSC 99 `o=invisible`.
    public var workspaceIsVisible: () -> Bool = { true }
    var notificationLimiter = NotificationRateLimiter()
    /// FR-AG01: the agents this Trellis can launch, bundled and from the Agents folder.
    @Published public internal(set) var agentCatalog = AgentCatalogSnapshot(definitions: AgentCatalog.bundled())
    /// FR-AG10: each agent pane's state, by pane; runtime only, never persisted.
    @Published public internal(set) var agentStates: [UUID: AgentStateReducer] = [:]
    /// FR-AG07: whether each agent is on this Mac's login PATH, by agent ID; only ever from a check.
    @Published public internal(set) var agentAvailability: [String: AgentAvailability] = [:]
    /// FR-AG12: agents a launch found missing on a host, by host.
    @Published public internal(set) var remoteMissingAgents: [UUID: Set<String>] = [:]
    /// FR-AG12: the install offer on screen.
    @Published public var agentInstallOffer: AgentInstallOffer?
    /// The user's Agents folder; nil offers only the bundled agents.
    public var agentsDirectory: URL?
    /// Sessions started without the broker report to the app's own socket, by nonce.
    var agentHookNonces: [String: UUID] = [:]
    var agentHookReceiver: AgentHookReceiver?
    /// Panes whose next start runs the agent's installer first (FR-AG12).
    var agentInstallPanes: Set<UUID> = []
    var agentPathProbe: Task<Void, Never>?
    /// The login shell's PATH from the last check, for agents and their installers' requirements.
    var agentLoginPath: [String]?
    /// When the last PATH check finished; pane headers appearing re-check at most once a minute.
    var agentPathCheckedAt: Date?
    /// Sessions whose launch ran the agent's installer first.
    var agentInstalling: Set<UUID> = []
    /// Each host's OS from its helper (`linux`, `darwin`), for the installer that fits it.
    var remoteHostPlatforms: [UUID: String] = [:]
    var activityNow: () -> Date = Date.init
    var activitySleep: @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    /// Applies to sessions started after a change (FR-SI06).
    @Published public private(set) var shellIntegrationEnabled: Bool
    /// Runtime-only, per pane, from authenticated marks; never persisted or logged.
    @Published public private(set) var shellStates: [UUID: ShellIntegrationState] = [:]
    /// Per session, outliving its shell state so Quit can still save it as the launch directory (FR-SI07).
    /// Keyed by session so a restarted or reconfigured pane never resumes a previous shell's directory.
    private var lastReportedDirectories: [UUID: String] = [:]
    /// Injected by tests; nil disables integration.
    var shellIntegrationDirectory: String? = BundledShellIntegration.directory()
    public var confirmCloseSessions: (Int) -> Bool = { _ in true }
    public var confirmForceSessions: (Int) -> Bool = { _ in false }
    private var closeSummary: [String] = []
    let closureCoordinator = SessionClosureCoordinator()
    var closureInProgress = false
    var closingWindowIDs = Set<UUID>()
    var closingTabIDs = Set<UUID>()
    var closingPaneIDs = Set<UUID>()
    @Published public internal(set) var maximizedPanes: [UUID: UUID] = [:]
    private var pendingDividerResize: (splitID: UUID, ratio: Double, tabID: UUID)?
    private var dividerResizeTask: Task<Void, Never>?
    var canvasSizes: [UUID: CanvasDimensions] = [:]
    @Published public var tabRenameRequest: UUID?
    @Published public var windowRenameRequest: UUID?
    @Published public private(set) var editingTabID: UUID?
    @Published public var tabRenameDraft = ""
    /// Bumped to give the tab name field its focus back (after the command palette closed over it).
    @Published public internal(set) var tabRenameFocusRequest = 0
    @Published public private(set) var keyboard: KeyboardSettings
    @Published public private(set) var keyboardNotice: String?
    public var onKeyboardSettingsChanged: (() -> Void)?
    @Published public private(set) var increaseContrast = false
    @Published public private(set) var reduceMotion = false
    @Published public private(set) var isRestoring: Bool
    @Published public private(set) var recoveryMessage: String?
    @Published public private(set) var backupAvailable = false
    @Published public private(set) var persistenceReadOnly = false
    @Published public internal(set) var unconfiguredPaneIDs = Set<UUID>()
    /// Sessions that received API input: their late write failures never raise an alert.
    var automationInputSessionIDs = Set<UUID>()
    public private(set) var restoredWindowFrame: String?
    public var onRestoreWindowFrame: ((String) -> Void)?
    let persistence: WorkspacePersistence?
    /// Declarative layout key bindings per namespace; loaded on first use.
    var layoutNamespaces: [String: [String: LayoutBinding]]?
    var layoutApplyInFlight = false
    /// Project commands waiting for their new shell's first prompt, by session; never persisted or logged.
    var pendingProjectCommands: [UUID: String] = [:]
    /// The project being launched (FR-PL06, FR-PL07); its sheet shows while set.
    @Published public internal(set) var projectLaunch: ProjectLaunchSession?
    /// Remembers where a project was launched (FR-PL06); set by the app.
    public var onProjectLaunched: ((UUID, ProjectTarget, String) -> Void)?
    /// Each pane's git branch and counts (FR-PL09); runtime only, never persisted.
    @Published public internal(set) var gitStatuses: [UUID: BrokerGitStatus] = [:]
    var gitStatusInFlight: Set<UUID> = []
    var gitStatusAgain: Set<UUID> = []
    /// Turned on by the app; off by default so tests that don't look at it run no git behind them.
    public var gitStatusEnabled = false
    /// Runs `git status` in a local folder; injected by tests.
    public var gitStatusRunner: @Sendable (String) -> BrokerGitStatus? = { BrokerGit.status(directory: $0, environment: ProcessInfo.processInfo.environment) }
    /// The library's projects for the command palette (FR-PL08); set by the app.
    public var commandPaletteProjects: () -> [ProjectDefinition] = { [] }
    /// The task each pane was last asked to run (FR-TK07); runtime only, never persisted or logged.
    @Published public internal(set) var taskRuns: [UUID: TaskRun] = [:]
    /// The Tasks menu's project, read when the menu opens (FR-TK02); nil when the active pane has none.
    @Published public internal(set) var taskCatalog: TaskCatalog?
    @Published public internal(set) var pendingTaskReview: TaskReview?
    var taskCatalogGeneration: UInt64 = 0
    var launchTrust: ProjectTrustList?
    /// How long after Stop the button offers Force Stop (FR-TK08).
    var taskStopEscalation: TimeInterval = 2
    /// The command scratchpad (FR-SP01–FR-SP10): runtime only, never persisted or logged. Run and Save write the
    /// buffer to a file; nothing else does.
    @Published public internal(set) var scratchpadVisible = false
    /// Published apart from the model, so typing re-renders only the scratchpad panel, not every workspace view.
    public let scratchpadBuffer = ScratchpadBuffer()
    public var scratchpad: ScratchpadDocument {
        get { scratchpadBuffer.document }
        set {
            let old = scratchpadBuffer.document
            scratchpadBuffer.document = newValue
            // A check describes the text it ran on; any edit makes it stale.
            if (newValue.text != old.text || newValue.language != old.language) && scratchpadCheck != nil { scratchpadCheck = nil }
        }
    }
    @Published public internal(set) var scratchpadCheck: ScratchpadCheck?
    @Published public internal(set) var scratchpadChecking = false
    /// Bumped when the editor should take keyboard focus.
    @Published public internal(set) var scratchpadFocusRequest = 0
    /// The buffer as it was last saved or opened, so the header can name its file and Clear knows what would be lost.
    @Published public internal(set) var scratchpadSaved: ScratchpadDocument? { didSet { scratchpadSavedTask = nil } }
    /// The task the saved script was saved as, so saving again offers its name and group (FR-SP06).
    public internal(set) var scratchpadSavedTask: LaunchTask?
    /// The focused pane's project's saved scratchpads (FR-SP10); nil when it has no project.
    @Published public internal(set) var scratchpadFiles: ScratchpadFileList?
    /// The project scripts the scratchpad saved, the only existing ones Save may replace.
    var scratchpadSavedPaths: Set<String> = []
    /// Where Run writes the buffer; the state directory's `scratch` folder unless a test injects one.
    var scratchpadDirectory: URL?
    /// Runs the syntax check; injected by tests.
    public var scratchpadProcessRunner: ScratchpadProcessRunner = ScratchpadValidator.runProcess
    /// Opens launch.json in the user's editor; injected by tests.
    public var openLaunchFile: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The command palette (FR-CP01–FR-CP08): runtime only; the query is never persisted or logged.
    @Published public internal(set) var commandPaletteVisible = false
    @Published public internal(set) var commandPaletteQuery = ""
    @Published public internal(set) var commandPaletteScope: CommandPaletteScope?
    @Published public internal(set) var commandPaletteSelection: String?
    /// Bumped when the palette's field should take keyboard focus.
    @Published public internal(set) var commandPaletteFocusRequest = 0
    var commandPaletteRecents = CommandPaletteRecents()
    var commandPaletteSearchCache: (key: CommandPaletteSearchKey, sections: [CommandPaletteSection])?
    /// The actions their menus enabled when the palette opened, read before its field took focus (FR-CP03).
    var commandPaletteActions: [ShortcutAction] = []
    /// True only while the palette owns the workspace theme preview (FR-CP08).
    var commandPalettePreviewing = false
    /// What had keyboard focus when the palette opened, other than a terminal or a field editor (FR-CP01).
    weak var commandPaletteReturnFocus: NSView?
    /// Set by the app: runs an action as its menu item does, and says whether that item is enabled.
    public var performShortcutAction: ((ShortcutAction) -> Void)?
    public var canPerformShortcutAction: ((ShortcutAction) -> Bool)?
    /// The saved hosts the palette lists; set by the app to the host library's committed list.
    public var commandPaletteHosts: () -> [SavedHost] = { [] }
    private var recoveryBackup: RestoredWorkspace?
    private var recoveryReason: WorkspacePersistenceError?
    private var pendingSaveTask: Task<Void, Never>?
    private var saveGeneration: UInt64 = 0
    public var openSettings: (() -> Void)?
    public var openHosts: (() -> Void)?
    /// Shows the project library (FR-PL01); set by the app.
    public var openProjects: (() -> Void)?
    /// Metadata events derived from each published snapshot, in order.
    public var onWorkspaceEvents: (([WorkspaceEvent]) -> Void)?
    /// Raw output appended to the journal: session, pane, bytes, next offset.
    public var onSessionOutput: ((UUID, UUID, Data, UInt64) -> Void)?
    /// Bounded raw output for automation readers; memory only.
    public internal(set) var outputJournal = OutputJournal()
    /// Reads the current saved host at spawn time, so reconnects use later edits.
    public var resolveHost: ((UUID) async -> SavedHost?)?
    /// Injected only by tests; connections always use the system OpenSSH client.
    var sshExecutable = "/usr/bin/ssh"
    /// Answers ssh's password prompt for hosts with a saved password (FR-H08); nil keeps every prompt typed.
    public var askpass: AskpassBroker?
    /// Reads a host's Keychain password for one answer, given the connection revision the session started with.
    public var savedPassword: (@Sendable (UUID, UInt64) async -> Data?)?
    private var askpassRegistrations: [UUID: AskpassBroker.Registration] = [:]
    /// Owns every session's PTY (FR-R07), so sessions survive quit and crashes; nil (tests, no helper) keeps every
    /// session a local PTY.
    public var sessionBroker: (any SessionBrokerClient)? {
        didSet { sessionBroker?.observeAgentEvents { [weak self] sessionID, event in self?.receiveAgentEvent(sessionID: sessionID, event: event) } }
    }
    /// FR-R03: on by default; off means quitting and closing the window stop sessions. Saved per state directory.
    @Published public internal(set) var keepSessionsRunning = true
    /// This launch only (`--fixture`, never saved): quitting and closing the window end sessions whatever the setting, so
    /// scripted runs leave nothing behind. Sessions still run in the broker.
    public var endSessionsAtQuitForThisLaunch = false
    /// What quitting and closing the window do for this launch.
    public var keepsSessionsAtQuit: Bool { keepSessionsRunning && !endSessionsAtQuitForThisLaunch }
    /// Remote workspaces (FR-RW01): the helper and the shared link of each saved host; nil disables them.
    public var remoteHosts: RemoteHostsModel? {
        didSet { remoteHosts?.onWorkspaceLinkChanged = { [weak self] host, state in self?.remoteLinkChanged(host, state) } }
    }
    /// Each remote workspace host's link, for the sidebar and pane headers (FR-RW07, FR-RW16).
    @Published public internal(set) var remoteLinks: [UUID: RemoteLinkDisplay] = [:]
    /// Remote sessions closed while their host was unreachable, hung up once it is reachable again.
    var pendingRemoteHangups: [UUID: Set<UUID>] = [:]
    /// Automatic reconnects (FR-RW07); its clock, sleep and randomness are injectable for tests.
    public private(set) lazy var remoteReconnector: RemoteReconnector = {
        let reconnector = RemoteReconnector()
        reconnector.model = self
        return reconnector
    }()
    /// Unclaimed remote sessions already offered Stop Them / Leave Running in this run.
    var remoteOrphansAsked: Set<UUID> = []
    /// Hosts whose panes are being re-attached now.
    var remoteReconnecting: Set<UUID> = []
    /// The saved setting predates the new default; Settings explains the change once.
    @Published public internal(set) var sessionDefaultNoticePending = false
    /// FR-R04, saved per state directory.
    @Published public internal(set) var restoreScrollback = false
    /// FR-R06, saved per state directory. True while the hour's budget is spent and saves are batched.
    @Published public private(set) var saveBudgetMegabytesPerHour = WorkspaceWriteBudget.defaultMegabytesPerHour
    @Published public private(set) var savesThrottled = false
    var writeBudget = WorkspaceWriteBudget()
    private var pendingSaveBatched = false
    /// Injected so tests run the save delays instantly; cancellation must throw.
    var saveSleep: @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    let scrollbackStore: ScrollbackStore?
    /// Asked on ⌘Q with broker sessions running: kept count, then sessions that will stop.
    public var confirmKeepRunning: (Int, Int) -> QuitChoice = { _, _ in .cancel }
    /// Asked at launch for running sessions no restored pane claims (0: an incompatible broker); true stops them.
    public var confirmStopOrphans: (Int) -> Bool = { _ in false }
    let service: WorkspaceCommandService
    private var updates: Task<Void, Never>?
    let preferences: UserDefaults
    var shuttingDown = false
    var pendingOperations = 0

    public init(store: WorkspaceStore, preferences: UserDefaults = .standard, persistence: WorkspacePersistence? = nil, themeLibrary: ThemeLibrary? = nil) {
        self.themeLibrary = themeLibrary
        self.persistence = persistence
        scrollbackStore = persistence.map { ScrollbackStore(directory: $0.directory.appendingPathComponent("Scrollback", isDirectory: true)) }
        self.isRestoring = persistence != nil
        service = WorkspaceCommandService(store: store)
        self.preferences = preferences
        defaultShell = preferences.string(forKey: "terminal.shell") ?? LocalLaunchConfiguration.loginShell().executable
        defaultDirectory = preferences.string(forKey: "terminal.directory") ?? FileManager.default.homeDirectoryForCurrentUser.path
        shellIntegrationEnabled = preferences.object(forKey: "terminal.shellIntegration") as? Bool ?? true
        sidebarCollapsed = preferences.bool(forKey: "sidebar.collapsed")
        (keyboard, keyboardNotice) = Self.loadKeyboardSettings(preferences)
        confirmCloseSessions = { [weak self] in self?.showClosureConfirmation(count: $0, force: false) ?? false }
        confirmForceSessions = { [weak self] in self?.showClosureConfirmation(count: $0, force: true) ?? false }
        confirmKeepRunning = { [weak self] in self?.showKeepRunningConfirmation(kept: $0, stopping: $1) ?? .cancel }
        confirmStopOrphans = { [weak self] in self?.showOrphanConfirmation(count: $0) ?? false }
    }

    /// Returns true for an existing document or recovery state, even if empty.
    public func loadWorkspace() async -> Bool {
        if let themeLibrary {
            themeCatalog = await themeLibrary.reload()
            reconcileThemeSelections()
            refreshEffectiveTheme()
        }
        guard let persistence else { return false }
        removeScratchpadRunFiles()
        isRestoring = true
        pendingOperations += 1
        defer { isRestoring = false; pendingOperations -= 1 }
        let result = await persistence.load()
        // Restoring never starts a process. Finish it even if startup was
        // cancelled by Quit, so shutdown cannot replace saved state with an
        // uninitialized empty snapshot.
        switch result {
        case .missing:
            _ = await reattachBrokerSessions()
            return false
        case .loaded(let restored):
            do { try await applyRestored(restored) } catch {
                recoveryMessage = "The saved workspace could not be restored."
                _ = await reattachBrokerSessions()
                return true
            }
            // A kept session's broker replay replaces its saved text, so adopt first.
            let replayed = await reattachBrokerSessions()
            await restoreScrollbackText(skipping: replayed)
            // Remote hosts can be slow or need a password; their panes re-attach as each answers (FR-RW09).
            Task { await reattachRemoteSessions() }
            return true
        case .recovery(let reason, let backup):
            recoveryReason = reason; recoveryBackup = backup; backupAvailable = backup != nil
            if case .unsupportedVersion = reason {
                recoveryMessage = "This workspace was saved by a newer application version. It will remain unchanged. Recovery opens a temporary workspace."
            } else {
                recoveryMessage = "The saved workspace could not be read. Recover the backup or start empty; the original file will be preserved."
            }
            // No pane can claim a kept session here; the orphan alert still reports them, and Leave Running is safe.
            _ = await reattachBrokerSessions()
            return true
        }
    }

    private func applyRestored(_ restored: RestoredWorkspace) async throws {
        try await service.store.restoreStoppedSnapshot(restored.snapshot)
        defaultShell = restored.settings.shell; defaultDirectory = restored.settings.directory
        appearance = restored.settings.appearance
        remoteControl = restored.settings.remoteControl
        keepSessionsRunning = restored.settings.keepSessionsRunning
        sessionDefaultNoticePending = restored.settings.sessionDefaultNoticePending
        restoreScrollback = restored.settings.restoreScrollback
        saveBudgetMegabytesPerHour = restored.settings.saveBudgetMegabytesPerHour
        writeBudget.megabytesPerHour = saveBudgetMegabytesPerHour
        onRemoteControlSettingsChanged?(remoteControl)
        reconcileThemeSelections()
        refreshEffectiveTheme()
        restoredWindowFrame = restored.settings.windowFrame
        if !persistenceReadOnly {
            if let frame = restoredWindowFrame { preferences.set(frame, forKey: "app.windowFrame") }

            preferences.set(defaultShell, forKey: "terminal.shell")
            preferences.set(defaultDirectory, forKey: "terminal.directory")
        }
        if let frame = restoredWindowFrame { onRestoreWindowFrame?(frame) }
        for pane in restored.snapshot.panes.values { attachTerminal(pane) }
        unconfiguredPaneIDs = restored.unconfiguredPaneIDs
        publish(restored.snapshot)
    }

    public func recoverWorkspace(useBackup: Bool) async {
        guard let persistence, recoveryMessage != nil, !isRestoring else { return }
        guard !useBackup || recoveryBackup != nil else { return }
        isRestoring = true
        if case .unsupportedVersion = recoveryReason {
            persistenceReadOnly = true
        } else {
            do { try await persistence.authorizeRecovery() } catch { persistenceReadOnly = true }
        }
        do {
            if useBackup, let backup = recoveryBackup { try await applyRestored(backup) }
            recoveryMessage = nil; recoveryBackup = nil; backupAvailable = false
        } catch { errorMessage = "The backup could not be restored." }
        isRestoring = false
        if !persistenceReadOnly, recoveryMessage == nil { _ = await flushWorkspaceSave() }
    }

    public func startRestoredShell(_ paneID: UUID) async {
        guard unconfiguredPaneIDs.contains(paneID), !isClosing(paneID: paneID), !shuttingDown,
            let pane = snapshot.panes[paneID], let session = snapshot.sessions[pane.sessionID]
        else { return }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        let directory: String?
        if case .process(_, _, let path) = session.launch { directory = path } else { directory = nil }
        do {
            let result = try await service.execute(.configureStoppedSession(paneID: paneID, launch: .shell(directory: directory)))
            unconfiguredPaneIDs.remove(paneID)
            publish(result.snapshot)
            if !isClosing(paneID: paneID), !shuttingDown { await start(paneID: paneID) }
        } catch { errorMessage = "A new shell could not be configured." }
    }

    func scheduleWorkspaceSave() {
        guard persistence != nil, !isRestoring, recoveryMessage == nil, !persistenceReadOnly else { return }
        if saveGeneration < UInt64.max { saveGeneration += 1 }
        let generation = saveGeneration
        // Over budget, the scheduled save takes every later change with it instead of restarting its wait (FR-R06).
        let throttled = writeBudget.isExhausted(at: activityNow())
        if savesThrottled != throttled { savesThrottled = throttled }
        if throttled, pendingSaveBatched, pendingSaveTask != nil { return }
        pendingSaveTask?.cancel()
        pendingSaveBatched = throttled
        pendingSaveTask = Task { [weak self] in
            guard let sleep = self?.saveSleep else { return }
            do { try await sleep(throttled ? WorkspaceWriteBudget.throttledInterval : 0.3) } catch { return }
            guard let self, !Task.isCancelled, throttled || generation == saveGeneration else { return }
            pendingSaveTask = nil; pendingSaveBatched = false
            _ = await saveWorkspaceNow()
        }
    }

    /// FR-R06: one of `WorkspaceWriteBudget.choices`; anything else keeps the current budget.
    public func setSaveBudget(megabytesPerHour: Int) {
        guard WorkspaceWriteBudget.choices.contains(megabytesPerHour), megabytesPerHour != saveBudgetMegabytesPerHour else { return }
        saveBudgetMegabytesPerHour = megabytesPerHour
        writeBudget.megabytesPerHour = megabytesPerHour
        // A raised budget ends batching now rather than after the pending batched save.
        if pendingSaveBatched, !writeBudget.isExhausted(at: activityNow()) { pendingSaveTask?.cancel(); pendingSaveTask = nil; pendingSaveBatched = false }
        scheduleWorkspaceSave()
    }

    public func toggleSidebar() {
        sidebarCollapsed.toggle()
        preferences.set(sidebarCollapsed, forKey: "sidebar.collapsed")
    }

    public func updateWindowFrame(_ frame: String) {
        preferences.set(frame, forKey: "app.windowFrame")
        scheduleWorkspaceSave()
    }

    /// A failed shutdown save cancels Quit; allow the remaining workspace to
    /// continue accepting commands while the user resolves the storage error.
    public func cancelShutdown() { shuttingDown = false }

    @discardableResult
    public func flushWorkspaceSave() async -> Bool {
        // Capture the final dragged divider and ordered session callbacks before
        // taking the snapshot used by an explicit Save or shutdown.
        await dividerResizeTask?.value
        await waitForUpdates()
        pendingSaveTask?.cancel(); pendingSaveTask = nil; pendingSaveBatched = false
        return await saveWorkspaceNow()
    }

    private func saveWorkspaceNow() async -> Bool {
        guard let persistence, !isRestoring, recoveryMessage == nil, !persistenceReadOnly else { return true }
        var settings = WorkspaceSettings(
            shell: defaultShell, directory: defaultDirectory,
            windowFrame: preferences.string(forKey: "app.windowFrame"), appearance: appearance, remoteControl: remoteControl,
            keepSessionsRunning: keepSessionsRunning, restoreScrollback: restoreScrollback, saveBudgetMegabytesPerHour: saveBudgetMegabytesPerHour)
        settings.sessionDefaultNoticePending = sessionDefaultNoticePending
        do {
            let written = try await persistence.save(snapshotForSave(), settings: settings, sequence: saveGeneration)
            writeBudget.record(written, at: activityNow())
            let throttled = writeBudget.isExhausted(at: activityNow())
            if savesThrottled != throttled { savesThrottled = throttled }
            return true
        } catch {
            errorMessage = "The workspace could not be saved. Your current terminals are still available."; return false
        }
    }

    public var presentation: WorkspacePresentation { WorkspacePresentation(snapshot: snapshot) }
    public var activeTerminal: NativeTerminal? { presentation.activePane.flatMap { terminals[$0.id] } }
    public var runningTerminals: [NativeTerminal] { terminals.values.filter(\.isRunning) }

    public func refresh() async { publish(await service.store.snapshot()) }

    /// Async command replies can resume out of order; never regress visible state.
    func publish(_ next: WorkspaceSnapshot) {
        guard next.revision >= snapshot.revision else { return }
        let previous = snapshot
        snapshot = next
        // Replaced or closed sessions drop their output; their cursors become invalid.
        for id in previous.sessions.keys where next.sessions[id] == nil { outputJournal.remove(session: id) }
        // A closed pane or window, or a restart, discards the saved text of the session it replaced (FR-R04).
        let removed = previous.sessions.keys.filter { next.sessions[$0] == nil }
        if restoreScrollback, !removed.isEmpty, let scrollbackStore { Task { await scrollbackStore.delete(sessionIDs: removed) } }
        if let onWorkspaceEvents {
            let events = WorkspaceEvents.diff(previous, next)
            if !events.isEmpty { onWorkspaceEvents(events) }
        }
        if let pendingPaste, pendingPaste.target != currentPasteTarget { cancelPaste() }
        maximizedPanes = maximizedPanes.filter { tabID, paneID in next.tabs[tabID]?.root.paneIDs.contains(paneID) == true }
        canvasSizes = canvasSizes.filter { next.tabs[$0.key] != nil }
        if shellStates.keys.contains(where: { next.panes[$0] == nil }) { shellStates = shellStates.filter { next.panes[$0.key] != nil } }
        outputActivity.retain(Set(next.panes.keys))
        notificationLimiter.retain(Set(next.panes.keys))
        if inputWaits.keys.contains(where: { next.panes[$0] == nil }) { inputWaits = inputWaits.filter { next.panes[$0.key] != nil } }
        for id in progressTrackers.keys where next.panes[id] == nil { clearProgress(paneID: id) }
        // Looking at the pane answers a bell; a password prompt stays until echo returns.
        if let viewed = presentation.activePane?.id, inputWaits[viewed] == .attention { inputWaits.removeValue(forKey: viewed) }
        if agentStates.keys.contains(where: { next.panes[$0] == nil }) { agentStates = agentStates.filter { next.panes[$0.key] != nil } }
        markAgentsViewed()
        for id in busyTabIDs where next.tabs[id] == nil { busyTabIDs.remove(id); busySettleTasks.removeValue(forKey: id)?.cancel() }
        lastReportedDirectories = lastReportedDirectories.filter { next.sessions[$0.key] != nil }
        unconfiguredPaneIDs = unconfiguredPaneIDs.filter { next.panes[$0] != nil }
        if let selected = next.activeWindowID { activity.removeValue(forKey: selected) }
        if let editingTabID, next.tabs[editingTabID] == nil || presentation.selectedTab?.id != editingTabID { endTabRenameEditing() }
        refreshTerminalAccessibility()
        scheduleWorkspaceSave()
    }

    @discardableResult
    public func createWindow(name: String? = nil, startSession: Bool = true, fixture: Bool = false) async -> UUID? {
        guard !isRestoring, recoveryMessage == nil, !shuttingDown, !Task.isCancelled else { return nil }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        do {
            let result = try await service.execute(.createWindow(name: name ?? "Window \(snapshot.windows.count + 1)"))
            // Always materialize a committed result, including during a native
            // confirmation loop. Shutdown gates only the process launch.
            guard let id = result.createdWindowID, let window = result.snapshot.windows.first(where: { $0.id == id }),
                let tab = result.snapshot.tabs[window.activeTabID], let pane = result.snapshot.panes[tab.activePaneID]
            else { return nil }
            attachTerminal(pane)
            publish(result.snapshot)
            if startSession { await start(paneID: pane.id, fixture: fixture) }
            return id
        } catch { errorMessage = "The window could not be created."; return nil }
    }

    public func selectWindow(_ id: UUID) async {
        if id != snapshot.activeWindowID { cancelPaste(); notePasteFocus(nil) }
        do {
            publish(try await service.execute(.selectWindow(id: id)).snapshot)
        } catch { errorMessage = "The window could not be selected." }
    }

    /// `quietly` (automation) reports failure through session state, never an alert.
    /// `environment` holds runtime-only overrides (automation); they are never persisted.
    public func start(paneID: UUID, fixture: Bool = false, quietly: Bool = false, environment: [String: String] = [:]) async {
        guard !isRestoring, recoveryMessage == nil, !unconfiguredPaneIDs.contains(paneID),
            !isClosing(paneID: paneID), !shuttingDown, !Task.isCancelled, let terminal = terminals[paneID], terminal.sessionState == .stopped
        else { return }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        do {
            // Freeze the actual local launch configuration before starting. A duplicate
            // must reuse this session's shell and directory even after Settings change.
            let resolvedLaunch: SessionLaunch?
            if let pane = snapshot.panes[paneID], let session = snapshot.sessions[pane.sessionID] {
                switch session.launch {
                case .shell(let directory):
                    resolvedLaunch = .process(executable: defaultShell, arguments: ["-l"], directory: directory ?? defaultDirectory)
                case .process(let executable, let arguments, let directory):
                    resolvedLaunch = .process(executable: executable, arguments: arguments, directory: directory ?? defaultDirectory)
                case .host, .remoteShell, .agent: resolvedLaunch = nil
                }
            } else {
                resolvedLaunch = nil
            }
            let result = try await service.execute(.startSession(paneID: paneID, resolvedLaunch: resolvedLaunch))
            publish(result.snapshot)
            guard case .start(let request) = result.effects.first else { return }
            guard !isClosing(paneID: paneID), !shuttingDown, !Task.isCancelled else {
                // The terminal mirrors the store's Failed, so a cancelled quit or close leaves a restartable pane.
                if terminals[paneID] === terminal { terminal.refuseLaunch(message: "Session launch was cancelled.") }
                publish(
                    try await service.execute(
                        .completeLaunch(
                            sessionID: request.sessionID, attemptID: request.attemptID,
                            outcome: .failed(message: "Session launch was cancelled."))
                    ).snapshot)
                return
            }
            installLifecycle(terminal, paneID: paneID, sessionID: request.sessionID, attemptID: request.attemptID)
            if case .remoteShell(let hostID, let directory) = request.launch {
                await startRemote(paneID: paneID, terminal: terminal, request: request, hostID: hostID, directory: directory)
                return
            }
            if case .agent(let agent) = request.launch {
                await startAgent(agent, paneID: paneID, terminal: terminal, request: request, environment: environment, quietly: quietly)
                return
            }
            if fixture {
                await terminal.startFixture()
            } else {
                var configuration: LocalLaunchConfiguration
                switch request.launch {
                case .shell(let directory):
                    configuration = .loginShell(executable: defaultShell, directory: directory ?? defaultDirectory, environmentOverrides: environment)
                    configuration.shellIntegration = shellIntegration(for: configuration)
                case .process(let executable, let arguments, let directory):
                    configuration = LocalLaunchConfiguration(
                        executable: executable, arguments: arguments, directory: directory ?? defaultDirectory, environmentOverrides: environment)
                    // `.shell` is frozen to `.process(shell, ["-l"])` before launch. Any frozen login shell qualifies, so
                    // panes started before the default shell changed keep integration on restart and restore.
                    if arguments == ["-l"] { configuration.shellIntegration = shellIntegration(for: configuration) }
                case .remoteShell, .agent: return
                case .host(let hostID):
                    // Each spawn freezes the host's current arguments; the domain keeps
                    // `.host(id)` so persistence and explicit reconnects re-read it.
                    let host = await resolveHost?(hostID)
                    guard let host, case .process(_, let arguments, _) = host.connectionLaunch,
                        terminals[paneID] === terminal, !isClosing(paneID: paneID), !shuttingDown, !Task.isCancelled
                    else {
                        let message = host == nil ? "This saved host is no longer available." : "Session launch was cancelled."
                        // The pane must show Failed (with Reconnect), not a startable stopped pane.
                        if terminals[paneID] === terminal {
                            terminal.refuseLaunch(
                                message: host == nil ? "This saved host was deleted or the host library could not be read. Close this pane or connect to another host." : message)
                        }
                        publish(
                            try await service.execute(
                                .completeLaunch(sessionID: request.sessionID, attemptID: request.attemptID, outcome: .failed(message: message))
                            ).snapshot)
                        return
                    }
                    var overrides = environment
                    // argv is untouched: the password reaches ssh only through the one-shot askpass broker.
                    if host.savedPassword != nil, let askpass, let savedPassword {
                        let revision = host.connectionRevision
                        let registration = askpass.register(
                            parent: { [weak terminal] in await MainActor.run { terminal?.processID } },
                            answer: { await savedPassword(hostID, revision) })
                        if let registration {
                            askpassRegistrations[request.sessionID] = registration
                            overrides.merge(registration.environment(helper: askpass.helperPath)) { $1 }
                        }
                    }
                    configuration = LocalLaunchConfiguration(
                        executable: sshExecutable, arguments: arguments, directory: defaultDirectory, environmentOverrides: overrides)
                }
                // FR-R07: whatever the quit setting, so a crash or force quit never ends a session.
                if let sessionBroker {
                    let ready = await sessionBroker.prepare()
                    guard terminals[paneID] === terminal, !isClosing(paneID: paneID), !shuttingDown, !Task.isCancelled else {
                        if let registration = askpassRegistrations.removeValue(forKey: request.sessionID) { askpass?.unregister(registration) }
                        if terminals[paneID] === terminal { terminal.refuseLaunch(message: "Session launch was cancelled.") }
                        publish(
                            try await service.execute(
                                .completeLaunch(sessionID: request.sessionID, attemptID: request.attemptID, outcome: .failed(message: "Session launch was cancelled."))
                            ).snapshot)
                        return
                    }
                    if ready, let transport = sessionBroker.makeTransport(sessionID: request.sessionID) {
                        terminal.useTransport(transport)
                    } else if !quietly {
                        errorMessage = "The session broker could not start, so this session will end when Trellis quits."
                    }
                }
                if shellIntegrationEnabled, Self.isRemote(request.launch) { terminal.observeRemoteShellMarks() }
                await terminal.start(configuration: configuration)
                // A launch refused before spawning never reports an exit, so drop its nonce here.
                if terminal.processID == nil, let registration = askpassRegistrations.removeValue(forKey: request.sessionID) { askpass?.unregister(registration) }
            }
        } catch { if !quietly { errorMessage = "The terminal session could not be started." } }
    }

    /// Feeds a session's state changes and exit back to the store. `attemptID` is nil for a session
    /// adopted from the broker, which is already running (FR-R03).
    func installLifecycle(_ terminal: NativeTerminal, paneID: UUID, sessionID: UUID, attemptID: UUID?) {
        terminal.onInputError = { [weak self, weak terminal] _ in
            guard let self, !self.automationInputSessionIDs.contains(sessionID) else { return }
            if let remote = terminal?.remoteTransport, remote.linkLost {
                // Never queued, so nothing is typed later by surprise (FR-RW07).
                self.errorMessage = "Not sent: reconnecting to \(self.remoteHostName(remote.hostID)). Nothing you type is kept for later."
                return
            }
            self.errorMessage = "Terminal input could not be sent. Check the session or try a smaller paste."
        }
        var launchCompleted = attemptID == nil
        terminal.onStateChanged = { [weak self, weak terminal] state in
            if state != .running, self?.pendingPaste?.target.paneID == paneID { self?.cancelPaste() }
            if !launchCompleted, let attemptID, state == .running || state == .closing, let pid = terminal?.processID {
                launchCompleted = true
                self?.enqueue(.completeLaunch(sessionID: sessionID, attemptID: attemptID, outcome: .started(processID: pid)))
            }
            if launchCompleted, state == .closing { self?.enqueue(.markSessionClosing(sessionID: sessionID)) }
        }
        terminal.onExit = { [weak self, weak terminal] code in
            guard let self, let terminal else { return }
            let command: WorkspaceCommand =
                !launchCompleted
                ? .completeLaunch(
                    sessionID: sessionID, attemptID: attemptID ?? UUID(),
                    outcome: .failed(
                        message: terminal.sessionState == .failed
                            ? "The executable, directory, or environment could not be used." : "Session launch was cancelled."))
                : .recordSessionExit(sessionID: sessionID, code: code)
            self.closureCoordinator.forget(sessionID: sessionID)
            self.pendingProjectCommands.removeValue(forKey: sessionID)
            if let registration = self.askpassRegistrations.removeValue(forKey: sessionID) { self.askpass?.unregister(registration) }
            self.agentSessionEnded(paneID: paneID, sessionID: sessionID, code: code, current: self.terminals[paneID] === terminal)
            if self.terminals[paneID] === terminal {
                self.shellStates.removeValue(forKey: paneID); self.inputWaits.removeValue(forKey: paneID); self.settleOutput(paneID: paneID)
                self.taskRuns.removeValue(forKey: paneID)
                self.clearProgress(paneID: paneID)
            }
            self.recordActivity(paneID: paneID, exited: true)
            self.enqueue(command)
        }
    }

    /// The default login shell with bundled scripts only; other processes, SSH and fixtures never reach this (FR-SI01).
    private func shellIntegration(for configuration: LocalLaunchConfiguration) -> ShellIntegrationInjection? {
        guard shellIntegrationEnabled, let directory = shellIntegrationDirectory, let kind = ShellIntegrationKind(executable: configuration.executable) else {
            return nil
        }
        // Plan against the final environment so a pane's own ZDOTDIR/XDG_DATA_DIRS override is the one restored.
        return .plan(
            kind: kind, arguments: configuration.arguments,
            inheritedEnvironment: configuration.inheritedEnvironment.merging(configuration.environmentOverrides) { $1 },
            resourceDirectory: directory, nonce: ShellIntegrationInjection.makeNonce())
    }

    public func setShellIntegrationEnabled(_ enabled: Bool) {
        guard enabled != shellIntegrationEnabled else { return }
        shellIntegrationEnabled = enabled
        preferences.set(enabled, forKey: "terminal.shellIntegration")
    }

    /// The local shell's authenticated directory; nil without integration (INT-01) and for remote marks (FR-SI09),
    /// so file links, new splits and tabs, saved launches and `session.get` never use a remote path.
    public func currentDirectory(paneID: UUID) -> String? {
        guard let state = shellStates[paneID], state.origin == .authenticated, !isRemoteWorkspace(paneID: paneID) else { return nil }
        return state.currentDirectory
    }

    /// An SSH pane's unverified reported location for display only (FR-SI09): `host:/path`, or the path alone.
    public func remoteDirectory(paneID: UUID) -> String? {
        guard let state = shellStates[paneID], state.origin == .remote, let directory = state.currentDirectory else { return nil }
        return state.remoteHost.map { "\($0):\(directory)" } ?? directory
    }

    /// A saved SSH host, or a pane started straight into `ssh`, `mosh` or `autossh`: its paths name remote files.
    public static func isRemote(_ launch: SessionLaunch) -> Bool {
        switch launch {
        case .host, .remoteShell: true
        case .agent(let agent): agent.hostID != nil
        case .process(let executable, _, _): ["ssh", "mosh", "autossh"].contains((executable as NSString).lastPathComponent)
        case .shell: false
        }
    }

    /// File links resolve only in local panes, read at click time so a restart is seen (FR-L04).
    func fileLinkContext(paneID: UUID) -> FileLinkContext? {
        guard let pane = snapshot.panes[paneID], let launch = snapshot.sessions[pane.sessionID]?.launch, !Self.isRemote(launch) else { return nil }
        return FileLinkContext(currentDirectory: currentDirectory(paneID: paneID), homeDirectory: NSHomeDirectory())
    }

    /// A renamed tab keeps its title; the default title follows the active pane (FR-SI05).
    public func displayTitle(_ tab: WorkspaceTab) -> String {
        guard tab.title == WorkspaceTab.defaultTitle else { return tab.title }
        return automaticTitle(paneID: tab.activePaneID) ?? tab.title
    }

    /// Non-zero exit of the pane's last finished command (FR-SI04).
    public func failedCommandExit(paneID: UUID) -> Int32? {
        guard let state = shellStates[paneID], state.lastCommandFailed else { return nil }
        return state.lastExitCode
    }

    /// The strongest wait among a tab's panes: a password prompt outranks a bell (FR-T06).
    public func inputWait(tabID: UUID) -> InputWaitReason? {
        let waits = snapshot.tabs[tabID]?.root.paneIDs.compactMap { inputWaits[$0] } ?? []
        return waits.contains(.password) ? .password : waits.first
    }

    /// The most urgent progress among a tab's panes (FR-T09).
    public func progress(tabID: UUID) -> TerminalProgress? {
        TerminalProgress.aggregate(snapshot.tabs[tabID]?.root.paneIDs.compactMap { progress[$0] } ?? [])
    }

    public var windowsNeedingInput: Set<UUID> {
        Set(inputWaits.keys.compactMap { snapshot.panes[$0].flatMap { snapshot.tabs[$0.tabID]?.windowID } })
    }

    /// A window's tabs in order with their live status, for the rail's hover card (FR-W06). Unknown window → empty.
    public func tabPreviews(windowID: UUID) -> [WindowTabPreview] {
        guard let window = snapshot.windows.first(where: { $0.id == windowID }) else { return [] }
        return window.tabIDs.compactMap { snapshot.tabs[$0] }.map { tab in
            let panes = tab.root.paneIDs
            return WindowTabPreview(
                id: tab.id, title: displayTitle(tab), color: tab.color, isActive: tab.id == window.activeTabID, paneCount: panes.count,
                isBusy: busyTabIDs.contains(tab.id), inputWait: inputWait(tabID: tab.id), progress: progress(tabID: tab.id),
                failedCommandExit: panes.lazy.compactMap(failedCommandExit(paneID:)).first,
                hasExitedSession: panes.contains { [.exited, .failed].contains(terminals[$0]?.sessionState) },
                agent: tabAgent(tabID: tab.id), agentIconDirectory: tabAgent(tabID: tab.id).flatMap { agentCatalog.iconDirectories[$0.id] },
                agentState: agentBadge(tabID: tab.id)?.state, agentStateName: agentBadge(tabID: tab.id)?.agent.name)
        }
    }

    /// Selecting a tab only sets its window's active tab, so jumping from another window selects both.
    public func selectWindowTab(windowID: UUID, tabID: UUID) async {
        guard snapshot.tabs[tabID]?.windowID == windowID else { return }
        await selectWindow(windowID)
        await selectTab(tabID)
    }

    /// At the shell prompt (known through integration) nothing is waiting on a program: a completion bell or the
    /// user's own `stty -echo` must not label the tab.
    private func atShellPrompt(_ paneID: UUID) -> Bool { shellStates[paneID]?.commandRunning == false }

    private func setPasswordPrompt(_ active: Bool, paneID: UUID) {
        if active, !atShellPrompt(paneID) {
            applyAgentSignal(.attention, paneID: paneID)
            if inputWaits[paneID] != .password { inputWaits[paneID] = .password }
        } else if inputWaits[paneID] == .password {
            inputWaits.removeValue(forKey: paneID)
        }
        refreshTerminalAccessibility()
    }

    private func requestAttention(paneID: UUID) {
        applyAgentSignal(.attention, paneID: paneID)
        guard inputWaits[paneID] == nil, presentation.activePane?.id != paneID, !atShellPrompt(paneID) else { return }
        inputWaits[paneID] = .attention
        refreshTerminalAccessibility()
    }

    /// FR-T08: shown only while the user isn't looking at the pane (or as OSC 99 `o=` asks), never at the shell's own prompt.
    private func postNotification(_ notification: TerminalNotification, paneID: UUID) {
        applyAgentSignal(.attention, paneID: paneID)
        guard appearance.desktopNotifications, let desktopNotifier, !atShellPrompt(paneID), let pane = snapshot.panes[paneID] else { return }
        let frontmost = workspaceIsFrontmost()
        switch notification.occasion {
        case .always: break
        case .unfocused: guard !frontmost || presentation.activePane?.id != paneID else { return }
        case .invisible:
            // kitty: unfocused and not visible. A shown pane counts as visible even while another app is key.
            let shown = presentation.selectedTab?.id == pane.tabID && (maximizedPanes[pane.tabID] ?? paneID) == paneID
            guard !shown || !workspaceIsVisible() else { return }
        }
        guard notificationLimiter.allow(paneID, at: activityNow()) else { return }
        let title = notification.title.isEmpty ? paneTitle(paneID) : notification.title
        desktopNotifier.post(DesktopNotification(paneID: paneID, title: title, body: notification.body))
    }

    /// FR-SI08: a long command finished while the user wasn't looking at its pane. Unlike `postNotification` this runs
    /// at the prompt by design, and it never labels the tab. The body names the program only, never the command line.
    private func postCommandFinished(_ state: ShellIntegrationState, paneID: UUID) {
        let threshold = appearance.commandFinishedNotificationSeconds
        guard appearance.desktopNotifications, threshold > 0, let desktopNotifier, snapshot.panes[paneID] != nil,
            let duration = state.lastDuration, duration >= TimeInterval(threshold), let durationText = state.durationText
        else { return }
        guard !workspaceIsFrontmost() || presentation.activePane?.id != paneID else { return }
        guard notificationLimiter.allow(paneID, at: activityNow()) else { return }
        let title = state.lastCommandFailed ? "Command failed (exit \(state.lastExitCode ?? 0))" : "Command finished"
        // The program name is untrusted output, so it gets the same cleaning as OSC notification text.
        guard let text = TerminalNotification(title: title, body: "\(state.lastCommandName ?? paneTitle(paneID)) ran for \(durationText)") else { return }
        desktopNotifier.post(DesktopNotification(paneID: paneID, title: text.title, body: text.body))
    }

    /// Progress never labels the tab as waiting (FR-T09); it only refreshes the bar, text and spoken status.
    private func applyProgress(_ report: TerminalProgressReport, paneID: UUID) {
        var tracker = progressTrackers[paneID] ?? PaneProgressTracker()
        let next = tracker.apply(report, at: activityNow())
        progressTrackers[paneID] = next == nil ? nil : tracker
        if progress[paneID] != next { progress[paneID] = next; refreshTerminalAccessibility() }
        applyAgentSignal(.progress(active: next != nil), paneID: paneID)
        scheduleProgressExpiry()
    }

    private func clearProgress(paneID: UUID) {
        progressTrackers.removeValue(forKey: paneID)
        if progress.removeValue(forKey: paneID) != nil { refreshTerminalAccessibility() }
    }

    /// One task for every pane: it sleeps until the earliest deadline, so updates never spawn timers.
    private func scheduleProgressExpiry() {
        guard progressExpiryTask == nil, !progressTrackers.isEmpty else { return }
        progressExpiryTask = Task { [weak self] in
            while !Task.isCancelled, let delay = self?.nextProgressExpiry() {
                guard let sleep = self?.activitySleep else { return }
                await sleep(delay)
                self?.expireProgress()
            }
            self?.progressExpiryTask = nil
        }
    }

    private func nextProgressExpiry() -> TimeInterval? {
        progressTrackers.values.compactMap(\.expiresAt).min().map { max(0.05, $0.timeIntervalSince(activityNow())) }
    }

    private func expireProgress() {
        let now = activityNow()
        for (id, tracker) in progressTrackers {
            var tracker = tracker
            if tracker.expire(at: now) { clearProgress(paneID: id) }
        }
    }

    /// Clicking a notification shows its pane, in whichever window and tab it now lives.
    public func revealPane(_ paneID: UUID) async {
        guard let pane = snapshot.panes[paneID], let windowID = snapshot.tabs[pane.tabID]?.windowID else { return }
        await selectWindowTab(windowID: windowID, tabID: pane.tabID)
        _ = await selectPane(paneID)
    }

    private var automaticTitles: [UUID: String] {
        var titles: [UUID: String] = [:]
        for id in shellStates.keys { if let title = automaticTitle(paneID: id) { titles[id] = title } }
        for tab in snapshot.tabs.values where tab.title == WorkspaceTab.defaultTitle { titles[tab.id] = automaticTitle(paneID: tab.activePaneID) }
        return titles
    }

    public func paneTitle(_ id: UUID) -> String {
        snapshot.panes[id]?.title ?? automaticTitle(paneID: id) ?? WorkspaceTab.defaultTitle
    }

    private func automaticTitle(paneID: UUID) -> String? {
        if let title = agentTitle(paneID: paneID) { return title }
        guard let state = shellStates[paneID] else { return nil }
        if let name = state.commandName { return name }
        guard let directory = state.currentDirectory else { return nil }
        // A remote path is never this Mac's home, even when it is spelled the same.
        if state.origin == .authenticated, !isRemoteWorkspace(paneID: paneID), directory == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty ? directory : name
    }

    private func applyShellEvent(_ event: ShellIntegrationEvent, paneID: UUID) {
        // After a cd or a command the work tree may have changed (FR-PL09); looked at once the prompt's directory is applied.
        defer { if case .promptStart = event { refreshGitStatus(paneID: paneID) } }
        switch event {
        case .commandFinished, .promptStart: settleOutput(paneID: paneID)
        case .commandInputStart, .commandStart, .reportedDirectory, .reportedHost: break
        }
        // Back at the prompt, the program that asked (or reported progress) is gone.
        if case .promptStart = event {
            if inputWaits[paneID] != nil { inputWaits.removeValue(forKey: paneID) }
            clearProgress(paneID: paneID)
            // The shell is reading input now, so a project's command can be typed.
            submitProjectCommand(paneID: paneID)
        }
        updateTaskRun(paneID: paneID, event: event)
        var state = shellStates[paneID] ?? ShellIntegrationState(origin: terminals[paneID]?.shellMarkOrigin ?? .authenticated)
        let wasRunning = state.commandRunning
        state.apply(event, at: activityNow())
        guard state != shellStates[paneID] else { return }
        shellStates[paneID] = state
        // Replayed marks (FR-R03) describe commands that finished while Trellis was closed; they never notify.
        if wasRunning, !state.commandRunning, terminals[paneID]?.isReplaying != true { postCommandFinished(state, paneID: paneID) }
        if let directory = currentDirectory(paneID: paneID), let sessionID = terminals[paneID]?.sessionID, lastReportedDirectories[sessionID] != directory {
            lastReportedDirectories[sessionID] = directory; scheduleWorkspaceSave()
        }
        pruneProjectState()
        refreshTerminalAccessibility()
    }

    /// Local shells are saved with their last reported directory so a restart resumes there (FR-SI07).
    /// The store keeps the original launch, so Restart and Duplicate Tab are unchanged.
    private func snapshotForSave() -> WorkspaceSnapshot {
        var saved = snapshot
        let files = SystemLaunchFileAccess()
        for (sessionID, directory) in lastReportedDirectories {
            guard let launch = saved.sessions[sessionID]?.launch else { continue }
            let resumed: SessionLaunch
            switch launch {
            case .shell: resumed = .shell(directory: directory)
            case .process(let executable, let arguments, _) where arguments == ["-l"]: resumed = .process(executable: executable, arguments: arguments, directory: directory)
            default: continue
            }
            guard resumed != launch, files.isAccessibleDirectory(directory) else { continue }
            saved.sessions[sessionID]?.launch = resumed
        }
        return saved
    }

    /// New panes start in the source pane's reported directory when it is still accessible.
    private func inheritDirectory(from sourcePaneID: UUID?, into paneID: UUID) async {
        // A remote workspace pane starts where the source pane's shell is on the host; the helper falls back to home
        // when the directory is gone, so nothing is checked here (FR-RW04).
        if let pane = snapshot.panes[paneID], case .remoteShell(let host, nil)? = snapshot.sessions[pane.sessionID]?.launch {
            guard let directory = sourcePaneID.flatMap(remoteWorkingDirectory(paneID:)),
                let result = try? await service.execute(.configureStoppedSession(paneID: paneID, launch: .remoteShell(hostID: host, directory: directory)))
            else { return }
            publish(result.snapshot)
            return
        }
        guard let directory = sourcePaneID.flatMap(currentDirectory(paneID:)), SystemLaunchFileAccess().isAccessibleDirectory(directory),
            let pane = snapshot.panes[paneID], case .shell(nil)? = snapshot.sessions[pane.sessionID]?.launch
        else { return }
        if let result = try? await service.execute(.configureStoppedSession(paneID: paneID, launch: .shell(directory: directory))) {
            publish(result.snapshot)
        }
    }

    func isClosing(paneID: UUID) -> Bool {
        guard let pane = snapshot.panes[paneID], let tab = snapshot.tabs[pane.tabID] else { return false }
        return closingWindowIDs.contains(tab.windowID) || closingTabIDs.contains(tab.id) || closingPaneIDs.contains(paneID)
    }

    public func recordActivity(paneID: UUID, exited: Bool = false) {
        guard let pane = snapshot.panes[paneID], let tab = snapshot.tabs[pane.tabID],
            tab.windowID != snapshot.activeWindowID
        else { return }
        var indicator = activity[tab.windowID] ?? WindowActivity()
        if exited { indicator.hasExit = true } else { indicator.hasOutput = true }
        if indicator != activity[tab.windowID] { activity[tab.windowID] = indicator }
    }

    private func recordOutput(paneID: UUID) {
        guard outputActivity.recordOutput(paneID, at: activityNow(), commandRunning: shellStates[paneID]?.commandRunning),
            let tabID = snapshot.panes[paneID]?.tabID
        else { return }
        if !busyTabIDs.contains(tabID) { busyTabIDs.insert(tabID) }
        guard busySettleTasks[tabID] == nil else { return }
        // One polling task per busy tab; output chunks only refresh a timestamp, never publish.
        busySettleTasks[tabID] = Task { [weak self] in
            repeat {
                guard let sleep = self?.activitySleep else { return }
                await sleep(PaneOutputActivity.quietInterval / 4)
            } while !Task.isCancelled && self?.refreshBusy(tabID) == true
        }
    }

    /// Clears the tab when none of its panes is busy; returns whether it still is.
    @discardableResult
    private func refreshBusy(_ tabID: UUID) -> Bool {
        let now = activityNow()
        if snapshot.tabs[tabID]?.root.paneIDs.contains(where: { outputActivity.isBusy($0, at: now) }) == true { return true }
        if busyTabIDs.contains(tabID) { busyTabIDs.remove(tabID) }
        busySettleTasks.removeValue(forKey: tabID)?.cancel()
        return false
    }

    private func settleOutput(paneID: UUID) {
        outputActivity.settle(paneID)
        if let tabID = snapshot.panes[paneID]?.tabID { refreshBusy(tabID) }
    }

    public func renameWindow(_ id: UUID, name: String) async {
        do { publish(try await service.execute(.renameWindow(id: id, name: name)).snapshot) } catch { errorMessage = "Use a window name between 1 and 200 characters." }
    }

    public func moveWindow(_ id: UUID, offset: Int) async {
        var order = snapshot.windows.map(\.id)
        guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        do { publish(try await service.execute(.reorderWindows(ids: order)).snapshot) } catch { errorMessage = "The window order could not be changed." }
    }

    /// Drag reordering (FR-W07): the window takes the target's place, so dragging down lands below it and up above it.
    public func moveWindow(_ id: UUID, to targetID: UUID) async {
        var order = snapshot.windows.map(\.id)
        guard id != targetID, order.contains(id), let destination = order.firstIndex(of: targetID) else { return }
        order.removeAll { $0 == id }; order.insert(id, at: destination)
        do { publish(try await service.execute(.reorderWindows(ids: order)).snapshot) } catch { errorMessage = "The window order could not be changed." }
    }

    func attachTerminal(_ pane: WorkspacePane) {
        let terminal = NativeTerminal(sessionID: pane.sessionID)
        terminal.applyAppearance(terminalAppearance)
        terminal.optionAsMeta = keyboard.optionAsMeta
        terminal.searchShortcut = keyboard.shortcuts[.findInPane]
        terminal.inputSuspended = editingTabID != nil || commandPaletteVisible
        terminal.applyPalette(effectiveTheme.terminal)
        terminal.view.setAccessibilityIdentifier("terminal.\(pane.id.uuidString)")
        terminal.onOutput = { [weak self, weak terminal] in
            guard let self else { return }
            self.recordActivity(paneID: pane.id)
            if let terminal, self.terminals[pane.id] === terminal { self.recordOutput(paneID: pane.id) }
        }
        terminal.onInput = { [weak self] in
            guard let self else { return }
            self.outputActivity.recordInput(pane.id, at: self.activityNow())
        }
        terminal.onReturnKey = { [weak self, weak terminal] in
            guard let self, let terminal, self.terminals[pane.id] === terminal else { return }
            self.applyAgentSignal(.inputSubmitted, paneID: pane.id)
        }
        shellStates.removeValue(forKey: pane.id)
        inputWaits.removeValue(forKey: pane.id)
        agentStates.removeValue(forKey: pane.id)
        taskRuns.removeValue(forKey: pane.id)
        clearProgress(paneID: pane.id)
        terminal.onPasswordPromptChanged = { [weak self, weak terminal] active in
            guard let self, let terminal, self.terminals[pane.id] === terminal else { return }
            self.setPasswordPrompt(active, paneID: pane.id)
        }
        terminal.onAttentionRequested = { [weak self, weak terminal] in
            guard let self, let terminal, self.terminals[pane.id] === terminal else { return }
            self.requestAttention(paneID: pane.id)
        }
        terminal.onNotification = { [weak self, weak terminal] notification in
            guard let self, let terminal, self.terminals[pane.id] === terminal else { return }
            self.postNotification(notification, paneID: pane.id)
        }
        terminal.onProgress = { [weak self, weak terminal] report in
            guard let self, let terminal, self.terminals[pane.id] === terminal else { return }
            self.applyProgress(report, paneID: pane.id)
        }
        terminal.onShellIntegrationEvent = { [weak self, weak terminal] event in
            guard let self, let terminal, self.terminals[pane.id] === terminal else { return }
            self.applyShellEvent(event, paneID: pane.id)
        }
        terminal.fileLinkContext = { [weak self] in self?.fileLinkContext(paneID: pane.id) }
        terminal.onOutputData = { [weak self, weak terminal] data in
            // Late output from a closed or replaced session must not recreate its journal.
            guard let self, let terminal, self.snapshot.sessions[terminal.sessionID] != nil else { return }
            let session = terminal.sessionID
            self.outputJournal.append(data, session: session)
            self.onSessionOutput?(session, pane.id, data, self.outputJournal.end(session: session))
        }
        terminal.onFocused = { [weak self] in
            // Clicking a terminal leaves an in-progress rename; Finder-style, keep the edit.
            if let self, let editing = self.editingTabID {
                Task { await self.finishTabRename(editing, draft: self.tabRenameDraft, action: .commit) }
            }
            self?.notePasteFocus(pane.id)
            Task { await self?.selectPane(pane.id) }
        }
        terminal.onPasteRequested = { [weak self, weak terminal] input in
            guard let self, let terminal,
                terminal.view.window?.firstResponder === terminal.view
            else { return }
            self.notePasteFocus(pane.id)
            let epoch = self.pasteFocusEpoch
            Task { @MainActor [weak self, weak terminal] in
                guard let self, let terminal, self.pasteFocusEpoch == epoch,
                    self.terminals[pane.id] === terminal,
                    terminal.view.window?.firstResponder === terminal.view
                else { return }
                guard await self.selectPane(pane.id), self.pasteFocusEpoch == epoch,
                    self.terminals[pane.id] === terminal,
                    terminal.view.window?.firstResponder === terminal.view
                else { return }
                self.requestPaste(input, paneID: pane.id)
            }
        }
        terminals[pane.id] = terminal
    }

    public func setCanvasSize(_ size: CanvasDimensions, tabID: UUID) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        canvasSizes[tabID] = size
    }

    public func toggleMaximize(_ paneID: UUID) async {
        guard !shuttingDown, let pane = snapshot.panes[paneID], !isClosing(paneID: paneID) else { return }
        guard await selectPane(paneID), !shuttingDown, !isClosing(paneID: paneID),
            presentation.selectedTab?.id == pane.tabID,
            snapshot.tabs[pane.tabID]?.activePaneID == paneID
        else { return }
        if maximizedPanes[pane.tabID] == paneID { maximizedPanes.removeValue(forKey: pane.tabID) } else { maximizedPanes[pane.tabID] = paneID }
    }

    public func focusPane(_ direction: PaneDirection) async {
        guard let tab = presentation.selectedTab, let canvas = canvasSizes[tab.id],
            let next = PaneGeometry(layout: tab.root, canvas: canvas).neighbor(of: tab.activePaneID, direction: direction)
        else { return }
        let wasMaximized = maximizedPanes[tab.id] != nil
        guard await selectPane(next), !shuttingDown, !isClosing(paneID: next),
            presentation.selectedTab?.id == tab.id,
            snapshot.tabs[tab.id]?.activePaneID == next
        else { return }
        if wasMaximized, maximizedPanes[tab.id] != nil { maximizedPanes[tab.id] = next }
    }

    /// Coalesce rapid pointer events while preserving the final requested position.
    public func queueDividerResize(_ splitID: UUID, ratio: Double, tabID: UUID) {
        pendingDividerResize = (splitID, ratio, tabID)
        guard dividerResizeTask == nil else { return }
        dividerResizeTask = Task { [weak self] in
            guard let self else { return }
            while let request = pendingDividerResize {
                pendingDividerResize = nil
                await resizeSplit(request.splitID, ratio: request.ratio, tabID: request.tabID, quietly: true)
            }
            dividerResizeTask = nil
        }
    }

    public func resizeSplit(_ splitID: UUID, ratio: Double, tabID: UUID, quietly: Bool = false) async {
        guard !shuttingDown, maximizedPanes[tabID] == nil, let canvas = canvasSizes[tabID] else { return }
        do { publish(try await service.execute(.resizeSplit(tabID: tabID, splitID: splitID, ratio: ratio, canvas: canvas)).snapshot) } catch { if !quietly { errorMessage = "This divider would make a pane too small." } }
    }

    public func resizeFocusedPane(_ direction: PaneDirection) async {
        guard let tab = presentation.selectedTab else { return }
        let axis: SplitAxis = direction == .left || direction == .right ? .x : .y
        guard let split = tab.root.enclosingSplit(paneID: tab.activePaneID, axis: axis) else { return }
        let delta = direction == .left || direction == .up ? -0.05 : 0.05
        await resizeSplit(split.id, ratio: split.ratio + delta, tabID: tab.id)
    }

    public func restartPane(_ id: UUID, startSession: Bool = true) async {
        guard !shuttingDown, !isClosing(paneID: id), let terminal = terminals[id],
            terminal.sessionState == .exited || terminal.sessionState == .failed
        else { return }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        await waitForUpdates()
        guard !shuttingDown, !isClosing(paneID: id), terminals[id] === terminal else { return }
        do {
            let result = try await service.execute(.restartSession(paneID: id))
            guard let pane = result.snapshot.panes[id] else { return }
            terminal.adapter.detach()
            attachTerminal(pane)
            publish(result.snapshot)
            if startSession { await start(paneID: id) }
        } catch { errorMessage = "The session could not be restarted." }
    }

    public func selectPane(_ id: UUID) async -> Bool {
        notePasteFocus(id)
        guard !shuttingDown, !isClosing(paneID: id), snapshot.panes[id] != nil else { return false }
        do {
            publish(try await service.execute(.selectPane(id: id)).snapshot)
            guard let pane = snapshot.panes[id], !isClosing(paneID: id) else { return false }
            return snapshot.tabs[pane.tabID]?.activePaneID == id
        } catch {
            if snapshot.panes[id] != nil, !isClosing(paneID: id) { errorMessage = "The pane could not be selected." }
            return false
        }
    }

    @discardableResult
    public func splitPane(_ id: UUID, axis: SplitAxis, availableCanvas: CanvasDimensions? = nil, startSession: Bool = true) async -> UUID? {
        guard !shuttingDown, !isClosing(paneID: id), let terminal = terminals[id] else { return nil }
        if let canvas = availableCanvas {
            let minimum = CanvasDimensions.minimum(for: .split(id: UUID(), axis: axis, ratio: 0.5, children: [.pane(UUID()), .pane(UUID())]))
            guard canvas.width >= minimum.width, canvas.height >= minimum.height else {
                errorMessage = "Enlarge this pane before splitting it."
                return nil
            }
        }
        let dimensions = terminal.getWindowSize()
        guard let size = try? TerminalSize(columns: Int(dimensions.ws_col), rows: Int(dimensions.ws_row)) else { return nil }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        do {
            let result = try await service.execute(.splitPane(id: id, axis: axis, availableSize: size))
            guard let newID = result.createdPaneID, let pane = result.snapshot.panes[newID] else { return nil }
            attachTerminal(pane)
            publish(result.snapshot)
            // The store may have committed while a close operation began. Keep
            // its surviving pane materialized, but do not launch a new process
            // inside a hierarchy that is already closing.
            if startSession, !isClosing(paneID: id), !isClosing(paneID: newID) {
                await inheritDirectory(from: id, into: newID)
                await start(paneID: newID)
            }
            return newID
        } catch {
            errorMessage = "This pane cannot be split further. Check its size and the layout limits."
            return nil
        }
    }

    /// Where a saved-host connection opens. Splits divide the focused pane.
    public enum HostPlacement: Sendable, Equatable { case newTab, newWindow, split(SplitAxis) }

    /// Each call creates a new pane and session with its own ssh process; an
    /// existing connection is never reused or retried.
    @discardableResult
    public func connect(host: SavedHost, placement: HostPlacement = .newTab) async -> UUID? {
        guard !isRestoring, recoveryMessage == nil, !shuttingDown else { return nil }
        let paneID: UUID?
        switch placement {
        case .newTab, .newWindow:
            let created: UUID?
            if placement == .newWindow || presentation.selectedWindow == nil {
                // A new window already contains one stopped pane; use it instead of adding a tab.
                let window = await createWindow(name: host.name, startSession: false)
                created = window.flatMap { id in snapshot.windows.first { $0.id == id }?.activeTabID }
            } else {
                created = await createTab(startSessions: false)
            }
            paneID = created.flatMap { snapshot.tabs[$0]?.activePaneID }
            if let created { await renameTab(created, title: host.name) }
        case .split(let axis):
            // Match the pane split controls: a hidden split would hide ssh prompts.
            guard let tab = presentation.selectedTab, let focused = presentation.activePane?.id, maximizedPanes[tab.id] == nil else {
                errorMessage = presentation.selectedTab == nil ? "Open a window before connecting in a split." : "Restore panes before connecting in a split."
                return nil
            }
            paneID = await splitPane(focused, axis: axis, startSession: false)
        }
        guard let paneID, snapshot.panes[paneID] != nil, !isClosing(paneID: paneID), !shuttingDown else { return nil }
        do {
            publish(try await service.execute(.configureStoppedSession(paneID: paneID, launch: .host(host.id))).snapshot)
        } catch {
            errorMessage = "The connection pane could not be prepared."
            return nil
        }
        await start(paneID: paneID)
        return paneID
    }

    public func closePane(_ id: UUID) async {
        guard !shuttingDown, !closureInProgress, !isClosing(paneID: id), let pane = snapshot.panes[id], let tab = snapshot.tabs[pane.tabID] else { return }
        closureInProgress = true
        defer { closureInProgress = false }
        if pendingPaste?.target.paneID == id || pasteFocusPaneID == id { cancelPaste() }
        closingPaneIDs.insert(id)
        defer { closingPaneIDs.remove(id) }
        await closeResources(panes: [id], command: .deletePane(id: id))
        if !snapshot.windows.contains(where: { $0.id == tab.windowID }) { activity.removeValue(forKey: tab.windowID) }
    }

    @discardableResult
    public func createTab(windowID: UUID? = nil, duplicate id: UUID? = nil, startSessions: Bool = true) async -> UUID? {
        guard !shuttingDown, !Task.isCancelled,
            let windowID = windowID ?? presentation.selectedWindow?.id,
            !closingWindowIDs.contains(windowID)
        else { return nil }
        if let id {
            guard snapshot.tabs[id]?.windowID == windowID, !closingTabIDs.contains(id) else { return nil }
        }
        // A new (not duplicated) tab starts where the window's focused shell is.
        let sourcePaneID =
            id == nil
            ? snapshot.windows.first { $0.id == windowID }
                .flatMap { snapshot.tabs[$0.activeTabID]?.activePaneID } : nil
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        do {
            let result = try await service.execute(id.map { .duplicateTab(id: $0) } ?? .createTab(windowID: windowID))
            guard let tabID = result.createdTabID, let tab = result.snapshot.tabs[tabID] else { return nil }
            for paneID in tab.root.paneIDs {
                if let pane = result.snapshot.panes[paneID] { attachTerminal(pane) }
            }
            publish(result.snapshot)
            if startSessions {
                if let sourcePaneID, let paneID = tab.root.paneIDs.first { await inheritDirectory(from: sourcePaneID, into: paneID) }
                for paneID in tab.root.paneIDs { await start(paneID: paneID) }
            }
            return tabID
        } catch {
            errorMessage = "The tab could not be created."
            return nil
        }
    }

    public func selectTab(_ id: UUID) async {
        if id != presentation.selectedTab?.id { cancelPaste(); notePasteFocus(nil) }
        do { publish(try await service.execute(.selectTab(id: id)).snapshot) } catch { errorMessage = "The tab could not be selected." }
    }

    /// Native text editing of a tab title. Terminals stop receiving key input until
    /// the edit ends, so Return/Escape only commit or cancel the title.
    public func beginTabRename(_ id: UUID) async {
        await selectTab(id)
        guard let tab = presentation.selectedTab, tab.id == id else { return }
        tabRenameDraft = tab.title
        editingTabID = id
        terminals.values.forEach { $0.inputSuspended = true }
    }

    public func finishTabRename(_ id: UUID, draft: String, action: TabRenameAction) async {
        if editingTabID == id { endTabRenameEditing() }
        guard case .commit = action else { return }
        await renameTab(id, title: draft)
    }

    private func endTabRenameEditing() {
        editingTabID = nil
        terminals.values.forEach { $0.inputSuspended = commandPaletteVisible }
    }

    public func renameTab(_ id: UUID, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do { publish(try await service.execute(.renameTab(id: id, title: trimmed)).snapshot) } catch { errorMessage = "Use a tab name between 1 and 200 characters." }
    }

    public func setTabColor(_ id: UUID, color: TabColor?) async {
        do { publish(try await service.execute(.setTabColor(id: id, color: color)).snapshot) } catch { errorMessage = "The tab color could not be changed." }
    }

    public func moveTab(_ id: UUID, offset: Int) async {
        guard let tab = snapshot.tabs[id], let window = snapshot.windows.first(where: { $0.id == tab.windowID }) else { return }
        var order = window.tabIDs
        guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        do { publish(try await service.execute(.reorderTabs(windowID: tab.windowID, ids: order)).snapshot) } catch { errorMessage = "The tab order could not be changed." }
    }

    /// Drag reordering (FR-T10): the tab takes the target's place, so dragging right lands after it and left before it.
    public func moveTab(_ id: UUID, to targetID: UUID) async {
        guard id != targetID, let tab = snapshot.tabs[id], snapshot.tabs[targetID]?.windowID == tab.windowID,
            let window = snapshot.windows.first(where: { $0.id == tab.windowID }), let destination = window.tabIDs.firstIndex(of: targetID)
        else { return }
        var order = window.tabIDs
        order.removeAll { $0 == id }; order.insert(id, at: destination)
        do { publish(try await service.execute(.reorderTabs(windowID: tab.windowID, ids: order)).snapshot) } catch { errorMessage = "The tab order could not be changed." }
    }

    public func deleteWindow(_ id: UUID) async {
        guard !shuttingDown, !closureInProgress, !closingWindowIDs.contains(id),
            let window = snapshot.windows.first(where: { $0.id == id })
        else { return }
        closureInProgress = true
        defer { closureInProgress = false }
        let pastePaneID = pendingPaste?.target.paneID ?? pasteFocusPaneID
        if pastePaneID.flatMap({ snapshot.panes[$0] }).flatMap({ snapshot.tabs[$0.tabID] })?.windowID == id { cancelPaste() }
        closingWindowIDs.insert(id)
        defer { closingWindowIDs.remove(id) }
        let panes = Set(window.tabIDs.flatMap { snapshot.tabs[$0]?.root.paneIDs ?? [] })
        await closeResources(panes: panes, command: .deleteWindow(id: id))
        if !snapshot.windows.contains(where: { $0.id == id }) { activity.removeValue(forKey: id) }
    }

    public func closeTab(_ id: UUID) async {
        guard !shuttingDown, !closureInProgress, let tab = snapshot.tabs[id], !closingTabIDs.contains(id),
            !closingWindowIDs.contains(tab.windowID)
        else { return }
        closureInProgress = true
        defer { closureInProgress = false }
        let pastePaneID = pendingPaste?.target.paneID ?? pasteFocusPaneID
        if pastePaneID.flatMap({ snapshot.panes[$0] })?.tabID == id { cancelPaste() }
        closingTabIDs.insert(id)
        defer { closingTabIDs.remove(id) }
        await closeResources(panes: Set(tab.root.paneIDs), command: .deleteTab(id: id))
        if !snapshot.windows.contains(where: { $0.id == tab.windowID }) { activity.removeValue(forKey: tab.windowID) }
    }

    func prepareCloseSummary(_ panes: Set<UUID>) {
        closeSummary = panes.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            guard terminals[id]?.isRunning == true, let pane = snapshot.panes[id], let tab = snapshot.tabs[pane.tabID],
                let window = snapshot.windows.first(where: { $0.id == tab.windowID })
            else { return nil }
            return "\(window.name) / \(tab.title) / \(pane.title ?? "Terminal")"
        }
    }

    private func showClosureConfirmation(count: Int, force: Bool) -> Bool {
        guard count > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = force ? "Force stop \(count) session(s)?" : "Close \(count) terminal session(s)?"
        let summary = closeSummary.prefix(8).joined(separator: "\n")
        let more = closeSummary.count > 8 ? "\n…and \(closeSummary.count - 8) more" : ""
        alert.informativeText =
            (force ? "These sessions have not finished closing after two seconds.\n\n" : "Their owned local processes will stop.\n\n")
            + summary + more + "\n\nDetached or remote processes may continue running."
        alert.addButton(withTitle: force ? "Force Stop" : "Close Sessions")
        alert.addButton(withTitle: force ? "Keep Waiting" : "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func confirmAllSessionClosure() -> Bool {
        guard !shuttingDown, !closureInProgress else { return false }
        // Freeze creation before entering the native modal loop. Cancel restores
        // the gate without sending any signal or changing the workspace.
        cancelPaste()
        shuttingDown = true
        prepareCloseSummary(Set(terminals.keys))
        let accepted = confirmCloseSessions(runningTerminals.count)
        if !accepted { shuttingDown = false }
        return accepted
    }

    func finishClosure(_ panes: Set<UUID>) async -> Bool {
        let affected: [any ClosableSession] = panes.compactMap { terminals[$0] }
        var result = await closureCoordinator.close(affected, allowRunning: true)
        if case .closePending = result {
            let live = affected.filter(\.requiresTermination)
            guard !Task.isCancelled else { return false }
            if live.isEmpty {
                // The child has exited; allow bounded I/O cleanup without
                // asking the user to force-stop an already dead process.
                result = await closureCoordinator.close(affected, allowRunning: true)
            } else {
                prepareCloseSummary(Set(panes.filter { terminals[$0]?.requiresTermination == true }))
                guard confirmForceSessions(live.count) else { return false }
                result = await closureCoordinator.close(affected, allowRunning: true, force: true)
            }
        }
        guard result == .closed else { errorMessage = "Some sessions are still closing. Try Close again when they are ready."; return false }
        // Pending store/start work must complete before deleting its hierarchy.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while pendingOperations > 0, ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard pendingOperations == 0 else { errorMessage = "A session launch is still finishing. Try Close again shortly."; return false }
        await waitForUpdates()
        return !Task.isCancelled
    }

    private func closeResources(panes initialPanes: Set<UUID>, command: WorkspaceCommand) async {
        // Close gates are already set. Let operations that committed just before
        // the gate materialize their stopped panes before computing the summary.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while pendingOperations > 0, ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard pendingOperations == 0, !Task.isCancelled else {
            errorMessage = "A session launch is still finishing. Try Close again shortly."
            return
        }
        await waitForUpdates()
        let panes: Set<UUID>
        switch command {
        case .deleteWindow(let id):
            panes = Set(snapshot.windows.first(where: { $0.id == id })?.tabIDs.flatMap { snapshot.tabs[$0]?.root.paneIDs ?? [] } ?? [])
        case .deleteTab(let id): panes = Set(snapshot.tabs[id]?.root.paneIDs ?? [])
        default: panes = initialPanes
        }
        prepareCloseSummary(panes)
        let live = panes.compactMap { terminals[$0] }.filter(\.isRunning)
        guard live.isEmpty || confirmCloseSessions(live.count) else { return }
        guard await finishClosure(panes), !shuttingDown else { return }
        do {
            publish(try await service.execute(command).snapshot)
            terminals = terminals.filter { snapshot.panes[$0.key] != nil }
        } catch { errorMessage = "The sessions could not be closed." }
    }

    /// Preserve callback order across async store calls, including fast exits.
    func enqueue(_ command: WorkspaceCommand) {
        let previous = updates
        updates = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do { self.publish(try await self.service.execute(command).snapshot) } catch { self.errorMessage = "The terminal state could not be updated." }
        }
    }

    public func waitForUpdates() async { await updates?.value }

    public func saveLaunchSettings(shell: String, directory: String) async -> Bool {
        let configuration = LocalLaunchConfiguration.loginShell(executable: shell, directory: directory)
        do {
            _ = try await Task.detached { try LocalLaunchValidator().validate(configuration) }.value
            defaultShell = shell; defaultDirectory = directory
            preferences.set(shell, forKey: "terminal.shell")
            preferences.set(directory, forKey: "terminal.directory")
            scheduleWorkspaceSave()
            return true
        } catch { return false }
    }

    /// Remote workspace sessions are left running on their hosts (FR-RW06); `shutdown(endingRemoteSessions:)` decides.
    public func stopAll() {
        cancelPaste()
        shuttingDown = true
        runningTerminals.filter { $0.remoteTransport == nil }.forEach { $0.stop() }
    }

    private var currentPasteTarget: TerminalPasteTarget? {
        guard !shuttingDown, let pane = presentation.activePane, !isClosing(paneID: pane.id),
            let terminal = terminals[pane.id], terminal.sessionID == pane.sessionID,
            terminal.sessionState == .running
        else { return nil }
        return TerminalPasteTarget(paneID: pane.id, sessionID: pane.sessionID)
    }

    public func requestPaste(_ input: TerminalPasteInput, paneID: UUID) {
        guard let target = currentPasteTarget, target.paneID == paneID,
            let session = snapshot.sessions[target.sessionID], let terminal = terminals[paneID]
        else { return }
        let shell: String?
        switch session.launch {
        case .shell: shell = defaultShell
        case .process(let executable, _, _): shell = executable
        case .host, .remoteShell, .agent: shell = nil
        }
        let plan = TerminalPastePlan(input: input, shell: shell)
        let paneNumber = (presentation.selectedTab?.root.paneIDs.firstIndex(of: paneID) ?? 0) + 1
        let paneName = "Pane \(paneNumber) — \(presentation.activePane?.title ?? "Terminal")"
        let name = [presentation.selectedWindow?.name, presentation.selectedTab?.title, paneName]
            .compactMap { $0 }.joined(separator: " / ")
        defer { pendingPaste = pasteReview.pending }
        do {
            try pasteReview.request(plan, target: target, name: name) { try terminal.paste($0) }
        } catch { errorMessage = "The paste could not be sent. The session may have stopped or the input may be too large." }
    }

    public func confirmPaste(_ id: UUID) {
        let target = currentPasteTarget
        defer { pendingPaste = pasteReview.pending }
        do {
            try pasteReview.confirm(id: id, currentTarget: target) { plan in
                guard let target, let terminal = terminals[target.paneID] else { return }
                try terminal.paste(plan)
            }
        } catch { errorMessage = "The paste could not be sent. The session may have stopped or the input may be too large." }
    }

    private func notePasteFocus(_ paneID: UUID?) {
        guard pasteFocusPaneID != paneID else { return }
        pasteFocusPaneID = paneID
        cancelPaste()
    }

    public func cancelPaste() { pasteFocusEpoch &+= 1; pasteReview.cancel(); pendingPaste = nil }

    @discardableResult
    /// Quitting and closing the window detach remote workspace sessions without a signal (FR-RW06); closing the
    /// workspaces themselves ends them.
    public func shutdown(endingRemoteSessions: Bool = false) async -> Bool {
        cancelPaste()
        let remote = Set(terminals.filter { $0.value.remoteTransport != nil }.keys)
        let ending = endingRemoteSessions ? Set(terminals.keys) : Set(terminals.keys).subtracting(remote)
        if !endingRemoteSessions { remote.forEach { terminals[$0]?.prepareForKeepRunning() } }
        prepareCloseSummary(ending)
        stopAll()
        if endingRemoteSessions { remote.forEach { terminals[$0]?.stop() } }
        let closed = await finishClosure(ending)
        if !closed {
            shuttingDown = false
            if !endingRemoteSessions { remote.forEach { terminals[$0]?.prepareForKeepRunning(false) } }
        } else if !endingRemoteSessions {
            remoteReconnector.cancelAll()
            remoteHosts?.closeWorkspaceLinks()
            // Closed without a state callback: the sidebar must not keep saying Connected, and Reconnect must stay possible.
            for host in remoteLinks.keys { remoteLinks[host] = .disconnected(nil) }
        }
        return closed
    }

    /// MAC-04: with sessions kept (the default), closing the window only hides it; the app and its sessions go on.
    public var windowCloseAction: WindowCloseAction { keepsSessionsAtQuit ? .hide : .endSessions }

    /// Closing the native window with Stop sessions when Trellis quits on (MAC-04) ends every session but keeps windows, tabs and splits as stopped panes,
    /// so a later Quit saves the layout instead of an empty workspace.
    @discardableResult
    public func endSessionsForWindowClose() async -> Bool {
        guard await shutdown() else { return false }
        shuttingDown = false
        // The app goes on: detached remote sessions can be reconnected and closed again, so they are signalled normally.
        terminals.values.filter { $0.remoteTransport != nil }.forEach { $0.prepareForKeepRunning(false) }
        return await flushWorkspaceSave()
    }

    @discardableResult
    public func closeAllWorkspaces() async -> Bool {
        guard await shutdown(endingRemoteSessions: true) else { return false }
        do {
            publish(try await service.execute(.closeAllWindows).snapshot)
            terminals.removeAll()
            activity.removeAll()
            shuttingDown = false
            return await flushWorkspaceSave()
        } catch { errorMessage = "The workspaces could not be closed."; shuttingDown = false; return false }
    }
}
