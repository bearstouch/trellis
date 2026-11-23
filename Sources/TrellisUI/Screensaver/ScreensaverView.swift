import AppKit
import CoreText
import SwiftUI
import TrellisCore

/// Paints a recorded frame with CoreText, one draw call per font, color and opacity, so a few thousand characters stay cheap.
@MainActor
final class ScreensaverPainter {
    private struct FontKey: Hashable { let size: CGFloat, bold: Bool }
    private struct GlyphKey: Hashable { let font: FontKey, code: UniChar }
    private struct Entry { let font: Int, glyph: CGGlyph, advance: CGFloat, ascent: CGFloat }
    private struct Batch { var glyphs: [CGGlyph] = [], points: [CGPoint] = [] }
    private var fonts: [CTFont] = []
    private var baseFonts: [FontKey: Int] = [:]
    /// Fallback fonts by size and PostScript name, so every katakana from one font shares a draw call.
    private var fallbackFonts: [String: Int] = [:]
    private var entries: [GlyphKey: Entry?] = [:]
    private var colors: [Int: CGColor] = [:]
    private var glyphBatches: [Int: Batch] = [:]
    private var fillBatches: [Int: [CGRect]] = [:]
    private static let opacityLevels = 16
    let advancePerPoint: CGFloat

    init() {
        let probe = Self.font(size: 100, bold: false)
        var glyph = CGGlyph(0), zero = UniChar(48), advance = CGSize.zero
        CTFontGetGlyphsForCharacters(probe, &zero, &glyph, 1)
        CTFontGetAdvancesForGlyphs(probe, .horizontal, &glyph, &advance, 1)
        advancePerPoint = advance.width > 0 ? advance.width / 100 : 0.6
    }

    /// The bundled JetBrains Mono (registered with the terminal fonts), else the system monospace font.
    private static func font(size: CGFloat, bold: Bool) -> CTFont {
        NSFont(name: bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    private func entry(_ glyph: ScreensaverFrame.Glyph) -> Entry? {
        let key = GlyphKey(font: FontKey(size: glyph.size, bold: glyph.bold), code: glyph.code)
        if let cached = entries[key] { return cached }
        let baseIndex: Int
        if let index = baseFonts[key.font] {
            baseIndex = index
        } else {
            baseIndex = fonts.count; fonts.append(Self.font(size: glyph.size, bold: glyph.bold)); baseFonts[key.font] = baseIndex
        }
        var code = glyph.code, cg = CGGlyph(0)
        var index = baseIndex
        if !CTFontGetGlyphsForCharacters(fonts[baseIndex], &code, &cg, 1) || cg == 0 {
            // Katakana and other characters the monospace font lacks come from the system's fallback font.
            let fallback = CTFontCreateForString(fonts[baseIndex], String(utf16CodeUnits: [code], count: 1) as CFString, CFRange(location: 0, length: 1))
            guard CTFontGetGlyphsForCharacters(fallback, &code, &cg, 1), cg != 0 else { entries[key] = .some(nil); return nil }
            let name = "\(glyph.size) \(CTFontCopyPostScriptName(fallback) as String)"
            if let known = fallbackFonts[name] {
                index = known
            } else {
                index = fonts.count; fonts.append(fallback); fallbackFonts[name] = index
            }
        }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(fonts[index], .horizontal, &cg, &advance, 1)
        let found = Entry(font: index, glyph: cg, advance: advance.width, ascent: CTFontGetAscent(fonts[baseIndex]))
        entries[key] = found
        return found
    }

    /// Empties every value in place; walking indices (not `keys`) keeps the dictionary uniquely referenced, so nothing is copied.
    private static func clear<V>(_ batches: inout [Int: V], _ empty: (inout V) -> Void) {
        var i = batches.values.startIndex
        while i != batches.values.endIndex { empty(&batches.values[i]); batches.values.formIndex(after: &i) }
    }

    private func level(_ alpha: Float) -> Int { min(Self.opacityLevels, max(1, Int((alpha * Float(Self.opacityLevels)).rounded()))) }

    private func color(_ rgb: UInt32, level: Int) -> CGColor {
        let key = Int(rgb) << 5 | level
        if let cached = colors[key] { return cached }
        let made = CGColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255,
            alpha: CGFloat(level) / CGFloat(Self.opacityLevels))
        colors[key] = made
        return made
    }

    /// The phosphor glow (FR-LK05): a soft shadow in the ink's own colour, only over dark backgrounds.
    private func withGlow(_ on: Bool, _ ink: CGColor, palette: ScreensaverPalette, in ctx: CGContext, _ body: () -> Void) {
        guard on, palette.isDark else { body(); return }
        ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 7, color: ink.copy(alpha: 0.75)); body(); ctx.restoreGState()
    }

    /// Draws into an unflipped context of the given height; frames use top-left coordinates.
    func paint(_ frame: ScreensaverFrame, palette: ScreensaverPalette, in ctx: CGContext, height: CGFloat) {
        // Paths keep their recorded order: a filled polygon may hide what an earlier path drew (Ridgelines).
        let points = frame.pathPoints
        for path in frame.paths {
            let cg = CGMutablePath()
            cg.addLines(between: points[path.points].map { CGPoint(x: $0.x, y: height - $0.y) })
            let ink = color(palette[path.ink], level: level(path.alpha))
            if let width = path.lineWidth {
                ctx.setLineWidth(width); ctx.setLineJoin(.round); ctx.setLineCap(.round); ctx.setStrokeColor(ink)
                withGlow(path.glow, ink, palette: palette, in: ctx) {
                    ctx.addPath(cg); ctx.strokePath()
                }
            } else {
                cg.closeSubpath(); ctx.setFillColor(ink); ctx.addPath(cg); ctx.fillPath()
            }
        }
        // Batches keep their arrays between frames, so a steady animation allocates nothing per frame.
        Self.clear(&fillBatches) { $0.removeAll(keepingCapacity: true) }
        for fill in frame.fills {
            let r = fill.rect
            fillBatches[fill.ink.rawValue << 8 | level(fill.alpha), default: []].append(CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height))
        }
        for (key, rects) in fillBatches where !rects.isEmpty {
            ctx.setFillColor(color(palette[ScreensaverPalette.Ink(rawValue: key >> 8)!], level: key & 0xFF))
            ctx.fill(rects)
        }
        Self.clear(&glyphBatches) {
            $0.glyphs.removeAll(keepingCapacity: true); $0.points.removeAll(keepingCapacity: true)
        }
        for glyph in frame.glyphs {
            guard let entry = entry(glyph) else { continue }
            let key = entry.font << 16 | (glyph.glow ? 1 << 15 : 0) | glyph.ink.rawValue << 8 | level(glyph.alpha)
            glyphBatches[key, default: Batch()].glyphs.append(entry.glyph)
            glyphBatches[key, default: Batch()].points.append(CGPoint(x: glyph.x - entry.advance / 2, y: height - glyph.y - entry.ascent))
        }
        ctx.textMatrix = .identity
        for (key, batch) in glyphBatches where !batch.glyphs.isEmpty {
            let ink = color(palette[ScreensaverPalette.Ink(rawValue: (key >> 8) & 0x3F)!], level: key & 0xFF)
            ctx.setFillColor(ink)
            withGlow(key & 1 << 15 != 0, ink, palette: palette, in: ctx) { CTFontDrawGlyphs(fonts[key >> 16], batch.glyphs, batch.points, batch.glyphs.count, ctx) }
        }
    }
}

/// What a screensaver canvas draws: an idle screensaver (FR-SS01) or a lock screen (FR-LK05).
enum ScreensaverContent: Hashable {
    case idle(IdleScreensaverStyle), lock(LockScreenStyle)
    var isOff: Bool { self == .idle(.off) }
    @MainActor func makeScene(size: CGSize, seed: UInt64) -> ScreensaverScene? {
        switch self {
        case .idle(let style): style.makeScene(size: size, seed: seed)
        case .lock(let style): style.makeScene(size: size, seed: seed)
        }
    }
}

/// Runs one scene at 30 frames a second while its window is visible; with `animated` off (Reduce Motion, FR-SS04) it
/// draws a single still frame.
@MainActor
final class ScreensaverNSView: NSView {
    var onPointerMoved: (() -> Void)?
    /// Set for the lock screen: a click asks to unlock, and no click or scroll reaches what lies beneath (FR-LK03).
    var onMouseDown: (() -> Void)?
    private var style = ScreensaverContent.idle(.off)
    private var palette: ScreensaverPalette?
    private var animated = true
    private var scene: ScreensaverScene?
    private var sceneSize = CGSize.zero
    private let frameBuffer = ScreensaverFrame()
    private lazy var painter = ScreensaverPainter()
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0

    override var isOpaque: Bool { true }

    func configure(style: ScreensaverContent, palette: ScreensaverPalette, animated: Bool) {
        if style != self.style { self.style = style; scene = nil }
        if animated != self.animated { self.animated = animated; scene = nil }
        if palette != self.palette { self.palette = palette }
        syncTimer(); needsDisplay = true
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); syncTimer() }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize != sceneSize { scene = nil }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { onPointerMoved?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onMouseDown != nil }
    override func mouseDown(with event: NSEvent) { if let onMouseDown { onMouseDown() } else { super.mouseDown(with: event) } }
    override func rightMouseDown(with event: NSEvent) { if let onMouseDown { onMouseDown() } else { super.rightMouseDown(with: event) } }
    override func otherMouseDown(with event: NSEvent) { if let onMouseDown { onMouseDown() } else { super.otherMouseDown(with: event) } }
    override func scrollWheel(with event: NSEvent) { if onMouseDown == nil { super.scrollWheel(with: event) } }
    override func isAccessibilityElement() -> Bool { false }

    func stop() { timer?.invalidate(); timer = nil; scene = nil }

    private func syncTimer() {
        let run = window != nil && animated && !style.isOff
        if run, timer == nil {
            lastTick = 0
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !run {
            timer?.invalidate(); timer = nil
        }
    }

    private func currentScene() -> ScreensaverScene? {
        if let scene { return scene }
        let size = bounds.size
        scene = style.makeScene(size: size, seed: UInt64.random(in: 1...UInt64.max)); sceneSize = size
        // A still frame shows the animation a few seconds in, not its empty first frame.
        if !animated { for _ in 0..<120 { scene?.advance(1.0 / 30) } }
        return scene
    }

    private func tick() {
        // FR-SS05: nothing advances or draws while the window is hidden or covered.
        guard let window, window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor else { lastTick = 0; return }
        let now = CACurrentMediaTime()
        let dt = lastTick == 0 ? 1.0 / 30 : min(0.1, now - lastTick)
        lastTick = now
        currentScene()?.advance(dt)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let palette else { return }
        let bg = palette.background
        ctx.setFillColor(CGColor(srgbRed: CGFloat((bg >> 16) & 0xFF) / 255, green: CGFloat((bg >> 8) & 0xFF) / 255, blue: CGFloat(bg & 0xFF) / 255, alpha: 1))
        ctx.fill(bounds)
        guard let scene = currentScene() else { return }
        frameBuffer.reset(); frameBuffer.advancePerPoint = painter.advancePerPoint
        scene.render(into: frameBuffer)
        painter.paint(frameBuffer, palette: palette, in: ctx, height: bounds.height)
    }

    deinit { MainActor.assumeIsolated { timer?.invalidate() } }
}

struct ScreensaverCanvas: NSViewRepresentable {
    let content: ScreensaverContent
    let palette: ScreensaverPalette
    let animated: Bool
    var onPointerMoved: (() -> Void)?
    var onMouseDown: (() -> Void)?
    init(style: IdleScreensaverStyle, palette: ScreensaverPalette, animated: Bool, onPointerMoved: (() -> Void)? = nil) {
        content = .idle(style); self.palette = palette; self.animated = animated; self.onPointerMoved = onPointerMoved
    }
    init(lock: LockScreenStyle, palette: ScreensaverPalette, animated: Bool, onMouseDown: (() -> Void)? = nil) {
        content = .lock(lock); self.palette = palette; self.animated = animated; self.onMouseDown = onMouseDown
    }
    func makeNSView(context: Context) -> ScreensaverNSView {
        let view = ScreensaverNSView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: ScreensaverNSView, context: Context) {
        view.onPointerMoved = onPointerMoved; view.onMouseDown = onMouseDown
        view.configure(style: content, palette: palette, animated: animated)
    }
    static func dismantleNSView(_ view: ScreensaverNSView, coordinator: ()) { view.stop() }
}

/// The screensaver over an idle focused pane (FR-SS01..FR-SS06): the animation, and the way back in words.
struct IdleScreensaverOverlay: View {
    let style: IdleScreensaverStyle
    let palette: ScreensaverPalette
    let animated: Bool
    let onPointerMoved: () -> Void
    var body: some View {
        ScreensaverCanvas(style: style, palette: palette, animated: animated, onPointerMoved: onPointerMoved)
            .overlay(alignment: .bottom) {
                Text(L("Press any key to return")).font(.system(size: 11)).tracking(0.8)
                    .foregroundStyle(Color(themeRGB: palette[.muted])).padding(.bottom, 12)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Screensaver: %@", style.displayName))
            .accessibilityHint(L("Press any key to return"))
    }
}
