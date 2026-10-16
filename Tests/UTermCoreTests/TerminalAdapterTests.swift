import XCTest
@testable import UTermCore

final class TerminalAdapterTests: XCTestCase {
    @MainActor
    func testS001_UT01_adapterPreservesOutputOrder() async {
        var chunks: [Data] = []
        let adapter = TerminalAdapter(render: { chunks.append($0) }, write: { _ in }, resizePTY: { _ in }, readText: { "" }, cleanup: {})
        let input = [Data([0, 1]), Data([2]), Data([3, 4])]
        input.forEach(adapter.receive)
        XCTAssertEqual(chunks, input)
    }

    @MainActor
    func testS001_UT02_adapterPropagatesResize() async throws {
        var sizes: [TerminalSize] = []
        let adapter = TerminalAdapter(render: { _ in }, write: { _ in }, resizePTY: { sizes.append($0) }, readText: { "" }, cleanup: {})
        let size = try TerminalSize(columns: 100, rows: 30)
        try adapter.resize(size)
        try adapter.resize(size)
        XCTAssertEqual(sizes, [size])
        XCTAssertThrowsError(try TerminalSize(columns: 0, rows: 30))
        XCTAssertThrowsError(try TerminalSize(columns: 80, rows: 65_536))
    }

    @MainActor
    func testS001_UT03_adapterDetachIsIdempotent() async throws {
        var cleanupCount = 0
        var writes = 0
        var renders = 0
        let adapter = TerminalAdapter(render: { _ in renders += 1 }, write: { _ in writes += 1 }, resizePTY: { _ in }, readText: { "" }, cleanup: { cleanupCount += 1 })
        adapter.detach()
        adapter.detach()
        adapter.receive(Data([1]))
        XCTAssertThrowsError(try adapter.send(Data([2])))
        XCTAssertThrowsError(try adapter.resize(TerminalSize(columns: 80, rows: 24)))
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(renders, 0)
    }

    @MainActor
    func testS001_UT04_unsupportedEngineCapabilityIsExplicit() async throws {
        let adapter = TerminalAdapter(render: { _ in }, write: { _ in }, resizePTY: { _ in }, readText: { "retained text" }, cleanup: {})
        XCTAssertEqual(try adapter.read(.retainedText), "retained text")
        XCTAssertThrowsError(try adapter.read(.commandExitStatus)) { error in
            XCTAssertEqual(error as? TerminalAdapterError, .unsupportedRead)
        }
    }

    @MainActor
    func testAdapterPropagatesInputFailure() async {
        let adapter = TerminalAdapter(render: { _ in }, write: { _ in throw TerminalAdapterError.inputQueueFull },
                                      resizePTY: { _ in }, readText: { "" }, cleanup: {})
        XCTAssertThrowsError(try adapter.send(Data([1]))) {
            XCTAssertEqual($0 as? TerminalAdapterError, .inputQueueFull)
        }
    }

}
