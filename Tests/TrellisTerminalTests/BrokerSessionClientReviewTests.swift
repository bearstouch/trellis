import Darwin
import Foundation
import TrellisBroker
import XCTest
@testable import TrellisTerminal

/// Review-driven: the app's broker client against the built `trellis-broker` (FR-R03).
@MainActor
final class BrokerSessionClientReviewTests: XCTestCase {
    private var launcher: BrokerLauncher?
    private var held: BrokerConnection?

    override func tearDown() async throws {
        held?.sendStopAll()
        try? await Task.sleep(for: .milliseconds(100))
        held?.close()
        held = nil
        if let launcher {
            if let path = launcher.discovery()?.socketPath, let connection = try? BrokerConnection.connect(socketPath: path, brokerExecutable: launcher.helperPath) {
                connection.sendStopAll()
                try? await Task.sleep(for: .milliseconds(100))
                connection.close()
            }
            try? FileManager.default.removeItem(at: launcher.stateDirectory)
        }
        launcher = nil
    }

    private func makeLauncher() throws -> BrokerLauncher {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(BrokerProtocol.helperName).path
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("Run `swift build` first to build \(BrokerProtocol.helperName).") }
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("trellis-broker-client-\(UUID())")
        let made = BrokerLauncher(stateDirectory: state, helperPath: helper, clientPath: try XCTUnwrap(BrokerLauncher.currentExecutable()), idleExit: 5)
        launcher = made
        return made
    }

    func testABrokerThatTurnsUsAwayIsNeverReplacedByASecondOne() async throws {
        let launcher = try makeLauncher()
        let socket = try launcher.spawn()
        launcher.publish(socketPath: socket)
        // Another client holds the broker's only slot, as a just-quit app can for a moment.
        let deadline = Date().addingTimeInterval(3)
        while held == nil, Date() < deadline {
            if let connection = try? BrokerConnection.connect(socketPath: socket, brokerExecutable: launcher.helperPath), (try? await connection.hello()) != nil {
                held = connection
            } else {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTAssertNotNil(held)

        let client = BrokerSessionClient(launcher: launcher)
        let ready = await client.prepare()
        XCTAssertFalse(ready, "A live broker that refused us is not ready, and no second broker is started")
        XCTAssertEqual(launcher.discovery()?.socketPath, socket, "broker.json still names the live broker, so its sessions stay reachable")
        let listing = await client.existingSessions()
        XCTAssertNil(listing)
    }

    func testABrokerFromAnotherHelperPathIsNeverReplaced() async throws {
        let launcher = try makeLauncher()
        let socket = try launcher.spawn()
        launcher.publish(socketPath: socket)
        // The same helper at another path, as after moving the app or App Translocation.
        let moved = launcher.stateDirectory.deletingLastPathComponent().appendingPathComponent("moved-\(UUID())")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: moved) }
        let copy = moved.appendingPathComponent(BrokerProtocol.helperName).path
        try FileManager.default.copyItem(atPath: launcher.helperPath, toPath: copy)
        let elsewhere = BrokerLauncher(stateDirectory: launcher.stateDirectory, helperPath: copy, clientPath: try XCTUnwrap(BrokerLauncher.currentExecutable()), idleExit: 2)

        let client = BrokerSessionClient(launcher: elsewhere)
        let ready = await client.prepare()
        XCTAssertFalse(ready, "A live broker we can't verify is not used, and no second broker is started")
        XCTAssertEqual(launcher.discovery()?.socketPath, socket, "broker.json still names the live broker, so its sessions stay reachable")
        let listing = await client.existingSessions()
        XCTAssertNil(listing)
    }

    /// Settings → Sessions: the status never starts a broker, names a busy one, and describes a connected one.
    func testStatusReportsWithoutStartingABroker() async throws {
        let launcher = try makeLauncher()
        let idle = BrokerSessionClient(launcher: launcher)
        let none = await idle.status()
        XCTAssertEqual(none, .notRunning)
        XCTAssertNil(launcher.discovery(), "Asking for the status started nothing")

        let client = BrokerSessionClient(launcher: launcher)
        let ready = await client.prepare()
        XCTAssertTrue(ready)
        guard case .connected(let details) = await client.status() else { return XCTFail("No status") }
        XCTAssertGreaterThan(details.processID, 0)
        XCTAssertEqual(details.protocolVersion, BrokerProtocol.version)
        XCTAssertEqual(details.running, 0)
        XCTAssertEqual(details.socketPath, launcher.discovery()?.socketPath)
        XCTAssertEqual(details.clientPath, launcher.clientPath)
        await client.detach()

        // Another client holding the broker's only slot shows as busy.
        held = try BrokerConnection.connect(socketPath: try XCTUnwrap(launcher.discovery()?.socketPath), brokerExecutable: launcher.helperPath)
        _ = try await held?.hello()
        let other = await BrokerSessionClient(launcher: launcher).status()
        XCTAssertEqual(other, .busy)
    }
}
