import XCTest
import SwiftTerm

/// Terminal output is untrusted: a hostile byte stream must not hang, crash or exhaust the app,
/// because every pane shares one process and the engine is fed on the main thread.
final class TerminalEngineReviewTests: XCTestCase {
    final class Replies: TerminalDelegate, @unchecked Sendable {
        var text = ""
        func send(source: Terminal, data: ArraySlice<UInt8>) { text += String(decoding: data, as: UTF8.self) }
    }

    /// Feeds `sequences` off the main thread and fails, rather than hanging the suite, if the engine stalls.
    private func feed(_ sequences: [String], timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> String {
        let replies = Replies()
        nonisolated(unsafe) let terminal = Terminal(delegate: replies)
        let done = DispatchSemaphore(value: 0)
        Thread {
            for sequence in sequences { terminal.feed(text: sequence) }
            done.signal()
        }.start()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            XCTFail("The engine did not finish processing the output", file: file, line: line)
            return ""
        }
        return replies.text
    }

    func testKittyZlibPayloadDecodesAndNeverStalls() {
        // zlib.compress(bytes([255, 0, 0, 255])): one red RGBA pixel.
        let pixel = "eJz7z8DwHwAE/wH/"
        // zlib.compress(bytes(400)): a 10x10 RGBA image. Upstream decoded zlib as raw deflate and spun forever on it.
        let image = "eJxjYBgFgwkAAAGQAAE="
        let replies = feed(["\u{1b}_Ga=t,f=32,s=1,v=1,o=z,i=1;\(pixel)\u{1b}\\", "\u{1b}_Ga=t,f=32,s=10,v=10,o=z,i=2;\(image)\u{1b}\\"])
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
        let replies = feed(payloads.enumerated().map { "\u{1b}_Ga=t,f=32,s=1,v=1,o=z,i=\($0.offset + 1);\($0.element)\u{1b}\\" })
        XCTAssertFalse(replies.contains(";OK"), replies)
        XCTAssertEqual(replies.components(separatedBy: "\u{1b}_G").count - 1, payloads.count, "Each refused payload gets an error reply")
    }
}
