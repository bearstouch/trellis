import Darwin
import XCTest
@testable import TrellisCore

final class SSHConfigDiscoveryReviewTests: XCTestCase {
    func testEqualsSeparatorWithSurroundingWhitespace() {
        let result = SSHConfigDiscovery.parse("Host = spaced\nHost =left\nHost= right\nHOST\t=\ttabbed other\nHost a=b\n")
        XCTAssertEqual(result.aliases.map(\.name), ["spaced", "left", "right", "tabbed", "other"])
        XCTAssertEqual(result.warnings, [.invalidName(line: 5, value: "a=b")])
    }

    func testReadConfigRejectsFIFOWithoutBlocking() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-ssh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fifo = dir.appendingPathComponent("config"), loop = dir.appendingPathComponent("loop")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try SSHConfigDiscovery.readConfig(fifo))
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: loop.path)
        XCTAssertThrowsError(try SSHConfigDiscovery.readConfig(loop), "A symlink loop is unreadable, not missing")
    }

    func testImportSkipsAliasesAlreadySavedOrRepeated() async throws {
        let storage = MemoryHostStorage()
        let library = HostLibrary(storage: storage)
        _ = try await library.create(HostDraft(name: "Prod", destination: "prod"))
        let imported = try await library.importAliases(["prod", "web", "web"])
        XCTAssertEqual(imported.map(\.destination), ["web"])
        let again = try await library.importAliases(["prod"])
        XCTAssertEqual(again, [])
        XCTAssertEqual(storage.writeCount, 2, "A no-op import does not write")
        let destinations = await library.hosts.map(\.destination)
        XCTAssertEqual(destinations, ["prod", "web"])
    }
}
