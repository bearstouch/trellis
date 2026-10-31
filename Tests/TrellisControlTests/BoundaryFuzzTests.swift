import Darwin
import XCTest
import TrellisCore
@testable import TrellisControl

/// Seeded mutation fuzzing of every external input boundary (NFR-R04). A
/// failure prints its seed and iteration so it can be replayed exactly.
final class BoundaryFuzzTests: XCTestCase {
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let seeds: [Data] = [
        Data(#"{"jsonrpc":"2.0","id":1,"method":"window.create","params":{"name":"x","idempotencyKey":"k"}}"#.utf8),
        Data(
            #"{"version":1,"windows":[{"key":"w","name":"W","tabs":[{"key":"t","title":"T","root":{"type":"split","key":"s","axis":"x","ratio":0.5,"children":[{"type":"pane","key":"a","launch":{"kind":"shell","directory":"~"}},{"type":"pane","key":"b","launch":{"kind":"host","hostId":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}}]}}]}]}"#
                .utf8),
        Data(##"{"version":1,"id":"my-theme","name":"Mine","appearance":"dark","terminal":{"background":"#101820","ansi":["#000000"]},"ui":{"accent":"#7CC7FF"}}"##.utf8),
        Data(#"{"format":"trellis.portable","version":1,"layout":{"version":1,"windows":[]},"hosts":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"h","destination":"h","port":22,"tags":["a"]}]}"#.utf8)
    ]

    private func mutate(_ data: Data, _ random: inout Generator) -> Data {
        var bytes = [UInt8](data)
        let interesting: [UInt8] = [0x00, 0x0A, 0x22, 0x5C, 0x7B, 0x7D, 0x5B, 0x5D, 0x2C, 0x3A, 0xFF, 0xC3, 0x2D, 0x30, 0x7E, 0x2E]
        for _ in 0..<Int.random(in: 1...6, using: &random) {
            guard !bytes.isEmpty else { break }
            let index = Int.random(in: 0..<bytes.count, using: &random)
            switch Int.random(in: 0..<6, using: &random) {
            case 0: bytes[index] = interesting.randomElement(using: &random)!
            case 1: bytes[index] ^= UInt8.random(in: 1...255, using: &random)
            case 2: bytes.remove(at: index)
            case 3: bytes.insert(contentsOf: bytes[index..<min(bytes.count, index + Int.random(in: 1...40, using: &random))], at: index)
            case 4: bytes = Array(bytes.prefix(index))
            default: bytes.insert(contentsOf: Array(repeating: UInt8(ascii: "["), count: Int.random(in: 1...300, using: &random)), at: index)
            }
        }
        return Data(bytes)
    }

    func testMutatedInputsAreRejectedSafelyAtEveryBoundary() async throws {
        var random = Generator(state: 0x5031)
        var accepted = 0, restored = 0
        // A real saved workspace (a split tab), so mutations reach the persisted-tree decoder, not just its header check.
        let store = try WorkspaceStore()
        _ = try await store.execute(.createWindow(name: "W"))
        let created = await store.snapshot()
        let pane = try XCTUnwrap(created.panes.keys.first)
        _ = try await store.execute(.splitPane(id: pane, axis: .x, availableSize: try TerminalSize(columns: 200, rows: 50)))
        let split = await store.snapshot()
        let seeds = Self.seeds + [try WorkspaceSnapshotCodec.encode(split, settings: WorkspaceSettings())]
        for iteration in 0..<3_000 {
            let input = mutate(seeds[iteration % seeds.count], &random)
            // Control protocol: never crashes, always answers or closes.
            let session = ControlSession(peerUID: geteuid(), handler: RejectingControlHandler())
            _ = await session.receive(input + Data([0x0A]))
            // Layout and portable documents.
            if let value = try? JSONDecoder().decode(JSONValue.self, from: input) {
                if case .success(let document) = LayoutJSON.parse(value) {
                    let plan = LayoutPlanner.plan(document, bindings: [:], snapshot: WorkspaceSnapshot(), home: "/Users/test", hostExists: { _ in true }, directoryExists: { _ in true })
                    if let target = plan.target { XCTAssertNoThrow(try target.validate(), "iteration \(iteration)") }
                    accepted += 1
                }
                _ = PortableDocument.parse(value)
            }
            // Themes and persisted workspaces use their own bounded readers.
            _ = try? ThemeValidator.validate(input)
            if let workspace = try? WorkspaceSnapshotCodec.decode(input) {
                XCTAssertNoThrow(try workspace.snapshot.validate(), "iteration \(iteration)")
                restored += 1
            }
        }
        XCTAssertGreaterThan(accepted, 0, "Some mutations stay valid, so the accept path is exercised too")
        XCTAssertGreaterThan(restored, 0, "Some mutated workspaces still restore, and only as valid trees")
    }

    func testHostileNestingAndSizeAreBoundedBeforeDecoding() async {
        let deep = Data(String(repeating: "[", count: 200_000).utf8) + Data([0x0A])
        let session = ControlSession(peerUID: geteuid(), handler: RejectingControlHandler())
        let reply = await session.receive(deep)
        XCTAssertFalse(reply.output.isEmpty, "Deep nesting gets a sanitized error, not a crash")
        XCTAssertThrowsError(try ThemeValidator.validate(Data(String(repeating: "[", count: 70_000).utf8)))
        XCTAssertThrowsError(try WorkspaceSnapshotCodec.decode(Data(String(repeating: "{\"a\":", count: 10_000).utf8)))
    }
}
