import AppKit
import XCTest
import TrellisControl
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

final class AutomationOutputTests: XCTestCase {
    @MainActor
    func testReadOutputViewsCursorsAndLimitsEndToEnd() async throws {
        let h = try Harness()
        try await h.grant("full")
        var published: [WorkspaceEvent] = []
        h.model.onWorkspaceEvents = { published += $0 }
        let window: String = try await h.value("windowId", "window.create", ["name": "Out"])
        XCTAssertTrue(published.contains { $0.type == "window.created" && $0.resourceID.uuidString == window })
        let pane = try XCTUnwrap(h.model.presentation.activePane?.id)
        let script = #"stty raw -echo; printf '\303'; sleep 0.05; printf '\251\000\377READY-END'; exec /bin/sleep 30"#
        _ = try await h.model.service.execute(.configureStoppedSession(paneID: pane, launch: .process(executable: "/bin/zsh", arguments: ["-f", "-c", script], directory: "/tmp")))
        await h.model.refresh()
        _ = try await h.code("session.start", ["paneId": pane.uuidString])
        let terminal = NativeTerminalHandle(try XCTUnwrap(h.model.terminals[pane]))
        defer {
            h.model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        try await terminal.waitFor("READY-END")
        let session = terminal.native.sessionID.uuidString

        let stream = try result(try await h.call("session.readOutput", ["id": session, "view": "stream"]))
        let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(stream["base64"] as? String)))
        XCTAssertEqual(bytes, Data([0xC3, 0xA9, 0x00, 0xFF]) + Data("READY-END".utf8), "Exact raw bytes across a split UTF-8 sequence")
        XCTAssertEqual(stream["gap"] as? Bool, false)
        XCTAssertEqual(stream["truncated"] as? Bool, false)
        let cursor = try XCTUnwrap(stream["nextCursor"] as? String)
        let again = try result(try await h.call("session.readOutput", ["id": session, "view": "stream", "cursor": cursor]))
        XCTAssertEqual(again["base64"] as? String, "")
        let small = try result(try await h.call("session.readOutput", ["id": session, "view": "stream", "maxBytes": 2]))
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(small["base64"] as? String)), Data([0xC3, 0xA9]))
        XCTAssertEqual(small["truncated"] as? Bool, true)

        let screen = try result(try await h.call("session.readOutput", ["id": session, "view": "screen"]))
        XCTAssertTrue((screen["text"] as? String ?? "").contains("READY-END"))
        XCTAssertNotNil(screen["capturedAt"] as? String)
        let scrollback = try result(try await h.call("session.readOutput", ["id": session, "view": "scrollback", "maxBytes": 3]))
        XCTAssertLessThanOrEqual((scrollback["text"] as? String ?? "").utf8.count, 3)

        for maxBytes in [0, 262_145, 1.5] as [Any] {
            let rejected = try await h.call("session.readOutput", ["id": session, "view": "stream", "maxBytes": maxBytes])
            XCTAssertEqual((rejected["error"] as? [String: Any])?["code"] as? Int, -32602)
        }
        let maximum = try result(try await h.call("session.readOutput", ["id": session, "view": "stream", "maxBytes": 262_144]))
        XCTAssertNotNil(maximum["nextCursor"])
        let garbage = try await h.code("session.readOutput", ["id": session, "view": "stream", "cursor": "oc1_nope"])
        XCTAssertEqual(garbage, "INVALID_CURSOR")

        // A cursor from another session, or from before a restart, is rejected.
        let foreign = OutputCursor(token: cursor).map { OutputCursor(instanceID: $0.instanceID, sessionID: UUID(), offset: 0).token } ?? ""
        let foreignCode = try await h.code("session.readOutput", ["id": session, "view": "stream", "cursor": foreign])
        XCTAssertEqual(foreignCode, "INVALID_CURSOR")
        _ = try await h.code("session.restart", ["paneId": pane.uuidString, "allowRunning": true])
        let restarted = try XCTUnwrap(h.model.terminals[pane]?.sessionID.uuidString)
        XCTAssertNotEqual(restarted, session)
        let stale = try await h.code("session.readOutput", ["id": restarted, "view": "stream", "cursor": cursor])
        XCTAssertEqual(stale, "INVALID_CURSOR")
        XCTAssertFalse(h.model.outputJournal.contains(session: UUID(uuidString: session)!), "Replaced sessions drop their retained output")
    }
}
