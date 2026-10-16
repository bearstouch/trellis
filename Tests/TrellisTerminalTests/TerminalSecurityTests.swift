import AppKit
import XCTest
import SwiftTerm
import TrellisCore
@testable import TrellisTerminal

final class TerminalSecurityTests: XCTestCase {
    @MainActor
    func testOsc52CannotReadOrWriteClipboard() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        var writes = 0, reads = 0, responses = 0
        view.writeClipboard = { _ in writes += 1 }
        view.readClipboardText = {
            reads += 1; return "clipboard secret"
        }
        native.onInputError = { _ in responses += 1 }  // any reply to the PTY would surface here
        let changeCount = NSPasteboard.general.changeCount
        let payload = Data("PWNED".utf8).base64EncodedString()
        for sequence in ["\u{1b}]52;c;\(payload)\u{07}", "\u{1b}]52;p;\(payload)\u{1b}\\", "\u{1b}]52;c;?\u{07}", "\u{1b}]52;;?\u{1b}\\"] {
            native.adapter.receive(Data(sequence.utf8))
        }
        XCTAssertEqual(NSPasteboard.general.changeCount, changeCount, "The system pasteboard was not written")
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(responses, 0, "No clipboard contents were sent back to the program")
        XCTAssertNil(native.clipboardRead(source: view))
        XCTAssertTrue(view.getTerminal().silentLog, "Engine logging that could echo output is off")
        native.adapter.receive(Data("\u{1b}[5n".utf8))
        XCTAssertEqual(responses, 1, "A status report does reach the reply path, so the zero above is meaningful")
    }

    func testKittyGraphicsCannotReadOrUnlinkLocalFiles() throws {
        final class Replies: TerminalDelegate {
            var text = ""
            func send(source: Terminal, data: ArraySlice<UInt8>) { text += String(decoding: data, as: UTF8.self) }
        }
        let replies = Replies()
        let terminal = Terminal(delegate: replies)
        // A valid 1x1 PNG at a path the upstream temporary-file rule would read and then unlink.
        let base64PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg=="
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tty-graphics-protocol-\(UUID().uuidString).png")
        try XCTUnwrap(Data(base64Encoded: base64PNG)).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let path = Data(file.path.utf8).base64EncodedString()
        for (id, medium) in ["f", "t", "s"].enumerated() { terminal.feed(text: "\u{1b}_Ga=t,f=100,i=\(id + 1),t=\(medium);\(path)\u{1b}\\") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Output cannot make the app delete a local file")
        XCTAssertFalse(replies.text.contains(";OK"), "Output cannot make the app read or probe a local file")
        terminal.feed(text: "\u{1b}_Ga=t,f=100,i=9;\(base64PNG)\u{1b}\\")
        XCTAssertTrue(replies.text.contains("i=9;OK"), "Direct transmission still works, so the refusals above are meaningful")
    }

    @MainActor
    func testValidateUrlAndGesture() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        var opened: [String] = []
        native.openURL = {
            opened.append($0.absoluteString); return true
        }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        native.now = { clock }

        // Output alone can never open anything.
        native.requestOpenLink(source: view, link: "https://example.com/a", params: [:])
        XCTAssertEqual(opened, [])

        for link in ["https://example.com/a", "http://example.com", "mailto:someone@example.com"] {
            view.lastUserGesture = clock
            native.requestOpenLink(source: view, link: link, params: [:])
        }
        XCTAssertEqual(opened, ["https://example.com/a", "http://example.com", "mailto:someone@example.com"])

        let forbidden = [
            "file:///etc/passwd", "javascript:alert(1)", "x-custom://do", "ssh://host", "vnc://host", "https://user:pass@example.com",
            "https://exa mple.com", "https://example.com/\u{1b}[31m", "https:///nohost", String(repeating: "a", count: 3000)
        ]
        for link in forbidden {
            view.lastUserGesture = clock
            native.requestOpenLink(source: view, link: link, params: [:])
        }
        XCTAssertEqual(opened.count, 3, "Unsafe or custom schemes never open, even after a click")

        // A stale or already-used gesture does not authorize a later request.
        view.lastUserGesture = clock
        clock = clock.addingTimeInterval(5)
        native.requestOpenLink(source: view, link: "https://example.com/late", params: [:])
        view.lastUserGesture = clock
        native.requestOpenLink(source: view, link: "https://example.com/once", params: [:])
        native.requestOpenLink(source: view, link: "https://example.com/twice", params: [:])
        XCTAssertEqual(opened.suffix(1), ["https://example.com/once"])

        // A click that opened nothing does not leave a gesture behind for later output.
        let click = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        view.mouseUp(with: click)
        XCTAssertNil(view.lastUserGesture)
    }
}
