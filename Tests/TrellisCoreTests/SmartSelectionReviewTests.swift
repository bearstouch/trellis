import XCTest
@testable import TrellisCore

final class SmartSelectionReviewTests: XCTestCase {
    func testUnbalancedBracketTailIsTrimmedInLinearTime() {
        for tail in [")", "]", "}", ">"] {
            let text = "https://example.com/a" + String(repeating: tail, count: 4_000)
            let start = Date()
            let match = SmartSelection.match(in: text, at: 3)
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "Slow trimming \(tail)")
            XCTAssertEqual(match.map { String(Array(text)[$0.range]) }, "https://example.com/a")
        }
        let start = Date()
        XCTAssertEqual(SmartSelection.trimmed("(" + String(repeating: "(", count: 2_000) + "x"), "x")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
    }
}

final class FileLinkPolicyReviewTests: XCTestCase {
    private let files = FileLinkContext(currentDirectory: "/work", homeDirectory: "/Users/me", localHostNames: ["mymac"])

    func testFileURLWithPortIsRefused() {
        XCTAssertNil(TerminalLinkClassifier.classify("file://mymac:22/etc/hosts", explicit: true, files: files))
        XCTAssertEqual(TerminalLinkClassifier.classify("file://mymac/etc/hosts", explicit: true, files: files), .file(path: "/etc/hosts", line: nil, column: nil))
    }

    func testAutomountPathsAreNeverProbed() {
        for link in ["/net/evil.example/x.txt", "/NET/evil/x", "//net/evil/x", "/tmp/../net/evil/x", "file:///Network/Servers/evil/x", "/network/x"] {
            XCTAssertNil(TerminalLinkClassifier.classify(link, explicit: false, files: files), link)
        }
        XCTAssertNotNil(TerminalLinkClassifier.classify("/netlify/x.txt", explicit: false, files: files))
    }

    func testLiveProbeRevealsFilesWithAnyExecuteBit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o604 | 0o001], ofItemAtPath: file.path)
        XCTAssertEqual(FileLinkPolicy.action(path: file.path), .reveal(file.resolvingSymlinksInPath()), "An others-only execute bit still counts")
    }
}
