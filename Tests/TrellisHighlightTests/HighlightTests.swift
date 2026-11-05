import AppKit
import XCTest
@testable import TrellisCore
@testable import TrellisHighlight

@MainActor
final class HighlightTests: XCTestCase {
    func testLineTableStaysEqualToAFullRescanAcrossEdits() {
        var generator = SystemRandomNumberGenerator()
        let text = NSMutableString(string: "let a = 1\nlet b = 2\n\nfunc f() {\n  return\n}\n")
        var table = LineTable(text)
        let pieces = ["", "x", "\n", "ab\ncd", "\n\n", "é\n", "🙂"]
        for _ in 0..<500 {
            let location = Int.random(in: 0...text.length, using: &generator)
            let length = Int.random(in: 0...min(6, text.length - location), using: &generator)
            let replacement = pieces.randomElement(using: &generator)!
            text.replaceCharacters(in: NSRange(location: location, length: length), with: replacement)
            let inserted = (replacement as NSString).length
            table.apply(editedRange: NSRange(location: location, length: inserted), delta: inserted - length, in: text)
            XCTAssertEqual(table, LineTable(text), "after replacing \(length) at \(location) with \(replacement.debugDescription)")
        }
        let lines = LineTable("ab\ncd\n" as NSString)
        XCTAssertEqual(lines.location(of: 0).row, 0)
        XCTAssertEqual(lines.location(of: 4).row, 1)
        XCTAssertEqual(lines.location(of: 4).column, 1)
        XCTAssertEqual(lines.location(of: 6).row, 2)
    }

    func testEveryGrammarLoadsItsHighlightQueries() {
        for grammar in Grammar.allCases {
            XCTAssertNotNil(Grammar.queriesURL(bundleName: grammar.bundleName), "\(grammar) queries bundle")
            XCTAssertNotNil(grammar.configuration, "\(grammar) configuration")
        }
        XCTAssertEqual(Grammar.forFile("App.tsx"), .tsx)
        XCTAssertEqual(Grammar.forFile("app.ts"), .typescript)
        XCTAssertEqual(Grammar.forFile("deploy.sh"), .bash)
        XCTAssertNil(Grammar.forFile("Makefile"))
        XCTAssertEqual(Grammar.injected("markdown_inline"), .markdownInline)
    }

    func testCapturesMapToTheScratchpadsANSIColors() {
        XCTAssertEqual(CaptureColors.ansiIndex(for: "keyword"), 5)
        XCTAssertEqual(CaptureColors.ansiIndex(for: "keyword.function"), 5)
        XCTAssertEqual(CaptureColors.ansiIndex(for: "string"), 2)
        XCTAssertEqual(CaptureColors.ansiIndex(for: "comment"), 8)
        XCTAssertEqual(CaptureColors.ansiIndex(for: "function.call"), 4)
        XCTAssertEqual(CaptureColors.ansiIndex(for: "number"), 9)
        XCTAssertNil(CaptureColors.ansiIndex(for: "operator"), "Operators keep the text color")
        XCTAssertNil(CaptureColors.ansiIndex(for: "nonsense"))
    }

    private func makeTextView(_ text: String) -> (NSTextView, NSWindow) {
        let storage = NSTextStorage(string: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = textView
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        return (textView, window)
    }
    private func color(_ textView: NSTextView, at offset: Int) -> NSColor? {
        textView.layoutManager?.temporaryAttributes(atCharacterIndex: offset, effectiveRange: nil)[.foregroundColor] as? NSColor
    }
    private func waitForColor(_ textView: NSTextView, at offset: Int, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while color(textView, at: offset) == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertNotNil(color(textView, at: offset), "no color at \(offset)", file: file, line: line)
    }

    func testHighlightsSwiftWithTheThemesColorsWithoutTouchingTheTextOrUndo() throws {
        let (textView, window) = makeTextView("let greeting = \"hi\" // hello\n")
        let palette = TerminalPalette.builtIn
        let highlighter = try XCTUnwrap(CodeHighlighter.make(for: textView, fileName: "Hello.swift", palette: palette))
        waitForColor(textView, at: 0)
        let keyword = palette.ansi[5]
        let expected = NSColor(srgbRed: CGFloat((keyword >> 16) & 255) / 255, green: CGFloat((keyword >> 8) & 255) / 255, blue: CGFloat(keyword & 255) / 255, alpha: 1)
        XCTAssertEqual(color(textView, at: 0), expected, "`let` takes ANSI 5")
        XCTAssertNil(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil), "Colors are temporary attributes, not text")
        XCTAssertFalse(textView.undoManager?.canUndo ?? false, "Highlighting registers no undo")

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("var x = 1\n", replacementRange: NSRange(location: 0, length: 0))
        waitForColor(textView, at: 0)
        XCTAssertEqual(textView.string, "var x = 1\nlet greeting = \"hi\" // hello\n")
        highlighter.setPalette(TerminalPalette.builtInLight)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNotEqual(color(textView, at: 0), expected, "A new theme restyles")
        highlighter.detach()
        XCTAssertNil(color(textView, at: 0))
        _ = window
    }

    func testInjectedLanguagesAndBackgroundParsesDontLeaveTheMainActorUnsafe() throws {
        // Markdown's inline grammar and HTML's scripts are injections, which tree-sitter resolves while parsing in the
        // background; a large file is parsed in the background too. Any main-actor closure called there would trap.
        let (markdown, w1) = makeTextView("# Title\n\nSome **bold** and `code`.\n")
        let md = try XCTUnwrap(CodeHighlighter.make(for: markdown, fileName: "README.md", palette: .builtIn))
        waitForColor(markdown, at: 2)
        let (html, w2) = makeTextView("<html><script>let x = 1;</script></html>\n")
        let page = try XCTUnwrap(CodeHighlighter.make(for: html, fileName: "index.html", palette: .builtIn))
        waitForColor(html, at: 1)
        let big = String(repeating: "func f() { let s = \"text\"; return }\n", count: 20_000)
        let (large, w3) = makeTextView(big)
        let swift = try XCTUnwrap(CodeHighlighter.make(for: large, fileName: "Big.swift", palette: .builtIn))
        waitForColor(large, at: 0)
        large.insertText("let a = 1\n", replacementRange: NSRange(location: 0, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        waitForColor(large, at: 0)
        _ = (md, page, swift, w1, w2, w3)
    }

    func testPlainTextFilesGetNoHighlighter() {
        let (textView, _) = makeTextView("hello")
        XCTAssertNil(CodeHighlighter.make(for: textView, fileName: "notes.txt", palette: .builtIn))
    }
}
