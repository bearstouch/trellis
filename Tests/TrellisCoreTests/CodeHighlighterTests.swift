import Foundation
import XCTest

@testable import TrellisCore

/// Editor tabs' languages and highlighting (FR-ED03, FR-ED09).
final class CodeHighlighterTests: XCTestCase {
    private func kinds(_ text: String, _ grammar: ScratchpadLanguage.Grammar) -> [(String, ScratchpadTokenKind)] {
        let string = text as NSString
        return ScratchpadHighlighter.tokens(in: text, grammar: grammar).map { (string.substring(with: $0.range), $0.kind) }
    }

    private func has(_ tokens: [(String, ScratchpadTokenKind)], _ text: String, _ kind: ScratchpadTokenKind, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(tokens.contains { $0.0 == text && $0.1 == kind }, "\(text) as \(kind) in \(tokens)", file: file, line: line)
    }

    func testLanguagesComeFromTheNameThenTheShebang() {
        XCTAssertEqual(EditorLanguage.detect(fileName: "App.swift", firstLine: "").id, "swift")
        XCTAssertEqual(EditorLanguage.detect(fileName: "MAIN.PY", firstLine: "").id, "python", "Extensions ignore case")
        XCTAssertEqual(EditorLanguage.detect(fileName: "index.tsx", firstLine: "").id, "typescript")
        XCTAssertEqual(EditorLanguage.detect(fileName: "launch.json", firstLine: "").id, "json")
        XCTAssertEqual(EditorLanguage.detect(fileName: "Package.resolved", firstLine: "").id, "json")
        XCTAssertEqual(EditorLanguage.detect(fileName: "Makefile", firstLine: "").id, "shell")
        XCTAssertEqual(EditorLanguage.detect(fileName: "ci.yml", firstLine: "").id, "yaml")
        XCTAssertEqual(EditorLanguage.detect(fileName: "Cargo.toml", firstLine: "").id, "toml")
        XCTAssertEqual(EditorLanguage.detect(fileName: "deploy", firstLine: "#!/usr/bin/env bash").id, "shell")
        XCTAssertEqual(EditorLanguage.detect(fileName: "tool", firstLine: "#!/usr/bin/python3").id, "python")
        XCTAssertEqual(EditorLanguage.detect(fileName: "notes.txt", firstLine: "#!/bin/sh").id, "plain", "A known extension wins over the #! line")
        XCTAssertEqual(EditorLanguage.detect(fileName: "LICENSE", firstLine: "MIT").id, "plain")
        XCTAssertNil(EditorLanguage.swift.interpreter, "Editor languages never run")
    }

    func testSwiftTokens() {
        let tokens = kinds(
            """
            @MainActor final class Model: ObservableObject { // note
                let name = "a \\"quoted\\" // not a comment"
                /* block */ func run(_ count: Int = 42) async throws -> Bool? { nil }
                let text = \"\"\"
                multi // line
                \"\"\"
            }
            #if DEBUG
            """, .code(.swift))
        has(tokens, "@MainActor", .variable)
        has(tokens, "final", .keyword)
        has(tokens, "Model", .type)
        has(tokens, "// note", .comment)
        has(tokens, "\"a \\\"quoted\\\" // not a comment\"", .string)
        has(tokens, "/* block */", .comment)
        has(tokens, "run", .command)
        has(tokens, "42", .number)
        has(tokens, "nil", .number)
        has(tokens, "\"\"\"\n    multi // line\n    \"\"\"", .string)
        has(tokens, "#if", .variable)
        XCTAssertFalse(tokens.contains { $0.1 == .comment && $0.0.contains("multi") }, "A comment marker inside a string is text")
    }

    func testPythonGoRustCAndCSSTokens() {
        let python = kinds("def f(x):  # c\n    return \"\"\"doc\"\"\" if x else None\n@cache\n", .code(.python))
        has(python, "def", .keyword); has(python, "# c", .comment); has(python, "\"\"\"doc\"\"\"", .string); has(python, "None", .number); has(python, "@cache", .variable)
        let go = kinds("func main() { s := `raw\nline`; fmt.Println(s) }", .code(.go))
        has(go, "func", .keyword); has(go, "`raw\nline`", .string); has(go, "Println", .type)
        let rust = kinds("#[derive(Debug)] pub fn f<'a>(x: &'a str) -> Option<u8> { None }", .code(.rust))
        has(rust, "pub", .keyword); has(rust, "Option", .type)
        let c = kinds("#include <stdio.h>\nint main(void) { return NULL; }", .code(.cFamily))
        has(c, "#include", .variable); has(c, "int", .keyword); has(c, "NULL", .number)
        let css = kinds("@media (x) { .a { color: #fff !important; width: 10px; } } /* c */", .code(.css))
        has(css, "@media", .variable); has(css, "#fff", .variable); has(css, "!important", .keyword); has(css, "10px", .number); has(css, "/* c */", .comment)
    }

    func testMarkupYAMLAndTOMLTokens() {
        let html = kinds("<!-- c --><a href=\"x\" data-id='1'>Tom &amp; Jerry</a>", .markup)
        has(html, "<!-- c -->", .comment); has(html, "<a", .keyword); has(html, "href", .variable); has(html, "\"x\"", .string)
        has(html, "&amp;", .number); has(html, "</a", .keyword)
        let yaml = kinds("name: CI  # build\non:\n  - push\nretries: 3\nquiet: true\nurl: \"http://x#y\"\n", .yaml)
        has(yaml, "name", .keyword); has(yaml, "# build", .comment); has(yaml, "-", .operator); has(yaml, "3", .number); has(yaml, "true", .number)
        has(yaml, "\"http://x#y\"", .string)
        XCTAssertFalse(yaml.contains { $0.1 == .comment && $0.0.contains("y\"") }, "A # inside a string isn't a comment")
        let toml = kinds("[package]\nname = \"trellis\"\nversion = 2\n", .toml)
        has(toml, "[package]", .type); has(toml, "name", .keyword); has(toml, "\"trellis\"", .string); has(toml, "2", .number)
        XCTAssertTrue(kinds("anything", .plain).isEmpty)
    }

    func testHostileInputStaysLinear() {
        let inputs = [
            String(repeating: "/*", count: 20_000), String(repeating: "\"", count: 20_000), String(repeating: "<a ", count: 20_000),
            String(repeating: "a: '", count: 20_000), String(repeating: "\"\"\"", count: 20_000), String(repeating: "@", count: 40_000)
        ]
        let started = Date()
        for input in inputs {
            for grammar: ScratchpadLanguage.Grammar in [.code(.swift), .code(.python), .code(.css), .markup, .yaml, .toml] { _ = ScratchpadHighlighter.tokens(in: input, grammar: grammar) }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "Every grammar finishes quickly on unclosed delimiters")
    }

    func testTokensStayInsideTheText() {
        let samples = ["\"unterminated", "/* open", "<a href=\"", "key: 'open", "x = \"\"\"", "#", "@", "&#"]
        for sample in samples {
            let length = (sample as NSString).length
            for grammar: ScratchpadLanguage.Grammar in [.code(.swift), .code(.python), .code(.typescript), .code(.css), .markup, .yaml, .toml] {
                for token in ScratchpadHighlighter.tokens(in: sample, grammar: grammar) {
                    XCTAssertLessThanOrEqual(NSMaxRange(token.range), length, "\(sample) \(grammar)")
                    XCTAssertGreaterThan(token.range.length, 0, "\(sample) \(grammar)")
                }
            }
        }
    }
}
