import Darwin
import Foundation
import TrellisBroker
import TrellisCore
import XCTest

@testable import TrellisTerminal

/// The link against a real sshd and the static Linux helper (FR-RW02, FR-RW03, FR-RW06, FR-RW17). Opt-in: run
/// `scripts/test-remote-docker.sh`, which starts a disposable host and sets the environment; skipped otherwise, and a
/// skipped run is never counted as this check passing.
@MainActor
final class RemoteDockerTests: XCTestCase {
    private var destination = ""
    private var options: [String] = []
    private var catalog = RemoteArtifactCatalog(artifacts: [:])
    private let clientID = RemoteClientIdentity.randomHex()

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let destination = environment["TRELLIS_REMOTE_TEST_DESTINATION"], let helpers = environment["TRELLIS_REMOTE_TEST_HELPERS"] else {
            throw XCTSkip("Run scripts/test-remote-docker.sh to test against a real SSH host.")
        }
        self.destination = destination
        options = (environment["TRELLIS_REMOTE_TEST_OPTIONS"] ?? "").split(separator: " ").map(String.init)
        catalog = RemoteArtifactCatalog.load(remoteDirectory: URL(fileURLWithPath: helpers), macHelper: nil)
    }

    private func link() -> RemoteHostLink {
        let environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("TRELLIS_") }
        let link = RemoteHostLink(
            request: .init(sshExecutable: "/usr/bin/ssh", options: options, destination: destination, environment: environment, clientID: clientID), catalog: catalog)
        link.confirmInstall = { _, _ in true }
        return link
    }

    func testInstallRunAndResumeASessionOnALinuxHost() async throws {
        let first = try await link().run(.check, install: .never).get()
        XCTAssertEqual(first.system, "Linux")
        XCTAssertEqual(RemoteHelperRecord(probe: first, catalog: catalog, checkedAt: Date()).state, .missing, "A fresh host has no helper")

        let bridge = link()
        _ = try await bridge.run(.bridge, install: .ask).get()
        let connection = try XCTUnwrap(bridge.connection)
        XCTAssertEqual(connection.hostInfo?.os, "linux")
        let sink = Sink()
        let session = UUID()
        connection.register(sink, sessionID: session)
        let spawned = try await connection.request(
            .spawnLogin(BrokerLoginRequest(sessionID: session, shell: nil, directory: nil, environment: ["TERM": "xterm-256color"], integration: nil, columns: 100, rows: 30)))
        guard case .spawned = spawned else { return XCTFail("\(spawned)") }
        try connection.sendInput(Data("echo remote-$((6*7))\n".utf8), sessionID: session)
        try await wait { sink.text.contains("remote-42") }
        // The echo of the typed line arrives at once; its result, a second later, only after the link is gone.
        try connection.sendInput(Data("sleep 1; echo after-$((1+1))-link\n".utf8), sessionID: session)
        try await wait { sink.text.contains("$((1+1))-link") }
        let shown = UInt64(sink.output.count)
        bridge.close()
        XCTAssertEqual(bridge.state, .closed, "Closing the link sends nothing to the host's sessions")

        try await Task.sleep(for: .seconds(2))
        let again = link()
        _ = try await again.run(.bridge, install: .never).get()
        let resumed = try XCTUnwrap(again.connection)
        guard case .sessions(let records) = try await resumed.request(.list) else { return XCTFail("No listing") }
        XCTAssertEqual(records.first { $0.sessionID == session }?.running, true, "The session kept running without the link")
        let later = Sink()
        resumed.register(later, sessionID: session)
        guard case .attached(let attachment) = try await resumed.request(.attach(sessionID: session, columns: 100, rows: 30, since: shown)) else {
            return XCTFail("Not attached")
        }
        XCTAssertEqual(attachment.resumed, true)
        XCTAssertTrue(String(decoding: later.replay, as: UTF8.self).contains("after-2-link"))
        XCTAssertFalse(String(decoding: later.replay, as: UTF8.self).contains("remote-42"), "Output already shown isn't sent again")
        resumed.sendStopAll()
        try await Task.sleep(for: .milliseconds(500))
        again.close()

        _ = try await link().run(.remove, install: .never).get()
        let gone = try await link().run(.check, install: .never).get()
        XCTAssertTrue(gone.installed.isEmpty, "Remove leaves no helper behind")
    }

    private func wait(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

@MainActor
private final class Sink: BrokerSessionSink {
    var output = Data(), replay = Data()
    var text: String { String(decoding: output, as: UTF8.self) }
    func brokerOutput(_ data: Data) { output.append(data) }
    func brokerReplay(_ data: Data) { replay.append(data) }
    func brokerExited(waitStatus: Int32) {}
    func brokerPrompt(_ active: Bool) {}
    func brokerDisconnected() {}
    func brokerInputRejected() {}
}
