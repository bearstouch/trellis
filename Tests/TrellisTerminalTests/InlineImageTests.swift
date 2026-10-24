import AppKit
import ImageIO
import SwiftTerm
import UniformTypeIdentifiers
import XCTest

@testable import TrellisTerminal

final class InlineImageTests: XCTestCase {
    private static func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func bytes(_ text: String) -> ArraySlice<UInt8> { Array(text.utf8)[...] }

    func testParsesFileArgumentsAndDimensions() {
        guard case .file(let arguments, let payload) = InlineImageCommand(Self.bytes("File=name=YS5wbmc=;size=3;inline=1;width=20;height=50%;preserveAspectRatio=0:QUJD")) else {
            return XCTFail("File command")
        }
        XCTAssertTrue(arguments.inline)
        XCTAssertEqual(arguments.declaredSize, 3)
        XCTAssertFalse(arguments.preserveAspectRatio)
        XCTAssertEqual(String(decoding: payload, as: UTF8.self), "QUJD")
        guard case .cells(20) = arguments.width, case .percent(50) = arguments.height else { return XCTFail("Dimensions") }
        for (value, valid) in [("120px", true), ("auto", false), ("0", false), ("200", false), ("101%", false), ("4096px", false), ("-3", false), ("x", false)] {
            if case .auto = InlineImageArguments.dimension(value) { XCTAssertFalse(valid, value) } else { XCTAssertTrue(valid, value) }
        }
        XCTAssertFalse(InlineImageArguments(Self.bytes("inline=0")).inline)
        XCTAssertFalse(InlineImageArguments(Self.bytes("")).inline, "Download unless inline=1 is explicit")
    }

    func testParsesMultipartCellSizeAndIgnoresOtherCommands() {
        XCTAssertEqual(InlineImageCommand(Self.bytes("MultipartFile=inline=1;size=9")), .multipartBegin(InlineImageArguments(Self.bytes("inline=1;size=9"))))
        XCTAssertEqual(InlineImageCommand(Self.bytes("FilePart=QUJD")), .filePart(Self.bytes("QUJD")))
        XCTAssertEqual(InlineImageCommand(Self.bytes("FileEnd")), .fileEnd)
        XCTAssertEqual(InlineImageCommand(Self.bytes("ReportCellSize")), .reportCellSize)
        for other in ["File=inline=1", "SetMark", "SetUserVar=a=b", "CurrentDir=/tmp", "", "FileEnd=1", "ReportCellSize=1"] {
            XCTAssertEqual(InlineImageCommand(Self.bytes(other)), .other, other)
        }
        XCTAssertEqual(
            InlineImageCommand.cellSizeReport(size: CGSize(width: 8, height: 17.25), scale: 2), "\u{1b}]1337;ReportCellSize=17.2;8.0;2.0\u{1b}\\")
    }

    func testDecoderAcceptsBitmapsAndRefusesDocumentsAndHugeImages() throws {
        let image = try XCTUnwrap(InlineImageDecoder.image(from: try Self.png(width: 3, height: 2)))
        XCTAssertEqual(image.size, CGSize(width: 3, height: 2))
        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 10, height: 10)
        let consumer = try XCTUnwrap(CGDataConsumer(data: pdf))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        XCTAssertNotNil(NSImage(data: pdf as Data), "NSImage would draw this PDF")
        XCTAssertNil(InlineImageDecoder.image(from: pdf as Data))
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>"#.utf8)
        XCTAssertNil(InlineImageDecoder.image(from: svg))
        XCTAssertNil(InlineImageDecoder.image(from: Data("%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 10 10\n".utf8)))
        XCTAssertNil(InlineImageDecoder.image(from: Data("not an image".utf8)))
        // A header claiming 20,000 px wide is refused before any pixel data is read.
        var header = try Self.png(width: 1, height: 1)
        header.replaceSubrange(16..<20, with: [0, 0, 0x4e, 0x20])
        XCTAssertNil(InlineImageDecoder.acceptedSource(header))
    }

    func testMultipartTransferReassemblesAndDiscardsBadTransfers() throws {
        let payload = Array(try Self.png(width: 2, height: 2).base64EncodedString().utf8)
        var transfer = MultipartImageTransfer()
        transfer.begin(InlineImageArguments(Self.bytes("inline=1")))
        // Parts split at arbitrary offsets, not on base64 quanta.
        for start in stride(from: 0, to: payload.count, by: 7) { transfer.append(payload[start..<min(start + 7, payload.count)]) }
        let (arguments, bytes) = try XCTUnwrap(transfer.finish())
        XCTAssertTrue(arguments.inline)
        XCTAssertEqual(bytes, try Self.png(width: 2, height: 2))
        XCTAssertNil(transfer.finish(), "Finishing ends the transfer")

        transfer.begin(InlineImageArguments(Self.bytes("inline=1;size=2")))
        transfer.append(Self.bytes("QUJD"))
        XCTAssertNil(transfer.finish(), "More data than the declared size")
        transfer.begin(InlineImageArguments(Self.bytes("inline=1")))
        transfer.append(Self.bytes("QU*D"))
        transfer.append(Self.bytes("QUJD"))
        XCTAssertNil(transfer.finish(), "Bad base64 discards the whole transfer")
        transfer.begin(InlineImageArguments(Self.bytes("inline=1")))
        transfer.append(Self.bytes("QUJ"))
        XCTAssertNil(transfer.finish(), "A truncated final quantum")
        transfer.begin(InlineImageArguments(Self.bytes("inline=0")))
        transfer.append(Self.bytes("QUJD"))
        XCTAssertNil(transfer.finish(), "Downloads are never assembled")
        transfer.begin(InlineImageArguments(Self.bytes("inline=1;size=\(MultipartImageTransfer.maxBytes + 1)")))
        XCTAssertFalse(transfer.isActive, "A declared size over the limit is refused up front")
    }

    @MainActor
    func testInlineImageIsPlacedAtCursorAndDownloadsAreRefused() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let terminal = view.getTerminal()
        let png = try Self.png(width: 8, height: 8).base64EncodedString()
        // Other tests, their helpers and system tools add and remove entries here concurrently; only a new image
        // file could be the refused download (`x.png`).
        func temporaryEntries() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.lowercased().hasSuffix(".png") })
        }
        let before = try temporaryEntries()
        native.adapter.receive(Data("\u{1b}]1337;File=name=eC5wbmc=;inline=0:\(png)\u{07}".utf8))
        native.adapter.receive(Data("\u{1b}]1337;File=inline=1:\(Data("%PDF-1.4".utf8).base64EncodedString())\u{07}".utf8))
        XCTAssertFalse(terminal.buffer.hasAnyImages, "Downloads and non-bitmap data show nothing")
        XCTAssertEqual(try temporaryEntries().subtracting(before), [], "Nothing is downloaded")
        let row = terminal.getCursorLocation().y
        native.adapter.receive(Data("\u{1b}]1337;File=inline=1;width=4;height=3:\(png)\u{07}after".utf8))
        XCTAssertTrue(terminal.buffer.hasAnyImages)
        XCTAssertGreaterThanOrEqual(terminal.getCursorLocation().y, row + 2, "The cursor moves below a three-row image")
        XCTAssertTrue(view.retainedText.contains("after"), "Output after the image renders")
    }

    @MainActor
    func testMultipartImageAndCellSizeReport() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let png = try Self.png(width: 4, height: 4).base64EncodedString()
        var replies = 0
        native.onInputError = { _ in replies += 1 }  // the session isn't started, so any reply surfaces as a write error
        native.adapter.receive(Data("\u{1b}]1337;MultipartFile=inline=1\u{07}\u{1b}]1337;FilePart=\(png.prefix(10))\u{07}".utf8))
        native.adapter.receive(Data("\u{1b}]1337;SetMark\u{07}\u{1b}]1337;FilePart=\(png.dropFirst(10))\u{07}\u{1b}]1337;FileEnd\u{07}".utf8))
        XCTAssertFalse(view.getTerminal().buffer.hasAnyImages, "An interrupted transfer shows nothing")
        native.adapter.receive(Data("\u{1b}]1337;MultipartFile=inline=1\u{07}\u{1b}]1337;FilePart=\(png.prefix(10))\u{07}".utf8))
        native.adapter.receive(Data("\u{1b}]1337;FilePart=\(png.dropFirst(10))\u{07}\u{1b}]1337;FileEnd\u{07}".utf8))
        XCTAssertTrue(view.getTerminal().buffer.hasAnyImages)
        XCTAssertEqual(replies, 0)
        native.adapter.receive(Data("\u{1b}]1337;ReportCellSize\u{1b}\\".utf8))
        XCTAssertEqual(replies, 1, "ReportCellSize is answered")
    }

    func testOversizedStringSequencesAreDroppedAndParsingRecovers() {
        final class Sink: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }
        let sink = Sink()
        let terminal = Terminal(delegate: sink)
        XCTAssertEqual(terminal.parser.maxStringPayloadBytes, 8 * 1024 * 1024)
        terminal.parser.maxStringPayloadBytes = 64
        var received: [Int] = []
        terminal.registerOscHandler(code: 7777) { received.append($0.count) }
        terminal.feed(text: "\u{1b}]7777;" + String(repeating: "A", count: 100) + "\u{07}")
        terminal.feed(text: "\u{1b}]7777;" + String(repeating: "B", count: 40))
        terminal.feed(text: String(repeating: "B", count: 40) + "\u{1b}\\")
        XCTAssertEqual(received, [], "Payloads over the limit are dropped, including ones split across reads")
        terminal.feed(text: "\u{1b}]7777;short\u{07}ok")
        XCTAssertEqual(received, [5], "The next sequence is parsed normally")
        XCTAssertEqual(terminal.getLine(row: 0)?.translateToString(trimRight: true), "ok")
    }
}
