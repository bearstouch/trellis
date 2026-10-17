import XCTest
@testable import TrellisCore

final class RemoteControlSettingsTests: XCTestCase {
    func testDefaultsAreOffOnLoopback() {
        let settings = RemoteControlSettings()
        XCTAssertFalse(settings.mcpEnabled)
        XCTAssertEqual(settings.bindAddress, "127.0.0.1")
        XCTAssertEqual(settings.port, 7777)
        XCTAssertTrue(settings.isValid)
        XCTAssertTrue(settings.isLoopback)
        XCTAssertEqual(settings.endpointURL, "http://127.0.0.1:7777/mcp")
    }

    func testValidationAcceptsOnlyIPLiteralsAndUnprivilegedPorts() {
        for address in ["127.0.0.1", "0.0.0.0", "192.168.1.20", "::1", "::", "fd00::1"] {
            XCTAssertTrue(RemoteControlSettings(bindAddress: address).isValid, address)
        }
        for address in ["", "localhost", "example.com", "127.0.0.1:80", "fe80::1%en0", "1.2.3", " 127.0.0.1"] {
            XCTAssertFalse(RemoteControlSettings(bindAddress: address).isValid, address)
        }
        XCTAssertFalse(RemoteControlSettings(port: 80).isValid)
        XCTAssertFalse(RemoteControlSettings(port: 0).isValid)
        XCTAssertTrue(RemoteControlSettings(port: 1024).isValid)
        XCTAssertTrue(RemoteControlSettings(port: 65_535).isValid)
    }

    func testLoopbackClassification() {
        XCTAssertTrue(RemoteControlSettings(bindAddress: "127.0.0.2").isLoopback)
        XCTAssertTrue(RemoteControlSettings(bindAddress: "::1").isLoopback)
        XCTAssertFalse(RemoteControlSettings(bindAddress: "0.0.0.0").isLoopback, "Wildcard binds are network binds")
        XCTAssertFalse(RemoteControlSettings(bindAddress: "::").isLoopback)
        XCTAssertFalse(RemoteControlSettings(bindAddress: "10.0.0.5").isLoopback)
    }

    func testIPv6EndpointIsBracketed() {
        XCTAssertEqual(RemoteControlSettings(bindAddress: "::1", port: 9000).endpointURL, "http://[::1]:9000/mcp")
    }

    func testRoundTripsThroughWorkspaceSettings() throws {
        let remote = RemoteControlSettings(mcpEnabled: true, bindAddress: "::1", port: 8123)
        let settings = WorkspaceSettings(shell: "/bin/zsh", directory: "/tmp", remoteControl: remote)
        let decoded = try JSONDecoder().decode(WorkspaceSettings.self, from: try JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.remoteControl, remote)
    }

    func testWorkspaceSavedBeforeRemoteControlLoadsWithServerOff() throws {
        let legacy = #"{"shell":"/bin/zsh","directory":"/tmp"}"#
        let decoded = try JSONDecoder().decode(WorkspaceSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.remoteControl, RemoteControlSettings())
    }

    func testUnusableSavedValueTurnsTheServerOffWithoutFailingTheWorkspace() throws {
        for remote in [#"{"mcpEnabled":true,"bindAddress":"evil.example","port":7777}"#, #"{"mcpEnabled":true,"port":80}"#, #"{"mcpEnabled":"yes"}"#, #"[]"#] {
            let json = #"{"shell":"/bin/zsh","directory":"/tmp","remoteControl":"# + remote + "}"
            let decoded = try JSONDecoder().decode(WorkspaceSettings.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.remoteControl, RemoteControlSettings(), remote)
            XCTAssertFalse(decoded.remoteControl.mcpEnabled)
        }
    }

    func testInterfaceListExcludesLoopbackAndLinkLocal() {
        for entry in NetworkInterfaceAddress.current() {
            XCTAssertNotNil(IPAddressLiteral(entry.address), entry.address)
            XCTAssertFalse(IPAddressLiteral(entry.address)?.isLoopback ?? true)
            XCTAssertFalse(entry.address.lowercased().hasPrefix("fe80"))
        }
    }
}
