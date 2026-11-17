import AppKit
import SwiftUI
import TrellisCore

/// A diff as one text (FR-GC05): its lines joined by newlines, and where each one starts, so a place in the text view maps
/// back to its diff line for the gutter, the tint behind it and VoiceOver.
struct DiffText: Equatable, Sendable {
    let lines: [GitDiffLine]
    let text: String
    /// Each line's first UTF-16 unit in `text`.
    let starts: [Int]
    let length: Int

    init(_ lines: [GitDiffLine]) {
        self.lines = lines
        var text = "", starts: [Int] = [], location = 0
        text.reserveCapacity(lines.reduce(0) { $0 + $1.text.utf8.count + 1 })
        starts.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            starts.append(location)
            text += line.text
            location += line.text.utf16.count
            if index < lines.count - 1 { text += "\n"; location += 1 }
        }
        (self.text, self.starts, length) = (text, starts, location)
    }

    /// The line holding the UTF-16 unit at `location` (its newline counts as its own); nil for an empty diff.
    func lineIndex(at location: Int) -> Int? {
        guard !starts.isEmpty else { return nil }
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= location { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The line's text, without its newline.
    func range(ofLine index: Int) -> NSRange {
        let end = index + 1 < starts.count ? starts[index + 1] - 1 : length
        return NSRange(location: starts[index], length: end - starts[index])
    }

    /// The lines touching `range`, an empty range counting as the line it is in.
    func lineIndices(in range: NSRange) -> ClosedRange<Int>? {
        guard let first = lineIndex(at: range.location), let last = lineIndex(at: max(range.location, NSMaxRange(range) - 1)) else { return nil }
        return first...last
    }

    /// What VoiceOver reads for `range` (FR-GC08): "Added line 12: …" for each whole line in it, and for the first part of
    /// one line, which is what it asks for when a long line wraps. Nil for an empty range or the middle of a line, which
    /// read as their own text.
    func spoken(for range: NSRange, in text: NSString) -> String? {
        guard range.length > 0, NSMaxRange(range) <= length, let indices = lineIndices(in: range), starts[indices.lowerBound] == range.location else { return nil }
        let end = self.range(ofLine: indices.upperBound)
        if NSMaxRange(range) == NSMaxRange(end) || NSMaxRange(range) == NSMaxRange(end) + 1 { return indices.map { lines[$0].spoken }.joined(separator: "\n") }
        guard indices.count == 1, NSMaxRange(range) < NSMaxRange(end) else { return nil }
        let line = lines[indices.lowerBound]
        return GitDiffLine(id: line.id, kind: line.kind, old: line.old, new: line.new, text: text.substring(with: range)).spoken
    }
}

/// A change to scroll to: a new one each time, so asking for the same line twice scrolls twice.
struct DiffJump: Equatable {
    let line: Int
    let id = UUID()
}

/// Whether the diff should take the keyboard when it next reaches the window. A reference, so setting it redraws nothing.
@MainActor final class DiffFocusRequest {
    var pending = false
}

/// The theme colors a diff draws with, read once per redraw of the tab.
struct DiffPalette: Equatable {
    let foreground: Color, muted: Color, accent: Color, added: Color, removed: Color

    @MainActor init(_ model: AppWorkspaceModel) {
        (foreground, muted, accent) = (model.themeColor(.foreground), model.themeColor(.mutedForeground), model.themeColor(.accent))
        (added, removed) = (model.themeColor(.success), model.themeColor(.error))
    }
}

/// The diff drawn in one text view with a gutter for line numbers and marks. As a stack of SwiftUI rows, each line was
/// several views, built and placed as it scrolled into view and kept from then on: a long diff scrolled at ~170 ms a step
/// and slowed the whole app the more of it had been seen. A text view lays out and draws only what is on screen.
struct DiffTextView: NSViewRepresentable {
    let lines: [GitDiffLine]
    let palette: DiffPalette
    let accessibilityName: String
    let jump: DiffJump?
    let reduceMotion: Bool
    let focus: DiffFocusRequest
    /// Returns whether it handled the key (`n`, `p`, `]`, `[`, Return, Esc).
    let onKey: (NSEvent) -> Bool

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let storage = NSTextStorage(), layout = ScratchpadEditor.makeLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let textView = DiffNSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize), textContainer: container)
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        container.lineFragmentPadding = 0
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        let gutter = DiffGutter(textView: textView)
        scroll.verticalRulerView = gutter
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        textView.gutter = gutter
        context.coordinator.textView = textView
        apply(to: textView, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        apply(to: textView, coordinator: context.coordinator)
    }

    private func apply(to textView: DiffNSTextView, coordinator: Coordinator) {
        textView.onKey = onKey
        textView.focus = focus
        textView.setAccessibilityLabel(accessibilityName)
        // The same array is the usual case (any redraw of the tab), and comparing it to itself is immediate.
        if coordinator.lines != lines {
            (coordinator.lines, coordinator.palette) = (lines, palette)
            textView.show(DiffText(lines), colors: DiffColors(palette))
        } else if coordinator.palette != palette {
            coordinator.palette = palette
            textView.recolor(DiffColors(palette))
        }
        if jump != coordinator.jump {
            coordinator.jump = jump
            if let jump { textView.scroll(toLine: jump.line, animated: !reduceMotion) }
        }
        textView.takeFocusIfAsked()
    }

    @MainActor final class Coordinator {
        weak var textView: DiffNSTextView?
        var lines: [GitDiffLine]?
        var palette: DiffPalette?
        var jump: DiffJump?
    }
}

/// The diff's colors for AppKit drawing.
struct DiffColors {
    let foreground: NSColor, muted: NSColor, accent: NSColor, added: NSColor, removed: NSColor

    init(foreground: NSColor, muted: NSColor, accent: NSColor, added: NSColor, removed: NSColor) {
        (self.foreground, self.muted, self.accent, self.added, self.removed) = (foreground, muted, accent, added, removed)
    }

    init(_ palette: DiffPalette) {
        self.init(foreground: NSColor(palette.foreground), muted: NSColor(palette.muted), accent: NSColor(palette.accent), added: NSColor(palette.added), removed: NSColor(palette.removed))
    }

    func tint(_ kind: GitDiffLine.Kind) -> NSColor? {
        switch kind {
        case .added: added
        case .removed: removed
        default: nil
        }
    }

    /// The fill behind a whole line: a hunk header's, or a faint one for added and removed lines.
    func lineFill(_ kind: GitDiffLine.Kind) -> NSColor? { kind == .hunk ? accent.withAlphaComponent(0.08) : tint(kind)?.withAlphaComponent(0.11) }
}

/// The diff's text: read-only and selectable, with each added, removed or hunk line tinted across the full width.
final class DiffNSTextView: NSTextView {
    private(set) var diff = DiffText([])
    private(set) var colors: DiffColors?
    weak var gutter: DiffGutter?
    var onKey: ((NSEvent) -> Bool)?
    var focus: DiffFocusRequest?

    func show(_ diff: DiffText, colors: DiffColors) {
        self.diff = diff
        self.colors = colors
        let font = DiffTextView.font, style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        // Tabs every four columns, wherever on the line: the default stops end after twelve, and a tab past the last one
        // would break the line.
        style.tabStops = []
        style.defaultTabInterval = 4 * (" " as NSString).size(withAttributes: [.font: font]).width
        textStorage?.setAttributedString(NSAttributedString(string: diff.text, attributes: [.font: font, .paragraphStyle: style]))
        applyColors()
        if let scroll = enclosingScrollView {
            // The clip view starts left of zero by the gutter's width (the scroll view insets it), so x is kept as it is.
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: -scroll.contentInsets.top))
            scroll.reflectScrolledClipView(clip)
        }
        restartLayout()
    }

    /// A new theme: the same text in new colors, with its layout, selection and place kept.
    func recolor(_ colors: DiffColors) {
        self.colors = colors
        applyColors()
    }

    private func applyColors() {
        guard let colors, let storage = textStorage else { return }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: colors.foreground, range: NSRange(location: 0, length: storage.length))
        for (index, line) in diff.lines.enumerated() where line.kind == .hunk || line.kind == .note {
            let range = diff.range(ofLine: index)
            storage.addAttribute(.foregroundColor, value: line.kind == .hunk ? colors.accent : colors.muted, range: range)
            if line.kind == .note { storage.addAttribute(.obliqueness, value: 0.18, range: range) }
        }
        storage.endEditing()
        needsDisplay = true
        gutter?.needsDisplay = true
    }

    private func restartLayout() {
        layoutGeneration &+= 1
        laidOut = 0
        let generation = layoutGeneration
        DispatchQueue.main.async { [weak self] in self?.layOutMore(generation) }
    }

    /// A new width wraps the lines again, so what was laid out no longer holds.
    override func setFrameSize(_ newSize: NSSize) {
        let width = frame.width
        super.setFrameSize(newSize)
        if abs(newSize.width - width) > 0.5, diff.length > 0 { restartLayout() }
    }

    /// How far the text has been laid out from its start, in UTF-16 units; the whole text once the height is exact.
    private(set) var laidOut = 0
    private var layoutGeneration = 0
    /// Main-thread time one slice of laying out may take, so scrolling and keys stay responsive between slices.
    static let layoutSlice: TimeInterval = 0.006

    /// Lays the rest of the diff out a slice at a time. Only what is on screen is laid out to draw it, and the height of
    /// the rest is a guess, a third too small for a long diff with wrapped lines: the scroller crept as scrolling replaced
    /// the guess. Laid out through, shortly after it opens, the height is exact.
    private func layOutMore(_ generation: Int) {
        // Not before the view has its width: a new width starts this again (`setFrameSize`).
        guard generation == layoutGeneration, let layout = layoutManager, laidOut < diff.length, bounds.width > 1 else { return }
        let deadline = Date().addingTimeInterval(Self.layoutSlice)
        repeat {
            let next = min(diff.length, laidOut + 16_384)
            layout.ensureLayout(forCharacterRange: NSRange(location: laidOut, length: next - laidOut))
            laidOut = next
        } while laidOut < diff.length && Date() < deadline
        gutter?.needsDisplay = true
        guard laidOut < diff.length else { return }
        DispatchQueue.main.async { [weak self] in self?.layOutMore(generation) }
    }

    /// The diff lines on screen, each with the rectangle its text takes (all of a wrapped line), in the text view's coordinates.
    func visibleLines(in rect: NSRect) -> [(index: Int, rect: NSRect)] {
        guard let layout = layoutManager, let container = textContainer, !diff.lines.isEmpty else { return [] }
        let origin = textContainerOrigin
        let glyphs = layout.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard var indices = diff.lineIndices(in: characters) else { return [] }
        // An empty last line has no glyph to be found by: it is the extra fragment after the final newline.
        let last = diff.lines.count - 1
        if indices.upperBound < last, diff.range(ofLine: last).length == 0, layout.extraLineFragmentTextContainer != nil,
            layout.extraLineFragmentRect.maxY + origin.y > rect.minY, layout.extraLineFragmentRect.minY + origin.y < rect.maxY
        {
            indices = indices.lowerBound...last
        }
        return indices.map { index in (index, lineRect(index, layout: layout, container: container)) }
    }

    private func lineRect(_ index: Int, layout: NSLayoutManager, container: NSTextContainer) -> NSRect {
        let range = diff.range(ofLine: index)
        var rect: NSRect
        if range.length == 0 {
            // An empty line has no glyph of its own: its newline's fragment, or the extra fragment after the last newline.
            if range.location >= diff.length {
                rect = layout.extraLineFragmentTextContainer != nil ? layout.extraLineFragmentRect : .zero
            } else {
                rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            }
        } else {
            rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            // The line spacing under the last fragment belongs to the line too, so tints meet.
            let last = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: NSMaxRange(range) - 1), effectiveRange: nil)
            rect = NSRect(x: 0, y: rect.minY, width: rect.width, height: last.maxY - rect.minY)
        }
        return NSRect(x: 0, y: rect.minY + textContainerOrigin.y, width: bounds.width, height: rect.height)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let colors else { return }
        // The dirty rectangle can be far larger than what is on screen; tinting all of it would lay the whole diff out.
        for (index, lineRect) in visibleLines(in: rect.intersection(visibleRect.insetBy(dx: 0, dy: -200))) {
            guard let fill = colors.lineFill(diff.lines[index].kind) else { continue }
            fill.setFill()
            lineRect.fill(using: .sourceOver)
        }
    }

    /// Scrolls so the line sits a quarter of the way down, as `n` and `p` do.
    func scroll(toLine index: Int, animated: Bool) {
        guard diff.lines.indices.contains(index), let layout = layoutManager, let container = textContainer, let scroll = enclosingScrollView else { return }
        if diff.range(ofLine: index).location >= diff.length { layout.ensureLayout(for: container) } else { layout.ensureLayout(forCharacterRange: diff.range(ofLine: index)) }
        let line = lineRect(index, layout: layout, container: container)
        let visible = scroll.contentView.bounds.height
        let top = -scroll.contentInsets.top
        let target = NSPoint(x: scroll.contentView.bounds.origin.x, y: max(top, min(line.minY - visible * 0.25, max(top, frame.height - visible))))
        let clip = scroll.contentView
        scrollGeneration &+= 1
        let generation = scrollGeneration
        guard animated, window?.isVisible == true else { clip.scroll(to: target); scroll.reflectScrolledClipView(clip); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            clip.animator().setBoundsOrigin(target)
        } completionHandler: { [weak self, weak scroll, weak clip] in
            // Where it was going, whatever became of the animation; a newer jump has its own end.
            MainActor.assumeIsolated {
                guard let self, let scroll, let clip, generation == self.scrollGeneration else { return }
                clip.scroll(to: target)
                scroll.reflectScrolledClipView(clip)
            }
        }
    }

    private var scrollGeneration = 0

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    func takeFocusIfAsked() {
        guard let focus, focus.pending, let window else { return }
        focus.pending = false
        // Not from a field being typed in, such as the Changes filter: its next letters would be the diff's keys.
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { return }
        window.makeFirstResponder(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // After the window has taken the view in, so it can be made first responder.
        DispatchQueue.main.async { [weak self] in self?.takeFocusIfAsked() }
    }

    /// A diff that had the keyboard hands it to the one replacing it (the next file, or the same one read again).
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, window?.firstResponder === self { focus?.pending = true }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: VoiceOver (FR-GC08)

    override func accessibilityString(for range: NSRange) -> String? { diff.spoken(for: range, in: string as NSString) ?? super.accessibilityString(for: range) }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        diff.spoken(for: range, in: string as NSString).map { NSAttributedString(string: $0) } ?? super.accessibilityAttributedString(for: range)
    }
}

/// Old and new line numbers and the `+`/`−` mark beside each diff line, tinted like the line.
final class DiffGutter: NSRulerView {
    weak var textView: DiffNSTextView?
    static let numberWidth: CGFloat = 52
    static let markWidth: CGFloat = 20

    init(textView: DiffNSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = Self.numberWidth * 2 + Self.markWidth
        // Views don't clip by default since the macOS 14 SDK; unclipped, numbers paint over the views around the diff.
        clipsToBounds = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var requiredThickness: CGFloat { ruleThickness }
    /// Only the numbers and tints: the ruler's own background and edge line would frame the diff.
    override func draw(_ dirtyRect: NSRect) { drawHashMarksAndLabels(in: dirtyRect) }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let colors = textView.colors else { return }
        let font = DiffTextView.font, bold = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
        let height = font.ascender - font.descender + font.leading
        for (index, lineRect) in textView.visibleLines(in: textView.visibleRect) {
            let line = textView.diff.lines[index]
            let y = convert(NSPoint(x: 0, y: lineRect.minY), from: textView).y
            let band = NSRect(x: 0, y: y, width: ruleThickness, height: lineRect.height)
            if let fill = colors.lineFill(line.kind) { fill.setFill(); band.fill(using: .sourceOver) }
            if let tint = colors.tint(line.kind) {
                tint.withAlphaComponent(0.18).setFill()
                NSRect(x: 0, y: y, width: Self.numberWidth * 2, height: lineRect.height).fill(using: .sourceOver)
            }
            func draw(_ text: String, right: CGFloat, attributes: [NSAttributedString.Key: Any]) {
                let label = text as NSString
                label.draw(at: NSPoint(x: right - label.size(withAttributes: attributes).width, y: y + max(0, (font.pointSize + 5 - height) / 2)), withAttributes: attributes)
            }
            let numbers: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.muted]
            if let old = line.old { draw(String(old), right: Self.numberWidth - 6, attributes: numbers) }
            if let new = line.new { draw(String(new), right: Self.numberWidth * 2 - 6, attributes: numbers) }
            if let tint = colors.tint(line.kind) {
                let mark = line.kind == .added ? "+" : "−"
                let attributes: [NSAttributedString.Key: Any] = [.font: bold, .foregroundColor: tint]
                draw(mark, right: Self.numberWidth * 2 + (Self.markWidth + (mark as NSString).size(withAttributes: attributes).width) / 2, attributes: attributes)
            }
        }
    }
}
