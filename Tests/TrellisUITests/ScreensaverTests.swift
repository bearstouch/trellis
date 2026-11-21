import AppKit
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// FR-SS02..FR-SS05: when the idle screensaver shows over the focused pane, and what takes it away. Time is injected; the
/// once-a-second poll is driven by calling `tickScreensaver()` directly.
final class ScreensaverTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let h: Harness
        var now = Date(timeIntervalSince1970: 1000)
        var visible = true
        var model: AppWorkspaceModel { h.model }
        init() throws {
            h = try Harness()
            h.model.activityNow = { [unowned self] in now }
            h.model.activitySleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
            h.model.workspaceIsVisible = { [unowned self] in visible }
        }
        func choose(_ style: IdleScreensaverStyle, delay: Int = 60) {
            var settings = model.appearance
            settings.idleScreensaver = style; settings.idleScreensaverDelaySeconds = delay
            XCTAssertTrue(model.applyAppearance(settings))
        }
        func pass(_ seconds: TimeInterval) { now.addTimeInterval(seconds); model.tickScreensaver() }
    }

    @MainActor
    private func makeTwoPanes(_ f: Fixture) async throws -> (tab: UUID, first: UUID, second: UUID) {
        _ = await f.model.createSpace(name: "W", startSession: false)
        let tab = try XCTUnwrap(f.model.presentation.selectedTab?.id)
        let first = try XCTUnwrap(f.model.snapshot.tabs[tab]?.activePaneID)
        let split = await f.model.splitPane(first, axis: .x, startSession: false)
        let second = try XCTUnwrap(split)
        _ = await f.model.selectPane(second)
        XCTAssertNotEqual(first, second)
        return (tab, first, second)
    }

    @MainActor
    func testShowsOverTheFocusedPaneOnlyAfterTheChosenDelay() async throws {
        let f = try Fixture()
        let p = try await makeTwoPanes(f)
        f.choose(.digitalRain, delay: 60)
        f.pass(0)
        f.pass(59)
        XCTAssertNil(f.model.screensaverPaneID)
        f.pass(1)
        XCTAssertEqual(f.model.screensaverPaneID, p.second, "Only the focused pane is covered")
    }

    @MainActor
    func testOffNeverShowsAndTurningItOffDismisses() async throws {
        let f = try Fixture()
        _ = try await makeTwoPanes(f)
        f.pass(0); f.pass(10_000)
        XCTAssertNil(f.model.screensaverPaneID, "Off is the default")
        f.choose(.life, delay: 30)
        f.pass(0); f.pass(30)
        XCTAssertNotNil(f.model.screensaverPaneID)
        f.choose(.off)
        XCTAssertNil(f.model.screensaverPaneID)
        XCTAssertNil(f.model.screensaverTask)
    }

    @MainActor
    func testFocusedOutputAndInputRestartTheCountdownAndDismiss() async throws {
        let f = try Fixture()
        let p = try await makeTwoPanes(f)
        f.choose(.plasma, delay: 60)
        f.pass(0); f.pass(50)
        try XCTUnwrap(f.model.terminals[p.second]).onOutput?()
        f.pass(50)
        XCTAssertNil(f.model.screensaverPaneID, "Output restarted the countdown")
        try XCTUnwrap(f.model.terminals[p.second]).onInput?()
        f.pass(59)
        XCTAssertNil(f.model.screensaverPaneID, "Input restarted the countdown")
        f.pass(1)
        XCTAssertEqual(f.model.screensaverPaneID, p.second)
        try XCTUnwrap(f.model.terminals[p.second]).onOutput?()
        XCTAssertNil(f.model.screensaverPaneID, "New output in the covered pane takes the screensaver away")
    }

    @MainActor
    func testOutputInAnotherPaneNeitherDelaysNorDismisses() async throws {
        let f = try Fixture()
        let p = try await makeTwoPanes(f)
        f.choose(.briansBrain, delay: 60)
        f.pass(0); f.pass(30)
        try XCTUnwrap(f.model.terminals[p.first]).onOutput?()
        f.pass(30)
        XCTAssertEqual(f.model.screensaverPaneID, p.second)
        try XCTUnwrap(f.model.terminals[p.first]).onOutput?()
        XCTAssertEqual(f.model.screensaverPaneID, p.second)
    }

    @MainActor
    func testUserActivityDismissesAndRestartsTheCountdown() async throws {
        let f = try Fixture()
        _ = try await makeTwoPanes(f)
        f.choose(.hexSpirals, delay: 60)
        f.pass(0); f.pass(60)
        XCTAssertNotNil(f.model.screensaverPaneID)
        f.model.noteUserActivity()
        XCTAssertNil(f.model.screensaverPaneID)
        f.pass(59)
        XCTAssertNil(f.model.screensaverPaneID)
        f.pass(1)
        XCTAssertNotNil(f.model.screensaverPaneID)
    }

    @MainActor
    func testFocusingAnotherPaneDismissesAndStartsAFreshCountdown() async throws {
        let f = try Fixture()
        let p = try await makeTwoPanes(f)
        f.choose(.digitalRain, delay: 60)
        f.pass(0); f.pass(60)
        XCTAssertEqual(f.model.screensaverPaneID, p.second)
        _ = await f.model.selectPane(p.first)
        f.pass(0)
        XCTAssertNil(f.model.screensaverPaneID)
        f.pass(59)
        XCTAssertNil(f.model.screensaverPaneID, "The newly focused pane waits its own full delay")
        f.pass(1)
        XCTAssertEqual(f.model.screensaverPaneID, p.first)
    }

    @MainActor
    func testHiddenWindowNeverShowsItAndHidingDismisses() async throws {
        let f = try Fixture()
        _ = try await makeTwoPanes(f)
        f.choose(.life, delay: 30)
        f.visible = false
        f.pass(0); f.pass(1000)
        XCTAssertNil(f.model.screensaverPaneID)
        f.visible = true
        f.pass(0); f.pass(30)
        XCTAssertNotNil(f.model.screensaverPaneID)
        f.visible = false
        f.pass(1)
        XCTAssertNil(f.model.screensaverPaneID)
    }

    @MainActor
    func testOnlyTheKeyThatWakesTheWorkspaceIsSwallowed() async throws {
        let f = try Fixture()
        _ = try await makeTwoPanes(f)
        f.choose(.digitalRain, delay: 60)
        f.pass(0); f.pass(30)
        XCTAssertFalse(f.model.noteUserEvent(keyInWorkspaceWindow: true), "A key while nothing shows reaches the pane")
        f.pass(59)
        XCTAssertNil(f.model.screensaverPaneID, "That key restarted the countdown")
        f.pass(1)
        XCTAssertFalse(f.model.noteUserEvent(keyInWorkspaceWindow: false), "A key for another window is never dropped")
        XCTAssertNil(f.model.screensaverPaneID, "It still dismisses")
        f.pass(60)
        XCTAssertTrue(f.model.noteUserEvent(keyInWorkspaceWindow: true), "The waking key is not typed into the pane")
        XCTAssertNil(f.model.screensaverPaneID)
        XCTAssertFalse(f.model.noteUserEvent(keyInWorkspaceWindow: true), "The next key is typed normally")
    }

    @MainActor
    func testCommandPaletteKeepsItAway() async throws {
        let f = try Fixture()
        _ = try await makeTwoPanes(f)
        f.choose(.life, delay: 30)
        f.model.commandPaletteVisible = true
        f.pass(0); f.pass(1000)
        XCTAssertNil(f.model.screensaverPaneID)
        f.model.commandPaletteVisible = false
        f.pass(0); f.pass(29)
        XCTAssertNil(f.model.screensaverPaneID, "Closing the palette starts a full countdown")
        f.pass(1)
        XCTAssertNotNil(f.model.screensaverPaneID)
    }

    /// The CoreText painter draws every animation, katakana included, into an unflipped bitmap.
    @MainActor
    func testPainterDrawsEveryAnimationOverTheBackground() throws {
        let size = CGSize(width: 320, height: 200), palette = ScreensaverPalette(theme: .builtIn(.dark)), painter = ScreensaverPainter()
        for style in IdleScreensaverStyle.animations {
            let scene = try XCTUnwrap(style.makeScene(size: size, seed: 3))
            for _ in 0..<90 { scene.advance(1.0 / 30) }
            let frame = ScreensaverFrame()
            frame.advancePerPoint = painter.advancePerPoint
            scene.render(into: frame)
            let ctx = try XCTUnwrap(
                CGContext(
                    data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
            painter.paint(frame, palette: palette, in: ctx, height: size.height)
            painter.paint(frame, palette: palette, in: ctx, height: size.height)
            let data = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
            let lit = (0..<(ctx.bytesPerRow * ctx.height)).reduce(0) { $0 + (data[$1] > 40 ? 1 : 0) }
            XCTAssertGreaterThan(lit, 200, style.rawValue)
        }
    }

    /// Every animation runs headless from a fixed seed, draws something, and keeps a bounded frame over a long run.
    @MainActor
    func testEveryAnimationDrawsAndStaysBounded() throws {
        let size = CGSize(width: 960, height: 570)
        for style in IdleScreensaverStyle.animations {
            let scene = try XCTUnwrap(style.makeScene(size: size, seed: 42), style.rawValue)
            let frame = ScreensaverFrame()
            var largest = 0
            for i in 0..<900 {
                scene.advance(1.0 / 30)
                guard i % 50 == 0 else { continue }
                frame.reset(); scene.render(into: frame)
                largest = max(largest, frame.glyphs.count + frame.fills.count)
                for g in frame.glyphs { XCTAssertTrue(g.alpha > 0 && g.alpha <= 1, style.rawValue) }
            }
            XCTAssertGreaterThan(largest, 50, "\(style.rawValue) draws")
            XCTAssertLessThan(largest, 20_000, "\(style.rawValue) stays bounded")
        }
        XCTAssertNil(IdleScreensaverStyle.off.makeScene(size: size, seed: 1))
        XCTAssertNil(IdleScreensaverStyle.life.makeScene(size: CGSize(width: 10, height: 10), seed: 1), "Too small to draw")
    }

    @MainActor
    func testSameSeedReplaysTheSameFrame() throws {
        let size = CGSize(width: 400, height: 300)
        for style in IdleScreensaverStyle.animations {
            let a = try XCTUnwrap(style.makeScene(size: size, seed: 7)), b = try XCTUnwrap(style.makeScene(size: size, seed: 7))
            for _ in 0..<60 { a.advance(1.0 / 30); b.advance(1.0 / 30) }
            let fa = ScreensaverFrame(), fb = ScreensaverFrame()
            a.render(into: fa); b.render(into: fb)
            XCTAssertEqual(fa.glyphs.map(\.code), fb.glyphs.map(\.code), style.rawValue)
            XCTAssertEqual(fa.fills.map(\.rect), fb.fills.map(\.rect), style.rawValue)
        }
    }

    @MainActor
    func testPaletteFollowsTheTheme() {
        let dark = ScreensaverPalette(theme: .builtIn(.dark)), light = ScreensaverPalette(theme: .builtIn(.light))
        XCTAssertEqual(dark.background, ResolvedTheme.builtIn(.dark).terminal.background)
        XCTAssertEqual(light[.green], ResolvedTheme.builtIn(.light).terminal.ansi[2])
        XCTAssertNotEqual(dark.background, light.background)
    }
}
