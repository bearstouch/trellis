import Darwin
import XCTest
@testable import TrellisControl

final class ControlEndpointTests: XCTestCase {
    private var root: URL!
    private var state: URL!
    private var runtime: URL!

    override func setUpWithError() throws {
        // Short names keep the socket path well under the 104-byte sun_path limit.
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        state = root.appendingPathComponent("state", isDirectory: true)
        runtime = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        XCTAssertEqual(mkdir(runtime.path, 0o700), 0)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        return info.st_mode & 0o777
    }

    func testS021_UT03_rejectUnsafeEndpoint() async throws {
        let uid = geteuid()
        let server = ControlServer(endpoint: ControlEndpoint(stateDirectory: state, runtimeRoot: runtime), handler: CountingHandler())
        let discovery = try server.start()
        defer { server.stop() }
        XCTAssertNoThrow(try ControlEndpoint.verifySocket(discovery.socketPath, uid: uid))

        // A symlink to a real socket is refused.
        let link = runtime.appendingPathComponent("link").path
        XCTAssertEqual(symlink(discovery.socketPath, link), 0)
        XCTAssertThrowsError(try ControlEndpoint.verifySocket(link, uid: uid)) { XCTAssertEqual($0 as? ControlEndpointError, .unsafeSocket) }
        // An endpoint owned by another user is refused.
        XCTAssertThrowsError(try ControlEndpoint.verifySocket(discovery.socketPath, uid: uid &+ 1)) {
            XCTAssertEqual($0 as? ControlEndpointError, .unsafeSocket)
        }
        // A regular file posing as the socket, and a group-readable directory, are refused.
        let plain = runtime.appendingPathComponent("plain").path
        FileManager.default.createFile(atPath: plain, contents: Data())
        XCTAssertThrowsError(try ControlEndpoint.verifySocket(plain, uid: uid))
        let open = root.appendingPathComponent("open").path
        XCTAssertEqual(mkdir(open, 0o755), 0)
        XCTAssertThrowsError(try ControlEndpoint.verifyOwnerOnlyDirectory(open, uid: uid)) {
            XCTAssertEqual($0 as? ControlEndpointError, .unsafeDirectory)
        }
        // A stale discovery pointing at a symlink never causes its target to be removed.
        let victim = root.appendingPathComponent("victim").path
        FileManager.default.createFile(atPath: victim, contents: Data("keep".utf8))
        let other = ControlEndpoint(stateDirectory: root.appendingPathComponent("state2"), runtimeRoot: runtime)
        try other.publish(ControlDiscovery(protocolVersion: 1, instanceID: UUID(), socketPath: link))
        _ = try other.prepare()
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), discovery.socketPath)
    }

    func testS021_UT04_discoveryContainsNoSecret() throws {
        let endpoint = ControlEndpoint(stateDirectory: state, runtimeRoot: runtime)
        let server = ControlServer(endpoint: endpoint, handler: CountingHandler())
        let discovery = try server.start()
        defer { server.stop() }
        let data = try Data(contentsOf: endpoint.discoveryURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["protocolVersion", "instanceID", "socketPath"])
        XCTAssertEqual(object["protocolVersion"] as? Int, 1)
        XCTAssertEqual(object["socketPath"] as? String, discovery.socketPath)
        for forbidden in ["token", "secret", "password", "letmein"] { XCTAssertFalse(String(decoding: data, as: UTF8.self).lowercased().contains(forbidden)) }
        XCTAssertEqual(mode(endpoint.discoveryURL.path), 0o600)
        XCTAssertEqual(mode(discovery.socketPath), 0o600)
        XCTAssertEqual(mode((discovery.socketPath as NSString).deletingLastPathComponent), 0o700)
        XCTAssertLessThanOrEqual(discovery.socketPath.utf8.count, ControlEndpoint.socketPathLimit)
    }

    func testRealSocketRoundTripGateAndFramingClose() throws {
        let handler = CountingHandler()
        let server = ControlServer(endpoint: ControlEndpoint(stateDirectory: state, runtimeRoot: runtime), handler: handler)
        let discovery = try server.start()
        defer { server.stop() }
        let client = try SocketClient(path: discovery.socketPath)
        defer { client.close() }
        let unauth = try client.request(#"{"jsonrpc":"2.0","id":1,"method":"window.list"}"#)
        XCTAssertEqual(appCode(unauth), "UNAUTHENTICATED")
        _ = try client.request(#"{"jsonrpc":"2.0","id":2,"method":"auth.authenticate","params":{"token":"letmein"}}"#)
        let listed = try client.request(#"{"jsonrpc":"2.0","id":3,"method":"window.list"}"#)
        XCTAssertEqual((listed["result"] as? [String: Any])?["method"] as? String, "window.list")
        XCTAssertEqual(handler.dispatches, ["window.list"])

        // An over-limit frame gets a best-effort error, then the server closes.
        let flood = try SocketClient(path: discovery.socketPath)
        defer { flood.close() }
        flood.send(Data(repeating: 0x61, count: ControlFramer.maximumFrame + 10))
        let reply = flood.readUntilClosed()
        XCTAssertTrue(String(decoding: reply, as: UTF8.self).contains("FRAME_TOO_LARGE"))
    }

    func testStaleInstanceIsReplacedOnlyWhenGone() throws {
        let endpoint = ControlEndpoint(stateDirectory: state, runtimeRoot: runtime)
        let first = ControlServer(endpoint: endpoint, handler: CountingHandler())
        let live = try first.start()
        let second = ControlServer(endpoint: endpoint, handler: CountingHandler())
        XCTAssertThrowsError(try second.start()) { XCTAssertEqual($0 as? ControlEndpointError, .anotherInstanceRunning) }
        XCTAssertEqual(endpoint.readDiscovery(), live, "A live instance's discovery is untouched")

        // Simulate a crash: the socket file and discovery remain, nothing listens.
        let crashedDirectory = (live.socketPath as NSString).deletingLastPathComponent
        first.stopListeningForTesting()
        let replacement = try second.start()
        defer { second.stop() }
        XCTAssertNotEqual(replacement.instanceID, live.instanceID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashedDirectory), "The stale runtime directory was removed")
        XCTAssertEqual(endpoint.readDiscovery(), replacement)
        second.stop()
        XCTAssertNil(endpoint.readDiscovery(), "Stop removes only its own discovery")
    }
}

extension ControlServer {
    /// Closes the listener but leaves files behind, as a crashed instance would.
    func stopListeningForTesting() { closeListenerOnly() }
}

/// Minimal blocking AF_UNIX client for integration tests.
final class SocketClient {
    private let fd: Int32
    private var pending = Data()

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try XCTUnwrap(ControlEndpoint.unixAddress(path))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    func send(_ data: Data) {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            guard written > 0 else { return }
            offset += written
        }
    }

    func request(_ line: String) throws -> [String: Any] {
        send(Data((line + "\n").utf8))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !pending.contains(0x0A) {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { throw POSIXError(.ECONNRESET) }
            pending.append(contentsOf: buffer.prefix(count))
        }
        let newline = pending.firstIndex(of: 0x0A)!
        let frame = pending[pending.startIndex..<newline]
        pending.removeSubrange(pending.startIndex...newline)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame)) as? [String: Any])
    }

    func readUntilClosed() -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    func close() { Darwin.close(fd) }
}
