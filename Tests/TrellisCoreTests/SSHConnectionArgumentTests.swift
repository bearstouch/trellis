import XCTest
@testable import TrellisCore

final class SSHConnectionArgumentTests: XCTestCase {
    private func host(_ draft: HostDraft, keys: Set<String> = []) throws -> SavedHost {
        SavedHost(id: UUID(), draft: try draft.validated(isRegularFile: keys.contains), revision: 1)
    }

    func testS020_UT01_buildSshArgumentsSafely() throws {
        let key = "/Users/me/Key Files/id ed25519"
        let full = try host(HostDraft(name: "Prod", destination: "prod-api", user: "deploy", port: "2222", identityFile: key), keys: [key])
        XCTAssertEqual(
            full.connectionLaunch,
            .process(executable: "/usr/bin/ssh", arguments: ["-p", "2222", "-l", "deploy", "-i", key, "--", "prod-api"], directory: nil))
        // Unset fields stay delegated to ssh_config: only the alias is passed.
        XCTAssertEqual(try host(HostDraft(name: "Alias", destination: "prod-api")).connectionLaunch, .process(executable: "/usr/bin/ssh", arguments: ["--", "prod-api"], directory: nil))
        // Spaces and shell syntax stay inside one argv element; nothing is interpolated.
        guard case .process(let executable, let arguments, _) = full.connectionLaunch else { return XCTFail() }
        XCTAssertEqual(executable, "/usr/bin/ssh")
        XCTAssertEqual(arguments.firstIndex(of: key), 5)
        XCTAssertEqual(arguments.last, "prod-api")
        XCTAssertEqual(arguments[arguments.count - 2], "--")
    }

    func testS020_UT02_neverAddTrustBypass() throws {
        let key = "/k/id"
        let variants = [
            HostDraft(name: "a", destination: "h"),
            HostDraft(name: "a", destination: "h", user: "u"),
            HostDraft(name: "a", destination: "h", port: "22"),
            HostDraft(name: "a", destination: "h", identityFile: key),
            HostDraft(name: "a", destination: "10.0.0.1", user: "u", port: "65535", identityFile: key, tags: "x")
        ]
        for draft in variants {
            guard case .process(_, let arguments, _) = try host(draft, keys: [key]).connectionLaunch else { return XCTFail() }
            let options = arguments.prefix(while: { $0 != "--" }).enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
            XCTAssertTrue(Set(options).isSubset(of: ["-p", "-l", "-i"]), "\(arguments)")
            let joined = arguments.joined(separator: " ").lowercased()
            for forbidden in ["-o", "stricthostkeychecking", "userknownhostsfile", "/dev/null", "-t", "batchmode", "-f"] {
                XCTAssertFalse(arguments.contains(forbidden) || (forbidden.count > 2 && joined.contains(forbidden)), "\(forbidden) in \(arguments)")
            }
        }
    }
}
