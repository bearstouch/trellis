import Darwin
import XCTest
@testable import UTermCore

final class ThemeLibraryReviewTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uterm-theme-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func data(_ id: String = "review", name: String = "Review") -> Data {
        Data("{\"version\":1,\"id\":\"\(id)\",\"name\":\"\(name)\",\"appearance\":\"dark\"}".utf8)
    }

    func testReloadRejectsSymlinksAndFIFOWithoutReadingOutsideLibraryOrBlocking() async throws {
        let root = try directory()
        let themes = root.appendingPathComponent("Themes")
        let disk = DiskThemeLibraryFiles()
        try disk.prepare(themes)
        let external = root.appendingPathComponent("external.json")
        try data().write(to: external)
        try FileManager.default.createSymbolicLink(at: themes.appendingPathComponent("review.theme.json"), withDestinationURL: external)
        XCTAssertEqual(mkfifo(themes.appendingPathComponent("pipe.theme.json").path, 0o600), 0)
        let library = ThemeLibrary(directory: themes)
        let snapshot = await library.reload()
        XCTAssertTrue(snapshot.documents.isEmpty)
        XCTAssertEqual(Set(snapshot.issues.map(\.filename)), ["review.theme.json", "pipe.theme.json"])
        XCTAssertEqual(try Data(contentsOf: external), data())
    }

    func testInvalidExternalEditRetainsPriorDocumentUntilItsFileIsRemoved() async throws {
        let root = try directory()
        let library = ThemeLibrary(directory: root)
        let installed = try await library.install(data())
        let file = root.appendingPathComponent("review.theme.json")
        // A valid document saved under the wrong filename is still an invalid edit.
        try data("other").write(to: file)
        let invalid = await library.reload()
        XCTAssertEqual(invalid.documents, installed.documents)
        XCTAssertEqual(invalid.issues.count, 1)
        XCTAssertFalse(invalid.documents.keys.contains("other"))
        try FileManager.default.removeItem(at: file)
        let removed = await library.reload()
        XCTAssertTrue(removed.documents.isEmpty)
        XCTAssertTrue(removed.issues.isEmpty)
    }

    func testConcurrentIndependentLibrariesCannotOverwriteWithoutReplacement() async throws {
        let root = try directory()
        let first = ThemeLibrary(directory: root)
        let second = ThemeLibrary(directory: root)
        let a = data(name: "First"), b = data(name: "Second")
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            group.addTask { do { _ = try await first.install(a); return true } catch { return false } }
            group.addTask { do { _ = try await second.install(b); return true } catch { return false } }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let installed = try ThemeValidator.validate(Data(contentsOf: root.appendingPathComponent("review.theme.json")))
        XCTAssertTrue(["First", "Second"].contains(installed.name))
        let filenames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(filenames, ["review.theme.json"])
    }

    func testOversizedExternalEditRetainsLastValidPalette() async throws {
        let root = try directory()
        let library = ThemeLibrary(directory: root)
        let installed = try await library.install(data())
        try Data(repeating: 32, count: ThemeValidator.maximumBytes + 1).write(to: root.appendingPathComponent("review.theme.json"))
        let snapshot = await library.reload()
        XCTAssertEqual(snapshot.documents, installed.documents)
        XCTAssertEqual(snapshot.issues.count, 1)
    }
}
