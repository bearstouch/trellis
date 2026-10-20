import AppKit
import UniformTypeIdentifiers
import SwiftUI
import TrellisControl
import TrellisCore
import TrellisMCP
import TrellisTerminal
import TrellisUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let model: AppWorkspaceModel
    private let hosts: HostListModel
    private var hostsWindow: NSWindow?
    private let control: ControlServer
    private let mcp: MCPServer
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

    private let identity: AppInstanceIdentity

    init(model: AppWorkspaceModel, hosts: HostListModel, control: ControlServer, mcp: MCPServer, grants: GrantListModel, identity: AppInstanceIdentity) {
        self.model = model; self.hosts = hosts; self.control = control; self.mcp = mcp; self.grants = grants; self.identity = identity
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
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAccessibilityDisplayOptions() }
        }
        buildMenus()
        model.onKeyboardSettingsChanged = { [weak self] in self?.buildMenus() }
        model.openSettings = { [weak self] in self?.showSettings() }
        // Restored or applied settings (re)start the MCP server; fixture and --no-mcp launches never listen.
        let mcpBlocked = CommandLine.arguments.contains("--no-mcp") || CommandLine.arguments.contains("--fixture")
        model.onRemoteControlSettingsChanged = { [weak self] settings in
            guard let self else { return }
            if mcpBlocked, settings.mcpEnabled {
                mcp.stop()
                model.remoteControlStatus = .failed(reason: "Turned off for this launch (--no-mcp or --fixture).")
            } else {
                model.remoteControlStatus = mcp.apply(settings)
            }
        }
        model.openHosts = { [weak self] in self?.showHosts() }
        model.resolveHost = { [hosts] id in await hosts.host(id) }
        if let helper = Self.helperPath(AskpassBroker.helperName) {
            model.askpass = AskpassBroker(helperPath: helper)
            let library = hosts.library, gate = LocalAuthenticationGate()
            hosts.userPresence = gate
            model.savedPassword = { id, revision in await library.password(hostID: id, connectionRevision: revision, gate: gate) }
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
        startupTask = Task {
            // Saved-host panes resolve their host when started, so load hosts first.
            await hosts.load()
            let restored = await model.loadWorkspace()
            await model.refresh()
            guard !Task.isCancelled else { return }
            if !restored, model.snapshot.windows.isEmpty {
                await model.createWindow(name: "Terminal", fixture: CommandLine.arguments.contains("--fixture"))
            }
        }
        // Local automation is optional: an unsafe endpoint leaves the app
        // fully usable without a control socket.
        _ = try? control.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) { control.stop(); mcp.stop(); model.askpass?.stop() }

    /// Bundled in Contents/Helpers; `swift run` builds it beside the app binary.
    static func helperPath(_ name: String) -> String? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)"),
            executable.deletingLastPathComponent().appendingPathComponent(name)
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path
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
        let about = app.submenu?.addItem(withTitle: "About Trellis", action: #selector(aboutAction), keyEquivalent: "")
        about?.target = self
        app.submenu?.addItem(.separator())
        app.submenu?.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: ",")
        app.submenu?.addItem(.separator())
        app.submenu?.addItem(withTitle: "Hide Trellis", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.submenu?.addItem(withTitle: "Quit Trellis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)
        menu.addItem(
            submenu("File", [.newWindow, .newTab, nil, .renameTab, .renameWindow, nil, .closePane, .closeTab, .deleteWindow, nil, .showHosts, .saveWorkspace]))
        if let file = menu.items.last?.submenu {
            file.addItem(.separator())
            file.addItem(withTitle: "Export Workspace…", action: #selector(exportWorkspace), keyEquivalent: "")
            file.addItem(withTitle: "Import Workspace…", action: #selector(importWorkspace), keyEquivalent: "")
            file.addItem(.separator())
            file.addItem(withTitle: "Open Workspace File…", action: #selector(openWorkspaceFile), keyEquivalent: "")
            file.addItem(withTitle: "Save Window as Workspace File…", action: #selector(saveWorkspaceFile), keyEquivalent: "")
        }
        let edit = NSMenuItem(); edit.submenu = NSMenu(title: "Edit")
        // Undo/Cut/Redo exist for native text fields (tab names, search, settings);
        // the terminal does not implement them, so they stay disabled there.
        edit.submenu?.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.submenu?.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.submenu?.addItem(.separator())
        edit.submenu?.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: "Copy All Retained Text", action: NSSelectorFromString("copyAllRetainedText:"), keyEquivalent: "")
        edit.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu?.addItem(withTitle: "Paste Escaped Path", action: NSSelectorFromString("pasteEscapedPath:"), keyEquivalent: "")
        edit.submenu?.addItem(withTitle: "Select All", action: #selector(selectAllText(_:)), keyEquivalent: "a")
        edit.submenu?.addItem(.separator())
        for action in [ShortcutAction.findInPane, .findNext, .findPrevious] { edit.submenu?.addItem(item(action)) }
        edit.submenu?.addItem(.separator())
        for action in [ShortcutAction.previousPrompt, .nextPrompt] { edit.submenu?.addItem(item(action)) }
        edit.submenu?.addItem(.separator())
        edit.submenu?.addItem(item(.clearPane))
        menu.addItem(edit)
        let view = submenu("View", [.toggleSidebar, nil, .zoomIn, .zoomOut, .actualSize])
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
                "Pane",
                [
                    .splitLeftRight, .splitTopBottom, nil, .focusLeft, .focusRight, .focusUp, .focusDown, nil,
                    .resizeLeft, .resizeRight, .resizeUp, .resizeDown, nil, .maximizePane
                ]))
        let windows = submenu(
            "Window",
            [
                nil, .previousWindow, .nextWindow, .previousTab, .nextTab, nil,
                .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5, .selectTab6, .selectTab7, .selectTab8, .selectTab9
            ])
        windows.submenu?.insertItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "", at: 0)
        windows.submenu?.insertItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "", at: 0)
        windows.submenu?.insertItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m", at: 0)
        menu.addItem(windows)
        let help = NSMenuItem(); help.submenu = NSMenu(title: "Help")
        help.submenu?.addItem(withTitle: "Export Diagnostics…", action: #selector(exportDiagnostics), keyEquivalent: "")
        menu.addItem(help)
        NSApp.helpMenu = help.submenu
        NSApp.windowsMenu = windows.submenu
        NSApp.mainMenu = menu
    }

    @objc private func performShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = ShortcutAction(rawValue: raw) else { return }
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
        switch action {
        case .newWindow: newWindow()
        case .newTab: Task { await model.createTab() }
        case .renameTab: model.tabRenameRequest = UUID()
        case .renameWindow: model.windowRenameRequest = UUID()
        case .closePane: if let pane { Task { await model.closePane(pane) } }
        case .closeTab: if let tab = presentation.selectedTab?.id { Task { await model.closeTab(tab) } }
        case .deleteWindow: if let id = presentation.selectedWindow?.id { Task { await model.deleteWindow(id) } }
        case .saveWorkspace: Task { await model.flushWorkspaceSave() }
        case .showHosts: showHosts()
        case .findInPane: model.activeTerminal?.showSearch()
        case .findNext: model.activeTerminal?.findInPane()
        case .findPrevious: model.activeTerminal?.findInPane(forward: false)
        case .previousPrompt: model.activeTerminal?.scrollToPrompt(forward: false)
        case .nextPrompt: model.activeTerminal?.scrollToPrompt(forward: true)
        case .clearPane: model.activeTerminal?.clear()
        case .zoomIn: model.zoomTerminalFont(by: 1)
        case .zoomOut: model.zoomTerminalFont(by: -1)
        case .actualSize: model.zoomTerminalFont(by: 0, reset: true)
        case .toggleSidebar: model.toggleSidebar()
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
        case .nextWindow: selectRelativeWindow(1)
        case .previousWindow: selectRelativeWindow(-1)
        case .nextTab: selectRelativeTab(1)
        case .previousTab: selectRelativeTab(-1)
        default: break
        }
    }

    private func validateShortcut(_ action: ShortcutAction) -> Bool {
        let presentation = model.presentation
        if [.closePane, .closeTab].contains(action), let key = NSApp.keyWindow, key !== window { return true }
        if [.newWindow, .saveWorkspace, .showHosts, .zoomIn, .zoomOut, .actualSize].contains(action) { return true }
        // Workspace commands act on the main window only while it is key.
        guard window?.isKeyWindow == true else { return false }
        if action == .toggleSidebar { return true }
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
        case .nextWindow, .previousWindow: return model.snapshot.windows.count > 1
        case .nextTab, .previousTab: return presentation.visibleTabs.count > 1
        default: return presentation.selectedWindow != nil || action == .newTab
        }
    }

    @objc private func newWindow() {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        Task { await model.createWindow() }
    }
    @objc private func selectAllText(_ sender: Any?) {
        if !NSApp.sendAction(NSSelectorFromString("selectAllTerminalText:"), to: nil, from: sender) {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: sender)
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performShortcut(_:)) {
            guard let raw = menuItem.representedObject as? String, let action = ShortcutAction(rawValue: raw) else { return false }
            if action == .toggleSidebar { menuItem.title = model.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar" }
            return validateShortcut(action)
        }
        if menuItem.action == #selector(saveWorkspaceFile) { return model.snapshot.activeWindowID != nil }
        guard menuItem.action == #selector(selectAllText(_:)) else { return true }
        return NSApp.target(forAction: NSSelectorFromString("selectAllTerminalText:")) != nil
            || NSApp.target(forAction: #selector(NSText.selectAll(_:))) != nil
    }
    private func selectRelativeWindow(_ offset: Int) {
        let windows = model.snapshot.windows
        guard let id = model.snapshot.activeWindowID, let index = windows.firstIndex(where: { $0.id == id }), !windows.isEmpty else { return }
        let next = windows[(index + offset + windows.count) % windows.count].id
        Task { await model.selectWindow(next) }
    }
    private func selectRelativeTab(_ offset: Int) {
        let tabs = model.presentation.visibleTabs
        guard let id = model.presentation.selectedTab?.id, let index = tabs.firstIndex(where: { $0.id == id }), !tabs.isEmpty else { return }
        let next = tabs[(index + offset + tabs.count) % tabs.count].id
        Task { await model.selectTab(next) }
    }

    private func syncAccessibilityDisplayOptions() {
        let workspace = NSWorkspace.shared
        model.accessibilityDisplayOptionsDidChange(
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast, reduceMotion: workspace.accessibilityDisplayShouldReduceMotion)
    }
    @objc private func aboutAction() {
        let credits = NSMutableAttributedString(string: "Released under the ", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        credits.append(
            NSAttributedString(
                string: "MIT License",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .link: URL(string: "https://github.com/bearstouch/trellis/blob/master/LICENSE")!
                ]))
        credits.append(NSAttributedString(string: ".\n\n© 2026 ", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        // The standard Copyright option is plain text, so the linked copyright line lives in the credits.
        credits.append(NSAttributedString(string: "bearstouch", attributes: [.font: NSFont.systemFont(ofSize: 12), .link: URL(string: "https://github.com/bearstouch")!]))
        credits.append(NSAttributedString(string: " and Trellis contributors. All rights reserved.", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let centered = NSMutableParagraphStyle(); centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Trellis",
            .applicationIcon: NSApp.applicationIconImage!,
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
            .version: "",
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "",
            .credits: credits
        ])
    }

    @objc private func settingsAction() { showSettings() }
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

    /// Writes a portable export; credentials and runtime state are never included.
    @objc private func exportWorkspace() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Trellis Workspace.trellis.json"
        panel.message = "Exports windows, tabs, splits, and saved hosts. No output, passwords, keys, or tokens are included."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let transfer = PortableTransfer(model: model, hosts: hosts)
        Task {
            let (data, converted) = await transfer.exportData()
            do {
                try data.write(to: url, options: .atomic)
                // Exports hold no secrets, but stay owner-only like other Trellis files.
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                if converted > 0 { model.errorMessage = "\(converted) custom command pane(s) were exported as plain shells; their commands are never exported." }
            } catch { model.errorMessage = "The export could not be written. Check the location and try again." }
        }
    }

    /// A project's `.trellis/workspace.json` (FR-WF04); commands wait for review unless that exact file is trusted.
    @objc private func openWorkspaceFile() {
        Task { await model.beginOpenWorkspaceFile() }
    }

    @objc private func saveWorkspaceFile() {
        guard let id = model.snapshot.activeWindowID else { return }
        model.beginSaveWorkspaceFile(windowID: id)
    }

    @objc private func importWorkspace() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a Trellis export to review before importing."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let transfer = PortableTransfer(model: model, hosts: hosts)
        Task {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { model.errorMessage = "The file could not be read."; return }
            switch await transfer.preview(data) {
            case .failure(let error): model.errorMessage = error.message
            case .success(let (parsed, preview)):
                let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
                sheet.isReleasedWhenClosed = false
                sheet.contentView = NSHostingView(
                    rootView: ImportPreviewView(transfer: transfer, parsed: parsed, preview: preview) { [weak self, weak sheet] in
                        guard let sheet else { return }
                        self?.window.endSheet(sheet)
                    })
                window.beginSheet(sheet, completionHandler: nil)
            }
        }
    }

    private func showHosts() {
        if hostsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Hosts"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: HostLibraryView(model: hosts, workspace: model))
            panel.center()
            hostsWindow = panel
        }
        hostsWindow?.makeKeyAndOrderFront(nil)
    }
    private func showSettings() {
        if settingsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Settings"
            panel.contentMinSize = NSSize(width: 860, height: 620)
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: AppSettingsView(model: model, grants: grants, hosts: hosts))
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
    func windowDidMove(_ notification: Notification) { saveGeometry() }
    func windowDidResize(_ notification: Notification) { saveGeometry() }
    private func saveGeometry() { if let window { model.updateWindowFrame(NSStringFromRect(window.frame)) } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closingWindow, !terminationPending else { return false }
        guard confirmSessionClosure() else { return false }
        closingWindow = true
        startupTask?.cancel()
        model.stopAll()
        Task {
            let closed = await model.closeAllWorkspaces()
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
            let identity = AppInstanceIdentity(bundleIdentifier: Bundle.main.bundleIdentifier)
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
            if let index = CommandLine.arguments.firstIndex(of: "--state-directory"), CommandLine.arguments.indices.contains(index + 1) {
                directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            } else {
                directory = try ApplicationSupportLocation.prepare(
                    root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                    bundleIdentifier: identity.identifier)
            }
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
            // FR-R03: a broker is started only when a session is started with Keep Running on; one left by an
            // earlier run is always looked for at launch.
            if let helper = AppDelegate.helperPath(BrokerSessionClient.helperName), let client = BrokerSessionClient.currentExecutable() {
                model.sessionBroker = BrokerSessionClient(stateDirectory: directory, helperPath: helper, clientPath: client)
            }
            let hosts = HostListModel(library: HostLibrary(storage: HostFileStorage(directory: directory), secrets: KeychainHostSecretStore()))
            let grantStore = GrantStore(url: directory.appendingPathComponent("grants.json"), secrets: KeychainGrantSecretStore())
            let instanceID = UUID()
            let events = EventHub(instanceID: instanceID, grants: grantStore)
            let handler = AuthorizingControlHandler(
                grants: grantStore, domain: AutomationService(model: model, hosts: hosts, instanceID: instanceID), events: events)
            let control = ControlServer(endpoint: ControlEndpoint(stateDirectory: directory), handler: handler, instanceID: instanceID)
            let mcp = MCPServer(handler: handler, serverVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")
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
                            type: "appearance.changed", resourceID: appearanceResource, windowID: nil,
                            data: [
                                "mode": settings.chromeMode.rawValue, "lightThemeId": settings.lightThemeID, "darkThemeId": settings.darkThemeID,
                                "effectiveThemeId": model.effectiveTheme.id, "revision": String(model.appearanceRevision)
                            ])
                    ]))
            }
            model.onSessionOutput = { [weak model] session, pane, data, next in
                let window = model?.snapshot.panes[pane].flatMap { model?.snapshot.tabs[$0.tabID]?.windowID }
                forwarder.send(.output(session: session, window: window, data: data, next: next))
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
            let delegate = AppDelegate(model: model, hosts: hosts, control: control, mcp: mcp, grants: GrantListModel(store: grantStore), identity: identity)
            app.delegate = delegate
            app.run()
            withExtendedLifetime(delegate) {}
        } catch {
            let alert = NSAlert(); alert.messageText = "Trellis could not initialize its workspace."
            alert.runModal()
        }
    }
}
