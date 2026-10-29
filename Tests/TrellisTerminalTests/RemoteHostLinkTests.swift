import Darwin
import Foundation
import TrellisBroker
import TrellisCore
import XCTest

@testable import TrellisTerminal

/// The link end to end on this Mac (FR-RW02, FR-RW03, FR-RW17): a fake `ssh` runs the bootstrap locally under a temporary
/// `HOME`, so the real script, upload, digest check, bridge and broker all run; only the network is missing.
@MainActor
final class RemoteHostLinkTests: XCTestCase {
    private var root = ""
    private var home = ""
    private var fakeSSH = ""
    private var helper = ""
    private var links: [RemoteHostLink] = []
    private let clientID = RemoteClientIdentity.randomHex()

    override func setUp() async throws {
        let built = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(BrokerProtocol.helperName).path
        guard FileManager.default.isExecutableFile(atPath: built) else { throw XCTSkip("Run `swift build` first to build \(BrokerProtocol.helperName).") }
        helper = built
        root = try XCTUnwrap(BrokerFiles.realPath(NSTemporaryDirectory())) + "/trellis-link-\(UUID().uuidString.prefix(8))"
        home = root + "/home dir"  // a remote HOME with a space: every bootstrap path is quoted
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        fakeSSH = root + "/ssh"
        try """
        #!/bin/sh
        while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
        shift; shift
        [ -n "$FAKE_SSH_STDERR" ] && printf '%s\\n' "$FAKE_SSH_STDERR" >&2
        [ -n "$FAKE_SSH_EXIT" ] && exit "$FAKE_SSH_EXIT"
        export HOME="$FAKE_SSH_HOME"
        echo "Welcome to the test host"
        exec /bin/sh -c "$1"
        """.write(toFile: fakeSSH, atomically: true, encoding: .utf8)
        chmod(fakeSSH, 0o755)
    }

    override func tearDown() async throws {
        // Stop any broker the bridge started, then forget the temporary host.
        let link = makeLink()
        if case .success = await link.run(.bridge, install: .never) { link.connection?.sendStopAll() }
        try? await Task.sleep(for: .milliseconds(200))
        links.forEach { $0.close() }
        links = []
        try? FileManager.default.removeItem(atPath: root)
    }

    private func makeLink(_ environment: [String: String] = [:], catalog: RemoteArtifactCatalog? = nil) -> RemoteHostLink {
        let request = RemoteHostLink.Request(
            sshExecutable: fakeSSH, options: ["-p", "2222"], destination: "test-host",
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "FAKE_SSH_HOME": home].merging(environment) { $1 }, clientID: clientID)
        let link = RemoteHostLink(request: request, catalog: catalog ?? RemoteArtifactCatalog.load(remoteDirectory: nil, macHelper: helper))
        links.append(link)
        return link
    }

    private var installRoot: String { home + "/.trellis/remote" }

    func testCheckInstallBridgeAndRemove() async throws {
        let catalog = RemoteArtifactCatalog.load(remoteDirectory: nil, macHelper: helper)
        let artifact = try XCTUnwrap(catalog.artifacts["darwin"])

        let check = try await makeLink().run(.check, install: .never).get()
        XCTAssertEqual(check.system, "Darwin")
        XCTAssertNotNil(check.checksumTool)
        XCTAssertEqual(RemoteHelperRecord(probe: check, catalog: catalog, checkedAt: Date()).state, .missing)

        let declining = makeLink()
        var asked: (RemoteProbe, RemoteArtifact)?
        declining.confirmInstall = {
            asked = ($0, $1); return false
        }
        let declined = await declining.run(.bridge, install: .ask)
        XCTAssertEqual(declined, .failure(.declined))
        XCTAssertEqual(asked?.1.digest, artifact.digest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installRoot), "Declining writes nothing on the host")

        let link = makeLink()
        link.confirmInstall = { _, _ in true }
        let probe = try await link.run(.bridge, install: .ask).get()
        XCTAssertEqual(link.state, .connected)
        XCTAssertTrue(probe.installed.contains(artifact.directory))
        let installed = installRoot + "/" + artifact.directory + "/trellis-broker"
        XCTAssertEqual(BrokerFiles.entry(installed).map { $0.mode & 0o777 }, 0o700)
        XCTAssertEqual(BrokerFiles.entry(home + "/.trellis").map { $0.mode & 0o777 }, 0o700)
        XCTAssertEqual(RemoteArtifactCatalog.sha256(file: installed), artifact.digest)
        // FR-RW05: the shell integration scripts are installed beside the helper, each checked on the host.
        XCTAssertFalse(catalog.integration.isEmpty)
        for file in catalog.integration {
            XCTAssertEqual(FileManager.default.contents(atPath: installRoot + "/" + artifact.directory + "/integration/" + file.path), file.data, file.path)
        }
        let connection = try XCTUnwrap(link.connection)
        XCTAssertEqual(connection.protocolVersion, 2)
        XCTAssertEqual(connection.hostInfo?.home, home)
        guard case .pong(4) = try await connection.request(.ping(4)) else { return XCTFail("No pong through the link") }
        XCTAssertFalse(link.console.screenText.contains("Welcome"), "Login-script output never reaches the protocol or the console")

        let again = try await makeLink().run(.check, install: .never).get()
        XCTAssertEqual(RemoteHelperRecord(probe: again, catalog: catalog, checkedAt: Date()).state, .current)

        connection.sendStopAll()
        link.close()
        XCTAssertEqual(link.state, .closed)
        try await Task.sleep(for: .milliseconds(300))
        _ = try await makeLink().run(.remove, install: .never).get()
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.trellis"), "Remove deletes only Trellis's folders, and an empty ~/.trellis")
    }

    func testAHelperThatDoesNotMatchItsDigestIsNeverInstalled() async throws {
        // The file is intact here, but its recorded helper digest is wrong: the host's own check must refuse it.
        let real = try XCTUnwrap(RemoteArtifactCatalog.load(remoteDirectory: nil, macHelper: helper).artifacts["darwin"])
        var forged = real
        forged.digest = String(repeating: "ab", count: 32)
        let link = makeLink(catalog: RemoteArtifactCatalog(artifacts: ["darwin": forged]))
        let refused = await link.run(.install, install: .always)
        XCTAssertEqual(refused, .failure(.remote("DIGEST")))
        let directory = installRoot + "/" + forged.directory
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [], [], "No helper and no partial upload is left")
    }

    func testABundledFileThatChangedIsNotUploaded() async throws {
        var changed = try XCTUnwrap(RemoteArtifactCatalog.load(remoteDirectory: nil, macHelper: helper).artifacts["darwin"])
        changed.fileDigest = String(repeating: "cd", count: 32)
        let link = makeLink(catalog: RemoteArtifactCatalog(artifacts: ["darwin": changed]))
        guard case .failure(.artifactUnavailable) = await link.run(.install, install: .always) else { return XCTFail("Uploaded a changed file") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: installRoot))
    }

    func testSSHMessagesAppearInTheConsoleAndAFailedConnectionReportsItsExit() async throws {
        let link = makeLink(["FAKE_SSH_STDERR": "dev@test-host: Permission denied (publickey).", "FAKE_SSH_EXIT": "255"])
        var shown = false
        link.onConsoleOutput = { shown = true }
        let result = await link.run(.bridge, install: .never)
        guard case .failure(.exited) = result else { return XCTFail("\(result)") }
        let deadline = Date().addingTimeInterval(3)
        while !link.console.screenText.contains("Permission denied"), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(shown)
        XCTAssertTrue(link.console.screenText.contains("Permission denied"))
    }

    func testABootstrapErrorBeforeTheBridgeIsReportedNotTakenForTheSync() async throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { Darwin.close(pair[1]) }
        let nonce = RemoteClientIdentity.randomHex()
        let channel = LinkChannel(fd: pair[0], nonce: nonce)
        // Login noise, a forged error for another connection, then this connection's own error: longer than the sync marker.
        let text = "motd line\nTRELLIS-\(RemoteClientIdentity.randomHex()) ERROR FORGED\nTRELLIS-\(nonce) ERROR MISSING\n"
        XCTAssertTrue(BrokerFiles.writeAll(pair[1], Data(text.utf8)))
        let synced = await channel.awaitSync()
        XCTAssertFalse(synced)
        XCTAssertEqual(channel.lastError, "MISSING")
    }

    func testCancellingAChannelWakesABlockedReadAndHandsOverNothing() async throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { Darwin.close(pair[1]) }
        let channel = LinkChannel(fd: pair[0], nonce: RemoteClientIdentity.randomHex())
        let pending = Task { await channel.reply() }
        try await Task.sleep(for: .milliseconds(100))
        channel.cancel()
        let reply = await pending.value
        XCTAssertNil(reply)
        XCTAssertEqual(channel.takeDescriptor(), -1, "A cancelled channel never hands its socket to a connection")
    }

    func testTheArgumentsKeepOptionsBeforeTheDestination() {
        let link = makeLink()
        let arguments = link.arguments
        XCTAssertEqual(Array(arguments.prefix(6)), [fakeSSH, "-T", "-e", "none", "-p", "2222"])
        XCTAssertEqual(arguments[arguments.count - 3], "--")
        XCTAssertEqual(arguments[arguments.count - 2], "test-host")
        XCTAssertFalse(arguments.contains { $0.contains("StrictHostKeyChecking") }, "No host-trust bypass")
    }
}
