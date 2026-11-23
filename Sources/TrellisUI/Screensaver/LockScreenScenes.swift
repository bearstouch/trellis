import CoreGraphics
import Foundation
import TrellisCore

private let hexUpper = Array("0123456789ABCDEF".utf16), hexLower = Array("0123456789abcdef".utf16)

extension LockScreenStyle {
    /// FR-LK05: every lock screen draws in the theme's accent over its background.
    @MainActor func makeScene(size: CGSize, seed: UInt64) -> ScreensaverScene? {
        guard size.width >= 40, size.height >= 40 else { return nil }
        switch self {
        case .vaultDial: return VaultDialScene(size: size, seed: seed)
        case .redactedShell: return RedactedShellScene(size: size, seed: seed)
        case .cipherWall: return CipherWallScene(size: size, seed: seed)
        case .ridgelines: return RidgelinesScene(size: size, seed: seed)
        case .signalLost: return SignalLostScene(size: size, seed: seed)
        }
    }
}

/// Four rings of hex digits around the clock, each turning a few notches at a time like a combination tumbler; the digits
/// passing under the gate at the top glow.
@MainActor
final class VaultDialScene: ScreensaverScene {
    private struct Ring { let radius: CGFloat, chars: [UniChar]; var rotation = 0.0, target = 0.0, next: Double, direction: Double }
    private let center: CGPoint, fontSize: CGFloat
    private var rings: [Ring], rng: ScreensaverRandom, time = 0.0

    init(size: CGSize, seed: UInt64) {
        var rng = ScreensaverRandom(seed: seed)
        let m = min(size.width, size.height), fontSize = max(8, (m * 0.036).rounded())
        center = CGPoint(x: size.width / 2, y: size.height / 2); self.fontSize = fontSize
        rings = [0.26, 0.31, 0.36, 0.41].enumerated().map { i, k in
            let radius = m * k, count = max(8, Int(2 * .pi * radius / (fontSize * 1.25)))
            return Ring(radius: radius, chars: (0..<count).map { _ in hexUpper[rng.below(16)] }, next: 0.5 + rng.unit() * 2.5, direction: i % 2 == 0 ? 1 : -1)
        }
        self.rng = rng
    }

    func advance(_ dt: Double) {
        time += dt
        let ease = 1 - pow(0.88, dt * 30)
        for i in rings.indices {
            if time > rings[i].next {
                rings[i].target += rings[i].direction * Double(1 + rng.below(4)) * 2 * .pi / Double(rings[i].chars.count)
                rings[i].next = time + 1.2 + rng.unit() * 2.8
                if rng.chance(0.3) { rings[i].direction = -rings[i].direction }
            }
            rings[i].rotation += (rings[i].target - rings[i].rotation) * ease
        }
    }

    func render(into frame: ScreensaverFrame) {
        for ring in rings {
            let r = ring.radius + fontSize * 0.85
            for k in 0...96 { let a = Double(k) / 96 * 2 * .pi; frame.addPoint(center.x + cos(a) * r, center.y + sin(a) * r) }
            frame.strokePath(ink: .accent, alpha: 0.12)
        }
        for ring in rings {
            let n = ring.chars.count
            for (k, code) in ring.chars.enumerated() {
                let angle = ring.rotation + Double(k) * 2 * .pi / Double(n) - .pi / 2
                let hot = max(0, 1 - abs(remainder(angle + .pi / 2, 2 * .pi)) / 0.22)
                frame.glyph(
                    code, x: center.x + cos(angle) * ring.radius, y: center.y + sin(angle) * ring.radius - fontSize * 0.55, size: fontSize, ink: .accent,
                    alpha: 0.2 + 0.8 * hot, bold: hot > 0.4, glow: hot > 0.4)
            }
        }
        let outer = rings[rings.count - 1].radius
        frame.glyph(0x25BC, x: center.x, y: center.y - outer - fontSize * 2.3, size: fontSize, ink: .accent, glow: true)
    }
}

/// A shell that keeps typing commands and printing output, with every word drawn as a bar: it says what the lock does.
@MainActor
final class RedactedShellScene: ScreensaverScene {
    private struct Line { let command: Bool, words: [Int], length: Int }
    private let cellWidth: CGFloat = 11, cellHeight: CGFloat = 20
    private let rows: Int, columns: Int, origin: CGPoint
    private var lines: [Line] = [], progress = 0.0, pause = 0.0, time = 0.0, rng: ScreensaverRandom

    init(size: CGSize, seed: UInt64) {
        rows = max(4, Int(size.height * 0.84 / 20)); columns = max(20, Int(size.width * 0.88 / 11))
        origin = CGPoint(x: size.width * 0.06, y: size.height * 0.08)
        rng = ScreensaverRandom(seed: seed)
        // A screen of history already typed, so the lock never opens on an empty shell.
        for _ in 0..<rows { lines.append(makeLine(after: lines.last)) }
    }

    private func makeLine(after previous: Line?) -> Line {
        let command = previous?.command != true && rng.chance(0.3)
        let limit = Double(columns) * (command ? 0.55 : 0.85) * (0.35 + 0.65 * rng.unit())
        var words: [Int] = [], length = command ? 2 : 0
        while Double(length) < limit { let word = 2 + rng.below(10); words.append(word); length += word + 1 }
        return Line(command: command, words: words, length: length)
    }

    func advance(_ dt: Double) {
        time += dt
        if pause > 0 { pause -= dt; return }
        let current = lines[lines.count - 1]
        progress += (current.command ? 27 : 210) * dt
        guard progress >= Double(current.length) else { return }
        pause = current.command ? 0.6 : 0.07; progress = 0
        lines.append(makeLine(after: current))
        if lines.count > rows { lines.removeFirst() }
    }

    func render(into frame: ScreensaverFrame) {
        var cursorX = origin.x, cursorY = origin.y
        for (row, line) in lines.enumerated() {
            let y = origin.y + CGFloat(row) * cellHeight, last = row == lines.count - 1, limit = last ? Int(progress) : .max
            var x = origin.x, used = 0
            if line.command {
                frame.glyph(0x276F, x: x + cellWidth / 2, y: y + 2, size: 15, ink: .accent, bold: true, glow: true)
                x += cellWidth * 2; used = 2
            }
            for word in line.words where used < limit {
                let n = min(word, limit - used)
                frame.fill(CGRect(x: x, y: y + cellHeight * 0.22, width: CGFloat(n) * cellWidth, height: cellHeight * 0.56), ink: .accent, alpha: line.command ? 0.8 : 0.3)
                x += CGFloat(word + 1) * cellWidth; used += word + 1
            }
            if last { cursorX = origin.x + CGFloat(min(limit, line.length)) * cellWidth; cursorY = y }
        }
        if time.truncatingRemainder(dividingBy: 1) < 0.55 {
            frame.fill(CGRect(x: cursorX, y: cursorY + cellHeight * 0.12, width: cellWidth, height: cellHeight * 0.76), ink: .accent)
        }
    }
}

/// A wall of hex digits that keep re-rolling; the brighter cells spell LOCKED.
@MainActor
final class CipherWallScene: ScreensaverScene {
    private static let font: [Character: [String]] = [
        "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"], "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
        "C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"], "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
        "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"], "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"]
    ]
    private let columns: Int, rows: Int, cellWidth: CGFloat, rowHeight: CGFloat, fontSize: CGFloat
    private var cells: [UniChar], heat: [Float], word: [Bool], rng: ScreensaverRandom, rerollCarry = 0.0

    init(size: CGSize, seed: UInt64) {
        columns = size.width / 52 >= 9 ? 52 : max(37, Int(size.width / 9))
        cellWidth = size.width / CGFloat(columns); rowHeight = cellWidth * 1.55; fontSize = max(7, (cellWidth * 1.15).rounded())
        rows = max(9, Int((size.height / rowHeight).rounded(.up)))
        var rng = ScreensaverRandom(seed: seed)
        cells = (0..<columns * rows).map { _ in hexLower[rng.below(16)] }
        heat = Array(repeating: 0, count: columns * rows); word = Array(repeating: false, count: columns * rows)
        self.rng = rng
        let c0 = (columns - 35) / 2, r0 = max(0, (rows - 7) / 2 - 1)
        for (li, letter) in "LOCKED".enumerated() {
            for (ry, line) in Self.font[letter]!.enumerated() {
                for (rx, bit) in line.enumerated() where bit == "1" { word[(r0 + ry) * columns + c0 + li * 6 + rx] = true }
            }
        }
    }

    func advance(_ dt: Double) {
        let decay = Float(pow(0.9, dt * 30))
        for i in heat.indices { heat[i] *= decay }
        rerollCarry += Double(cells.count) * 0.45 * dt
        while rerollCarry >= 1 { let i = rng.below(cells.count); cells[i] = hexLower[rng.below(16)]; heat[i] = 1; rerollCarry -= 1 }
    }

    func render(into frame: ScreensaverFrame) {
        for i in cells.indices {
            let x = (CGFloat(i % columns) + 0.5) * cellWidth, y = CGFloat(i / columns) * rowHeight + rowHeight * 0.12, h = Double(heat[i])
            if word[i] {
                frame.glyph(cells[i], x: x, y: y, size: fontSize, ink: .accent, alpha: 0.85 + 0.15 * h, bold: true, glow: true)
            } else {
                frame.glyph(cells[i], x: x, y: y, size: fontSize, ink: .accent, alpha: 0.12 + 0.5 * h)
            }
        }
    }
}

/// Stacked signal traces rising slowly, with their peaks in the middle; each trace hides the ones behind it.
@MainActor
final class RidgelinesScene: ScreensaverScene {
    private struct Profile { let bumps: [(center: Double, width: Double, height: Double)], phase: Double }
    private static let lines = 26, samples = 110
    private let size: CGSize, seed: UInt64
    private var time = 0.0, profiles: [Int: Profile] = [:]

    init(size: CGSize, seed: UInt64) { self.size = size; self.seed = seed }

    func advance(_ dt: Double) { time += dt }

    /// Each trace's shape comes from its index, so it keeps its shape as it rises.
    private func profile(_ n: Int) -> Profile {
        if let known = profiles[n] { return known }
        var rng = ScreensaverRandom(seed: seed &+ UInt64(bitPattern: Int64(n)) &* 0x9E37_79B9_7F4A_7C15)
        let made = Profile(bumps: (0..<4).map { _ in (0.34 + rng.unit() * 0.32, 0.02 + rng.unit() * 0.05, 0.3 + rng.unit() * 0.9) }, phase: rng.unit() * 2 * .pi)
        if profiles.count > 64 { profiles.removeAll(keepingCapacity: true) }
        profiles[n] = made
        return made
    }

    func render(into frame: ScreensaverFrame) {
        let w = size.width, h = size.height, top = h * 0.1, gap = h * 0.8 / CGFloat(Self.lines), amp = gap * 5
        let offset = time * 0.35, base = Int(offset.rounded(.down)), fraction = CGFloat(offset - Double(base))
        for i in 0...Self.lines {
            let n = base + i, y = top + (CGFloat(i) - fraction) * gap, shape = profile(n)
            let depth = Double(min(1, max(0, (y - top) / (gap * 4))))
            var ys: [CGFloat] = []
            ys.reserveCapacity(Self.samples + 1)
            for k in 0...Self.samples {
                let xn = Double(k) / Double(Self.samples), envelope = exp(-pow((xn - 0.5) / 0.2, 2))
                var v = 0.06 * sin(xn * 60 + shape.phase + time * 0.8) * envelope
                for bump in shape.bumps { v += bump.height * exp(-pow((xn - bump.center) / bump.width, 2)) }
                ys.append(y - amp * CGFloat(v * envelope * (1 + 0.08 * sin(time * 0.6 + Double(n)))))
            }
            for (k, yy) in ys.enumerated() { frame.addPoint(w * CGFloat(k) / CGFloat(Self.samples), yy) }
            frame.addPoint(w, h); frame.addPoint(0, h)
            frame.fillPath(ink: .background)
            for (k, yy) in ys.enumerated() { frame.addPoint(w * CGFloat(k) / CGFloat(Self.samples), yy) }
            frame.strokePath(ink: .accent, alpha: 0.85 * depth, lineWidth: 1.3, glow: true)
        }
    }
}

/// Dim static tinted with the accent and a rolling bar, like a monitor with no input. The noise changes 15 times a second.
@MainActor
final class SignalLostScene: ScreensaverScene {
    private let cell: CGFloat, columns: Int, rows: Int
    private var values: [Float], rng: ScreensaverRandom, time = 0.0, pending = 0.0

    init(size: CGSize, seed: UInt64) {
        cell = max(8, (size.width / 200).rounded(.up))
        columns = Int((size.width / cell).rounded(.up)); rows = Int((size.height / cell).rounded(.up))
        values = Array(repeating: 0, count: columns * rows); rng = ScreensaverRandom(seed: seed)
        regenerate()
    }

    private func regenerate() {
        let bar = (time * 0.16).truncatingRemainder(dividingBy: 1.4) - 0.2, barRow = bar * Double(rows)
        let tear = rng.chance(0.05) ? rng.below(rows) : -9
        for y in 0..<rows {
            let glow = exp(-pow((Double(y) - barRow) / (Double(rows) * 0.07), 2)) * 0.3, torn = abs(y - tear) < 2 ? 0.25 : 0
            for x in 0..<columns {
                let r = rng.unit()
                values[y * columns + x] = Float(min(1, r * r * 0.3 + glow * rng.unit() + torn * rng.unit()))
            }
        }
    }

    func advance(_ dt: Double) {
        time += dt; pending += dt
        if pending >= 1.0 / 15 { pending = min(pending - 1.0 / 15, 1.0 / 15); regenerate() }
    }

    func render(into frame: ScreensaverFrame) {
        for (i, v) in values.enumerated() where v > 0.03 {
            frame.fill(CGRect(x: CGFloat(i % columns) * cell, y: CGFloat(i / columns) * cell, width: cell, height: cell), ink: .accent, alpha: Double(v))
        }
    }
}
