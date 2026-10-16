import AppKit
import XCTest
import SwiftTerm
import TrellisCore
@testable import TrellisTerminal

final class KeyboardInputTests: XCTestCase {
    private let noReplacement = NSRange(location: NSNotFound, length: 0)

    @MainActor
    func testS017_UT03_inputRoutingRespectsComposition() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let observer = CompositionObserver()
        view.terminalDelegate = observer

        // IME: romaji → kana → kanji candidates are marked text only.
        view.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: noReplacement)
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: noReplacement)
        view.setMarkedText(NSAttributedString(string: "漢字"), selectedRange: NSRange(location: 2, length: 0), replacementRange: noReplacement)
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(observer.sent, Data())
        view.insertText("漢字", replacementRange: noReplacement)
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(String(decoding: observer.sent, as: UTF8.self), "漢字")

        // Dead key (´ then e on US/Portuguese layouts) commits one composed character.
        observer.sent = Data()
        view.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: noReplacement)
        XCTAssertEqual(observer.sent, Data())
        view.insertText("é", replacementRange: noReplacement)
        XCTAssertEqual(String(decoding: observer.sent, as: UTF8.self), "é")

        // An abandoned composition sends nothing.
        observer.sent = Data()
        view.setMarkedText("ü", selectedRange: NSRange(location: 1, length: 0), replacementRange: noReplacement)
        view.unmarkText()
        XCTAssertEqual(observer.sent, Data())

        // Emoji and combining marks pass through unchanged.
        view.insertText("👋e\u{301}", replacementRange: noReplacement)
        XCTAssertEqual(String(decoding: observer.sent, as: UTF8.self), "👋e\u{301}")
    }

    @MainActor
    func testSuspendedInputNeverReachesTheSession() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        var errors = 0
        // The session is stopped, so any byte reaching it reports an input error.
        native.onInputError = { _ in errors += 1 }
        native.inputSuspended = true
        view.insertText("ls\r", replacementRange: noReplacement)
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(errors, 0)
        native.inputSuspended = false
        view.insertText("x", replacementRange: noReplacement)
        XCTAssertEqual(errors, 1)
    }

    @MainActor
    func testOptionAsMetaIsOptInAndNotToggledByTheEngine() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        XCTAssertFalse(native.optionAsMeta)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        window.makeFirstResponder(view)
        let toggle = try XCTUnwrap(keyEvent("o", flags: [.command, .option], keyCode: 31, window: window))
        XCTAssertTrue(view.performKeyEquivalent(with: toggle))
        XCTAssertFalse(native.optionAsMeta)
        // SwiftTerm also toggles on ⌘⌥⌃O; that variant must not reach its keyDown either.
        let controlToggle = try XCTUnwrap(keyEvent("o", flags: [.command, .option, .control], keyCode: 31, window: window))
        XCTAssertTrue(view.performKeyEquivalent(with: controlToggle))
        XCTAssertFalse(native.optionAsMeta)
        native.optionAsMeta = true
        XCTAssertTrue(view.optionAsMetaKey)

        var searches = 0
        view.onSearchRequested = { searches += 1 }
        native.searchShortcut = KeyChord("e", [.command, .shift])
        let oldFind = try XCTUnwrap(keyEvent("f", flags: [.command], keyCode: 3, window: window))
        XCTAssertFalse(view.performKeyEquivalent(with: oldFind))
        let newFind = try XCTUnwrap(keyEvent("e", flags: [.command, .shift], keyCode: 14, window: window))
        XCTAssertTrue(view.performKeyEquivalent(with: newFind))
        XCTAssertEqual(searches, 1)
    }

    @MainActor
    func testRecordedChordsUseLayoutBaseKeysAndMenuEquivalents() throws {
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let arrow = try XCTUnwrap(keyEvent(String(UnicodeScalar(NSLeftArrowFunctionKey)!), flags: [.command, .option], keyCode: 123, window: window))
        XCTAssertEqual(KeyChord(event: arrow), KeyChord("left", [.command, .option]))
        XCTAssertEqual(KeyChord("left", [.command, .option]).keyEquivalent, String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        XCTAssertEqual(KeyChord("return", [.command, .shift]).modifierMask, [.command, .shift])
        let escape = try XCTUnwrap(keyEvent("\u{1b}", flags: [.command], keyCode: 53, window: window))
        XCTAssertNil(KeyChord(event: escape))
    }

    @MainActor
    private func keyEvent(_ characters: String, flags: NSEvent.ModifierFlags, keyCode: UInt16, window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
    }
}

@MainActor
private final class CompositionObserver: NSObject, @preconcurrency TerminalViewDelegate {
    var sent = Data()
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
}
