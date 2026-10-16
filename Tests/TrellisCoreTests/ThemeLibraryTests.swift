import Darwin
import XCTest
@testable import TrellisCore

@MainActor
final class ThemeLibraryTests: XCTestCase {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("trellis-theme-\(UUID())/Themes") }
    func testS016_UT01_duplicateRequiresReplace() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let library = ThemeLibrary(directory: directory)
        let original = try ThemeExamples.data(.dark)
        _ = try await library.install(original)
        let file = directory.appendingPathComponent("my-dark.theme.json"), before = try Data(contentsOf: directory.appendingPathComponent("my-dark.theme.json"))
        let replacement = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "My Dark", with: "Replacement").utf8)
        do { _ = try await library.install(replacement); XCTFail("Duplicate replaced without explicit authorization") }
        catch { XCTAssertEqual(error as? ThemeLibraryError, .duplicateID("my-dark")) }
        XCTAssertEqual(try Data(contentsOf: file), before)
        let unchanged = await library.snapshot()
        XCTAssertEqual(unchanged.documents["my-dark"]?.name, "My Dark")
        let replaced = try await library.install(replacement, replace: true)
        XCTAssertEqual(replaced.documents["my-dark"]?.name, "Replacement")
    }
    func testS016_UT02_failedReplacePreservesOldFile() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let original = try ThemeExamples.data(.dark)
        _ = try await ThemeLibrary(directory: directory).install(original)
        let library = ThemeLibrary(directory: directory, files: FailingThemeCommit())
        let before = await library.reload()
        let file = directory.appendingPathComponent("my-dark.theme.json"), bytes = try Data(contentsOf: directory.appendingPathComponent("my-dark.theme.json"))
        let replacement = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "My Dark", with: "Replacement").utf8)
        do { _ = try await library.install(replacement, replace: true); XCTFail("Injected write should fail") }
        catch { XCTAssertEqual(error as? ThemeLibraryError, .io(ENOSPC)) }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let after = await library.snapshot()
        XCTAssertEqual(after, before)
    }
    func testS016_UT04_reloadInvalidAndMissingThemes() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let library = ThemeLibrary(directory: directory)
        let initial = try await library.install(ThemeExamples.data(.dark))
        let file = directory.appendingPathComponent("my-dark.theme.json")
        try Data("{bad json".utf8).write(to: file)
        let invalid = await library.reload()
        XCTAssertEqual(invalid.documents, initial.documents)
        XCTAssertEqual(invalid.issues.first?.filename, file.lastPathComponent)
        XCTAssertTrue(invalid.issues.first?.message.contains("$") == true)
        try FileManager.default.removeItem(at: file)
        let missing = await library.reload()
        XCTAssertTrue(missing.documents.isEmpty)
    }
    func testSparseAndResolvedExportsRoundTripWithoutSourceFile() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let library = ThemeLibrary(directory: directory)
        _ = try await library.install(ThemeExamples.data(.minimal))
        let original = try ThemeValidator.validate(ThemeExamples.data(.minimal))
        let sparse = try await library.export("my-midnight")
        let resolved = try await library.export("my-midnight", resolved: true)
        XCTAssertEqual(try ThemeValidator.validate(sparse), original)
        XCTAssertEqual(try ThemeValidator.validate(resolved).resolved(), original.resolved())
        XCTAssertEqual(try ThemeValidator.validate(resolved).terminal.count, 6)
        let other = ThemeLibrary(directory: directory.deletingLastPathComponent().appendingPathComponent("Imported"))
        let imported = try await other.install(resolved)
        XCTAssertEqual(imported.documents[original.id]?.resolved(), original.resolved())
        let fresh = await ThemeLibrary(directory: directory).reload()
        XCTAssertEqual(fresh.documents[original.id], original)
    }
    func testBuiltInNamespaceAndArbitraryDeletePathsAreProtected() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let library = ThemeLibrary(directory: directory)
        let data = try ResolvedTheme.builtIn(.light).encoded()
        do { _ = try await library.install(data, replace: true); XCTFail("Built-in replacement") }
        catch { XCTAssertEqual(error as? ThemeLibraryError, .reservedID) }
        do { _ = try await library.delete("trellis-light"); XCTFail("Built-in deletion") }
        catch { XCTAssertEqual(error as? ThemeLibraryError, .reservedID) }
        do { _ = try await library.delete("../other"); XCTFail("Traversal") }
        catch { XCTAssertEqual(error as? ThemeLibraryError, .notFound) }
    }
}

private struct FailingThemeCommit: ThemeLibraryFiles {
    let disk = DiskThemeLibraryFiles()
    func prepare(_ directory: URL) throws { try disk.prepare(directory) }
    func filenames(in directory: URL) throws -> [String] { try disk.filenames(in: directory) }
    func read(_ file: URL) throws -> Data { try disk.read(file) }
    func exists(_ file: URL) -> Bool { disk.exists(file) }
    func commit(_ data: Data, to file: URL, replace: Bool) throws { throw ThemeLibraryError.io(ENOSPC) }
    func remove(_ file: URL) throws { try disk.remove(file) }
}
