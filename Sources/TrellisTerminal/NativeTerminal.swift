import AppKit
import Darwin
import SwiftTerm
import TrellisCore
import Combine

/// SwiftTerm renders terminal state; PTYProcess exclusively owns process I/O
/// and reaping so EOF cannot race termination or leak an exited session’s FD.
@MainActor
public final class NativeTerminal: NSObject, ObservableObject, @preconcurrency TerminalViewDelegate, ClosableSession {
    @Published public private(set) var searchVisible = false
    @Published public var searchQuery = ""
    @Published public private(set) var searchStatus = ""
    @Published public private(set) var searchFocusRequest = UUID()
    private var hasSearchMatch = false
    private var applyingAppearance = false
    private let paneSearch = PaneTextSearch()
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
    /// Raw PTY bytes in arrival order, for bounded automation journaling.
    public var onOutputData: ((Data) -> Void)?
    public var onExit: ((Int32?) -> Void)?
    public var onInputError: ((Error) -> Void)?
    public var onPasteRequested: ((TerminalPasteInput) -> Void)?
    /// True while a native text field (such as tab renaming) owns editing keys.
    /// Keyboard and mouse-report bytes are dropped instead of reaching the PTY.
    public var inputSuspended = false
    /// Option composes characters unless the user opts into Meta.
    public var optionAsMeta: Bool {
        get { terminalView.optionAsMetaKey }
        set { terminalView.optionAsMetaKey = newValue }
    }
    public var searchShortcut: KeyChord? {
        get { terminalView.searchChord }
        set { terminalView.searchChord = newValue }
    }

    public init(sessionID: UUID = UUID(), scrollbackBudget: ScrollbackBudget = .standard) {
        let surface = AccessibleTerminalView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 520),
            font: NSFont(name: "Monaco", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        terminalView = surface
        surface.scrollback = TerminalScrollback(budget: scrollbackBudget)
        surface.changeScrollback(scrollbackBudget.lineLimit)
        view = surface
        let process = PTYProcess()
        self.process = process
        session = LocalSessionController(id: sessionID, transport: process)
        super.init()
        TerminalPalette.builtIn.apply(to: surface)
        surface.optionAsMetaKey = false
        surface.setAccessibilityLabel("Terminal session")
        surface.terminalDelegate = self
        surface.onFocused = { [weak self] in self?.onFocused?() }
        surface.onPasteRequested = { [weak self] in self?.onPasteRequested?($0) }
        surface.onSearchRequested = { [weak self] in self?.showSearch() }
        surface.onContentsChanged = { [weak self] in self?.invalidateSearchForOutput() }
        session.onOutput = { [weak self] data in
            self?.adapter.receive(data)
            if !data.isEmpty {
                self?.onOutputData?(data)
                self?.onOutput?()
            }
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

    /// Shows why a launch was refused without spawning anything.
    public func refuseLaunch(message: String) {
        guard sessionState == .stopped, !adapter.isDetached else { return }
        adapter.receive(Data("\(message)\r\n".utf8))
        session.refuseLaunch()
    }

    public func start(fixture: Bool = false) {
        Task {
            if fixture { await startFixture() } else { await start(configuration: .loginShell()) }
        }
    }

    public func startFixture() async {
        let script = "printf '\\033[32mPTY ready\\033[0m — café 漢字 👋\\n'; stty size; printf '\\033[?1049hAlternate screen\\r\\n'; sleep 0.1; printf '\\033[?1049l'; printf 'Fixture complete\\n'; exit 7"
        await start(
            configuration: LocalLaunchConfiguration(
                executable: "/bin/zsh", arguments: ["-f", "-c", script],
                directory: FileManager.default.homeDirectoryForCurrentUser.path))
    }

    func start(arguments: [String]) {
        let configuration = LocalLaunchConfiguration(
            executable: "/bin/zsh", arguments: arguments,
            directory: FileManager.default.homeDirectoryForCurrentUser.path)
        Task { await start(configuration: configuration) }
    }

    /// Graceful close never silently escalates. Force is a separate user/API action.
    public func stop() { requestTermination(force: false) }
    public func requestTermination(force: Bool) { session.stop(signal: force ? SIGKILL : SIGTERM) }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        terminalView.scrollback.enforce(on: terminalView)
        if !applyingAppearance { invalidateSearchForOutput() }
        guard let size = try? TerminalSize(columns: newCols, rows: newRows) else { return }
        try? adapter.resize(size)
    }
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !inputSuspended else { return }
        do { try adapter.send(Data(data)) } catch { onInputError?(error) }
    }
    /// Mutate the stable native view. No session lifecycle or input operation is
    /// involved; a metrics change only updates the PTY's dimensions.
    public func applyAppearance(_ settings: AppearanceSettings) {
        guard settings.isValid else { return }
        applyingAppearance = true
        defer { applyingAppearance = false }
        let bookmark = TerminalSelectionBookmark(terminalView)
        let font = NativeTerminalFont.font(NativeTerminalFont.choice(for: settings.fontName), size: settings.fontSize)
        if terminalView.font != font {
            terminalView.getTerminal().reflowCursorLine = true
            terminalView.font = font
            terminalView.getTerminal().reflowCursorLine = false
            paneSearch.reset()
        }
        if terminalView.scrollback.budget.lineLimit != settings.scrollbackLines {
            let old = terminalView.scrollback
            let evicted = old.historyEvicted || old.retainedHistoryRows > settings.scrollbackLines
            terminalView.scrollback = TerminalScrollback(budget: ScrollbackBudget(lineLimit: settings.scrollbackLines), historyEvicted: evicted)
            terminalView.changeScrollback(settings.scrollbackLines)
            terminalView.scrollback.enforce(on: terminalView)
        }
        bookmark?.restore(in: terminalView)
        TerminalPalette.builtIn.apply(to: terminalView)
        let style: CursorStyle
        switch (settings.cursorShape, settings.cursorBlinks) {
        case (.block, false): style = .steadyBlock
        case (.block, true): style = .blinkBlock
        case (.underline, false): style = .steadyUnderline
        case (.underline, true): style = .blinkUnderline
        case (.bar, false): style = .steadyBar
        case (.bar, true): style = .blinkBar
        }
        terminalView.getTerminal().options.cursorStyle = style
        terminalView.cursorStyleChanged(source: terminalView.getTerminal(), newStyle: style)
        terminalView.needsDisplay = true
    }
    /// Color-only application for preview/library integration. No parsing,
    /// input, font, selection, or process lifecycle operation is performed.
    public func applyPalette(_ palette: TerminalPalette) {
        palette.apply(to: terminalView)
        terminalView.needsDisplay = true
    }
    public func paste(_ plan: TerminalPastePlan) throws {
        guard session.state == .running else { throw TerminalAdapterError.inputClosed }
        // Enqueue payload and negotiated framing together, preserving every byte.
        try adapter.send(plan.data(bracketed: terminalView.getTerminal().bracketedPasteMode))
    }

    /// Plain text of the visible screen only (no scrollback).
    public var screenText: String { terminalView.screenText }

    public var historyNotice: String {
        if terminalView.getTerminal().isCurrentBufferAlternate { return "Current screen only · No scrollback" }
        return terminalView.scrollback.historyEvicted ? "Earlier output was evicted" : "Retained output only"
    }
    public func showSearch() {
        searchVisible = true
        searchFocusRequest = UUID()
        searchStatus = searchQuery.isEmpty ? historyNotice : "Search again · \(historyNotice)"
    }
    public func closeSearch() {
        searchVisible = false
        terminalView.clearSearch()
        paneSearch.reset()
        hasSearchMatch = false
        if terminalView.window?.makeFirstResponder(terminalView) == true { onFocused?() }
    }
    @discardableResult
    public func findInPane(forward: Bool = true, reset: Bool = false) -> Bool {
        if reset { terminalView.clearSearch(); paneSearch.reset() }
        guard !searchQuery.isEmpty, searchQuery.utf8.count <= 8192 else {
            terminalView.clearSearch(); paneSearch.reset(); hasSearchMatch = false
            searchStatus = searchQuery.isEmpty ? historyNotice : "Search is limited to 8 KiB · \(historyNotice)"
            return false
        }
        let found = paneSearch.find(searchQuery, forward: forward, in: terminalView)
        hasSearchMatch = found
        searchStatus = "\(found ? "Match found" : "No match") · \(historyNotice)"
        return found
    }
    private func invalidateSearchForOutput() {
        if hasSearchMatch { terminalView.clearSearch(); paneSearch.reset(); hasSearchMatch = false }
        if searchVisible {
            let next = searchQuery.isEmpty ? historyNotice : "Output changed — search again · \(historyNotice)"
            if searchStatus != next { searchStatus = next }
        }
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
