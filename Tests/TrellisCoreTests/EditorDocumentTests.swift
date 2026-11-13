import Foundation
import XCTest

@testable import TrellisCore

/// Editor tabs' files (FR-ED02–FR-ED04, FR-ED06): decoding, refusals, saving and noticing disk changes.
final class EditorDocumentTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-ed-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private func file(_ name: String, _ data: Data) throws -> String {
        let path = scratch.appendingPathComponent(name).path
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    func testLineEndingsBOMAndTheFinalNewlineRoundTrip() throws {
        for bytes in ["a\nb\n", "a\nb", "a\r\nb\r\n", "\u{FEFF}héllo\r\n", "mixed\r\nends\n", "", "no newline"] {
            let path = try file("f.txt", Data(bytes.utf8))
            let document = try EditorDocument.load(path: path)
            let saved = try document.saving(document.text)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data(bytes.utf8), "Unchanged text saves the same bytes: \(bytes.debugDescription)")
            XCTAssertEqual(saved.text, document.text)
        }
        let crlf = try EditorDocument.load(path: try file("c.txt", Data("one\r\ntwo\r\n".utf8)))
        XCTAssertEqual(crlf.text, "one\ntwo\n", "CRLF throughout is edited as plain line breaks")
        XCTAssertEqual(crlf.lineEnding, .crlf)
        _ = try crlf.saving("one\ntwo\nthree\n")
        XCTAssertEqual(try String(contentsOfFile: crlf.path, encoding: .utf8), "one\r\ntwo\r\nthree\r\n", "Typed lines get the file's endings")
        let bom = try EditorDocument.load(path: try file("b.txt", Data([0xEF, 0xBB, 0xBF]) + Data("x".utf8)))
        XCTAssertTrue(bom.hasBOM)
        XCTAssertEqual(bom.text, "x")
    }

    func testBinaryInvalidAndOversizedFilesAreRefused() throws {
        XCTAssertThrowsError(try EditorDocument.load(path: try file("bin", Data([0x41, 0x00, 0x42])))) { XCTAssertEqual($0 as? EditorFileError, .binary) }
        XCTAssertThrowsError(try EditorDocument.load(path: try file("latin1", Data([0x63, 0x61, 0x66, 0xE9])))) { XCTAssertEqual($0 as? EditorFileError, .notUTF8) }
        let big = Data(repeating: 0x61, count: EditorDocument.maximumBytes + 1)
        XCTAssertThrowsError(try EditorDocument.load(path: try file("big", big))) { XCTAssertEqual($0 as? EditorFileError, .tooLarge) }
        XCTAssertNoThrow(try EditorDocument.load(path: try file("max", Data(repeating: 0x61, count: EditorDocument.maximumBytes))))
        XCTAssertThrowsError(try EditorDocument.load(path: scratch.path)) { XCTAssertEqual($0 as? EditorFileError, .notAFile) }
        XCTAssertThrowsError(try EditorDocument.load(path: scratch.appendingPathComponent("missing").path)) { XCTAssertEqual($0 as? EditorFileError, .notAFile) }
        XCTAssertTrue(EditorFileError.binary.opensElsewhere && EditorFileError.tooLarge.opensElsewhere && EditorFileError.notUTF8.opensElsewhere)
        XCTAssertFalse(EditorFileError.notAFile.opensElsewhere)
    }

    func testSavingReplacesAtomicallyKeepsPermissionsAndFollowsLinks() throws {
        let path = try file("script.sh", Data("echo hi\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: path)
        let document = try EditorDocument.load(path: path)
        let saved = try document.saving("echo bye\n")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "echo bye\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o750, "Permissions are kept")
        XCTAssertNotNil(saved.stamp)
        XCTAssertEqual(saved.diskState(), .unchanged, "A save is what the tab now knows")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter { $0.contains(".trellis-") }
        XCTAssertEqual(leftovers, [], "No temporary file is left behind")

        let link = scratch.appendingPathComponent("link.sh").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        _ = try EditorDocument.load(path: link).saving("echo link\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), path, "The link stays a link")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "echo link\n", "Its target is written")
    }

    func testAFailedSaveLeavesTheFileAndTheDocument() throws {
        let path = try file("keep.txt", Data("original\n".utf8))
        let document = try EditorDocument.load(path: path)
        var fs = EditorFileSystem.live
        fs.write = { _, _ in throw EditorFileError.writeFailed("disk full") }
        XCTAssertThrowsError(try document.saving("changed\n", fs: fs)) { XCTAssertEqual($0 as? EditorFileError, .writeFailed("disk full")) }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "original\n")
        XCTAssertEqual(document.text, "original\n")

        // A real failure: the folder is read-only, so the temporary file can't be created.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: scratch.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path) }
        XCTAssertThrowsError(try document.saving("changed\n")) { error in
            guard case .writeFailed? = error as? EditorFileError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "original\n")
    }

    func testDiskChangesAndDeletionAreNoticed() throws {
        let path = try file("watched.txt", Data("one\n".utf8))
        let document = try EditorDocument.load(path: path)
        XCTAssertEqual(document.diskState(), .unchanged)
        try Data("one two\n".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(document.diskState(), .changed)
        try FileManager.default.removeItem(atPath: path)
        XCTAssertEqual(document.diskState(), .deleted)
        let saved = try document.saving("back\n")
        XCTAssertEqual(saved.diskState(), .unchanged, "Save creates a deleted file again")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "back\n")
    }

    func testLinksOpenInTheEditorOnlyInsideTheProjectOrCurrentFolder() throws {
        let project = scratch.appendingPathComponent("project").path, other = scratch.appendingPathComponent("other").path
        for folder in [project + "/Sources", other] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(atPath: project + "/escape", withDestinationPath: other)
        XCTAssertTrue(EditorLinkScope.contains(project + "/Sources/App.swift", roots: [project]))
        XCTAssertFalse(EditorLinkScope.contains(other + "/x.txt", roots: [project]))
        XCTAssertFalse(EditorLinkScope.contains(project + "/../other/x.txt", roots: [project]), "`..` can't leave the project")
        XCTAssertFalse(EditorLinkScope.contains(project + "/escape/x.txt", roots: [project]), "A link out of the project is judged by its target")
        XCTAssertFalse(EditorLinkScope.contains(project + "x/y.txt", roots: [project]), "A sibling with a longer name isn't inside")
        XCTAssertTrue(EditorLinkScope.contains(other + "/x.txt", roots: [project, other]), "The current folder counts too")
        XCTAssertFalse(EditorLinkScope.contains("/etc/hosts", roots: ["/"]), "The root folder never makes everything editable")
        let context = FileLinkContext(currentDirectory: nil, homeDirectory: NSHomeDirectory(), projectRoot: project)
        XCTAssertTrue(context.editorMayOpen(project + "/Sources/App.swift"))
        XCTAssertFalse(FileLinkContext(currentDirectory: nil, homeDirectory: NSHomeDirectory()).editorMayOpen(project + "/a"), "No folders, no editor")
    }
}
