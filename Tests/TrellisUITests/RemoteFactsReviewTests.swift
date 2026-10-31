import Darwin
import Foundation
import TrellisBroker
import XCTest

@testable import TrellisUI

/// Review-driven: a host's file facts over a socket pair standing in for its helper (FR-RW11).
@MainActor
final class RemoteFactsReviewTests: XCTestCase {
    func testAnAnswerTooLargeForAFrameIsAskedForInHalves() async throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let connection = BrokerConnection(fd: fds[0])
        let peer = fds[1]
        defer { connection.close(); Darwin.close(peer) }
        // The helper refuses any multi-path answer as too large, and answers single paths.
        let helper = Task.detached { () -> Int in
            var decoder = BrokerFrameDecoder(), buffer = [UInt8](repeating: 0, count: 65_536), requests = 0
            while true {
                let count = read(peer, &buffer, buffer.count)
                guard count > 0, let frames = try? decoder.append(Data(buffer[0..<count])) else { return requests }
                for frame in frames {
                    guard let envelope = frame.envelope, case .stat(let paths) = envelope.message else { continue }
                    requests += 1
                    let message: BrokerMessage =
                        paths.count > 1
                        ? .failed(code: "TOO_LARGE", errno: 0) : .pathInfo(paths.map { BrokerPathInfo(path: $0, kind: .directory, owned: true, size: 0, realPath: $0) })
                    let reply = try! BrokerFrame.control(BrokerEnvelope(requestID: envelope.requestID, message: message)).encoded
                    reply.withUnsafeBytes { _ = write(peer, $0.baseAddress, reply.count) }
                }
            }
        }
        let paths = (0..<5).map { "/srv/project-\($0)" }
        let found = await RemoteFacts(connection: connection).evaluate { lookup in paths.filter(lookup.isDirectory) }
        XCTAssertEqual(found, paths, "Every path is answered, one half at a time")
        shutdown(peer, SHUT_RDWR)
        let requests = await helper.value
        XCTAssertEqual(requests, 9, "5 paths: 1 + 2 + 2 + 4 halves, each halving only what was refused")
    }

    func testStatRequestsAreChunkedBySize() {
        XCTAssertLessThanOrEqual(RemoteFacts.statBytes * 6 + BrokerProtocol.statLimit * 16, BrokerProtocol.frameLimit, "Escaped as JSON, a full chunk still fits a frame")
    }
}
