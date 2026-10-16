import AppKit
import SwiftTerm

/// SwiftTerm 1.20's macOS accessibility helper is a stub. Supply a native text
/// area interface here so assistive clients can read actual retained terminal text.
@MainActor
final class AccessibleTerminalView: TerminalView {
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
    override func accessibilitySelectedText() -> String? { selection.getSelectedText() }

    override func accessibilitySelectedTextRange() -> NSRange {
        guard selection.active else { return NSRange(location: (retainedText as NSString).length, length: 0) }
        let position = Position.compare(selection.start, selection.end) == .after ? selection.end : selection.start
        let prefix = getTerminal().getText(start: Position(col: 0, row: 0), end: position)
        let selected = selection.getSelectedText()
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
