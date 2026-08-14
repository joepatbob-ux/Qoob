//
//  BoardModel.swift
//  Qoob
//
//  Pure grid model + match logic. No rendering — the renderer builds tile
//  visuals from this and is told (via GameRenderer) when a target is satisfied
//  and when a fresh one appears.
//
//  Endless model: a target tile blocks the cube unless the face landing on it
//  matches (the controller enforces this using `target(at:)`). A matched tile
//  clears and `spawnTarget` places a new one elsewhere, so the game never ends.
//

import Foundation

/// One cell's game state.
struct CellModel {
    var target: Int?          // palette index this tile wants, or nil (neutral)
}

/// A W×H grid of cells and the colour-matching rules over it.
final class BoardModel {

    let width: Int
    let height: Int
    private(set) var cells: [[CellModel]]     // cells[row][col]
    private(set) var remaining: Int
    let blocked: Set<GridCell>                // furniture cells (impassable)
    private(set) var items: Set<GridCell>     // pushable toys' current cells
    let itemGoals: Set<GridCell>              // spots that score when covered
    private(set) var perched: [GridCell: GridCell]  // furniture cell → landing cell

    /// The connected free region the cube can roll around — where fresh targets
    /// may spawn so they're always reachable.
    private let reachable: Set<GridCell>
    /// Rows where targets may appear (never under the HUD controls).
    private let targetRows: Range<Int>
    /// Columns where targets may appear (never bled off the screen edges).
    private let targetCols: Range<Int>
    /// Deterministic source for respawn placement (seeded per level).
    private var rng: SeededGenerator

    init(level: Level) {
        width = level.width
        height = level.height
        blocked = level.blocked
        items = Set(level.items)
        itemGoals = Set(level.itemGoals)
        var perch: [GridCell: GridCell] = [:]
        for p in level.perched { perch[p.perch] = p.landing }
        perched = perch
        cells = Array(
            repeating: Array(repeating: CellModel(), count: level.width),
            count: level.height
        )
        for t in level.targets where t.row >= 0 && t.row < height && t.col >= 0 && t.col < width {
            cells[t.row][t.col].target = t.colorIndex
        }
        remaining = level.targets.count
        reachable = BoardModel.floodFill(
            width: level.width, height: level.height,
            start: GridCell(col: level.startCol, row: level.startRow),
            blocked: level.blocked)
        rng = SeededGenerator(seed: 0xB0A2D_9E37 &+ UInt64(bitPattern: Int64(level.index)) &* 2654435761)
        targetRows = level.targetRows
        targetCols = level.targetCols
    }

    /// 4-neighbour flood fill of the free cells reachable from `start`.
    private static func floodFill(width: Int, height: Int, start: GridCell,
                                  blocked: Set<GridCell>) -> Set<GridCell> {
        var seen: Set<GridCell> = []
        guard start.col >= 0, start.col < width, start.row >= 0, start.row < height,
              !blocked.contains(start) else { return seen }
        var stack = [start]; seen.insert(start)
        let deltas = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        while let cur = stack.popLast() {
            for (dc, dr) in deltas {
                let n = GridCell(col: cur.col + dc, row: cur.row + dr)
                if n.col < 0 || n.col >= width || n.row < 0 || n.row >= height { continue }
                if blocked.contains(n) || seen.contains(n) { continue }
                seen.insert(n); stack.append(n)
            }
        }
        return seen
    }

    func contains(col: Int, row: Int) -> Bool {
        col >= 0 && col < width && row >= 0 && row < height
    }

    /// A furniture cell the cube cannot roll into.
    func isBlocked(col: Int, row: Int) -> Bool {
        blocked.contains(GridCell(col: col, row: row))
    }

    /// On the board and not blocked by furniture.
    func passable(col: Int, row: Int) -> Bool {
        contains(col: col, row: row) && !isBlocked(col: col, row: row)
    }

    // MARK: - Pushable toys

    func hasItem(_ cell: GridCell) -> Bool { items.contains(cell) }
    func isItemGoal(_ cell: GridCell) -> Bool { itemGoals.contains(cell) }

    /// Moves a toy one cell. Returns true if it landed on a goal it wasn't on.
    @discardableResult
    func moveItem(from: GridCell, to: GridCell) -> Bool {
        items.remove(from)
        items.insert(to)
        return itemGoals.contains(to) && !itemGoals.contains(from)
    }

    var itemsOnGoals: Int { items.intersection(itemGoals).count }
    /// Pads still to fill (stable even as knocked-off toys are added).
    var itemsRemaining: Int { max(0, itemGoals.count - itemsOnGoals) }

    // MARK: - Knock-off toys (perched on furniture)

    func perchedLanding(at furnitureCell: GridCell) -> GridCell? {
        perched[furnitureCell]
    }

    /// Knocks a perched toy off its furniture onto the floor. Returns the
    /// landing cell, or nil if there's no perched toy or the landing is now
    /// occupied. The landed toy becomes a normal pushable toy.
    @discardableResult
    func knockOff(at furnitureCell: GridCell) -> GridCell? {
        guard let landing = perched[furnitureCell], !items.contains(landing) else { return nil }
        perched[furnitureCell] = nil
        items.insert(landing)
        return landing
    }

    func cell(col: Int, row: Int) -> CellModel? {
        guard contains(col: col, row: row) else { return nil }
        return cells[row][col]
    }

    /// The palette index a target tile at this cell wants, or nil if the cell
    /// has no active target. The controller uses it to refuse a roll onto a
    /// target unless the face that will land matches.
    func target(at cell: GridCell) -> Int? {
        guard contains(col: cell.col, row: cell.row) else { return nil }
        return cells[cell.row][cell.col].target
    }

    /// Distinct active-target symbol indices, sorted — for the HUD legend.
    func remainingTargetSymbols() -> [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        for row in 0..<height {
            for col in 0..<width {
                if let t = cells[row][col].target, !seen.contains(t) {
                    seen.insert(t)
                    out.append(t)
                }
            }
        }
        return out.sorted()
    }

    /// Attempts to satisfy the tile under the cube. Returns `true` if the down
    /// face matched an active target, which is then removed (it "disappears").
    func tryMatch(col: Int, row: Int, downColor: Int) -> Bool {
        guard contains(col: col, row: row) else { return false }
        guard let target = cells[row][col].target, target == downColor else { return false }

        cells[row][col].target = nil
        remaining = max(0, remaining - 1)
        return true
    }

    /// Places a fresh target of a random symbol on a random empty reachable
    /// cell, keeping the active-target count constant. Returns the new target,
    /// or nil if no free cell exists. `cube` is excluded so none spawns under
    /// the cat, and item cells/goals are avoided.
    @discardableResult
    func spawnTarget(avoiding cube: GridCell) -> Target? {
        // Free, reachable, target-less cells. `onScreenOnly` keeps targets clear of
        // the HUD-covered rows and the columns the full-bleed camera crops off the
        // edges; if that leaves nothing, we relax it as a fallback.
        func freeCells(onScreenOnly: Bool) -> [GridCell] {
            var out: [GridCell] = []
            for cell in reachable where cell != cube {
                if items.contains(cell) || itemGoals.contains(cell) { continue }
                if cells[cell.row][cell.col].target != nil { continue }
                if onScreenOnly && !(targetRows.contains(cell.row)
                                     && targetCols.contains(cell.col)) { continue }
                out.append(cell)
            }
            return out
        }
        var candidates = freeCells(onScreenOnly: true)
        if candidates.isEmpty { candidates = freeCells(onScreenOnly: false) }
        guard !candidates.isEmpty else { return nil }
        // Sort for deterministic indexing (Set iteration order isn't stable).
        candidates.sort { ($0.row, $0.col) < ($1.row, $1.col) }
        let cell = candidates[Int(rng.next() % UInt64(candidates.count))]
        let color = Int(rng.next() % UInt64(GamePalette.count))
        cells[cell.row][cell.col].target = color
        remaining += 1
        return Target(col: cell.col, row: cell.row, colorIndex: color)
    }
}
