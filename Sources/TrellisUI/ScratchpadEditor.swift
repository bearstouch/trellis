import AppKit
import SwiftUI
import TrellisCore

/// The panel's commands, also reachable from the keyboard while the editor has focus.
struct ScratchpadEditorCommands {
    var run: () -> Void = {}
    var validate: () -> Void = {}
    var save: () -> Void = {}
    /// ⌘S and ⌘L, for editor tabs (FR-ED03, FR-ED04); nil leaves the chords to the menus.
    var saveFile: (() -> Void)?
    var goToLine: (() -> Void)?
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
    var accessibilityName = L("Script editor")
    /// Read after the language name, as in "sh script".
    var contentNoun = L("script")
    var maximumBytes = ScratchpadDocument.maximumBytes
    /// Editor tabs: a band behind the cursor's line, a pending jump (cleared through `onJumped`), the cursor's 1-based
    /// line and column, and the size above which highlighting is off (FR-ED03).
    var highlightsCurrentLine = false
    var jump: EditorJump?
    var onJumped: () -> Void = {}
    var onCursor: ((Int, Int) -> Void)?
    var highlightLimit = Int.max
    /// False while the editor is mounted but not shown: focus requests are noted, not acted on.
    var acceptsFocus = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Whether replacing `range` keeps the buffer within `limit` (64 KB for scripts); a change that doesn't grow it,
    /// such as deleting from a larger buffer set by the model, is always allowed.
    static func allowsChange(of text: String, in range: NSRange, to replacement: String, limit: Int = ScratchpadDocument.maximumBytes) -> Bool {
        let removed = (text as NSString).substring(with: range).utf8.count, added = replacement.utf8.count
        return added <= removed || text.utf8.count - removed + added <= limit
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
        textView.setAccessibilityLabel(accessibilityName)
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
        private var jumpID: UUID?
        private var pendingHighlight: DispatchWorkItem?

        init(_ parent: ScratchpadEditor) { self.parent = parent; focusRequest = parent.focusRequest - 1 }

        func apply(_ editor: ScratchpadEditor, force: Bool) {
            guard let textView else { return }
            textView.commands = editor.commands
            textView.currentLineColor = editor.highlightsCurrentLine ? Self.currentLineColor(editor.palette) : nil
            textView.setAccessibilityValueDescription(L("%1$@ %2$@", editor.language.displayName, editor.contentNoun))
            var restyle = force
            if textView.string != editor.text {
                let selection = textView.selectedRanges
                // Typing's undo steps name ranges in the old text; undoing one after Clear or Open would raise.
                if let storage = textView.textStorage { textView.undoManager?.removeAllActions(withTarget: storage) }
                textView.breakUndoCoalescing()
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
            if restyle { highlight(); ruler?.fitLineNumbers(in: textView.string as NSString); ruler?.needsDisplay = true; textView.needsDisplay = true }
            if ruler?.issueLines != editor.issueLines { ruler?.issueLines = editor.issueLines }
            if let jump = editor.jump, jump.id != jumpID {
                jumpID = jump.id
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    Self.move(textView, toLine: jump.line, column: jump.column)
                    self.parent.onJumped()
                }
            }
            if editor.focusRequest != focusRequest {
                focusRequest = editor.focusRequest
                guard editor.acceptsFocus else { return }
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

        /// The cursor's line band: the foreground faintly over the background, so it suits light and dark themes (FR-ED11).
        static func currentLineColor(_ palette: TerminalPalette) -> NSColor { NSColor(rgb: palette.foreground).withAlphaComponent(0.07) }

        /// Selects `column` (1-based) of `line` and scrolls it to the middle; lines past the end go to the last.
        static func move(_ textView: NSTextView, toLine line: Int, column: Int?) {
            let string = textView.string as NSString
            var location = 0, current = 1
            while current < max(1, line) {
                let newline = string.range(of: "\n", options: .literal, range: NSRange(location: location, length: string.length - location))
                guard newline.location != NSNotFound else { break }
                location = newline.location + 1
                current += 1
            }
            let lineEnd = string.range(of: "\n", options: .literal, range: NSRange(location: location, length: string.length - location))
            let end = lineEnd.location == NSNotFound ? string.length : lineEnd.location
            let target = min(location + max(0, (column ?? 1) - 1), end)
            textView.setSelectedRange(NSRange(location: target, length: 0))
            if let layout = textView.layoutManager, let container = textView.textContainer, let scroll = textView.enclosingScrollView {
                layout.ensureLayout(forCharacterRange: NSRange(location: target, length: 0))
                let glyph = layout.glyphIndexForCharacter(at: min(target, max(0, string.length - 1)))
                var rect = string.length == 0 ? .zero : layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                rect.origin.y += textView.textContainerOrigin.y
                let visible = scroll.contentView.bounds.height
                let y = max(0, min(rect.midY - visible / 2, textView.frame.height - visible))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            } else {
                textView.scrollRangeToVisible(NSRange(location: target, length: 0))
            }
        }

        /// Large texts are highlighted a moment after typing stops, so each key stays quick.
        func scheduleHighlight() {
            pendingHighlight?.cancel()
            guard let textView, (textView.string as NSString).length > 65_536 else { highlight(); return }
            let work = DispatchWorkItem { [weak self] in self?.highlight() }
            pendingHighlight = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        func highlight() {
            guard let textView, let layout = textView.layoutManager else { return }
            let length = (textView.string as NSString).length
            let full = NSRange(location: 0, length: length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            guard textView.string.utf8.count <= parent.highlightLimit else { return }
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
            case .type: index = 12
            }
            return NSColor(rgb: palette.ansi.indices.contains(index) ? palette.ansi[index] : palette.foreground)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            scheduleHighlight()
            ruler?.fitLineNumbers(in: textView.string as NSString)
            ruler?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            if textView.currentLineColor != nil { textView.needsDisplay = true }
            guard let onCursor = parent.onCursor else { return }
            let string = textView.string as NSString
            let location = min(textView.selectedRange().location, string.length)
            let before = string.substring(to: location)
            let line = 1 + before.utf16.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
            let lineStart = string.range(of: "\n", options: [.literal, .backwards], range: NSRange(location: 0, length: location))
            onCursor(line, location - (lineStart.location == NSNotFound ? 0 : lineStart.location + 1) + 1)
        }

        /// The buffer is limited (64 KB for scripts), so checking and highlighting stay quick.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacementString, !ScratchpadEditor.allowsChange(of: textView.string, in: range, to: replacementString, limit: parent.maximumBytes) else {
                return true
            }
            NSSound.beep()
            return false
        }
    }
}

/// Handles the scratchpad's shortcuts only while it has focus, before the menus see them: ⌘Return runs,
/// ⌥⌘V validates and ⌥⌘S saves.
final class ScratchpadTextView: NSTextView {
    var commands = ScratchpadEditorCommands()
    /// Fills the cursor's line behind the text when set (editor tabs).
    var currentLineColor: NSColor?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let currentLineColor, let layout = layoutManager, selectedRange().length == 0 else { return }
        let location = selectedRange().location
        var line: NSRect
        if location >= (string as NSString).length, layout.extraLineFragmentTextContainer != nil {
            line = layout.extraLineFragmentRect
        } else {
            let glyph = layout.glyphIndexForCharacter(at: min(location, max(0, (string as NSString).length - 1)))
            guard glyph < layout.numberOfGlyphs else { return }
            line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        line.origin.y += textContainerOrigin.y
        line.origin.x = 0
        line.size.width = bounds.width
        currentLineColor.setFill()
        line.intersection(rect).fill(using: .sourceOver)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        switch (flags, isReturn, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command], false, "s") where commands.saveFile != nil: commands.saveFile?()
        case ([.command], false, "l") where commands.goToLine != nil: commands.goToLine?()
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
        // Views don't clip by default since the macOS 14 SDK; unclipped, numbers paint over the views around the editor.
        clipsToBounds = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var requiredThickness: CGFloat { ruleThickness }
    /// Only the numbers: the ruler's own background and edge line would frame the editor.
    override func draw(_ dirtyRect: NSRect) { drawHashMarksAndLabels(in: dirtyRect) }

    /// Widens the ruler for the text's largest line number, so five-digit numbers fit.
    func fitLineNumbers(in string: NSString) {
        let lines = 1 + (string as String).utf16.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        let digits = max(3, String(lines).count)
        let width = ceil(("8" as NSString).size(withAttributes: [.font: font]).width * CGFloat(digits)) + 16
        if abs(ruleThickness - max(40, width)) > 0.5 { ruleThickness = max(40, width) }
    }

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
        guard let textView, let layout = textView.layoutManager, let (lines, next) = visibleLines else { return }
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
        for line in lines { draw(line.number, fragment: layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: line.location), effectiveRange: nil)) }
        // The empty last line after a final newline, or an empty buffer.
        if layout.extraLineFragmentTextContainer != nil { draw(next, fragment: layout.extraLineFragmentRect) }
    }

    /// The lines the text view is showing now.
    var visibleLines: (lines: [(number: Int, location: Int)], next: Int)? {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
        // In the container's coordinates: the clip view's bounds only match them while the text view's frame origin is zero.
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        return Self.lines(in: textView.string as NSString, visible: layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
    }

    /// The lines starting in, or wrapping into, `visible`, numbered by `\n` alone as validation counts them, and the number
    /// after the last. The first visible fragment may continue a wrapped line, so numbering starts at that line's start.
    nonisolated static func lines(in string: NSString, visible: NSRange) -> (lines: [(number: Int, location: Int)], next: Int) {
        let length = string.length
        var location = min(visible.location, length)
        let previous = string.range(of: "\n", options: [.literal, .backwards], range: NSRange(location: 0, length: location))
        location = previous.location == NSNotFound ? 0 : previous.location + 1
        var number = 1 + string.substring(to: location).utf16.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        var lines: [(number: Int, location: Int)] = []
        while location < min(NSMaxRange(visible), length) {
            lines.append((number, location))
            number += 1
            let newline = string.range(of: "\n", options: .literal, range: NSRange(location: location, length: length - location))
            guard newline.location != NSNotFound else { break }
            location = newline.location + 1
        }
        return (lines, number)
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
