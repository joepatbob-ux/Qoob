//
//  Level.swift
//  Qoob
//
//  A level is a grid size, a cube start cell, a time limit, and a set of
//  target tiles. Levels are generated procedurally so the game is endlessly
//  playable without any external asset files.
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

    /// Every target colour is reachable by rolling (the cube carries all six
    /// colours), and every target *cell* is placed only in the region the cube
    /// can actually reach around the furniture — so levels are always solvable.
    static func generate(index: Int, seed: UInt64? = nil) -> Level {
        var rng = SeededGenerator(seed: seed ?? UInt64(0xE7D0 &+ UInt64(index) &* 2654435761))

        // Grid grows gently with progression, capped for phone screens.
        let size = min(5 + index / 2, 8)
        let start = GridCell(col: size / 2, row: size / 2)
        let env = Environment.forLevel(index)

        // --- Place furniture (impassable), from this environment's set ---
        let pieceCount = min(1 + index / 2, max(1, (size * size) / 8))
        var furniture: [Furniture] = []
        var blocked = Set<GridCell>()

        func fits(_ f: Furniture) -> Bool {
            for cell in f.cells {
                if cell.col < 0 || cell.col >= size || cell.row < 0 || cell.row >= size { return false }
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
            let origin = GridCell(col: Int(rng.next() % UInt64(size)),
                                  row: Int(rng.next() % UInt64(size)))
            let piece = Furniture(kind: kind, origin: origin, cols: fp.cols, rows: fp.rows)
            guard fits(piece) else { continue }
            // Keep the reachable area connected & roomy.
            var candidate = blocked
            for c in piece.cells { candidate.insert(c) }
            let reach = reachable(from: start, size: size, blocked: candidate).count
            if reach < (size * size) - (size * size) / 3 { continue }  // don't wall off too much
            furniture.append(piece)
            blocked = candidate
        }

        let reach = reachable(from: start, size: size, blocked: blocked)

        // --- Targets, only on reachable free cells ---
        let freeReachable = reach.subtracting([start])
        let maxTargets = max(1, freeReachable.count)
        let targetCount = min(3 + index, maxTargets)

        var placed = Set<GridCell>()
        var targets: [Target] = []
        var tAttempts = 0
        let pool = Array(freeReachable)
        while targets.count < targetCount && tAttempts < 800 && !pool.isEmpty {
            tAttempts += 1
            let cell = pool[Int(rng.next() % UInt64(pool.count))]
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
            if landing.col < 0 || landing.col >= size || landing.row < 0 || landing.row >= size { continue }
            if blocked.contains(landing) || !reach.contains(landing) { continue }
            if landing == start || usedItems.contains(landing) { continue }
            if perched.contains(where: { $0.perch == perch || $0.landing == landing }) { continue }
            perched.append(PerchedToy(perch: perch, landing: landing))
            usedItems.insert(landing)
        }

        return Level(index: index,
                     width: size, height: size,
                     startCol: start.col, startRow: start.row,
                     targets: targets,
                     furniture: furniture,
                     blocked: blocked,
                     items: items,
                     itemGoals: goals,
                     environment: env,
                     perched: perched)
    }

    /// 4-neighbour flood fill of cells reachable from `start` without entering
    /// a blocked (furniture) cell.
    private static func reachable(from start: GridCell, size: Int,
                                  blocked: Set<GridCell>) -> Set<GridCell> {
        var seen = Set<GridCell>()
        var stack = [start]
        seen.insert(start)
        let deltas = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        while let cur = stack.popLast() {
            for (dc, dr) in deltas {
                let n = GridCell(col: cur.col + dc, row: cur.row + dr)
                if n.col < 0 || n.col >= size || n.row < 0 || n.row >= size { continue }
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
