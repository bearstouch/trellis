import AppKit
import SwiftUI
import XCTest
import TrellisCore
@testable import TrellisUI

/// The text view bridge under typing and model updates (editor typing performance review).
final class ScratchpadEditorReviewTests: XCTestCase {
    @MainActor private final class Box { var text = "" }
    /// Every window a test opens. Their text views hold up to 2 MB; left open, a later redraw lays it all out again, which
    /// froze CI for the rest of the run. Each is emptied and closed after its test.
    nonisolated(unsafe) private var windows: [NSWindow] = []

    override func tearDown() {
        let open = windows
        windows = []
        MainActor.assumeIsolated {
            for window in open {
                for case let text as NSTextView in window.contentView?.subviews ?? [] { text.string = "" }
                window.contentView = nil
                window.close()
            }
        }
        super.tearDown()
    }

    @MainActor
    private func makeEditor(_ box: Box, window: NSWindow, language: ScratchpadLanguage = .markdown) -> (ScratchpadTextView, ScratchpadEditor.Coordinator, (String) -> ScratchpadEditor) {
        let textView = ScratchpadTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.allowsUndo = true
        window.contentView?.addSubview(textView)
        let editor = { (text: String) in
            box.text = text
            return ScratchpadEditor(
                text: Binding(get: { box.text }, set: { box.text = $0 }), language: language, font: .systemFont(ofSize: 12), palette: .builtIn,
                issueLines: [], focusRequest: 0, commands: ScratchpadEditorCommands())
        }
        let coordinator = ScratchpadEditor.Coordinator(editor(box.text))
        coordinator.textView = textView
        textView.delegate = coordinator
        return (textView, coordinator, editor)
    }

    @MainActor
    func testTypingSyncsANativeCopyAndAnUnchangedRedrawLeavesTheViewAlone() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let box = Box()
        let (textView, coordinator, editor) = makeEditor(box, window: window)
        coordinator.apply(editor("hello"), force: true)
        XCTAssertEqual(textView.string, "hello")
        XCTAssertEqual(coordinator.synced, "hello")

        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertText(" world", replacementRange: textView.selectedRange())
        XCTAssertEqual(box.text, "hello world", "Typing reaches the model")
        XCTAssertTrue(box.text.isContiguousUTF8, "as a native string, so comparing it is a byte comparison")
        XCTAssertEqual(coordinator.synced, box.text)

        // Any redraw of the window updates the editor with the model's text, which is what the view already has.
        coordinator.parent = editor(box.text)
        coordinator.apply(coordinator.parent, force: false)
        XCTAssertEqual(textView.undoManager?.canUndo, true, "An unchanged text isn't set again, so typing's undo survives")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 11, length: 0))

        // A change from the model (reload, Clear) still replaces the text and clamps the selection.
        coordinator.parent = editor("hi")
        coordinator.apply(coordinator.parent, force: false)
        XCTAssertEqual(textView.string, "hi")
        XCTAssertEqual(coordinator.synced, "hi")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    private func color(_ textView: NSTextView, at index: Int) -> NSColor? {
        textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
    }

    @MainActor
    func testLongTextsAreHighlightedOffTheMainThreadAndAStaleResultIsDropped() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let comment = ScratchpadEditor.Coordinator.color(.comment, palette: .builtIn)

        let small = Box()
        let (smallView, smallCoordinator, smallEditor) = makeEditor(small, window: window, language: .sh)
        smallCoordinator.apply(smallEditor("# note\necho hi\n"), force: true)
        XCTAssertEqual(color(smallView, at: 0), comment, "A short text is highlighted at once")

        let long = String(repeating: "echo hello world\n", count: 1_000)
        XCTAssertGreaterThan((long as NSString).length, ScratchpadEditor.Coordinator.immediateHighlightLimit)
        let box = Box()
        let (textView, coordinator, editor) = makeEditor(box, window: window, language: .sh)
        coordinator.apply(editor("# first\n" + long), force: true)
        XCTAssertNil(color(textView, at: 0), "A long text isn't tokenized on the main thread")
        let deadline = Date().addingTimeInterval(5)
        while color(textView, at: 0) == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(color(textView, at: 0), comment, "…and is highlighted a moment later")

        // A key while the long text is being tokenized: only the result for the newest text may land.
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("echo x # tail\n", replacementRange: textView.selectedRange())
        textView.insertText("ls\n", replacementRange: textView.selectedRange())
        let tail = ("echo x " as NSString).length, later = Date().addingTimeInterval(5)
        while color(textView, at: tail) != comment, Date() < later { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(box.text, "echo x # tail\nls\n# first\n" + long)
        XCTAssertNotEqual(color(textView, at: 0), comment, "`echo` isn't a comment: no stale tokens from before the keys")
        XCTAssertEqual(color(textView, at: ("echo x # tail\nls\n" as NSString).length), comment, "the newest text's comment is colored")
        XCTAssertEqual(color(textView, at: ("echo x " as NSString).length), comment)

        // A new long text from the model, replaced by a short one before its tokens arrive: they're dropped, not applied
        // over the short text.
        coordinator.parent = editor("# again\n" + long)
        coordinator.apply(coordinator.parent, force: false)
        coordinator.parent = editor("echo hi")
        coordinator.apply(coordinator.parent, force: false)
        XCTAssertNotEqual(color(textView, at: 0), comment)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotEqual(color(textView, at: 0), comment, "The long text's comment never colors the short text")
        withExtendedLifetime([coordinator, smallCoordinator]) {}
    }

    func testNewlinesAreCountedLikeAPlainCountAcrossChunksAndSurrogates() {
        func plain(_ text: String, before end: Int) -> Int { Array(text.utf16.prefix(max(0, end))).filter { $0 == 10 }.count }
        let long = String(repeating: "line 👋🏽 with emoji\n", count: 2_000) + "last"
        XCTAssertGreaterThan((long as NSString).length, 8_192 * 3, "Spans several chunks")
        for text in ["", "\n", "no newline", "a\nb\n", "\n\n\n", "é\n🇵🇹\n", long] {
            let string = text as NSString
            for end in Set([0, 1, string.length / 2, string.length - 1, string.length, string.length + 5, -3, 8_192, 8_193]) {
                XCTAssertEqual(ScratchpadLineRuler.newlines(in: string, before: end), plain(text, before: min(end, string.length)), "\(end) in \(string.length)")
            }
        }
        let lines = ScratchpadLineRuler.lines(in: long as NSString, visible: NSRange(location: 8_200, length: 100))
        XCTAssertEqual(lines.lines.first?.number, 1 + plain(long, before: lines.lines.first?.location ?? 0), "The ruler numbers from the same count")
    }

    @MainActor
    func testTheCursorReportsItsLineAndColumnAndTheRulerFitsTheLineCount() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let box = Box()
        let (textView, coordinator, editor) = makeEditor(box, window: window)
        var cursor: (Int, Int)?
        var reporting = editor("one\ntwo\nthree")
        reporting.onCursor = { cursor = ($0, $1) }
        coordinator.parent = reporting
        coordinator.apply(reporting, force: true)
        textView.setSelectedRange(NSRange(location: ("one\ntwo\nth" as NSString).length, length: 0))
        XCTAssertEqual(cursor?.0, 3)
        XCTAssertEqual(cursor?.1, 3)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(cursor?.0, 1)
        XCTAssertEqual(cursor?.1, 1)

        let ruler = ScratchpadLineRuler(textView: textView)
        ruler.fitLineNumbers(in: "x" as NSString)
        let narrow = ruler.ruleThickness
        ruler.fitLineNumbers(in: String(repeating: "\n", count: 99_999) as NSString)
        XCTAssertGreaterThan(ruler.ruleThickness, narrow, "Six-digit line numbers widen the ruler")
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testTheCursorPositionIsShownOnItsButtonWithoutSwiftUIOrALayoutChange() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let readout = EditorCursorReadout()
        let button = EditorCursorButton.Button(title: "", target: nil, action: nil)
        readout.button = button
        XCTAssertEqual(button.title, "Ln 1, Col 1")
        XCTAssertEqual(button.intrinsicContentSize.width, NSView.noIntrinsicMetric, "A new title never changes the header's layout")
        let widest = ("Ln 99999, Col 9999" as NSString).size(withAttributes: [.font: EditorCursorButton.font]).width
        XCTAssertGreaterThanOrEqual(EditorCursorButton.width, widest, "The fixed width fits a five-digit line and four-digit column")

        let box = Box()
        let (textView, coordinator, editor) = makeEditor(box, window: window)
        var reporting = editor("one\ntwo\nthree")
        reporting.onCursor = { [readout] in readout.update(line: $0, column: $1) }
        coordinator.parent = reporting
        coordinator.apply(reporting, force: true)
        textView.setSelectedRange(NSRange(location: ("one\ntwo\nth" as NSString).length, length: 0))
        XCTAssertEqual(button.title, "Ln 3, Col 3", "A cursor move reaches the button directly")
        XCTAssertEqual(readout.line, 3)
        XCTAssertEqual(readout.column, 3)
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testALongTextIsLaidOutOnlyAsFarAsNeededAndJumpsStillWork() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let storage = NSTextStorage(), layout = ScratchpadEditor.makeLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let textView = ScratchpadTextView(frame: scroll.bounds, textContainer: container)
        // As `makeNSView` sets it up: the text view grows with its text.
        textView.minSize = NSSize(width: 0, height: 300)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        let text = (1...20_000).map { "let line\($0) = \($0)" }.joined(separator: "\n")
        textView.string = text
        scroll.documentView = textView
        window.contentView?.addSubview(scroll)
        XCTAssertTrue(layout.allowsNonContiguousLayout)
        XCTAssertLessThan(layout.firstUnlaidCharacterIndex(), (text as NSString).length, "Showing a long text doesn't lay all of it out")

        ScratchpadEditor.Coordinator.move(textView, toLine: 15_000, column: 5)
        let expected = (text as NSString).range(of: "let line15000 =").location + 4
        XCTAssertEqual(textView.selectedRange(), NSRange(location: expected, length: 0), "A jump far down still lands on its line")
        let glyph = layout.glyphIndexForCharacter(at: expected)
        var target = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        target.origin.y += textView.textContainerOrigin.y
        XCTAssertTrue(textView.visibleRect.intersects(target), "and scrolls it into view: \(target) in \(textView.visibleRect)")
        let ruler = ScratchpadLineRuler(textView: textView)
        XCTAssertTrue(ruler.visibleLines?.lines.contains { $0.number == 15_000 } == true, "and the ruler numbers it")
    }

    @MainActor
    func testANewCursorPositionDoesNotAskTheWindowToLayOutAgain() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let readout = EditorCursorReadout()
        let button = EditorCursorButton.Button(title: "", target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(button)
        readout.button = button
        window.contentView?.layoutSubtreeIfNeeded()
        window.updateConstraintsIfNeeded()
        XCTAssertFalse(button.needsUpdateConstraints)

        readout.update(line: 1_234, column: 56)
        XCTAssertEqual(button.title, "Ln 1234, Col 56")
        XCTAssertFalse(button.needsUpdateConstraints, "Its size is fixed, so a new title doesn't invalidate it (SwiftUI would lay the window out again)")
        XCTAssertFalse(window.contentView?.needsUpdateConstraints ?? true)
    }

    @MainActor
    func testTheCursorButtonKeepsTheHeaderItsOwnHeight() throws {
        // The header sits above the flexible editor; a button with no height of its own let it take half the window.
        _ = NSApplication.shared
        let readout = EditorCursorReadout()
        let root = VStack(spacing: 0) {
            HStack {
                Text("README.md")
                EditorCursorButton(readout: readout, color: .secondaryLabelColor) {}.frame(width: EditorCursorButton.width, alignment: .trailing)
            }
            Color.clear
        }
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(readout.button)
        XCTAssertLessThanOrEqual(button.frame.height, 30, "The button is one line tall, not a share of the window")
        XCTAssertGreaterThanOrEqual(button.frame.height, EditorCursorButton.font.pointSize)
        XCTAssertEqual(button.frame.width, EditorCursorButton.width, accuracy: 1)
        readout.update(line: 2_000, column: 40)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(button.frame.height, 30, "and stays so as the cursor moves")
    }

    func testTheTextStorageIsReadAsANativeStringInOnePass() {
        for sample in ["", "plain ascii\nlines\n", "café — naïve ✓", "emoji 👩‍💻 and 𝒳 beyond the BMP", String(repeating: "línea ñ 🙂\n", count: 5_000)] {
            // As the text view holds it: a mutable UTF-16 string, not a Swift one.
            let stored = NSMutableString(string: sample)
            let native = ScratchpadEditor.nativeText(of: stored)
            XCTAssertEqual(native, sample)
            XCTAssertEqual(Array(native.utf8), Array(sample.utf8), "The same bytes, not just an equal string")
            XCTAssertTrue(native.isContiguousUTF8, "Comparing it with the model's text is a byte comparison")
        }
        // An unpaired surrogate has no UTF-8 form: it comes out as Swift repairs it, and the rest of the text is kept.
        let broken = NSMutableString(string: "ab")
        broken.append(String(utf16CodeUnits: [0xD83D], count: 1))
        broken.append("cd\n")
        let repaired = ScratchpadEditor.nativeText(of: broken)
        XCTAssertEqual(repaired, "ab\u{FFFD}cd\n")
        XCTAssertTrue(repaired.isContiguousUTF8)
        // Wherever the broken unit is, high or low, the result is what Swift's own reading of the string gives.
        for units: [unichar] in [[0xDE00, 0x61], [0x61, 0xD83D], [0x61, 0xDE00, 0x62], [0xD83D, 0xD83D, 0xDE00]] {
            let odd = NSMutableString(string: String(utf16CodeUnits: units, count: units.count))
            var expected = odd as String
            expected.makeContiguousUTF8()
            XCTAssertEqual(Array(ScratchpadEditor.nativeText(of: odd).utf8), Array(expected.utf8), "\(units)")
        }
        XCTAssertEqual(Array(ScratchpadEditor.nativeText(of: NSMutableString(string: "a\0b\r\nc")).utf8), Array("a\0b\r\nc".utf8), "NUL and CRLF are kept as they are")
    }

    func testTheSizeLimitUsesTheKnownSizeOnlyWhileItMatchesTheTextView() {
        let storage = NSMutableString(string: "ñandú!")  // 6 UTF-16 units, 8 bytes
        let end = NSRange(location: 6, length: 0)
        XCTAssertTrue(ScratchpadEditor.allowsChange(of: storage, synced: "ñandú!", in: end, to: "ab", limit: 10))
        XCTAssertFalse(ScratchpadEditor.allowsChange(of: storage, synced: "ñandú!", in: end, to: "abc", limit: 10), "Growing past the limit is refused")
        XCTAssertTrue(ScratchpadEditor.allowsChange(of: storage, synced: "ñandú!", in: NSRange(location: 0, length: 1), to: "n", limit: 4), "A change that doesn't grow the text is always allowed")
        XCTAssertTrue(ScratchpadEditor.allowsChange(of: storage, synced: "ñandú!", in: NSRange(location: 0, length: 1), to: "ññ", limit: 10), "The replaced range's bytes are counted from the text view")

        // A copy that fell behind the text view isn't trusted: the text view's own size decides, and a range past the
        // copy's end is read from the text view.
        XCTAssertFalse(ScratchpadEditor.allowsChange(of: storage, synced: "ñ", in: end, to: "abc", limit: 10))
        XCTAssertTrue(ScratchpadEditor.allowsChange(of: storage, synced: "ñandú! and much more that was deleted", in: end, to: "ab", limit: 10))
        XCTAssertFalse(ScratchpadEditor.allowsChange(of: storage, synced: nil, in: end, to: "abc", limit: 10))
    }

    @MainActor
    func testTypingInALongNonASCIITextReachesTheModelIntact() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let box = Box()
        let (textView, coordinator, editor) = makeEditor(box, window: window)
        let start = String(repeating: "let señal = \"🙂\" // ñ\n", count: 20_000)
        // An editor tab's limit, not the scratchpad's 64 KB.
        var large = editor(start)
        large.maximumBytes = EditorDocument.maximumBytes
        coordinator.parent = large
        coordinator.apply(large, force: true)
        window.makeFirstResponder(textView)
        let middle = (start as NSString).length / 2
        textView.insertText("é👍", replacementRange: NSRange(location: middle, length: 0))

        let expected = (start as NSString).replacingCharacters(in: NSRange(location: middle, length: 0), with: "é👍")
        XCTAssertEqual(box.text, expected, "The model gets the typed text")
        XCTAssertEqual(Array(box.text.utf8), Array(expected.utf8))
        XCTAssertEqual(coordinator.synced, expected)
        XCTAssertTrue(box.text.isContiguousUTF8)
    }
}
