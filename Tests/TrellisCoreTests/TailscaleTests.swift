import XCTest
@testable import TrellisCore

/// Replays fixed CLI answers and records every command.
final class FakeTailscaleCLI: TailscaleCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: [Result<Data, TailscaleError>]] = [:]
    private var _calls: [[String]] = []
    var calls: [[String]] { lock.withLock { _calls } }

    /// Answers for `arguments.joined(" ")`, used in order; the last one repeats.
    func answer(_ command: String, _ results: Result<Data, TailscaleError>...) { lock.withLock { answers[command] = results } }
    func answer(_ command: String, json: String) { answer(command, .success(Data(json.utf8))) }

    func run(_ arguments: [String], timeout: TimeInterval) async throws(TailscaleError) -> Data {
        let key = arguments.joined(separator: " ")
        let result = lock.withLock { () -> Result<Data, TailscaleError> in
            _calls.append(arguments)
            guard var list = answers[key], !list.isEmpty else { return .success(Data()) }
            let first = list.count > 1 ? list.removeFirst() : list[0]
            answers[key] = list
            return first
        }
        return try result.get()
    }
}

enum TailscaleFixtures {
    static let host = "studio.tail1a2b.ts.net"
    static let status = """
        {"Version":"1.80.0","BackendState":"Running","CertDomains":["studio.tail1a2b.ts.net"],
         "Self":{"ID":"nSelf","HostName":"studio","DNSName":"Studio.tail1a2b.ts.net.","OS":"macOS","Online":true,"TailscaleIPs":["100.101.12.7","fd7a:115c:a1e0::1"]},
         "Peer":{"nodekey:a":{"ID":"nBuild","HostName":"build-server","DNSName":"build-server.tail1a2b.ts.net.","OS":"linux","Online":true,"TailscaleIPs":["100.70.9.3"]},
                 "nodekey:b":{"ID":"nAir","HostName":"","DNSName":"macbook-air.tail1a2b.ts.net.","OS":"macOS","Online":false,"TailscaleIPs":["100.88.4.21"]},
                 "nodekey:c":{"ID":"","HostName":"ghost","TailscaleIPs":["100.64.0.9"]},
                 "nodekey:d":{"ID":"nNoIP","HostName":"odd","TailscaleIPs":["8.8.8.8"]}}}
        """
    static func serve(_ target: String = "http://127.0.0.1:7777", port: Int = 8443, funnel: Bool = false, host: String = host) -> String {
        """
        {"TCP":{"\(port)":{"HTTPS":true}},"Web":{"\(host):\(port)":{"Handlers":{"/":{"Proxy":"\(target)"}}}}\(funnel ? #","AllowFunnel":{"\#(host):\#(port)":true}"# : "")}
        """
    }
}

final class TailscaleTests: XCTestCase {
    private let target = "http://127.0.0.1:7777"

    func testTailnetRanges() {
        for yes in ["100.64.0.0", "100.101.12.7", "100.127.255.255", "fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ab12::99"] {
            XCTAssertTrue(IPAddressLiteral(yes)?.isTailnet ?? false, yes)
        }
        for no in ["100.63.255.255", "100.128.0.0", "10.0.0.1", "127.0.0.1", "fd7a:115c:a1e1::1", "::1"] {
            XCTAssertFalse(IPAddressLiteral(no)?.isTailnet ?? true, no)
        }
    }

    func testStatusParsesSelfPeersAndHTTPS() throws {
        let status = try TailscaleStatus(json: Data(TailscaleFixtures.status.utf8))
        XCTAssertEqual(status.backend, .connected)
        XCTAssertEqual(status.dnsName, TailscaleFixtures.host, "Lowercased, trailing dot dropped")
        XCTAssertEqual(status.addresses, ["100.101.12.7", "fd7a:115c:a1e0::1"])
        XCTAssertTrue(status.httpsEnabled)
        XCTAssertEqual(status.peers.map(\.id), ["nBuild", "nAir"], "Peers without an ID or a tailnet address are left out")
        XCTAssertEqual(status.peers[1].name, "macbook-air", "An empty host name falls back to the DNS label")
        XCTAssertFalse(status.peers[1].online)
    }

    func testStatusStates() throws {
        func backend(_ json: String) throws -> TailscaleBackend { try TailscaleStatus(json: Data(json.utf8)).backend }
        XCTAssertEqual(try backend(#"{"BackendState":"NeedsLogin"}"#), .needsLogin)
        XCTAssertEqual(try backend(#"{"BackendState":"NeedsMachineAuth"}"#), .needsLogin)
        XCTAssertEqual(try backend(#"{"BackendState":"Stopped"}"#), .stopped)
        XCTAssertEqual(try backend(#"{"BackendState":"Running"}"#), .connected)
        XCTAssertFalse(try TailscaleStatus(json: Data(#"{"BackendState":"Running","CertDomains":["a.ts.net"]}"#.utf8)).httpsEnabled, "Without a MagicDNS name it can't be shared")
        XCTAssertFalse(try TailscaleStatus(json: Data(#"{"BackendState":"Running","Self":{"DNSName":"a.ts.net."}}"#.utf8)).httpsEnabled)
        XCTAssertThrowsError(try TailscaleStatus(json: Data("not json".utf8)))
    }

    func testServeConfigOwnership() throws {
        let mine = try TailscaleServeConfig(json: Data(TailscaleFixtures.serve().utf8))
        XCTAssertEqual(mine.use(host: TailscaleFixtures.host, port: 8443, target: target), .trellis)
        XCTAssertEqual(mine.use(host: TailscaleFixtures.host, port: 8443, target: "http://127.0.0.1:7778"), .other)
        XCTAssertEqual(mine.use(host: TailscaleFixtures.host, port: 443, target: target), .free)
        XCTAssertEqual(try TailscaleServeConfig(json: Data(TailscaleFixtures.serve(target + "/").utf8)).use(host: TailscaleFixtures.host, port: 8443, target: target), .trellis)
        let tcpOnly = try TailscaleServeConfig(json: Data(#"{"TCP":{"8443":{"TCPForward":"127.0.0.1:22"}}}"#.utf8))
        XCTAssertEqual(tcpOnly.use(host: TailscaleFixtures.host, port: 8443, target: target), .other, "A raw TCP forward is someone else's")
        let twoPaths = #"{"TCP":{"8443":{"HTTPS":true}},"Web":{"studio.tail1a2b.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7777"},"/x":{"Path":"/tmp"}}}}}"#
        XCTAssertEqual(try TailscaleServeConfig(json: Data(twoPaths.utf8)).use(host: TailscaleFixtures.host, port: 8443, target: target), .other)
        XCTAssertEqual(try TailscaleServeConfig(json: Data()), TailscaleServeConfig())
        XCTAssertEqual(try TailscaleServeConfig(json: Data("{}".utf8)), TailscaleServeConfig())
        XCTAssertTrue(try TailscaleServeConfig(json: Data(TailscaleFixtures.serve(funnel: true).utf8)).funnelOn(host: TailscaleFixtures.host, port: 8443))
        let foreground = #"{"Foreground":{"sess1":{"TCP":{"8443":{"HTTPS":true}},"Web":{"studio.tail1a2b.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7777"}}}}}}}"#
        XCTAssertEqual(try TailscaleServeConfig(json: Data(foreground.utf8)).use(host: TailscaleFixtures.host, port: 8443, target: target), .other, "A foreground serve in another terminal")
    }

    private func connected() throws -> TailscaleStatus { try TailscaleStatus(json: Data(TailscaleFixtures.status.utf8)) }

    func testShareAddsTheEntryWithExactArgumentsAndConfirmsIt() async throws {
        let cli = FakeTailscaleCLI()
        cli.answer("serve status --json", .success(Data("{}".utf8)), .success(Data(TailscaleFixtures.serve().utf8)))
        let url = try await TailscaleController(runner: cli).share(status: try connected(), port: 8443, target: target)
        XCTAssertEqual(url, "https://studio.tail1a2b.ts.net:8443/mcp")
        XCTAssertEqual(cli.calls, [["serve", "status", "--json"], ["serve", "--bg", "--https=8443", target], ["serve", "status", "--json"]])
        XCTAssertFalse(cli.calls.joined().contains("funnel"))
    }

    func testShareOnPort443HasNoPortInTheURLAndAnExistingEntryIsReused() async throws {
        let cli = FakeTailscaleCLI()
        cli.answer("serve status --json", json: TailscaleFixtures.serve(port: 443))
        let url = try await TailscaleController(runner: cli).share(status: try connected(), port: 443, target: target)
        XCTAssertEqual(url, "https://studio.tail1a2b.ts.net/mcp")
        XCTAssertEqual(cli.calls, [["serve", "status", "--json"]], "Already Trellis's: nothing is written")
    }

    func testShareRefusesAPortSomeoneElseServes() async throws {
        let cli = FakeTailscaleCLI()
        cli.answer("serve status --json", json: TailscaleFixtures.serve("http://127.0.0.1:3000"))
        let status = try connected()
        do throws(TailscaleShareError) {
            _ = try await TailscaleController(runner: cli).share(status: status, port: 8443, target: target)
            XCTFail("Expected portInUse")
        } catch {
            XCTAssertEqual(error, .portInUse(8443))
        }
        XCTAssertEqual(cli.calls.count, 1, "Nothing is changed")
    }

    func testFunnelOnTrellisEntryIsWithdrawnAndRefused() async throws {
        let cli = FakeTailscaleCLI()
        cli.answer("serve status --json", json: TailscaleFixtures.serve(funnel: true))
        let status = try connected()
        do throws(TailscaleShareError) {
            _ = try await TailscaleController(runner: cli).share(status: status, port: 8443, target: target)
            XCTFail("Expected funnelOn")
        } catch {
            XCTAssertEqual(error, .funnelOn(8443))
        }
        XCTAssertEqual(cli.calls.last, ["serve", "--https=8443", "off"])
    }

    func testShareNeedsAConnectedTailnetWithHTTPS() async throws {
        let controller = TailscaleController(runner: FakeTailscaleCLI())
        do throws(TailscaleShareError) {
            _ = try await controller.share(status: TailscaleStatus(backend: .stopped), port: 8443, target: target)
            XCTFail("Expected notConnected")
        } catch {
            XCTAssertEqual(error, .notConnected(.stopped))
        }
        var noHTTPS = try connected()
        noHTTPS.httpsEnabled = false
        do throws(TailscaleShareError) {
            _ = try await controller.share(status: noHTTPS, port: 8443, target: target)
            XCTFail("Expected httpsDisabled")
        } catch {
            XCTAssertEqual(error, .httpsDisabled)
        }
    }

    func testConsentLinkIsReportedOnlyForTailscalesOwnHost() async throws {
        let cli = FakeTailscaleCLI()
        cli.answer("serve status --json", json: "{}")
        cli.answer("serve --bg --https=8443 \(target)", .failure(.failed("https://login.tailscale.com/f/serve?node=abc")))
        let status = try connected()
        do throws(TailscaleShareError) {
            _ = try await TailscaleController(runner: cli).share(status: status, port: 8443, target: target)
            XCTFail("Expected consentRequired")
        } catch {
            XCTAssertEqual(error, .consentRequired(URL(string: "https://login.tailscale.com/f/serve?node=abc")!))
        }
        XCTAssertNil(TailscaleController.consentURL(in: "visit https://evil.example/login.tailscale.com"))
        XCTAssertNil(TailscaleController.consentURL(in: "visit http://login.tailscale.com/f/serve"))
    }

    func testShareFailsWhenTheCLIDidNotWriteTheEntry() async throws {
        let cli = FakeTailscaleCLI()
        cli.answer("serve status --json", json: "{}")
        let status = try connected()
        do throws(TailscaleShareError) {
            _ = try await TailscaleController(runner: cli).share(status: status, port: 8443, target: target)
            XCTFail("Expected a failure")
        } catch {
            guard case .tailscale(.failed) = error else { return XCTFail("\(error)") }
        }
    }

    func testUnshareRemovesOnlyTrellisEntry() async throws {
        let cli = FakeTailscaleCLI()
        cli.answer("serve status --json", json: TailscaleFixtures.serve())
        let removed = await TailscaleController(runner: cli).unshare(host: TailscaleFixtures.host, port: 8443, target: target)
        XCTAssertTrue(removed)
        XCTAssertEqual(cli.calls.last, ["serve", "--https=8443", "off"])

        let other = FakeTailscaleCLI()
        other.answer("serve status --json", json: TailscaleFixtures.serve("http://127.0.0.1:3000"))
        let removedOther = await TailscaleController(runner: other).unshare(host: TailscaleFixtures.host, port: 8443, target: target)
        XCTAssertFalse(removedOther)
        XCTAssertEqual(other.calls, [["serve", "status", "--json"]], "Someone else's entry is never removed")
    }

    func testStatusMapsMissingCLIAndStoppedDaemon() async throws {
        let cli = FakeTailscaleCLI()
        cli.answer("status --json", .failure(.notInstalled), .failure(.notRunning), .failure(.timedOut), .success(Data("garbage".utf8)))
        let controller = TailscaleController(runner: cli)
        var results: [Result<TailscaleStatus, TailscaleError>] = []
        for _ in 0..<4 { results.append(await controller.status()) }
        XCTAssertEqual(results[0], .success(TailscaleStatus(backend: .notInstalled)))
        XCTAssertEqual(results[1], .success(TailscaleStatus(backend: .stopped)))
        XCTAssertEqual(results[2], .failure(.timedOut))
        XCTAssertEqual(results[3], .failure(.malformed))
    }

    func testCLIIsFoundOnlyWhenTrusted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-ts-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = directory.appendingPathComponent("tailscale").path
        FileManager.default.createFile(atPath: tool, contents: Data("#!/bin/sh\necho '{}'\n".utf8))
        chmod(tool, 0o755)
        XCTAssertNotNil(TailscaleCLI.trusted(tool))
        chmod(tool, 0o757)
        XCTAssertNil(TailscaleCLI.trusted(tool), "World-writable")
        chmod(tool, 0o775)
        XCTAssertNil(TailscaleCLI.trusted(tool), "Group-writable")
        chmod(tool, 0o644)
        XCTAssertNil(TailscaleCLI.trusted(tool), "Not executable")
        XCTAssertNil(TailscaleCLI.trusted(directory.path), "A directory")
        XCTAssertNil(TailscaleCLI.trusted(directory.appendingPathComponent("missing").path))
        XCTAssertNil(TailscaleCLI(candidates: [directory.appendingPathComponent("missing").path]).executable)
    }

    func testCLIRunsWithoutAShellAndTimesOut() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-ts-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = directory.appendingPathComponent("tailscale").path
        let script = """
            #!/bin/sh
            case "$1" in
              status) printf '%s' "$2";;
              slow) exec /bin/sleep 30;;
              consent) echo 'To enable, visit: https://login.tailscale.com/f/serve?node=x'; exec /bin/sleep 30;;
              down) echo 'failed to connect to local Tailscale daemon' >&2; exit 1;;
              *) echo "bad: $1" >&2; exit 2;;
            esac
            """
        FileManager.default.createFile(atPath: tool, contents: Data(script.utf8))
        chmod(tool, 0o755)
        let cli = TailscaleCLI(candidates: [tool])
        let echoed = try await cli.run(["status", "$(touch /tmp/x); --json"], timeout: 5)
        XCTAssertEqual(String(decoding: echoed, as: UTF8.self), "$(touch /tmp/x); --json", "Arguments are passed literally")
        await XCTAssertThrowsAsync(try await cli.run(["slow"], timeout: 0.3), .timedOut)
        await XCTAssertThrowsAsync(try await cli.run(["consent"], timeout: 0.5), .failed("https://login.tailscale.com/f/serve?node=x"))
        await XCTAssertThrowsAsync(try await cli.run(["down"], timeout: 5), .notRunning)
        await XCTAssertThrowsAsync(try await cli.run(["other"], timeout: 5), .failed("bad: other"))
    }

    private func XCTAssertThrowsAsync(_ body: @autoclosure () async throws(TailscaleError) -> Data, _ expected: TailscaleError, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("Expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error, expected, line: line)
        }
    }

    // MARK: - Settings

    func testSharingSettingsValidateAndRoundTrip() throws {
        let device = TailnetDevice(id: "nBuild", name: "build-server", addresses: ["100.70.9.3"])
        let shared = RemoteControlSettings(mcpEnabled: true, tailscaleShare: true, tailscalePort: 443, allowedDevices: [device])
        XCTAssertTrue(shared.isValid)
        XCTAssertTrue(shared.sharesOverTailscale)
        XCTAssertEqual(shared.serveTarget, "http://127.0.0.1:7777")
        XCTAssertEqual(RemoteControlSettings(bindAddress: "::1", port: 9000).serveTarget, "http://[::1]:9000")
        XCTAssertEqual(try JSONDecoder().decode(RemoteControlSettings.self, from: try JSONEncoder().encode(shared)), shared)

        XCTAssertFalse(RemoteControlSettings(tailscalePort: 8080).isValid, "Only serve's HTTPS ports")
        XCTAssertFalse(RemoteControlSettings(bindAddress: "0.0.0.0", tailscaleShare: true).isValid, "Sharing proxies to loopback only")
        XCTAssertFalse(RemoteControlSettings(allowedDevices: [TailnetDevice(id: "x", name: "x", addresses: ["192.168.1.2"])]).isValid, "Tailnet addresses only")
        XCTAssertFalse(RemoteControlSettings(allowedDevices: [TailnetDevice(id: "", name: "x", addresses: ["100.70.9.3"])]).isValid)
        XCTAssertFalse(RemoteControlSettings(tailscaleShare: true).sharesOverTailscale, "Not while the server is off")
    }

    func testWorkspaceSavedBeforeSharingLoadsWithSharingOff() throws {
        let legacy = #"{"mcpEnabled":true,"bindAddress":"127.0.0.1","port":7777}"#
        let decoded = try JSONDecoder().decode(RemoteControlSettings.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.tailscaleShare)
        XCTAssertEqual(decoded.tailscalePort, 8443)
        XCTAssertEqual(decoded.allowedDevices, [])
        let json = #"{"shell":"/bin/zsh","directory":"/tmp","remoteControl":{"mcpEnabled":true,"tailscaleShare":true,"tailscalePort":22}}"#
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceSettings.self, from: Data(json.utf8)).remoteControl, RemoteControlSettings(), "An unusable value turns everything off")
    }

    func testWideningNeedsConfirmation() {
        let a = TailnetDevice(id: "a", name: "a", addresses: ["100.64.0.1"]), b = TailnetDevice(id: "b", name: "b", addresses: ["100.64.0.2"])
        let off = RemoteControlSettings(mcpEnabled: true)
        let onlyA = RemoteControlSettings(mcpEnabled: true, tailscaleShare: true, allowedDevices: [a])
        let any = RemoteControlSettings(mcpEnabled: true, tailscaleShare: true)
        XCTAssertTrue(onlyA.widensTailnetAccess(from: off))
        XCTAssertTrue(any.widensTailnetAccess(from: onlyA), "From a list to any device")
        XCTAssertTrue(RemoteControlSettings(mcpEnabled: true, tailscaleShare: true, allowedDevices: [a, b]).widensTailnetAccess(from: onlyA))
        XCTAssertFalse(onlyA.widensTailnetAccess(from: any), "Narrowing never asks")
        XCTAssertFalse(onlyA.widensTailnetAccess(from: onlyA))
        XCTAssertFalse(off.widensTailnetAccess(from: onlyA))
        var otherPort = onlyA
        otherPort.tailscalePort = 443
        XCTAssertFalse(otherPort.widensTailnetAccess(from: onlyA))
    }

    func testClientSnippetsNeverHoldAToken() {
        let url = "https://studio.tail1a2b.ts.net:8443/mcp"
        XCTAssertEqual(
            MCPClientSetup.claudeCode.snippet(url: url), #"claude mcp add --transport http trellis https://studio.tail1a2b.ts.net:8443/mcp --header "Authorization: Bearer <TOKEN>""#)
        XCTAssertEqual(MCPClientSetup.codex.snippet(url: url), "[mcp_servers.trellis]\nurl = \"\(url)\"\nbearer_token_env_var = \"TRELLIS_TOKEN\"\n")
        let json = try? JSONSerialization.jsonObject(with: Data(MCPClientSetup.json.snippet(url: url).utf8)) as? [String: Any]
        let server = (json?["mcpServers"] as? [String: Any])?["trellis"] as? [String: Any]
        XCTAssertEqual(server?["url"] as? String, url)
        XCTAssertEqual(server?["type"] as? String, "http")
        XCTAssertEqual((server?["headers"] as? [String: String])?["Authorization"], "Bearer <TOKEN>")
        for setup in MCPClientSetup.allCases { XCTAssertFalse(setup.snippet(url: url).contains("trl_"), "\(setup)") }
    }
}
