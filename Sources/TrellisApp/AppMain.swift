import AppKit
import SwiftUI
import TrellisControl
import TrellisCore
import TrellisUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let model: AppWorkspaceModel
    private let hosts: HostListModel
    private var hostsWindow: NSWindow?
    private let control: ControlServer
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

    init(model: AppWorkspaceModel, hosts: HostListModel, control: ControlServer, grants: GrantListModel) {
        self.model = model; self.hosts = hosts; self.control = control; self.grants = grants
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        model.onChromeModeChanged = { mode in
            switch mode {
            case .light: NSApp.appearance = NSAppearance(named: .aqua)
            case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
            case .system: NSApp.appearance = nil
            }
        }
        model.onChromeModeChanged?(model.appearance.chromeMode)
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
        model.openHosts = { [weak self] in self?.showHosts() }
        model.resolveHost = { [hosts] id in await hosts.host(id) }
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
        // Local automation is optional: an unsafe endpoint or a second live
        // instance leaves the app fully usable without a control socket.
        _ = try? control.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) { control.stop() }

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
        app.submenu?.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: ",")
        app.submenu?.addItem(.separator())
        app.submenu?.addItem(withTitle: "Hide Trellis", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.submenu?.addItem(withTitle: "Quit Trellis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)
        menu.addItem(
            submenu("File", [.newWindow, .newTab, nil, .renameTab, .renameWindow, nil, .closePane, .closeTab, .deleteWindow, nil, .showHosts, .saveWorkspace]))
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
        menu.addItem(edit)
        let view = submenu("View", [.zoomIn, .zoomOut, .actualSize])
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
        case .zoomIn: model.zoomTerminalFont(by: 1)
        case .zoomOut: model.zoomTerminalFont(by: -1)
        case .actualSize: model.zoomTerminalFont(by: 0, reset: true)
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
        guard window?.isKeyWindow == true, !model.isRestoring, model.recoveryMessage == nil else { return false }
        if let index = action.tabIndex { return presentation.visibleTabs.indices.contains(index) }
        switch action {
        case .findInPane, .findNext, .findPrevious: return model.activeTerminal != nil
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
            return validateShortcut(action)
        }
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
    @objc private func settingsAction() { showSettings() }
    private func showHosts() {
        if hostsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Hosts"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: HostLibraryView(model: hosts))
            panel.center()
            hostsWindow = panel
        }
        hostsWindow?.makeKeyAndOrderFront(nil)
    }
    private func showSettings() {
        if settingsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 490), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Settings"
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
        guard !closingWindow, confirmSessionClosure() else { return .terminateCancel }
        terminationPending = true
        startupTask?.cancel()
        // Gate pending UI operations before yielding, including launches that
        // are waiting for the shared command store rather than a live PTY.
        model.stopAll()
        Task {
            let closed = await model.shutdown()
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
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        do {
            let directory: URL
            if let index = CommandLine.arguments.firstIndex(of: "--state-directory"), CommandLine.arguments.indices.contains(index + 1) {
                directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            } else {
                directory = try ApplicationSupportLocation.prepare(
                    root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                    bundleIdentifier: Bundle.main.bundleIdentifier)
            }
            let model = AppWorkspaceModel(
                store: try WorkspaceStore(), persistence: WorkspacePersistence(directory: directory),
                themeLibrary: ThemeLibrary(directory: directory.appendingPathComponent("Themes", isDirectory: true)))
            let hosts = HostListModel(library: HostLibrary(storage: HostFileStorage(directory: directory)))
            let grantStore = GrantStore(url: directory.appendingPathComponent("grants.json"), secrets: KeychainGrantSecretStore())
            let instanceID = UUID()
            let events = EventHub(instanceID: instanceID, grants: grantStore)
            let handler = AuthorizingControlHandler(
                grants: grantStore, domain: AutomationService(model: model, hosts: hosts, instanceID: instanceID), events: events)
            let control = ControlServer(endpoint: ControlEndpoint(stateDirectory: directory), handler: handler, instanceID: instanceID)
            let forwarder = EventForwarder(hub: events, instanceID: instanceID)
            model.onWorkspaceEvents = { forwarder.send(.metadata($0)) }
            model.onSessionOutput = { [weak model] session, pane, data, next in
                let window = model?.snapshot.panes[pane].flatMap { model?.snapshot.tabs[$0.tabID]?.windowID }
                forwarder.send(.output(session: session, window: window, data: data, next: next))
            }
            Task {
                await events.setDelivery { connection, data in control.push(data, to: connection) }
                await grantStore.load()
                // Revocation disconnects clients and ends their subscriptions at once.
                await grantStore.onRevocation { grantID in
                    Task {
                        await events.removeGrant(grantID)
                        control.closeConnections(await handler.connections(for: grantID))
                    }
                }
            }
            let delegate = AppDelegate(model: model, hosts: hosts, control: control, grants: GrantListModel(store: grantStore))
            app.delegate = delegate
            app.run()
            withExtendedLifetime(delegate) {}
        } catch {
            let alert = NSAlert(); alert.messageText = "Trellis could not initialize its workspace."
            alert.runModal()
        }
    }
}
