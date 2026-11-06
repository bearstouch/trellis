import XCTest

@testable import TrellisCore

/// The Changes view's parsing and tree (FR-GC02, FR-GC04, FR-GC05): porcelain v2, numstat, unified diffs, and folders.
final class GitChangesTests: XCTestCase {
    private func status(_ records: [String]) -> String { records.joined(separator: "\0") + "\0" }

    func testPorcelainEntriesBecomeKindsAndStagedStates() {
        let list = GitChanges.parseStatus(
            status([
                "# branch.oid 0123456789abcdef0123456789abcdef01234567", "# branch.head develop", "# branch.upstream origin/develop", "# branch.ab +2 -1",
                "1 .M N... 100644 100644 100644 aaa bbb Sources/App.swift",
                "1 M. N... 100644 100644 100644 aaa bbb staged.swift",
                "1 MM N... 100644 100644 100644 aaa bbb partly.swift",
                "1 A. N... 000000 100644 100644 000 bbb new file.swift",
                "1 D. N... 100644 000000 000000 aaa 000 gone.md",
                "1 .D N... 100644 100644 000000 aaa aaa removed.md",
                "u UU N... 100644 100644 100644 100644 a b c conflict.swift",
                "? notes/todo.txt",
                "! ignored.log"
            ]), root: "/repo")
        XCTAssertEqual(list.branch, "develop")
        XCTAssertNil(list.commit)
        XCTAssertEqual(list.ahead, 2); XCTAssertEqual(list.behind, 1)
        XCTAssertTrue(list.hasCommits)
        XCTAssertFalse(list.truncated)
        let byPath = Dictionary(uniqueKeysWithValues: list.files.map { ($0.path, $0) })
        XCTAssertEqual(list.files.count, 8, "Ignored files aren't listed")
        XCTAssertEqual(byPath["Sources/App.swift"]?.kind, .modified); XCTAssertEqual(byPath["Sources/App.swift"]?.staging, GitChangedFile.Staging.none)
        XCTAssertEqual(byPath["staged.swift"]?.staging, .full)
        XCTAssertEqual(byPath["partly.swift"]?.staging, .partial)
        XCTAssertEqual(byPath["new file.swift"]?.kind, .added, "A path with a space keeps it")
        XCTAssertEqual(byPath["gone.md"]?.kind, .deleted); XCTAssertEqual(byPath["gone.md"]?.staging, .full)
        XCTAssertEqual(byPath["removed.md"]?.kind, .deleted); XCTAssertEqual(byPath["removed.md"]?.staging, GitChangedFile.Staging.none)
        XCTAssertEqual(byPath["conflict.swift"]?.kind, .conflicted); XCTAssertEqual(byPath["conflict.swift"]?.kind.letter, "C")
        XCTAssertEqual(byPath["notes/todo.txt"]?.kind, .untracked); XCTAssertEqual(byPath["notes/todo.txt"]?.kind.letter, "U")
    }

    func testDetachedInitialRenamedAndCutOutput() {
        let detached = GitChanges.parseStatus(status(["# branch.oid 89abcdef0123456789abcdef0123456789abcdef", "# branch.head (detached)"]), root: "/r")
        XCTAssertNil(detached.branch); XCTAssertEqual(detached.commit, "89abcde")
        let initial = GitChanges.parseStatus(status(["# branch.oid (initial)", "# branch.head main", "? a.txt"]), root: "/r")
        XCTAssertFalse(initial.hasCommits, "Before the first commit everything compares with the empty tree")
        let renamed = GitChanges.parseStatus(status(["2 R. N... 100644 100644 100644 aaa bbb R100 new.swift", "old.swift", "? z.txt"]), root: "/r")
        XCTAssertEqual(renamed.files.map(\.path), ["new.swift", "z.txt"], "A rename's original path is its own record, never a file")
        let cut = GitChanges.parseStatus("? a.txt\0? b.t", root: "/r", complete: false)
        XCTAssertEqual(cut.files.map(\.path), ["a.txt"], "A record the buffer cut is dropped")
        XCTAssertTrue(cut.truncated)
        let duplicate = GitChanges.parseStatus(status(["1 D. N... 100644 000000 000000 aaa 000 x.swift", "? x.swift"]), root: "/r")
        XCTAssertEqual(duplicate.files.count, 1, "A deleted file re-created untracked is listed once")
    }

    func testTheListStopsAtTheFileLimit() {
        let records = (0..<(GitChanges.fileLimit + 5)).map { "? f\($0).txt" }
        let list = GitChanges.parseStatus(status(records), root: "/r")
        XCTAssertEqual(list.files.count, GitChanges.fileLimit)
        XCTAssertTrue(list.truncated)
    }

    func testNumstatCountsAndBinaryFiles() {
        let counts = GitChanges.parseNumstat("12\t3\tSources/App.swift\0-\t-\tlogo.png\00\t40\tgone.md\0")
        XCTAssertEqual(counts["Sources/App.swift"]?.added, 12); XCTAssertEqual(counts["Sources/App.swift"]?.removed, 3)
        XCTAssertNil(counts["logo.png"]?.added)
        let list = GitChanges.applying(
            counts,
            to: GitChangeList(
                root: "/r",
                files: [
                    GitChangedFile(path: "Sources/App.swift", kind: .modified, staging: .none), GitChangedFile(path: "logo.png", kind: .modified, staging: .none),
                    GitChangedFile(path: "gone.md", kind: .deleted, staging: .full), GitChangedFile(path: "new.txt", kind: .untracked, staging: .none, added: 5, removed: 0)
                ]))
        XCTAssertEqual(list.files[1].binary, true)
        XCTAssertEqual(list.files[3].added, 5, "Untracked counts come from the file, not numstat")
        XCTAssertEqual(list.added, 17); XCTAssertEqual(list.removed, 43)
    }

    func testLineCountsForNewFiles() {
        XCTAssertEqual(GitChanges.lineCount(Data("a\nb\n".utf8)), 2)
        XCTAssertEqual(GitChanges.lineCount(Data("a\nb".utf8)), 2, "A last line without a newline still counts")
        XCTAssertEqual(GitChanges.lineCount(Data()), 0)
        XCTAssertNil(GitChanges.lineCount(Data([0x41, 0x00, 0x42])), "A NUL byte means binary")
    }

    func testUnifiedDiffNumbersLinesAndFindsChanges() {
        let diff = GitChanges.parseDiff(
            """
            diff --git a/App.swift b/App.swift
            index 1111111..2222222 100644
            --- a/App.swift
            +++ b/App.swift
            @@ -2,4 +2,5 @@ import SwiftUI
             import Core
            -let a = 1
            +let a = 2
            +let b = 3

             struct App {}
            @@ -40 +41 @@ struct App {}
            -old
            +new
            \\ No newline at end of file

            """)
        guard case .lines(let lines) = diff.body else { return XCTFail("Expected lines") }
        XCTAssertEqual(diff.hunks, 2)
        XCTAssertEqual(lines.first?.kind, .hunk)
        XCTAssertEqual(lines[1].old, 2); XCTAssertEqual(lines[1].new, 2); XCTAssertEqual(lines[1].text, "import Core")
        XCTAssertEqual(lines[2].kind, .removed); XCTAssertEqual(lines[2].old, 3); XCTAssertNil(lines[2].new)
        XCTAssertEqual(lines[3].kind, .added); XCTAssertEqual(lines[3].new, 3)
        XCTAssertEqual(lines[4].new, 4)
        XCTAssertEqual(lines[5].kind, .context, "A context line that is only a space"); XCTAssertEqual(lines[5].old, 4); XCTAssertEqual(lines[5].new, 5)
        XCTAssertEqual(lines[8].old, 40); XCTAssertEqual(lines[9].new, 41)
        XCTAssertEqual(lines.last?.kind, .note); XCTAssertEqual(lines.last?.text, "No newline at end of file")
        XCTAssertEqual(diff.changeStarts, [2, 8], "One start per run of changed lines")
        XCTAssertEqual(lines[3].spoken, "Added line 3: let a = 2")
        XCTAssertEqual(lines[2].spoken, "Removed line 3: let a = 1")
    }

    func testOddPathsSurviveNulSeparatedRecordsAndCRLFLinesLoseTheirReturn() {
        let odd = ["tab\there.txt", "new\nline.txt", "-dash.txt", "sp ace/x y.md"]
        let list = GitChanges.parseStatus(status(odd.map { "1 .M N... 100644 100644 100644 aaa bbb \($0)" }), root: "/r")
        XCTAssertEqual(list.files.map(\.path), odd, "With -z a path keeps its tabs, newlines and spaces")
        let counts = GitChanges.parseNumstat(odd.map { "1\t2\t\($0)" }.joined(separator: "\0") + "\0")
        XCTAssertEqual(Set(counts.keys), Set(odd))
        guard case .lines(let lines) = GitChanges.parseDiff("@@ -1,2 +1,2 @@\r\n x\r\n-y\r\n+Y\r\n").body else { return XCTFail() }
        XCTAssertEqual(lines.map(\.text), ["@@ -1,2 +1,2 @@", "x", "y", "Y"])
    }

    func testNewFileBinaryUnchangedAndLargeDiffs() {
        guard case .lines(let lines) = GitChanges.parseDiff("--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1,2 @@\n+one\n+two\n").body else { return XCTFail() }
        XCTAssertEqual(lines[1].new, 1, "An empty old side starts the new file at line 1")
        XCTAssertEqual(GitChanges.parseDiff("diff --git a/x.png b/x.png\nBinary files a/x.png and b/x.png differ\n").body, .binary)
        XCTAssertEqual(GitChanges.parseDiff("").body, .unchanged)
        let big = "@@ -1,0 +1,30 @@\n" + (1...30).map { "+\($0)" }.joined(separator: "\n")
        XCTAssertEqual(GitChanges.parseDiff(big, lineLimit: 10).body, .tooLarge)
    }

    func testTreeMergesFolderChainsSumsAndSorts() {
        let files = [
            GitChangedFile(path: "docs/features/changes.md", kind: .added, staging: .none, added: 84, removed: 0),
            GitChangedFile(path: "Sources/UI/Right.swift", kind: .modified, staging: .none, added: 31, removed: 9),
            GitChangedFile(path: "Sources/UI/file10.swift", kind: .modified, staging: .none, added: 1, removed: 0),
            GitChangedFile(path: "Sources/UI/file2.swift", kind: .modified, staging: .none, added: 1, removed: 0),
            GitChangedFile(path: "Sources/Core/Git.swift", kind: .added, staging: .full, added: 10, removed: 0),
            GitChangedFile(path: "README.md", kind: .modified, staging: .none, added: 2, removed: 1),
            GitChangedFile(path: "logo.png", kind: .modified, staging: .none, binary: true)
        ]
        let rows = GitChanges.rows(files, collapsed: [], filter: "")
        XCTAssertEqual(
            rows.map { "\(String(repeating: " ", count: $0.depth))\($0.name)" },
            ["docs/features", " changes.md", "Sources", " Core", "  Git.swift", " UI", "  file2.swift", "  file10.swift", "  Right.swift", "logo.png", "README.md"],
            "Folders first, natural name order, a one-folder chain merged")
        let sources = rows.first { $0.path == "Sources" }
        XCTAssertEqual(sources?.added, 43); XCTAssertEqual(sources?.removed, 9)
        XCTAssertEqual(rows.first?.path, "docs/features")
        XCTAssertEqual(GitChangeList(root: "/r", files: files).orderedFiles.map(\.name), ["changes.md", "Git.swift", "file2.swift", "file10.swift", "Right.swift", "logo.png", "README.md"])

        let folded = GitChanges.rows(files, collapsed: ["Sources/UI", "docs/features"], filter: "")
        XCTAssertEqual(folded.map(\.name), ["docs/features", "Sources", "Core", "Git.swift", "UI", "logo.png", "README.md"])
        XCTAssertEqual(folded.first { $0.path == "Sources/UI" }?.isExpanded, false)

        let filtered = GitChanges.rows(files, collapsed: ["Sources", "Sources/UI"], filter: "right")
        XCTAssertEqual(filtered.map(\.name), ["Sources/UI", "Right.swift"], "A filter shows matches inside open folders, whatever is folded")
        XCTAssertEqual(GitChanges.folderPaths(files), ["docs/features", "Sources", "Sources/Core", "Sources/UI"])
    }
}
