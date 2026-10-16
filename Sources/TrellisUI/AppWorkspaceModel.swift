import AppKit
import Combine
import TrellisCore
import TrellisTerminal

public enum TabRenameAction: Sendable { case commit, cancel }

public struct WindowActivity: Equatable, Sendable {
    public var hasOutput = false
    public var hasExit = false
    public init() {}
}

@MainActor
public final class AppWorkspaceModel: ObservableObject {
    @Published public private(set) var snapshot = WorkspaceSnapshot()
    @Published public private(set) var terminals: [UUID: NativeTerminal] = [:]
    @Published public var errorMessage: String?
    @Published public private(set) var appearance = AppearanceSettings()
    @Published public private(set) var themeCatalog = ThemeLibrarySnapshot()
    @Published public private(set) var effectiveTheme = ResolvedTheme.builtIn(.light)
    @Published public private(set) var previewedTheme: ThemeDocument?
    @Published public private(set) var themeNotice: String?
    @Published public private(set) var themeBusy = false
    @Published public private(set) var themeReplacementID: String?
    private let themeLibrary: ThemeLibrary?
    private var systemIsDark = false
    public var themesDirectory: URL? { themeLibrary?.directory }
    public var effectiveChromeMode: ChromeMode {
        if let previewedTheme { return previewedTheme.appearance == .light ? .light : .dark }
        return appearance.chromeMode
    }
    public var allThemes: [ResolvedTheme] {
        ThemeAppearance.allCases.map(ResolvedTheme.builtIn) + themeCatalog.documents.values.map { $0.resolved() }.sorted { $0.id < $1.id }
    }
    public func availableThemes(for slot: ThemeAppearance) -> [ResolvedTheme] { allThemes.filter { $0.appearance == slot } }
    public func systemAppearanceDidChange(isDark: Bool) {
        guard systemIsDark != isDark else { return }
        systemIsDark = isDark
        if appearance.chromeMode == .system, previewedTheme == nil { refreshEffectiveTheme() }
    }
    private func refreshEffectiveTheme() {
        let slot: ThemeAppearance = appearance.chromeMode.isDark(systemIsDark: systemIsDark) ? .dark : .light
        let id = appearance.themeID(systemIsDark: systemIsDark)
        effectiveTheme = previewedTheme?.resolved() ?? themeCatalog.documents[id]?.resolved() ?? .builtIn(slot)
        onChromeModeChanged?(effectiveChromeMode)
        for terminal in terminals.values { terminal.applyPalette(effectiveTheme.terminal) }
    }
    private func reconcileThemeSelections() {
        guard themeLibrary != nil else { return }
        var notices: [String] = []
        for slot in ThemeAppearance.allCases {
            let id = slot == .light ? appearance.lightThemeID : appearance.darkThemeID
            let builtIn = ResolvedTheme.builtIn(slot)
            if id != builtIn.id, themeCatalog.documents[id]?.appearance != slot {
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
    public var appearanceNotice: String? { NativeTerminalFont.choice(for: appearance.fontName).notice }

    public func applyAppearance(_ settings: AppearanceSettings) -> Bool {
        guard settings.isValid else { return false }
        let previous = appearance
        let terminalSettingsChanged =
            previous.fontName != settings.fontName || previous.fontSize != settings.fontSize
            || previous.cursorShape != settings.cursorShape || previous.cursorBlinks != settings.cursorBlinks
            || previous.scrollbackLines != settings.scrollbackLines
        appearance = settings
        reconcileThemeSelections()
        if terminalSettingsChanged { for terminal in terminals.values { terminal.applyAppearance(terminalAppearance) } }
        refreshEffectiveTheme()
        scheduleWorkspaceSave()
        return true
    }
    /// Reduce Motion keeps the cursor steady without changing the saved preference.
    var terminalAppearance: AppearanceSettings {
        var settings = appearance
        if reduceMotion { settings.cursorBlinks = false }
        return settings
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
            live: terminals.mapValues { WorkspaceAccessibility.LiveSession(state: $0.sessionState, exitCode: $0.exitCode) },
            windowsWithOutput: Set(activity.filter(\.value.hasOutput).keys), windowsWithExit: Set(activity.filter(\.value.hasExit).keys))
    }

    /// VoiceOver names each terminal by pane and status; its value stays the text.
    private func refreshTerminalAccessibility() {
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
    public var confirmCloseSessions: (Int) -> Bool = { _ in true }
    public var confirmForceSessions: (Int) -> Bool = { _ in false }
    private var closeSummary: [String] = []
    private let closureCoordinator = SessionClosureCoordinator()
    private var closureInProgress = false
    private var closingWindowIDs = Set<UUID>()
    private var closingTabIDs = Set<UUID>()
    private var closingPaneIDs = Set<UUID>()
    @Published public private(set) var maximizedPanes: [UUID: UUID] = [:]
    private var pendingDividerResize: (splitID: UUID, ratio: Double, tabID: UUID)?
    private var dividerResizeTask: Task<Void, Never>?
    private var canvasSizes: [UUID: CanvasDimensions] = [:]
    @Published public var tabRenameRequest: UUID?
    @Published public var windowRenameRequest: UUID?
    @Published public private(set) var editingTabID: UUID?
    @Published public var tabRenameDraft = ""
    @Published public private(set) var keyboard: KeyboardSettings
    @Published public private(set) var keyboardNotice: String?
    public var onKeyboardSettingsChanged: (() -> Void)?
    @Published public private(set) var increaseContrast = false
    @Published public private(set) var reduceMotion = false
    @Published public private(set) var isRestoring: Bool
    @Published public private(set) var recoveryMessage: String?
    @Published public private(set) var backupAvailable = false
    @Published public private(set) var persistenceReadOnly = false
    @Published public private(set) var unconfiguredPaneIDs = Set<UUID>()
    public private(set) var restoredWindowFrame: String?
    public var onRestoreWindowFrame: ((String) -> Void)?
    private let persistence: WorkspacePersistence?
    private var recoveryBackup: RestoredWorkspace?
    private var recoveryReason: WorkspacePersistenceError?
    private var pendingSaveTask: Task<Void, Never>?
    private var saveGeneration: UInt64 = 0
    public var openSettings: (() -> Void)?
    private let service: WorkspaceCommandService
    private var updates: Task<Void, Never>?
    private let preferences: UserDefaults
    private var shuttingDown = false
    private var pendingOperations = 0

    public init(store: WorkspaceStore, preferences: UserDefaults = .standard, persistence: WorkspacePersistence? = nil, themeLibrary: ThemeLibrary? = nil) {
        self.themeLibrary = themeLibrary
        self.persistence = persistence
        self.isRestoring = persistence != nil
        service = WorkspaceCommandService(store: store)
        self.preferences = preferences
        defaultShell = preferences.string(forKey: "terminal.shell") ?? LocalLaunchConfiguration.loginShell().executable
        defaultDirectory = preferences.string(forKey: "terminal.directory") ?? FileManager.default.homeDirectoryForCurrentUser.path
        (keyboard, keyboardNotice) = Self.loadKeyboardSettings(preferences)
        confirmCloseSessions = { [weak self] in self?.showClosureConfirmation(count: $0, force: false) ?? false }
        confirmForceSessions = { [weak self] in self?.showClosureConfirmation(count: $0, force: true) ?? false }
    }

    /// Returns true for an existing document or recovery state, even if empty.
    public func loadWorkspace() async -> Bool {
        if let themeLibrary {
            themeCatalog = await themeLibrary.reload()
            reconcileThemeSelections()
            refreshEffectiveTheme()
        }
        guard let persistence else { return false }
        isRestoring = true
        pendingOperations += 1
        defer { isRestoring = false; pendingOperations -= 1 }
        let result = await persistence.load()
        // Restoring never starts a process. Finish it even if startup was
        // cancelled by Quit, so shutdown cannot replace saved state with an
        // uninitialized empty snapshot.
        switch result {
        case .missing: return false
        case .loaded(let restored):
            do { try await applyRestored(restored); return true } catch { recoveryMessage = "The saved workspace could not be restored."; return true }
        case .recovery(let reason, let backup):
            recoveryReason = reason; recoveryBackup = backup; backupAvailable = backup != nil
            if case .unsupportedVersion = reason {
                recoveryMessage = "This workspace was saved by a newer application version. It will remain unchanged. Recovery opens a temporary workspace."
            } else {
                recoveryMessage = "The saved workspace could not be read. Recover the backup or start empty; the original file will be preserved."
            }
            return true
        }
    }

    private func applyRestored(_ restored: RestoredWorkspace) async throws {
        try await service.store.restoreStoppedSnapshot(restored.snapshot)
        defaultShell = restored.settings.shell; defaultDirectory = restored.settings.directory
        appearance = restored.settings.appearance
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

    private func scheduleWorkspaceSave() {
        guard persistence != nil, !isRestoring, recoveryMessage == nil, !persistenceReadOnly else { return }
        if saveGeneration < UInt64.max { saveGeneration += 1 }
        let generation = saveGeneration
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, !Task.isCancelled, generation == saveGeneration else { return }
            pendingSaveTask = nil
            _ = await saveWorkspaceNow()
        }
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
        pendingSaveTask?.cancel(); pendingSaveTask = nil
        return await saveWorkspaceNow()
    }

    private func saveWorkspaceNow() async -> Bool {
        guard let persistence, !isRestoring, recoveryMessage == nil, !persistenceReadOnly else { return true }
        let settings = WorkspaceSettings(
            shell: defaultShell, directory: defaultDirectory,
            windowFrame: preferences.string(forKey: "app.windowFrame"), appearance: appearance)
        do { try await persistence.save(snapshot, settings: settings, sequence: saveGeneration); return true } catch {
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
        snapshot = next
        if let pendingPaste, pendingPaste.target != currentPasteTarget { cancelPaste() }
        maximizedPanes = maximizedPanes.filter { tabID, paneID in next.tabs[tabID]?.root.paneIDs.contains(paneID) == true }
        canvasSizes = canvasSizes.filter { next.tabs[$0.key] != nil }
        unconfiguredPaneIDs = unconfiguredPaneIDs.filter { next.panes[$0] != nil }
        if let selected = next.activeWindowID { activity.removeValue(forKey: selected) }
        if let editingTabID, next.tabs[editingTabID] == nil || presentation.selectedTab?.id != editingTabID { endTabRenameEditing() }
        refreshTerminalAccessibility()
        scheduleWorkspaceSave()
    }

    public func createWindow(name: String? = nil, startSession: Bool = true, fixture: Bool = false) async {
        guard !isRestoring, recoveryMessage == nil, !shuttingDown, !Task.isCancelled else { return }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        do {
            let result = try await service.execute(.createWindow(name: name ?? "Window \(snapshot.windows.count + 1)"))
            // Always materialize a committed result, including during a native
            // confirmation loop. Shutdown gates only the process launch.
            guard let id = result.createdWindowID, let window = result.snapshot.windows.first(where: { $0.id == id }),
                let tab = result.snapshot.tabs[window.activeTabID], let pane = result.snapshot.panes[tab.activePaneID]
            else { return }
            attachTerminal(pane)
            publish(result.snapshot)
            if startSession { await start(paneID: pane.id, fixture: fixture) }
        } catch { errorMessage = "The window could not be created." }
    }

    public func selectWindow(_ id: UUID) async {
        if id != snapshot.activeWindowID { cancelPaste(); notePasteFocus(nil) }
        do {
            publish(try await service.execute(.selectWindow(id: id)).snapshot)
        } catch { errorMessage = "The window could not be selected." }
    }

    public func start(paneID: UUID, fixture: Bool = false) async {
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
                case .host: resolvedLaunch = nil
                }
            } else {
                resolvedLaunch = nil
            }
            let result = try await service.execute(.startSession(paneID: paneID, resolvedLaunch: resolvedLaunch))
            publish(result.snapshot)
            guard case .start(let request) = result.effects.first else { return }
            guard !isClosing(paneID: paneID), !shuttingDown, !Task.isCancelled else {
                publish(
                    try await service.execute(
                        .completeLaunch(
                            sessionID: request.sessionID, attemptID: request.attemptID,
                            outcome: .failed(message: "Session launch was cancelled."))
                    ).snapshot)
                return
            }
            terminal.onInputError = { [weak self] _ in self?.errorMessage = "Terminal input could not be sent. Check the session or try a smaller paste." }
            var launchCompleted = false
            terminal.onStateChanged = { [weak self, weak terminal] state in
                if state != .running, self?.pendingPaste?.target.paneID == paneID { self?.cancelPaste() }
                if !launchCompleted, state == .running || state == .closing, let pid = terminal?.processID {
                    launchCompleted = true
                    self?.enqueue(.completeLaunch(sessionID: request.sessionID, attemptID: request.attemptID, outcome: .started(processID: pid)))
                }
                if launchCompleted, state == .closing { self?.enqueue(.markSessionClosing(sessionID: request.sessionID)) }
            }
            terminal.onExit = { [weak self, weak terminal] code in
                guard let self, let terminal else { return }
                let command: WorkspaceCommand =
                    !launchCompleted
                    ? .completeLaunch(
                        sessionID: request.sessionID, attemptID: request.attemptID,
                        outcome: .failed(
                            message: terminal.sessionState == .failed
                                ? "The executable, directory, or environment could not be used." : "Session launch was cancelled."))
                    : .recordSessionExit(sessionID: request.sessionID, code: code)
                self.closureCoordinator.forget(sessionID: request.sessionID)
                self.recordActivity(paneID: paneID, exited: true)
                self.enqueue(command)
            }
            if fixture {
                await terminal.startFixture()
            } else {
                let configuration: LocalLaunchConfiguration
                switch request.launch {
                case .shell(let directory):
                    configuration = .loginShell(executable: defaultShell, directory: directory ?? defaultDirectory)
                case .process(let executable, let arguments, let directory):
                    configuration = LocalLaunchConfiguration(executable: executable, arguments: arguments, directory: directory ?? defaultDirectory)
                case .host:
                    publish(
                        try await service.execute(
                            .completeLaunch(
                                sessionID: request.sessionID, attemptID: request.attemptID,
                                outcome: .failed(message: "Saved host connections require SSH integration."))
                        ).snapshot)
                    return
                }
                await terminal.start(configuration: configuration)
            }
        } catch { errorMessage = "The terminal session could not be started." }
    }

    private func isClosing(paneID: UUID) -> Bool {
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

    public func renameWindow(_ id: UUID, name: String) async {
        do { publish(try await service.execute(.renameWindow(id: id, name: name)).snapshot) } catch { errorMessage = "Use a window name between 1 and 200 characters." }
    }

    public func moveWindow(_ id: UUID, offset: Int) async {
        var order = snapshot.windows.map(\.id)
        guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        do { publish(try await service.execute(.reorderWindows(ids: order)).snapshot) } catch { errorMessage = "The window order could not be changed." }
    }

    private func attachTerminal(_ pane: WorkspacePane) {
        let terminal = NativeTerminal(sessionID: pane.sessionID)
        terminal.applyAppearance(terminalAppearance)
        terminal.optionAsMeta = keyboard.optionAsMeta
        terminal.searchShortcut = keyboard.shortcuts[.findInPane]
        terminal.inputSuspended = editingTabID != nil
        terminal.applyPalette(effectiveTheme.terminal)
        terminal.view.setAccessibilityIdentifier("terminal.\(pane.id.uuidString)")
        terminal.onOutput = { [weak self] in self?.recordActivity(paneID: pane.id) }
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

    public func splitPane(_ id: UUID, axis: SplitAxis, availableCanvas: CanvasDimensions? = nil, startSession: Bool = true) async {
        guard !shuttingDown, !isClosing(paneID: id), let terminal = terminals[id] else { return }
        if let canvas = availableCanvas {
            let minimum = CanvasDimensions.minimum(for: .split(id: UUID(), axis: axis, ratio: 0.5, children: [.pane(UUID()), .pane(UUID())]))
            guard canvas.width >= minimum.width, canvas.height >= minimum.height else {
                errorMessage = "Enlarge this pane before splitting it."
                return
            }
        }
        let dimensions = terminal.getWindowSize()
        guard let size = try? TerminalSize(columns: Int(dimensions.ws_col), rows: Int(dimensions.ws_row)) else { return }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        do {
            let result = try await service.execute(.splitPane(id: id, axis: axis, availableSize: size))
            guard let newID = result.createdPaneID, let pane = result.snapshot.panes[newID] else { return }
            attachTerminal(pane)
            publish(result.snapshot)
            // The store may have committed while a close operation began. Keep
            // its surviving pane materialized, but do not launch a new process
            // inside a hierarchy that is already closing.
            if startSession, !isClosing(paneID: id), !isClosing(paneID: newID) { await start(paneID: newID) }
        } catch { errorMessage = "This pane cannot be split further. Check its size and the layout limits." }
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

    public func createTab(windowID: UUID? = nil, duplicate id: UUID? = nil, startSessions: Bool = true) async {
        guard !shuttingDown, !Task.isCancelled,
            let windowID = windowID ?? presentation.selectedWindow?.id,
            !closingWindowIDs.contains(windowID)
        else { return }
        if let id {
            guard snapshot.tabs[id]?.windowID == windowID, !closingTabIDs.contains(id) else { return }
        }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        do {
            let result = try await service.execute(id.map { .duplicateTab(id: $0) } ?? .createTab(windowID: windowID))
            guard let tabID = result.createdTabID, let tab = result.snapshot.tabs[tabID] else { return }
            for paneID in tab.root.paneIDs {
                if let pane = result.snapshot.panes[paneID] { attachTerminal(pane) }
            }
            publish(result.snapshot)
            if startSessions {
                for paneID in tab.root.paneIDs { await start(paneID: paneID) }
            }
        } catch { errorMessage = "The tab could not be created." }
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
        terminals.values.forEach { $0.inputSuspended = false }
    }

    public func renameTab(_ id: UUID, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do { publish(try await service.execute(.renameTab(id: id, title: trimmed)).snapshot) } catch { errorMessage = "Use a tab name between 1 and 200 characters." }
    }

    public func moveTab(_ id: UUID, offset: Int) async {
        guard let tab = snapshot.tabs[id], let window = snapshot.windows.first(where: { $0.id == tab.windowID }) else { return }
        var order = window.tabIDs
        guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
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

    private func prepareCloseSummary(_ panes: Set<UUID>) {
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

    private func finishClosure(_ panes: Set<UUID>) async -> Bool {
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
    private func enqueue(_ command: WorkspaceCommand) {
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

    public func stopAll() {
        cancelPaste()
        shuttingDown = true
        runningTerminals.forEach { $0.stop() }
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
        case .host: shell = nil
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
    public func shutdown() async -> Bool {
        cancelPaste()
        prepareCloseSummary(Set(terminals.keys))
        stopAll()
        let closed = await finishClosure(Set(terminals.keys))
        if !closed { shuttingDown = false }
        return closed
    }

    @discardableResult
    public func closeAllWorkspaces() async -> Bool {
        guard await shutdown() else { return false }
        do {
            publish(try await service.execute(.closeAllWindows).snapshot)
            terminals.removeAll()
            activity.removeAll()
            shuttingDown = false
            return await flushWorkspaceSave()
        } catch { errorMessage = "The workspaces could not be closed."; shuttingDown = false; return false }
    }
}
