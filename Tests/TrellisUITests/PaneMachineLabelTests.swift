import AppKit
import TrellisCore
import XCTest

@testable import TrellisUI

/// What the pane header and the bottom bar say about a pane's machine (FR-RW05, FR-RW07).
final class PaneMachineLabelTests: XCTestCase {
    func testLocalAndSSHHaveTheirOwnSymbolsAndNoLinkText() {
        XCTAssertEqual(PaneMachine.local.name, "Local")
        XCTAssertEqual(PaneMachine.local.symbol, "laptopcomputer")
        XCTAssertEqual(PaneMachine.local.tone, .local)
        XCTAssertEqual(PaneMachine.ssh.name, "SSH")
        XCTAssertEqual(PaneMachine.ssh.symbol, "network")
        XCTAssertEqual(PaneMachine.ssh.tone, .remote)
        XCTAssertEqual(PaneMachine.local.linkText + PaneMachine.ssh.linkText, "")
    }

    func testConnectedHostShowsAServerAndNoLinkText() {
        let machine = PaneMachine.host("build-box", link: .connected)
        XCTAssertEqual(machine.name, "build-box")
        XCTAssertEqual(machine.symbol, "server.rack")
        XCTAssertEqual(machine.linkText, "")
        XCTAssertEqual(machine.tone, .remote)
    }

    func testAHostThatIsNotConnectedNamesItsLinkInWordsWithTheLinkSymbol() {
        let links: [(RemoteLinkDisplay, PaneMachine.Tone)] = [
            (.connecting, .remote), (.reconnecting(attempt: 2, at: Date(timeIntervalSince1970: 0)), .linkDown), (.offline, .linkDown),
            (.needsInput("A password"), .linkDown), (.disconnected(nil), .linkDown)
        ]
        for (link, tone) in links {
            let machine = PaneMachine.host("build-box", link: link)
            XCTAssertEqual(machine.name, "build-box", "The name stays apart, so a narrow pane shortens only it")
            XCTAssertEqual(machine.linkText, " · " + link.label)
            XCTAssertEqual(machine.symbol, link.symbol)
            XCTAssertEqual(machine.tone, tone, link.label)
        }
    }

    func testAHostNamedLikeAKindIsStillAHost() {
        for name in ["Local", "SSH"] {
            XCTAssertNotEqual(PaneMachine.host(name, link: .connected), .local)
            XCTAssertNotEqual(PaneMachine.host(name, link: .connected), .ssh)
        }
    }

    @MainActor
    func testFocusedMachineFollowsTheSelectedWindowAndItsLink() async throws {
        _ = NSApplication.shared
        let host = UUID()
        let store = try WorkspaceStore()
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "trellis.tests.\(UUID())"))
        let model = AppWorkspaceModel(store: store, preferences: preferences)
        XCTAssertEqual(model.focusedMachine, .local, "No window yet")

        let local = try await store.execute(.createWindow(name: "Here")).snapshot.windows[0].id
        let remote = try await store.execute(.createRemoteWindow(name: "There", hostID: host)).snapshot.windows.first { $0.id != local }!.id
        await model.refresh()

        await model.selectWindow(local)
        XCTAssertEqual(model.focusedMachine, .local)

        await model.selectWindow(remote)
        XCTAssertEqual(model.focusedMachine, .host(model.remoteHostName(host), link: .disconnected(nil)), "No link recorded yet is not connected")
        model.remoteLinks[host] = .connected
        XCTAssertEqual(model.focusedMachine, .host(model.remoteHostName(host), link: .connected))
    }
}
