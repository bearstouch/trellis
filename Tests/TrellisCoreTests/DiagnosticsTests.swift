import XCTest
@testable import TrellisCore

final class DiagnosticsTests: XCTestCase {
    func testS030_UT03_sanitizeErrorsAndDiagnostics() throws {
        var snapshot = WorkspaceSnapshot()
        let window = UUID(), tab = UUID(), pane = UUID(), session = UUID()
        snapshot.windows = [ManagedWindow(id: window, name: "SECRET-WINDOW", tabIDs: [tab], activeTabID: tab)]
        snapshot.activeWindowID = window
        snapshot.tabs[tab] = WorkspaceTab(id: tab, windowID: window, title: "SECRET-TAB", root: .pane(pane), activePaneID: pane)
        snapshot.panes[pane] = WorkspacePane(id: pane, tabID: tab, sessionID: session, title: "SECRET-PANE")
        snapshot.sessions[session] = WorkspaceSession(id: session, launch: .process(executable: "/bin/sh", arguments: ["-c", "export PASSWORD=hunter2"], directory: "/Users/me/secret-dir"))
        var report = DiagnosticsReport(appVersion: "1.0", systemVersion: "macOS 15", architecture: "arm64")
        report.count(snapshot)
        report.savedHosts = 2
        report.recentErrorCodes = ["LAUNCH_FAILED", "token trl_ABCDEFGHIJK leaked", "hunter2"]
        let text = report.text
        for secret in ["SECRET-WINDOW", "SECRET-TAB", "SECRET-PANE", "hunter2", "secret-dir", "/bin/sh", "trl_ABCDEFGHIJK", session.uuidString, pane.uuidString] {
            XCTAssertFalse(text.contains(secret), "Diagnostics contain \(secret)")
        }
        XCTAssertTrue(text.contains("1 window(s), 1 tab(s), 1 pane(s)"))
        XCTAssertTrue(text.contains("stopped=1"))
        XCTAssertTrue(text.contains("LAUNCH_FAILED"), "Stable error codes are kept")
        XCTAssertTrue(text.contains("Not included:"), "The preview states what is excluded")

        let redacted = SecretRedactor.redact(
            "token trl_abcDEF123_-x hash sha256:\(String(repeating: "a", count: 64)) mail ops@example.com path /Users/me/project\n-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----",
            home: "/Users/me")
        for secret in ["trl_abc", "aaaaaaaa", "ops@example.com", "/Users/me", "AAAA"] { XCTAssertFalse(redacted.contains(secret), secret) }
        XCTAssertTrue(redacted.contains("~/project"))
    }

    func testLinkPolicyAllowList() {
        XCTAssertNotNil(LinkPolicy.url("https://example.com"))
        XCTAssertNotNil(LinkPolicy.url("MAILTO:a@example.com"))
        XCTAssertNil(LinkPolicy.url("data:text/html,hi"))
        let mail = LinkPolicy.url("mailto:a@example.com?subject=Hi&bcc=attacker@example.com&body=x")?.absoluteString ?? ""
        XCTAssertTrue(mail.contains("subject=Hi") && mail.contains("body=x"))
        XCTAssertFalse(mail.contains("bcc"), "Output cannot add recipients or headers")
        var report = DiagnosticsReport(appVersion: "1", systemVersion: "m", architecture: "a")
        report.recentErrorCodes = ["SECRET_TOKEN_VALUE", "CONFLICT"]
        XCTAssertFalse(report.text.contains("SECRET_TOKEN_VALUE"), "Only known codes are reported")
        XCTAssertNil(LinkPolicy.mayOpen("https://example.com", lastGesture: nil, now: Date()))
        let now = Date()
        XCTAssertNil(LinkPolicy.mayOpen("https://example.com", lastGesture: now.addingTimeInterval(1), now: now), "A future gesture is not trusted")
    }
}
