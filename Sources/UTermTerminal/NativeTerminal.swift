import AppKit
import Darwin
import SwiftTerm
import UTermCore

/// SwiftTerm renders terminal state; PTYProcess exclusively owns process I/O
/// and reaping so EOF cannot race termination or leak an exited session’s FD.
@MainActor
public final class NativeTerminal: NSObject, @preconcurrency TerminalViewDelegate, ClosableSession {
    public let view: NSView
    private let terminalView: AccessibleTerminalView
    private let process: PTYProcess
    public private(set) var adapter: TerminalAdapter!
    private let session: LocalSessionController
    public var isRunning: Bool { [.starting, .running, .closing].contains(session.state) }
    public var requiresTermination: Bool { process.isRunning || (isRunning && processID == nil) }
    public var sessionID: UUID { session.id }
    public var exitCode: Int32? { session.exitCode }
    public var processID: Int32? { session.processID }
    public var sessionState: SessionState { session.state }
    public var onStateChanged: ((SessionState) -> Void)?
    public var onFocused: (() -> Void)?
    public var onOutput: (() -> Void)?
    public var onExit: ((Int32?) -> Void)?
    public var onInputError: ((Error) -> Void)?
    public var onPasteRequested: ((TerminalPasteInput) -> Void)?

    public init(sessionID: UUID = UUID()) {
        let surface = AccessibleTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 520),
                                   font: NSFont(name: "Monaco", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        terminalView = surface
        view = surface
        let process = PTYProcess()
        self.process = process
        session = LocalSessionController(id: sessionID, transport: process)
        super.init()
        surface.nativeBackgroundColor = NSColor(srgbRed: 0.082, green: 0.09, blue: 0.098, alpha: 1)
        surface.nativeForegroundColor = NSColor(srgbRed: 0.87, green: 0.88, blue: 0.90, alpha: 1)
        surface.caretColor = .lightGray
        surface.setAccessibilityLabel("Terminal session")
        surface.terminalDelegate = self
        surface.onFocused = { [weak self] in self?.onFocused?() }
        surface.onPasteRequested = { [weak self] in self?.onPasteRequested?($0) }
        session.onOutput = { [weak self] data in
            self?.adapter.receive(data)
            if !data.isEmpty { self?.onOutput?() }
        }
        session.onInputError = { [weak self] error in self?.onInputError?(error) }
        session.onExit = { [weak self] code in self?.processTerminated(exitCode: code) }
        session.onStateChanged = { [weak self] in self?.onStateChanged?($0) }
        adapter = TerminalAdapter(
            render: { [weak self] data in self?.terminalView.display(data) },
            write: { [weak self] data in
                guard let self else { throw TerminalAdapterError.inputClosed }
                try self.session.send(data)
            },
            resizePTY: { [weak self] size in self?.session.resize(size) },
            readText: { [weak self] in
                guard let self else { return "" }
                return self.terminalView.retainedText
            },
            cleanup: { [weak self] in self?.stop() }
        )
    }

    /// Start a user-configured local shell/process after asynchronous validation.
    public func start(configuration: LocalLaunchConfiguration) async {
        guard !adapter.isDetached else { return }
        let size = getWindowSize()
        guard let dimensions = try? TerminalSize(columns: Int(size.ws_col), rows: Int(size.ws_row)) else { return }
        await session.start(configuration, size: dimensions)
        if session.state == .failed {
            adapter.receive(Data("Unable to start the terminal session. Check its executable, directory, and environment.\r\n".utf8))
        }
    }

    public func start(fixture: Bool = false) {
        Task {
            if fixture { await startFixture() }
            else { await start(configuration: .loginShell()) }
        }
    }

    public func startFixture() async {
        let script = "printf '\\033[32mPTY ready\\033[0m — café 漢字 👋\\n'; stty size; printf '\\033[?1049hAlternate screen\\r\\n'; sleep 0.1; printf '\\033[?1049l'; printf 'Fixture complete\\n'; exit 7"
        await start(configuration: LocalLaunchConfiguration(executable: "/bin/zsh", arguments: ["-f", "-c", script],
                    directory: FileManager.default.homeDirectoryForCurrentUser.path))
    }

    func start(arguments: [String]) {
        let configuration = LocalLaunchConfiguration(executable: "/bin/zsh", arguments: arguments,
                            directory: FileManager.default.homeDirectoryForCurrentUser.path)
        Task { await start(configuration: configuration) }
    }

    /// Graceful close never silently escalates. Force is a separate user/API action.
    public func stop() { requestTermination(force: false) }
    public func requestTermination(force: Bool) { session.stop(signal: force ? SIGKILL : SIGTERM) }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let size = try? TerminalSize(columns: newCols, rows: newRows) else { return }
        try? adapter.resize(size)
    }
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        do { try adapter.send(Data(data)) }
        catch { onInputError?(error) }
    }
    public func paste(_ plan: TerminalPastePlan) throws {
        guard session.state == .running else { throw TerminalAdapterError.inputClosed }
        // Enqueue payload and negotiated framing together, preserving every byte.
        try adapter.send(plan.data(bracketed: terminalView.getTerminal().bracketedPasteMode))
    }
    public func getWindowSize() -> winsize {
        let terminal = terminalView.getTerminal()
        return winsize(ws_row: UInt16(clamping: terminal.rows), ws_col: UInt16(clamping: terminal.cols), ws_xpixel: 0, ws_ypixel: 0)
    }
    private func processTerminated(exitCode: Int32?) {
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
