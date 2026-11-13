import Foundation
import XCTest

@testable import TrellisCore

/// The Markdown preview's reader and link rules (FR-ED12).
final class MarkdownDocumentTests: XCTestCase {
    func testHeadingsParagraphsBreaksAndRules() {
        let source = [
            "# Title #", "Some *text*", "on two lines\\", "with a hard break  ", "and the end.", "", "Setext", "======", "", "Sub", "---", "", "***", "#nope"
        ].joined(separator: "\n")
        let blocks = MarkdownDocument.parse(source)
        XCTAssertEqual(
            blocks,
            [
                .heading(level: 1, text: "Title"),
                .paragraph("Some *text* on two lines\nwith a hard break\nand the end."),
                .heading(level: 1, text: "Setext"),
                .heading(level: 2, text: "Sub"),
                .rule,
                .paragraph("#nope")
            ])
    }

    func testListsTasksAndNesting() {
        let blocks = MarkdownDocument.parse(
            """
            - one
            - [x] done
            - [ ] todo
              - nested
                continued
            lazy line

            3. three
            4. four
            """)
        XCTAssertEqual(blocks.count, 2)
        guard case .list(let ordered, _, let items) = blocks[0] else { return XCTFail("\(blocks)") }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items.map(\.task), [nil, true, false])
        XCTAssertEqual(items[0].blocks, [.paragraph("one")])
        XCTAssertEqual(items[1].blocks, [.paragraph("done")])
        XCTAssertEqual(
            items[2].blocks,
            [.paragraph("todo"), .list(ordered: false, start: 1, items: [MarkdownListItem(blocks: [.paragraph("nested continued lazy line")])])])
        XCTAssertEqual(
            blocks[1], .list(ordered: true, start: 3, items: [MarkdownListItem(blocks: [.paragraph("three")]), MarkdownListItem(blocks: [.paragraph("four")])]))
    }

    func testQuotesCodeTablesAndHTML() {
        let blocks = MarkdownDocument.parse(
            """
            > quoted **text**
            lazily
            > > deeper

            ```swift
            let x = 1

            print(x)
            ```

                indented code

            | Name | Size |  Note  |
            |:-----|-----:|:------:|
            | a \\| b | 1 | `x|y` |
            | short |

            <div class="x">
            <script>alert(1)</script>
            </div>
            """)
        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks[0], .quote([.paragraph("quoted **text** lazily"), .quote([.paragraph("deeper")])]))
        XCTAssertEqual(blocks[1], .code(language: "swift", text: "let x = 1\n\nprint(x)"))
        XCTAssertEqual(blocks[2], .code(language: nil, text: "indented code"))
        XCTAssertEqual(
            blocks[3], .table(header: ["Name", "Size", "Note"], alignments: [.leading, .trailing, .center], rows: [["a | b", "1", "`x|y`"], ["short", "", ""]]))
        XCTAssertEqual(blocks[4], .html("<div class=\"x\">\n<script>alert(1)</script>\n</div>"), "HTML is kept as text, never interpreted")
    }

    func testEdgeCases() {
        XCTAssertEqual(MarkdownDocument.parse("```\nnever closed\n# not a heading"), [.code(language: nil, text: "never closed\n# not a heading")])
        XCTAssertEqual(MarkdownDocument.parse("a | b\nnot a separator"), [.paragraph("a | b not a separator")], "No separator, no table")
        XCTAssertEqual(MarkdownDocument.parse("\r\n# Windows\r\ntext\r\n"), [.heading(level: 1, text: "Windows"), .paragraph("text")])
        XCTAssertEqual(MarkdownDocument.parse("text\n2. not a list"), [.paragraph("text 2. not a list")], "Only 1. interrupts a paragraph")
        XCTAssertEqual(MarkdownDocument.parse(""), [])
    }

    func testHostileInputIsBoundedAndQuick() {
        let started = Date()
        let deep = MarkdownDocument.parse(String(repeating: ">", count: 10_000) + " x")
        var depth = 0, block = deep.first
        while case .quote(let inner)? = block { depth += 1; block = inner.first }
        XCTAssertLessThanOrEqual(depth, MarkdownDocument.maximumDepth, "Nesting stops at the cap")
        _ = MarkdownDocument.parse(String(repeating: "```\n", count: 10_000))
        _ = MarkdownDocument.parse(String(repeating: "- ", count: 10_000))
        _ = MarkdownDocument.parse(String(repeating: "- a\n  ", count: 10_000))
        _ = MarkdownDocument.parse(String(repeating: "| a |\n", count: 10_000))
        _ = MarkdownDocument.parse(String(repeating: "> - > - ", count: 5_000))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testLongBlankRunsAndTabRunsStayLinear() {
        let started = Date()
        // Each blank line inside a list item used to look ahead over every following blank one.
        XCTAssertEqual(
            MarkdownDocument.parse("- a\n" + String(repeating: "\n", count: 60_000) + "  b"),
            [.list(ordered: false, start: 1, items: [MarkdownListItem(blocks: [.paragraph("a"), .paragraph("b")])])])
        // Leading tabs used to be counted by walking the string from its start for each one.
        XCTAssertEqual(MarkdownDocument.parse(String(repeating: "\t", count: 60_000) + "x"), [.code(language: nil, text: String(repeating: " ", count: 239_996) + "x")])
        XCTAssertEqual(MarkdownDocument.parse("\tcode"), [.code(language: nil, text: "code")])
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testRandomInputNeverTraps() {
        // A fixed-seed generator, so a failure repeats.
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return Int((seed >> 33) % UInt64(bound)) }
        let pieces = [
            "#", " ", "  ", "\t", "\n", "\r\n", "\r", "-", "*", "+", "_", "=", ">", "`", "```", "~~~", "|", ":", "\\", "[x]", "[ ]", "1.", "9)",
            "1234567890.", "<", "<a>", "a", "é", "👩‍👩‍👧", "\u{301}", "[l](x)", "![i](y)", "    "
        ]
        for _ in 0..<3_000 {
            let text = (0..<next(60)).map { _ in pieces[next(pieces.count)] }.joined()
            for block in MarkdownDocument.parse(text) {
                if case .table(let header, let alignments, let rows) = block {
                    XCTAssertEqual(header.count, alignments.count, text)
                    XCTAssertTrue(rows.allSatisfy { $0.count == header.count }, text)
                }
            }
        }
    }

    func testBlankLinesBetweenItemsKeepOneList() {
        guard case .list(_, _, let items)? = MarkdownDocument.parse("- a\n\n\n- b").first else { return XCTFail() }
        XCTAssertEqual(items.count, 2)
    }

    func testSlugs() {
        XCTAssertEqual(MarkdownDocument.slug("Editing and saving"), "editing-and-saving")
        XCTAssertEqual(MarkdownDocument.slug("FR-ED12: Preview!"), "fr-ed12-preview")
    }

    func testLinksOnlyLeaveForTheWebAndOnlyOpenProjectFiles() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-md-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let project = scratch.appendingPathComponent("project").path
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(atPath: project + "/docs", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: scratch.appendingPathComponent("outside").path, withIntermediateDirectories: true)
        for file in ["/docs/a.md", "/docs/b c.md", "/README.md"] { try "x".write(toFile: project + file, atomically: true, encoding: .utf8) }
        try "x".write(toFile: scratch.appendingPathComponent("outside/secret.md").path, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: project + "/docs/out", withDestinationPath: scratch.appendingPathComponent("outside").path)
        let document = project + "/docs/index.md"
        let regular: (String) -> Bool = {
            var dir: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &dir) && !dir.boolValue
        }
        func action(_ link: String) -> MarkdownLink.Action { MarkdownLink.action(link, documentPath: document, projectRoot: project, isRegularFile: regular) }

        XCTAssertEqual(action("https://example.com/x"), .web(URL(string: "https://example.com/x")!))
        XCTAssertEqual(action("mailto:me@example.com"), .web(URL(string: "mailto:me@example.com")!))
        XCTAssertEqual(action("javascript:alert(1)"), MarkdownLink.Action.none)
        XCTAssertEqual(action("file:///etc/passwd"), MarkdownLink.Action.none)
        XCTAssertEqual(action("x-man-page://ls"), MarkdownLink.Action.none)
        XCTAssertEqual(action("http:///nohost"), MarkdownLink.Action.none)
        XCTAssertEqual(action("a.md#section"), .file(project + "/docs/a.md"))
        XCTAssertEqual(action("b%20c.md"), .file(project + "/docs/b c.md"))
        XCTAssertEqual(action("../README.md"), .file(project + "/README.md"))
        XCTAssertEqual(action("/README.md"), .file(project + "/README.md"), "A leading / names the project root")
        XCTAssertEqual(action("../../outside/secret.md"), MarkdownLink.Action.none, "Outside the project")
        XCTAssertEqual(action("out/secret.md"), MarkdownLink.Action.none, "A link out of the project is judged by its target")
        XCTAssertEqual(action("missing.md"), MarkdownLink.Action.none)
        XCTAssertEqual(action("."), MarkdownLink.Action.none, "A folder doesn't open")
        XCTAssertEqual(action("#editing-and-saving"), .anchor("editing-and-saving"))
        for link in ["https://example.com", "MAILTO:me@example.com", "a.md", "#top", "//host/x"] { XCTAssertTrue(MarkdownLink.isClickable(URL(string: link)!), link) }
        for link in ["javascript:alert(1)", "file:///etc/passwd", "x-man-page://ls", "ssh://host", "vscode://file/x"] {
            XCTAssertFalse(MarkdownLink.isClickable(URL(string: link)!), link)
        }
    }
}
