import AppKit
import SwiftUI
import XCTest
import TrellisCore
@testable import TrellisUI

/// The text view bridge under typing and model updates (editor typing performance review).
final class ScratchpadEditorReviewTests: XCTestCase {
    @MainActor private final class Box { var text = "" }

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
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(box.text, "echo x # tail\nls\n# first\n" + long)
        XCTAssertNotEqual(color(textView, at: 0), comment, "`echo` isn't a comment: no stale tokens from before the keys")
        XCTAssertEqual(color(textView, at: ("echo x # tail\nls\n" as NSString).length), comment, "the newest text's comment is colored")
        XCTAssertEqual(color(textView, at: ("echo x " as NSString).length), comment)
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
}
