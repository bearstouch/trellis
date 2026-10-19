import AppKit
import SwiftTerm
import TrellisCore

/// Context-menu titles for a link under the pointer.
struct TerminalLinkMenu: Equatable {
    var openTitle: String
    var copyTitle: String
    var copyText: String
    /// What Open re-resolves: the described link text, without its cell.
    var click: TerminalLinkClick
}

/// A clicked link: the engine's text (nil if it found none), whether it is an OSC 8
/// hyperlink, and the clicked cell for re-detecting the token under it.
struct TerminalLinkClick: Equatable {
    var link: String?
    var explicit: Bool
    var position: Position?
}

/// SwiftTerm 1.20's macOS accessibility helper is a stub. Supply a native text
/// area interface here so assistive clients can read actual retained terminal text.
@MainActor
final class AccessibleTerminalView: TerminalView {
    var onFocused: (() -> Void)?
    var onPasteRequested: ((TerminalPasteInput) -> Void)?
    var onSearchRequested: (() -> Void)?
    var onContentsChanged: (() -> Void)?
    var onBell: (() -> Void)?
    /// Describes a clicked link for the context menu (FR-L05); nil when it must not be offered.
    var describeLink: ((TerminalLinkClick) -> TerminalLinkMenu?)?
    /// Opens a link chosen from the context menu, under the same rules as ⌘-click.
    var onOpenLink: ((TerminalLinkClick) -> Void)?
    var scrollback = TerminalScrollback(budget: .standard)
    /// The configurable Find chord; other ⌘ chords reach the menu bar.
    var searchChord: KeyChord? = ShortcutMap.defaults[.findInPane]
    private var accessibilityUpdateScheduled = false
    private var scrollbarTrackingArea: NSTrackingArea?
    private var scrollbarHovered = false
    private var scrollbarHideTask: Task<Void, Never>?
    var scrollbarIdleDelay: Duration = .seconds(1)
    private var terminalScroller: NSScroller? { subviews.compactMap { $0 as? NSScroller }.first }
    /// Draws with the Metal renderer (FR-TX05). Metal needs a window, so it's applied
    /// when the view gets one; until then, and whenever Metal fails, CoreGraphics draws.
    var prefersMetal = false {
        didSet {
            guard prefersMetal != oldValue else { return }
            // Turning the setting back on retries a renderer that failed.
            metalUnavailable = false
            applyRendererPreference()
        }
    }
    /// Set when Metal couldn't start or the engine fell back to CoreGraphics; not retried
    /// on every window move, so a failing GPU doesn't flap between renderers.
    private(set) var metalUnavailable = false

    func applyRendererPreference() {
        if metalRendererStatus.state == .fellBackToCoreGraphics {
            // Acknowledge the fallback (the state becomes disabled), or turning the setting back on would
            // read it again and never retry.
            metalUnavailable = true
            try? setUseMetal(false)
        }
        let wanted = prefersMetal && !metalUnavailable
        guard wanted != isUsingMetalRenderer, !wanted || window != nil else { return }
        do { try setUseMetal(wanted) } catch { metalUnavailable = true }
    }

    /// Every BEL counts as an attention request, whatever the bell style.
    override func bell(source: Terminal) {
        super.bell(source: source)
        onBell?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scrollbarHideTask?.cancel()
        scrollbarHovered = false
        terminalScroller?.alphaValue = 0
        applyRendererPreference()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = scrollbarTrackingArea { removeTrackingArea(area) }
        let width = NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollerStyle)
        let area = NSTrackingArea(
            rect: NSRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height),
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .enabledDuringMouseDrag], owner: self)
        scrollbarTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === scrollbarTrackingArea else { super.mouseEntered(with: event); return }
        scrollbarHovered = true
        revealScrollbar()
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === scrollbarTrackingArea else { super.mouseExited(with: event); return }
        scrollbarHovered = false
        scheduleScrollbarHide()
    }

    override func scrollWheel(with event: NSEvent) {
        let before = scrollPosition
        super.scrollWheel(with: event)
        // Mouse reporting, alternate-screen key events, and gestures against
        // the scrollback limit do not move the viewport or reveal its scrollbar.
        if scrollPosition != before { revealScrollbar() }
    }

    private func revealScrollbar() {
        scrollbarHideTask?.cancel()
        guard canScroll else { return }
        terminalScroller?.alphaValue = 1
        if !scrollbarHovered { scheduleScrollbarHide() }
    }

    private func scheduleScrollbarHide() {
        scrollbarHideTask?.cancel()
        let delay = scrollbarIdleDelay
        scrollbarHideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !self.scrollbarHovered else { return }
            // Keep a thumb drag visible even after the pointer leaves its track.
            guard NSEvent.pressedMouseButtons & 1 == 0 else { self.scheduleScrollbarHide(); return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
                self.terminalScroller?.animator().alphaValue = 0
            }
        }
    }
    @objc func showPaneSearch(_ sender: Any?) { onSearchRequested?() }
    var readClipboardText: () -> String? = { NSPasteboard.general.string(forType: .string) }
    var readClipboardPaths: () -> [String] = {
        let board = NSPasteboard.general
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls.map(\.path) }
        return board.string(forType: .string).map { [$0] } ?? []
    }

    override func paste(_ sender: Any) {
        guard window?.firstResponder === self, let text = readClipboardText() else { return }
        onPasteRequested?(.text(text))
    }

    @objc func pasteEscapedPath(_ sender: Any?) {
        guard window?.firstResponder === self else { return }
        let paths = readClipboardPaths()
        if !paths.isEmpty { onPasteRequested?(.paths(paths)) }
    }
    // Write-only injection keeps selection tests off the user's pasteboard.
    var writeClipboard: (String) -> Void = { text in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    override func copy(_ sender: Any) {
        guard selection.active else { return }
        writePlainText(selectedText)
    }

    @objc func copyAllRetainedText(_ sender: Any?) { writePlainText(retainedText) }

    /// Like Terminal's ⌘K (FR-C07): drops the scrollback and the screen above the cursor's logical
    /// line, which moves to the top so the prompt and typed text stay. Nothing is sent to the PTY,
    /// so a running program is unaffected; an alternate-screen program keeps its screen.
    @objc func clearTerminal(_ sender: Any?) {
        let terminal = getTerminal(), buffer = terminal.buffer
        if !terminal.isCurrentBufferAlternate {
            var count = 0
            while terminal.bufferLine(atRow: count) != nil { count += 1 }
            let top = max(0, count - terminal.rows)
            var start = buffer.y
            while start > 0, terminal.bufferLine(atRow: top + start)?.isWrapped == true { start -= 1 }
            // Scroll the whole screen, not the program's scroll region or left/right margins
            // (which scroll in place), so those rows reach history.
            let region = (buffer.scrollTop, buffer.scrollBottom, buffer.marginLeft, buffer.marginRight)
            buffer.scrollTop = 0; buffer.scrollBottom = terminal.rows - 1; buffer.marginLeft = 0; buffer.marginRight = terminal.cols - 1
            for _ in 0..<start { terminal.scroll() }
            (buffer.scrollTop, buffer.scrollBottom, buffer.marginLeft, buffer.marginRight) = region
            buffer.y -= start; buffer.savedY = max(0, buffer.savedY - start)
        }
        selection.selectNone()
        clearScrollback()
        // A viewport scrolled up into the dropped history must follow output again.
        scrollTo(row: 0)
        terminal.updateFullScreen()
        scrollback.enforce(on: self)
        onContentsChanged?()
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    @objc func selectAllTerminalText(_ sender: Any?) {
        // SwiftTerm's Select All ends at cols-1 even though text ranges are
        // half-open. Use its public selection operations to include that cell.
        var count = 0
        while getTerminal().bufferLine(atRow: count) != nil { count += 1 }
        guard count > 0 else { return }
        selection.setSoftStart(bufferPosition: Position(col: 0, row: 0))
        selection.startSelection()
        selection.dragExtend(bufferPosition: Position(col: getTerminal().cols, row: count - 1))
    }

    private var selectedText: String {
        guard selection.active else { return "" }
        if selection.selectingRows {
            let first = min(selection.start.row, selection.end.row)
            let last = max(selection.start.row, selection.end.row)
            return getTerminal().getText(
                start: Position(col: 0, row: first),
                end: Position(col: getTerminal().cols, row: last))
        }
        return selection.getSelectedText()
    }

    private func writePlainText(_ text: String) {
        // The engine resolves ANSI and grapheme cells. Defensively exclude
        // remaining control scalars without damaging combining marks or ZWJ.
        let plain = String(
            text.unicodeScalars.filter {
                $0.value == 9 || $0.value == 10 || ($0.value >= 32 && !((127...159).contains($0.value)))
            })
        guard !plain.isEmpty else { return }
        writeClipboard(plain)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Consume Cmd-C even when Copy is disabled. It must never fall through
        // to a terminal keyboard protocol as interrupt/input bytes.
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copy(self); return true
            case "a": selectAllTerminalText(self); return true
            case "v": paste(self); return true
            default: break
            }
        }
        if let chord = KeyChord(event: event), chord == searchChord { showPaneSearch(self); return true }
        // SwiftTerm's keyDown toggles Option-as-Meta on any ⌘⌥(⌃)O without telling the
        // app. Settings → Keyboard owns it: let a bound menu item run, never the toggle.
        if event.modifierFlags.contains([.command, .option]), event.charactersIgnoringModifiers == "o" {
            _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    var copyAllTitle: String {
        let terminal = getTerminal()
        if terminal.isCurrentBufferAlternate { return "Copy All Current Screen (No Scrollback)" }
        return scrollback.historyEvicted || terminal.buffer.totalLinesTrimmed > 0
            ? "Copy All Retained Text (Older Lines Evicted)" : "Copy All Retained Text"
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copyAllRetainedText(_:)) {
            (item as? NSMenuItem)?.title = copyAllTitle
            return !retainedText.isEmpty
        }
        if item.action == #selector(selectAllTerminalText(_:)) { return true }
        if item.action == #selector(pasteEscapedPath(_:)) { return true }
        if item.action == #selector(showPaneSearch(_:)) || item.action == #selector(clearTerminal(_:)) { return true }
        if item.action == #selector(openContextLink(_:)) || item.action == #selector(copyContextLink(_:)) { return contextLink != nil }
        if item.action == #selector(copy(_:)) { return !selectedText.isEmpty }
        return super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Context actions belong to the clicked pane, preserving its selection.
        window?.makeFirstResponder(self)
        onFocused?()
        let menu = NSMenu()
        let position = bufferPosition(for: event), terminal = getTerminal()
        let click = TerminalLinkClick(
            link: terminal.link(at: .buffer(position), mode: .explicitAndImplicit), explicit: terminal.linkIsExplicit(at: .buffer(position)), position: position)
        contextLink = nil
        if let described = describeLink?(click) {
            contextLink = (described.click, described.copyText)
            for (title, action) in [(described.openTitle, #selector(openContextLink(_:))), (described.copyTitle, #selector(copyContextLink(_:)))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        for (title, action) in [
            ("Copy", #selector(copy(_:))),
            (copyAllTitle, #selector(copyAllRetainedText(_:))),
            ("Select All", #selector(selectAllTerminalText(_:))),
            ("Paste", #selector(paste(_:))),
            ("Paste Escaped Path", #selector(pasteEscapedPath(_:))),
            ("Find…", #selector(showPaneSearch(_:))),
            ("Clear", #selector(clearTerminal(_:)))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    private var contextLink: (click: TerminalLinkClick, copyText: String)?

    @objc func openContextLink(_ sender: Any?) {
        guard let contextLink else { return }
        // Choosing the menu item is the gesture.
        lastUserGesture = Date()
        defer { lastUserGesture = nil }
        onOpenLink?(contextLink.click)
    }

    @objc func copyContextLink(_ sender: Any?) {
        guard let contextLink else { return }
        writePlainText(contextLink.copyText)
    }

    override func mouseDown(with event: NSEvent) {
        onFocused?()
        super.mouseDown(with: event)
    }

    /// Set only while a click is being handled; links open only during one.
    var lastUserGesture: Date?
    /// The clicked cell and whether it holds an OSC 8 hyperlink; set only during `mouseUp`.
    private(set) var linkClick: TerminalLinkClick?

    override func mouseUp(with event: NSEvent) {
        // SwiftTerm requests link opening from mouseUp; the gesture ends with this click.
        lastUserGesture = Date()
        let position = bufferPosition(for: event)
        linkClick = TerminalLinkClick(link: nil, explicit: getTerminal().linkIsExplicit(at: .buffer(position)), position: position)
        defer { lastUserGesture = nil; linkClick = nil }
        super.mouseUp(with: event)
    }

    var screenText: String {
        let terminal = getTerminal()
        var count = 0
        while terminal.bufferLine(atRow: count) != nil { count += 1 }
        guard count > 0 else { return "" }
        return terminal.getText(start: Position(col: 0, row: max(0, count - terminal.rows)), end: Position(col: terminal.cols, row: count - 1))
    }

    var retainedText: String {
        let terminal = getTerminal()
        var count = 0
        while terminal.bufferLine(atRow: count) != nil { count += 1 }
        guard count > 0 else { return "" }
        // getBufferAsData does not resolve SwiftTerm's grapheme table and emits
        // NUL continuation cells. getText uses the engine's Unicode-aware path.
        return terminal.getText(
            start: Position(col: 0, row: 0),
            end: Position(col: terminal.cols, row: count - 1))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityValue() -> Any? { retainedText }
    override func accessibilityNumberOfCharacters() -> Int { (retainedText as NSString).length }
    override func accessibilitySelectedText() -> String? { selectedText }

    override func accessibilitySelectedTextRange() -> NSRange {
        guard selection.active else { return NSRange(location: (retainedText as NSString).length, length: 0) }
        let position = Position.compare(selection.start, selection.end) == .after ? selection.end : selection.start
        let prefix = getTerminal().getText(start: Position(col: 0, row: 0), end: position)
        let selected = selectedText
        let range = NSRange(location: (prefix as NSString).length, length: (selected as NSString).length)
        // Reject a range if engine trimming/wrapping makes it unrepresentable.
        guard accessibilityString(for: range) == selected else { return NSRange(location: NSNotFound, length: 0) }
        return range
    }

    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }

    func display(_ data: Data) {
        feed(byteArray: Array(data)[...])
        scrollback.enforce(on: self)
        onContentsChanged?()
        // Coalesce notifications, never parser input: reads retain byte order.
        guard !accessibilityUpdateScheduled else { return }
        accessibilityUpdateScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self else { return }
            self.accessibilityUpdateScheduled = false
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }

    override func accessibilityString(for range: NSRange) -> String? {
        let text = retainedText as NSString
        guard range.location != NSNotFound, range.location <= text.length,
            range.length <= text.length - range.location
        else { return nil }
        return text.substring(with: range)
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0) }
    }

    override func accessibilityLine(for index: Int) -> Int {
        let text = retainedText as NSString
        guard index >= 0, index <= text.length else { return NSNotFound }
        return text.substring(to: index).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        guard line >= 0 else { return NSRange(location: NSNotFound, length: 0) }
        let lines = retainedText.components(separatedBy: "\n")
        guard line < lines.count else { return NSRange(location: NSNotFound, length: 0) }
        let start = lines.prefix(line).reduce(0) { $0 + ($1 as NSString).length + 1 }
        return NSRange(location: start, length: (lines[line] as NSString).length)
    }
}
