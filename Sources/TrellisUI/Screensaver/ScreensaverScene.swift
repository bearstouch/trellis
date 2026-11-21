import CoreGraphics
import Foundation
import TrellisCore

/// The colors a screensaver draws with, taken from the pane's theme so every animation matches it (FR-SS01).
struct ScreensaverPalette: Equatable {
    enum Ink: Int, CaseIterable { case foreground, muted, green, bright, cyan, blue, magenta, yellow, border }
    let background: UInt32
    private let inks: [UInt32]
    init(theme: ResolvedTheme) {
        let t = theme.terminal, ansi = t.ansi.count >= 16 ? t.ansi : TerminalPalette.builtIn.ansi
        background = t.background
        inks = [t.foreground, theme[.mutedForeground].rgb, ansi[2], ansi[10], ansi[6], ansi[4], ansi[5], ansi[3], theme[.border].rgb]
    }
    subscript(_ ink: Ink) -> UInt32 { inks[ink.rawValue] }
}

/// SplitMix64: small, fast and seedable, so tests replay the same animation.
struct ScreensaverRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9; z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// In 0..<1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

/// One frame's drawing, recorded by a scene and painted by `ScreensaverNSView`. Recording keeps the scenes free of
/// AppKit, so tests can run them headless and count what they draw.
final class ScreensaverFrame {
    struct Glyph {
        var code: UniChar
        /// Center of the cell horizontally, top of the cell vertically.
        var x: CGFloat, y: CGFloat
        var size: CGFloat, bold: Bool
        var ink: ScreensaverPalette.Ink, alpha: Float
    }
    struct Fill {
        var rect: CGRect
        var ink: ScreensaverPalette.Ink, alpha: Float
    }
    private(set) var glyphs: [Glyph] = []
    private(set) var fills: [Fill] = []
    /// The advance of one character at size 1; the painter sets it from the font, tests leave the default.
    var advancePerPoint: CGFloat = 0.6
    func reset() { glyphs.removeAll(keepingCapacity: true); fills.removeAll(keepingCapacity: true) }
    func glyph(_ code: UniChar, x: CGFloat, y: CGFloat, size: CGFloat, ink: ScreensaverPalette.Ink, alpha: Double = 1, bold: Bool = false) {
        guard alpha > 0.01 else { return }
        glyphs.append(Glyph(code: code, x: x, y: y, size: size, bold: bold, ink: ink, alpha: Float(min(1, alpha))))
    }
    /// A left-aligned run of text; returns where it ends.
    @discardableResult
    func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, ink: ScreensaverPalette.Ink, alpha: Double = 1) -> CGFloat {
        let advance = advancePerPoint * size
        var cursor = x
        for code in string.utf16 {
            if code != 32 { glyph(code, x: cursor + advance / 2, y: y, size: size, ink: ink, alpha: alpha) }
            cursor += advance
        }
        return cursor
    }
    func fill(_ rect: CGRect, ink: ScreensaverPalette.Ink, alpha: Double = 1) {
        guard alpha > 0.01 else { return }
        fills.append(Fill(rect: rect, ink: ink, alpha: Float(min(1, alpha))))
    }
}

/// An animation: advanced by elapsed time, then recorded into a frame. Its size is fixed; a resized pane gets a new scene.
@MainActor
protocol ScreensaverScene: AnyObject {
    init(size: CGSize, seed: UInt64)
    func advance(_ dt: Double)
    func render(into frame: ScreensaverFrame)
}

extension IdleScreensaverStyle {
    @MainActor func makeScene(size: CGSize, seed: UInt64) -> ScreensaverScene? {
        guard size.width >= 40, size.height >= 40 else { return nil }
        switch self {
        case .off: return nil
        case .digitalRain: return DigitalRainScene(size: size, seed: seed)
        case .life: return LifeScene(size: size, seed: seed)
        case .briansBrain: return BriansBrainScene(size: size, seed: seed)
        case .hexSpirals: return HexSpiralsScene(size: size, seed: seed)
        case .plasma: return PlasmaScene(size: size, seed: seed)
        }
    }
}

/// Wrap-around grid neighbours, shared by the cellular automata.
struct TorusGrid {
    let width: Int, height: Int
    var count: Int { width * height }
    @inline(__always) func row(_ y: Int) -> Int { ((y + height) % height) * width }
    @inline(__always) func col(_ x: Int) -> Int { (x + width) % width }
}
