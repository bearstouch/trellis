import AppKit
import SwiftUI
import TrellisCore
import TrellisUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let model: AppWorkspaceModel
    private var window: NSWindow!
    private var settingsWindow: NSWindow?
    private var terminationPending = false
    private var closingWindow = false
    private var startupTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var appearanceObserver: NSKeyValueObservation?
    private var settingsCloseObserver: NSObjectProtocol?

    init(model: AppWorkspaceModel) { self.model = model }

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
        buildMenus()
        model.openSettings = { [weak self] in self?.showSettings() }
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
            let restored = await model.loadWorkspace()
            await model.refresh()
            guard !Task.isCancelled else { return }
            if !restored, model.snapshot.windows.isEmpty {
                await model.createWindow(name: "Terminal", fixture: CommandLine.arguments.contains("--fixture"))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenus() {
        let menu = NSMenu()
        let app = NSMenuItem(); app.submenu = NSMenu(title: "Trellis")
        app.submenu?.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: ",")
        app.submenu?.addItem(.separator())
        app.submenu?.addItem(withTitle: "Hide Trellis", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.submenu?.addItem(withTitle: "Quit Trellis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)
        let file = NSMenuItem(); file.submenu = NSMenu(title: "File")
        file.submenu?.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n")
        file.submenu?.addItem(withTitle: "Save Workspace", action: #selector(saveWorkspace), keyEquivalent: "s")
        file.submenu?.addItem(withTitle: "New Tab", action: #selector(newTab), keyEquivalent: "t")
        file.submenu?.addItem(withTitle: "Rename Tab…", action: #selector(renameTab), keyEquivalent: "")
        file.submenu?.addItem(withTitle: "Next Tab", action: #selector(nextTab), keyEquivalent: "]").keyEquivalentModifierMask = [.command, .shift]
        file.submenu?.addItem(withTitle: "Previous Tab", action: #selector(previousTab), keyEquivalent: "[").keyEquivalentModifierMask = [.command, .shift]
        file.submenu?.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(file)
        let edit = NSMenuItem(); edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: "Copy All Retained Text", action: NSSelectorFromString("copyAllRetainedText:"), keyEquivalent: "")
        edit.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu?.addItem(withTitle: "Paste Escaped Path", action: NSSelectorFromString("pasteEscapedPath:"), keyEquivalent: "")
        edit.submenu?.addItem(withTitle: "Select All", action: #selector(selectAllText(_:)), keyEquivalent: "a")
        edit.submenu?.addItem(.separator())
        edit.submenu?.addItem(withTitle: "Find in Pane…", action: #selector(showPaneSearch), keyEquivalent: "f")
        edit.submenu?.addItem(withTitle: "Find Next", action: #selector(findNextInPane), keyEquivalent: "g")
        edit.submenu?.addItem(withTitle: "Find Previous", action: #selector(findPreviousInPane), keyEquivalent: "g").keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(edit)
        let view = NSMenuItem(); view.submenu = NSMenu(title: "View")
        view.submenu?.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+")
        // Also accept the unshifted key on keyboards where '+' shares '='.
        let zoomAlias = NSMenuItem(title: "Zoom In", action: #selector(zoomIn), keyEquivalent: "=")
        zoomAlias.isHidden = true
        zoomAlias.allowsKeyEquivalentWhenHidden = true
        view.submenu?.addItem(zoomAlias)
        view.submenu?.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        view.submenu?.addItem(withTitle: "Actual Size", action: #selector(actualSize), keyEquivalent: "0")
        menu.addItem(view)
        let panes = NSMenuItem(); panes.submenu = NSMenu(title: "Pane")
        for direction in PaneDirection.allCases {
            let item = NSMenuItem(title: "Focus \(direction.rawValue.capitalized)", action: #selector(focusPane(_:)), keyEquivalent: arrowKey(direction))
            item.representedObject = direction.rawValue
            item.keyEquivalentModifierMask = [.command, .option]
            panes.submenu?.addItem(item)
            let resize = NSMenuItem(title: "Move Divider \(direction.rawValue.capitalized)", action: #selector(resizePane(_:)), keyEquivalent: arrowKey(direction))
            resize.representedObject = direction.rawValue
            resize.keyEquivalentModifierMask = [.command, .option, .shift]
            panes.submenu?.addItem(resize)
        }
        panes.submenu?.addItem(.separator())
        panes.submenu?.addItem(withTitle: "Maximize / Restore Pane", action: #selector(maximizePane), keyEquivalent: "\r").keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(panes)
        let windows = NSMenuItem(); windows.submenu = NSMenu(title: "Window")
        windows.submenu?.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.submenu?.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.submenu?.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        menu.addItem(windows)
        NSApp.windowsMenu = windows.submenu
        NSApp.mainMenu = menu
    }

    @objc private func newWindow() {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        Task { await model.createWindow() }
    }
    @objc private func saveWorkspace() { Task { await model.flushWorkspaceSave() } }
    @objc private func selectAllText(_ sender: Any?) {
        if !NSApp.sendAction(NSSelectorFromString("selectAllTerminalText:"), to: nil, from: sender) {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: sender)
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if [#selector(showPaneSearch), #selector(findNextInPane), #selector(findPreviousInPane)].contains(menuItem.action) {
            return window?.isKeyWindow == true && model.activeTerminal != nil
        }
        guard menuItem.action == #selector(selectAllText(_:)) else { return true }
        return NSApp.target(forAction: NSSelectorFromString("selectAllTerminalText:")) != nil
            || NSApp.target(forAction: #selector(NSText.selectAll(_:))) != nil
    }
    @objc private func showPaneSearch() { if window?.isKeyWindow == true { model.activeTerminal?.showSearch() } }
    @objc private func findNextInPane() { if window?.isKeyWindow == true { model.activeTerminal?.findInPane() } }
    @objc private func findPreviousInPane() { if window?.isKeyWindow == true { model.activeTerminal?.findInPane(forward: false) } }
    @objc private func newTab() { Task { await model.createTab() } }
    @objc private func zoomIn() { model.zoomTerminalFont(by: 1) }
    @objc private func zoomOut() { model.zoomTerminalFont(by: -1) }
    @objc private func actualSize() { model.zoomTerminalFont(by: 0, reset: true) }
    @objc private func renameTab() { model.tabRenameRequest = UUID() }
    @objc private func nextTab() { selectRelativeTab(1) }
    @objc private func previousTab() { selectRelativeTab(-1) }
    private func selectRelativeTab(_ offset: Int) {
        let tabs = model.presentation.visibleTabs
        guard let id = model.presentation.selectedTab?.id, let index = tabs.firstIndex(where: { $0.id == id }), !tabs.isEmpty else { return }
        let next = tabs[(index + offset + tabs.count) % tabs.count].id
        Task { await model.selectTab(next) }
    }
    private func arrowKey(_ direction: PaneDirection) -> String {
        let code: Int
        switch direction {
        case .left: code = NSLeftArrowFunctionKey;
        case .right: code = NSRightArrowFunctionKey;
        case .up: code = NSUpArrowFunctionKey;
        case .down: code = NSDownArrowFunctionKey
        }
        return String(UnicodeScalar(code)!)
    }
    @objc private func focusPane(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let direction = PaneDirection(rawValue: raw) else { return }
        Task { await model.focusPane(direction) }
    }
    @objc private func resizePane(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let direction = PaneDirection(rawValue: raw) else { return }
        Task { await model.resizeFocusedPane(direction) }
    }
    @objc private func maximizePane() {
        guard let id = model.presentation.activePane?.id else { return }
        Task { await model.toggleMaximize(id) }
    }
    @objc private func settingsAction() { showSettings() }
    private func showSettings() {
        if settingsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 490), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Settings"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: AppSettingsView(model: model))
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
            let delegate = AppDelegate(model: model)
            app.delegate = delegate
            app.run()
            withExtendedLifetime(delegate) {}
        } catch {
            let alert = NSAlert(); alert.messageText = "Trellis could not initialize its workspace."
            alert.runModal()
        }
    }
}
