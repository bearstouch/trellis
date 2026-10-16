import AppKit
import UTermTerminal

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let terminal = NativeTerminal()
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.appearance = NSAppearance(named: .aqua)
        let appMenu = NSMenu()
        let item = NSMenuItem()
        item.submenu = NSMenu(title: "uTerm")
        item.submenu?.addItem(withTitle: "Quit uTerm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(item)
        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu?.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        appMenu.addItem(edit)
        NSApp.mainMenu = appMenu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "uTerm — terminal feasibility"
        window.minSize = NSSize(width: 480, height: 240)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = terminal.view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal.view)
        terminal.onInputError = { [weak self] error in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "Terminal input could not be sent"
            alert.informativeText = "The session may have closed or the input queue may be full. Try a smaller paste after the session responds. (\(error))"
            alert.beginSheetModal(for: self.window)
        }
        terminal.onExit = { [weak self] code in
            guard let self else { return }
            self.window.title = "uTerm — exited (\(code.map(String.init) ?? "unknown"))"
            if self.terminationPending { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        terminal.start(fixture: CommandLine.arguments.contains("--fixture"))
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminal.isRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Close this terminal session?"
        alert.informativeText = "The local shell and its attached processes will stop."
        alert.addButton(withTitle: "Close Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        guard terminal.isRunning else { return .terminateNow }
        terminationPending = true
        terminal.adapter.detach()
        return .terminateLater
    }
}

@main
struct UTermMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
