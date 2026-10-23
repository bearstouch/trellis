import AppKit
import SwiftUI
import TrellisCore

/// The panel's commands, also reachable from the keyboard while the editor has focus.
struct ScratchpadEditorCommands {
    var run: () -> Void = {}
    var validate: () -> Void = {}
    var save: () -> Void = {}
}

/// A plain-text code editor (FR-SP02): TextKit 1, so highlighting can use temporary attributes that never enter the
/// text or its undo stack. Every substitution that would change typed code (smart quotes, dashes, replacements,
/// spelling) is off.
struct ScratchpadEditor: NSViewRepresentable {
    @Binding var text: String
    let language: ScratchpadLanguage
    let font: NSFont
    let palette: TerminalPalette
    let issueLines: Set<Int>
    let focusRequest: Int
    let commands: ScratchpadEditorCommands

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Whether replacing `range` keeps the buffer within 64 KB; a change that doesn't grow it, such as deleting from a
    /// larger buffer set by the model, is always allowed.
    static func allowsChange(of text: String, in range: NSRange, to replacement: String) -> Bool {
        let removed = (text as NSString).substring(with: range).utf8.count, added = replacement.utf8.count
        return added <= removed || text.utf8.count - removed + added <= ScratchpadDocument.maximumBytes
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let storage = NSTextStorage(), layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let textView = ScratchpadTextView(frame: NSRect(origin: .zero, size: scroll.contentSize), textContainer: container)
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 10)
        textView.setAccessibilityLabel("Script editor")
        textView.delegate = context.coordinator
        textView.string = text
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let ruler = ScratchpadLineRuler(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.apply(self, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(self, force: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScratchpadEditor
        weak var textView: ScratchpadTextView?
        weak var ruler: ScratchpadLineRuler?
        private var styled: (font: NSFont, palette: TerminalPalette, language: ScratchpadLanguage)?
        private var focusRequest: Int

        init(_ parent: ScratchpadEditor) { self.parent = parent; focusRequest = parent.focusRequest - 1 }

        func apply(_ editor: ScratchpadEditor, force: Bool) {
            guard let textView else { return }
            textView.commands = editor.commands
            textView.setAccessibilityValueDescription("\(editor.language.displayName) script")
            var restyle = force
            if textView.string != editor.text {
                let selection = textView.selectedRanges
                textView.string = editor.text
                // Clamped, never dropped: AppKit raises on an empty selection array, as after Clear or opening a shorter file.
                textView.selectedRanges = Self.clamped(selection.map(\.rangeValue), length: (editor.text as NSString).length).map { NSValue(range: $0) }
                restyle = true
            }
            if force || styled?.font != editor.font || styled?.palette != editor.palette || styled?.language != editor.language {
                styled = (editor.font, editor.palette, editor.language)
                let foreground = NSColor(rgb: editor.palette.foreground)
                textView.font = editor.font
                textView.textColor = foreground
                textView.typingAttributes = [.font: editor.font, .foregroundColor: foreground]
                textView.backgroundColor = NSColor(rgb: editor.palette.background)
                textView.insertionPointColor = NSColor(rgb: editor.palette.cursor)
                textView.selectedTextAttributes = [
                    .backgroundColor: NSColor(rgb: editor.palette.selectionBackground), .foregroundColor: NSColor(rgb: editor.palette.selectionForeground)
                ]
                ruler?.style(font: editor.font, palette: editor.palette)
                restyle = true
            }
            if restyle { highlight() }
            if ruler?.issueLines != editor.issueLines { ruler?.issueLines = editor.issueLines }
            if editor.focusRequest != focusRequest {
                focusRequest = editor.focusRequest
                // After the pane's own focus change, which a pane button may have started.
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, let window = textView.window else { return }
                    window.makeFirstResponder(textView)
                }
            }
        }

        /// Each range moved inside `length`; at least the insertion point at the end.
        static func clamped(_ ranges: [NSRange], length: Int) -> [NSRange] {
            let inside = ranges.map { range -> NSRange in
                let location = min(range.location, length)
                return NSRange(location: location, length: min(range.length, length - location))
            }
            return inside.isEmpty ? [NSRange(location: length, length: 0)] : inside
        }

        func highlight() {
            guard let textView, let layout = textView.layoutManager else { return }
            let length = (textView.string as NSString).length
            let full = NSRange(location: 0, length: length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            let palette = parent.palette
            for token in ScratchpadHighlighter.tokens(in: textView.string, grammar: parent.language.grammar) {
                let range = NSIntersectionRange(token.range, full)
                guard range.length > 0 else { continue }
                layout.addTemporaryAttribute(.foregroundColor, value: Self.color(token.kind, palette: palette), forCharacterRange: range)
            }
        }

        /// Token colors come from the theme's ANSI palette, so they match what the terminal shows.
        static func color(_ kind: ScratchpadTokenKind, palette: TerminalPalette) -> NSColor {
            let index: Int
            switch kind {
            case .keyword: index = 5
            case .command: index = 4
            case .string: index = 2
            case .comment: index = 8
            case .variable: index = 3
            case .number: index = 9
            case .operator: index = 6
            }
            return NSColor(rgb: palette.ansi.indices.contains(index) ? palette.ansi[index] : palette.foreground)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            highlight()
            ruler?.needsDisplay = true
        }

        /// The buffer is limited to 64 KB, so checking and highlighting stay quick.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacementString, !ScratchpadEditor.allowsChange(of: textView.string, in: range, to: replacementString) else { return true }
            NSSound.beep()
            return false
        }
    }
}

/// Handles the scratchpad's shortcuts only while it has focus, before the menus see them: ⌘Return runs,
/// ⌥⌘V validates and ⌥⌘S saves.
final class ScratchpadTextView: NSTextView {
    var commands = ScratchpadEditorCommands()

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        switch (flags, isReturn, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command], true, _): commands.run()
        case ([.command, .option], false, "v"): commands.validate()
        case ([.command, .option], false, "s"): commands.save()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

/// Line numbers beside the editor; lines with a validation issue are drawn bold in the error color with a bar.
final class ScratchpadLineRuler: NSRulerView {
    private weak var textView: NSTextView?
    var issueLines: Set<Int> = [] { didSet { needsDisplay = true } }
    private var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var numberColor = NSColor.secondaryLabelColor
    private var background = NSColor.textBackgroundColor
    private var errorColor = NSColor.systemRed

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSText.didChangeNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var requiredThickness: CGFloat { ruleThickness }
    /// Only the numbers: the ruler's own background and edge line would frame the editor.
    override func draw(_ dirtyRect: NSRect) { drawHashMarksAndLabels(in: dirtyRect) }

    @objc private func redraw() { needsDisplay = true }

    func style(font: NSFont, palette: TerminalPalette) {
        self.font = NSFont.monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 2), weight: .regular)
        background = NSColor(rgb: palette.background)
        let foreground = NSColor(rgb: palette.foreground)
        numberColor = foreground.withAlphaComponent(0.55)
        errorColor = NSColor(rgb: palette.ansi.indices.contains(9) ? palette.ansi[9] : 0xFF5F57)
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        background.setFill()
        bounds.fill()
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer, let scrollView else { return }
        let string = textView.string as NSString
        let visible = scrollView.contentView.bounds
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = 1
        string.enumerateSubstrings(in: NSRange(location: 0, length: characters.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        func draw(_ number: Int, fragment: NSRect) {
            let y = convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y), from: textView).y
            let flagged = issueLines.contains(number)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: flagged ? NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .bold) : font,
                .foregroundColor: flagged ? errorColor : numberColor
            ]
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (fragment.height - size.height) / 2), withAttributes: attributes)
            if flagged {
                errorColor.setFill()
                NSRect(x: ruleThickness - 3, y: y, width: 3, height: fragment.height).fill()
            }
        }
        var index = characters.location
        while index < NSMaxRange(characters) {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            draw(line, fragment: layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: lineRange.location), effectiveRange: nil))
            line += 1
            index = NSMaxRange(lineRange)
        }
        // The empty last line after a final newline, or an empty buffer.
        if layout.extraLineFragmentTextContainer != nil { draw(line, fragment: layout.extraLineFragmentRect) }
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
