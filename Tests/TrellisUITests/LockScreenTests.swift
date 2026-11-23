import AppKit
import XCTest
import TrellisCore
import TrellisTerminal
@testable import TrellisUI

/// FR-LK01..FR-LK06: locking, unlocking through the (fake) Touch ID / password gate, and the five lock screen scenes.
final class LockScreenTests: XCTestCase {
    /// Answers each prompt with the next queued answer; holds a prompt open until `release()` when told to.
    private final class FakeGate: UserPresenceGate, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Bool] = []
        private var held: CheckedContinuation<Void, Never>?
        private var hold = false
        private(set) var prompts = 0
        private(set) var reasons: [String] = []
        func queue(_ answer: Bool, hold: Bool = false) {
            lock.withLock {
                answers.append(answer); self.hold = hold
            }
        }
        func release() {
            lock.withLock {
                let c = held; held = nil; return c
            }?.resume()
        }
        func authorize(reason: String) async -> Bool {
            let mustHold = lock.withLock {
                prompts += 1; reasons.append(reason); return hold
            }
            if mustHold { await withCheckedContinuation { c in lock.withLock { held = c } } }
            return lock.withLock { answers.isEmpty ? false : answers.removeFirst() }
        }
    }

    @MainActor
    private final class Fixture {
        let h: Harness, gate = FakeGate()
        var now = Date(timeIntervalSince1970: 1000)
        var changes: [Bool] = []
        var model: AppWorkspaceModel { h.model }
        init() throws {
            h = try Harness()
            h.model.activityNow = { [unowned self] in now }
            h.model.activitySleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
            h.model.workspaceIsVisible = { true }
            h.model.lockGate = gate
            h.model.onLockChanged = { [unowned self] in changes.append($0) }
        }
        /// Lets the unlock task finish.
        func settle() async { for _ in 0..<20 { await Task.yield() } }
    }

    @MainActor
    func testLockThenUnlockAfterTheOwnerAuthenticates() async throws {
        let f = try Fixture()
        _ = await f.model.createSpace(name: "W", startSession: false)
        XCTAssertNil(f.model.lockUnavailableReason)
        XCTAssertTrue(f.model.lockWorkspace())
        XCTAssertTrue(f.model.isLocked)
        XCTAssertEqual(f.changes, [true])
        XCTAssertNotNil(f.model.lockUnavailableReason, "Locking twice does nothing")
        XCTAssertFalse(f.model.lockWorkspace())
        f.gate.queue(true)
        f.model.requestUnlock()
        await f.settle()
        XCTAssertFalse(f.model.isLocked)
        XCTAssertFalse(f.model.unlockInProgress)
        XCTAssertEqual(f.changes, [true, false])
        XCTAssertEqual(f.gate.prompts, 1)
        XCTAssertEqual(f.gate.reasons, ["unlock the workspace"])
    }

    @MainActor
    func testFailedOrCancelledAuthenticationKeepsItLockedAndAsksAgainNextTime() async throws {
        let f = try Fixture()
        XCTAssertTrue(f.model.lockWorkspace())
        f.gate.queue(false)
        f.model.requestUnlock()
        await f.settle()
        XCTAssertTrue(f.model.isLocked, "A cancelled or failed prompt never unlocks")
        XCTAssertFalse(f.model.unlockInProgress)
        f.gate.queue(true)
        f.model.requestUnlock()
        await f.settle()
        XCTAssertFalse(f.model.isLocked)
        XCTAssertEqual(f.gate.prompts, 2)
    }

    @MainActor
    func testOnlyOnePromptAtATime() async throws {
        let f = try Fixture()
        XCTAssertTrue(f.model.lockWorkspace())
        f.gate.queue(true, hold: true)
        f.model.requestUnlock()
        await f.settle()
        XCTAssertTrue(f.model.unlockInProgress)
        f.model.requestUnlock(); f.model.requestUnlock()
        await f.settle()
        XCTAssertEqual(f.gate.prompts, 1, "Keys and clicks while the prompt is open don't open another")
        f.gate.release()
        await f.settle()
        XCTAssertFalse(f.model.isLocked)
        XCTAssertFalse(f.model.unlockInProgress)
    }

    @MainActor
    func testUnlockRequestWhileUnlockedDoesNothing() async throws {
        let f = try Fixture()
        f.model.requestUnlock()
        await f.settle()
        XCTAssertEqual(f.gate.prompts, 0)
        XCTAssertEqual(f.changes, [])
    }

    @MainActor
    func testUnavailableWithoutAGateOrAuthenticationOrDuringTheTour() throws {
        let f = try Fixture()
        f.model.lockAvailable = { false }
        XCTAssertNotNil(f.model.lockUnavailableReason)
        XCTAssertFalse(f.model.lockWorkspace())
        f.model.lockAvailable = { true }
        f.model.lockGate = nil
        XCTAssertFalse(f.model.lockWorkspace(), "No way to unlock means no lock")
        XCTAssertFalse(f.model.isLocked)
        XCTAssertEqual(f.changes, [])
    }

    @MainActor
    func testLockingClosesThePaletteTakesAwayTheScreensaverAndKeepsItAway() async throws {
        let f = try Fixture()
        _ = await f.model.createSpace(name: "W", startSession: false)
        var settings = f.model.appearance
        settings.idleScreensaver = .life; settings.idleScreensaverDelaySeconds = 30
        XCTAssertTrue(f.model.applyAppearance(settings))
        f.model.tickScreensaver(); f.now.addTimeInterval(30); f.model.tickScreensaver()
        XCTAssertNotNil(f.model.screensaverPaneID)
        f.model.commandPaletteVisible = true
        XCTAssertTrue(f.model.lockWorkspace())
        XCTAssertFalse(f.model.commandPaletteVisible)
        XCTAssertNil(f.model.screensaverPaneID)
        f.now.addTimeInterval(10_000); f.model.tickScreensaver()
        XCTAssertNil(f.model.screensaverPaneID, "The screensaver never starts while locked")
        f.gate.queue(true)
        f.model.requestUnlock()
        await f.settle()
        f.model.tickScreensaver(); f.now.addTimeInterval(29); f.model.tickScreensaver()
        XCTAssertNil(f.model.screensaverPaneID, "Unlocking counts as activity: a full countdown follows")
        f.now.addTimeInterval(1); f.model.tickScreensaver()
        XCTAssertNotNil(f.model.screensaverPaneID)
    }

    @MainActor
    func testLockedStateIsNotPartOfTheAppearanceOrWorkspace() throws {
        let f = try Fixture()
        XCTAssertTrue(f.model.lockWorkspace())
        var settings = f.model.appearance
        settings.lockScreen = .ridgelines
        XCTAssertTrue(f.model.applyAppearance(settings))
        XCTAssertEqual(f.model.appearance.lockScreen, .ridgelines)
        XCTAssertTrue(f.model.isLocked, "Changing the style doesn't unlock")
        let encoded = String(decoding: try JSONEncoder().encode(f.model.appearance), as: UTF8.self)
        XCTAssertFalse(encoded.contains("isLocked"))
    }

    // MARK: scenes (FR-LK05, FR-LK06)

    @MainActor
    func testEveryLockScreenDrawsAndStaysBounded() throws {
        for (size, frames) in [(CGSize(width: 1040, height: 640), 1800), (CGSize(width: 2560, height: 1440), 300), (CGSize(width: 420, height: 280), 300)] {
            for style in LockScreenStyle.allCases {
                let scene = try XCTUnwrap(style.makeScene(size: size, seed: 42), style.rawValue)
                let frame = ScreensaverFrame()
                var largest = 0, smallest = Int.max
                for i in 0..<frames {
                    scene.advance(1.0 / 30)
                    guard i % 60 == 0 else { continue }
                    frame.reset(); scene.render(into: frame)
                    let count = frame.glyphs.count + frame.fills.count + frame.pathPoints.count
                    largest = max(largest, count); smallest = min(smallest, count)
                    for g in frame.glyphs { XCTAssertTrue(g.alpha > 0 && g.alpha <= 1, style.rawValue) }
                    for p in frame.paths { XCTAssertTrue(p.points.upperBound <= frame.pathPoints.count, style.rawValue) }
                }
                XCTAssertGreaterThan(smallest, 20, "\(style.rawValue) at \(size) draws on every frame")
                XCTAssertLessThan(largest, 40_000, "\(style.rawValue) at \(size) stays bounded")
            }
        }
        XCTAssertNil(LockScreenStyle.vaultDial.makeScene(size: CGSize(width: 10, height: 10), seed: 1), "Too small to draw")
    }

    @MainActor
    func testSameSeedReplaysTheSameLockScreen() throws {
        let size = CGSize(width: 800, height: 500)
        for style in LockScreenStyle.allCases {
            let a = try XCTUnwrap(style.makeScene(size: size, seed: 9)), b = try XCTUnwrap(style.makeScene(size: size, seed: 9))
            for _ in 0..<90 { a.advance(1.0 / 30); b.advance(1.0 / 30) }
            let fa = ScreensaverFrame(), fb = ScreensaverFrame()
            a.render(into: fa); b.render(into: fb)
            XCTAssertEqual(fa.glyphs.map(\.code), fb.glyphs.map(\.code), style.rawValue)
            XCTAssertEqual(fa.fills.map(\.rect), fb.fills.map(\.rect), style.rawValue)
            XCTAssertEqual(fa.pathPoints, fb.pathPoints, style.rawValue)
        }
    }

    @MainActor
    func testCipherWallSpellsLockedInBrightGlowingCells() throws {
        let scene = try XCTUnwrap(LockScreenStyle.cipherWall.makeScene(size: CGSize(width: 1040, height: 640), seed: 1))
        let frame = ScreensaverFrame()
        scene.render(into: frame)
        // L O C K E D in a 5×7 font: 11 + 16 + 13 + 14 + 18 + 18 lit cells.
        XCTAssertEqual(frame.glyphs.filter(\.glow).count, 90)
        XCTAssertTrue(frame.glyphs.filter(\.glow).allSatisfy { $0.alpha >= 0.85 })
    }

    /// Paths, fills, glyphs and the glow paint into a bitmap, in a dark and a light theme.
    @MainActor
    func testPainterDrawsEveryLockScreenInDarkAndLightThemes() throws {
        let size = CGSize(width: 480, height: 300), painter = ScreensaverPainter()
        for theme in [ResolvedTheme.builtIn(.dark), .builtIn(.light)] {
            let palette = ScreensaverPalette(theme: theme)
            XCTAssertEqual(palette.isDark, theme.appearance == .dark)
            for style in LockScreenStyle.allCases {
                let scene = try XCTUnwrap(style.makeScene(size: size, seed: 3))
                for _ in 0..<90 { scene.advance(1.0 / 30) }
                let frame = ScreensaverFrame()
                frame.advancePerPoint = painter.advancePerPoint
                scene.render(into: frame)
                let ctx = try XCTUnwrap(
                    CGContext(
                        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                let bg = palette.background
                ctx.setFillColor(CGColor(srgbRed: CGFloat((bg >> 16) & 0xFF) / 255, green: CGFloat((bg >> 8) & 0xFF) / 255, blue: CGFloat(bg & 0xFF) / 255, alpha: 1))
                ctx.fill(CGRect(origin: .zero, size: size))
                painter.paint(frame, palette: palette, in: ctx, height: size.height)
                let data = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
                let bytes = [UInt8((bg >> 16) & 0xFF), UInt8((bg >> 8) & 0xFF), UInt8(bg & 0xFF)]
                var changed = 0
                for y in 0..<ctx.height {
                    for x in 0..<ctx.width {
                        let i = y * ctx.bytesPerRow + x * 4
                        if (0..<3).contains(where: { abs(Int(data[i + $0]) - Int(bytes[$0])) > 24 }) { changed += 1 }
                    }
                }
                XCTAssertGreaterThan(changed, 300, "\(style.rawValue) in \(theme.appearance)")
            }
        }
    }

    @MainActor
    func testPaletteCarriesTheAccentAndBackground() {
        let dark = ResolvedTheme.builtIn(.dark), palette = ScreensaverPalette(theme: dark)
        XCTAssertEqual(palette[.accent], dark[.accent].rgb)
        XCTAssertEqual(palette[.background], dark.terminal.background)
        XCTAssertTrue(palette.isDark)
        XCTAssertFalse(ScreensaverPalette(theme: .builtIn(.light)).isDark)
    }
}
