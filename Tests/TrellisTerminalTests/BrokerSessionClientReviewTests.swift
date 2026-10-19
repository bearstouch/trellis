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
}
