import AppKit
import Darwin
import SwiftTerm
import TrellisBroker
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
    private var transport: any TerminalProcessTransport
    public private(set) var adapter: TerminalAdapter!
    private let session: LocalSessionController
    public var isRunning: Bool { [.starting, .running, .closing].contains(session.state) }
    public var requiresTermination: Bool { transport.isRunning || (isRunning && processID == nil) }
    /// The session is held by the broker and survives quitting with Keep Running (FR-R03).
    public var survivesQuit: Bool { transport.survivesQuit }
    /// True while replayed or restored output is parsed: replies to the program, attention,
    /// notifications, progress and the bell are all suppressed (FR-R03, FR-R04).
    public private(set) var isReplaying = false
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
    /// A typed Return (FR-AG11). Only that a key was pressed is reported, never what was typed.
    public var onReturnKey: (() -> Void)?
    /// Raw PTY bytes in arrival order, for bounded automation journaling.
    public var onOutputData: ((Data) -> Void)?
    public var onExit: ((Int32?) -> Void)?
    public var onInputError: ((Error) -> Void)?
    public var onPasteRequested: ((TerminalPasteInput) -> Void)?
    /// Authenticated shell-integration marks (FR-SI02), or an SSH pane's unverified marks (FR-SI09) once
    /// `observeRemoteShellMarks()` chose that; forged output in a local pane never reaches this.
    public var onShellIntegrationEvent: ((ShellIntegrationEvent) -> Void)?
    /// Which marks this session accepts, fixed before launch; nil accepts none.
    public private(set) var shellMarkOrigin: ShellMarkOrigin?
    /// A password-style prompt: the PTY has echo off with line editing on (FR-T06). Fires on change only.
    public var onPasswordPromptChanged: ((Bool) -> Void)?
    /// The program rang the bell or posted an OSC 9/777/99 notification (FR-T06). Carries no text.
    public var onAttentionRequested: (() -> Void)?
    /// The program posted a desktop notification (FR-T08); its text is untrusted and shown only in the notification.
    public var onNotification: ((TerminalNotification) -> Void)?
    /// OSC 9;4 progress reports (FR-T09); never an attention request.
    public var onProgress: ((TerminalProgressReport) -> Void)?
    private var kittyNotifications = KittyNotificationAssembler()
    /// The audible half of the bell (FR-T07); injected so tests stay silent.
    var playBell: () -> Void = { NSSound.beep() }
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

    public init(sessionID: UUID = UUID(), scrollbackBudget: ScrollbackBudget = .standard, transport: (any TerminalProcessTransport)? = nil) {
        let surface = AccessibleTerminalView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 520),
            font: NativeTerminalFont.font(NativeTerminalFont.choice(for: AppearanceSettings.defaultFontName), size: 13))
        terminalView = surface
        surface.scrollback = TerminalScrollback(budget: scrollbackBudget)
        surface.changeScrollback(scrollbackBudget.lineLimit)
        view = surface
        let transport = transport ?? PTYProcess()
        self.transport = transport
        session = LocalSessionController(id: sessionID, transport: transport)
        super.init()
        observePrompt(transport)
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
        surface.onBell = { [weak self] in if self?.isReplaying == false { self?.onAttentionRequested?() } }
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
        if session.state == .stopped, shellMarkOrigin == nil, let nonce = configuration.shellIntegration?.nonce { observeShellIntegration(nonce: nonce) }
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
        // A session kept for the next launch is never signalled, including by the adapter's detach cleanup.
        guard !keptAlive else { return }
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
        // Replayed queries (DA, DSR, cursor reports, kitty `p=?`) were answered when first printed; never again.
        guard !inputSuspended, !isReplaying else { return }
        onInput?()
        // A keystroke, not a paste: pastes arrive as larger writes through the paste review.
        if data.count <= 4, data.contains(0x0d) { onReturnKey?() }
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
        terminalView.bellStyle = Self.bellStyle(settings.bellStyle)
        if settings.gpuRendering { Self.prepareGPURendering() }
        terminalView.prefersMetal = settings.gpuRendering
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
    /// Compiles the GPU renderer's shaders off the main thread at launch, so the first pane doesn't wait for them.
    public static func prepareGPURendering() { TerminalView.prewarmMetal() }
    /// True while the Metal renderer draws this pane; false on CoreGraphics (FR-TX05).
    public var isUsingMetalRenderer: Bool { terminalView.isUsingMetalRenderer }
    /// Frames presented by Metal (since it was last turned on) and passes drawn by CoreGraphics.
    public var renderedFrames: (metal: Int, coreGraphics: Int) {
        (Int(clamping: terminalView.metalRendererStatus.presentedFrameCount), terminalView.coreGraphicsDrawCount)
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
    /// Clears the pane's scrollback and the screen above the prompt (FR-C07); the session is untouched.
    public func clear() { terminalView.clearTerminal(nil) }
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
            self.updatePasswordPrompt(self.transport.passwordPromptActive)
        }
    }

    private func updatePasswordPrompt(_ active: Bool) {
        guard active != passwordPromptActive else { return }
        passwordPromptActive = active
        onPasswordPromptChanged?(active)
    }

    /// OSC 9 text, OSC 777 `notify` and OSC 99 are attention requests (FR-T06) and desktop notifications (FR-T08).
    /// Their text goes only to `onNotification`; it is never printed, kept or logged.
    private func observeNotifications() {
        let terminal = terminalView.getTerminal()
        // The OSC 9 handler replaces upstream's, so 9;4 progress reaches only `onProgress` and the engine's bar stays hidden.
        terminal.registerOscHandler(code: 9) { [weak self, weak terminal] data in
            if let report = terminal?.parseProgressReport(data) {
                if self?.isReplaying == false { self?.onProgress?(TerminalProgressReport(report)) }
                return
            }
            guard let self, !self.isReplaying, TerminalNotification.isNotification(osc9: data) else { return }
            self.onAttentionRequested?()
            if let notification = TerminalNotification.parse(osc9: data) { self.onNotification?(notification) }
        }
        terminal.registerOscHandler(code: 777) { [weak self] data in
            guard let self, !self.isReplaying, data.starts(with: Array("notify;".utf8)) else { return }
            self.onAttentionRequested?()
            if let notification = TerminalNotification.parse(osc777: data) { self.onNotification?(notification) }
        }
        terminal.registerOscHandler(code: 99) { [weak self, weak terminal] data in
            guard let self, !self.isReplaying else { return }
            switch self.kittyNotifications.receive(data) {
            case .notification(let notification): self.onAttentionRequested?(); self.onNotification?(notification)
            case .reply(let text): terminal?.sendResponse(text: text)
            case nil: break
            }
        }
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
        case .other:
            imageTransfer.reset()
            if shellMarkOrigin == .remote, let event = ShellIntegrationEvent.parseRemote(osc1337: data) { onShellIntegrationEvent?(event) }
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
        shellMarkOrigin = .authenticated
        let terminal = terminalView.getTerminal()
        terminal.registerOscHandler(code: 133) { [weak self, weak terminal] data in
            terminal?.handleSemanticPrompt(data)
            guard let self, let event = ShellIntegrationEvent.parse(data, nonce: nonce) else { return }
            self.onShellIntegrationEvent?(event)
        }
    }

    /// FR-SI09: an SSH pane's nonce-less OSC 133 marks, OSC 7 and OSC 1337 `CurrentDir=` become display-only events.
    /// Call before starting; a session observes either these or its nonce, never both.
    public func observeRemoteShellMarks() {
        guard shellMarkOrigin == nil, session.state == .stopped else { return }
        shellMarkOrigin = .remote
        let terminal = terminalView.getTerminal()
        terminal.registerOscHandler(code: 133) { [weak self, weak terminal] data in
            terminal?.handleSemanticPrompt(data)
            guard let self, let event = ShellIntegrationEvent.parseRemote(data) else { return }
            self.onShellIntegrationEvent?(event)
        }
        terminal.registerOscHandler(code: 7) { [weak self] data in
            guard let self, let event = ShellIntegrationEvent.parseRemote(osc7: data) else { return }
            self.onShellIntegrationEvent?(event)
        }
    }

    private func observePrompt(_ transport: any TerminalProcessTransport) {
        transport.onPasswordPromptChanged = { [weak self] active in self?.updatePasswordPrompt(active) }
    }

    /// Uses another process owner for a session that never started (a broker-held one, FR-R03).
    @discardableResult
    public func useTransport(_ next: any TerminalProcessTransport) -> Bool {
        guard !adapter.isDetached, session.replaceTransport(next) else { return false }
        transport.onPasswordPromptChanged = nil
        transport = next
        observePrompt(next)
        return true
    }

    /// The host of a remote workspace session (FR-RW04); nil for local and SSH panes.
    public var remoteTransport: RemoteSessionTransport? { transport as? RemoteSessionTransport }

    /// Starts a remote workspace session through its transport (FR-RW04): the helper on the host spawns the login shell.
    /// `nonce` authenticates the shell-integration marks when integration was planned (FR-RW05).
    public func start(remote transport: RemoteSessionTransport, request: BrokerLoginRequest, nonce: String?) async {
        guard !adapter.isDetached, session.state == .stopped, useTransport(transport) else { return }
        let size = getWindowSize()
        guard let dimensions = try? TerminalSize(columns: Int(size.ws_col), rows: Int(size.ws_row)) else { return }
        if let nonce, shellMarkOrigin == nil { observeShellIntegration(nonce: nonce) }
        var request = request
        request.columns = UInt16(dimensions.columns); request.rows = UInt16(dimensions.rows)
        await session.start(size: dimensions) { _, _ in try await transport.launchRemote(request) }
        if session.state == .failed { adapter.receive(Data("Unable to start the remote session. The host’s helper refused it or the connection ended.\r\n".utf8)) }
    }

    /// Takes over a session the broker kept while the app was closed: its marks, then its replay with
    /// every reply suppressed, then live I/O at this view's size. Never starts a process.
    @discardableResult
    public func adopt(_ adoption: BrokerAdoption) -> Bool {
        guard session.state == .stopped, let transport = adoption.transport, let pid = adoption.processID, useTransport(transport) else { return false }
        if let nonce = adoption.nonce, shellMarkOrigin == nil { observeShellIntegration(nonce: nonce) }
        replay(adoption.replay)
        guard session.adopt(processID: pid) else { return false }
        updatePasswordPrompt(transport.passwordPromptActive)
        transport.beginDelivery()
        let size = getWindowSize()
        if let dimensions = try? TerminalSize(columns: Int(size.ws_col), rows: Int(size.ws_row)) { session.resize(dimensions) }
        return true
    }

    /// A kept session that ended while the app was closed: its replay, then a notice; the pane stays stopped.
    public func showEndedSession(replay data: Data, exitCode: Int32?, while reason: String = "Trellis was closed") {
        guard session.state == .stopped else { return }
        replay(data)
        replay(Data("\r\n\u{1b}[0m\u{1b}[2m— Session ended while \(reason)\(exitCode.map { " (exit \($0))" } ?? "") —\u{1b}[0m\r\n".utf8))
    }

    /// Restored plain text from the scrollback file (FR-R04), cleaned to printable text first.
    public func showRestoredOutput(_ text: String, savedAt: Date) {
        guard session.state == .stopped, !text.isEmpty else { return }
        let date = savedAt.formatted(date: .abbreviated, time: .shortened)
        replay(Data((Self.printable(text) + "\r\n\u{1b}[2m— Restored output from \(date) —\u{1b}[0m\r\n").utf8))
    }

    /// Only printable characters, tabs and line breaks survive: no escape sequence can reach the parser.
    static func printable(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0a: result.append("\r"); result.append(scalar)
            case 0x09: result.append(scalar)
            case 0x00..<0x20, 0x7f..<0xa0: continue
            default: result.append(scalar)
            }
        }
        return String(result)
    }

    private func replay(_ data: Data) {
        guard !data.isEmpty else { return }
        isReplaying = true
        defer { isReplaying = false }
        adapter.receive(data)
    }

    /// The pane's retained plain text, for the scrollback file (FR-R04).
    public var retainedText: String { terminalView.retainedText }

    /// Quitting with Keep Running: the broker keeps the process, so nothing here may signal it. A cancelled quit turns it back off.
    public func prepareForKeepRunning(_ on: Bool = true) {
        keptAlive = on && survivesQuit
        transport.setKeepAlive(keptAlive)
    }
    private var keptAlive = false

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
    public func bell(source: TerminalView) { if !isReplaying { playBell() } }
    static func bellStyle(_ style: TerminalBellStyle) -> BellStyle {
        switch style {
        case .sound: .sound;
        case .visual: .visual;
        case .soundAndVisual: .soundAndVisual;
        case .off: .none
        }
    }
    public func setTerminalTitle(source: TerminalView, title: String) {}
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func scrolled(source: TerminalView, position: Double) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

extension TerminalProgressReport {
    init(_ report: Terminal.ProgressReport) {
        let kind: Kind =
            switch report.state {
            case .remove: .remove
            case .set: .set
            case .error: .error
            case .indeterminate: .indeterminate
            case .pause: .pause
            }
        self.init(kind: kind, value: report.progress.map(Int.init))
    }
}
