import Foundation
import XCTest
@testable import TrellisBroker

final class BrokerProtocolTests: XCTestCase {
    func testFramesRoundTripAcrossArbitrarySplits() throws {
        let id = UUID()
        let frames = [
            try BrokerFrame.control(BrokerEnvelope(requestID: 7, message: .attach(sessionID: id, columns: 80, rows: 24))),
            BrokerFrame(kind: .output, payload: Data((0..<300).map { UInt8($0 % 256) })), BrokerFrame(kind: .stopAll, payload: Data())
        ]
        let bytes = frames.reduce(Data()) { $0 + $1.encoded }
        for step in [1, 3, 7, bytes.count] {
            var decoder = BrokerFrameDecoder(), decoded: [BrokerFrame] = []
            var offset = 0
            while offset < bytes.count {
                decoded += try decoder.append(bytes[offset..<min(offset + step, bytes.count)])
                offset += step
            }
            XCTAssertEqual(decoded, frames, "split every \(step) bytes")
        }
        XCTAssertEqual(frames[0].envelope, BrokerEnvelope(requestID: 7, message: .attach(sessionID: id, columns: 80, rows: 24)))
    }

    func testOversizedAndUnknownFramesAreRejected() {
        var decoder = BrokerFrameDecoder()
        var length = UInt32(BrokerProtocol.frameLimit + 1).bigEndian
        XCTAssertThrowsError(try decoder.append(Data(bytes: &length, count: 4))) { XCTAssertEqual($0 as? BrokerFrameError, .oversized) }
        var empty = BrokerFrameDecoder()
        XCTAssertThrowsError(try empty.append(Data([0, 0, 0, 0]))) { XCTAssertEqual($0 as? BrokerFrameError, .oversized) }
        var unknown = BrokerFrameDecoder()
        XCTAssertThrowsError(try unknown.append(Data([0, 0, 0, 1, 42]))) { XCTAssertEqual($0 as? BrokerFrameError, .unknownKind) }
    }

    func testStreamsAreChunkedAndCarryTheirSession() throws {
        let id = UUID()
        let bytes = Data(repeating: 0x41, count: BrokerProtocol.chunkLimit * 2 + 5)
        let frames = BrokerFrame.stream(.replay, sessionID: id, bytes: bytes)
        XCTAssertEqual(frames.map { $0.payload.count - 16 }, [BrokerProtocol.chunkLimit, BrokerProtocol.chunkLimit, 5])
        XCTAssertTrue(frames.allSatisfy { $0.stream?.sessionID == id && $0.kind == .replay })
        XCTAssertEqual(frames.compactMap { $0.stream?.bytes }.reduce(Data(), +), bytes)
        XCTAssertNil(BrokerFrame(kind: .output, payload: Data(count: 4)).stream, "A stream frame needs a whole session ID")
    }

    func testExitCodesMatchTheLocalPTYDecoding() {
        XCTAssertEqual(BrokerSessionRecord.exitCode(3 << 8), 3)
        XCTAssertEqual(BrokerSessionRecord.exitCode(SIGHUP), 128 + SIGHUP)
        XCTAssertEqual(BrokerSessionRecord(sessionID: UUID(), processID: 9, running: true, waitStatus: nil).exitCode, nil)
    }
}

final class OutputRingTests: XCTestCase {
    func testUntruncatedReplayIsExactlyTheOutput() {
        var ring = OutputRing(limit: 64)
        ring.append(Data("one\r\n\u{1b}[?2004htwo".utf8))
        XCTAssertFalse(ring.truncated)
        XCTAssertEqual(ring.replay, Data("one\r\n\u{1b}[?2004htwo".utf8))
    }

    func testTruncatedReplayResetsRestoresModesAndStartsAtALine() {
        var ring = OutputRing(limit: 32)
        ring.append(Data("\u{1b}[?1049h\u{1b}[?25l".utf8))
        ring.append(Data(String(repeating: "x", count: 40).utf8))
        ring.append(Data("partial line\nwhole line".utf8))
        XCTAssertTrue(ring.truncated)
        XCTAssertLessThanOrEqual(ring.count, 32 + 4)
        XCTAssertEqual(String(decoding: ring.replay, as: UTF8.self), "\u{1b}c\u{1b}[?1049h\u{1b}[?25lwhole line")
    }

    func testModesChangedInsideTheDroppedPartialLineStillCount() {
        var ring = OutputRing(limit: 16)
        ring.append(Data(String(repeating: "y", count: 20).utf8))
        ring.append(Data("ab\u{1b}[?2004h\ntail".utf8))
        XCTAssertEqual(String(decoding: ring.replay, as: UTF8.self), "\u{1b}c\u{1b}[?2004htail")
    }

    func testReplayNeverExceedsTheLimit() {
        var ring = OutputRing(limit: 100)
        ring.append(Data(repeating: 0x7a, count: 110))
        XCTAssertGreaterThan(ring.count, 100, "Trimming happens in steps")
        XCTAssertEqual(ring.replay, Data("\u{1b}c".utf8) + Data(repeating: 0x7a, count: 100), "Without a line break the cut output is kept")
    }

    func testBudgetTrimsTheLargestRingFirst() {
        var rings = ["big": OutputRing(limit: 1 << 20), "small": OutputRing(limit: 1 << 20)]
        rings["big"]?.append(Data(count: 300_000))
        rings["small"]?.append(Data(count: 10_000))
        OutputBudget.enforce(&rings, total: 200_000)
        XCTAssertEqual(rings["small"]?.count, 10_000)
        XCTAssertLessThanOrEqual(rings.values.reduce(0) { $0 + $1.count }, 200_000)
        XCTAssertEqual(rings["big"]?.truncated, true)
    }
}

final class ModeTrackerTests: XCTestCase {
    func testTracksSetsResetsAndSequencesSplitAcrossChunks() {
        var modes = ModeTracker()
        for byte in Array("\u{1b}[?1;1000;1006h\u{1b}[?25l\u{1b}[?1000l\u{1b}[?9999h\u{1b}[31m".utf8) { modes.feed([byte]) }
        XCTAssertEqual(modes.enabled, [1, 1006])
        XCTAssertEqual(String(decoding: modes.assertion, as: UTF8.self), "\u{1b}[?1h\u{1b}[?1006h\u{1b}[?25l")
        modes.feed(Array("\u{1b}c".utf8))
        XCTAssertEqual(modes.enabled, [25], "RIS restores the defaults")
        XCTAssertTrue(modes.assertion.isEmpty)
    }
}

final class BrokerCoreTests: XCTestCase {
    func testOneClientAtATime() {
        var core = BrokerCore(idleExit: 30, now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(core.acceptClient())
        XCTAssertFalse(core.acceptClient(), "A second app is refused while the first is connected")
        core.clientDisconnected()
        XCTAssertTrue(core.acceptClient())
    }

    func testOnlyCloseSignalsAreAllowed() {
        XCTAssertEqual(BrokerCore.allowedSignals, [SIGHUP, SIGTERM, SIGKILL])
        for signal in [SIGSTOP, SIGINT, SIGUSR1, SIGWINCH, 0] { XCTAssertFalse(BrokerCore.permitsSignal(signal)) }
    }

    func testIdleExitWaitsForNoSessionsAndNoClient() {
        let start = Date(timeIntervalSince1970: 1000)
        var core = BrokerCore(idleExit: 30, now: start)
        core.update(runningSessions: 1, now: start)
        XCTAssertFalse(core.shouldExit(now: start + 100))
        core.update(runningSessions: 0, now: start + 100)
        XCTAssertFalse(core.shouldExit(now: start + 129))
        XCTAssertTrue(core.shouldExit(now: start + 130))
        _ = core.acceptClient()
        core.update(runningSessions: 0, now: start + 131)
        XCTAssertFalse(core.shouldExit(now: start + 500), "A connected app keeps the broker")
    }

    func testVersionMismatchIsRefused() {
        XCTAssertEqual(BrokerCore.hello(BrokerProtocol.version, brokerPID: 42), .welcome(protocolVersion: BrokerProtocol.version, brokerPID: 42))
        XCTAssertEqual(BrokerCore.hello(BrokerProtocol.version + 1, brokerPID: 42), .refused(reason: "PROTOCOL_VERSION_MISMATCH"))
    }

    func testHelloFeaturesStayCompatibleBothWays() throws {
        // An older app's hello has no features: it decodes, and gets no event it can't read.
        let old = try JSONDecoder().decode(BrokerEnvelope.self, from: Data(#"{"requestID":1,"message":{"hello":{"protocolVersion":1}}}"#.utf8))
        XCTAssertEqual(old.message, .hello(protocolVersion: 1, features: nil))
        // An older broker ignores keys it doesn't know, as this decoder does with a future one.
        let newer = try JSONDecoder().decode(
            BrokerEnvelope.self, from: Data(#"{"requestID":1,"message":{"hello":{"protocolVersion":1,"features":["inputRejected"],"later":true}}}"#.utf8))
        XCTAssertEqual(newer.message, .hello(protocolVersion: 1, features: ["inputRejected"]))
        let encoded = String(decoding: try JSONEncoder().encode(BrokerEnvelope(requestID: 1, message: .hello(protocolVersion: 1))), as: UTF8.self)
        XCTAssertFalse(encoded.contains("features"), encoded)
    }

    func testSignalsNeedOurOwnUnreapedGroupLeader() {
        let identity = BrokerProcessIdentity(pid: 50, parentPID: 10, groupID: 50, startedSeconds: 1, startedMicroseconds: 2)
        XCTAssertTrue(identity.permitsSignal(current: identity, ownerPID: 10))
        XCTAssertFalse(identity.permitsSignal(current: identity, ownerPID: 11), "Another parent")
        XCTAssertFalse(identity.permitsSignal(current: nil, ownerPID: 10), "Gone")
        let reused = BrokerProcessIdentity(pid: 50, parentPID: 10, groupID: 50, startedSeconds: 9, startedMicroseconds: 2)
        XCTAssertFalse(identity.permitsSignal(current: reused, ownerPID: 10), "A reused PID")
    }
}
