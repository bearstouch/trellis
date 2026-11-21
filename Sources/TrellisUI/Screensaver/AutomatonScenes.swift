import CoreGraphics
import Foundation

/// Layout shared by the cell-grid scenes: a status line on top, room for the hint at the bottom.
private struct CellLayout {
    static let top: CGFloat = 30, bottom: CGFloat = 34
    let grid: TorusGrid, cell: CGFloat, origin: CGPoint
    init(size: CGSize, cell: CGFloat) {
        self.cell = cell
        let width = max(4, Int(size.width / cell)), height = max(4, Int((size.height - Self.top - Self.bottom) / cell))
        grid = TorusGrid(width: width, height: height)
        origin = CGPoint(x: (size.width - CGFloat(width) * cell) / 2, y: Self.top)
    }
    func rect(_ i: Int, inset: CGFloat) -> CGRect {
        CGRect(x: origin.x + CGFloat(i % grid.width) * cell + inset, y: origin.y + CGFloat(i / grid.width) * cell + inset, width: cell - inset * 2, height: cell - inset * 2)
    }
}

/// Conway's Game of Life on a torus: newborn cells bright, dying ones leave a fading trail, gliders drop in, and a
/// pattern that settles or dies out starts over. The hacker emblem (a glider) sits in the corner.
@MainActor
final class LifeScene: ScreensaverScene {
    static let glider = [(1, 0), (2, 1), (0, 2), (1, 2), (2, 2)]
    private static let stepInterval = 0.11
    private let layout: CellLayout, size: CGSize
    private var rng: ScreensaverRandom
    private var cells: [UInt8], next: [UInt8], age: [UInt16], trail: [Float]
    private var history: [Int] = []
    private var pending = 0.0
    private(set) var generation = 0, population = 0

    init(size: CGSize, seed: UInt64) {
        self.size = size
        layout = CellLayout(size: size, cell: 12); rng = ScreensaverRandom(seed: seed)
        let n = layout.grid.count
        cells = Array(repeating: 0, count: n); next = cells; age = Array(repeating: 0, count: n); trail = Array(repeating: 0, count: n)
        seedCells()
    }

    private func seedCells() {
        let g = layout.grid
        for i in cells.indices { cells[i] = 0; age[i] = 0 }
        generation = 0; history.removeAll()
        let cx = Double(g.width) / 2, cy = Double(g.height) / 2
        for y in 0..<g.height {
            for x in 0..<g.width {
                let dx = (Double(x) - cx) / cx, dy = (Double(y) - cy) / cy
                if dx * dx + dy * dy < 0.55, rng.chance(0.3) { cells[y * g.width + x] = 1 }
            }
        }
        for _ in 0..<6 { dropGlider(x: rng.below(g.width), y: rng.below(g.height), direction: rng.below(4)) }
        population = cells.reduce(0) { $0 + Int($1) }
    }

    private func dropGlider(x x0: Int, y y0: Int, direction: Int) {
        let g = layout.grid
        for (gx, gy) in Self.glider {
            let x = direction & 1 != 0 ? 2 - gx : gx, y = direction & 2 != 0 ? 2 - gy : gy
            cells[g.row(y0 + y) + g.col(x0 + x)] = 1
        }
    }

    func step() {
        let g = layout.grid
        var alive = 0
        for y in 0..<g.height {
            let up = g.row(y - 1), here = g.row(y), down = g.row(y + 1)
            for x in 0..<g.width {
                let l = g.col(x - 1), r = g.col(x + 1)
                let n = cells[up + l] + cells[up + x] + cells[up + r] + cells[here + l] + cells[here + r] + cells[down + l] + cells[down + x] + cells[down + r]
                let i = here + x, lives = n == 3 || (n == 2 && cells[i] == 1)
                next[i] = lives ? 1 : 0
                if lives {
                    alive += 1; age[i] = cells[i] == 1 ? min(age[i] + 1, 999) : 0; trail[i] = 1
                } else {
                    age[i] = 0
                }
            }
        }
        swap(&cells, &next)
        generation += 1; population = alive
        history.append(alive); if history.count > 50 { history.removeFirst() }
        if generation % 90 == 0 { dropGlider(x: rng.below(g.width), y: 0, direction: rng.below(4)) }
        let stale = history.count == 50 && (history.max() ?? 0) - (history.min() ?? 0) < 5
        if alive < 12 || stale || generation > 1500 { seedCells() }
    }

    func advance(_ dt: Double) {
        pending += dt
        var steps = 0
        while pending > Self.stepInterval, steps < 3 { step(); pending -= Self.stepInterval; steps += 1 }
        if steps == 3 { pending = 0 }
        for i in trail.indices where cells[i] == 0 && trail[i] > 0 { trail[i] = max(0, trail[i] - Float(dt) * 1.4) }
    }

    func render(into frame: ScreensaverFrame) {
        for i in cells.indices where cells[i] == 0 && trail[i] > 0.02 { frame.fill(layout.rect(i, inset: 1), ink: .cyan, alpha: Double(trail[i]) * 0.28) }
        for i in cells.indices where cells[i] == 1 { frame.fill(layout.rect(i, inset: 1), ink: age[i] < 1 ? .bright : .green) }
        let command = "$ life --torus \(layout.grid.width)x\(layout.grid.height)"
        let end = frame.text(command + "   ", x: 24, y: 8, size: 12, ink: .green)
        frame.text("gen \(generation)   pop \(population)", x: end, y: 8, size: 12, ink: .muted)
        // The glider emblem: a 3×3 grid with the glider filled in.
        let cell: CGFloat = 7, ex = size.width - 24 - cell * 3, ey: CGFloat = 5
        for i in 0...3 {
            frame.fill(CGRect(x: ex + CGFloat(i) * cell, y: ey, width: 1, height: cell * 3 + 1), ink: .border)
            frame.fill(CGRect(x: ex, y: ey + CGFloat(i) * cell, width: cell * 3 + 1, height: 1), ink: .border)
        }
        for (gx, gy) in Self.glider { frame.fill(CGRect(x: ex + CGFloat(gx) * cell + 2, y: ey + CGFloat(gy) * cell + 2, width: cell - 3, height: cell - 3), ink: .yellow) }
    }
}

/// Brian's Brain: a cell fires (cyan), is refractory for one step (magenta), then rests. It never settles, so sparks race
/// across the grid; a quiet grid gets a new spark, and one that dies out starts over.
@MainActor
final class BriansBrainScene: ScreensaverScene {
    private static let stepInterval = 0.07
    private let layout: CellLayout
    private var rng: ScreensaverRandom
    /// 0 resting, 1 firing, 2 refractory.
    private var cells: [UInt8], next: [UInt8], glow: [Float]
    private var pending = 0.0, quietSteps = 0
    private(set) var generation = 0, firing = 0

    init(size: CGSize, seed: UInt64) {
        layout = CellLayout(size: size, cell: 10); rng = ScreensaverRandom(seed: seed)
        cells = Array(repeating: 0, count: layout.grid.count); next = cells; glow = Array(repeating: 0, count: cells.count)
        seedCells()
    }

    private func seedCells() {
        let g = layout.grid
        for i in cells.indices { cells[i] = 0 }
        generation = 0; quietSteps = 0
        let cx = Double(g.width) / 2, cy = Double(g.height) / 2
        for y in 0..<g.height {
            for x in 0..<g.width {
                let dx = (Double(x) - cx) / (Double(g.width) * 0.18), dy = (Double(y) - cy) / (Double(g.height) * 0.22)
                if dx * dx + dy * dy < 1, rng.chance(0.35) { cells[y * g.width + x] = 1 }
            }
        }
    }

    private func spark() {
        let g = layout.grid, x0 = rng.below(g.width), y0 = rng.below(g.height)
        for y in 0..<5 { for x in 0..<5 where rng.chance(0.4) { cells[g.row(y0 + y) + g.col(x0 + x)] = 1 } }
    }

    func step() {
        let g = layout.grid
        var count = 0
        for y in 0..<g.height {
            let up = g.row(y - 1), here = g.row(y), down = g.row(y + 1)
            for x in 0..<g.width {
                let i = here + x
                switch cells[i] {
                case 1: next[i] = 2
                case 2: next[i] = 0
                default:
                    let l = g.col(x - 1), r = g.col(x + 1)
                    @inline(__always) func on(_ j: Int) -> Int { cells[j] == 1 ? 1 : 0 }
                    let n = on(up + l) + on(up + x) + on(up + r) + on(here + l) + on(here + r) + on(down + l) + on(down + x) + on(down + r)
                    if n == 2 { next[i] = 1; count += 1; glow[i] = 1 } else { next[i] = 0 }
                }
            }
        }
        swap(&cells, &next)
        generation += 1; firing = count
        let density = Double(count) / Double(g.count)
        quietSteps = density < 0.004 ? quietSteps + 1 : 0
        if quietSteps > 20 || generation > 2400 { seedCells() } else if density < 0.012, rng.chance(0.08) { spark() }
    }

    func advance(_ dt: Double) {
        pending += dt
        var steps = 0
        while pending > Self.stepInterval, steps < 3 { step(); pending -= Self.stepInterval; steps += 1 }
        if steps == 3 { pending = 0 }
        for i in glow.indices where glow[i] > 0 { glow[i] = max(0, glow[i] - Float(dt) * 1.1) }
    }

    func render(into frame: ScreensaverFrame) {
        for i in cells.indices where cells[i] == 0 && glow[i] > 0.02 { frame.fill(layout.rect(i, inset: 1), ink: .blue, alpha: Double(glow[i]) * 0.22) }
        for i in cells.indices where cells[i] == 2 { frame.fill(layout.rect(i, inset: 2), ink: .magenta, alpha: 0.75) }
        for i in cells.indices where cells[i] == 1 { frame.fill(layout.rect(i, inset: 1), ink: .cyan) }
        let end = frame.text("$ brain --rule B2/S/C3 --torus \(layout.grid.width)x\(layout.grid.height)   ", x: 24, y: 8, size: 12, ink: .green)
        frame.text("gen \(generation)   firing \(firing)", x: end, y: 8, size: 12, ink: .muted)
    }
}
