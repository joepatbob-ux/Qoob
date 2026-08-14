//
//  Level.swift
//  Qoob
//
//  A level is a grid size, a cube start cell, and a set of target tiles. The
//  grid is shaped to the screen's aspect ratio so it fills the display. Levels
//  are generated procedurally so the game is endlessly playable without any
//  external asset files.
//

import Foundation

struct Target {
    let col: Int
    let row: Int
    let colorIndex: Int
}

/// A toy perched on a furniture cell; rolling the cat into that furniture
/// knocks it onto `landing` (a free floor cell) for bonus points.
struct PerchedToy {
    let perch: GridCell     // the furniture cell it sits on
    let landing: GridCell   // where it falls to
}

struct Level {
    let index: Int
    let width: Int
    let height: Int
    let startCol: Int
    let startRow: Int
    let targets: [Target]
    let furniture: [Furniture]
    let blocked: Set<GridCell>
    let items: [GridCell]        // pushable toys' start cells
    let itemGoals: [GridCell]    // spots to push them onto (bonus points)
    let environment: Environment
    let perched: [PerchedToy]    // toys sitting on furniture to knock off
    let targetRows: Range<Int>   // rows where targets may appear (not under the HUD)

    /// Every target colour is reachable by rolling (the cube carries all six
    /// colours), and every target *cell* is placed only in the region the cube
    /// can actually reach around the furniture — so levels are always solvable.
    static func generate(index: Int, aspect: Double = 0.46, seed: UInt64? = nil) -> Level {
        var rng = SeededGenerator(seed: seed ?? UInt64(0xE7D0 &+ UInt64(index) &* 2654435761))

        // The board fills the screen, so its shape follows the view's aspect
        // ratio: a fixed cell count on the short side, more on the long side.
        // A denser grid (more, smaller cells) reads better full-screen; both
        // grow gently with progression, capped for phone screens.
        let shortCells = min(7 + index / 2, 9)
        let longCap = 15
        let width: Int
        let height: Int
        if aspect >= 1 {
            height = shortCells                                  // landscape: wider than tall
            width = max(shortCells, min(longCap, Int((Double(shortCells) * aspect).rounded())))
        } else {
            width = shortCells                                   // portrait: taller than wide
            height = max(shortCells, min(longCap, Int((Double(shortCells) / aspect).rounded())))
        }
        let cellCount = width * height
        let start = GridCell(col: width / 2, row: height / 2)
        let env = Environment.forLevel(index)

        // Reserve the top rows the header overlays and the bottom rows the D-pad
        // overlays, so targets never spawn under the controls. Fall back to the
        // whole board if reserving would leave too little room.
        let topReserved = Int((Double(height) * 0.18).rounded(.up))
        let bottomReserved = Int((Double(height) * 0.26).rounded(.up))
        var rowLo = topReserved
        var rowHi = height - bottomReserved
        if rowHi - rowLo < 3 { rowLo = 0; rowHi = height }
        let targetRows = rowLo..<rowHi

        // --- Place furniture (impassable), from this environment's set ---
        let pieceCount = min(1 + index / 2, max(1, cellCount / 8))
        var furniture: [Furniture] = []
        var blocked = Set<GridCell>()

        func fits(_ f: Furniture) -> Bool {
            for cell in f.cells {
                if cell.col < 0 || cell.col >= width || cell.row < 0 || cell.row >= height { return false }
                if cell == start { return false }
                if blocked.contains(cell) { return false }
            }
            return true
        }

        var attempts = 0
        while furniture.count < pieceCount && attempts < 300 {
            attempts += 1
            let kind = env.furnitureKinds[Int(rng.next() % UInt64(env.furnitureKinds.count))]
            let fp = kind.footprints[Int(rng.next() % UInt64(kind.footprints.count))]
            let origin = GridCell(col: Int(rng.next() % UInt64(width)),
                                  row: Int(rng.next() % UInt64(height)))
            let piece = Furniture(kind: kind, origin: origin, cols: fp.cols, rows: fp.rows)
            guard fits(piece) else { continue }
            // Keep the reachable area connected & roomy.
            var candidate = blocked
            for c in piece.cells { candidate.insert(c) }
            let reach = reachable(from: start, width: width, height: height, blocked: candidate).count
            if reach < cellCount - cellCount / 3 { continue }  // don't wall off too much
            furniture.append(piece)
            blocked = candidate
        }

        let reach = reachable(from: start, width: width, height: height, blocked: blocked)

        // --- Targets, only on reachable free cells ---
        let freeReachable = reach.subtracting([start])
        let maxTargets = max(1, freeReachable.count)
        let targetCount = min(3 + index, maxTargets)

        var placed = Set<GridCell>()
        var targets: [Target] = []
        var tAttempts = 0
        // Sorted, not just `Array(...)`: `Set` iteration order depends on a
        // per-process hash seed, so indexing an unsorted pool with the seeded
        // RNG made a level index generate a *different* board every launch —
        // defeating the whole point of the deterministic generator.
        let pool = sortedCells(freeReachable)
        // Targets draw from cells outside the reserved (HUD-covered) rows.
        let restricted = freeReachable.filter { targetRows.contains($0.row) }
        let targetPool = sortedCells(restricted.isEmpty ? freeReachable : restricted)
        while targets.count < targetCount && tAttempts < 800 && !targetPool.isEmpty {
            tAttempts += 1
            let cell = targetPool[Int(rng.next() % UInt64(targetPool.count))]
            if placed.contains(cell) { continue }
            placed.insert(cell)
            let color = Int(rng.next() % UInt64(GamePalette.count))
            targets.append(Target(col: cell.col, row: cell.row, colorIndex: color))
        }

        // --- Pushable toys (bonus): each placed so a single push solves it ---
        // For goal G and push direction d: item sits at I = G-d and the cat can
        // stand at S = G-2d, so rolling from S in +d shoves the toy onto G.
        let itemCount = min(index / 3, 3)
        var items: [GridCell] = []
        var goals: [GridCell] = []
        var usedItems = blocked.union(placed).union([start])
        let dirs = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        var iAttempts = 0
        while items.count < itemCount && iAttempts < 400 && !pool.isEmpty {
            iAttempts += 1
            let g = pool[Int(rng.next() % UInt64(pool.count))]
            let (dc, dr) = dirs[Int(rng.next() % 4)]
            let itemCell = GridCell(col: g.col - dc, row: g.row - dr)
            let stand = GridCell(col: g.col - 2 * dc, row: g.row - 2 * dr)
            let needed = [g, itemCell, stand]
            if Set(needed).count != 3 { continue }
            if !needed.allSatisfy({ reach.contains($0) && !usedItems.contains($0) }) { continue }
            items.append(itemCell)
            goals.append(g)
            needed.forEach { usedItems.insert($0) }
        }

        // --- Perched toys on furniture (knock-off bonus) ---
        let perchCount = min(index / 4, 2)
        var perched: [PerchedToy] = []
        var pAttempts = 0
        while perched.count < perchCount && pAttempts < 200 && !furniture.isEmpty {
            pAttempts += 1
            let piece = furniture[Int(rng.next() % UInt64(furniture.count))]
            let perch = piece.cells[Int(rng.next() % UInt64(piece.cells.count))]
            let (dc, dr) = dirs[Int(rng.next() % 4)]
            let landing = GridCell(col: perch.col + dc, row: perch.row + dr)
            if landing.col < 0 || landing.col >= width || landing.row < 0 || landing.row >= height { continue }
            if blocked.contains(landing) || !reach.contains(landing) { continue }
            if landing == start || usedItems.contains(landing) { continue }
            if perched.contains(where: { $0.perch == perch || $0.landing == landing }) { continue }
            perched.append(PerchedToy(perch: perch, landing: landing))
            usedItems.insert(landing)
        }

        return Level(index: index,
                     width: width, height: height,
                     startCol: start.col, startRow: start.row,
                     targets: targets,
                     furniture: furniture,
                     blocked: blocked,
                     items: items,
                     itemGoals: goals,
                     environment: env,
                     perched: perched,
                     targetRows: targetRows)
    }

    /// Cells in a stable row-major order, so a seeded RNG indexing them picks
    /// the same cell on every launch.
    private static func sortedCells(_ cells: Set<GridCell>) -> [GridCell] {
        cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
    }

    /// 4-neighbour flood fill of cells reachable from `start` without entering
    /// a blocked (furniture) cell.
    private static func reachable(from start: GridCell, width: Int, height: Int,
                                  blocked: Set<GridCell>) -> Set<GridCell> {
        var seen = Set<GridCell>()
        var stack = [start]
        seen.insert(start)
        let deltas = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        while let cur = stack.popLast() {
            for (dc, dr) in deltas {
                let n = GridCell(col: cur.col + dc, row: cur.row + dr)
                if n.col < 0 || n.col >= width || n.row < 0 || n.row >= height { continue }
                if blocked.contains(n) || seen.contains(n) { continue }
                seen.insert(n)
                stack.append(n)
            }
        }
        return seen
    }

    /// The cube-cat's face layout at level start:
    /// front = face, up = butt, down = 4 paws, left = dot, right = ring,
    /// back = three dots (triangle). Indices are CatSymbol raw values.
    static func startingFaces() -> [Face: Int] {
        [.front: CatSymbol.face.rawValue,
         .up:    CatSymbol.butt.rawValue,
         .down:  CatSymbol.paws.rawValue,
         .left:  CatSymbol.dot.rawValue,
         .right: CatSymbol.ring.rawValue,
         .back:  CatSymbol.triangle.rawValue]
    }
}

/// Small deterministic PRNG (SplitMix64) so a given level index always
/// generates the same board — handy for testing and fair for scoring.
struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
