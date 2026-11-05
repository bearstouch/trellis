import AppKit
import SwiftUI
import TrellisCore
import TrellisHighlight

/// The tool dock's editor (FR-TD11): the scratchpad's text view, with tree-sitter highlighting instead of the
/// scratchpad's tokenizer, a 2 MiB limit, a read-only mode and the line a `file:line` link opened at.
struct FileEditor: NSViewRepresentable {
    @Binding var text: String
    let fileName: String
    let languageName: String
    let font: NSFont
    let palette: TerminalPalette
    let isEditable: Bool
    /// 1-based; marked in the gutter and scrolled to when `revealRequest` changes.
    let markedLine: Int?
    let revealRequest: Int
    let focusRequest: Int
    let saveChord: KeyChord?
    let save: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, textView, ruler) = ScratchpadEditor.makeCodeView(accessibilityName: "\(fileName) editor", delegate: context.coordinator)
        // Lays out only what is shown, so a 2 MiB file opens without laying out every line.
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.apply(self, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(self, force: false)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.highlighter?.detach() }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FileEditor
        weak var textView: ScratchpadTextView?
        weak var ruler: ScratchpadLineRuler?
        private(set) var highlighter: CodeHighlighter?
        private var styled: (font: NSFont, palette: TerminalPalette)?
        private var focusRequest: Int, revealRequest: Int

        init(_ parent: FileEditor) {
            self.parent = parent
            focusRequest = parent.focusRequest - 1
            revealRequest = parent.revealRequest - 1
        }

        func apply(_ editor: FileEditor, force: Bool) {
            guard let textView else { return }
            textView.saveChord = editor.saveChord
            textView.saveFile = editor.save
            textView.isEditable = editor.isEditable
            textView.setAccessibilityValueDescription(editor.isEditable ? "\(editor.languageName) file" : "\(editor.languageName) file, read only")
            if force || styled?.font != editor.font || styled?.palette != editor.palette {
                styled = (editor.font, editor.palette)
                ScratchpadEditor.style(textView, ruler: ruler, font: editor.font, palette: editor.palette)
                highlighter?.setPalette(editor.palette)
            }
            if textView.string != editor.text {
                // A reload from disk replaced the buffer: undo steps name ranges in the old text.
                let selection = textView.selectedRanges
                if let storage = textView.textStorage { textView.undoManager?.removeAllActions(withTarget: storage) }
                textView.breakUndoCoalescing()
                textView.string = editor.text
                textView.selectedRanges = ScratchpadEditor.Coordinator.clamped(selection.map(\.rangeValue), length: (editor.text as NSString).length)
                    .map { NSValue(range: $0) }
                highlighter?.textWasReplaced()
            }
            if highlighter == nil, force {
                highlighter = CodeHighlighter.make(for: textView, fileName: editor.fileName, palette: editor.palette)
            }
            if ruler?.markedLine != editor.markedLine { ruler?.markedLine = editor.markedLine }
            if editor.revealRequest != revealRequest {
                revealRequest = editor.revealRequest
                if let line = editor.markedLine { DispatchQueue.main.async { [weak self] in self?.reveal(line: line) } }
            }
            if editor.focusRequest != focusRequest {
                focusRequest = editor.focusRequest
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, let window = textView.window else { return }
                    window.makeFirstResponder(textView)
                }
            }
        }

        /// Scrolls to `line` (1-based) and puts the insertion point at its start.
        func reveal(line: Int) {
            guard let textView else { return }
            let text = textView.string as NSString
            var location = 0, current = 1
            while current < line, location < text.length {
                let newline = text.range(of: "\n", options: .literal, range: NSRange(location: location, length: text.length - location))
                guard newline.location != NSNotFound else { break }
                location = newline.location + 1
                current += 1
            }
            let range = NSRange(location: min(location, text.length), length: 0)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            ruler?.needsDisplay = true
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacementString,
                !ScratchpadEditor.allowsChange(of: textView.string, in: range, to: replacementString, limit: EditorFile.maximumBytes)
            else { return true }
            NSSound.beep()
            return false
        }
    }
}
