import CoreGraphics
import Foundation

private let hexDigits = Array("0123456789ABCDEF".utf16)

/// A cyclic cellular automaton with 16 states, each drawn as its hex digit: a cell advances when a neighbour already holds
/// its next state, and random noise organizes itself into rotating spiral waves.
@MainActor
final class HexSpiralsScene: ScreensaverScene {
    static let states = 16
    private static let stepInterval = 0.09, warmUpSteps = 120
    private static let inks: [ScreensaverPalette.Ink] = [.green, .cyan, .blue, .magenta]
    private let cellWidth: CGFloat = 12, cellHeight: CGFloat = 15, top: CGFloat = 30
    private let grid: TorusGrid, originX: CGFloat
    private var rng: ScreensaverRandom
    private var cells: [UInt8], next: [UInt8]
    private var pending = 0.0, stillSteps = 0
    private(set) var generation = 0

    init(size: CGSize, seed: UInt64) {
        grid = TorusGrid(width: max(4, Int(size.width / 12)), height: max(4, Int((size.height - 30 - 34) / 15)))
        originX = (size.width - CGFloat(grid.width) * 12) / 2
        rng = ScreensaverRandom(seed: seed)
        cells = Array(repeating: 0, count: grid.count); next = cells
        seedCells()
    }

    private func seedCells() {
        for i in cells.indices { cells[i] = UInt8(rng.below(Self.states)) }
        generation = 0; stillSteps = 0
        // Skip the noisy start, so spirals are already forming when it appears.
        for _ in 0..<Self.warmUpSteps { step() }
    }

    func step() {
        var changed = 0
        for y in 0..<grid.height {
            let up = grid.row(y - 1), here = grid.row(y), down = grid.row(y + 1)
            for x in 0..<grid.width {
                let i = here + x, target = UInt8((Int(cells[i]) + 1) % Self.states)
                if cells[up + x] == target || cells[down + x] == target || cells[here + grid.col(x - 1)] == target || cells[here + grid.col(x + 1)] == target {
                    next[i] = target; changed += 1
                } else {
                    next[i] = cells[i]
                }
            }
        }
        swap(&cells, &next)
        generation += 1
        stillSteps = Double(changed) < Double(grid.count) * 0.01 ? stillSteps + 1 : 0
    }

    func advance(_ dt: Double) {
        pending += dt
        var steps = 0
        while pending > Self.stepInterval, steps < 3 { step(); pending -= Self.stepInterval; steps += 1 }
        if steps == 3 { pending = 0 }
        if stillSteps > 30 || generation > 4000 { seedCells() }
    }

    func render(into frame: ScreensaverFrame) {
        for i in cells.indices {
            let s = Int(cells[i])
            // Four color bands around the state cycle; brightness climbs within each band.
            let band = s * Self.inks.count / Self.states
            let alpha = 0.35 + 0.65 * Double(s % (Self.states / Self.inks.count) + 1) / Double(Self.states / Self.inks.count)
            frame.glyph(
                hexDigits[s], x: originX + CGFloat(i % grid.width) * cellWidth + cellWidth / 2, y: top + CGFloat(i / grid.width) * cellHeight, size: 12,
                ink: Self.inks[band], alpha: alpha, bold: true)
        }
        let end = frame.text("$ cyclic --states 16 --range 1 --threshold 1   ", x: 24, y: 8, size: 12, ink: .green)
        frame.text("gen \(generation)", x: end, y: 8, size: 12, ink: .muted)
    }
}

/// Plasma waves drawn as text: four drifting sine fields, shaded with ` .:-=+*#%@`, blue in the troughs through cyan to
/// green; the hottest crests flicker as hex digits.
@MainActor
final class PlasmaScene: ScreensaverScene {
    private static let ramp = Array(" .:-=+*#%@".utf16)
    private let cellWidth: CGFloat = 10, cellHeight: CGFloat = 16
    private let columns: Int, rows: Int
    private var time: Double

    init(size: CGSize, seed: UInt64) {
        columns = max(1, Int((size.width / 10).rounded(.up))); rows = max(1, Int((size.height / 16).rounded(.up)))
        var rng = ScreensaverRandom(seed: seed)
        time = rng.unit() * 100
    }

    func advance(_ dt: Double) { time += dt }

    /// The shade level, 0 (blank) through 9, of a cell at the current time.
    func level(column x: Int, row y: Int) -> Int {
        let t = time, w = Double(columns), h = Double(rows)
        let ax = w * (0.5 + 0.3 * sin(t * 0.21)), ay = h * (0.5 + 0.3 * cos(t * 0.17))
        let bx = w * (0.5 + 0.35 * cos(t * 0.13)), by = h * (0.5 + 0.25 * sin(t * 0.23))
        let fx = Double(x), fy = Double(y)
        let d1 = hypot(fx - ax, (fy - ay) * 1.8), d2 = hypot(fx - bx, (fy - by) * 1.8)
        let v = sin(fx * 0.06 + t * 0.9) + sin(fy * 1.8 * 0.05 - t * 0.6) + sin(d1 * 0.12 - t * 1.4) + sin(d2 * 0.09 + t * 1.1)
        let n = (v + 4) / 8
        return min(Self.ramp.count - 1, max(0, Int(pow(n, 1.6) * Double(Self.ramp.count))))
    }

    func render(into frame: ScreensaverFrame) {
        let top = Self.ramp.count - 1, flicker = Int(time * 6)
        for y in 0..<rows {
            for x in 0..<columns {
                let lvl = level(column: x, row: y)
                guard lvl > 0 else { continue }
                let f = Double(lvl) / Double(top)
                let ink: ScreensaverPalette.Ink = f < 0.4 ? .blue : f < 0.75 ? .cyan : f < 0.95 ? .green : .bright
                let code = lvl == top ? hexDigits[((y * columns + x) &* 7 &+ flicker) & 15] : Self.ramp[lvl]
                frame.glyph(code, x: CGFloat(x) * cellWidth + cellWidth / 2, y: CGFloat(y) * cellHeight, size: 14, ink: ink, alpha: 0.25 + 0.75 * f)
            }
        }
    }
}
