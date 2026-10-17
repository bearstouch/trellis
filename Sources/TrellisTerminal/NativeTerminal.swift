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
    /// Fires on each write to the PTY through the view (keystrokes, paste, and terminal-generated replies such as
    /// cursor or mouse reports); carries no data, so input is never exposed.
    public var onInput: (() -> Void)?
    /// Raw PTY bytes in arrival order, for bounded automation journaling.
    public var onOutputData: ((Data) -> Void)?
    public var onExit: ((Int32?) -> Void)?
    public var onInputError: ((Error) -> Void)?
    public var onPasteRequested: ((TerminalPasteInput) -> Void)?
    /// Authenticated shell-integration marks only (FR-SI02); forged output never reaches this.
    public var onShellIntegrationEvent: ((ShellIntegrationEvent) -> Void)?
    /// A password-style prompt: the PTY has echo off with line editing on (FR-T06). Fires on change only.
    public var onPasswordPromptChanged: ((Bool) -> Void)?
    /// The program rang the bell or posted an OSC 9/777 notification (FR-T06). Carries no text.
    public var onAttentionRequested: (() -> Void)?
    public private(set) var passwordPromptActive = false
    private var passwordCheck: Task<Void, Never>?
    private var imageTransfer = MultipartImageTransfer()
    /// Delay before re-reading the PTY modes after I/O; prompts change them just before or after writing.
    static let passwordCheckDelay: TimeInterval = 0.1
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
            font: NativeTerminalFont.font(NativeTerminalFont.choice(for: AppearanceSettings.defaultFontName), size: 13))
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
        // Engine diagnostics can echo sequence contents; never print them, in any build.
        surface.getTerminal().silentLog = true
        surface.setAccessibilityLabel("Terminal session")
        surface.terminalDelegate = self
        surface.onFocused = { [weak self] in self?.onFocused?() }
        surface.onPasteRequested = { [weak self] in self?.onPasteRequested?($0) }
        surface.onSearchRequested = { [weak self] in self?.showSearch() }
        surface.onContentsChanged = { [weak self] in self?.invalidateSearchForOutput() }
        surface.onBell = { [weak self] in self?.onAttentionRequested?() }
        surface.doubleClickSelection = { [weak surface] position in
            guard let surface else { return nil }
            return TerminalLogicalLine.smartSelection(in: surface.getTerminal(), at: position)
        }
        surface.describeLink = { [weak self] in self?.describeLink($0) }
        surface.onOpenLink = { [weak self] in self?.openLink($0) }
        observeNotifications()
        observeInlineImages()
        session.onOutput = { [weak self] data in
            self?.adapter.receive(data)
            if !data.isEmpty {
                self?.onOutputData?(data)
                self?.onOutput?()
                self?.schedulePasswordCheck()
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
        if session.state == .stopped, let nonce = configuration.shellIntegration?.nonce { observeShellIntegration(nonce: nonce) }
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
    public func requestTermination(force: Bool) {
        // Interactive shells ignore SIGTERM. A terminal close is a hangup;
        // SIGHUP lets the shell exit and notify its jobs normally.
        session.stop(signal: force ? SIGKILL : SIGHUP)
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        terminalView.scrollback.enforce(on: terminalView)
        if !applyingAppearance { invalidateSearchForOutput() }
        guard let size = try? TerminalSize(columns: newCols, rows: newRows) else { return }
        try? adapter.resize(size)
    }
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !inputSuspended else { return }
        onInput?()
        do { try adapter.send(Data(data)) } catch { onInputError?(error) }
        schedulePasswordCheck()
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
        // Each property redraws only when its value changes; none resizes the grid.
        terminalView.fontLigatures = settings.fontLigatures
        terminalView.boldIsBright = settings.boldAsBright
        terminalView.allowBoldFont = settings.allowBoldFont
        terminalView.allowItalicFont = settings.allowItalicFont
        terminalView.textBlinkEnabled = settings.blinkingText
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
        passwordCheck?.cancel(); passwordCheck = nil
        updatePasswordPrompt(false)
        onExit?(exitCode)
    }

    /// Coalesced: a burst of output reads the PTY modes once. Modes only change around I/O, so nothing polls.
    private func schedulePasswordCheck() {
        guard passwordCheck == nil else { return }
        passwordCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.passwordCheckDelay))
            guard let self, !Task.isCancelled else { return }
            self.passwordCheck = nil
            self.updatePasswordPrompt(self.process.passwordPromptActive)
        }
    }

    private func updatePasswordPrompt(_ active: Bool) {
        guard active != passwordPromptActive else { return }
        passwordPromptActive = active
        onPasswordPromptChanged?(active)
    }

    /// OSC 9 text and OSC 777 `notify` are attention requests; their text is never kept. Numbered OSC 9 forms
    /// (`9;4;…` progress and other ConEmu commands) are not notifications.
    private func observeNotifications() {
        let terminal = terminalView.getTerminal()
        // The OSC 9 handler replaces upstream's, so 9;4 progress is forwarded to keep the progress bar.
        terminal.registerOscHandler(code: 9) { [weak self, weak terminal] data in
            if terminal?.handleProgressReport(data) == true { return }
            guard let self, Self.isNotification(osc9: data) else { return }
            self.onAttentionRequested?()
        }
        terminal.registerOscHandler(code: 777) { [weak self] data in
            guard let self, data.starts(with: Array("notify;".utf8)) else { return }
            self.onAttentionRequested?()
        }
    }

    nonisolated static func isNotification(osc9 data: ArraySlice<UInt8>) -> Bool {
        guard !data.isEmpty else { return false }
        let digits = data.prefix { (0x30...0x39).contains($0) }
        guard !digits.isEmpty else { return true }
        let rest = data.dropFirst(digits.count)
        return !(rest.isEmpty || rest.first == UInt8(ascii: ";"))
    }

    /// iTerm2's inline image protocol (FR-IM01–FR-IM04) replaces upstream's OSC 1337 handling, which would decode
    /// any NSImage format. Images are decoded in stream order so they land where the cursor was.
    private func observeInlineImages() {
        terminalView.getTerminal().registerOscHandler(code: 1337) { [weak self] data in self?.handleInlineImage(data) }
    }

    func handleInlineImage(_ data: ArraySlice<UInt8>) {
        // Any command other than a part ends an unfinished multipart transfer.
        switch InlineImageCommand(data) {
        case .filePart(let part): imageTransfer.append(part)
        case .fileEnd: if let (arguments, bytes) = imageTransfer.finish() { showImage(bytes, arguments) }
        case .multipartBegin(let arguments): imageTransfer.begin(arguments)
        case .file(let arguments, let payload):
            imageTransfer.reset()
            guard arguments.inline, let bytes = Data(base64Encoded: Data(payload)) else { return }
            showImage(bytes, arguments)
        case .reportCellSize:
            imageTransfer.reset()
            let metrics = terminalView.cellMetrics
            terminalView.getTerminal().sendResponse(text: InlineImageCommand.cellSizeReport(size: metrics.size, scale: metrics.scale))
        case .other: imageTransfer.reset()
        }
    }

    private func showImage(_ data: Data, _ arguments: InlineImageArguments) {
        guard let image = InlineImageDecoder.image(from: data) else { return }
        let metrics = terminalView.cellMetrics
        let box = InlineImageLayout.requests(image: image.size, arguments, cell: metrics.size, pane: terminalView.frame.size, scale: metrics.scale)
        terminalView.insertImage(image, width: box.width, height: box.height, preserveAspectRatio: box.preserveAspectRatio)
    }

    /// Every 133 mark keeps upstream prompt handling; only marks with this session's
    /// nonce become events. The nonce lives only in memory for this session.
    private func observeShellIntegration(nonce: String) {
        let terminal = terminalView.getTerminal()
        terminal.registerOscHandler(code: 133) { [weak self, weak terminal] data in
            terminal?.handleSemanticPrompt(data)
            guard let self, let event = ShellIntegrationEvent.parse(data, nonce: nonce) else { return }
            self.onShellIntegrationEvent?(event)
        }
    }

    /// Scrolls to the previous or next shell prompt marked through OSC 133 (FR-SI06).
    @discardableResult
    public func scrollToPrompt(forward: Bool) -> Bool {
        let terminal = terminalView.getTerminal()
        guard !terminal.isCurrentBufferAlternate else { return false }
        let top = terminal.getTopVisibleRow()
        var row = forward ? top + 1 : top - 1
        while row >= 0, terminal.bufferLine(atRow: row) != nil {
            if terminal.semanticRowKind(at: row) == .initial {
                terminalView.scrollTo(row: row)
                return true
            }
            row += forward ? 1 : -1
        }
        if forward { terminalView.scrollTo(row: .max) }
        return false
    }
    // OSC 52 clipboard access is denied; native selection copy/paste remains in the view.
    public func clipboardCopy(source: TerminalView, content: Data) {}
    public func clipboardRead(source: TerminalView) -> Data? { nil }
    /// Opens a vetted URL; injected by tests.
    public var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    /// Shows a file in Finder instead of opening it (FR-L03); injected by tests.
    public var revealURL: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// Where this pane's file links resolve, read at click time; nil refuses every file link (FR-L04).
    public var fileLinkContext: () -> FileLinkContext? = { nil }
    var fileProbe = FileProbe.live
    var now: () -> Date = { Date() }

    /// Output can request any link; only clicked web links and vetted local files open.
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        var click = terminalView.linkClick ?? TerminalLinkClick(link: nil, explicit: false, position: nil)
        click.link = link
        openLink(click)
    }

    private enum ResolvedLink { case web(URL), file(path: String, action: FileLinkAction) }

    /// SwiftTerm's detector lets paths contain spaces, so `a.txt b.txt` reads as one path.
    /// When its text names nothing, the smart-selection token under the click is tried.
    private func resolve(_ click: TerminalLinkClick) -> (candidate: String, link: ResolvedLink)? {
        var candidates = click.link.map { [$0] } ?? []
        if !click.explicit, let position = click.position, let token = linkToken(at: position), token != click.link { candidates.append(token) }
        let files = fileLinkContext()
        for candidate in candidates {
            switch TerminalLinkClassifier.classify(candidate, explicit: click.explicit, files: files) {
            case .web(let url): return (candidate, .web(url))
            case .file(let path, _, _): if let action = FileLinkPolicy.action(path: path, probe: fileProbe) { return (candidate, .file(path: path, action: action)) }
            case nil: continue
            }
        }
        return nil
    }

    private func linkToken(at position: Position) -> String? {
        guard let line = TerminalLogicalLine(terminal: terminalView.getTerminal(), row: position.row), let offset = line.offset(for: position),
            let match = SmartSelection.match(in: line.text, at: offset), [.url, .filePath].contains(match.kind)
        else { return nil }
        return String(Array(line.text)[match.range])
    }

    func openLink(_ click: TerminalLinkClick) {
        guard LinkPolicy.gestureIsFresh(lastGesture: terminalView.lastUserGesture, now: now()), let resolved = resolve(click) else { return }
        terminalView.lastUserGesture = nil
        switch resolved.link {
        case .web(let url): _ = openURL(url)
        case .file(_, .open(let url)): _ = openURL(url)
        case .file(_, .reveal(let url)): revealURL(url)
        }
    }

    /// The menu keeps the text it described, so output arriving while it is open can't change what Open opens.
    func describeLink(_ click: TerminalLinkClick) -> TerminalLinkMenu? {
        guard let resolved = resolve(click) else { return nil }
        let frozen = TerminalLinkClick(link: resolved.candidate, explicit: click.explicit, position: nil)
        switch resolved.link {
        case .web(let url): return TerminalLinkMenu(openTitle: "Open Link", copyTitle: "Copy Link", copyText: url.absoluteString, click: frozen)
        case .file(let path, .open): return TerminalLinkMenu(openTitle: "Open", copyTitle: "Copy Path", copyText: path, click: frozen)
        case .file(let path, .reveal): return TerminalLinkMenu(openTitle: "Reveal in Finder", copyTitle: "Copy Path", copyText: path, click: frozen)
        }
    }
    public func setTerminalTitle(source: TerminalView, title: String) {}
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func scrolled(source: TerminalView, position: Double) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
