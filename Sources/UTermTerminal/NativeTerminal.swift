import AppKit
import Darwin
import SwiftTerm
import UTermCore

/// SwiftTerm renders terminal state; PTYProcess exclusively owns process I/O
/// and reaping so EOF cannot race termination or leak an exited session’s FD.
@MainActor
public final class NativeTerminal: NSObject, @preconcurrency TerminalViewDelegate {
    public let view: NSView
    private let terminalView: AccessibleTerminalView
    private let process = PTYProcess()
    public private(set) var adapter: TerminalAdapter!
    public private(set) var isRunning = false
    public var onExit: ((Int32?) -> Void)?
    public var onInputError: ((Error) -> Void)?
    private var closing = false
    private var killTimer: Timer?

    public override init() {
        let surface = AccessibleTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 520),
                                   font: NSFont(name: "Monaco", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        terminalView = surface
        view = surface
        super.init()
        surface.nativeBackgroundColor = NSColor(srgbRed: 0.082, green: 0.09, blue: 0.098, alpha: 1)
        surface.nativeForegroundColor = NSColor(srgbRed: 0.87, green: 0.88, blue: 0.90, alpha: 1)
        surface.caretColor = .lightGray
        surface.setAccessibilityLabel("Terminal session")
        surface.terminalDelegate = self
        process.onOutput = { [weak self] data in self?.adapter.receive(data) }
        process.onInputError = { [weak self] error in self?.onInputError?(error) }
        process.onExit = { [weak self] code in self?.processTerminated(exitCode: code) }
        adapter = TerminalAdapter(
            render: { [weak self] data in self?.terminalView.display(data) },
            write: { [weak self] data in
                guard let self else { throw TerminalAdapterError.inputClosed }
                try self.process.send(data)
            },
            resizePTY: { [weak self] size in
                guard let self, self.process.isRunning else { return }
                var dimensions = winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.columns), ws_xpixel: 0, ws_ypixel: 0)
                _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: self.process.descriptor, windowSize: &dimensions)
            },
            readText: { [weak self] in
                guard let self else { return "" }
                return self.terminalView.retainedText
            },
            cleanup: { [weak self] in self?.stop() }
        )
    }

    /// Feasibility host only. The validated configurable launch service is S003.
    public func start(fixture: Bool = false) {
        guard !isRunning, !adapter.isDetached, !closing else { return }
        let fixtureScript = "printf '\\033[32mPTY ready\\033[0m — café 漢字 👋\\n'; stty size; printf '\\033[?1049hAlternate screen\\r\\n'; sleep 0.1; printf '\\033[?1049l'; printf 'Fixture complete\\n'; exit 7"
        start(arguments: fixture ? ["-f", "-c", fixtureScript] : ["-l"])
    }

    func start(arguments: [String]) {
        guard !isRunning, !adapter.isDetached, !closing else { return }
        let environment = ["TERM=xterm-256color", "COLORTERM=truecolor", "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                           "HOME=\(FileManager.default.homeDirectoryForCurrentUser.path)", "LANG=en_US.UTF-8"]
        do {
            try process.start(executable: "/bin/zsh", arguments: arguments, environment: environment,
                              directory: FileManager.default.homeDirectoryForCurrentUser.path, size: getWindowSize())
            isRunning = true
        } catch {
            adapter.receive(Data("Unable to start the terminal session.\r\n".utf8))
            onExit?(nil)
        }
    }

    /// Keep process ownership and reaping active independently of terminal EOF.
    public func stop() {
        guard isRunning, !closing else { return }
        closing = true
        signalOwnedProcessGroup(SIGTERM)
        killTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.signalOwnedProcessGroup(SIGKILL) }
        }
    }

    private func signalOwnedProcessGroup(_ signal: Int32) {
        process.signalGroup(signal)
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let size = try? TerminalSize(columns: newCols, rows: newRows) else { return }
        try? adapter.resize(size)
    }
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        do { try adapter.send(Data(data)) }
        catch { onInputError?(error) }
    }
    public func getWindowSize() -> winsize {
        let terminal = terminalView.getTerminal()
        return winsize(ws_row: UInt16(clamping: terminal.rows), ws_col: UInt16(clamping: terminal.cols), ws_xpixel: 0, ws_ypixel: 0)
    }
    private func processTerminated(exitCode: Int32?) {
        isRunning = false
        closing = false
        killTimer?.invalidate()
        killTimer = nil
        onExit?(exitCode)
    }
    // OSC 52 clipboard access is denied; native selection copy/paste remains in the view.
    public func clipboardCopy(source: TerminalView, content: Data) {}
    public func clipboardRead(source: TerminalView) -> Data? { nil }
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    public func setTerminalTitle(source: TerminalView, title: String) {}
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func scrolled(source: TerminalView, position: Double) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
