import AppKit
import XCTest
import TrellisCore
@testable import TrellisUI

/// FR-AG22, FR-AG23: the Agents view's usage, with a fake client; nothing here reads the Keychain, the network or codex.
@MainActor
final class AgentUsageModelTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func add(_ name: String) { lock.withLock { names.append(name) } }
        var all: [String] { lock.withLock { names } }
    }

    private var scratch: URL!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-usage-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    nonisolated private static let claudeBody = Data(#"{"five_hour":{"utilization":42,"resets_at":"2027-01-15T10:00:00Z"},"seven_day":{"utilization":83}}"#.utf8)
    nonisolated private static let codexBody = Data(#"{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300},"secondary":{"usedPercent":97,"windowDurationMins":10080},"planType":"plus"}}"#.utf8)

    private func makeModel(
        credential: ClaudeCredential? = ClaudeCredential(accessToken: "token", expiresAt: nil, plan: "Max"), http: AgentUsageHTTP = .ok(claudeBody),
        codex: CodexUsageOutcome = .reply(.result(codexBody)), calls: Calls
    ) throws -> AppWorkspaceModel {
        _ = NSApplication.shared
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis-usage-\(UUID().uuidString)"))
        let model = AppWorkspaceModel(store: try WorkspaceStore(), preferences: preferences, persistence: WorkspacePersistence(directory: scratch))
        model.activityNow = { [unowned self] in now }
        model.agentUsageClient = AgentUsageClient(
            claudeCredential: {
                calls.add("keychain"); return credential
            },
            claudeUsage: { token in
                calls.add("http:\(token)"); return http
            },
            codexRateLimits: { executable, _ in
                calls.add("codex:\(executable)"); return codex
            })
        model.agentAvailability[AppWorkspaceModel.codexUsageAgentID] = .installed(path: "/opt/bin/codex")
        return model
    }

    func testUsageIsOffByDefaultAndAsksNothing() async throws {
        let calls = Calls()
        let model = try makeModel(calls: calls)
        XCTAssertFalse(model.claudeUsageEnabled)
        XCTAssertFalse(model.codexUsageEnabled)
        XCTAssertTrue(model.agentUsageAgents.isEmpty)
        await model.refreshAgentUsage(force: true)
        await model.pollAgentUsage()
        XCTAssertEqual(calls.all, [])
        XCTAssertTrue(model.agentUsage.isEmpty)
    }

    func testEnabledAgentsReadTheirUsage() async throws {
        let calls = Calls()
        let model = try makeModel(calls: calls)
        model.claudeUsageEnabled = true; model.codexUsageEnabled = true
        XCTAssertEqual(model.agentUsageAgents.map(\.id), [AppWorkspaceModel.claudeUsageAgentID, AppWorkspaceModel.codexUsageAgentID])
        await model.refreshAgentUsage()
        XCTAssertEqual(Set(calls.all), ["keychain", "http:token", "codex:/opt/bin/codex"])
        let claude = try XCTUnwrap(model.agentUsage[AppWorkspaceModel.claudeUsageAgentID]?.snapshot)
        XCTAssertEqual(claude.windows.map(\.usedPercent), [42, 83])
        XCTAssertEqual(claude.plan, "Max")
        guard case .ready(let codex)? = model.agentUsage[AppWorkspaceModel.codexUsageAgentID] else { return XCTFail("codex not ready") }
        XCTAssertEqual(codex.windows.map(\.kind), [.session, .weekly])
        XCTAssertFalse(model.agentUsageRefreshing)
    }

    func testAnAskWithinAMinuteIsSkippedUnlessForced() async throws {
        let calls = Calls()
        let model = try makeModel(calls: calls)
        model.claudeUsageEnabled = true
        await model.refreshAgentUsage()
        now += 30
        await model.refreshAgentUsage()
        XCTAssertEqual(calls.all.filter { $0 == "keychain" }.count, 1)
        await model.refreshAgentUsage(force: true)
        XCTAssertEqual(calls.all.filter { $0 == "keychain" }.count, 2)
        now += 61
        await model.refreshAgentUsage()
        XCTAssertEqual(calls.all.filter { $0 == "keychain" }.count, 3)
    }

    func testAnExpiredSignInIsNeverSentOrRenewed() async throws {
        let calls = Calls()
        let model = try makeModel(credential: ClaudeCredential(accessToken: "old", expiresAt: now.addingTimeInterval(-1), plan: nil), calls: calls)
        model.claudeUsageEnabled = true
        await model.refreshAgentUsage()
        XCTAssertEqual(calls.all, ["keychain"])
        XCTAssertEqual(model.agentUsage[AppWorkspaceModel.claudeUsageAgentID], .unavailable(.signInExpired, last: nil))
    }

    func testNoSignInAndARefusedTokenAreReported() async throws {
        let calls = Calls()
        let signedOut = try makeModel(credential: nil, calls: calls)
        signedOut.claudeUsageEnabled = true
        await signedOut.refreshAgentUsage()
        XCTAssertEqual(signedOut.agentUsage[AppWorkspaceModel.claudeUsageAgentID], .unavailable(.notSignedIn, last: nil))
        XCTAssertFalse(calls.all.contains { $0.hasPrefix("http") })
        let refused = try makeModel(http: .status(401), calls: Calls())
        refused.claudeUsageEnabled = true
        await refused.refreshAgentUsage()
        XCTAssertEqual(refused.agentUsage[AppWorkspaceModel.claudeUsageAgentID], .unavailable(.signInExpired, last: nil))
    }

    func testAFailureKeepsTheLastValuesAsStale() async throws {
        let calls = Calls()
        let model = try makeModel(calls: calls)
        model.claudeUsageEnabled = true
        await model.refreshAgentUsage()
        let first = try XCTUnwrap(model.agentUsage[AppWorkspaceModel.claudeUsageAgentID]?.snapshot)
        model.agentUsageClient.claudeUsage = { _ in .failed }
        await model.refreshAgentUsage(force: true)
        XCTAssertEqual(model.agentUsage[AppWorkspaceModel.claudeUsageAgentID], .unavailable(.failed, last: first))
        model.agentUsageClient.claudeUsage = { _ in .ok(Data("not json".utf8)) }
        await model.refreshAgentUsage(force: true)
        XCTAssertEqual(model.agentUsage[AppWorkspaceModel.claudeUsageAgentID], .unavailable(.failed, last: first))
    }

    func testRateLimitedWaitsFifteenMinutesEvenForRefresh() async throws {
        let calls = Calls()
        let model = try makeModel(http: .status(429), calls: calls)
        model.claudeUsageEnabled = true
        await model.refreshAgentUsage()
        XCTAssertEqual(model.agentUsage[AppWorkspaceModel.claudeUsageAgentID], .unavailable(.rateLimited, last: nil))
        now += 600
        await model.refreshAgentUsage(force: true)
        XCTAssertEqual(calls.all.filter { $0 == "keychain" }.count, 1)
        now += 301
        await model.refreshAgentUsage(force: true)
        XCTAssertEqual(calls.all.filter { $0 == "keychain" }.count, 2)
    }

    func testTurningUsageOffClearsIt() async throws {
        let calls = Calls()
        let model = try makeModel(calls: calls)
        model.codexUsageEnabled = true
        await model.refreshAgentUsage()
        XCTAssertNotNil(model.agentUsage[AppWorkspaceModel.codexUsageAgentID])
        model.codexUsageEnabled = false
        XCTAssertNil(model.agentUsage[AppWorkspaceModel.codexUsageAgentID])
        XCTAssertTrue(model.agentUsageAgents.isEmpty)
        // Back on, it asks again at once.
        model.codexUsageEnabled = true
        await model.refreshAgentUsage()
        XCTAssertEqual(calls.all.filter { $0.hasPrefix("codex") }.count, 2)
    }

    func testCodexMissingIsReportedWithoutRunningIt() async throws {
        let calls = Calls()
        let model = try makeModel(calls: calls)
        model.agentAvailability[AppWorkspaceModel.codexUsageAgentID] = .missing
        model.codexUsageEnabled = true
        await model.refreshAgentUsage()
        XCTAssertEqual(calls.all, [])
        XCTAssertEqual(model.agentUsage[AppWorkspaceModel.codexUsageAgentID], .unavailable(.notInstalled, last: nil))
    }

    func testCodexSignedOutAndApiKeyAccounts() async throws {
        let signedOut = try makeModel(codex: .reply(.error("Not logged in: run codex login")), calls: Calls())
        signedOut.codexUsageEnabled = true
        await signedOut.refreshAgentUsage()
        XCTAssertEqual(signedOut.agentUsage[AppWorkspaceModel.codexUsageAgentID], .unavailable(.notSignedIn, last: nil))
        let apiKey = try makeModel(codex: .reply(.result(Data(#"{"rateLimits":{"primary":null,"secondary":null}}"#.utf8))), calls: Calls())
        apiKey.codexUsageEnabled = true
        await apiKey.refreshAgentUsage()
        XCTAssertEqual(apiKey.agentUsage[AppWorkspaceModel.codexUsageAgentID], .unavailable(.noPlanLimits, last: nil))
        let broken = try makeModel(codex: .failed, calls: Calls())
        broken.codexUsageEnabled = true
        await broken.refreshAgentUsage()
        XCTAssertEqual(broken.agentUsage[AppWorkspaceModel.codexUsageAgentID], .unavailable(.failed, last: nil))
    }

    func testPollingStopsWhenCancelledAndSleepsFiveMinutes() async throws {
        let calls = Calls()
        let model = try makeModel(calls: calls)
        model.claudeUsageEnabled = true
        var sleeps: [TimeInterval] = []
        model.activitySleep = { [unowned self] seconds in
            sleeps.append(seconds); now += seconds
            if sleeps.count == 2 { model.claudeUsageEnabled = false }
        }
        await model.pollAgentUsage()
        XCTAssertEqual(sleeps, [300, 300])
        XCTAssertEqual(calls.all.filter { $0 == "keychain" }.count, 2)
    }

    /// The real runner against stand-ins for `codex`: one that answers, one that exits silently, one that never answers.
    func testCodexAppServerRunnerReadsTheReplyAndEndsTheProcess() async throws {
        func script(_ name: String, _ body: String) throws -> String {
            let path = scratch.appendingPathComponent(name).path
            try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }
        let answering = try script(
            "codex-ok",
            """
            [ "$1" = app-server ] || exit 2
            while IFS= read -r line; do case "$line" in *rateLimits/read*) printf '%s\\n' '{"method":"account/updated"}' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":300}}}}';; esac; done
            """)
        let outcome = await CodexAppServer.readRateLimits(executable: answering, path: ["/usr/bin", "/bin"], timeout: 5)
        guard case .reply(.result(let data)) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(CodexUsage.parse(data, now: now)?.windows.first?.usedPercent, 5)
        let silent = try script("codex-exit", "exit 1")
        let exited = await CodexAppServer.readRateLimits(executable: silent, path: nil, timeout: 5)
        XCTAssertEqual(exited, .failed)
        let hanging = try script("codex-hang", "exec /bin/sleep 30")
        let started = Date()
        let timedOut = await CodexAppServer.readRateLimits(executable: hanging, path: nil, timeout: 0.5)
        XCTAssertEqual(timedOut, .failed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let missing = await CodexAppServer.readRateLimits(executable: scratch.appendingPathComponent("none").path, path: nil, timeout: 1)
        XCTAssertEqual(missing, .failed)
    }

    func testClosingTheViewMidReadDoesNotRecordAFailure() async throws {
        let calls = Calls()
        let model = try makeModel(calls: calls)
        model.agentUsageClient.claudeUsage = { _ in
            try? await Task.sleep(for: .milliseconds(300))
            return Task.isCancelled ? .failed : .ok(Self.claudeBody)
        }
        model.claudeUsageEnabled = true
        let poll = Task { await model.pollAgentUsage() }
        try await Task.sleep(for: .milliseconds(50))
        poll.cancel()
        await poll.value
        let deadline = Date().addingTimeInterval(3)
        while model.agentUsageRefreshing, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard case .ready? = model.agentUsage[AppWorkspaceModel.claudeUsageAgentID] else {
            return XCTFail("\(String(describing: model.agentUsage[AppWorkspaceModel.claudeUsageAgentID]))")
        }
    }

    func testTheRateLimitWaitSurvivesTurningTheAgentOffAndOn() async throws {
        let calls = Calls()
        let model = try makeModel(http: .status(429), calls: calls)
        model.claudeUsageEnabled = true
        await model.refreshAgentUsage()
        model.claudeUsageEnabled = false; model.claudeUsageEnabled = true
        now += 60
        await model.refreshAgentUsage(force: true)
        XCTAssertEqual(calls.all.filter { $0 == "keychain" }.count, 1)
    }

    func testARateLimitArrivingAfterTurningOffStillWaits() async throws {
        let calls = Calls()
        let model = try makeModel(http: .status(429), calls: calls)
        model.agentUsageClient.claudeCredential = { [weak model] in
            await MainActor.run { model?.claudeUsageEnabled = false }
            calls.add("keychain")
            return ClaudeCredential(accessToken: "token", expiresAt: nil, plan: nil)
        }
        model.claudeUsageEnabled = true
        await model.refreshAgentUsage()
        XCTAssertNil(model.agentUsage[AppWorkspaceModel.claudeUsageAgentID])
        model.claudeUsageEnabled = true
        await model.refreshAgentUsage(force: true)
        XCTAssertEqual(calls.all.filter { $0 == "keychain" }.count, 1)
    }

    func testTheTokenGoesOnlyToTheUsageEndpoint() async throws {
        XCTAssertTrue(AgentUsageClient.isEndpoint(URL(string: "https://api.anthropic.com/api/oauth/usage")))
        for other in ["http://api.anthropic.com/api/oauth/usage", "https://evil.example/api/oauth/usage", "https://api.anthropic.com/api/other"] {
            XCTAssertFalse(AgentUsageClient.isEndpoint(URL(string: other)), other)
        }
        XCTAssertFalse(AgentUsageClient.isEndpoint(nil))
        let redirect = try XCTUnwrap(HTTPURLResponse(url: ClaudeUsage.endpoint, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://evil.example/"]))
        let next = await NoRedirects().urlSession(
            URLSession.shared, task: URLSession.shared.dataTask(with: ClaudeUsage.endpoint), willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: URL(string: "https://evil.example/")!))
        XCTAssertNil(next)
    }

    func testResetAndUpdatedWording() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(AgentUsageText.resets(now.addingTimeInterval(2 * 3600 + 9 * 60 + 30), now: now), "Resets in 2 h 10 min")
        XCTAssertEqual(AgentUsageText.resets(now.addingTimeInterval(59), now: now), "Resets in 1 min")
        XCTAssertEqual(AgentUsageText.resets(now.addingTimeInterval(-5), now: now), "Resetting now")
        XCTAssertNil(AgentUsageText.resets(nil, now: now))
        XCTAssertTrue(AgentUsageText.resets(now.addingTimeInterval(3 * 86_400), now: now)?.hasPrefix("Resets ") ?? false)
        XCTAssertEqual(AgentUsageText.updated(now.addingTimeInterval(-20), now: now), "Updated just now")
        XCTAssertEqual(AgentUsageText.updated(now.addingTimeInterval(-180), now: now), "Updated 3 min ago")
        XCTAssertEqual(AgentUsageText.title(.span(minutes: 43_200 - 1440)), "29-day window")
        XCTAssertEqual(AgentUsageText.title(.scoped("Fable")), "Fable weekly")
    }
}
