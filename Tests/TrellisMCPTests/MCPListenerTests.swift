import Darwin
import XCTest
import TrellisControl
import TrellisCore
@testable import TrellisMCP

/// Minimal blocking TCP client for loopback tests.
final class TCPClient: @unchecked Sendable {
    let fd: Int32

    init?(port: UInt16, address: String = "127.0.0.1") {
        fd = socket(address.contains(":") ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let connected: Int32
        if address.contains(":") {
            var sin6 = sockaddr_in6()
            sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); sin6.sin6_family = sa_family_t(AF_INET6); sin6.sin6_port = port.bigEndian
            inet_pton(AF_INET6, address, &sin6.sin6_addr)
            connected = withUnsafePointer(to: &sin6) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); sin.sin_family = sa_family_t(AF_INET); sin.sin_port = port.bigEndian
            inet_pton(AF_INET, address, &sin.sin_addr)
            connected = withUnsafePointer(to: &sin) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard connected == 0 else { close(fd); return nil }
    }

    deinit { close(fd) }

    func send(_ text: String) { _ = text.withCString { write(fd, $0, strlen($0)) } }

    /// Reads one response (headers plus Content-Length body), or nil on EOF/timeout.
    func response() -> (status: Int, headers: [String: String], body: String)? {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if let end = data.firstRange(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in head.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                if data.distance(from: end.upperBound, to: data.endIndex) >= length {
                    let status = Int(head[0].split(separator: " ")[1]) ?? 0
                    return (status, headers, String(decoding: data[end.upperBound..<data.index(end.upperBound, offsetBy: length)], as: UTF8.self))
                }
            }
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    /// True once the server has closed the connection.
    func isClosed() -> Bool {
        var byte: UInt8 = 0
        return read(fd, &byte, 1) == 0
    }
}

final class MCPListenerTests: XCTestCase {
    private func echoListener() throws -> (MCPListener, UInt16) {
        let listener = MCPListener { request in .json(200, Data(#"{"path":"\#(request.path)","bytes":\#(request.body.count)}"#.utf8)) }
        let port = try listener.start(address: "127.0.0.1", port: 0)
        return (listener, port)
    }

    func testRoundTripAndKeepAlive() throws {
        let (listener, port) = try echoListener()
        defer { listener.stop() }
        let client = try XCTUnwrap(TCPClient(port: port))
        client.send("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc")
        let first = try XCTUnwrap(client.response())
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(first.body, #"{"path":"/mcp","bytes":3}"#)
        client.send("GET /second HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertEqual(client.response()?.body, #"{"path":"/second","bytes":0}"#, "The connection stays open for the next request")
    }

    func testConnectionCloseIsHonored() throws {
        let (listener, port) = try echoListener()
        defer { listener.stop() }
        let client = try XCTUnwrap(TCPClient(port: port))
        client.send("GET / HTTP/1.1\r\nConnection: close\r\n\r\n")
        XCTAssertEqual(client.response()?.headers["connection"], "close")
        XCTAssertTrue(client.isClosed())
    }

    func testMalformedRequestGetsAnErrorAndIsClosed() throws {
        let (listener, port) = try echoListener()
        defer { listener.stop() }
        let client = try XCTUnwrap(TCPClient(port: port))
        client.send("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
        XCTAssertEqual(client.response()?.status, 411)
        XCTAssertTrue(client.isClosed())
    }

    func testPortInUseIsReported() throws {
        let (listener, port) = try echoListener()
        defer { listener.stop() }
        XCTAssertThrowsError(try MCPListener { _ in .empty(200) }.start(address: "127.0.0.1", port: port)) {
            XCTAssertEqual($0 as? MCPListenerError, .addressInUse)
        }
    }

    func testUnavailableAddressIsReported() {
        XCTAssertThrowsError(try MCPListener { _ in .empty(200) }.start(address: "203.0.113.7", port: 0)) {
            XCTAssertEqual($0 as? MCPListenerError, .addressUnavailable)
        }
        XCTAssertThrowsError(try MCPListener { _ in .empty(200) }.start(address: "localhost", port: 0)) {
            XCTAssertEqual($0 as? MCPListenerError, .invalidAddress)
        }
    }

    func testStopClosesListenerAndConnections() throws {
        let (listener, port) = try echoListener()
        let client = try XCTUnwrap(TCPClient(port: port))
        client.send("GET / HTTP/1.1\r\n\r\n")
        XCTAssertNotNil(client.response())
        listener.stop()
        XCTAssertFalse(listener.isRunning)
        XCTAssertTrue(client.isClosed())
        XCTAssertNil(TCPClient(port: port), "Nothing listens after stop")
    }

    func testIPv6LoopbackBind() throws {
        let listener = MCPListener { _ in .empty(204) }
        let port: UInt16
        do { port = try listener.start(address: "::1", port: 0) } catch { throw XCTSkip("IPv6 loopback unavailable") }
        defer { listener.stop() }
        let client = try XCTUnwrap(TCPClient(port: port, address: "::1"))
        client.send("DELETE /mcp HTTP/1.1\r\nHost: [::1]\r\n\r\n")
        XCTAssertEqual(client.response()?.status, 204)
    }

    func testConnectionLimitAnswers503() throws {
        let (listener, port) = try echoListener()
        defer { listener.stop() }
        var held: [TCPClient] = []
        for _ in 0..<MCPListener.maximumConnections { held.append(try XCTUnwrap(TCPClient(port: port))) }
        // Make sure every held connection has been admitted before the extra one arrives.
        for client in held {
            client.send("GET / HTTP/1.1\r\n\r\n")
            XCTAssertNotNil(client.response())
        }
        let extra = try XCTUnwrap(TCPClient(port: port))
        XCTAssertEqual(extra.response()?.status, 503)
    }

    /// End to end: the real endpoint behind the real listener, with a real grant.
    func testServerAppliesSettingsAndServesMCP() async throws {
        let store = GrantStore(url: nil, secrets: MCPSecrets())
        let handler = AuthorizingControlHandler(grants: store, domain: MCPFakeDomain())
        let token = try await store.create(name: "e2e", capabilities: [.workspaceRead], spaceScope: .all, hostScope: .all, lifetime: 3600).token
        let server = MCPServer(handler: handler, serverVersion: "test")
        XCTAssertEqual(server.apply(RemoteControlSettings(mcpEnabled: false)), .stopped)
        // Port 0 is not a valid setting; find a free port first.
        let probe = MCPListener { _ in .empty(200) }
        let port = try probe.start(address: "127.0.0.1", port: 0)
        probe.stop()
        let status = server.apply(RemoteControlSettings(mcpEnabled: true, bindAddress: "127.0.0.1", port: port))
        XCTAssertEqual(status, .running(url: "http://127.0.0.1:\(port)/mcp"))
        defer { server.stop() }
        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#
        let response = try await Task.detached {
            let client = try XCTUnwrap(TCPClient(port: port))
            client.send(
                "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
            return try XCTUnwrap(client.response())
        }.value
        XCTAssertEqual(response.status, 200)
        XCTAssertNotNil(response.headers["mcp-session-id"])
        XCTAssertTrue(response.body.contains("\"serverInfo\""))
        let blocker = MCPListener { _ in .empty(200) }
        let busy = try blocker.start(address: "127.0.0.1", port: 0)
        defer { blocker.stop() }
        guard case .failed(let reason) = server.apply(RemoteControlSettings(mcpEnabled: true, port: busy)) else { return XCTFail("Expected a failure status") }
        XCTAssertTrue(reason.contains("already in use"))
        XCTAssertNil(TCPClient(port: port), "Applying new settings stops the previous listener")
    }

    /// events_poll over the real listener: a waiting poll holds its keep-alive connection for its timeout (well inside the
    /// listener's 30 s limit, which counts only time spent reading a request), then the connection serves the next call;
    /// an event answers a waiting poll early.
    func testEventsPollLongPollsOverHTTPOnAKeepAliveConnection() async throws {
        let store = GrantStore(url: nil, secrets: MCPSecrets())
        let hub = EventHubV2(instanceID: UUID(), grants: store)
        let handler = AuthorizingControlHandler(grants: store, domain: MCPFakeDomain(), events: hub)
        let token = try await store.create(name: "poller", capabilities: [.workspaceRead, .themeRead], spaceScope: .all, hostScope: .all, lifetime: 3600).token
        let endpoint = MCPEndpoint(handler: handler, serverVersion: "test", loopbackOnly: true)
        let listener = MCPListener { request in await endpoint.handle(request) }
        let port = try listener.start(address: "127.0.0.1", port: 0)
        defer { listener.stop() }
        XCTAssertGreaterThan(MCPListener.timeout, Double(EventHubV2.maximumTimeoutMs) / 1_000, "The longest poll fits the listener's limit")
        let request: @Sendable (String, String?) -> String = { body, session in
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\n"
                + (session.map { "Mcp-Session-Id: \($0)\r\n" } ?? "") + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        }
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#
        let poll: @Sendable (Int) -> String = { timeout in
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"events_poll","arguments":{"topics":["appearance"],"timeoutMs":\#(timeout)}}}"#
        }
        let client = try XCTUnwrap(TCPClient(port: port))
        let opened = try await Task.detached {
            client.send(request(initialize, nil))
            return try XCTUnwrap(client.response())
        }.value
        let session = try XCTUnwrap(opened.headers["mcp-session-id"])

        // No event: the poll answers after its timeout, on the same connection.
        let (waited, elapsed) = try await Task.detached {
            let start = ContinuousClock.now
            client.send(request(poll(1_500), session))
            let response = try XCTUnwrap(client.response())
            return (response, ContinuousClock.now - start)
        }.value
        XCTAssertEqual(waited.status, 200)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(1_400))
        XCTAssertLessThan(elapsed, .seconds(4))
        XCTAssertTrue(waited.body.contains(#""events":[]"#), waited.body)
        let pinged = try await Task.detached {
            client.send(request(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#, session))
            return try XCTUnwrap(client.response())
        }.value
        XCTAssertEqual(pinged.status, 200, "The kept-alive connection serves the next call")

        // An event published while the poll waits answers it early.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await hub.publish([.appearance(mode: "light", lightThemeID: "l", darkThemeID: "d", effectiveThemeID: "l", revision: 3)])
        }
        let (answered, early) = try await Task.detached {
            let start = ContinuousClock.now
            client.send(request(poll(20_000), session))
            let response = try XCTUnwrap(client.response())
            return (response, ContinuousClock.now - start)
        }.value
        XCTAssertEqual(answered.status, 200)
        XCTAssertLessThan(early, .seconds(4), "The event ended the wait")
        XCTAssertTrue(answered.body.contains("appearance.changed"), answered.body)
        XCTAssertTrue(answered.body.contains(MCPTools.untrustedNotice), "Poll results carry the untrusted-data notice")
    }
}
