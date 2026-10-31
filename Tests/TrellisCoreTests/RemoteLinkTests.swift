import Foundation
import XCTest

@testable import TrellisCore

/// The bootstrap's text and replies, platform mapping, helper status and the per-host settings file (FR-RW02, FR-RW13, FR-RW17).
final class RemoteLinkTests: XCTestCase {
    private let nonce = String(repeating: "a1", count: 16)
    private let client = String(repeating: "c3", count: 16)

    func testTheCommandSurvivesEveryLoginShell() throws {
        let command = RemoteBootstrap.command(nonce: nonce, clientID: client)
        XCTAssertFalse(command.contains("\n"), "csh can't continue a quoted line")
        XCTAssertFalse(command.contains("!"), "csh and bash history expansion")
        // Inside the single quotes there is only base64, so no login shell sees a quote, `$` or `;` of the script.
        let quoted = try XCTUnwrap(command.split(separator: "'").dropFirst().first)
        let encoded = try XCTUnwrap(quoted.split(separator: " ").first { $0.count > 100 })
        let script = String(decoding: try XCTUnwrap(Data(base64Encoded: String(encoded))), as: UTF8.self)
        XCTAssertEqual(script, RemoteBootstrap.script(nonce: nonce, clientID: client))
        XCTAssertTrue(script.contains("umask 077"))
        XCTAssertFalse(script.contains("sudo"), "Never needs administrator rights")
    }

    /// ssh hands the command to the account's login shell, whatever it is; every shell found here must run it unchanged.
    func testTheCommandRunsUnderEveryLoginShellAndReportsTheProbe() throws {
        let shells = ["/bin/sh", "/bin/zsh", "/bin/bash", "/bin/dash", "/bin/ksh", "/bin/csh", "/bin/tcsh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        XCTAssertTrue(shells.contains("/bin/csh"), "csh is the strictest parser and ships with macOS")
        for shell in shells {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-bootstrap-\(UUID())").path
            defer { try? FileManager.default.removeItem(atPath: home) }
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", RemoteBootstrap.command(nonce: nonce, clientID: client)]
            process.environment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            input.fileHandleForWriting.write(Data(RemoteBootstrap.quitLine.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard case .probe(let probe)? = text.split(separator: "\n").compactMap({ RemoteBootstrap.reply($0, nonce: nonce) }).first else {
                XCTFail("\(shell): \(text)")
                continue
            }
            XCTAssertEqual(probe.platform, "darwin", shell)
            XCTAssertTrue(probe.installed.isEmpty, shell)
            XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.trellis"), "\(shell): a probe writes nothing")
        }
    }

    func testRepliesAreAcceptedOnlyForThisConnection() {
        XCTAssertEqual(
            RemoteBootstrap.reply("TRELLIS-\(nonce) PROBE 1 Linux aarch64 sha256sum 0123456789abcdef nothex!!!!!!!!!!"[...], nonce: nonce),
            .probe(RemoteProbe(system: "Linux", machine: "aarch64", checksumTool: "sha256sum", installed: ["0123456789abcdef"])))
        XCTAssertEqual(
            RemoteBootstrap.reply("TRELLIS-\(nonce) PROBE 1 Linux x86_64 none"[...], nonce: nonce),
            .probe(RemoteProbe(system: "Linux", machine: "x86_64", checksumTool: nil, installed: [])))
        XCTAssertNil(RemoteBootstrap.reply("TRELLIS-\(String(repeating: "f", count: 32)) INSTALLED x"[...], nonce: nonce), "Another nonce, as a login script could print")
        XCTAssertNil(RemoteBootstrap.reply("Welcome to Ubuntu"[...], nonce: nonce))
        XCTAssertEqual(RemoteBootstrap.reply("TRELLIS-\(nonce) ERROR DIGEST"[...], nonce: nonce), .error("DIGEST"))
        XCTAssertEqual(RemoteBootstrap.reply("TRELLIS-\(nonce) REMOVED"[...], nonce: nonce), .removed)
    }

    func testPlatformsMapToBundledHelpers() {
        XCTAssertEqual(RemotePlatform.key(system: "Linux", machine: "x86_64"), "linux-x86_64")
        XCTAssertEqual(RemotePlatform.key(system: "Linux", machine: "arm64"), "linux-aarch64")
        XCTAssertEqual(RemotePlatform.key(system: "Darwin", machine: "x86_64"), "darwin")
        XCTAssertNil(RemotePlatform.key(system: "FreeBSD", machine: "amd64"))
        XCTAssertNil(RemotePlatform.key(system: "Linux", machine: "riscv64"))
        XCTAssertEqual(RemotePlatform.displayName(system: "Darwin", machine: "arm64"), "macOS arm64")
    }

    func testHelperStatusComesFromTheProbe() {
        let artifact = RemoteArtifact(
            platform: "linux-aarch64", path: "/x", digest: String(repeating: "d", count: 64), fileDigest: String(repeating: "e", count: 64), fileSize: 1, compressed: true)
        let catalog = RemoteArtifactCatalog(artifacts: ["linux-aarch64": artifact])
        // The catalog names each install directory after the helper and the scripts together.
        let named = try! XCTUnwrap(catalog.artifacts["linux-aarch64"])
        func state(_ installed: Set<String>, tool: String? = "sha256sum", machine: String = "aarch64") -> RemoteHelperRecord.State {
            RemoteHelperRecord(probe: RemoteProbe(system: "Linux", machine: machine, checksumTool: tool, installed: installed), catalog: catalog, checkedAt: Date()).state
        }
        XCTAssertEqual(state([]), .missing)
        XCTAssertEqual(state([named.directory]), .current)
        XCTAssertEqual(state(["0000000000000000"]), .outdated)
        XCTAssertEqual(state([], tool: nil), .unsupported, "No way to verify an upload there")
        XCTAssertEqual(state([], machine: "x86_64"), .unsupported, "No helper in this build")
        XCTAssertEqual(RemoteBootstrap.installLine(named), "install \(named.directory) \(named.digest) 1 gz\n")
    }

    func testCatalogIgnoresEntriesOutsideItsFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-catalog-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digest = String(repeating: "0", count: 64)
        let manifest = """
            {"helpers":[{"platform":"linux-x86_64","file":"ok.gz","digest":"\(digest)","fileDigest":"\(digest)","fileSize":3,"compressed":true},
            {"platform":"linux-aarch64","file":"../escape","digest":"\(digest)","fileDigest":"\(digest)","fileSize":3,"compressed":true},
            {"platform":"darwin","file":"bad","digest":"short","fileDigest":"\(digest)","fileSize":3,"compressed":false}]}
            """
        try Data(manifest.utf8).write(to: folder.appendingPathComponent(RemoteArtifactCatalog.manifestName))
        let catalog = RemoteArtifactCatalog.load(remoteDirectory: folder, macHelper: nil)
        XCTAssertEqual(Set(catalog.artifacts.keys), ["linux-x86_64"])
        XCTAssertEqual(catalog.artifacts["linux-x86_64"]?.path, folder.appendingPathComponent("ok.gz").path)
        XCTAssertNil(RemoteArtifactCatalog.payload(catalog.artifacts["linux-x86_64"]!), "A missing or changed file is never uploaded")
    }

    func testClientIdentityIsStableAndOwnerOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-client-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try RemoteClientIdentity.load(stateDirectory: folder)
        XCTAssertTrue(RemoteBootstrap.isNonce(first))
        XCTAssertEqual(try RemoteClientIdentity.load(stateDirectory: folder), first)
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(RemoteClientIdentity.fileName).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-client-\(UUID())")
        defer { try? FileManager.default.removeItem(at: other) }
        XCTAssertNotEqual(try RemoteClientIdentity.load(stateDirectory: other), first, "Each state directory is its own client")
    }

    func testAnUnreadableClientIdentityIsNeverReplaced() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-client-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(RemoteClientIdentity.fileName)
        _ = try RemoteClientIdentity.load(stateDirectory: folder)
        let truncated = Data(#"{"clientID":"0123"#.utf8)
        try truncated.write(to: url)
        XCTAssertThrowsError(try RemoteClientIdentity.load(stateDirectory: folder))
        XCTAssertEqual(try Data(contentsOf: url), truncated, "The old ID's sessions stay reachable once the file is repaired")
    }

    func testHostSettingsRoundTripAndForgetDeletedHosts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-remote-hosts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = UUID(), deleted = UUID()
        let record = RemoteHelperRecord(state: .current, system: "Linux", machine: "aarch64", checkedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let settings = RemoteHostSettings(stateDirectory: folder)
        await settings.update(kept) {
            $0.autoInstall = true; $0.helper = record
        }
        await settings.update(deleted) { $0.autoInstall = true }
        let path = folder.appendingPathComponent(RemoteHostSettings.fileName).path
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int, 0o600)
        let reloaded = RemoteHostSettings(stateDirectory: folder)
        let restored = await reloaded.preferences(kept)
        XCTAssertEqual(restored, RemoteHostPreferences(autoInstall: true, helper: record))
        await reloaded.retain([kept])
        let remaining = await RemoteHostSettings(stateDirectory: folder).all()
        XCTAssertEqual(Array(remaining.keys), [kept])
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        let unreadable = await RemoteHostSettings(stateDirectory: folder).all()
        XCTAssertEqual(unreadable, [:], "An unreadable file reads as empty")
    }
}

/// FR-RW07: which automatic failures are retried, and how long between attempts.
final class RemoteReconnectPolicyTests: XCTestCase {
    func testOnlyNetworkFailuresAreRetriedOnTheirOwn() {
        let refused = RemoteSSHDiagnosis.classify(exitCode: 255, output: "ssh: connect to host build-box port 22: Connection refused\r\n")
        XCTAssertEqual(refused, .unreachable("ssh: connect to host build-box port 22: Connection refused"))
        for output in ["ssh: Could not resolve hostname build-box: nodename nor servname provided", "ssh: connect to host 10.0.0.2 port 22: Operation timed out"] {
            guard case .unreachable = RemoteSSHDiagnosis.classify(exitCode: 255, output: output) else { return XCTFail(output) }
        }
        for output in [
            "dev@build-box: Permission denied (publickey,password).", "Host key verification failed.",
            "@@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@@\r\nHost key verification failed.",
            "Received disconnect: Too many authentication failures\r\nConnection closed by 10.0.0.2 port 22"
        ] {
            guard case .needsInput = RemoteSSHDiagnosis.classify(exitCode: 255, output: output) else { return XCTFail("Retried a credential: \(output)") }
        }
        guard case .needsInput = RemoteSSHDiagnosis.classify(exitCode: 255, output: "") else { return XCTFail("An unexplained ssh failure must ask, not loop") }
    }

    func testBackoffGrowsToAMinuteWithJitter() {
        XCTAssertEqual((1...8).map { RemoteBackoff.delay(attempt: $0, random: 0.5) }, [1, 2, 4, 8, 16, 32, 60, 60])
        XCTAssertEqual(RemoteBackoff.delay(attempt: 1, random: 0), 0.8, accuracy: 0.0001)
        XCTAssertEqual(RemoteBackoff.delay(attempt: 3, random: 1), 4.8, accuracy: 0.0001)
        XCTAssertEqual(RemoteBackoff.delay(attempt: 30, random: 1), 60, "Never above a minute")
    }
}
