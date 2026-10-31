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
    func testHeldOutputPastTheCapKeepsTheNewestAfterAReset() async throws {
        let connection = try makeConnection()
        let sessionID = UUID()
        let transport = RemoteSessionTransport(sessionID: sessionID, hostID: UUID(), connection: connection)
        var shown = Data()
        transport.onOutput = { shown.append($0) }
        let peer = self.peer
        let request = Task.detached { readBrokerRequest(peer) }
        let size = try TerminalSize(columns: 80, rows: 24)
        let attached = Task { await transport.attach(size: size) }
        let asked = await request.value
        let envelope = try XCTUnwrap(asked)
        let record = BrokerSessionRecord(sessionID: sessionID, processID: 4242, running: true, waitStatus: nil)
        write([
            try BrokerFrame.control(
                BrokerEnvelope(requestID: envelope.requestID, message: .attached(BrokerAttachment(record: record, nonce: nil, passwordPrompt: false, truncated: false, offset: 0))))
        ])
        let attachment = await attached.value
        XCTAssertNotNil(attachment)
        // Adopted, not yet delivering: more than the cap arrives, chunk by chunk.
        let chunk = 65_536, chunks = OutputRing.sessionLimit / chunk + 8
        for index in 0..<chunks { transport.brokerOutput(Data(repeating: UInt8(index & 0xff), count: chunk)) }
        XCTAssertEqual(transport.received, UInt64(chunk * chunks), "Everything that arrived is accounted for")
        transport.beginDelivery()
        XCTAssertEqual(shown.prefix(RemoteSessionTransport.reset.count), RemoteSessionTransport.reset, "Dropped output is replaced by a reset, never a gap")
        XCTAssertEqual(shown.count - RemoteSessionTransport.reset.count, OutputRing.sessionLimit)
        XCTAssertEqual(shown.last, UInt8((chunks - 1) & 0xff), "The most recent output is kept")
        connection.close()
    }
    func testAHostsSessionsResumeInCappedBatches() async throws {
        let count = RemoteSessionTransport.resumeBatch + 2
        /// A broker end that answers attaches only once it holds the next of `batches`, so one-at-a-time attaches never
        /// complete; `held` records how many it held each time it answered.
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var held: [Int] = []
        }
        func broker(batches: [Int], seen: Seen) -> (BrokerConnection, Int32) {
            var fds: [Int32] = [0, 0]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
            let peer = fds[1]
            Thread.detachNewThread {
                var decoder = BrokerFrameDecoder(), buffer = [UInt8](repeating: 0, count: 4096), waiting: [(UInt64, UUID)] = [], batches = batches
                while let batch = batches.first {
                    // Once a batch is held, anything else already sent arrives within the grace period and is counted too.
                    var ready = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
                    if waiting.count >= batch, poll(&ready, 1, 200) == 0 {
                        seen.lock.lock(); seen.held.append(waiting.count); seen.lock.unlock()
                        for (id, session) in waiting {
                            let record = BrokerSessionRecord(sessionID: session, processID: 4242, running: true, waitStatus: nil)
                            let attachment = BrokerAttachment(record: record, nonce: nil, passwordPrompt: false, truncated: false, offset: 0, resumed: true)
                            let reply = try! BrokerFrame.control(BrokerEnvelope(requestID: id, message: .attached(attachment))).encoded
                            reply.withUnsafeBytes { _ = Darwin.write(peer, $0.baseAddress, reply.count) }
                        }
                        waiting = []; batches.removeFirst()
                        continue
                    }
                    let read = Darwin.read(peer, &buffer, buffer.count)
                    guard read > 0, let frames = try? decoder.append(Data(buffer[0..<read])) else { return }
                    for frame in frames {
                        if let envelope = frame.envelope, let id = envelope.requestID, case .attach(let session, _, _, _) = envelope.message { waiting.append((id, session)) }
                    }
                }
            }
            return (BrokerConnection(fd: fds[0]), peer)
        }
        let setup = Seen(), resumed = Seen()
        let (first, firstPeer) = broker(batches: Array(repeating: 1, count: count), seen: setup)
        let (next, nextPeer) = broker(batches: [RemoteSessionTransport.resumeBatch, 2], seen: resumed)
        defer {
            // Shut down first, so the broker threads' reads end before their descriptors can be reused.
            shutdown(firstPeer, SHUT_RDWR); shutdown(nextPeer, SHUT_RDWR)
            first.close(); next.close(); Darwin.close(firstPeer); Darwin.close(nextPeer)
        }
        let size = try TerminalSize(columns: 80, rows: 24)
        var transports: [RemoteSessionTransport] = []
        for _ in 0..<count {
            let transport = RemoteSessionTransport(sessionID: UUID(), hostID: UUID(), connection: first)
            let attached = await transport.attach(size: size)
            XCTAssertNotNil(attached)
            transport.beginDelivery()
            transport.brokerDisconnected()
            transports.append(transport)
        }
        let results = await RemoteSessionTransport.resume(transports.map { ($0, size) }, on: next)
        XCTAssertEqual(results, Array(repeating: true, count: count), "Each batch was sent whole before any answer")
        XCTAssertEqual(resumed.held, [RemoteSessionTransport.resumeBatch, 2], "Never more than a batch in flight, so replies don't queue past their timeout")
        XCTAssertTrue(transports.allSatisfy { !$0.linkLost && $0.connection === next })
    }
}
