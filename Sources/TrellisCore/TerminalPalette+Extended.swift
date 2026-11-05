import Foundation

/// 256-color indexes for terminals with a light background (FR-TH09). The fixed xterm values
/// assume a dark terminal, so a program's "dark panel" (234) draws as a near-black block here.
extension TerminalPalette {
    /// Floor for text whose color pair uses an index from 16 to 255. Remapping makes light text
    /// dark, so only the pair can tell whether it stays readable.
    public static let lightTerminalMinimumContrast = 4.5

    /// Decided from the colors, not `appearance`: a light theme can keep dark panes.
    public var hasLightTerminal: Bool { ThemeColor(background).relativeLuminance > ThemeColor(foreground).relativeLuminance }

    /// Colors for indexes 16...255: the cube spans background (16) to foreground (231) through
    /// ANSI 1-6, and the grey ramp runs from background to foreground. Both keep xterm's own
    /// steps, whose jump from 0 is what makes mid indexes readable as text.
    public func extendedColors() -> [UInt32] {
        var corners = ansi.prefix(8).map(LabColor.init(rgb:))
        corners[0] = LabColor(rgb: background)
        corners[7] = LabColor(rgb: foreground)
        let steps: [Double] = [0, 0x5F, 0x87, 0xAF, 0xD7, 0xFF].map { $0 / 255 }
        var colors: [UInt32] = []
        colors.reserveCapacity(240)
        for red in steps {
            let lowLow = corners[0].mixed(with: corners[1], red), highLow = corners[2].mixed(with: corners[3], red)
            let lowHigh = corners[4].mixed(with: corners[5], red), highHigh = corners[6].mixed(with: corners[7], red)
            for green in steps {
                let low = lowLow.mixed(with: highLow, green), high = lowHigh.mixed(with: highHigh, green)
                for blue in steps { colors.append(low.mixed(with: high, blue).rgb) }
            }
        }
        for index in 0..<24 { colors.append(corners[0].mixed(with: corners[7], Double(8 + index * 10) / 255).rgb) }
        return colors
    }
}

/// CIELAB (D65), so interpolated colors look evenly spaced.
private struct LabColor {
    let l: Double, a: Double, b: Double

    init(l: Double, a: Double, b: Double) { self.l = l; self.a = a; self.b = b }

    init(rgb: UInt32) {
        func linear(_ shift: UInt32) -> Double {
            let value = Double((rgb >> shift) & 255) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let red = linear(16), green = linear(8), blue = linear(0)
        let x = f((0.4124564 * red + 0.3575761 * green + 0.1804375 * blue) / 0.95047)
        let y = f(0.2126729 * red + 0.7151522 * green + 0.0721750 * blue)
        let z = f((0.0193339 * red + 0.1191920 * green + 0.9503041 * blue) / 1.08883)
        self.init(l: 116 * y - 16, a: 500 * (x - y), b: 200 * (y - z))
    }

    func mixed(with other: Self, _ fraction: Double) -> Self {
        Self(l: l + (other.l - l) * fraction, a: a + (other.a - a) * fraction, b: b + (other.b - b) * fraction)
    }

    var rgb: UInt32 {
        func inverse(_ t: Double) -> Double { t * t * t > 216.0 / 24389 ? t * t * t : (116 * t - 16) * 27 / 24389 }
        let fy = (l + 16) / 116
        let x = inverse(a / 500 + fy) * 0.95047, y = inverse(fy), z = inverse(fy - b / 200) * 1.08883
        func channel(_ value: Double, _ shift: UInt32) -> UInt32 {
            let clamped = min(max(value, 0), 1)
            let companded = clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
            return UInt32((companded * 255).rounded()) << shift
        }
        return channel(3.2404542 * x - 1.5371385 * y - 0.4985314 * z, 16)
            | channel(-0.9692660 * x + 1.8760108 * y + 0.0415560 * z, 8)
            | channel(0.0556434 * x - 0.2040259 * y + 1.0572252 * z, 0)
    }
}
