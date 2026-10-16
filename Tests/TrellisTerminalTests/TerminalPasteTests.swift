import AppKit
import XCTest
import SwiftTerm
import TrellisCore
@testable import TrellisTerminal

final class NativeTerminalPasteTests: XCTestCase {
    @MainActor
    func testClipboardReadOccursOnlyOnFocusedExplicitAction() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        var reads = 0, pathReads = 0, received: [String] = []
        view.readClipboardText = { reads += 1; return "text\n" }
        view.readClipboardPaths = { pathReads += 1; return ["/tmp/a b"] }
        view.onPasteRequested = { input in
            switch input { case .text(let value): received.append(value); case .paths(let values): received += values }
        }
        _ = view.validateUserInterfaceItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: ""))
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(pathReads, 0)
        window.makeFirstResponder(nil)
        view.paste(self); view.pasteEscapedPath(self)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(pathReads, 0)
        window.makeFirstResponder(view)
        view.paste(self)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(received, ["text\n"])
        view.pasteEscapedPath(self)
        XCTAssertEqual(pathReads, 1)
        XCTAssertEqual(received, ["text\n", "/tmp/a b"])
    }

    @MainActor
    func testRealPTYPasteUsesNegotiatedFramingAndExactBytes() async throws {
        _ = NSApplication.shared
        for bracketed in [false, true] {
            let native = NativeTerminal()
            defer { native.requestTermination(force: true); native.adapter.detach() }
            let plan = TerminalPastePlan(input: .text("a\r\n\tcafé 👋\u{1b}\u{0}"), shell: nil)
            let expected = plan.data(bracketed: bracketed)
            let mode = bracketed ? "\\033[?2004h" : "\\033[?2004l"
            let script = "stty raw -echo; printf '\(mode)READY\\r\\n'; /bin/dd bs=1 count=\(expected.count) 2>/dev/null | /usr/bin/od -An -tx1; printf '\\r\\nDONE\\r\\n'"
            await native.start(configuration: LocalLaunchConfiguration(executable: "/bin/zsh", arguments: ["-f", "-c", script], directory: "/tmp"))
            let deadline = Date().addingTimeInterval(8)
            while !(try native.adapter.read(.retainedText)).contains("READY"), Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(try native.adapter.read(.retainedText).contains("READY"))
            try native.paste(plan)
            while !(try native.adapter.read(.retainedText)).contains("DONE"), Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let text = try native.adapter.read(.retainedText)
            XCTAssertTrue(text.contains("DONE"), text)
            let hex = text.components(separatedBy: .whitespacesAndNewlines).filter { $0.count == 2 && UInt8($0, radix: 16) != nil }
            XCTAssertEqual(hex, expected.map { String(format: "%02x", $0) }, text)
        }
    }
}
