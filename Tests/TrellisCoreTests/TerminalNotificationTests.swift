import XCTest
@testable import TrellisCore

/// FR-T08: OSC 9, OSC 777 and OSC 99 notification parsing, sanitizing and rate limiting.
final class TerminalNotificationTests: XCTestCase {
    private func bytes(_ text: String) -> ArraySlice<UInt8> { ArraySlice(Array(text.utf8)) }

    func testOSC9TextIsABodyButNumberedFormsAreNot() {
        XCTAssertEqual(TerminalNotification.parse(osc9: bytes("Build done")), TerminalNotification(title: "", body: "Build done"))
        XCTAssertEqual(TerminalNotification.parse(osc9: bytes("3 tests failed"))?.body, "3 tests failed")
        for numbered in ["4;1;50", "1", "9;x", ""] { XCTAssertNil(TerminalNotification.parse(osc9: bytes(numbered)), numbered) }
    }

    func testOSC777SplitsTitleFromABodyThatMayContainSemicolons() {
        let parsed = TerminalNotification.parse(osc777: bytes("notify;Claude;Needs approval; run ls?"))
        XCTAssertEqual(parsed?.title, "Claude")
        XCTAssertEqual(parsed?.body, "Needs approval; run ls?")
        XCTAssertEqual(TerminalNotification.parse(osc777: bytes("notify;Only title"))?.title, "Only title")
        XCTAssertNil(TerminalNotification.parse(osc777: bytes("other;x;y")))
        XCTAssertNil(TerminalNotification.parse(osc777: bytes("notify;;")), "Empty notifications are dropped")
    }

    func testTextIsStrippedOfControlsAndBidiOverridesAndCapped() throws {
        let parsed = try XCTUnwrap(TerminalNotification(title: "a\u{1b}[31mb\u{07}\u{202E}c", body: "line1\nline2\t\u{9B}end"))
        XCTAssertEqual(parsed.title, "a [31mb c")
        XCTAssertEqual(parsed.body, "line1 line2 end")
        XCTAssertNil(TerminalNotification(title: "\u{1b}\u{07}", body: " \n "))
        let long = try XCTUnwrap(TerminalNotification(title: String(repeating: "t", count: 5000), body: String(repeating: "b", count: 5000)))
        XCTAssertEqual(long.title.count, TerminalNotification.titleLimit)
        XCTAssertEqual(long.body.count, TerminalNotification.bodyLimit)
        XCTAssertTrue(long.body.hasSuffix("…"))
    }

    func testKittySimpleChunkedAndBase64Notifications() {
        var kitty = KittyNotificationAssembler()
        XCTAssertEqual(kitty.receive(bytes(";Hello world")), .notification(TerminalNotification(title: "Hello world", body: "")!))
        XCTAssertNil(kitty.receive(bytes("i=1:d=0;Hello ")))
        XCTAssertNil(kitty.receive(bytes("i=2:d=0;Other")))
        XCTAssertNil(kitty.receive(bytes("i=1:d=0;world")))
        XCTAssertEqual(kitty.receive(bytes("i=1:p=body;This is cool")), .notification(TerminalNotification(title: "Hello world", body: "This is cool")!))
        let encoded = Data("Grüße".utf8).base64EncodedString()
        XCTAssertEqual(kitty.receive(bytes("i=2:e=1:p=body;\(encoded)")), .notification(TerminalNotification(title: "Other", body: "Grüße")!))
        XCTAssertNil(kitty.receive(bytes("no separator")))
        XCTAssertNil(kitty.receive(bytes("p=icon;AAAA")), "Unsupported payloads alone show nothing")
        XCTAssertNil(kitty.receive(bytes("i=3:d=0;Pending")))
        XCTAssertNil(kitty.receive(bytes("i=3:p=close;")), "A close request doesn't finish a pending notification")
        XCTAssertNil(kitty.receive(bytes("i=3:p=alive;")))
        XCTAssertEqual(kitty.receive(bytes("i=3;")), .notification(TerminalNotification(title: "Pending", body: "")!))
    }

    func testKittyOccasionAndUnfocusedDefault() {
        var kitty = KittyNotificationAssembler()
        guard case .notification(let always) = kitty.receive(bytes("o=always;T")), case .notification(let plain) = kitty.receive(bytes(";T")),
            case .notification(let invisible) = kitty.receive(bytes("o=invisible;T")), case .notification(let unknown) = kitty.receive(bytes("o=sometimes;T"))
        else { return XCTFail("Expected notifications") }
        XCTAssertEqual([always.occasion, plain.occasion, invisible.occasion, unknown.occasion], [.always, .unfocused, .invisible, .unfocused])
    }

    func testKittyQueryRepliesWithCapabilitiesAndOnlyASafeIdentifier() {
        var kitty = KittyNotificationAssembler()
        XCTAssertEqual(kitty.receive(bytes("i=ab-1:p=?;")), .reply("\u{1b}]99;i=ab-1:p=?;a=focus:o=always,unfocused,invisible:p=title,body,?\u{1b}\\"))
        XCTAssertEqual(kitty.receive(bytes("i=x\u{1b}[2J:p=?;")), .reply("\u{1b}]99;i=0:p=?;a=focus:o=always,unfocused,invisible:p=title,body,?\u{1b}\\"))
        XCTAssertEqual(kitty.receive(bytes("p=?;")), .reply("\u{1b}]99;i=0:p=?;a=focus:o=always,unfocused,invisible:p=title,body,?\u{1b}\\"), "No identifier replies as i=0")
        XCTAssertEqual(KittyNotificationAssembler.identifier(String(repeating: "a", count: 65)), "")
    }

    func testKittyUnfinishedChunksAreBounded() {
        var kitty = KittyNotificationAssembler()
        for id in 0...KittyNotificationAssembler.pendingLimit { XCTAssertNil(kitty.receive(bytes("i=\(id):d=0;Title \(id)"))) }
        XCTAssertEqual(kitty.receive(bytes("i=0:p=body;B")), .notification(TerminalNotification(title: "", body: "B")!), "The oldest pending chunk was evicted")
        XCTAssertEqual(kitty.receive(bytes("i=1:p=body;B")), .notification(TerminalNotification(title: "Title 1", body: "B")!))
        for _ in 0..<20 { _ = kitty.receive(bytes("i=big:d=0;" + String(repeating: "x", count: 4096))) }
        guard case .notification(let big) = kitty.receive(bytes("i=big;y")) else { return XCTFail("Expected a notification") }
        XCTAssertEqual(big.title.count, TerminalNotification.titleLimit)
    }

    func testRateLimiterAllowsABurstPerPaneThenRecovers() {
        var limiter = NotificationRateLimiter(limit: 2, window: 10)
        let a = UUID(), b = UUID(), start = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(limiter.allow(a, at: start))
        XCTAssertTrue(limiter.allow(a, at: start.addingTimeInterval(1)))
        XCTAssertFalse(limiter.allow(a, at: start.addingTimeInterval(2)))
        XCTAssertTrue(limiter.allow(b, at: start.addingTimeInterval(2)), "Panes are limited separately")
        XCTAssertTrue(limiter.allow(a, at: start.addingTimeInterval(10.5)))
        limiter.retain([b])
        XCTAssertTrue(limiter.allow(a, at: start.addingTimeInterval(10.6)), "A removed pane's history is dropped")
    }
}
