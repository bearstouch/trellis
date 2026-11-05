import AppKit
import TrellisCore
import TrellisRelease
import TrellisUI

/// The app's way to install the `trellis` command (MAC-15): one offer after install, and a menu item.
/// Both only ever create the one user-local link, after the user chooses to.
@MainActor
final class CLIInstallController {
    private static let answeredKey = "cli.linkOfferAnswered"
    private let bundlePath: String, cliPath: String, home: String
    private let isReadOnlyVolume: Bool
    private let shell: () -> String
    private let defaults: UserDefaults
    private var working = false

    /// Nil for development builds: their CLI isn't the one the docs install, and an unbundled build has none.
    init?(identity: AppInstanceIdentity, shell: @escaping () -> String, defaults: UserDefaults = .standard, home: String = NSHomeDirectory()) {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let cli = bundle.appendingPathComponent("Contents/Helpers/\(CLILinkPlanner.linkName)").path
        guard !identity.isDevelopment, bundle.pathExtension == "app", FileManager.default.isExecutableFile(atPath: cli) else { return nil }
        bundlePath = bundle.path; cliPath = cli; self.home = home; self.shell = shell; self.defaults = defaults
        isReadOnlyVolume = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
    }

    /// Asks once. A window that's busy, or a reason to skip, leaves the question for a later launch.
    func offerIfNeeded(window: NSWindow?) async {
        guard !defaults.bool(forKey: Self.answeredKey) else { return }
        switch CLILinkInstaller.offer(bundlePath: bundlePath, home: home, isReadOnlyVolume: isReadOnlyVolume, effects: .live) {
        case .skip: return
        case .alreadyInstalled: defaults.set(true, forKey: Self.answeredKey); return
        case .ask: break
        }
        guard let window, window.isVisible, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Install the trellis command?"
        alert.informativeText =
            "This lets you control Trellis from any terminal. It creates one link at ~/.local/bin/trellis and doesn't change your shell's startup files.\n\nYou can do this later with Trellis → Install Command Line Tool…"
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now").keyEquivalent = "\u{1b}"
        let response = await alert.beginSheetModal(for: window)
        defaults.set(true, forKey: Self.answeredKey)
        if response == .alertFirstButtonReturn { await install(window: window) }
    }

    /// How the tour's last step shows the offer (FR-ON07): only where the sheet would ask, or as already done.
    func tourStatus() -> WelcomeTourCLIStatus {
        switch CLILinkInstaller.offer(bundlePath: bundlePath, home: home, isReadOnlyVolume: isReadOnlyVolume, effects: .live) {
        case .ask: .available
        case .alreadyInstalled: .installed
        case .skip: .unavailable
        }
    }

    /// The tour showed the same offer. A launch where it couldn't (the DMG) leaves the question for a later one.
    func recordOfferAnswered() {
        if tourStatus() == .available { defaults.set(true, forKey: Self.answeredKey) }
    }

    func install(window: NSWindow?) async {
        guard !working else { return }
        working = true; defer { working = false }
        guard CLILinkInstaller.location(bundlePath: bundlePath, home: home, isReadOnlyVolume: isReadOnlyVolume) != .transient else {
            await show(
                "Move Trellis to Applications first",
                "Trellis is running from the disk image or a temporary location, so a link to it would stop working. Drag Trellis to Applications, open it from there, and try again.", window)
            return
        }
        defaults.set(true, forKey: Self.answeredKey)
        let link: String, already: Bool
        do {
            switch try CLILinkInstaller.install(home: home, cliPath: cliPath, effects: .live) {
            case .installed(let path), .replaced(let path): link = path; already = false
            case .alreadyInstalled(let path): link = path; already = true
            case .invalidDirectory(let reason), .conflict(let reason):
                await show("The trellis command wasn't installed", reason, window)
                return
            }
        } catch {
            await show("The trellis command wasn't installed", error.localizedDescription, window)
            return
        }
        let shell = shell()
        let searchPath = await Task.detached { LoginShellPath.query(shell: shell) }.value
        let title = already ? "The trellis command is already installed" : "The trellis command is installed"
        let setup = CLILinkInstaller.pathSetupCommand(shell: shell)
        switch CLILinkInstaller.pathStatus(link: link, searchPath: searchPath, effects: .live) {
        case .onPath: await show(title, "Open a new terminal to use it.\n\n\(link)", window)
        case .notOnPath:
            await show(
                title,
                "~/.local/bin isn't on your PATH yet, and Trellis doesn't change your shell's startup files. To add it, run this or add the equivalent to your shell's startup file, then open a new terminal:\n\n\(setup)",
                window, copy: setup)
        case .shadowed(let other):
            await show(title, "Typing trellis in a terminal runs a different program, because your PATH finds it first:\n\n\(other)\n\nThe Trellis command is at \(link).", window)
        case .unknown:
            await show(title, "Trellis couldn't read the PATH from your shell. If trellis isn't found in a new terminal, run this or add the equivalent to your shell's startup file:\n\n\(setup)", window, copy: setup)
        }
    }

    /// A sheet where there's a free window, so automation and sessions keep running; otherwise a dialog.
    private func show(_ title: String, _ text: String, _ window: NSWindow?, copy: String? = nil) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if copy != nil { alert.addButton(withTitle: "Copy Command") }
        let done = alert.addButton(withTitle: "Done")
        if copy != nil { done.keyEquivalent = "\u{1b}" }
        let response: NSApplication.ModalResponse
        if let window, window.isVisible, window.attachedSheet == nil {
            response = await alert.beginSheetModal(for: window)
        } else {
            NSApp.activate()
            response = alert.runModal()
        }
        if let copy, response == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copy, forType: .string)
        }
    }
}
