import Foundation
import XCTest

@testable import TrellisCore

/// The scratchpad's document rules, highlighter and syntax check (FR-SP02–FR-SP04).
final class ScratchpadTests: XCTestCase {
    private func kinds(_ text: String, _ grammar: ScratchpadLanguage.Grammar) -> [(String, ScratchpadTokenKind)] {
        let string = text as NSString
        return ScratchpadHighlighter.tokens(in: text, grammar: grammar).map { (string.substring(with: $0.range), $0.kind) }
    }

    private func contains(_ tokens: [(String, ScratchpadTokenKind)], _ text: String, _ kind: ScratchpadTokenKind) -> Bool {
        tokens.contains { $0.0 == text && $0.1 == kind }
    }

    func testLanguagesAreARegistryWithTheirChecksAndInterpreters() {
        XCTAssertEqual(ScratchpadLanguage.all.map(\.id), ["sh", "bash", "javascript", "markdown"])
        XCTAssertEqual(ScratchpadLanguage.all.map(\.checkDescription), ["sh -n", "bash -n", "node --check", nil])
        XCTAssertFalse(ScratchpadLanguage.markdown.isRunnable)
        XCTAssertNil(ScratchpadDocument(name: "notes", language: .markdown, text: "# Hi").taskCommand)
        XCTAssertNil(ScratchpadDocument(name: "notes", language: .markdown, text: "# Hi").runLine(path: "/tmp/notes.md", kind: .zsh))
        XCTAssertEqual(ScratchpadLanguage.javascript.fileExtension, "js")
        XCTAssertEqual(Set(ScratchpadLanguage.all.map(\.id)).count, ScratchpadLanguage.all.count, "Ids are unique")
    }

    func testRunLineAndTaskCommandQuoteForTheShell() {
        let document = ScratchpadDocument(name: "deploy-1.2", language: .bash, text: "echo hi")
        XCTAssertEqual(document.taskCommand, "bash .trellis/scratch/deploy-1.2.sh")
        XCTAssertEqual(document.runLine(path: "/tmp/it's here/deploy.sh", kind: .zsh), #"bash '/tmp/it'\''s here/deploy.sh'"#)
        XCTAssertEqual(document.runLine(path: "/tmp/a'b.js", kind: .fish), #"bash '/tmp/a\'b.js'"#)
        XCTAssertNil(document.runLine(path: "/tmp/\u{202E}x.sh", kind: .zsh), "Hidden characters are never typed")
    }

    func testNamesNeedNoQuoting() {
        for name in ["a", "deploy-preview", "v1.2_test", String(repeating: "x", count: 64)] { XCTAssertNil(ScratchpadDocument.nameProblem(name), name) }
        for name in ["", ".hidden", "-flag", "has space", "semi;colon", "quote'", "dollar$", "ünïcode", String(repeating: "x", count: 65)] {
            XCTAssertNotNil(ScratchpadDocument.nameProblem(name), name)
        }
    }

    func testSuggestedNamesComeFromTaskNames() {
        XCTAssertEqual(ScratchpadDocument.suggestedName(for: "Deploy preview!"), "deploy-preview")
        XCTAssertEqual(ScratchpadDocument.suggestedName(for: "  Run  tests: UI "), "run-tests-ui")
        XCTAssertEqual(ScratchpadDocument.suggestedName(for: "v1.2_build"), "v1.2_build")
        XCTAssertEqual(ScratchpadDocument.suggestedName(for: "...ünï"), "n", "Leading dots and dashes go")
        XCTAssertEqual(ScratchpadDocument.suggestedName(for: "!!!"), "script")
        XCTAssertEqual(ScratchpadDocument.suggestedName(for: String(repeating: "a", count: 90)).count, 64)
    }

    func testSavedFilesMapBackToTheirLanguage() {
        XCTAssertEqual(ScratchpadLanguage.detect(fileName: "a.js", text: ""), .javascript)
        XCTAssertEqual(ScratchpadLanguage.detect(fileName: "a.md", text: ""), .markdown)
        XCTAssertEqual(ScratchpadLanguage.detect(fileName: "a.sh", text: "echo"), .bash, "No #! line: bash")
        XCTAssertEqual(ScratchpadLanguage.detect(fileName: "a.sh", text: "#!/bin/sh\necho"), .sh)
        XCTAssertEqual(ScratchpadLanguage.detect(fileName: "a.sh", text: "#!/usr/bin/env -S sh -e\n"), .sh)
        XCTAssertEqual(ScratchpadLanguage.detect(fileName: "a.sh", text: "#!/usr/bin/env bash\n"), .bash)
        XCTAssertEqual(ScratchpadLanguage.detect(fileName: "a.sh", text: "#!/bin/zsh\n"), .bash, "Unknown shells open as bash")
        XCTAssertNil(ScratchpadLanguage.detect(fileName: "a.py", text: ""))
        for name in ["deploy.sh", "notes.md", "x.js"] { XCTAssertTrue(ScratchpadDocument.isScriptFileName(name), name) }
        for name in ["deploy", ".hidden.sh", "a b.sh", "x.py", "-x.md"] { XCTAssertFalse(ScratchpadDocument.isScriptFileName(name), name) }
    }

    func testMarkdownHighlightingAndNoHiddenCharacterCheck() {
        let tokens = kinds(
            """
            # Release notes
            Some **bold**, _em_ and `code` with a [link](https://x.dev) <!-- hidden -->
            - item
            12. step
            > quote
            ---
            ```bash
            # not a heading
            ```
            """, .markdown)
        XCTAssertTrue(contains(tokens, "# Release notes", .keyword))
        XCTAssertTrue(contains(tokens, "**bold**", .variable))
        XCTAssertTrue(contains(tokens, "_em_", .variable))
        XCTAssertTrue(contains(tokens, "`code`", .string))
        XCTAssertTrue(contains(tokens, "[link]", .command))
        XCTAssertTrue(contains(tokens, "(https://x.dev)", .string))
        XCTAssertTrue(contains(tokens, "<!-- hidden -->", .comment))
        XCTAssertTrue(contains(tokens, "-", .operator))
        XCTAssertTrue(contains(tokens, "12.", .operator))
        XCTAssertTrue(contains(tokens, ">", .operator))
        XCTAssertTrue(contains(tokens, "---", .operator))
        XCTAssertTrue(contains(tokens, "```bash", .comment))
        XCTAssertTrue(contains(tokens, "# not a heading", .string), "Inside a fence")
        XCTAssertFalse(contains(tokens, "# not a heading", .keyword))
        for text in ["**open", "`open", "[a](b", "```\nopen", "<!-- open", "1."] {
            for token in ScratchpadHighlighter.tokens(in: text, grammar: .markdown) { XCTAssertLessThanOrEqual(NSMaxRange(token.range), (text as NSString).length, text) }
        }
        XCTAssertEqual(ScratchpadDocument(name: "n", language: .markdown, text: "family 👨\u{200D}👩\u{200D}👧").issues, [], "Joiners render in notes")
    }

    func testIssuesFlagHiddenCharactersByLineButAllowTabs() {
        XCTAssertEqual(ScratchpadDocument(text: "if true; then\n\techo ok\nfi\n").issues, [])
        XCTAssertEqual(ScratchpadDocument(text: "  \n ").issues.map(\.message), ["Write a command or script first."])
        let hidden = ScratchpadDocument(text: "echo a\necho \u{202E}b\u{200B}\nls\r\n").issues
        XCTAssertEqual(hidden.map(\.line), [2, 3], "One issue per line")
        XCTAssertTrue(hidden[1].message.contains("carriage return"))
        XCTAssertEqual(ScratchpadDocument(text: String(repeating: "x", count: ScratchpadDocument.maximumBytes + 1)).issues.map(\.message), ["The script is larger than 64 KB."])
        XCTAssertEqual(ScratchpadDocument(name: "bad name", text: "ls").issues.count, 1)
    }

    func testShellHighlightingColorsCommandsKeywordsStringsAndExpansions() {
        let tokens = kinds(
            """
            #!/usr/bin/env bash
            changed=$(git diff --name-only HEAD | grep '\\.swift$' || true)
            if [[ -z "$changed" ]]; then echo "none ${#x}"; exit 0; fi
            for file in $changed; do echo "→ $file" > out.txt; done
            a#b
            """, .shell)
        XCTAssertTrue(contains(tokens, "#!/usr/bin/env bash", .comment))
        XCTAssertTrue(contains(tokens, "changed", .variable))
        XCTAssertTrue(contains(tokens, "=", .operator))
        XCTAssertTrue(contains(tokens, "$(", .variable))
        XCTAssertTrue(contains(tokens, "git", .command))
        XCTAssertTrue(contains(tokens, "grep", .command), "After a pipe a new command starts")
        XCTAssertFalse(contains(tokens, "diff", .command), "Arguments aren't commands")
        XCTAssertTrue(contains(tokens, "'\\.swift$'", .string))
        XCTAssertTrue(contains(tokens, "||", .operator))
        XCTAssertTrue(contains(tokens, "if", .keyword))
        XCTAssertTrue(contains(tokens, "\"$changed\"", .string))
        XCTAssertTrue(contains(tokens, "$changed", .variable), "Expansions inside double quotes")
        XCTAssertTrue(contains(tokens, "${#x}", .variable))
        XCTAssertTrue(contains(tokens, "echo", .command), "After then")
        XCTAssertTrue(contains(tokens, "0", .number))
        XCTAssertTrue(contains(tokens, "in", .keyword))
        XCTAssertTrue(contains(tokens, "done", .keyword))
        XCTAssertFalse(contains(tokens, "out.txt", .command), "A redirection names a file")
        XCTAssertFalse(tokens.contains { $0.1 == .comment && $0.0.hasPrefix("#b") }, "# inside a word isn't a comment")
    }

    func testShellAssignmentValuesArentCommands() {
        let tokens = kinds("LANG=C sort file\nX=1 Y=two make", .shell)
        XCTAssertTrue(contains(tokens, "LANG", .variable))
        XCTAssertFalse(contains(tokens, "C", .command), "The value isn't the command")
        XCTAssertTrue(contains(tokens, "sort", .command))
        XCTAssertFalse(contains(tokens, "two", .command))
        XCTAssertTrue(contains(tokens, "make", .command), "After several assignments")
    }

    func testJavaScriptHighlighting() {
        let tokens = kinds(
            """
            // list PRs
            const prs = JSON.parse(execSync('gh pr list', { encoding: "utf8" })); /* block
            comment */
            for (const pr of prs) console.log(`#${pr.number} ${pr.title}`, 0x1F, 2.5);
            """, .javascript)
        XCTAssertTrue(contains(tokens, "// list PRs", .comment))
        XCTAssertTrue(contains(tokens, "/* block\ncomment */", .comment))
        XCTAssertTrue(contains(tokens, "const", .keyword))
        XCTAssertTrue(contains(tokens, "of", .keyword))
        XCTAssertTrue(contains(tokens, "parse", .command))
        XCTAssertTrue(contains(tokens, "log", .command))
        XCTAssertFalse(contains(tokens, "prs", .command))
        XCTAssertTrue(contains(tokens, "'gh pr list'", .string))
        XCTAssertTrue(contains(tokens, "\"utf8\"", .string))
        XCTAssertTrue(contains(tokens, "${pr.number}", .variable))
        XCTAssertTrue(contains(tokens, "0x1F", .number))
        XCTAssertTrue(contains(tokens, "2.5", .number))
        XCTAssertTrue(contains(tokens, "=", .operator))
    }

    func testHighlightingStaysInBoundsOnUnterminatedAndLargeInput() {
        let length = { (text: String) in (text as NSString).length }
        for text in ["echo \"open", "echo 'open", "x=${open", "a\\", "$", "`", "'", "\"\\"] {
            for token in ScratchpadHighlighter.tokens(in: text, grammar: .shell) { XCTAssertLessThanOrEqual(NSMaxRange(token.range), length(text), text) }
        }
        for text in ["'open", "`a ${b", "/* open", "\"\\", "1."] {
            for token in ScratchpadHighlighter.tokens(in: text, grammar: .javascript) { XCTAssertLessThanOrEqual(NSMaxRange(token.range), length(text), text) }
        }
        let large = String(repeating: "for i in 1 2 3; do echo \"$i ${i}\" | grep 'x' # note\n", count: 1_200)
        XCTAssertGreaterThan(large.utf8.count, 60_000)
        let start = Date()
        XCTAssertFalse(ScratchpadHighlighter.tokens(in: large, grammar: .shell).isEmpty)
        XCTAssertFalse(ScratchpadHighlighter.tokens(in: large, grammar: .javascript).isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(ScratchpadHighlighter.tokens(in: "a 😀 \"é\"", grammar: .shell).last?.range, NSRange(location: 5, length: 3), "UTF-16 offsets: the emoji counts as two")
    }

    func testMarkdownHighlightingStaysLinearOnUnclosedMarkers() {
        // Each unclosed `[`, `*`, `<` or backtick used to rescan the rest of its line: a 60 KB line took minutes.
        let start = Date()
        for marker in ["[", "*a ", "<", "a`", "_ ", "![x]"] {
            let line = String(repeating: marker, count: 60_000 / marker.count)
            for token in ScratchpadHighlighter.tokens(in: line, grammar: .markdown) { XCTAssertLessThanOrEqual(NSMaxRange(token.range), (line as NSString).length) }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let tokens = ScratchpadHighlighter.tokens(in: "*a* [l](u) [x] <!-- c --> `c` **b**", grammar: .markdown)
        XCTAssertEqual(tokens.map(\.range.location), [0, 4, 7, 15, 26, 30], "Reused searches still find each first match")
    }

    // MARK: Validation

    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-sp-\(UUID().uuidString.prefix(8))")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var items: [(String, [String], String)] = []
        func add(_ item: (String, [String], String)) { lock.withLock { items.append(item) } }
    }

    /// Runs the check with `run` standing in for the interpreter, found unless `found` is false.
    private func check(_ document: ScratchpadDocument, found: Bool = true, run: @escaping ScratchpadProcessRunner) async -> ScratchpadCheck {
        await ScratchpadValidator.check(document, directory: folder, searchPath: ["/missing", "/fake/bin"], isExecutable: { found && $0.hasPrefix("/fake/bin/") }, run: run)
    }

    func testCheckRunsTheInterpreterOnAPrivateCopyAndParsesShellErrors() async throws {
        let calls = Calls()
        let result = await check(ScratchpadDocument(name: "x", language: .bash, text: "if true; then\n echo")) { executable, arguments, timeout in
            let path = try XCTUnwrap(arguments.last)
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
            calls.add((executable, arguments, try String(contentsOfFile: path, encoding: .utf8)))
            XCTAssertEqual(timeout, ScratchpadValidator.timeout)
            return ScratchpadProcessResult(status: 2, output: "\(path): line 2: syntax error: unexpected end of file\n")
        }
        XCTAssertEqual(result, ScratchpadCheck(.failed, issues: [ScratchpadIssue(line: 2, "syntax error: unexpected end of file")], checker: "bash -n"))
        XCTAssertEqual(calls.items.first?.0, "/fake/bin/bash", "The first folder that has it")
        XCTAssertEqual(calls.items.first?.1.first, "-n")
        XCTAssertEqual(calls.items.first?.2, "if true; then\n echo")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(leftovers, [], "The copy is removed")
    }

    func testCheckParsesNodeAndDashAndFallsBackToTheFirstLine() {
        let node = "/x/check.js:8\n  }\n  ^\n\nSyntaxError: Unexpected token '}'\n    at wrapSafe (node:internal)\n"
        XCTAssertEqual(ScratchpadValidator.parse(node, grammar: .javascript), [ScratchpadIssue(line: 8, "SyntaxError: Unexpected token '}'")])
        XCTAssertEqual(ScratchpadValidator.parse("x.sh: 3: Syntax error: end of file unexpected", grammar: .shell), [ScratchpadIssue(line: 3, "Syntax error: end of file unexpected")])
        XCTAssertEqual(ScratchpadValidator.parse("weird", grammar: .shell), [])
    }

    func testCheckReportsSuccessTimeoutsMissingInterpretersAndStaticIssues() async {
        let document = ScratchpadDocument(name: "x", language: .javascript, text: "console.log(1)")
        let passed = await check(document) { _, _, _ in ScratchpadProcessResult(status: 0, output: "") }
        XCTAssertEqual(passed, ScratchpadCheck(.passed, checker: "node --check"))
        let timedOut = await check(document) { _, _, _ in throw ScratchpadCheckTimedOut() }
        XCTAssertEqual(timedOut.outcome, .failed)
        let path = folder.path
        let unknown = await check(document) { _, _, _ in ScratchpadProcessResult(status: 1, output: "\n\(path)/odd failure\n") }
        XCTAssertEqual(unknown.issues.map(\.line), [nil])
        let missing = await check(document, found: false) { _, _, _ in
            XCTFail("Nothing runs")
            return ScratchpadProcessResult(status: 0, output: "")
        }
        let markdown = await check(ScratchpadDocument(name: "n", language: .markdown, text: "# Hi")) { _, _, _ in
            XCTFail("Markdown isn't checked")
            return ScratchpadProcessResult(status: 0, output: "")
        }
        XCTAssertEqual(markdown.outcome, .notChecked)
        XCTAssertEqual(missing.outcome, .notChecked)
        XCTAssertEqual(missing.issues.first?.message, "node wasn't found, so the syntax wasn't checked.")
        let hidden = await check(ScratchpadDocument(text: "echo \u{202E}x")) { _, _, _ in
            XCTFail("Static issues stop the check")
            return ScratchpadProcessResult(status: 0, output: "")
        }
        XCTAssertEqual(hidden.outcome, .failed)
        XCTAssertEqual(hidden.issues.first?.line, 1)
    }

    func testChecksNeverInheritVariablesThatLoadCode() async throws {
        XCTAssertEqual(
            ScratchpadValidator.checkEnvironment(["PATH": "/bin", "BASH_ENV": "/tmp/x", "ENV": "/tmp/y", "NODE_OPTIONS": "--require /tmp/z", "NODE_PATH": "/tmp", "HOME": "/h"]),
            ["PATH": "/bin", "HOME": "/h"])
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/bash"))
        // A real bash -n with BASH_ENV set in the app would run the file it names.
        let marker = folder.appendingPathComponent("ran").path
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "touch '\(marker)'\n".write(to: folder.appendingPathComponent("env.sh"), atomically: true, encoding: .utf8)
        setenv("BASH_ENV", folder.appendingPathComponent("env.sh").path, 1)
        defer { unsetenv("BASH_ENV") }
        let result = await ScratchpadValidator.check(ScratchpadDocument(name: "x", language: .bash, text: "echo ok\n"), directory: folder, searchPath: ["/bin"])
        XCTAssertEqual(result.outcome, .passed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "BASH_ENV wasn't run")
    }

    func testSearchPathAddsHomebrewAndSystemFoldersOnce() {
        XCTAssertEqual(
            ScratchpadValidator.searchPath(environment: ["PATH": "/usr/bin:relative:/custom/bin:/bin"]), ["/usr/bin", "/custom/bin", "/bin", "/opt/homebrew/bin", "/usr/local/bin"])
    }

    func testRealBashCheckFindsTheLine() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/bash"))
        let broken = await ScratchpadValidator.check(
            ScratchpadDocument(name: "real", language: .bash, text: "echo ok\nif true; then\n  echo x\n"), directory: folder, searchPath: ["/bin"])
        XCTAssertEqual(broken.outcome, .failed)
        XCTAssertEqual(broken.issues.first?.line, 4)
        XCTAssertFalse(broken.issues.first?.message.contains(folder.path) ?? true, "The private path isn't shown")
        let fine = await ScratchpadValidator.check(ScratchpadDocument(name: "real", language: .bash, text: "for a in 1 2; do echo \"$a\"; done\n"), directory: folder, searchPath: ["/bin"])
        XCTAssertEqual(fine.outcome, .passed)
    }
}
