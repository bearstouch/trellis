#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import Foundation
import XCTest
@testable import TrellisBroker

/// Drives the built `trellis-broker` as ssh would on a remote host (FR-RW03, FR-RW06, FR-RW08, FR-RW13): installed
/// under a temporary `HOME`, `bridge` on a socket pair standing in for ssh's stdio. Runs on macOS and Linux.
final class BrokerBridgeTests: XCTestCase {
    private var home = ""
    private var helper = ""
    private var links: [TestLink] = []
    private let clientID = String(repeating: "5e", count: 16)

    override func setUpWithError() throws {
        signal(SIGPIPE, SIG_IGN)
        let built = try XCTUnwrap(Self.builtHelper(), "Run `swift build` first to build \(BrokerProtocol.helperName).")
        home = try XCTUnwrap(BrokerFiles.realPath(NSTemporaryDirectory())) + "/trellis-home-\(UUID().uuidString.prefix(8))"
        let install = home + "/.trellis/remote/0123456789abcdef"
        try FileManager.default.createDirectory(atPath: install, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(home + "/.trellis", 0o700)
        chmod(home + "/.trellis/remote", 0o700)
        helper = install + "/" + BrokerProtocol.helperName
        try FileManager.default.copyItem(atPath: built, toPath: helper)
    }

    override func tearDown() {
        // Never leave a broker or its sessions behind.
        if let link = try? TestLink(helper: helper, home: home, clientID: clientID), (try? link.hello(clientID: clientID)) != nil { link.stopAll() }
        links.forEach { $0.close() }
        links = []
        try? FileManager.default.removeItem(atPath: home)
    }

    private static func builtHelper() -> String? {
        let candidates = [
            Bundle(for: BrokerBridgeTests.self).bundleURL.deletingLastPathComponent(), Bundle.main.bundleURL,
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        ]
        return candidates.map { $0.appendingPathComponent(BrokerProtocol.helperName).path }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func link() throws -> TestLink {
        let link = try TestLink(helper: helper, home: home, clientID: clientID)
        links.append(link)
        return link
    }

    func testSessionsOutliveTheLinkAndResumeWithoutDuplicates() throws {
        let first = try link()
        guard case .welcome(let version, _, let info?) = try first.hello(clientID: clientID) else { return XCTFail("No v2 welcome") }
        XCTAssertEqual(version, 2)
        XCTAssertEqual(info.home, home)
        XCTAssertTrue(info.executable.hasPrefix(home + "/.trellis/remote/"))

        let id = UUID()
        let spawned = try first.request(
            .spawnLogin(BrokerLoginRequest(sessionID: id, shell: "/bin/sh", directory: home, environment: ["PS1": "$ "], integration: nil, columns: 80, rows: 24)))
        guard case .spawned = spawned else { return XCTFail("\(spawned)") }
        try first.send(input: "echo one-$((1+1))\n", to: id)
        try first.waitForOutput(id) { $0.contains("one-2") }
        let seen = first.received(id)
        // Output the app misses while the link is down.
        try first.send(input: "sleep 1; echo two-$((2+3))\n", to: id)
        try first.waitForOutput(id) { $0.utf8.count > seen }
        let shown = UInt64(first.received(id))
        first.close()
        Thread.sleep(forTimeInterval: 1.5)

        let second = try link()
        _ = try second.hello(clientID: clientID)
        guard case .sessions(let records) = try second.request(.list) else { return XCTFail("No listing") }
        XCTAssertEqual(records.map(\.sessionID), [id])
        XCTAssertEqual(records.first?.running, true, "Quitting or losing the link sends no signal")
        guard case .attached(let attachment) = try second.request(.attach(sessionID: id, columns: 80, rows: 24, since: shown)) else { return XCTFail("Not attached") }
        XCTAssertEqual(attachment.resumed, true)
        let replay = second.replay(id)
        XCTAssertTrue(replay.contains("two-5"), replay)
        XCTAssertFalse(replay.contains("one-2"), "Output already shown is not sent again")
        XCTAssertEqual(attachment.offset, shown + UInt64(replay.utf8.count))
    }

    /// FR-RW18: a v3 login request runs a project's setup command in the login shell instead of an interactive shell.
    func testAV3LoginRequestRunsItsCommandAndAV2ClientCantSendOne() throws {
        let v2 = try link()
        _ = try v2.hello(clientID: clientID)
        let refused = try v2.request(
            .spawnLogin(BrokerLoginRequest(sessionID: UUID(), shell: "/bin/sh", directory: home, environment: [:], integration: nil, columns: 80, rows: 24, command: "true")))
        XCTAssertEqual(refused, .failed(code: "INVALID_REQUEST", errno: EINVAL), "A v2 client never gets a command run in place of a shell")
        XCTAssertEqual(try v2.request(.gitStatus(path: home)), .failed(code: "UNSUPPORTED", errno: 0), "Git status is a v3 request")
        v2.close()

        let v3 = try link()
        guard case .welcome(let version, _, _) = try v3.hello(clientID: clientID, maximumVersion: 3) else { return XCTFail("No welcome") }
        XCTAssertEqual(version, 3)
        // FR-PL09: git status by the helper; a folder outside a work tree has none.
        XCTAssertEqual(try v3.request(.gitStatus(path: home)), .gitState(nil))
        let id = UUID()
        let spawned = try v3.request(
            .spawnLogin(
                BrokerLoginRequest(
                    sessionID: id, shell: "/bin/sh", directory: home, environment: [:], integration: nil, columns: 80, rows: 24,
                    command: "exec /bin/sh -c 'echo setup-$((2+2)) in \"$PWD\"'")))
        guard case .spawned = spawned else { return XCTFail("\(spawned)") }
        try v3.waitForOutput(id) { $0.contains("setup-4 in \(self.home)") }
        // csh and tcsh take -l only alone, so their setup runs in a POSIX login shell: `$((…))` is no csh syntax.
        for shell in ["/bin/csh", "/bin/tcsh"] where FileManager.default.isExecutableFile(atPath: shell) {
            let csh = UUID()
            let reply = try v3.request(
                .spawnLogin(
                    BrokerLoginRequest(
                        sessionID: csh, shell: shell, directory: home, environment: [:], integration: nil, columns: 80, rows: 24, command: "echo posix-$((3+3))")))
            guard case .spawned = reply else { return XCTFail("\(shell): \(reply)") }
            try v3.waitForOutput(csh) { $0.contains("posix-6") }
        }
    }

    func testALateGitStatusNeverReachesTheLinkThatTookOver() throws {
        // A git slow enough for the takeover to happen while it runs.
        try FileManager.default.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
        try "#!/bin/sh\nsleep 0.6\nexit 1\n".write(toFile: home + "/bin/git", atomically: true, encoding: .utf8)
        chmod(home + "/bin/git", 0o755)
        let stale = try TestLink(helper: helper, home: home, clientID: clientID, path: home + "/bin:/usr/bin:/bin")
        links.append(stale)
        _ = try stale.hello(clientID: clientID, maximumVersion: 3)
        try stale.post(.gitStatus(path: home))
        let fresh = try link()
        guard case .welcome = try fresh.hello(clientID: clientID, maximumVersion: 3) else { return XCTFail("No takeover") }
        // The stale request's ID is the next one the fresh link will use.
        XCTAssertEqual(fresh.unsolicited(within: 2.5), [:], "The reply belongs to the link that asked")
    }

    func testANewLinkTakesOverAStaleOne() throws {
        let stale = try link()
        _ = try stale.hello(clientID: clientID)
        let fresh = try link()
        guard case .welcome = try fresh.hello(clientID: clientID) else { return XCTFail("The newest link must be accepted, not BROKER_BUSY") }
        XCTAssertTrue(stale.waitForClose(timeout: 5), "The stale link is dropped")
        guard case .pong(9) = try fresh.request(.ping(9)) else { return XCTFail("No pong") }
    }

    func testAnotherMacsClientIDIsRefusedAndGetsItsOwnBroker() throws {
        let mine = try link()
        guard case .refused(let reason) = try mine.hello(clientID: String(repeating: "ab", count: 16)) else { return XCTFail("Accepted a foreign client ID") }
        XCTAssertEqual(reason, "CLIENT_MISMATCH")
        let other = String(repeating: "cd", count: 16)
        let theirs = try TestLink(helper: helper, home: home, clientID: other)
        defer { theirs.stopAll(); theirs.close() }
        _ = try theirs.hello(clientID: other)
        guard case .sessions(let records) = try theirs.request(.list) else { return XCTFail("No listing") }
        XCTAssertTrue(records.isEmpty)
    }

    func testProjectFilesAreReadThroughTheBridgeOnlyWhenAllowed() throws {
        try FileManager.default.createDirectory(atPath: home + "/app/.trellis", withIntermediateDirectories: true)
        try Data(#"{"version":1}"#.utf8).write(to: URL(fileURLWithPath: home + "/app/.trellis/launch.json"))
        try Data(#"{"version":1}"#.utf8).write(to: URL(fileURLWithPath: home + "/app/.trellis/project.json"))
        let link = try link()
        _ = try link.hello(clientID: clientID)
        XCTAssertEqual(try link.request(.readFile(path: home + "/app/.trellis/launch.json", limit: 1000)), .fileData(Data(#"{"version":1}"#.utf8)))
        // Repository project files were removed (FR-PL01), so the helper no longer reads them.
        XCTAssertEqual(try link.request(.readFile(path: home + "/app/.trellis/project.json", limit: 1000)), .failed(code: "NOT_ALLOWED", errno: 0))
        XCTAssertEqual(try link.request(.readFile(path: home + "/.trellis/run/\(clientID)/broker.json", limit: 1000)), .failed(code: "NOT_ALLOWED", errno: 0))
        guard case .pathInfo(let infos) = try link.request(.stat(paths: [home + "/app/.trellis", home + "/nope"])) else { return XCTFail("No stat") }
        XCTAssertEqual(infos.map(\.kind), [.directory, .missing])
    }

    func testTheBridgeRunsOnlyFromItsOwnerOnlyInstallRoot() throws {
        let built = try XCTUnwrap(Self.builtHelper())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: built)
        process.arguments = ["bridge", "--client-id", clientID, "--sync", String(repeating: "1", count: 32)]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 69)
        XCTAssertTrue(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("must run from"))

        chmod(home + "/.trellis", 0o755)
        defer { chmod(home + "/.trellis", 0o700) }
        XCTAssertThrowsError(try TestLink(helper: helper, home: home, clientID: clientID), "A group-readable ~/.trellis is never used, nor changed")
        XCTAssertEqual((BrokerFiles.entry(home + "/.trellis")?.mode ?? 0) & 0o777, 0o755)
    }
}

/// A blocking client for one `bridge` process over a socket pair; frames for sessions are collected per session.
private final class TestLink {
    enum Failure: Error { case spawn, sync, timedOut, closed }
    let process = Process()
    private var fd: Int32
    private var decoder = BrokerFrameDecoder()
    private var nextID: UInt64 = 1
    private var replies: [UInt64: BrokerMessage] = [:]
    private var output: [UUID: Data] = [:]
    private var replays: [UUID: Data] = [:]
    private var closed = false

    init(helper: String, home: String, clientID: String, path: String = "/usr/bin:/bin") throws {
        var pair: [Int32] = [0, 0]
        #if canImport(Darwin)
            let stream = SOCK_STREAM
        #else
            let stream = Int32(SOCK_STREAM.rawValue)
        #endif
        guard socketpair(AF_UNIX, stream, 0, &pair) == 0 else { throw Failure.spawn }
        _ = BrokerFiles.preventSigPipe(pair[0])
        fd = pair[0]
        let child = FileHandle(fileDescriptor: pair[1], closeOnDealloc: false)
        let token = BrokerFiles.randomHex(16)!
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["bridge", "--client-id", clientID, "--sync", token, "--idle-exit", "5"]
        process.environment = ["HOME": home, "PATH": path, "TMPDIR": "/tmp"]
        process.standardInput = child
        process.standardOutput = child
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { close(); Darwinless.close(pair[1]); throw Failure.spawn }
        Darwinless.close(pair[1])
        // Like the app: discard anything before the sync line.
        let marker = Data(("\n" + BrokerProtocol.syncPrefix + token + "\n").utf8)
        var prefix = Data()
        while prefix.range(of: marker) == nil {
            guard let byte = try readSome(limit: 1, timeout: 10).first else { close(); throw Failure.sync }
            prefix.append(byte)
        }
    }

    func hello(clientID: String, maximumVersion: Int = 2) throws -> BrokerMessage {
        try request(.hello(protocolVersion: 2, features: [BrokerProtocol.inputRejectedFeature], maximumVersion: maximumVersion, clientID: clientID))
    }

    func request(_ message: BrokerMessage) throws -> BrokerMessage {
        let id = nextID
        nextID += 1
        try write(BrokerFrame.control(BrokerEnvelope(requestID: id, message: message)).encoded)
        let deadline = Date().addingTimeInterval(10)
        while replies[id] == nil {
            guard Date() < deadline else { throw Failure.timedOut }
            try pump(timeout: 0.2)
        }
        return replies.removeValue(forKey: id)!
    }

    /// Sends without waiting for the reply.
    func post(_ message: BrokerMessage) throws {
        try write(BrokerFrame.control(BrokerEnvelope(requestID: nextID, message: message)).encoded)
        nextID += 1
    }

    /// Every reply that arrives within `seconds` and no request is waiting for.
    func unsolicited(within seconds: TimeInterval) -> [UInt64: BrokerMessage] {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, (try? pump(timeout: 0.2)) != nil {}
        return replies
    }

    func send(input: String, to session: UUID) throws {
        for frame in BrokerFrame.stream(.input, sessionID: session, bytes: Data(input.utf8)) { try write(frame.encoded) }
    }

    func waitForOutput(_ session: UUID, timeout: TimeInterval = 10, _ condition: (String) -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(String(decoding: output[session] ?? Data(), as: UTF8.self)) {
            guard Date() < deadline else { throw Failure.timedOut }
            try pump(timeout: 0.2)
        }
    }

    func received(_ session: UUID) -> Int { output[session]?.count ?? 0 }
    func replay(_ session: UUID) -> String { String(decoding: replays[session] ?? Data(), as: UTF8.self) }

    func waitForClose(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !closed, Date() < deadline { _ = try? pump(timeout: 0.2) }
        return closed
    }

    func stopAll() { try? write(BrokerFrame(kind: .stopAll, payload: Data()).encoded) }

    func close() {
        guard fd >= 0 else { return }
        Darwinless.close(fd)
        fd = -1
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    private func write(_ data: Data) throws {
        guard fd >= 0, BrokerFiles.writeAll(fd, data) else { throw Failure.closed }
    }

    private func pump(timeout: TimeInterval) throws {
        let data = try readSome(limit: 65_536, timeout: timeout)
        for frame in try decoder.append(data) {
            switch frame.kind {
            case .control:
                guard let envelope = frame.envelope else { continue }
                if let id = envelope.requestID { replies[id] = envelope.message }
            case .output: if let (id, bytes) = frame.stream { output[id, default: Data()].append(bytes) }
            case .replay: if let (id, bytes) = frame.stream { replays[id, default: Data()].append(bytes) }
            default: break
            }
        }
    }

    private func readSome(limit: Int, timeout: TimeInterval) throws -> Data {
        guard fd >= 0 else { throw Failure.closed }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: limit)
        let count = buffer.withUnsafeMutableBytes { Glue.read(fd, $0.baseAddress!, $0.count) }
        if count <= 0 { closed = true; throw Failure.closed }
        return Data(buffer.prefix(count))
    }
}

private enum Darwinless {
    static func close(_ fd: Int32) {
        #if canImport(Darwin)
            _ = Darwin.close(fd)
        #elseif canImport(Glibc)
            _ = Glibc.close(fd)
        #else
            _ = Musl.close(fd)
        #endif
    }
}
