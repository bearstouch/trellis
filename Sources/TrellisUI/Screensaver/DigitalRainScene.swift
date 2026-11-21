import CoreGraphics
import Foundation

/// Falling columns of half-width katakana and hex digits. A column crossing the middle row lights one letter of the
/// message, which holds for a few seconds and fades.
@MainActor
final class DigitalRainScene: ScreensaverScene {
    private struct Drop { var y: Double, speed: Double, length: Int }
    private static let glyphs = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ0123456789ABCDEF".utf16)
    private static let message = Array("CYPHERPUNKS WRITE CODE".utf16)
    private let cellWidth: CGFloat = 14, cellHeight: CGFloat = 18, fontSize: CGFloat = 14
    private let columns: Int, rows: Int, messageRow: Int, messageColumn: Int
    private var rng: ScreensaverRandom
    private var grid: [UniChar]
    private var drops: [Drop] = []
    private var litAt: [Double]
    private var time = 0.0

    init(size: CGSize, seed: UInt64) {
        rng = ScreensaverRandom(seed: seed)
        columns = max(1, Int((size.width / cellWidth).rounded(.up))); rows = max(1, Int((size.height / cellHeight).rounded(.up)))
        messageRow = Int(Double(rows) * 0.45); messageColumn = (columns - Self.message.count) / 2
        grid = []; litAt = Array(repeating: -1000, count: columns)
        grid = (0..<(columns * rows)).map { _ in randomGlyph() }
        drops = (0..<columns).map { _ in newDrop(initial: true) }
    }

    private func randomGlyph() -> UniChar { Self.glyphs[rng.below(Self.glyphs.count)] }
    private func newDrop(initial: Bool) -> Drop {
        let y = initial ? rng.unit() * Double(rows) * 1.6 - Double(rows) : -rng.unit() * 14
        return Drop(y: y, speed: 5 + rng.unit() * 15, length: 8 + rng.below(24))
    }
    private func messageCode(column x: Int) -> UniChar? {
        let i = x - messageColumn
        guard Self.message.indices.contains(i), Self.message[i] != 32 else { return nil }
        return Self.message[i]
    }
    private func litAlpha(_ x: Int) -> Double {
        let age = time - litAt[x]
        guard age >= 0, age <= 4.5 else { return 0 }
        return age < 0.15 ? age / 0.15 : age < 3 ? 1 : 1 - (age - 3) / 1.5
    }

    func advance(_ dt: Double) {
        time += dt
        for _ in 0..<Int((Double(grid.count) * 0.6 * dt).rounded(.up)) { grid[rng.below(grid.count)] = randomGlyph() }
        for x in 0..<columns {
            let previous = drops[x].y
            drops[x].y += drops[x].speed * dt
            if messageCode(column: x) != nil, previous < Double(messageRow), drops[x].y >= Double(messageRow), litAlpha(x) == 0 { litAt[x] = time }
            if drops[x].y - Double(drops[x].length) > Double(rows) { drops[x] = newDrop(initial: false) }
        }
    }

    func render(into frame: ScreensaverFrame) {
        for x in 0..<columns {
            let drop = drops[x], head = Int(drop.y.rounded(.down)), lit = messageCode(column: x) != nil && litAlpha(x) > 0
            let cx = CGFloat(x) * cellWidth + cellWidth / 2
            for k in 0..<drop.length {
                let r = head - k
                guard r >= 0, r < rows, !(lit && r == messageRow) else { continue }
                let alpha = k == 0 ? 1 : (1 - Double(k) / Double(drop.length)) * 0.85
                frame.glyph(grid[r * columns + x], x: cx, y: CGFloat(r) * cellHeight, size: fontSize, ink: k == 0 ? .bright : .green, alpha: alpha)
            }
        }
        for x in 0..<columns {
            guard let code = messageCode(column: x) else { continue }
            let alpha = litAlpha(x)
            guard alpha > 0 else { continue }
            frame.glyph(code, x: CGFloat(x) * cellWidth + cellWidth / 2, y: CGFloat(messageRow) * cellHeight, size: fontSize, ink: .yellow, alpha: alpha, bold: true)
        }
    }
}
