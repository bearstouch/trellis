import AppKit
import UniformTypeIdentifiers
import SwiftUI
import TrellisControl
import TrellisCore
import TrellisMCP
import TrellisRelease
import TrellisTerminal
import TrellisUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let model: AppWorkspaceModel
    private let hosts: HostListModel
    private var hostsWindow: NSWindow?
    private let projects: ProjectListModel
    private var projectsWindow: NSWindow?
    private let control: ControlServer
    private let mcp: MCPServer
    /// FR-RC06: Trellis's own `tailscale serve` entry, created only after the listener is up.
    private var sharing: TailscaleSharing?
    /// Chains Applies so the coordinator sees them in order; separate Tasks may reach the actor out of order.
    private var sharingUpdate: Task<Void, Never>?
    private let grants: GrantListModel
    private var window: NSWindow!
    private var settingsWindow: NSWindow?
    private var terminationPending = false
    private var closingWindow = false
    private var startupTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var appearanceObserver: NSKeyValueObservation?
    private var settingsCloseObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var updater: SparkleUpdater?
    private var updates: UpdateSettingsModel?
    private var cliInstall: CLIInstallController?

    private let identity: AppInstanceIdentity

    init(
        model: AppWorkspaceModel, hosts: HostListModel, projects: ProjectListModel, control: ControlServer, mcp: MCPServer, grants: GrantListModel,
        identity: AppInstanceIdentity
    ) {
        self.model = model; self.hosts = hosts; self.projects = projects; self.control = control; self.mcp = mcp; self.grants = grants; self.identity = identity
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(activateExistingInstance),
            name: Notification.Name(identity.activationNotification), object: nil)
        NSWindow.allowsAutomaticWindowTabbing = false
        // A packaged app gets its icon from AppIcon.icns; `swift run` would show the generic executable icon.
        if Bundle.main.bundleURL.pathExtension != "app", let url = BundledAppIcon.url(), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        model.onChromeModeChanged = { mode in
            switch mode {
            case .light: NSApp.appearance = NSAppearance(named: .aqua)
            case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
            case .system: NSApp.appearance = nil
            }
        }
        model.onChromeModeChanged?(model.appearance.chromeMode)
        if let notifier = SystemDesktopNotifier() {
            notifier.onActivate = { [weak self] paneID in
                guard let self else { return }
                NSApp.activate(); window?.makeKeyAndOrderFront(nil)
                Task { await self.model.revealPane(paneID) }
            }
            model.desktopNotifier = notifier
        }
        model.workspaceIsFrontmost = { [weak self] in NSApp.isActive && self?.window?.isKeyWindow == true }
        model.workspaceIsVisible = { [weak self] in self?.window?.occlusionState.contains(.visible) == true }
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] app, _ in
            MainActor.assumeIsolated {
                self?.model.systemAppearanceDidChange(isDark: app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            }
        }
        syncAccessibilityDisplayOptions()
        // MAC-14: only builds with a feed get an updater; fixture launches stay offline.
        if !CommandLine.arguments.contains("--fixture"), let updater = SparkleUpdater() {
            self.updater = updater; updates = UpdateSettingsModel(updater: updater)
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAccessibilityDisplayOptions() }
        }
        cliInstall = CLIInstallController(identity: identity, shell: { [model] in model.defaultShell })
        if let cliInstall {
            model.welcomeTourCLIProbe = { cliInstall.tourStatus() }
            model.welcomeTourInstallCLI = { [weak self] in await cliInstall.install(window: self?.window) }
        }
        buildMenus()
        model.onKeyboardSettingsChanged = { [weak self] in self?.buildMenus() }
        model.onLanguageChanged = { [weak self] in
            guard let self else { return }
            buildMenus()
            // FR-LN03: open panels keep their windows, so their titles follow here.
            hostsWindow?.title = L("Hosts"); projectsWindow?.title = L("Projects"); settingsWindow?.title = L("Settings")
        }
        model.openSettings = { [weak self] in self?.showSettings() }
        // Restored or applied settings (re)start the MCP server; fixture and --no-mcp launches never listen.
        let mcpBlocked = CommandLine.arguments.contains("--no-mcp") || CommandLine.arguments.contains("--fixture")
        // Fixture and --no-mcp launches never touch Tailscale either.
        if !mcpBlocked {
            let tailscale = TailscaleController(runner: TailscaleCLI())
            model.tailscaleStatus = { await tailscale.status() }
            sharing = TailscaleSharing(controller: tailscale, server: mcp) { [weak model] state in
                Task { @MainActor in model?.tailscaleShareState = state }
            }
        }
        model.onRemoteControlSettingsChanged = { [weak self] settings in
            guard let self else { return }
            if mcpBlocked, settings.mcpEnabled {
                mcp.stop()
                model.remoteControlStatus = .failed(reason: L("Turned off for this launch (--no-mcp or --fixture)."))
            } else {
                model.remoteControlStatus = mcp.apply(settings)
                // Never publish a port this app isn't listening on: another program could own it.
                var shared = settings
                if case .running = model.remoteControlStatus {} else { shared.tailscaleShare = false }
                if let sharing {
                    let previous = sharingUpdate
                    sharingUpdate = Task {
                        await previous?.value; await sharing.apply(shared)
                    }
                }
            }
        }
        model.openHosts = { [weak self] in self?.showHosts() }
        model.openProjects = { [weak self] in self?.showProjects() }
        projects.hostName = { [hosts] id in hosts.hosts.first { $0.id == id }?.name }
        projects.onLaunch = { [weak self] project in
            guard let self else { return }
            window?.makeKeyAndOrderFront(nil)
            model.beginProjectLaunch(project)
        }
        model.commandPaletteProjects = { [projects] in projects.projects }
        model.gitStatusEnabled = true  // FR-PL09
        Task { [projects] in await projects.load() }
        model.onProjectLaunched = { [projects] id, target, folder in Task { await projects.recordLaunch(id, target: target, folder: folder) } }
        // FR-CP03, FR-CP07: palette actions are the menu's, validated and run the same way.
        model.canPerformShortcutAction = { [weak self] in self?.validateShortcut($0) ?? false }
        model.performShortcutAction = { [weak self] in self?.perform($0) }
        model.commandPaletteHosts = { [hosts] in hosts.hosts }
        model.resolveHost = { [hosts] id in await hosts.host(id) }
        if let helper = Self.helperPath(AskpassBroker.helperName) {
            model.askpass = AskpassBroker(helperPath: helper)
            let library = hosts.library, gate = LocalAuthenticationGate()
            hosts.userPresence = gate
            model.savedPassword = { id, revision in await library.password(hostID: id, connectionRevision: revision, gate: gate) }
            hosts.remote?.askpass = model.askpass
            hosts.remote?.savedPassword = model.savedPassword
        }
        model.remoteHosts = hosts.remote
        model.remoteReconnector.startSystemMonitoring()
        hosts.onOpenRemoteWorkspace = { [weak self] host in
            guard let self else { return }
            window?.makeKeyAndOrderFront(nil)
            Task { await self.model.openRemoteWorkspace(host: host) }
        }
        hosts.onConnect = { [weak self] host, placement in
            guard let self else { return }
            window?.makeKeyAndOrderFront(nil)
            Task { await self.model.connect(host: host, placement: placement) }
        }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Trellis"
        window.minSize = NSSize(width: 400, height: 260)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceRootView(model: model))
        // FR-TH10: a translucent pane background needs a window that composites what's behind it.
        model.onWindowTranslucencyChanged = { [weak self] translucent in self?.setWindowTranslucent(translucent) }
        setWindowTranslucent(model.effectiveBackgroundOpacity < 1)
        if let saved = UserDefaults.standard.string(forKey: "app.windowFrame") { window.setFrame(NSRectFromString(saved), display: false) } else { window.center() }
        constrainWindow()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.constrainWindow() }
        }
        window.makeKeyAndOrderFront(nil)
        model.onRestoreWindowFrame = { [weak self] frame in
            guard let self else { return }
            window.setFrame(NSRectFromString(frame), display: true)
            constrainWindow()
        }
        // Scripted, isolated runs (qualification, benchmarks) must not leave sessions behind when they quit the app.
        model.endSessionsAtQuitForThisLaunch = CommandLine.arguments.contains("--fixture")
        startupTask = Task {
            // Saved-host panes resolve their host when started, so load hosts first.
            await hosts.load()
            await model.loadDirectoryHistory(hosts: hosts.loadFailed ? nil : hosts.hosts)
            let restored = await model.loadWorkspace()
            await model.refresh()
            guard !Task.isCancelled else { return }
            if !restored, model.snapshot.spaces.isEmpty {
                await model.createSpace(name: "Terminal", fixture: CommandLine.arguments.contains("--fixture"))
            }
            // MAC-15, FR-ON02: scripted and isolated launches never ask, and recovery comes first.
            if identity.stateDirectory == nil, !CommandLine.arguments.contains("--fixture"), model.recoveryMessage == nil, !terminationPending {
                // The tour's last step makes the same offer, so it replaces the sheet unless skipped before that step.
                model.onWelcomeTourReachedSetup = { [self] in cliInstall?.recordOfferAnswered() }
                model.onWelcomeTourClosed = { [self] reachedSetup in
                    if !reachedSetup, !terminationPending { Task { await cliInstall?.offerIfNeeded(window: window) } }
                }
                if !model.offerWelcomeTour(workspaceExisted: restored) {
                    model.onWelcomeTourReachedSetup = nil
                    model.onWelcomeTourClosed = nil
                    await cliInstall?.offerIfNeeded(window: window)
                }
            }
        }
        // Local automation is optional: an unsafe endpoint leaves the app
        // fully usable without a control socket.
        _ = try? control.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        control.stop(); mcp.stop(); model.askpass?.stop(); model.removeScratchpadRunFiles(); model.stopAgentHooks()
        // While Trellis is closed another program could take the port, so the tailnet entry goes too.
        if let sharing { Self.wait(seconds: 3) { await sharing.shutdown() } }
    }

    /// Runs `body` off the main thread and waits for it, at most `seconds`.
    private static func wait(seconds: TimeInterval, _ body: @escaping @Sendable () async -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await body()
            done.signal()
        }
        _ = done.wait(timeout: .now() + seconds)
    }

    /// Bundled in Contents/Helpers; `swift run` builds it beside the app binary.
    static func helperPath(_ name: String) -> String? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)"),
            executable.deletingLastPathComponent().appendingPathComponent(name)
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path
    }

    /// Data, not code: it lives in Resources, because codesign refuses unsigned files under Contents/Helpers.
    static func helperDirectory(_ name: String) -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(name)"), executable.deletingLastPathComponent().appendingPathComponent(name)
        ]
        return candidates.first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    @objc private func activateExistingInstance() {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Menus are rebuilt from the saved shortcut map, so every configurable
    /// command shows its current chord where users look for it.
    private func buildMenus() {
        let shortcuts = model.keyboard.shortcuts
        func item(_ action: ShortcutAction) -> NSMenuItem {
            let item = NSMenuItem(title: action.title, action: #selector(performShortcut(_:)), keyEquivalent: "")
            item.representedObject = action.rawValue
            item.target = self
            if let chord = shortcuts[action] {
                item.keyEquivalent = chord.keyEquivalent
                item.keyEquivalentModifierMask = chord.modifierMask
            }
            return item
        }
        func submenu(_ title: String, _ entries: [ShortcutAction?]) -> NSMenuItem {
            let parent = NSMenuItem()
            parent.submenu = NSMenu(title: title)
            for entry in entries { parent.submenu?.addItem(entry.map(item) ?? .separator()) }
            return parent
        }
        let menu = NSMenu()
        let app = NSMenuItem(); app.submenu = NSMenu(title: "Trellis")
        let about = app.submenu?.addItem(withTitle: L("About Trellis"), action: #selector(aboutAction), keyEquivalent: "")
        about?.target = self
        if updater != nil { app.submenu?.addItem(withTitle: L("Check for Updates…"), action: #selector(checkForUpdatesAction), keyEquivalent: "").target = self }
        if cliInstall != nil { app.submenu?.addItem(withTitle: L("Install Command Line Tool…"), action: #selector(installCommandLineToolAction), keyEquivalent: "").target = self }
        app.submenu?.addItem(.separator())
        app.submenu?.addItem(withTitle: L("Settings…"), action: #selector(settingsAction), keyEquivalent: ",")
        app.submenu?.addItem(.separator())
        app.submenu?.addItem(withTitle: L("Hide Trellis"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.submenu?.addItem(withTitle: L("Quit Trellis"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)
        menu.addItem(
            submenu(L("File"), [.newSpace, .newTab, nil, .renameTab, .renameSpace, nil, .closePane, .closeTab, .deleteSpace, nil, .showProjects, .showHosts, .saveWorkspace]))
        if let file = menu.items.last?.submenu {
            file.addItem(.separator())
            file.addItem(withTitle: L("Export Projects & Hosts…"), action: #selector(exportProjectsAndHosts), keyEquivalent: "")
            file.addItem(withTitle: L("Import Projects & Hosts…"), action: #selector(importProjectsAndHosts), keyEquivalent: "")
        }
        let edit = NSMenuItem(); edit.submenu = NSMenu(title: L("Edit"))
        // Undo/Cut/Redo exist for native text fields (tab names, search, settings);
        // the terminal does not implement them, so they stay disabled there.
        edit.submenu?.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.submenu?.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.submenu?.addItem(.separator())
        edit.submenu?.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.submenu?.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: L("Copy All Retained Text"), action: NSSelectorFromString("copyAllRetainedText:"), keyEquivalent: "")
        edit.submenu?.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu?.addItem(withTitle: L("Paste Escaped Path"), action: NSSelectorFromString("pasteEscapedPath:"), keyEquivalent: "")
        edit.submenu?.addItem(withTitle: L("Select All"), action: #selector(selectAllText(_:)), keyEquivalent: "a")
        edit.submenu?.addItem(.separator())
        for action in [ShortcutAction.findInPane, .findNext, .findPrevious] { edit.submenu?.addItem(item(action)) }
        edit.submenu?.addItem(.separator())
        for action in [ShortcutAction.previousPrompt, .nextPrompt] { edit.submenu?.addItem(item(action)) }
        edit.submenu?.addItem(.separator())
        edit.submenu?.addItem(item(.clearPane))
        menu.addItem(edit)
        let view = submenu(L("View"), [.commandPalette, .jumpToDirectory, nil, .toggleSidebar, nil, .toggleFiles, .toggleChanges, .toggleScratchpad, .toggleTasks, .toggleAgents, nil, .zoomIn, .zoomOut, .actualSize])
        // Also accept the unshifted key on keyboards where '+' shares '='.
        if shortcuts[.zoomIn] == KeyChord("+"), shortcuts.action(for: KeyChord("=")) == nil {
            let alias = item(.zoomIn)
            alias.keyEquivalent = "="
            alias.isHidden = true
            alias.allowsKeyEquivalentWhenHidden = true
            view.submenu?.addItem(alias)
        }
        menu.addItem(view)
        menu.addItem(
            submenu(
                L("Pane"),
                [
                    .splitLeftRight, .splitTopBottom, nil, .focusLeft, .focusRight, .focusUp, .focusDown, nil,
                    .resizeLeft, .resizeRight, .resizeUp, .resizeDown, nil, .maximizePane
                ]))
        let windows = submenu(
            L("Window"),
            [
                nil, .previousSpace, .nextSpace, .previousTab, .nextTab, nil,
                .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5, .selectTab6, .selectTab7, .selectTab8, .selectTab9
            ])
        windows.submenu?.insertItem(withTitle: L("Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "", at: 0)
        windows.submenu?.insertItem(withTitle: L("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "", at: 0)
        windows.submenu?.insertItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m", at: 0)
        menu.addItem(windows)
        let help = NSMenuItem(); help.submenu = NSMenu(title: L("Help"))
        help.submenu?.addItem(withTitle: L("Welcome Tour"), action: #selector(welcomeTourAction), keyEquivalent: "").target = self
        help.submenu?.addItem(withTitle: L("Export Diagnostics…"), action: #selector(exportDiagnostics), keyEquivalent: "")
        menu.addItem(help)
        NSApp.helpMenu = help.submenu
        NSApp.windowsMenu = windows.submenu
        NSApp.mainMenu = menu
    }

    @objc private func performShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = ShortcutAction(rawValue: raw) else { return }
        perform(action)
    }

    private func perform(_ action: ShortcutAction) {
        // ⌘W/⌘⇧W close an auxiliary window (Settings) instead of workspace content.
        if [.closePane, .closeTab].contains(action), let key = NSApp.keyWindow, key !== window {
            key.performClose(nil)
            return
        }
        let presentation = model.presentation
        if let index = action.tabIndex {
            guard presentation.visibleTabs.indices.contains(index) else { return }
            Task { await model.selectTab(presentation.visibleTabs[index].id) }
            return
        }
        let pane = presentation.activePane?.id
        model.revealTerminalsForPaneAction(action)
        switch action {
        case .newSpace: newSpace()
        case .newTab: Task { await model.createTab() }
        case .renameTab: model.tabRenameRequest = UUID()
        case .renameSpace: model.spaceRenameRequest = UUID()
        // The Review tab hides the terminals, so closing acts on what is shown, never on a pane out of sight (FR-GC05).
        case .closePane where model.reviewVisible, .closeTab where model.reviewVisible: model.closeReview()
        case .closePane: if let pane { Task { await model.closePane(pane) } }
        case .closeTab: if let tab = presentation.selectedTab?.id { Task { await model.closeTab(tab) } }
        case .deleteSpace: if let id = presentation.selectedSpace?.id { Task { await model.deleteSpace(id) } }
        case .saveWorkspace: Task { await model.flushWorkspaceSave() }
        case .showHosts: showHosts()
        case .showProjects: showProjects()
        case .findInPane: if !performTextFinderAction(.showFindInterface) { model.activeTerminal?.showSearch() }
        case .findNext: if !performTextFinderAction(.nextMatch) { model.activeTerminal?.findInPane() }
        case .findPrevious: if !performTextFinderAction(.previousMatch) { model.activeTerminal?.findInPane(forward: false) }
        case .previousPrompt: model.activeTerminal?.scrollToPrompt(forward: false)
        case .nextPrompt: model.activeTerminal?.scrollToPrompt(forward: true)
        case .clearPane: model.activeTerminal?.clear()
        case .zoomIn: model.zoomTerminalFont(by: 1)
        case .zoomOut: model.zoomTerminalFont(by: -1)
        case .actualSize: model.zoomTerminalFont(by: 0, reset: true)
        case .toggleSidebar: model.toggleSidebar()
        case .toggleFiles, .toggleChanges, .toggleScratchpad, .toggleTasks, .toggleAgents: if let view = SidebarView(shortcut: action) { model.toggleSidebarView(view) }
        case .commandPalette: model.toggleCommandPalette()
        case .jumpToDirectory: model.openDirectoryJump()
        case .splitLeftRight, .splitTopBottom:
            if let pane { Task { await model.splitPane(pane, axis: action == .splitLeftRight ? .x : .y) } }
        case .maximizePane: if let pane { Task { await model.toggleMaximize(pane) } }
        case .focusLeft: Task { await model.focusPane(.left) }
        case .focusRight: Task { await model.focusPane(.right) }
        case .focusUp: Task { await model.focusPane(.up) }
        case .focusDown: Task { await model.focusPane(.down) }
        case .resizeLeft: Task { await model.resizeFocusedPane(.left) }
        case .resizeRight: Task { await model.resizeFocusedPane(.right) }
        case .resizeUp: Task { await model.resizeFocusedPane(.up) }
        case .resizeDown: Task { await model.resizeFocusedPane(.down) }
        case .nextSpace: selectRelativeSpace(1)
        case .previousSpace: selectRelativeSpace(-1)
        case .nextTab: selectRelativeTab(1)
        case .previousTab: selectRelativeTab(-1)
        default: break
        }
    }

    /// Find in a focused text view with its own find bar (the scratchpad editor) searches there, not in the pane.
    private func performTextFinderAction(_ action: NSTextFinder.Action) -> Bool {
        guard let text = window?.firstResponder as? NSTextView, text.usesFindBar, !text.isFieldEditor else { return false }
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        text.performTextFinderAction(sender)
        return true
    }

    private func validateShortcut(_ action: ShortcutAction) -> Bool {
        let presentation = model.presentation
        // FR-ON04: the tour is modal, with no shortcut of its own. ⌘W can still close an auxiliary window such as Settings.
        if model.welcomeTourVisible { return [.closePane, .closeTab].contains(action) && NSApp.keyWindow != nil && NSApp.keyWindow !== window }
        // The palette is modal: menu shortcuts mustn't change the workspace (or steal its field's focus) behind it.
        if model.commandPaletteVisible, window?.isKeyWindow == true { return action == .commandPalette }
        if [.closePane, .closeTab].contains(action), let key = NSApp.keyWindow, key !== window { return true }
        if [.newSpace, .saveWorkspace, .showHosts, .showProjects, .zoomIn, .zoomOut, .actualSize].contains(action) { return true }
        // Workspace commands act on the main window only while it is key.
        guard window?.isKeyWindow == true else { return false }
        if action == .toggleSidebar { return true }
        if action == .commandPalette || action == .jumpToDirectory { return !model.isRestoring && model.recoveryMessage == nil }
        // FR-SB04: a view the focused pane can't use does nothing.
        if let view = SidebarView(shortcut: action) { return !model.presentation.isEmpty && model.sidebarUnavailableReason(view) == nil }
        guard !model.isRestoring, model.recoveryMessage == nil else { return false }
        if let index = action.tabIndex { return presentation.visibleTabs.indices.contains(index) }
        switch action {
        case .findInPane, .findNext, .findPrevious, .clearPane: return model.activeTerminal != nil
        // ⌘↑/⌘↓ stay text navigation while a field (rename, search) is editing.
        case .previousPrompt, .nextPrompt: return model.activeTerminal != nil && !(window?.firstResponder is NSText)
        case .splitLeftRight, .splitTopBottom:
            return presentation.activePane != nil && presentation.selectedTab.map { model.maximizedPanes[$0.id] == nil } == true
        case .closePane, .maximizePane, .focusLeft, .focusRight, .focusUp, .focusDown,
            .resizeLeft, .resizeRight, .resizeUp, .resizeDown:
            return presentation.activePane != nil
        case .nextSpace, .previousSpace: return model.snapshot.spaces.count > 1
        case .nextTab, .previousTab: return presentation.visibleTabs.count > 1
        default: return presentation.selectedSpace != nil || action == .newTab
        }
    }

    @objc private func newSpace() {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        Task { await model.createSpace() }
    }
    @objc private func selectAllText(_ sender: Any?) {
        if !NSApp.sendAction(NSSelectorFromString("selectAllTerminalText:"), to: nil, from: sender) {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: sender)
        }
    }
    private static func sidebarToggleTitle(_ view: SidebarView, visible: Bool) -> String {
        switch view {
        case .files: visible ? L("Hide Files") : L("Show Files")
        case .changes: visible ? L("Hide Changes") : L("Show Changes")
        case .scratchpad: visible ? L("Hide Scratchpad") : L("Show Scratchpad")
        case .tasks: visible ? L("Hide Tasks") : L("Show Tasks")
        case .agents: visible ? L("Hide Agents") : L("Show Agents")
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performShortcut(_:)) {
            guard let raw = menuItem.representedObject as? String, let action = ShortcutAction(rawValue: raw) else { return false }
            if action == .toggleSidebar { menuItem.title = model.sidebarCollapsed ? L("Show Sidebar") : L("Hide Sidebar") }
            if let view = SidebarView(shortcut: action) { menuItem.title = Self.sidebarToggleTitle(view, visible: model.visibleSidebarView == view) }
            return validateShortcut(action)
        }
        if menuItem.action == #selector(checkForUpdatesAction) { return updater?.canCheckForUpdates ?? false }
        if menuItem.action == #selector(welcomeTourAction) { return model.canOpenWelcomeTour && !model.welcomeTourVisible }
        guard menuItem.action == #selector(selectAllText(_:)) else { return true }
        return NSApp.target(forAction: NSSelectorFromString("selectAllTerminalText:")) != nil
            || NSApp.target(forAction: #selector(NSText.selectAll(_:))) != nil
    }
    private func selectRelativeSpace(_ offset: Int) {
        let spaces = model.snapshot.spaces
        guard let id = model.snapshot.activeSpaceID, let index = spaces.firstIndex(where: { $0.id == id }), !spaces.isEmpty else { return }
        let next = spaces[(index + offset + spaces.count) % spaces.count].id
        Task { await model.selectSpace(next) }
    }
    private func selectRelativeTab(_ offset: Int) {
        let tabs = model.presentation.visibleTabs
        guard let id = model.presentation.selectedTab?.id, let index = tabs.firstIndex(where: { $0.id == id }), !tabs.isEmpty else { return }
        let next = tabs[(index + offset + tabs.count) % tabs.count].id
        Task { await model.selectTab(next) }
    }

    private func setWindowTranslucent(_ translucent: Bool) {
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : .windowBackgroundColor
        // A clear window draws the title bar's separator as a solid black seam, even with the style set to none, so
        // the title bar is drawn by the root view instead, as chrome with the same border as the rest (FR-TH10).
        window.titlebarSeparatorStyle = translucent ? .none : .automatic
        window.titlebarAppearsTransparent = translucent
        if translucent { window.styleMask.insert(.fullSizeContentView) } else { window.styleMask.remove(.fullSizeContentView) }
        window.invalidateShadow()
    }
    private func syncAccessibilityDisplayOptions() {
        let workspace = NSWorkspace.shared
        model.accessibilityDisplayOptionsDidChange(
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast, reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency)
    }
    @objc private func aboutAction() {
        // One sentence for translators; the license and owner names are linked where they land in it.
        let license = "MIT License", owner = "bearstouch"
        let credits = NSMutableAttributedString(
            string: L("Released under the %1$@.\n\n© 2026 %2$@ and Trellis contributors. All rights reserved.", license, owner), attributes: [.font: NSFont.systemFont(ofSize: 12)])
        // The standard Copyright option is plain text, so the linked copyright line lives in the credits.
        for (name, link) in [(license, "https://github.com/bearstouch/trellis/blob/master/LICENSE"), (owner, "https://github.com/bearstouch")] {
            let range = (credits.string as NSString).range(of: name)
            if range.location != NSNotFound { credits.addAttribute(.link, value: URL(string: link)!, range: range) }
        }
        let centered = NSMutableParagraphStyle(); centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Trellis",
            .applicationIcon: NSApp.applicationIconImage!,
            .applicationVersion: AppVersion.bundled ?? L("Development"),
            .version: "",
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "",
            .credits: credits
        ])
    }

    @objc private func settingsAction() { showSettings() }
    @objc private func checkForUpdatesAction() { updates?.checkNow() }
    @objc private func welcomeTourAction() {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        model.openWelcomeTour()
    }

    @objc private func installCommandLineToolAction() { Task { await cliInstall?.install(window: window) } }
    /// Explicit, previewed diagnostics; nothing is written on Cancel.
    @objc private func exportDiagnostics() {
        let exporter = DiagnosticsExporter(model: model, hosts: hosts, grants: grants) { [control] in control.isRunning }
        Task {
            await exporter.export(
                present: { [weak self] text in
                    guard let self else { return nil }
                    return await withCheckedContinuation { continuation in
                        // The continuation body runs synchronously on the calling main actor.
                        MainActor.assumeIsolated {
                            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
                            sheet.isReleasedWhenClosed = false
                            var resumed = false
                            @MainActor func finish(_ url: URL?) {
                                guard !resumed else { return }
                                resumed = true
                                self.window.endSheet(sheet)
                                continuation.resume(returning: url)
                            }
                            sheet.contentView = NSHostingView(
                                rootView: DiagnosticsPreviewView(
                                    text: text,
                                    save: {
                                        let panel = NSSavePanel()
                                        panel.nameFieldStringValue = "Trellis Diagnostics.txt"
                                        finish(panel.runModal() == .OK ? panel.url : nil)
                                    },
                                    cancel: { finish(nil) }))
                            self.window.beginSheet(sheet, completionHandler: nil)
                        }
                    }
                },
                write: { data, url in
                    try data.write(to: url, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                })
        }
    }

    /// Writes a portable export of projects and saved hosts (FR-R02); credentials and runtime state are never included.
    @objc private func exportProjectsAndHosts() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Trellis Projects & Hosts.trellis.json"
        panel.message = L("Exports your projects and saved hosts. No output, passwords, keys, tokens, or open spaces are included.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let transfer = PortableTransfer(hosts: hosts, projects: projects)
        Task {
            let data = await transfer.exportData()
            do {
                try data.write(to: url, options: .atomic)
                // Exports hold no secrets, but stay owner-only like other Trellis files.
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { model.errorMessage = L("The export could not be written. Check the location and try again.") }
        }
    }

    @objc private func importProjectsAndHosts() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = L("Choose a Trellis export to review before importing.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let transfer = PortableTransfer(hosts: hosts, projects: projects)
        let parent: NSWindow? = window
        Task { [weak parent] in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { model.errorMessage = L("The file could not be read."); return }
            switch await transfer.preview(data) {
            case .failure(let error): model.errorMessage = error.message
            case .success(let (parsed, preview)):
                let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
                sheet.isReleasedWhenClosed = false
                sheet.contentView = NSHostingView(
                    rootView: ImportPreviewView(transfer: transfer, parsed: parsed, preview: preview) { [weak parent, weak sheet] in
                        guard let sheet else { return }
                        parent?.endSheet(sheet)
                    })
                parent?.beginSheet(sheet, completionHandler: nil)
            }
        }
    }

    private func showHosts() {
        if hostsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = L("Hosts")
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: HostLibraryView(model: hosts, workspace: model))
            panel.center()
            hostsWindow = panel
        }
        hostsWindow?.makeKeyAndOrderFront(nil)
    }
    /// The project library (FR-PL01). Closing it with unsaved changes asks first.
    private func showProjects() {
        if projectsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = L("Projects")
            panel.contentMinSize = NSSize(width: 900, height: 600)
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: ProjectLibraryView(model: projects, workspace: model))
            panel.center()
            projectsWindow = panel
        }
        projectsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showSettings() {
        if settingsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = L("Settings")
            panel.contentMinSize = NSSize(width: 860, height: 620)
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: AppSettingsView(model: model, grants: grants, hosts: hosts, updates: updates))
            settingsCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.cancelThemePreview() }
            }
            panel.center()
            settingsWindow = panel
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func constrainWindow() {
        guard let window else { return }
        let rect = window.frame
        let clamped = WindowRectangle(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height).constrained(
            to: NSScreen.screens.map {
                let frame = $0.visibleFrame
                return WindowRectangle(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
            })
        window.setFrame(NSRect(x: clamped.x, y: clamped.y, width: clamped.width, height: clamped.height), display: true)
    }
    // The projects window shares this delegate; only the workspace window's frame is saved.
    func windowDidMove(_ notification: Notification) { if notification.object as? NSWindow === window { saveGeometry() } }
    func windowDidResize(_ notification: Notification) { if notification.object as? NSWindow === window { saveGeometry() } }
    private func saveGeometry() { if let window { model.updateWindowFrame(NSStringFromRect(window.frame)) } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === projectsWindow {
            guard projects.editorDirty else { return true }
            let alert = NSAlert()
            alert.messageText = L("Save changes to the project?")
            alert.informativeText = L("Your changes to the project aren't saved.")
            alert.addButton(withTitle: L("Save"))
            alert.addButton(withTitle: L("Cancel"))
            alert.addButton(withTitle: L("Discard Changes"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: projects.requestSave { [weak sender] in sender?.close() }; return false
            case .alertThirdButtonReturn: projects.discardEditor(); return true
            default: return false
            }
        }
        guard !closingWindow, !terminationPending else { return false }
        // MAC-04: sessions are kept by default, so closing the window just hides it; the Dock icon reopens it.
        if model.windowCloseAction == .hide { sender.orderOut(nil); return false }
        guard confirmSessionClosure() else { return false }
        closingWindow = true
        startupTask?.cancel()
        model.stopAll()
        Task {
            let closed = await model.endSessionsForWindowClose()
            if closed, !terminationPending { window.orderOut(nil) }
            closingWindow = false
        }
        return false
    }

    private func confirmSessionClosure() -> Bool {
        model.confirmAllSessionClosure()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        guard !closingWindow else { return .terminateCancel }
        let choice = model.confirmQuit()
        guard choice != .cancel else { return .terminateCancel }
        terminationPending = true
        startupTask?.cancel()
        if choice == .keepRunning {
            // FR-R03: broker sessions get no signal; only sessions outside the broker close.
            Task {
                let saved = await model.detachForQuit()
                if !saved { terminationPending = false; model.cancelShutdown() }
                NSApp.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        }
        // Gate pending UI operations before yielding, including launches that
        // are waiting for the shared command store rather than a live PTY.
        model.stopAll()
        Task {
            let closed = await model.shutdown()
            if closed { await model.saveScrollback() }
            let saved = closed ? await model.flushWorkspaceSave() : false
            if !saved { terminationPending = false; model.cancelShutdown() }
            NSApp.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }

}

@main
struct TrellisMain {
    @MainActor static func main() {
        // A peer (broker, askpass helper, control client) that closes first must fail a write, never kill the app;
        // `trellis_spawn_*` restore the default disposition in every child.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        NativeTerminalFont.registerBundledFonts()
        do {
            let stateDirectory = LaunchStateDirectory.resolve(arguments: CommandLine.arguments, temporaryDirectory: FileManager.default.temporaryDirectory)
            // Keyed by the state directory too: a launch for another workspace must not just activate this one.
            let identity = AppInstanceIdentity(bundleIdentifier: Bundle.main.bundleIdentifier, stateDirectory: stateDirectory)
            let lockURL = identity.lockURL(in: FileManager.default.temporaryDirectory)
            let instanceLock: ApplicationInstanceLock
            switch try ApplicationInstanceLock.acquire(at: lockURL) {
            case .acquired(let lock): instanceLock = lock
            case .alreadyRunning(let pid):
                if let pid { NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows]) }
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name(identity.activationNotification), object: nil,
                    userInfo: nil, deliverImmediately: true)
                return
            }
            defer { withExtendedLifetime(instanceLock) {} }
            if !identity.isDevelopment {
                ApplicationSupportLocation.migratePreferences(
                    into: .standard, legacy: UserDefaults.standard.persistentDomain(forName: AppInstanceIdentity.legacyProduction))
            }
            let directory: URL
            if let stateDirectory {
                directory = stateDirectory
            } else {
                directory = try ApplicationSupportLocation.prepare(
                    root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                    bundleIdentifier: identity.identifier, isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })
            }
            // A single writer per workspace folder, whatever path or lock key led here.
            let workspaceLock: ApplicationInstanceLock
            switch try ApplicationInstanceLock.acquire(stateDirectory: directory) {
            case .acquired(let lock): workspaceLock = lock
            case .alreadyRunning(let pid):
                if let pid { NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows]) }
                return
            }
            defer { withExtendedLifetime(workspaceLock) {} }
            let model = AppWorkspaceModel(
                store: try WorkspaceStore(), persistence: WorkspacePersistence(directory: directory),
                themeLibrary: ThemeLibrary(directory: directory.appendingPathComponent("Themes", isDirectory: true)))
            // --renderer metal|coregraphics picks the renderer for this launch only, for benchmarks (FR-TX05).
            if let index = CommandLine.arguments.firstIndex(of: "--renderer"), CommandLine.arguments.indices.contains(index + 1) {
                switch CommandLine.arguments[index + 1] {
                case "metal": model.rendererOverride = true
                case "coregraphics": model.rendererOverride = false
                default: break
                }
            }
            if model.rendererOverride == true { NativeTerminal.prepareGPURendering() }
            // FR-LN01: System follows the Mac's language list; --language en|pt-PT|fr|es picks one for this launch only.
            model.systemLanguages = { Locale.preferredLanguages }
            if let index = CommandLine.arguments.firstIndex(of: "--language"), CommandLine.arguments.indices.contains(index + 1) {
                model.languageOverride = AppLanguage.translated.first { $0.rawValue.lowercased() == CommandLine.arguments[index + 1].lowercased() }
            }
            // FR-R03: a broker is started only when a session is started with Keep Running on; one left by an
            // earlier run is always looked for at launch.
            if let helper = AppDelegate.helperPath(BrokerSessionClient.helperName), let client = BrokerSessionClient.currentExecutable() {
                model.sessionBroker = BrokerSessionClient(stateDirectory: directory, helperPath: helper, clientPath: client)
            }
            // FR-AG01: the user's own agent definitions sit beside the theme library.
            model.agentsDirectory = directory.appendingPathComponent("Agents", isDirectory: true)
            model.reloadAgentCatalog()
            model.directoryHistory = DirectoryHistory(stateDirectory: directory)  // FR-DJ09
            let hosts = HostListModel(library: HostLibrary(storage: HostFileStorage(directory: directory), secrets: KeychainHostSecretStore()))
            // FR-RW17: the Linux helpers ship in Resources/remote (scripts/build-remote-helpers.sh); macOS hosts get the bundled broker.
            hosts.remote = RemoteHostsModel(
                settings: RemoteHostSettings(stateDirectory: directory),
                catalog: RemoteArtifactCatalog.load(
                    remoteDirectory: AppDelegate.helperDirectory("remote"), macHelper: AppDelegate.helperPath(BrokerSessionClient.helperName)),
                clientID: try? RemoteClientIdentity.load(stateDirectory: directory))
            let grantStore = GrantStore(url: directory.appendingPathComponent("grants.json"), secrets: KeychainGrantSecretStore())
            let instanceID = UUID()
            let events = EventHub(instanceID: instanceID, grants: grantStore)
            let handler = AuthorizingControlHandler(
                grants: grantStore, domain: AutomationService(model: model, hosts: hosts, instanceID: instanceID), events: events)
            let control = ControlServer(endpoint: ControlEndpoint(stateDirectory: directory), handler: handler, instanceID: instanceID)
            let mcp = MCPServer(handler: handler, serverVersion: AppVersion.bundled ?? "development")
            let forwarder = EventForwarder(hub: events, instanceID: instanceID)
            model.onWorkspaceEvents = { forwarder.send(.metadata($0)) }
            // Appearance is global; the hub gates it on theme.read, not window scope.
            let appearanceResource = UUID(uuidString: "00000000-0000-0000-0000-00000000A99E")!
            model.onAppearanceChanged = { [weak model] in
                guard let model else { return }
                let settings = model.appearance
                forwarder.send(
                    .metadata([
                        WorkspaceEvent(
                            type: "appearance.changed", resourceID: appearanceResource, spaceID: nil,
                            data: [
                                "mode": settings.chromeMode.rawValue, "lightThemeId": settings.lightThemeID, "darkThemeId": settings.darkThemeID,
                                "effectiveThemeId": model.effectiveTheme.id, "revision": String(model.appearanceRevision)
                            ])
                    ]))
            }
            model.onSessionOutput = { [weak model] session, pane, data, next in
                let space = model?.snapshot.panes[pane].flatMap { model?.snapshot.tabs[$0.tabID]?.spaceID }
                forwarder.send(.output(session: session, space: space, data: data, next: next))
            }
            Task {
                await events.setDelivery { connection, data in control.push(data, to: connection) }
                // Once only: an early client may already have loaded (and since changed) the grants.
                await grantStore.ensureLoaded()
                // Revocation disconnects clients and ends their subscriptions at once.
                await grantStore.onRevocation { grantID in
                    Task {
                        await events.removeGrant(grantID)
                        await mcp.closeSessions(grantID: grantID)
                        control.closeConnections(await handler.connections(for: grantID))
                    }
                }
            }
            let projects = ProjectListModel(library: ProjectLibrary(storage: ProjectFileStorage(directory: directory)))
            let delegate = AppDelegate(
                model: model, hosts: hosts, projects: projects, control: control, mcp: mcp, grants: GrantListModel(store: grantStore), identity: identity)
            app.delegate = delegate
            app.run()
            withExtendedLifetime(delegate) {}
        } catch {
            let alert = NSAlert(); alert.messageText = L("Trellis could not initialize its workspace.")
            alert.runModal()
        }
    }
}
