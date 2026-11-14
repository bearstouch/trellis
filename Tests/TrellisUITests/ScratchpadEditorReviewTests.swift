import AppKit
import SwiftUI
import XCTest
import TrellisCore
@testable import TrellisUI

/// The text view bridge under typing and model updates (editor typing performance review).
final class ScratchpadEditorReviewTests: XCTestCase {
    @MainActor private final class Box { var text = "" }

    @MainActor
    private func makeEditor(_ box: Box, window: NSWindow) -> (ScratchpadTextView, ScratchpadEditor.Coordinator, (String) -> ScratchpadEditor) {
        let textView = ScratchpadTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.allowsUndo = true
        window.contentView?.addSubview(textView)
        let editor = { (text: String) in
            box.text = text
            return ScratchpadEditor(
                text: Binding(get: { box.text }, set: { box.text = $0 }), language: .markdown, font: .systemFont(ofSize: 12), palette: .builtIn,
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
}
