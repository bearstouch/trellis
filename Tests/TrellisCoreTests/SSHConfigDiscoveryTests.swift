import XCTest
@testable import TrellisCore

final class SSHConfigDiscoveryTests: XCTestCase {
    func testS019_UT01_discoverLiteralAliases() {
        let config = """
            # Personal hosts
              Host prod-api  prod-db   # two aliases
            \tHostName 10.0.0.5
            \tUser deploy
            Host=staging
            host "quoted.example"
            Host prod-api
            HostName ignored-for-discovery
            #Host commented-out
            """
        let result = SSHConfigDiscovery.parse(config)
        XCTAssertEqual(result.aliases.map(\.name), ["prod-api", "prod-db", "staging", "quoted.example"])
        XCTAssertEqual(result.aliases.map(\.line), [2, 2, 5, 6])
        XCTAssertEqual(result.warnings, [])
    }

    func testS019_UT02_skipPatternsAndMatch() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-match-exec-\(UUID().uuidString)")
        let config = """
            Host *
              ServerAliveInterval 30
            Host *.corp !bastion.corp web? bastion
            Match exec "touch \(marker.path)"
              User attacker
            Host -oProxyCommand=x
            """
        let result = SSHConfigDiscovery.parse(config)
        XCTAssertEqual(result.aliases.map(\.name), ["bastion"])
        XCTAssertEqual(
            result.warnings,
            [
                .pattern(line: 1, value: "*"), .pattern(line: 3, value: "*.corp"), .pattern(line: 3, value: "!bastion.corp"),
                .pattern(line: 3, value: "web?"), .match(line: 4), .invalidName(line: 6, value: "-oProxyCommand=x")
            ])
        // Discovery is pure parsing: the Match exec command never runs.
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testS019_UT03_includeHasExplicitLimitation() {
        let result = SSHConfigDiscovery.parse("Include ~/.ssh/config.d/*\nHost local-only\n")
        XCTAssertEqual(result.aliases.map(\.name), ["local-only"])
        XCTAssertEqual(result.warnings, [.include(line: 1, pattern: "~/.ssh/config.d/*")])
        XCTAssertTrue(result.warnings[0].description.contains("not followed"))
        XCTAssertTrue(result.warnings[0].description.contains("manually"))
    }

    func testS019_UT04_unreadableConfigIsNonDestructive() async throws {
        let storage = MemoryHostStorage()
        let library = HostLibrary(storage: storage)
        let existing = try await library.create(HostDraft(name: "Prod", destination: "prod"))
        let before = storage.data
        let writesBefore = storage.writeCount
        let outcome = SSHConfigDiscovery.discover(URL(fileURLWithPath: "/fixture/.ssh/config")) { _ in throw CocoaError(.fileReadNoPermission) }
        guard case .failure(.unreadable) = outcome else { return XCTFail("Expected a recoverable read failure, got \(outcome)") }
        let hosts = await library.hosts
        XCTAssertEqual(hosts, [existing])
        XCTAssertEqual(storage.data, before)
        XCTAssertEqual(storage.writeCount, writesBefore)
        let missing = SSHConfigDiscovery.discover(URL(fileURLWithPath: "/fixture/.ssh/config")) { _ in nil }
        XCTAssertEqual(missing, .failure(.missing))
    }

    func testImportKeepsAliasAsDestinationAtomically() async throws {
        let storage = MemoryHostStorage()
        let library = HostLibrary(storage: storage)
        let imported = try await library.importAliases(["prod-api", "staging"])
        XCTAssertEqual(imported.map(\.destination), ["prod-api", "staging"])
        XCTAssertEqual(imported.map(\.name), ["prod-api", "staging"])
        XCTAssertEqual(imported[0].connectionLaunch, .process(executable: "/usr/bin/ssh", arguments: ["--", "prod-api"], directory: nil))
        XCTAssertEqual(storage.writeCount, 1, "One commit for the whole selection")
        do {
            _ = try await library.importAliases(["ok-alias", "-bad"])
            XCTFail("Invalid alias imported")
        } catch {
            guard case .invalid = error else { return XCTFail("\(error)") }
        }
        let names = await library.hosts.map(\.name)
        XCTAssertEqual(names, ["prod-api", "staging"], "Nothing from a failed selection is saved")
    }

    func testReadConfigIsBoundedAndReadOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-ssh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("config"), link = dir.appendingPathComponent("linked")
        try Data("Host a\n".utf8).write(to: config)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: config)
        XCTAssertEqual(try SSHConfigDiscovery.readConfig(link), Data("Host a\n".utf8))
        XCTAssertNil(try SSHConfigDiscovery.readConfig(dir.appendingPathComponent("absent")))
        XCTAssertThrowsError(try SSHConfigDiscovery.readConfig(dir))
        try Data(count: SSHConfigDiscovery.byteLimit + 1).write(to: config)
        XCTAssertThrowsError(try SSHConfigDiscovery.readConfig(config))
    }
}
