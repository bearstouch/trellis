import XCTest
import TrellisControl
import TrellisCore
@testable import TrellisMCP

/// FR-RC08, FR-RC09: requests proxied by `tailscale serve` to a loopback bind.
final class MCPTailnetTests: XCTestCase {
    private let clock = MCPClock()
    private let domain = MCPFakeDomain()
    private lazy var store = GrantStore(url: nil, secrets: MCPSecrets(), now: { [clock] in clock.now })
    private lazy var handler = AuthorizingControlHandler(
        grants: store, domain: domain, limiter: AuthenticationRateLimiter(now: { [clock] in clock.now }),
        networkLimiter: AuthenticationRateLimiter(now: { [clock] in clock.now }))
    private lazy var endpoint = MCPEndpoint(handler: handler, serverVersion: "test", loopbackOnly: true, now: { [clock] in clock.now })
    private let host = "studio.tail1a2b.ts.net"
    private let build = IPAddressLiteral("100.70.9.3")!

    private func token() async throws -> String {
        try await store.create(name: "agent", capabilities: Set(Capability.allCases), spaceScope: .all, hostScope: .all, lifetime: 3600).token
    }

    private func initialize(token: String, headers: [String: String]) async -> HTTPResponse {
        let all = ["Content-Type": "application/json", "Authorization": "Bearer \(token)"].merging(headers) { $1 }
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        return await endpoint.handle(HTTPRequest(method: "POST", path: "/mcp", headers: all, body: body))
    }

    private func ping(token: String, session: String, headers: [String: String]) async -> HTTPResponse {
        let all = ["Content-Type": "application/json", "Authorization": "Bearer \(token)", "Mcp-Session-Id": session].merging(headers) { $1 }
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2, "method": "ping"])
        return await endpoint.handle(HTTPRequest(method: "POST", path: "/mcp", headers: all, body: body))
    }

    func testProxiedRequestsAreRefusedWhileSharingIsOff() async throws {
        let token = try await token()
        let viaName = await initialize(token: token, headers: ["Host": "\(host):8443", "X-Forwarded-For": "100.70.9.3"])
        XCTAssertEqual(viaName.status, 403)
        let viaHeader = await initialize(token: token, headers: ["Host": "127.0.0.1:7777", "X-Forwarded-For": "100.70.9.3"])
        XCTAssertEqual(viaHeader.status, 403, "Forwarding headers mark a proxied request whatever Host says")
        let local = await initialize(token: token, headers: ["Host": "127.0.0.1:7777"])
        XCTAssertEqual(local.status, 200)
    }

    func testAnyTailnetDevice() async throws {
        let token = try await token()
        await endpoint.setTailnetAccess(TailnetAccess(hostName: host.uppercased(), port: 8443, allowedClients: nil))
        let tailnet = await initialize(token: token, headers: ["Host": "\(host):8443", "X-Forwarded-For": "100.70.9.3"])
        XCTAssertEqual(tailnet.status, 200)
        let rewrittenHost = await initialize(token: token, headers: ["Host": "127.0.0.1:7777", "X-Forwarded-For": "fd7a:115c:a1e0::5"])
        XCTAssertEqual(rewrittenHost.status, 200, "A proxy that rewrites Host is still checked by its forwarding header")
        let noHeader = await initialize(token: token, headers: ["Host": "\(host):8443"])
        XCTAssertEqual(noHeader.status, 200)
        let local = await initialize(token: token, headers: ["Host": "localhost:7777"])
        XCTAssertEqual(local.status, 200, "Local clients are unaffected")

        let publicClient = await initialize(token: token, headers: ["Host": "\(host):8443", "X-Forwarded-For": "203.0.113.9"])
        XCTAssertEqual(publicClient.status, 403, "A Funnel (public) client is never admitted")
        let otherName = await initialize(token: token, headers: ["Host": "other.tail1a2b.ts.net:8443", "X-Forwarded-For": "100.70.9.3"])
        XCTAssertEqual(otherName.status, 403)
        let otherPort = await initialize(token: token, headers: ["Host": "\(host):443", "X-Forwarded-For": "100.70.9.3"])
        XCTAssertEqual(otherPort.status, 403)
        let garbage = await initialize(token: token, headers: ["Host": "\(host):8443", "X-Forwarded-For": "unknown"])
        XCTAssertEqual(garbage.status, 403)
        let browser = await initialize(token: token, headers: ["Host": "\(host):8443", "X-Forwarded-For": "100.70.9.3", "Origin": "https://\(host):8443"])
        XCTAssertEqual(browser.status, 403, "Browsers are still refused")
    }

    func testPort443MatchesTheBareName() async throws {
        let token = try await token()
        await endpoint.setTailnetAccess(TailnetAccess(hostName: host, port: 443, allowedClients: nil))
        let bare = await initialize(token: token, headers: ["Host": host, "X-Forwarded-For": "100.70.9.3"])
        XCTAssertEqual(bare.status, 200)
        let explicit = await initialize(token: token, headers: ["Host": "\(host):443", "X-Forwarded-For": "100.70.9.3"])
        XCTAssertEqual(explicit.status, 200)
    }

    func testAllowedDevicesOnly() async throws {
        let token = try await token()
        await endpoint.setTailnetAccess(TailnetAccess(hostName: host, port: 8443, allowedClients: [build]))
        let allowed = await initialize(token: token, headers: ["Host": "\(host):8443", "X-Forwarded-For": "100.70.9.3"])
        XCTAssertEqual(allowed.status, 200)
        let chain = await initialize(token: token, headers: ["Host": "\(host):8443", "X-Forwarded-For": "100.88.4.21, 100.70.9.3"])
        XCTAssertEqual(chain.status, 200, "The nearest proxy's entry (the last) counts")
        let spoofed = await initialize(token: token, headers: ["Host": "\(host):8443", "X-Forwarded-For": "100.70.9.3, 100.88.4.21"])
        XCTAssertEqual(spoofed.status, 403)
        let other = await initialize(token: token, headers: ["Host": "\(host):8443", "X-Forwarded-For": "100.88.4.21"])
        XCTAssertEqual(other.status, 403)
        let unknown = await initialize(token: token, headers: ["Host": "\(host):8443"])
        XCTAssertEqual(unknown.status, 403, "With a device list, a client that can't be identified is refused")
    }

    func testRefusedClientsDontUseUpTheAuthenticationLimit() async throws {
        let token = try await token()
        await endpoint.setTailnetAccess(TailnetAccess(hostName: host, port: 8443, allowedClients: [build]))
        for _ in 0..<20 {
            let refused = await initialize(token: "trl_wrong", headers: ["Host": "\(host):8443", "X-Forwarded-For": "100.88.4.21"])
            XCTAssertEqual(refused.status, 403)
        }
        let allowed = await initialize(token: token, headers: ["Host": "\(host):8443", "X-Forwarded-For": "100.70.9.3"])
        XCTAssertEqual(allowed.status, 200)
    }

    func testChangingAccessKeepsSessionsButAppliesAtOnce() async throws {
        let token = try await token()
        let headers = ["Host": "\(host):8443", "X-Forwarded-For": "100.70.9.3"]
        await endpoint.setTailnetAccess(TailnetAccess(hostName: host, port: 8443, allowedClients: nil))
        let opened = await initialize(token: token, headers: headers)
        let session = try XCTUnwrap(opened.header("Mcp-Session-Id"))
        await endpoint.setTailnetAccess(TailnetAccess(hostName: host, port: 8443, allowedClients: [IPAddressLiteral("100.88.4.21")!]))
        let narrowed = await ping(token: token, session: session, headers: headers)
        XCTAssertEqual(narrowed.status, 403)
        await endpoint.setTailnetAccess(TailnetAccess(hostName: host, port: 8443, allowedClients: [build]))
        let again = await ping(token: token, session: session, headers: headers)
        XCTAssertEqual(again.status, 200)
        await endpoint.setTailnetAccess(nil)
        let off = await ping(token: token, session: session, headers: headers)
        XCTAssertEqual(off.status, 403)
    }

    func testNetworkBindIgnoresTailnetAccess() async throws {
        let network = MCPEndpoint(handler: handler, serverVersion: "test", loopbackOnly: false, now: { [clock] in clock.now })
        await network.setTailnetAccess(TailnetAccess(hostName: host, port: 8443, allowedClients: [build]))
        let token = try await token()
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "initialize"])
        let response = await network.handle(
            HTTPRequest(method: "POST", path: "/mcp", headers: ["Host": "192.168.1.5:7777", "Content-Type": "application/json", "Authorization": "Bearer \(token)"], body: body))
        XCTAssertEqual(response.status, 200)
    }

    func testDuplicateForwardedForIsMalformed() {
        var parser = HTTPRequestParser()
        let raw = "POST /mcp HTTP/1.1\r\nHost: a\r\nX-Forwarded-For: 100.70.9.3\r\nX-Forwarded-For: 100.88.4.21\r\nContent-Length: 0\r\n\r\n"
        XCTAssertThrowsError(try parser.append(Data(raw.utf8))) { XCTAssertEqual($0 as? HTTPParseError, .malformed) }
    }

    func testHelpers() {
        XCTAssertTrue(MCPEndpoint.hostMatches("Studio.Tail1a2b.ts.net:8443", name: host, port: 8443))
        XCTAssertFalse(MCPEndpoint.hostMatches(host, name: host, port: 8443))
        XCTAssertTrue(MCPEndpoint.hostMatches(host, name: host, port: 443))
        XCTAssertEqual(MCPEndpoint.forwardedClient("[fd7a:115c:a1e0::5]"), IPAddressLiteral("fd7a:115c:a1e0::5"))
        XCTAssertEqual(MCPEndpoint.forwardedClient(" 1.2.3.4 ,100.70.9.3 "), build)
        XCTAssertNil(MCPEndpoint.forwardedClient(""))
        XCTAssertNil(MCPEndpoint.forwardedClient("100.70.9.3:5555"))
    }
}

/// Replays fixed Tailscale CLI answers and records every command.
final class MCPFakeTailscaleCLI: TailscaleCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Result<Data, TailscaleError>] = [:]
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    func answer(_ command: String, _ result: Result<Data, TailscaleError>) { lock.withLock { answers[command] = result } }
    func answer(_ command: String, json: String) { answer(command, .success(Data(json.utf8))) }
    func run(_ arguments: [String], timeout: TimeInterval) async throws(TailscaleError) -> Data {
        let key = arguments.joined(separator: " ")
        let result = lock.withLock { () -> Result<Data, TailscaleError> in
            _calls.append(key)
            // Writing an entry makes `serve status` report it, as the real CLI does.
            if arguments.starts(with: ["serve", "--bg"]) { answers["serve status --json"] = .success(Data(MCPTailscaleFixtures.serve.utf8)) }
            if arguments.last == "off" { answers["serve status --json"] = .success(Data("{}".utf8)) }
            return answers[key] ?? .success(Data())
        }
        return try result.get()
    }
}

enum MCPTailscaleFixtures {
    static let connected = """
        {"BackendState":"Running","CertDomains":["studio.tail1a2b.ts.net"],
         "Self":{"ID":"nSelf","HostName":"studio","DNSName":"studio.tail1a2b.ts.net.","TailscaleIPs":["100.101.12.7"]},
         "Peer":{"k1":{"ID":"nBuild","HostName":"build-server","OS":"linux","Online":true,"TailscaleIPs":["100.70.9.3"]}}}
        """
    static let serve = #"{"TCP":{"8443":{"HTTPS":true}},"Web":{"studio.tail1a2b.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7777"}}}}}"#
}

/// FR-RC06, FR-RC07, FR-RC09: the coordinator that keeps the serve entry and the endpoint's access in line.
final class TailscaleSharingTests: XCTestCase {
    private final class States: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [TailscaleShareState] = []
        func append(_ state: TailscaleShareState) { lock.withLock { list.append(state) } }
        var all: [TailscaleShareState] { lock.withLock { list } }
    }

    private let cli = MCPFakeTailscaleCLI()
    private let states = States()
    private lazy var server: MCPServer = {
        let store = GrantStore(url: nil, secrets: MCPSecrets())
        return MCPServer(handler: AuthorizingControlHandler(grants: store, domain: MCPFakeDomain()), serverVersion: "test")
    }()
    private lazy var sharing = TailscaleSharing(
        controller: TailscaleController(runner: cli), server: server, sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }, onState: { [states] in states.append($0) })
    private let build = TailnetDevice(id: "nBuild", name: "build-server", addresses: ["100.70.9.99"])
    private let gone = TailnetDevice(id: "nGone", name: "old-laptop", addresses: ["100.88.4.21"])

    private func settings(share: Bool = true, devices: [TailnetDevice] = [], port: UInt16 = 8443) -> RemoteControlSettings {
        RemoteControlSettings(mcpEnabled: true, tailscaleShare: share, tailscalePort: port, allowedDevices: devices)
    }

    func testSharingPublishesTheEntryAndOpensAccess() async throws {
        cli.answer("status --json", json: MCPTailscaleFixtures.connected)
        await sharing.apply(settings())
        XCTAssertEqual(cli.calls, ["status --json", "serve status --json", "serve --bg --https=8443 http://127.0.0.1:7777", "serve status --json"])
        XCTAssertEqual(states.all, [.starting, .shared(url: "https://studio.tail1a2b.ts.net:8443/mcp")])
        XCTAssertEqual(server.tailnetAccess, TailnetAccess(hostName: "studio.tail1a2b.ts.net", port: 8443, allowedClients: nil))
    }

    func testAllowedDevicesUseCurrentAddressesAndKeepSavedOnesForUnlistedDevices() async throws {
        cli.answer("status --json", json: MCPTailscaleFixtures.connected)
        await sharing.apply(settings(devices: [build, gone]))
        XCTAssertEqual(server.tailnetAccess?.allowedClients, [IPAddressLiteral("100.70.9.3")!, IPAddressLiteral("100.88.4.21")!])
    }

    func testTurningOffRemovesTheEntryAndClosesAccess() async throws {
        cli.answer("status --json", json: MCPTailscaleFixtures.connected)
        await sharing.apply(settings())
        await sharing.apply(settings(share: false))
        XCTAssertEqual(Array(cli.calls.suffix(2)), ["serve status --json", "serve --https=8443 off"])
        XCTAssertNil(server.tailnetAccess)
        XCTAssertEqual(states.all.last, .off)
    }

    func testChangingThePortMovesTheEntry() async throws {
        cli.answer("status --json", json: MCPTailscaleFixtures.connected)
        await sharing.apply(settings())
        await sharing.apply(settings(port: 443))
        XCTAssertTrue(cli.calls.contains("serve --https=8443 off"), "The old port's entry is removed first")
        XCTAssertEqual(cli.calls.filter { $0.hasPrefix("serve --bg") }.last, "serve --bg --https=443 http://127.0.0.1:7777")
    }

    func testWaitsForTailscaleThenRecoversWithoutApply() async throws {
        cli.answer("status --json", json: #"{"BackendState":"Stopped"}"#)
        await sharing.apply(settings())
        XCTAssertEqual(states.all, [.starting, .waiting])
        XCTAssertFalse(cli.calls.contains { $0.hasPrefix("serve") }, "Nothing is written while Tailscale is down")
        cli.answer("status --json", json: MCPTailscaleFixtures.connected)
        await sharing.reconcile()
        XCTAssertEqual(states.all.last, .shared(url: "https://studio.tail1a2b.ts.net:8443/mcp"))
    }

    func testAnUnreadableStatusKeepsWorkingClients() async throws {
        cli.answer("status --json", json: MCPTailscaleFixtures.connected)
        await sharing.apply(settings())
        cli.answer("status --json", .failure(.timedOut))
        await sharing.reconcile()
        XCTAssertEqual(states.all.last, .failed(.tailscale(.timedOut)))
        XCTAssertNotNil(server.tailnetAccess)
    }

    func testPortInUseAndMissingTailscaleCloseAccess() async throws {
        cli.answer("status --json", json: MCPTailscaleFixtures.connected)
        cli.answer("serve status --json", json: #"{"TCP":{"8443":{"TCPForward":"127.0.0.1:22"}}}"#)
        await sharing.apply(settings())
        XCTAssertEqual(states.all.last, .failed(.portInUse(8443)))
        XCTAssertNil(server.tailnetAccess)
        XCTAssertFalse(cli.calls.contains { $0.hasPrefix("serve --bg") })

        cli.answer("status --json", .failure(.notInstalled))
        await sharing.reconcile()
        XCTAssertEqual(states.all.last, .failed(.notConnected(.notInstalled)))
    }

    func testShutdownRemovesTheEntry() async throws {
        cli.answer("status --json", json: MCPTailscaleFixtures.connected)
        await sharing.apply(settings())
        await sharing.shutdown()
        XCTAssertEqual(cli.calls.last, "serve --https=8443 off")
        XCTAssertEqual(states.all.last, .off)
        await sharing.reconcile()
        XCTAssertEqual(cli.calls.last, "serve --https=8443 off", "A late loop iteration never shares again after quit")
    }

    func testApplyClearsAccessBeforeCheckingAgain() async throws {
        cli.answer("status --json", json: MCPTailscaleFixtures.connected)
        await sharing.apply(settings())
        cli.answer("status --json", .failure(.timedOut))
        await sharing.apply(settings(devices: [build]))
        XCTAssertNil(server.tailnetAccess, "A narrowed list is never left at the old, wider access")
    }

    func testServerRestartClearsAccess() async throws {
        cli.answer("status --json", json: MCPTailscaleFixtures.connected)
        await sharing.apply(settings())
        XCTAssertNotNil(server.tailnetAccess)
        server.stop()
        XCTAssertNil(server.tailnetAccess, "A new listener admits proxied requests only once sharing sets access again")
    }
}
