import XCTest
@testable import UTermCore

final class TerminalPasteTests: XCTestCase {
    func testS012_UT01_pasteReviewClassifiesControls() {
        let plain = TerminalPastePlan(input: .text("café 👩‍💻"), shell: "/bin/zsh")
        XCTAssertFalse(plain.requiresReview)
        XCTAssertEqual(plain.lineCount, 1)
        for text in ["a\nb", "a\rb", "a\r\nb", "a\tb", "a\u{1b}b", "a\u{0}b", "a\u{7f}b", "a\u{202E}b"] {
            let plan = TerminalPastePlan(input: .text(text), shell: nil)
            XCTAssertTrue(plan.requiresReview, text.debugDescription)
            XCTAssertTrue(plan.preview.contains("⟨"))
            XCTAssertEqual(plan.text, text)
        }
        XCTAssertEqual(TerminalPastePlan(input: .text("a\r\nb\nc\rd"), shell: nil).lineCount, 4)
        XCTAssertEqual(TerminalPastePlan(input: .text("a\u{85}b"), shell: nil).lineCount, 2)
        let plan = TerminalPastePlan(input: .text("a\t\u{1b}\r\n"), shell: nil)
        XCTAssertEqual(plan.preview, "a⟨TAB⟩⟨ESC⟩⟨CR⟩\n⟨LF⟩\n")
        XCTAssertEqual(plan.lineCount, 2)
    }

    @MainActor
    func testS012_UT02_cancelOrStaleTargetWritesNothing() throws {
        let review = TerminalPasteReview()
        let a = TerminalPasteTarget(paneID: UUID(), sessionID: UUID())
        let b = TerminalPasteTarget(paneID: UUID(), sessionID: UUID())
        let plan = TerminalPastePlan(input: .text("first\nsecond"), shell: "/bin/zsh")
        var writes: [String] = []
        review.request(plan, target: a, name: "A") { writes.append($0.text) }
        let canceled = try XCTUnwrap(review.pending).id
        review.cancel()
        XCTAssertFalse(review.confirm(id: canceled, currentTarget: a) { writes.append($0.text) })
        review.request(plan, target: a, name: "A") { writes.append($0.text) }
        let stale = try XCTUnwrap(review.pending).id
        XCTAssertFalse(review.confirm(id: stale, currentTarget: b) { writes.append($0.text) })
        XCTAssertFalse(review.confirm(id: stale, currentTarget: a) { writes.append($0.text) })
        review.request(plan, target: a, name: "A") { writes.append($0.text) }
        let closed = try XCTUnwrap(review.pending).id
        XCTAssertFalse(review.confirm(id: closed, currentTarget: nil) { writes.append($0.text) })
        review.request(plan, target: a, name: "A") { writes.append($0.text) }
        let replaced = try XCTUnwrap(review.pending).id
        let fresh = TerminalPasteTarget(paneID: a.paneID, sessionID: UUID())
        XCTAssertFalse(review.confirm(id: replaced, currentTarget: fresh) { writes.append($0.text) })
        XCTAssertEqual(writes, [])
        review.request(plan, target: a, name: "A") { writes.append($0.text) }
        let approved = try XCTUnwrap(review.pending).id
        XCTAssertTrue(review.confirm(id: approved, currentTarget: a) { writes.append($0.text) })
        XCTAssertFalse(review.confirm(id: approved, currentTarget: a) { writes.append($0.text) })
        XCTAssertEqual(writes, [plan.text])
    }

    func testS012_UT03_bracketedPastePreservesPayload() {
        let text = "a\r\n\tcafé 👋\u{1b}\u{0}"
        let plan = TerminalPastePlan(input: .text(text), shell: nil)
        XCTAssertEqual(plan.data(bracketed: false), Data(text.utf8))
        XCTAssertEqual(plan.data(bracketed: true), Data("\u{1b}[200~".utf8) + Data(text.utf8) + Data("\u{1b}[201~".utf8))
    }

    func testS012_UT04_escapePathByShell() {
        let path = "/tmp/a b's $HOME\nfile"
        for shell in ["/bin/zsh", "/bin/bash", "/bin/sh"] {
            let plan = TerminalPastePlan(input: .paths([path]), shell: shell)
            XCTAssertEqual(plan.text, "'/tmp/a b'\\''s $HOME\nfile'")
            XCTAssertFalse(plan.unsupportedShell)
            XCTAssertTrue(plan.requiresReview) // Newline remains a visible reviewed control.
        }
        let ordinary = TerminalPastePlan(input: .text(path), shell: "/bin/zsh")
        XCTAssertEqual(ordinary.text, path)
        let unsupported = TerminalPastePlan(input: .paths(["/tmp/a b"]), shell: "/usr/bin/fish")
        XCTAssertTrue(unsupported.unsupportedShell)
        XCTAssertTrue(unsupported.requiresReview)
        XCTAssertEqual(unsupported.preview, "'/tmp/a b'")
        let multiple = TerminalPastePlan(input: .paths(["/tmp/a b", "/tmp/$value"]), shell: "/bin/bash")
        XCTAssertEqual(multiple.text, "'/tmp/a b' '/tmp/$value'")
        XCTAssertFalse(multiple.requiresReview)
    }

    func testEscapedPathRoundTripsThroughSupportedShells() throws {
        let path = "/tmp/a b's $HOME\nfile"
        for shell in ["/bin/zsh", "/bin/bash", "/bin/sh"] {
            let plan = TerminalPastePlan(input: .paths([path]), shell: shell)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            let prefix = shell.hasSuffix("zsh") ? ["-f"] : shell.hasSuffix("bash") ? ["--noprofile", "--norc"] : []
            process.arguments = prefix + ["-c", "printf '%s' " + plan.text]
            process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(bytes, Data(path.utf8))
        }
    }

    func testLargePreviewIsBoundedWithoutChangingPayload() {
        let text = String(repeating: "x", count: 12_000) + "\u{1b}"
        let plan = TerminalPastePlan(input: .text(text), shell: nil)
        XCTAssertTrue(plan.requiresReview)
        XCTAssertTrue(plan.preview.contains("Preview truncated"))
        XCTAssertLessThan(plan.preview.count, 8300)
        XCTAssertEqual(plan.text, text)
    }
}
