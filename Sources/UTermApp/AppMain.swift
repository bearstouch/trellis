import AppKit
import SwiftUI
import UTermCore
import UTermUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model: AppWorkspaceModel
    private var window: NSWindow!
    private var settingsWindow: NSWindow?
    private var terminationPending = false
    private var closingWindow = false
    private var startupTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    init(model: AppWorkspaceModel) { self.model = model }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.appearance = NSAppearance(named: .aqua)
        buildMenus()
        model.openSettings = { [weak self] in self?.showSettings() }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "uTerm"
        window.minSize = NSSize(width: 400, height: 260)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceRootView(model: model))
        if let saved = UserDefaults.standard.string(forKey: "app.windowFrame") { window.setFrame(NSRectFromString(saved), display: false) }
        else { window.center() }
        constrainWindow()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.constrainWindow() }
        }
        window.makeKeyAndOrderFront(nil)
        startupTask = Task {
            await model.refresh()
            guard !Task.isCancelled else { return }
            if model.snapshot.windows.isEmpty {
                await model.createWindow(name: "Terminal", fixture: CommandLine.arguments.contains("--fixture"))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenus() {
        let menu = NSMenu()
        let app = NSMenuItem(); app.submenu = NSMenu(title: "uTerm")
        app.submenu?.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: ",")
        app.submenu?.addItem(.separator())
        app.submenu?.addItem(withTitle: "Hide uTerm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.submenu?.addItem(withTitle: "Quit uTerm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)
        let file = NSMenuItem(); file.submenu = NSMenu(title: "File")
        file.submenu?.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n")
        file.submenu?.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(file)
        let edit = NSMenuItem(); edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu?.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(edit)
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
    @objc private func settingsAction() { showSettings() }
    private func showSettings() {
        if settingsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 230), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Settings"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: LaunchSettingsView(model: model))
            panel.center()
            settingsWindow = panel
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func constrainWindow() {
        guard let window else { return }
        let rect = window.frame
        let clamped = WindowRectangle(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height).constrained(to: NSScreen.screens.map {
            let frame = $0.visibleFrame
            return WindowRectangle(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        })
        window.setFrame(NSRect(x: clamped.x, y: clamped.y, width: clamped.width, height: clamped.height), display: true)
    }
    func windowDidMove(_ notification: Notification) { saveGeometry() }
    func windowDidResize(_ notification: Notification) { saveGeometry() }
    private func saveGeometry() { if let window { UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "app.windowFrame") } }
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
            await model.closeAllWorkspaces()
            if !terminationPending { window.orderOut(nil) }
            closingWindow = false
        }
        return false
    }

    private func confirmSessionClosure() -> Bool {
        guard !model.runningTerminals.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Close \(model.runningTerminals.count) terminal session(s)?"
        alert.informativeText = "Their local processes will stop."
        alert.addButton(withTitle: "Close Sessions")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        guard closingWindow || confirmSessionClosure() else { return .terminateCancel }
        terminationPending = true
        startupTask?.cancel()
        // Gate pending UI operations before yielding, including launches that
        // are waiting for the shared command store rather than a live PTY.
        model.stopAll()
        Task {
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

}

@main
struct UTermMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        do {
            let model = AppWorkspaceModel(store: try WorkspaceStore())
            let delegate = AppDelegate(model: model)
            app.delegate = delegate
            app.run()
            withExtendedLifetime(delegate) {}
        } catch {
            let alert = NSAlert(); alert.messageText = "uTerm could not initialize its workspace."
            alert.runModal()
        }
    }
}
