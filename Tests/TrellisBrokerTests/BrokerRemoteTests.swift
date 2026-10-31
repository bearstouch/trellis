#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import Foundation
import TrellisPOSIX
import XCTest
@testable import TrellisBroker

/// Protocol v2 and the remote broker's pure rules (FR-RW08, FR-RW12–FR-RW14). Runs on macOS and Linux.
final class BrokerRemoteTests: XCTestCase {
    func testNegotiationPicksTheHighestCommonVersion() {
        XCTAssertEqual(BrokerCore.negotiate(1, maximumVersion: nil), 1, "A v1 app")
        XCTAssertEqual(BrokerCore.negotiate(1, maximumVersion: 2), 2, "An app that speaks both")
        XCTAssertEqual(BrokerCore.negotiate(1, maximumVersion: 9), BrokerProtocol.version, "A newer app that still speaks this version")
        XCTAssertEqual(BrokerCore.negotiate(2, maximumVersion: 2), 2, "A remote link, which requires v2")
        XCTAssertNil(BrokerCore.negotiate(BrokerProtocol.version + 1, maximumVersion: nil), "Only newer versions")
        XCTAssertNil(BrokerCore.negotiate(0, maximumVersion: 0), "Below the minimum")
        XCTAssertEqual(BrokerCore.hello(1, maximumVersion: 2, brokerPID: 7), .welcome(protocolVersion: 2, brokerPID: 7))
        let info = BrokerHostInfo(os: "linux", arch: "aarch64", user: "u", home: "/home/u", shell: "/bin/bash", machineID: "m", executable: "/x", sessionsEndAtLogout: false)
        XCTAssertEqual(BrokerCore.hello(1, brokerPID: 7, info: info), .welcome(protocolVersion: 1, brokerPID: 7), "A v1 welcome never carries v2 fields")
    }

    func testAnUpdatedAppStillGreetsAVersionOneBroker() throws {
        // What `BrokerConnection.hello()` sends by default: a v1 broker reads only `protocolVersion` and accepts it.
        let hello = BrokerEnvelope(requestID: 1, message: .hello(protocolVersion: BrokerProtocol.minimumVersion, features: ["inputRejected"], maximumVersion: 2))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(hello)) as? [String: Any]
        let fields = (json?["message"] as? [String: Any])?["hello"] as? [String: Any]
        XCTAssertEqual(fields?["protocolVersion"] as? Int, 1)
        // And a v1 broker's answers decode here.
        let welcome = try JSONDecoder().decode(BrokerEnvelope.self, from: Data(#"{"requestID":1,"message":{"welcome":{"protocolVersion":1,"brokerPID":9}}}"#.utf8))
        XCTAssertEqual(welcome.message, .welcome(protocolVersion: 1, brokerPID: 9, info: nil))
        let attached = try JSONDecoder().decode(
            BrokerAttachment.self,
            from: Data(#"{"record":{"sessionID":"\#(UUID().uuidString)","processID":3,"running":true},"passwordPrompt":false,"truncated":false}"#.utf8))
        XCTAssertNil(attached.offset)
        XCTAssertNil(attached.resumed)
    }

    func testVersionTwoMessagesRoundTrip() throws {
        let id = UUID()
        let messages: [BrokerMessage] = [
            .hello(protocolVersion: 2, features: [], maximumVersion: 2, clientID: String(repeating: "a", count: 32)),
            .spawnLogin(
                BrokerLoginRequest(
                    sessionID: id, shell: "/bin/zsh", directory: "/srv", environment: ["TERM": "xterm-256color"],
                    integration: BrokerIntegration(shell: "/bin/zsh", arguments: ["-l"], environment: ["ZDOTDIR": "/x"], scriptPath: "/x/.zshenv"), columns: 80, rows: 24)),
            .attach(sessionID: id, columns: 80, rows: 24, since: 12), .ping(5), .pong(5), .stat(paths: ["/a"]),
            .pathInfo([BrokerPathInfo(path: "/a", kind: .directory, owned: true, size: 0, realPath: "/a")]), .readFile(path: "/a/.trellis/launch.json", limit: 10),
            .fileData(Data([0, 1, 2]))
        ]
        for message in messages {
            let frame = try BrokerFrame.control(BrokerEnvelope(requestID: 3, message: message))
            XCTAssertEqual(frame.envelope?.message, message)
        }
    }

    func testResumeSendsExactlyTheMissedOutputWhileTheRingHoldsIt() {
        var ring = OutputRing(limit: 64)
        ring.append(Data("one\n".utf8))
        ring.append(Data("two\n".utf8))
        XCTAssertEqual(ring.appendedTotal, 8)
        XCTAssertEqual(ring.replay(since: 4).data, Data("two\n".utf8))
        XCTAssertEqual(ring.replay(since: 4).resumed, true)
        XCTAssertEqual(ring.replay(since: 8).data, Data(), "Nothing missed")
        XCTAssertEqual(ring.replay(since: 8).resumed, true)
        XCTAssertEqual(ring.replay(since: 9).resumed, false, "A position past the end is never trusted")
        XCTAssertEqual(ring.replay(since: nil).data, ring.replay)
        // Once the missed output was evicted, the client gets the reset replay instead of a gap.
        ring.append(Data(repeating: UInt8(ascii: "x"), count: 100))
        XCTAssertEqual(ring.appendedTotal, 108)
        let stale = ring.replay(since: 4)
        XCTAssertFalse(stale.resumed)
        XCTAssertEqual(stale.data, ring.replay)
        XCTAssertTrue(ring.replay(since: 100).resumed)
    }

    func testOnlyAllowListedProjectAndTaskFilesAreReadable() {
        for path in ["/srv/app/.trellis/launch.json", "/srv/app/package.json", "/srv/app/Makefile", "/srv/app/Cargo.toml"] {
            XCTAssertTrue(BrokerRemoteFiles.isAllowed(path), path)
        }
        for path in [
            "/home/u/.ssh/id_ed25519", "/srv/app/.trellis/secret.json", "/srv/app/.trellis/project.json", "/srv/app/.trellis/workspace.json", "/srv/app/launch.json", "relative/.trellis/launch.json",
            "/srv/../etc/.trellis/launch.json",
            "/srv/./app/package.json", "/srv//app/package.json", "/package.json", "/srv/app/.env"
        ] {
            XCTAssertFalse(BrokerRemoteFiles.isAllowed(path), path)
        }
    }

    func testRemoteReadsRefuseSymlinksForeignAndOversizedFiles() throws {
        let root = try temporaryDirectory()
        let project = root + "/app"
        try FileManager.default.createDirectory(atPath: project + "/.trellis", withIntermediateDirectories: true)
        try Data(#"{"version":1}"#.utf8).write(to: URL(fileURLWithPath: project + "/.trellis/launch.json"))
        XCTAssertEqual(try BrokerRemoteFiles.read(project + "/.trellis/launch.json", limit: 1000).get(), Data(#"{"version":1}"#.utf8))
        XCTAssertEqual(failure(BrokerRemoteFiles.read(project + "/.trellis/launch.json", limit: 3)), .tooLarge)
        XCTAssertEqual(failure(BrokerRemoteFiles.read(project + "/Makefile", limit: 1000)), .notFound)
        XCTAssertEqual(failure(BrokerRemoteFiles.read(project + "/.trellis/launch.json", limit: 1000, uid: geteuid() + 1)), .notAllowed, "Another user's file")

        // A symlinked file, and a symlinked .trellis folder, are refused even when they point at an allowed file.
        try FileManager.default.createSymbolicLink(atPath: project + "/package.json", withDestinationPath: project + "/.trellis/launch.json")
        XCTAssertEqual(failure(BrokerRemoteFiles.read(project + "/package.json", limit: 1000)), .notAllowed)
        let other = root + "/other"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: other + "/.trellis", withDestinationPath: project + "/.trellis")
        XCTAssertEqual(failure(BrokerRemoteFiles.read(other + "/.trellis/launch.json", limit: 1000)), .notAllowed)
        XCTAssertEqual(failure(BrokerRemoteFiles.read(root + "/.ssh/config", limit: 1000)), .notAllowed)
    }

    func testStatDescribesEntriesWithoutFollowingThem() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: root)
        let infos = try XCTUnwrap(BrokerRemoteFiles.describe([root, root + "/link", root + "/missing"]))
        XCTAssertEqual(infos.map(\.kind), [.directory, .symlink, .missing])
        XCTAssertEqual(infos[0].owned, true)
        XCTAssertEqual(infos[1].realPath, BrokerFiles.realPath(root))
        XCTAssertNil(BrokerRemoteFiles.describe(["relative"]))
        XCTAssertNil(BrokerRemoteFiles.describe(Array(repeating: "/", count: BrokerProtocol.statLimit + 1)))
    }

    func testLogindPolicyIsDetectedAndLingeringOverridesIt() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(atPath: root + "/etc/systemd/logind.conf.d", withIntermediateDirectories: true)
        XCTAssertFalse(BrokerHost.killsUserProcesses(user: "u", root: root), "No configuration")
        try Data("[Login]\n#KillUserProcesses=yes\n".utf8).write(to: URL(fileURLWithPath: root + "/etc/systemd/logind.conf"))
        XCTAssertFalse(BrokerHost.killsUserProcesses(user: "u", root: root), "Commented out")
        try Data("[Login]\nKillUserProcesses = no\nKillUserProcesses=yes\n".utf8).write(to: URL(fileURLWithPath: root + "/etc/systemd/logind.conf"))
        XCTAssertTrue(BrokerHost.killsUserProcesses(user: "u", root: root))
        try Data("[Login]\nKillUserProcesses=no\n".utf8).write(to: URL(fileURLWithPath: root + "/etc/systemd/logind.conf.d/50-keep.conf"))
        XCTAssertFalse(BrokerHost.killsUserProcesses(user: "u", root: root), "A drop-in wins")
        try Data("[Login]\nKillUserProcesses=yes\n".utf8).write(to: URL(fileURLWithPath: root + "/etc/systemd/logind.conf.d/50-keep.conf"))
        try FileManager.default.createDirectory(atPath: root + "/var/lib/systemd/linger", withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: root + "/var/lib/systemd/linger/u"))
        XCTAssertFalse(BrokerHost.killsUserProcesses(user: "u", root: root), "Lingering keeps the user's processes")
    }

    func testPathHelpersNeedNoFoundationPathAPIs() {
        XCTAssertEqual(BrokerFiles.parent("/a/b/c"), "/a/b")
        XCTAssertEqual(BrokerFiles.parent("/a/b/"), "/a")
        XCTAssertEqual(BrokerFiles.parent("/a"), "/")
        XCTAssertEqual(BrokerFiles.lastComponent("/a/b.json"), "b.json")
        XCTAssertEqual(BrokerFiles.hex([0, 15, 255]), "000fff")
        XCTAssertEqual(BrokerFiles.randomHex(6)?.count, 12)
        XCTAssertTrue(BrokerBridge.isValidClientID(String(repeating: "0a", count: 16)))
        XCTAssertFalse(BrokerBridge.isValidClientID(String(repeating: "0A", count: 16)))
        XCTAssertFalse(BrokerBridge.isValidClientID("../../etc"))
    }

    func testHostInfoDescribesThisMachine() {
        let info = BrokerHost.info()
        #if os(Linux)
            XCTAssertEqual(info.os, "linux")
        #else
            XCTAssertEqual(info.os, "darwin")
        #endif
        XCTAssertFalse(info.arch.isEmpty)
        XCTAssertTrue(info.home.hasPrefix("/"))
        XCTAssertTrue(BrokerHost.isExecutableFile(info.shell))
    }

    func testSpawnedShellsInheritNoOtherDescriptors() throws {
        // A descriptor without close-on-exec, as a library might leave one; on Linux the child closes it with close_range.
        let leaked = dup2(STDERR_FILENO, 211)
        XCTAssertEqual(leaked, 211)
        defer { Glue.close(leaked) }
        let words: [String] = ["/bin/sh", "-c", "ls /dev/fd/", "PATH=/usr/bin:/bin"]
        let argv = words.prefix(3).map { strdup($0) } + [nil]
        let envp = [strdup(words[3])] + [nil]
        defer { (argv + envp).forEach { free($0) } }
        let result = trellis_spawn_pty("/bin/sh", argv, envp, "/", 80, 24)
        XCTAssertEqual(result.error_code, 0)
        defer { Glue.close(result.master_fd); var status: Int32 = 0; waitpid(result.pid, &status, 0) }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var descriptor = pollfd(fd: result.master_fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 200) >= 0 else { break }
            guard descriptor.revents != 0 else { continue }
            let count = buffer.withUnsafeMutableBytes { Glue.read(result.master_fd, $0.baseAddress!, $0.count) }
            if count <= 0 { break }
            output.append(contentsOf: buffer.prefix(count))
        }
        let listed = String(decoding: output, as: UTF8.self).split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
        XCTAssertTrue(listed.contains(0), "Listing: \(listed)")
        XCTAssertFalse(listed.contains(211), "Listing: \(listed)")
    }

    private func failure(_ result: Result<Data, BrokerRemoteFiles.Failure>) -> BrokerRemoteFiles.Failure? {
        if case .failure(let failure) = result { failure } else { nil }
    }

    private func temporaryDirectory() throws -> String {
        let path = try XCTUnwrap(BrokerFiles.realPath(NSTemporaryDirectory())) + "/trellis-remote-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }
}
