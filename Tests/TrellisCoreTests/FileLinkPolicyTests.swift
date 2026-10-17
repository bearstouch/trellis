import XCTest
@testable import TrellisCore

final class FileLinkPolicyTests: XCTestCase {
    private let context = FileLinkContext(currentDirectory: "/Users/me/project", homeDirectory: "/Users/me", localHostNames: ["mymac", "mymac.local"])

    private func file(_ path: String, _ line: Int? = nil, _ column: Int? = nil) -> TerminalLinkTarget { .file(path: path, line: line, column: column) }

    private func probe(_ table: [String: FileFacts]) -> FileProbe { FileProbe { table[$0] } }

    func testWebLinksStillUseLinkPolicy() {
        XCTAssertEqual(TerminalLinkClassifier.classify("https://example.com/a", explicit: true, files: nil), .web(URL(string: "https://example.com/a")!))
        XCTAssertEqual(TerminalLinkClassifier.classify("https://example.com/a", explicit: false, files: context), .web(URL(string: "https://example.com/a")!))
        XCTAssertNil(TerminalLinkClassifier.classify("https://user:pw@example.com", explicit: false, files: context))
    }

    func testNoContextRefusesAllFiles() {
        for link in ["/etc/hosts", "file:///etc/hosts", "~/notes.txt", "src/a.swift"] {
            XCTAssertNil(TerminalLinkClassifier.classify(link, explicit: false, files: nil), link)
        }
    }

    func testAbsoluteTildeAndRelativeResolution() {
        XCTAssertEqual(TerminalLinkClassifier.classify("/etc/hosts", explicit: false, files: context), file("/etc/hosts"))
        XCTAssertEqual(TerminalLinkClassifier.classify("~/notes.txt", explicit: false, files: context), file("/Users/me/notes.txt"))
        XCTAssertEqual(TerminalLinkClassifier.classify("./src/a.swift", explicit: false, files: context), file("/Users/me/project/src/a.swift"))
        XCTAssertEqual(TerminalLinkClassifier.classify("../other/b.txt", explicit: false, files: context), file("/Users/me/other/b.txt"))
        XCTAssertEqual(TerminalLinkClassifier.classify("src/a.swift", explicit: false, files: context), file("/Users/me/project/src/a.swift"))
        var noDirectory = context
        noDirectory.currentDirectory = nil
        XCTAssertNil(TerminalLinkClassifier.classify("src/a.swift", explicit: false, files: noDirectory), "Relative paths need the shell's directory")
        XCTAssertEqual(TerminalLinkClassifier.classify("/abs/x", explicit: false, files: noDirectory), file("/abs/x"))
        XCTAssertNil(TerminalLinkClassifier.classify("~root/.ssh/id", explicit: false, files: context))
        XCTAssertNil(TerminalLinkClassifier.classify("$HOME/x", explicit: false, files: context))
    }

    func testLineColumnSuffixStripped() {
        XCTAssertEqual(TerminalLinkClassifier.classify("src/a.swift:12:5", explicit: false, files: context), file("/Users/me/project/src/a.swift", 12, 5))
        XCTAssertEqual(TerminalLinkClassifier.classify("/x/b.txt:7", explicit: false, files: context), file("/x/b.txt", 7))
        XCTAssertEqual(TerminalLinkClassifier.classify("(/x/b.txt:7:).", explicit: false, files: context), file("/x/b.txt", 7))
    }

    func testFileURLHostRules() {
        XCTAssertEqual(TerminalLinkClassifier.classify("file:///etc/hosts", explicit: true, files: context), file("/etc/hosts"))
        XCTAssertEqual(TerminalLinkClassifier.classify("file://localhost/etc/hosts", explicit: true, files: context), file("/etc/hosts"))
        XCTAssertEqual(TerminalLinkClassifier.classify("file://MyMac.local./tmp/a", explicit: true, files: context), file("/tmp/a"))
        XCTAssertEqual(TerminalLinkClassifier.classify("file:///tmp/%E2%9C%93%20done.txt", explicit: true, files: context), file("/tmp/✓ done.txt"))
        XCTAssertNil(TerminalLinkClassifier.classify("file://evil.example/etc/hosts", explicit: true, files: context))
        XCTAssertNil(TerminalLinkClassifier.classify("file://user@localhost/etc/hosts", explicit: true, files: context))
        XCTAssertNil(TerminalLinkClassifier.classify("file:///tmp/a?x=1", explicit: true, files: context))
        XCTAssertNil(TerminalLinkClassifier.classify("file:///tmp/a%0Ab", explicit: true, files: context))
        XCTAssertNil(TerminalLinkClassifier.classify("file:relative", explicit: true, files: context))
    }

    func testExplicitSchemelessRefused() {
        XCTAssertNil(TerminalLinkClassifier.classify("/etc/hosts", explicit: true, files: context), "An OSC 8 target hides behind its visible text")
        XCTAssertNil(TerminalLinkClassifier.classify("src/a.swift", explicit: true, files: context))
    }

    func testOtherSchemesRefused() {
        for link in ["ssh://host/x", "ssh:host", "tel:123", "x-custom:do", "javascript:alert(1)", "vnc://host", "ftp://host/a"] {
            XCTAssertNil(TerminalLinkClassifier.classify(link, explicit: false, files: context), link)
        }
    }

    func testControlCharactersAndOverlongRefused() {
        XCTAssertNil(TerminalLinkClassifier.classify("/tmp/a\u{1b}[31m", explicit: false, files: context))
        XCTAssertNil(TerminalLinkClassifier.classify("/tmp/a\nb", explicit: false, files: context))
        XCTAssertNil(TerminalLinkClassifier.classify("/" + String(repeating: "a", count: 1100), explicit: false, files: context))
    }

    func testExecutablesPackagesAndScriptsAreRevealedNeverOpened() {
        let cases: [(String, FileFacts)] = [
            ("/bin/tool", FileFacts(resolvedPath: "/bin/tool", kind: .regular, isExecutable: true)),
            ("/Applications/X.app", FileFacts(resolvedPath: "/Applications/X.app", kind: .directory, isPackage: true)),
            ("/tmp/run.command", FileFacts(resolvedPath: "/tmp/run.command", kind: .regular)),
            ("/tmp/run.SH", FileFacts(resolvedPath: "/tmp/run.SH", kind: .regular)),
            ("/tmp/site.webloc", FileFacts(resolvedPath: "/tmp/site.webloc", kind: .regular)),
            ("/tmp/install.pkg", FileFacts(resolvedPath: "/tmp/install.pkg", kind: .regular)),
            ("/tmp/odd", FileFacts(resolvedPath: "/tmp/odd", kind: .regular, isLaunchableType: true))
        ]
        for (path, facts) in cases {
            XCTAssertEqual(FileLinkPolicy.action(path: path, probe: probe([path: facts])), .reveal(URL(fileURLWithPath: facts.resolvedPath)), path)
        }
    }

    func testDirectoryOpensRegularFileOpensMissingAndDevicesRefused() {
        let table = [
            "/tmp/dir": FileFacts(resolvedPath: "/tmp/dir", kind: .directory),
            "/tmp/a.txt": FileFacts(resolvedPath: "/tmp/a.txt", kind: .regular),
            "/dev/null": FileFacts(resolvedPath: "/dev/null", kind: .other)
        ]
        XCTAssertEqual(FileLinkPolicy.action(path: "/tmp/dir", probe: probe(table)), .open(URL(fileURLWithPath: "/tmp/dir")))
        XCTAssertEqual(FileLinkPolicy.action(path: "/tmp/a.txt", probe: probe(table)), .open(URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertNil(FileLinkPolicy.action(path: "/dev/null", probe: probe(table)))
        XCTAssertNil(FileLinkPolicy.action(path: "/tmp/missing", probe: probe(table)))
    }

    func testSymlinkClassifiedByTarget() {
        let table = ["/tmp/readme.txt": FileFacts(resolvedPath: "/bin/sh", kind: .regular, isExecutable: true)]
        XCTAssertEqual(FileLinkPolicy.action(path: "/tmp/readme.txt", probe: probe(table)), .reveal(URL(fileURLWithPath: "/bin/sh")))
    }

    func testLiveProbeOnRealFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appendingPathComponent("notes.txt"), script = directory.appendingPathComponent("tool")
        try Data("hi".utf8).write(to: text)
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
        XCTAssertEqual(FileLinkPolicy.action(path: text.path), .open(text.resolvingSymlinksInPath()))
        XCTAssertEqual(FileLinkPolicy.action(path: script.path), .reveal(script.resolvingSymlinksInPath()))
        XCTAssertEqual(FileLinkPolicy.action(path: link.path), .reveal(script.resolvingSymlinksInPath()))
        XCTAssertEqual(FileLinkPolicy.action(path: directory.path), .open(directory.resolvingSymlinksInPath()))
        XCTAssertNil(FileLinkPolicy.action(path: directory.appendingPathComponent("missing").path))
    }

    func testGestureIsFresh() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(LinkPolicy.gestureIsFresh(lastGesture: now, now: now))
        XCTAssertFalse(LinkPolicy.gestureIsFresh(lastGesture: nil, now: now))
        XCTAssertFalse(LinkPolicy.gestureIsFresh(lastGesture: now.addingTimeInterval(-2), now: now))
        XCTAssertFalse(LinkPolicy.gestureIsFresh(lastGesture: now.addingTimeInterval(1), now: now))
    }
}
