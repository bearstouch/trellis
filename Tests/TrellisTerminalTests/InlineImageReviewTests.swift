import AppKit
import ImageIO
import SwiftTerm
import UniformTypeIdentifiers
import XCTest

@testable import TrellisTerminal

final class InlineImageReviewTests: XCTestCase {
    private static func bytes(_ text: String) -> ArraySlice<UInt8> { Array(text.utf8)[...] }

    private static func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func box(_ image: CGSize, _ arguments: String, pane: CGSize = CGSize(width: 800, height: 600), scale: CGFloat = 2) -> (ImageSizeRequest, ImageSizeRequest, Bool) {
        let fitted = InlineImageLayout.requests(image: image, InlineImageArguments(bytes(arguments)), cell: CGSize(width: 8, height: 17), pane: pane, scale: scale)
        return (fitted.width, fitted.height, fitted.preserveAspectRatio)
    }

    func testAspectDerivedSidesAreBoundedToThePaneAndDecodableHeight() {
        // 10,000 × 1 px at ten rows would otherwise be 1.7 M points wide.
        guard case (.pixels(let width), .pixels(let height), false) = Self.box(CGSize(width: 10_000, height: 1), "inline=1;height=10") else {
            return XCTFail("Wide image is fitted")
        }
        XCTAssertLessThanOrEqual(width, 800)
        XCTAssertGreaterThanOrEqual(height, 1)
        guard case (.pixels(let thinWidth), .pixels(let tall), false) = Self.box(CGSize(width: 1, height: 10_000), "inline=1;width=199") else {
            return XCTFail("Tall image is fitted")
        }
        XCTAssertLessThanOrEqual(tall, 5_000, "No taller than the largest decodable image at this scale")
        XCTAssertGreaterThanOrEqual(thinWidth, 1)
        // An auto image wider than the pane shrinks to its width and keeps its shape.
        guard case (.pixels(800), .pixels(200), false) = Self.box(CGSize(width: 4_000, height: 1_000), "inline=1") else { return XCTFail("Fit to pane") }
    }

    func testImagesThatFitAndExplicitBoxesAreUnchanged() {
        guard case (.auto, .auto, true) = Self.box(CGSize(width: 400, height: 300), "inline=1") else { return XCTFail("Small auto image") }
        guard case (.cells(199), .pixels(4095), true) = Self.box(CGSize(width: 10_000, height: 1), "inline=1;width=199;height=4095px") else {
            return XCTFail("Two explicit sides are already bounded")
        }
        guard case (.cells(20), .auto, false) = Self.box(CGSize(width: 10_000, height: 1), "inline=1;width=20;preserveAspectRatio=0") else {
            return XCTFail("Without aspect ratio the auto side is the image's own, already within limits")
        }
    }

    @MainActor
    func testExtremeAspectImageRendersWithinThePane() throws {
        _ = NSApplication.shared
        let native = NativeTerminal()
        defer { native.adapter.detach() }
        let view = try XCTUnwrap(native.view as? AccessibleTerminalView)
        let terminal = view.getTerminal()
        let row = terminal.getCursorLocation().y
        let png = try Self.png(width: 4_000, height: 1).base64EncodedString()
        native.adapter.receive(Data("\u{1b}]1337;File=inline=1;height=3:\(png)\u{07}after".utf8))
        XCTAssertTrue(terminal.buffer.hasAnyImages)
        XCTAssertLessThanOrEqual(terminal.getCursorLocation().y, row + 3, "Shrinking to the pane width shortens the image")
        XCTAssertTrue(view.retainedText.contains("after"))
    }

    func testOverflowedApcAndCancelledSequencesRecover() {
        final class Sink: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }
        let sink = Sink()
        let terminal = Terminal(delegate: sink)
        terminal.parser.maxStringPayloadBytes = 16
        var received: [String] = []
        terminal.registerOscHandler(code: 7777) { received.append(String(decoding: $0, as: UTF8.self)) }
        terminal.feed(text: "\u{1b}_G" + String(repeating: "A", count: 40) + "\u{1b}\\")
        terminal.feed(text: "\u{1b}]7777;" + String(repeating: "B", count: 40) + "\u{18}")
        terminal.feed(text: "\u{1b}]7777;" + String(repeating: "C", count: 40) + "\u{1b}]7777;next\u{07}")
        XCTAssertEqual(received, ["next"], "An oversized APC, a cancelled one, and one ended by a new sequence are dropped")
        terminal.feed(text: "\u{1b}]7777;" + String(repeating: "D", count: 11) + "\u{07}")
        XCTAssertEqual(received.last, String(repeating: "D", count: 11), "A payload of exactly the limit is kept")
        terminal.feed(text: "ok")
        XCTAssertEqual(terminal.getLine(row: 0)?.translateToString(trimRight: true), "ok")
    }
}
