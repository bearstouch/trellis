import XCTest
@testable import TrellisMCP

final class HTTPParserTests: XCTestCase {
    private func parse(_ text: String) throws(HTTPParseError) -> [HTTPRequest] {
        var parser = HTTPRequestParser()
        return try parser.append(Data(text.utf8))
    }

    func testParsesPostWithBodyAndLowercasedHeaders() throws {
        let requests = try parse("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:7777\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].method, "POST")
        XCTAssertEqual(requests[0].path, "/mcp")
        XCTAssertEqual(requests[0].header("HOST"), "127.0.0.1:7777")
        XCTAssertEqual(requests[0].body, Data("{}".utf8))
        XCTAssertTrue(requests[0].keepAlive)
    }

    func testQueryStringIsNotPartOfThePath() throws {
        XCTAssertEqual(try parse("GET /mcp?x=1 HTTP/1.1\r\nHost: a\r\n\r\n").first?.path, "/mcp")
    }

    func testWaitsForTheWholeBodyAcrossChunks() throws {
        var parser = HTTPRequestParser()
        XCTAssertEqual(try parser.append(Data("POST /mcp HTTP/1.1\r\nContent-Length: 4\r\n\r\n{}".utf8)).count, 0)
        XCTAssertTrue(parser.hasPartialRequest)
        let done = try parser.append(Data("  ".utf8))
        XCTAssertEqual(done.first?.body, Data("{}  ".utf8))
        XCTAssertFalse(parser.hasPartialRequest)
    }

    func testPipelinedRequestsAreReturnedInOrder() throws {
        let requests = try parse("DELETE /a HTTP/1.1\r\n\r\nPOST /b HTTP/1.1\r\nContent-Length: 1\r\n\r\nx")
        XCTAssertEqual(requests.map(\.path), ["/a", "/b"])
    }

    func testBlankLinesAndPipelinedRequestsInOneReadCostLinearTime() throws {
        var parser = HTTPRequestParser()
        // Each blank line or request used to copy the rest of the buffer: a flood of them pinned a core before any auth.
        let started = Date()
        XCTAssertEqual(try parser.append(Data(String(repeating: "\r\n", count: 262_144).utf8)), [])
        XCTAssertFalse(parser.hasPartialRequest)
        let many = String(repeating: "GET /mcp HTTP/1.1\r\nHost: a\r\n\r\n\r\n", count: 20_000)
        XCTAssertEqual(try parser.append(Data(many.utf8)).count, 20_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertFalse(parser.hasPartialRequest)
    }

    func testABlankLineSplitAcrossReadsIsSkipped() throws {
        var parser = HTTPRequestParser()
        XCTAssertEqual(try parser.append(Data("GET /a HTTP/1.1\r\nHost: a\r\n\r\n\r".utf8)).map(\.path), ["/a"])
        XCTAssertTrue(parser.hasPartialRequest)
        XCTAssertEqual(try parser.append(Data("\nGET /b HTTP/1.1\r\nHost: a\r\n\r\nGET /c".utf8)).map(\.path), ["/b"])
        XCTAssertEqual(try parser.append(Data(" HTTP/1.1\r\nHost: a\r\n\r\n".utf8)).map(\.path), ["/c"])
        XCTAssertFalse(parser.hasPartialRequest)
    }

    func testHTTP10ClosesUnlessKeepAliveIsRequested() throws {
        XCTAssertFalse(try parse("GET / HTTP/1.0\r\n\r\n")[0].keepAlive)
        XCTAssertTrue(try parse("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")[0].keepAlive)
        XCTAssertFalse(try parse("GET / HTTP/1.1\r\nConnection: close\r\n\r\n")[0].keepAlive)
    }

    func testRejectsChunkedBodies() {
        XCTAssertThrowsError(try parse("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")) { XCTAssertEqual($0 as? HTTPParseError, .lengthRequired) }
    }

    func testRejectsOversizedBodyBeforeReadingIt() {
        XCTAssertThrowsError(try parse("POST /mcp HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n")) { XCTAssertEqual($0 as? HTTPParseError, .bodyTooLarge) }
    }

    func testRejectsOversizedHeadersEvenWithoutTerminator() {
        let long = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPRequestParser.maximumHeaderBytes + 1)
        XCTAssertThrowsError(try parse(long)) { XCTAssertEqual($0 as? HTTPParseError, .headersTooLarge) }
    }

    func testRejectsConflictingContentLengthsAndFoldedHeaders() {
        XCTAssertThrowsError(try parse("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nxx")) { XCTAssertEqual($0 as? HTTPParseError, .malformed) }
        XCTAssertThrowsError(try parse("POST / HTTP/1.1\r\nX-A: 1\r\n folded\r\n\r\n")) { XCTAssertEqual($0 as? HTTPParseError, .malformed) }
        XCTAssertThrowsError(try parse("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n")) { XCTAssertEqual($0 as? HTTPParseError, .malformed) }
    }

    func testRejectsMalformedRequestLinesAndVersions() {
        XCTAssertThrowsError(try parse("post /mcp HTTP/1.1\r\n\r\n"))
        XCTAssertThrowsError(try parse("GET mcp HTTP/1.1\r\n\r\n"))
        XCTAssertThrowsError(try parse("GET /mcp HTTP/2\r\n\r\n")) { XCTAssertEqual($0 as? HTTPParseError, .unsupportedVersion) }
    }

    func testResponseSerializationSetsLengthAndConnection() {
        let wire = String(decoding: HTTPResponse.json(200, Data("{}".utf8)).serialized(keepAlive: false), as: UTF8.self)
        XCTAssertTrue(wire.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(wire.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(wire.contains("Connection: close\r\n"))
        XCTAssertFalse(wire.lowercased().contains("access-control"))
        XCTAssertTrue(wire.hasSuffix("\r\n\r\n{}"))
    }

    /// Seeded fuzz: arbitrary bytes either parse or throw; never crash or grow unbounded.
    func testRandomInputNeverCrashes() {
        var generator = SeededGenerator(seed: 0xC0FFEE)
        let alphabet = Array("GETPOST /mcpHTTP/1.1\r\n:Content-Length: 0123456789{}\u{0}".utf8)
        for _ in 0..<2_000 {
            var parser = HTTPRequestParser()
            let bytes = (0..<Int.random(in: 0...400, using: &generator)).map { _ in
                Bool.random(using: &generator) ? alphabet.randomElement(using: &generator)! : UInt8.random(in: 0...255, using: &generator)
            }
            _ = try? parser.append(Data(bytes))
        }
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
