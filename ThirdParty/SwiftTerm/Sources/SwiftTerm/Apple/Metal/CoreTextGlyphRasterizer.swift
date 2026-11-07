#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import CoreText

/// The text and background colors a glyph is smoothed for, as 8-bit device RGB.
struct GlyphSmoothingColors: Hashable {
    let foreground: SIMD3<UInt8>
    let background: SIMD3<UInt8>

    init(foreground: SIMD4<Float>, background: SIMD4<Float>) {
        func quantize(_ c: SIMD4<Float>) -> SIMD3<UInt8> {
            let clamped = SIMD3<Float>(c.x, c.y, c.z).clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
            return SIMD3<UInt8>(clamped * 255, rounding: .toNearestOrEven)
        }
        self.foreground = quantize(foreground)
        self.background = quantize(background)
    }
}

final class CoreTextGlyphRasterizer {
#if os(macOS)
    var fontSmoothing: Bool = true
#else
    // iOS and visionOS never smooth: no outset, and the renderer keeps one plain mask per glyph.
    var fontSmoothing: Bool = false
#endif

    /// Rasterizes `glyph` as a coverage mask (white, premultiplied) or, for a color glyph, as its colors.
    ///
    /// macOS font smoothing thickens strokes by an amount that depends on the text and background colors: about
    /// 15% for dark text on white, 40% for white text on black, less for low-contrast pairs. A white mask smoothed on
    /// transparency always gets the heaviest weight, so Metal text came out bolder than CoreGraphics text. When
    /// `colors` is given and smoothing is on, the glyph is drawn the way CoreGraphics draws it, in its color over its
    /// background, and the coverage is recovered from that, so blending the mask reproduces the CoreGraphics pixels.
    func rasterize(font: CTFont, glyph: CGGlyph, smoothingOver colors: GlyphSmoothingColors? = nil) -> GlyphBitmap? {
        var glyphVar = glyph
        let rect = CTFontGetBoundingRectsForGlyphs(font, .default, &glyphVar, nil, 1)
        if rect.width <= 0 || rect.height <= 0 {
            return nil
        }
        // Smoothing dilates strokes past the outline's bounds.
        let outset: CGFloat = fontSmoothing ? 1 : 0
        let minX = floor(rect.origin.x) - outset
        let minY = floor(rect.origin.y) - outset
        let maxX = ceil(rect.origin.x + rect.size.width) + outset
        let maxY = ceil(rect.origin.y + rect.size.height) + outset
        let width = Int(maxX - minX)
        let height = Int(maxY - minY)
        if width <= 0 || height <= 0 {
            return nil
        }
        let origin = CGPoint(x: -minX, y: -minY)

        guard var pixels = draw(font: font, glyph: glyph, at: origin, width: width, height: height, colors: nil) else {
            return nil
        }
        var isColor = false
        var idx = 0
        while idx < pixels.count {
            let b = pixels[idx]
            let g = pixels[idx + 1]
            let r = pixels[idx + 2]
            if r != g || g != b {
                isColor = true
                break
            }
            idx += 4
        }

        #if os(macOS)
        if !isColor, fontSmoothing, let colors, let coverage = smoothedCoverage(font: font, glyph: glyph, at: origin, width: width, height: height, colors: colors) {
            pixels = coverage
        }
        #endif

        return GlyphBitmap(width: width,
                           height: height,
                           bearing: CGPoint(x: minX, y: minY),
                           pixels: pixels,
                           isColor: isColor)
    }

    #if os(macOS)
    /// The glyph's coverage as CoreGraphics smooths it for `colors`, or nil when the two colors are too close to
    /// recover it (the text is then all but invisible, and the plain mask is used).
    private func smoothedCoverage(font: CTFont, glyph: CGGlyph, at origin: CGPoint, width: Int, height: Int, colors: GlyphSmoothingColors) -> [UInt8]? {
        let fg = SIMD3<Int>(truncatingIfNeeded: colors.foreground), bg = SIMD3<Int>(truncatingIfNeeded: colors.background)
        let delta = fg &- bg
        // The channel with the largest difference resolves coverage most finely. BGRA byte order: blue is byte 0.
        let magnitudes = [abs(delta.z), abs(delta.y), abs(delta.x)]
        guard let span = magnitudes.max(), span >= 8, let channel = magnitudes.firstIndex(of: span) else {
            return nil
        }
        guard let drawn = draw(font: font, glyph: glyph, at: origin, width: width, height: height, colors: colors) else {
            return nil
        }
        let from = [bg.z, bg.y, bg.x][channel], to = [fg.z, fg.y, fg.x][channel]
        var coverage = [UInt8](repeating: 0, count: drawn.count)
        let span2 = 2 * (to - from)
        var idx = 0
        while idx < drawn.count {
            // Rounded (x * 255 / span); truncating would thin every edge pixel. Rounds for either sign of the span.
            let value = ((Int(drawn[idx + channel]) - from) * 510 + (to - from)) / span2
            let c = UInt8(clamping: value)
            coverage[idx] = c; coverage[idx + 1] = c; coverage[idx + 2] = c; coverage[idx + 3] = c
            idx += 4
        }
        return coverage
    }
    #endif

    /// Draws the glyph white on transparency, or, with `colors`, in the foreground color over an opaque background.
    private func draw(font: CTFont, glyph: CGGlyph, at origin: CGPoint, width: Int, height: Int, colors: GlyphSmoothingColors?) -> [UInt8]? {
        var glyphVar = glyph
        let bytesPerPixel = 4
        var pixels = Array(repeating: UInt8(0), count: width * height * bytesPerPixel)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else {
                return false
            }
            // Device RGB, like the colors the renderer blends with, so recovered coverage matches the blend.
            let colorSpace = colors == nil ? CGColorSpace(name: CGColorSpace.sRGB) : CGColorSpaceCreateDeviceRGB()
            guard let colorSpace else {
                return false
            }
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * bytesPerPixel,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo) else {
                return false
            }

            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setAllowsFontSubpixelPositioning(true)
            context.setShouldSubpixelPositionFonts(true)
            context.setAllowsFontSubpixelQuantization(false)
            context.setShouldSubpixelQuantizeFonts(false)
#if os(macOS)
            context.setAllowsFontSmoothing(fontSmoothing)
            context.setShouldSmoothFonts(fontSmoothing)
#else
            context.setAllowsFontSmoothing(false)
            context.setShouldSmoothFonts(false)
#endif

            let text: CGColor
            if let colors {
                func cg(_ c: SIMD3<UInt8>) -> CGColor {
                    CGColor(colorSpace: colorSpace, components: [CGFloat(c.x) / 255, CGFloat(c.y) / 255, CGFloat(c.z) / 255, 1])!
                }
                context.setFillColor(cg(colors.background))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                text = cg(colors.foreground)
            } else {
                text = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            }
            context.setFillColor(text)
            context.setStrokeColor(text)

            var positions = [origin]
            CTFontDrawGlyphs(font, &glyphVar, &positions, 1, context)
            return true
        }
        return drew ? pixels : nil
    }
}
#endif
