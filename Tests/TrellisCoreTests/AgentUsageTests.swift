import Foundation
import XCTest
@testable import TrellisCore

/// FR-AG22, FR-AG23: reading Claude Code's and Codex's limits.
final class AgentUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testClaudeCredentialReadsTokenExpiryAndPlanAndHidesTheToken() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-secret","refreshToken":"rt-secret","expiresAt":1800000600000,"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"},"mcpOAuth":{}}"#
        let credential = try XCTUnwrap(ClaudeUsage.parseCredential(Data(json.utf8)))
        XCTAssertEqual(credential.accessToken, "sk-secret")
        XCTAssertEqual(credential.plan, "Max 5x")
        XCTAssertFalse(credential.isExpired(at: now))
        XCTAssertTrue(credential.isExpired(at: now.addingTimeInterval(601)))
        XCTAssertFalse(credential.description.contains("secret"))
        XCTAssertFalse("\(credential)".contains("sk-"))
    }

    func testClaudeCredentialWithoutATokenIsNil() {
        for json in [#"{}"#, #"{"claudeAiOauth":{}}"#, #"{"claudeAiOauth":{"accessToken":""}}"#, #"{"claudeAiOauth":{"accessToken":"a\nb"}}"#, "not json"] {
            XCTAssertNil(ClaudeUsage.parseCredential(Data(json.utf8)), json)
        }
        let pro = ClaudeUsage.parseCredential(Data(#"{"claudeAiOauth":{"accessToken":"t","subscriptionType":"pro"}}"#.utf8))
        XCTAssertEqual(pro?.plan, "Pro")
        XCTAssertNil(pro?.expiresAt)
        XCTAssertEqual(pro?.isExpired(at: now), false)
    }

    func testClaudeUsageReadsSessionWeeklyAndScopedLimits() throws {
        let json = """
            {"five_hour":{"utilization":16.0,"resets_at":"2026-11-18T13:09:59.925382+00:00"},
             "seven_day":{"utilization":83.0,"resets_at":"2026-11-21T03:59:59+00:00"},
             "seven_day_opus":{"utilization":5.0,"resets_at":null},
             "limits":[{"kind":"session","percent":16},{"kind":"weekly_scoped","percent":23,"resets_at":"2026-11-21T03:59:59.925589+00:00","scope":{"model":{"id":null,"display_name":"Fable"}}}]}
            """
        let snapshot = try XCTUnwrap(ClaudeUsage.parse(Data(json.utf8), plan: "Max 5x", now: now))
        XCTAssertEqual(snapshot.windows.map(\.kind), [.session, .weekly, .scoped("Fable")])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [16, 83, 23])
        XCTAssertEqual(snapshot.windows[0].resetsAt.map { Int($0.timeIntervalSince1970) }, 1_795_007_399)
        XCTAssertEqual(snapshot.windows[1].resetsAt.map { Int($0.timeIntervalSince1970) }, 1_795_233_599)
        XCTAssertEqual(snapshot.windows[1].level, .high)
        XCTAssertEqual(snapshot.plan, "Max 5x")
        XCTAssertEqual(snapshot.fetchedAt, now)
    }

    func testClaudeUsageFallsBackToModelWindowsAndToleratesNulls() throws {
        let json = #"{"five_hour":null,"seven_day":{"utilization":140},"seven_day_opus":{"utilization":12.5},"seven_day_sonnet":null,"extra":{"x":1}}"#
        let snapshot = try XCTUnwrap(ClaudeUsage.parse(Data(json.utf8), plan: nil, now: now))
        XCTAssertEqual(snapshot.windows.map(\.kind), [.weekly, .scoped("Opus")])
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 100)
        XCTAssertEqual(snapshot.windows.first?.level, .critical)
        XCTAssertNil(snapshot.windows.first?.resetsAt)
        XCTAssertEqual(ClaudeUsage.parse(Data("{}".utf8), plan: nil, now: now)?.windows, [])
        XCTAssertNil(ClaudeUsage.parse(Data("[1]".utf8), plan: nil, now: now))
    }

    func testCodexUsagePicksWindowsByLength() throws {
        let json = #"{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1800016260},"secondary":{"usedPercent":97,"windowDurationMins":10080,"resetsAt":1800500000},"planType":"plus"}}"#
        let snapshot = try XCTUnwrap(CodexUsage.parse(Data(json.utf8), now: now))
        XCTAssertEqual(snapshot.windows.map(\.kind), [.session, .weekly])
        XCTAssertEqual(snapshot.windows.map(\.level), [.normal, .critical])
        XCTAssertEqual(snapshot.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_800_016_260))
        XCTAssertEqual(snapshot.plan, "Plus")
        // Codex Free's single 30-day window; windows come out shortest first whatever their order.
        let free = #"{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":43200,"resetsAt":1797590777},"secondary":{"usedPercent":3,"windowDurationMins":120},"planType":"free"}}"#
        let monthly = try XCTUnwrap(CodexUsage.parse(Data(free.utf8), now: now))
        XCTAssertEqual(monthly.windows.map(\.kind), [.span(minutes: 120), .monthly])
        XCTAssertEqual(monthly.plan, "Free")
    }

    func testCodexUsageWithoutLimitsOrLengths() throws {
        XCTAssertEqual(CodexUsage.parse(Data(#"{"rateLimits":{"primary":null,"secondary":null}}"#.utf8), now: now)?.windows, [])
        XCTAssertEqual(CodexUsage.parse(Data(#"{}"#.utf8), now: now)?.windows, [])
        let unsized = try XCTUnwrap(CodexUsage.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":40},"secondary":{"usedPercent":-5}}}"#.utf8), now: now))
        XCTAssertEqual(unsized.windows.map(\.kind), [.session, .weekly])
        XCTAssertEqual(unsized.windows.last?.usedPercent, 0)
        XCTAssertNil(CodexUsage.parse(Data("nope".utf8), now: now))
    }

    func testCodexRequestLinesAreThreeJSONLines() throws {
        let lines = String(decoding: CodexUsage.requestLines(version: "1.3.0"), as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        let methods = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])["method"] as? String }
        XCTAssertEqual(methods, ["initialize", "initialized", "account/rateLimits/read"])
    }

    func testCodexLineReaderFindsTheReplyAcrossChunksAndSkipsNotifications() throws {
        var reader = CodexUsage.LineReader()
        XCTAssertNil(reader.append(Data(#"{"id":1,"result":{"userAgent":"x"}}"#.utf8 + [10])))
        XCTAssertNil(reader.append(Data(#"{"method":"account/updated","params":{"authMode":"chatgpt"}}"#.utf8 + [10])))
        XCTAssertNil(reader.append(Data(#"{"id":2,"result":{"rateLimits":"#.utf8)))
        let reply = reader.append(Data(#"{"planType":"pro"}}}"#.utf8 + [10]))
        guard case .result(let data)? = reply else { return XCTFail("no reply: \(String(describing: reply))") }
        XCTAssertEqual(CodexUsage.parse(data, now: now)?.plan, "Pro")
        var failing = CodexUsage.LineReader()
        XCTAssertEqual(failing.append(Data(#"{"id":2,"error":{"code":-32600,"message":"not logged in"}}"#.utf8 + [10])), .error("not logged in"))
    }

    func testWindowKindsAndPlanNames() {
        XCTAssertEqual(AgentUsageWindowKind(minutes: 300), .session)
        XCTAssertEqual(AgentUsageWindowKind(minutes: 10_080), .weekly)
        XCTAssertEqual(AgentUsageWindowKind(minutes: 43_200), .monthly)
        XCTAssertEqual(AgentUsageWindowKind(minutes: 60), .span(minutes: 60))
        XCTAssertEqual(AgentUsageWindow(kind: .session, usedPercent: .nan, resetsAt: nil).usedPercent, 0)
        XCTAssertEqual(AgentUsageWindow(kind: .session, usedPercent: 79.9, resetsAt: nil).level, .normal)
        XCTAssertEqual(AgentUsageWindow(kind: .session, usedPercent: 80, resetsAt: nil).level, .high)
        XCTAssertEqual(AgentUsageWindow(kind: .session, usedPercent: 95, resetsAt: nil).level, .critical)
        XCTAssertEqual(AgentUsagePlan.displayName("prolite"), "Pro Lite")
        XCTAssertEqual(AgentUsagePlan.displayName("self_serve_business_usage_based"), "Self Serve Business Usage Based")
        XCTAssertNil(AgentUsagePlan.displayName(""))
        XCTAssertNil(AgentUsagePlan.displayName(nil))
    }
}

/// Review-driven: the token stays out of reflection, and a reply on a last line without a newline still counts.
final class AgentUsageReviewTests: XCTestCase {
    func testCredentialHidesTheTokenFromDumpAndReflection() {
        let credential = ClaudeCredential(accessToken: "sk-secret-token", expiresAt: nil, plan: "Max")
        var dumped = ""
        dump(credential, to: &dumped)
        XCTAssertFalse(dumped.contains("sk-secret"))
        XCTAssertFalse(String(reflecting: credential).contains("sk-secret"))
        XCTAssertFalse(Mirror(reflecting: credential).children.contains { "\($0.value)".contains("sk-secret") })
    }

    func testLineReaderReadsAReplyWithoutATrailingNewlineAtTheEnd() {
        var reader = CodexUsage.LineReader()
        XCTAssertNil(reader.append(Data(#"{"id":2,"result":{"rateLimits":{}}}"#.utf8)))
        XCTAssertEqual(reader.finish(), .result(Data(#"{"rateLimits":{}}"#.utf8)))
        var empty = CodexUsage.LineReader()
        XCTAssertNil(empty.finish())
    }
}
