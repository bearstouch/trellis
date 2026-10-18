import XCTest
@testable import SwiftTerm

/// Terminal output is untrusted: a hostile byte stream must not hang, crash or exhaust the app,
/// because every pane shares one process and the engine is fed on the main thread.
final class TerminalEngineReviewTests: XCTestCase {
    final class Replies: TerminalDelegate, @unchecked Sendable {
        var text = ""
        var images: [(width: Int, height: Int)] = []
        func send(source: Terminal, data: ArraySlice<UInt8>) { text += String(decoding: data, as: UTF8.self) }
        func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) { images.append((width, height)) }
    }

    /// Feeds `sequences` off the main thread and fails, rather than hanging the suite, if the engine stalls.
    @discardableResult
    private func feed(
        _ sequences: [String], timeout: TimeInterval = 10, payloadLimit: Int? = nil, kittyChunkLimit: Int? = nil, file: StaticString = #filePath,
        line: UInt = #line
    ) -> Replies {
        let replies = Replies()
        nonisolated(unsafe) let terminal = Terminal(delegate: replies)
        if let payloadLimit { terminal.parser.maxStringPayloadBytes = payloadLimit }
        if let kittyChunkLimit { terminal.kittyGraphicsState.maxPendingBytes = kittyChunkLimit }
        let done = DispatchSemaphore(value: 0)
        Thread {
            for sequence in sequences { terminal.feed(text: sequence) }
            done.signal()
        }.start()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            XCTFail("The engine did not finish processing the output", file: file, line: line)
        }
        return replies
    }

    func testKittyZlibPayloadDecodesAndNeverStalls() {
        // zlib.compress(bytes([255, 0, 0, 255])): one red RGBA pixel.
        let pixel = "eJz7z8DwHwAE/wH/"
        // zlib.compress(bytes(400)): a 10x10 RGBA image. Upstream decoded zlib as raw deflate and spun forever on it.
        let image = "eJxjYBgFgwkAAAGQAAE="
        let replies = feed(["\u{1b}_Ga=t,f=32,s=1,v=1,o=z,i=1;\(pixel)\u{1b}\\", "\u{1b}_Ga=t,f=32,s=10,v=10,o=z,i=2;\(image)\u{1b}\\"]).text
        XCTAssertTrue(replies.contains("i=1;OK"), replies)
        XCTAssertTrue(replies.contains("i=2;OK"), replies)
    }

    func testKittyMalformedZlibPayloadsAreRefused() {
        var adler = Array(Data(base64Encoded: "eJz7z8DwHwAE/wH/")!)
        adler[adler.count - 1] ^= 0xff
        var header = Array(Data(base64Encoded: "eJz7z8DwHwAE/wH/")!)
        header[1] ^= 0x01
        let truncated = Array(Data(base64Encoded: "eJxjYBgFgwkAAAGQAAE=")!).dropLast(6)
        let rawDeflate = Array(Data(base64Encoded: "eJz7z8DwHwAE/wH/")!).dropFirst(2).dropLast(4)
        let garbage = [UInt8](repeating: 0x78, count: 64)
        let payloads = [adler, header, Array(truncated), Array(rawDeflate), garbage].map { Data($0).base64EncodedString() }
        let replies = feed(payloads.enumerated().map { "\u{1b}_Ga=t,f=32,s=1,v=1,o=z,i=\($0.offset + 1);\($0.element)\u{1b}\\" }).text
        XCTAssertFalse(replies.contains(";OK"), replies)
        XCTAssertEqual(replies.components(separatedBy: "\u{1b}_G").count - 1, payloads.count, "Each refused payload gets an error reply")
    }

    private func sixel(_ body: String) -> String { "\u{1b}P0;0;0q\(body)\u{1b}\\" }

    func testSixelImageStillDecodes() {
        // Three red columns on two bands: 3 px wide, 12 px tall.
        let replies = feed([sixel("#1;2;100;0;0#1!3~-~")])
        XCTAssertEqual(replies.images.map(\.width), [3])
        XCTAssertEqual(replies.images.map(\.height), [12])
    }

    func testSixelHugeNumbersSaturateInsteadOfTrapping() {
        let huge = String(repeating: "9", count: 40)
        let replies = feed([sixel("#0!\(huge)~-"), sixel("#\(huge);2;\(huge);\(huge);\(huge)#\(huge)~-"), sixel("#1;1;\(huge);\(huge);\(huge)#1~-")])
        XCTAssertEqual(replies.images.map(\.width), [10_000, 1, 1], "A repeat count is clamped to the widest image allowed")
    }

    func testSixelOversizedImagesAreDroppedQuickly() {
        let replies = feed(
            [
                sixel("#0" + String(repeating: "!10000~", count: 2)),  // 20,000 px wide
                sixel("#0" + String(repeating: "~-", count: 2_000)),  // 12,000 px tall
                sixel("#0" + String(repeating: "!10000~$", count: 10_000))  // 100 million sixels redrawn over one band
            ], timeout: 5)
        XCTAssertTrue(replies.images.isEmpty)
    }

    func testDcsPayloadsAreBoundedAcrossReads() {
        let status = "\u{1b}[5n"
        // A request within the limit is answered; one over the limit, even split across reads, is dropped whole.
        let replies = feed(
            ["\u{1b}P$qm\u{1b}\\", "\u{1b}P$q" + String(repeating: "m", count: 600), String(repeating: "m", count: 600) + "\u{1b}\\", status],
            payloadLimit: 1_024)
        XCTAssertEqual(replies.text.components(separatedBy: "$r").count - 1, 1, replies.text)
        XCTAssertTrue(replies.text.hasSuffix("\u{1b}[0n"), "Parsing continues normally after the dropped sequence")

        let images = feed([sixel("#0" + String(repeating: "~", count: 2_000)), sixel("#0~~-")], payloadLimit: 1_024).images
        XCTAssertEqual(images.map(\.width), [2], "An oversized sixel is dropped and the next one still draws")
    }

    func testDecrqssKeepsOnlyARequestSizedBuffer() {
        let replies = feed(["\u{1b}P$q" + String(repeating: "m", count: 100_000) + "\u{1b}\\", "\u{1b}P$qr\u{1b}\\"])
        XCTAssertTrue(replies.text.contains("P0$r"), "An overlong request is answered as invalid")
        XCTAssertTrue(replies.text.contains("P1$r"), "A valid request still gets its status string")
    }

    func testKittyChunkedPayloadsAreBounded() {
        // zlib.compress(bytes(400)) split into chunks: a 10x10 RGBA image within the limit still decodes.
        let image = "eJxjYBgFgwkAAAGQAAE="
        let chunks = stride(from: 0, to: image.count, by: 8).map { String(Array(image)[$0..<min($0 + 8, image.count)]) }
        func transfer(id: Int) -> [String] {
            chunks.enumerated().map { index, chunk in
                let more = index == chunks.count - 1 ? 0 : 1
                return index == 0 ? "\u{1b}_Ga=t,f=32,s=10,v=10,o=z,i=\(id),m=\(more);\(chunk)\u{1b}\\" : "\u{1b}_Gm=\(more);\(chunk)\u{1b}\\"
            }
        }
        XCTAssertTrue(feed(transfer(id: 1), kittyChunkLimit: 64).text.contains("i=1;OK"))

        // Every chunk is under the parser cap, but together they pass the transfer limit: refused, and the next image works.
        let flood = ["\u{1b}_Ga=t,f=32,s=10,v=10,o=z,i=2,m=1;\(image)\u{1b}\\"] + Array(repeating: "\u{1b}_Gm=1;\(image)\u{1b}\\", count: 50) + ["\u{1b}_Gm=0;\u{1b}\\"]
        let replies = feed(flood + transfer(id: 3), kittyChunkLimit: 64).text
        XCTAssertTrue(replies.contains("i=2;EFBIG"), replies)
        XCTAssertTrue(replies.contains("i=3;OK"), replies)
    }
}
