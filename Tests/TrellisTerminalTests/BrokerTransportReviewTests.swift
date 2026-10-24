import Darwin
import Foundation
import XCTest
@testable import TrellisBroker
@testable import TrellisCore
@testable import TrellisTerminal

/// Reads frames from the fake broker's end until one control request arrives.
private func readBrokerRequest(_ fd: Int32) -> BrokerEnvelope? {
    var decoder = BrokerFrameDecoder()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        guard let frames = try? decoder.append(Data(buffer[0..<count])) else { return nil }
        if let envelope = frames.first(where: { $0.kind == .control })?.envelope, envelope.requestID != nil { return envelope }
    }
}

/// Review-driven: a broker transport driven over a socket pair standing in for the broker (FR-R03).
@MainActor
final class BrokerTransportReviewTests: XCTestCase {
    private var peer: Int32 = -1

    override func tearDown() async throws {
        if peer >= 0 { Darwin.close(peer); peer = -1 }
    }

    private func makeConnection() throws -> BrokerConnection {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        peer = fds[1]
        return BrokerConnection(fd: fds[0])
    }

    private func write(_ frames: [BrokerFrame]) {
        let data = frames.reduce(into: Data()) { $0.append($1.encoded) }
        data.withUnsafeBytes { _ = Darwin.write(peer, $0.baseAddress, data.count) }
    }

    func testAnExitInTheSameReadAsTheSpawnReplyIsReported() async throws {
        let connection = try makeConnection()
        let sessionID = UUID()
        let transport = BrokerSessionTransport(sessionID: sessionID, connection: connection, delivering: true)
        var exits: [Int32?] = []
        transport.onExit = { exits.append($0) }
        let launch = ValidatedLocalLaunch(executable: "/usr/bin/false", arguments: [], directory: "/", environment: [:])
        let peer = self.peer
        let request = Task.detached { readBrokerRequest(peer) }
        let launched = Task { try await transport.launch(launch, size: try TerminalSize(columns: 80, rows: 24)) }
        let received = await request.value
        let envelope = try XCTUnwrap(received)
        // Reply and exit in one write, as a process that exits at once can produce.
        write([
            try BrokerFrame.control(BrokerEnvelope(requestID: envelope.requestID, message: .spawned(sessionID: sessionID, processID: 4242))),
            try BrokerFrame.control(BrokerEnvelope(requestID: nil, message: .exited(sessionID: sessionID, waitStatus: 1 << 8)))
        ])
        let pid = try await launched.value
        XCTAssertEqual(pid, 4242)
        XCTAssertEqual(exits, [1], "the exit is reported, not dropped")
        XCTAssertFalse(transport.isRunning, "an exited session is never left running")
        connection.close()
    }

    func testAnExitInTheSameReadAsTheAttachReplyIsHeldForDelivery() async throws {
        let connection = try makeConnection()
        let sessionID = UUID()
        let transport = BrokerSessionTransport(sessionID: sessionID, connection: connection, delivering: false)
        var exits: [Int32?] = []
        transport.onExit = { exits.append($0) }
        let peer = self.peer
        let request = Task.detached { readBrokerRequest(peer) }
        let size = try TerminalSize(columns: 80, rows: 24)
        let attached = Task { await transport.attach(size: size) }
        let received = await request.value
        let envelope = try XCTUnwrap(received)
        let record = BrokerSessionRecord(sessionID: sessionID, processID: 4242, running: true, waitStatus: nil)
        write([
            try BrokerFrame.control(
                BrokerEnvelope(requestID: envelope.requestID, message: .attached(BrokerAttachment(record: record, nonce: nil, passwordPrompt: false, truncated: false)))),
            try BrokerFrame.control(BrokerEnvelope(requestID: nil, message: .exited(sessionID: sessionID, waitStatus: 0)))
        ])
        let attachment = await attached.value
        XCTAssertNotNil(attachment)
        XCTAssertFalse(transport.isRunning)
        XCTAssertEqual(exits, [], "output and exit wait for delivery to begin")
        transport.beginDelivery()
        XCTAssertEqual(exits, [0])
        connection.close()
    }
}
