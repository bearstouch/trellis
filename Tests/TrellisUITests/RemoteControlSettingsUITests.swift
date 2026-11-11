import AppKit
import XCTest
import TrellisControl
import TrellisCore
import TrellisMCP
@testable import TrellisUI

final class RemoteControlSettingsUITests: XCTestCase {
    @MainActor
    func testApplyPersistsRestoresAndNotifies() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-remote-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppWorkspaceModel(store: try WorkspaceStore(), persistence: WorkspacePersistence(directory: directory))
        _ = await model.loadWorkspace()
        await model.createSpace(startSession: false)
        var applied: [RemoteControlSettings] = []
        model.onRemoteControlSettingsChanged = { applied.append($0) }
        let settings = RemoteControlSettings(mcpEnabled: true, bindAddress: "::1", port: 8124)
        XCTAssertTrue(model.applyRemoteControl(settings))
        XCTAssertEqual(model.remoteControl, settings)
        XCTAssertEqual(applied, [settings])
        let saved = await model.flushWorkspaceSave()
        XCTAssertTrue(saved)

        let restored = AppWorkspaceModel(store: try WorkspaceStore(), persistence: WorkspacePersistence(directory: directory))
        var restoredApplied: [RemoteControlSettings] = []
        restored.onRemoteControlSettingsChanged = { restoredApplied.append($0) }
        _ = await restored.loadWorkspace()
        XCTAssertEqual(restored.remoteControl, settings)
        XCTAssertEqual(restoredApplied, [settings], "Restoring starts the server with the saved settings")
    }

    @MainActor
    func testInvalidSettingsKeepThePreviousOnes() throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        let good = RemoteControlSettings(mcpEnabled: true, port: 9001)
        XCTAssertTrue(model.applyRemoteControl(good))
        var notified = false
        model.onRemoteControlSettingsChanged = { _ in notified = true }
        XCTAssertFalse(model.applyRemoteControl(RemoteControlSettings(mcpEnabled: true, bindAddress: "example.com")))
        XCTAssertFalse(model.applyRemoteControl(RemoteControlSettings(mcpEnabled: true, port: 22)))
        XCTAssertEqual(model.remoteControl, good)
        XCTAssertFalse(notified, "A rejected change never restarts the server")
    }

    /// FR-RC06: copied URLs and client setups follow sharing, and never carry a token.
    @MainActor
    func testClientURLFollowsTailscaleSharing() throws {
        _ = NSApplication.shared
        let model = AppWorkspaceModel(store: try WorkspaceStore())
        XCTAssertTrue(model.applyRemoteControl(RemoteControlSettings(mcpEnabled: true, bindAddress: "::1", port: 9001)))
        XCTAssertEqual(model.remoteControlClientURL, "http://[::1]:9001/mcp")
        XCTAssertTrue(model.applyRemoteControl(RemoteControlSettings(mcpEnabled: true, port: 9001, tailscaleShare: true)))
        XCTAssertEqual(model.remoteControlClientURL, "http://127.0.0.1:9001/mcp", "Until Tailscale reports the shared URL")
        model.tailscaleShareState = .shared(url: "https://studio.tail1a2b.ts.net:8443/mcp")
        XCTAssertEqual(model.remoteControlClientURL, "https://studio.tail1a2b.ts.net:8443/mcp")
        XCTAssertTrue(MCPClientSetup.claudeCode.snippet(url: model.remoteControlClientURL).contains("https://studio.tail1a2b.ts.net:8443/mcp"))
        XCTAssertTrue(model.applyRemoteControl(RemoteControlSettings(mcpEnabled: true, bindAddress: "0.0.0.0", port: 9001)))
        XCTAssertEqual(model.remoteControlClientURL, "http://127.0.0.1:9001/mcp", "A stale shared state is ignored once sharing is off")
    }

    @MainActor
    func testSharingSettingsPersistAndUnsafeOnesAreRejected() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-remote-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppWorkspaceModel(store: try WorkspaceStore(), persistence: WorkspacePersistence(directory: directory))
        _ = await model.loadWorkspace()
        await model.createSpace(startSession: false)
        let device = TailnetDevice(id: "nBuild", name: "build-server", addresses: ["100.70.9.3"])
        let shared = RemoteControlSettings(mcpEnabled: true, tailscaleShare: true, tailscalePort: 10_000, allowedDevices: [device])
        XCTAssertTrue(model.applyRemoteControl(shared))
        XCTAssertFalse(model.applyRemoteControl(RemoteControlSettings(mcpEnabled: true, bindAddress: "0.0.0.0", tailscaleShare: true)), "Sharing needs loopback")
        XCTAssertFalse(model.applyRemoteControl(RemoteControlSettings(mcpEnabled: true, tailscaleShare: true, tailscalePort: 8080)))
        XCTAssertEqual(model.remoteControl, shared)
        let saved = await model.flushWorkspaceSave()
        XCTAssertTrue(saved)
        let restored = AppWorkspaceModel(store: try WorkspaceStore(), persistence: WorkspacePersistence(directory: directory))
        _ = await restored.loadWorkspace()
        XCTAssertEqual(restored.remoteControl, shared)
    }

    @MainActor
    func testEveryShareErrorHasText() {
        let errors: [TailscaleShareError] = [
            .tailscale(.notInstalled), .tailscale(.notRunning), .tailscale(.timedOut), .tailscale(.malformed), .tailscale(.failed("x")),
            .notConnected(.notInstalled), .notConnected(.stopped), .notConnected(.needsLogin), .notConnected(.connected), .httpsDisabled, .portInUse(8443),
            .funnelOn(443), .consentRequired(URL(string: "https://login.tailscale.com/f/serve")!)
        ]
        for error in errors { XCTAssertFalse(RemoteControlSettingsView.message(error).isEmpty, "\(error)") }
        XCTAssertTrue(RemoteControlSettingsView.message(.portInUse(8443)).contains("8443"))
    }

    /// INT-07: MCP tools drive the real model through the same authorizer and service as the socket.
    @MainActor
    func testMCPToolsDriveTheWorkspaceEndToEnd() async throws {
        let h = try Harness()
        defer { h.discardPreferences() }
        let token = try await h.grants.create(name: "mcp", capabilities: Set(Capability.allCases), spaceScope: .all, hostScope: .all, lifetime: 3600).token
        let endpoint = MCPEndpoint(handler: h.handler, serverVersion: "test", loopbackOnly: true)
        func post(_ body: [String: Any], session: String?) async throws -> HTTPResponse {
            var headers = ["Host": "127.0.0.1", "Content-Type": "application/json", "Authorization": "Bearer \(token)"]
            if let session { headers["Mcp-Session-Id"] = session }
            return await endpoint.handle(HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: try JSONSerialization.data(withJSONObject: body)))
        }
        let initialized = try await post(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]], session: nil)
        let session = try XCTUnwrap(initialized.header("Mcp-Session-Id"))
        var nextID = 2
        func tool(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
            nextID += 1
            let response = try await post(["jsonrpc": "2.0", "id": nextID, "method": "tools/call", "params": ["name": name, "arguments": arguments]], session: session)
            let result = try XCTUnwrap((try JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, false, "\(name): \(result)")
            return try XCTUnwrap(result["structuredContent"] as? [String: Any])
        }

        let created = try await tool("space_create", ["name": "From MCP"])
        XCTAssertTrue(h.model.snapshot.spaces.contains { $0.name == "From MCP" })
        let pane = try XCTUnwrap(((created["panes"] as? [[String: Any]])?.first)?["paneId"] as? String)
        defer {
            h.model.terminals.values.forEach {
                $0.requestTermination(force: true); $0.adapter.detach()
            }
        }
        _ = try await tool(
            "session_start",
            ["paneId": pane, "launch": ["kind": "process", "executable": "/bin/zsh", "arguments": ["-f", "-c", "echo MCP-READY; exec /bin/sleep 30"], "directory": "/tmp"]])
        let terminal = NativeTerminalHandle(try XCTUnwrap(h.model.terminals[try XCTUnwrap(UUID(uuidString: pane))]))
        try await terminal.waitFor("MCP-READY")
        let output = try await tool("session_read_output", ["id": terminal.native.sessionID.uuidString, "view": "screen"])
        XCTAssertTrue((output["text"] as? String ?? "").contains("MCP-READY"))
    }
}
