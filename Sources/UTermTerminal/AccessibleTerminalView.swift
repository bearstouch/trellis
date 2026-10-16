import AppKit
import SwiftTerm
import UTermCore

/// SwiftTerm 1.20's macOS accessibility helper is a stub. Supply a native text
/// area interface here so assistive clients can read actual retained terminal text.
@MainActor
final class AccessibleTerminalView: TerminalView {
    var onFocused: (() -> Void)?
    var onPasteRequested: ((TerminalPasteInput) -> Void)?
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
            return getTerminal().getText(start: Position(col: 0, row: first),
                                         end: Position(col: getTerminal().cols, row: last))
        }
        return selection.getSelectedText()
    }

    private func writePlainText(_ text: String) {
        // The engine resolves ANSI and grapheme cells. Defensively exclude
        // remaining control scalars without damaging combining marks or ZWJ.
        let plain = String(text.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || ($0.value >= 32 && !((127...159).contains($0.value)))
        })
        guard !plain.isEmpty else { return }
        writeClipboard(plain)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Consume Cmd-C even when Copy is disabled. It must never fall through
        // to a terminal keyboard protocol as interrupt/input bytes.
        if window?.firstResponder === self,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copy(self); return true
            case "a": selectAllTerminalText(self); return true
            case "v": paste(self); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    var copyAllTitle: String {
        let terminal = getTerminal()
        if terminal.isCurrentBufferAlternate { return "Copy All Current Screen (No Scrollback)" }
        return terminal.buffer.totalLinesTrimmed > 0
            ? "Copy All Retained Text (Older Lines Evicted)" : "Copy All Retained Text"
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copyAllRetainedText(_:)) {
            (item as? NSMenuItem)?.title = copyAllTitle
            return !retainedText.isEmpty
        }
        if item.action == #selector(selectAllTerminalText(_:)) { return true }
        if item.action == #selector(pasteEscapedPath(_:)) { return true }
        if item.action == #selector(copy(_:)) { return !selectedText.isEmpty }
        return super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Context actions belong to the clicked pane, preserving its selection.
        window?.makeFirstResponder(self)
        onFocused?()
        let menu = NSMenu()
        for (title, action) in [("Copy", #selector(copy(_:))),
                                (copyAllTitle, #selector(copyAllRetainedText(_:))),
                                ("Select All", #selector(selectAllTerminalText(_:))),
                                ("Paste", #selector(paste(_:))),
                                ("Paste Escaped Path", #selector(pasteEscapedPath(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        onFocused?()
        super.mouseDown(with: event)
    }

    var retainedText: String {
        let terminal = getTerminal()
        var count = 0
        while terminal.bufferLine(atRow: count) != nil { count += 1 }
        guard count > 0 else { return "" }
        // getBufferAsData does not resolve SwiftTerm's grapheme table and emits
        // NUL continuation cells. getText uses the engine's Unicode-aware path.
        return terminal.getText(start: Position(col: 0, row: 0),
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
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }

    override func accessibilityString(for range: NSRange) -> String? {
        let text = retainedText as NSString
        guard range.location != NSNotFound, range.location <= text.length,
              range.length <= text.length - range.location else { return nil }
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
