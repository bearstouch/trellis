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
}
