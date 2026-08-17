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

/// A room's cells and the colour-matching rules over them.
///
/// `width`/`height` are the room's bounding box — the extent of the `cells` array
/// — while `floor` is the subset of that box which is actually room. For a cut
/// outline (an L, a T) the two differ, and it's `floor` that decides what's on the
/// board: a cut-away corner is as impassable as the world's edge.
final class BoardModel {

    let width: Int
    let height: Int
    let floor: Set<GridCell>
    /// The rooms of the house, so the renderer can floor and wall each one as itself.
    let rooms: [HouseRoom]
    /// Cells joining rooms through a dividing wall. Floor, but in no room's rectangle.
    let doorways: Set<GridCell>
    /// Furniture with no standable top — walls with leaves.
    let solid: Set<GridCell>
    /// Standable surface level per raised cell. Absent means floor level, 0.
    private let surface: [GridCell: Int]
    /// The outdoor mounds, for the renderer to raise. The rules need nothing from these
    /// — a terrace is already in `surface`, so `canMove` climbs it and `canHoldToy`
    /// refuses to let a toy roll up it, both by the existing height checks.
    let hills: [Terrace]
    /// Used for a cell that belongs to no room — a doorway with no neighbour resolved,
    /// which shouldn't happen but shouldn't crash either.
    private let defaultEnvironment: Environment
    private(set) var cells: [[CellModel]]     // cells[row][col]
    private(set) var remaining: Int
    let blocked: Set<GridCell>                // furniture cells (impassable)
    private(set) var items: Set<GridCell>     // pushable toys' current cells
    /// The one basket toys are pushed into.
    let basket: GridCell?
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
        floor = level.floor
        rooms = level.rooms
        doorways = level.doorways
        defaultEnvironment = level.environment
        solid = level.solid
        surface = level.surface
        hills = level.hills
        blocked = level.blocked
        items = Set(level.items)
        basket = level.basket
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
        // Shares Level's flood fill, so what the generator considered reachable and
        // what respawning targets consider reachable can't drift apart.
        reachable = Level.reachable(from: GridCell(col: level.startCol, row: level.startRow),
                                    floor: level.floor,
                                    solid: level.solid,
                                    surface: level.surface)
        rng = SeededGenerator(seed: 0xB0A2D_9E37 &+ level.seed &* 2654435761)
        targetRows = level.targetRows
        targetCols = level.targetCols
    }

    /// Inside the bounding box — i.e. safe to index `cells` with. Not the same as
    /// being in the room; use `isFloor` for that.
    func contains(col: Int, row: Int) -> Bool {
        col >= 0 && col < width && row >= 0 && row < height
    }

    /// Part of the house's floor.
    func isFloor(col: Int, row: Int) -> Bool {
        floor.contains(GridCell(col: col, row: row))
    }

    /// Which room a cell belongs to, and so how it should be floored and walled.
    ///
    /// A doorway sits in the gap between two rooms and belongs to neither rectangle, so
    /// it takes the look of whichever room it adjoins — which keeps a threshold reading
    /// as part of a room rather than as a seam of nothing.
    func environment(at cell: GridCell) -> Environment {
        for room in rooms where room.contains(cell) { return room.kind }
        for (dc, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let n = GridCell(col: cell.col + dc, row: cell.row + dr)
            for room in rooms where room.contains(n) { return room.kind }
        }
        return defaultEnvironment
    }

    /// A furniture cell (of any kind). Not the movement rule — see `canMove`.
    func isBlocked(col: Int, row: Int) -> Bool {
        blocked.contains(GridCell(col: col, row: row))
    }

    /// The level of the standable surface at this cell: 0 for floor, higher for the
    /// top of a climbable piece.
    func surfaceLevel(at cell: GridCell) -> Int { surface[cell] ?? 0 }

    /// Whether this cell has a surface Qoob could stand on at all — in the room and
    /// not one of the solid pieces. Says nothing about being able to *get* there.
    func isStandable(_ cell: GridCell) -> Bool {
        floor.contains(cell) && !solid.contains(cell)
    }

    /// Whether Qoob can roll from `from` to the adjacent cell `to`.
    ///
    /// Up is limited to `Level.maxClimb`; down is unlimited, since falling always
    /// works. This replaces the old flat `passable` check — furniture used to be a
    /// wall, and most of it is now a step.
    func canMove(from: GridCell, to: GridCell) -> Bool {
        guard isStandable(to) else { return false }
        return surfaceLevel(at: to) - surfaceLevel(at: from) <= Level.maxClimb
    }

    /// Where a pushed toy may end up: floor level only, so a toy is never shoved up
    /// onto the furniture where no goal pad can be.
    func canHoldToy(_ cell: GridCell) -> Bool {
        isStandable(cell) && surfaceLevel(at: cell) == 0
    }

    // MARK: - Pushable toys

    func hasItem(_ cell: GridCell) -> Bool { items.contains(cell) }
    func isBasket(_ cell: GridCell) -> Bool { cell == basket }

    /// How far a shoved toy travels before friction stops it, in cells.
    static let toyRollDistance = 5
    /// How many rebounds it gets before it settles.
    static let toyBounces = 2

    /// The path a toy takes when shoved in `direction`, starting at `from` and
    /// excluding it. Empty if it can't move at all.
    ///
    /// A push used to move a toy exactly one cell and refuse outright if that cell was
    /// occupied, which is how toys ended up stuck: one wedged into a corner had no legal
    /// push left in any direction and simply stayed there for the rest of the game. Now
    /// it rolls until something stops it and rebounds off whatever that was — and a
    /// rebound is precisely what backs a toy out of a corner.
    ///
    /// It stops early on the basket, so a toy rolling past its destination still counts.
    func toyPath(from: GridCell, direction: RollDirection) -> [GridCell] {
        var path: [GridCell] = []
        var cell = from
        var (dc, dr) = direction.gridDelta
        var bouncesLeft = BoardModel.toyBounces

        for _ in 0..<BoardModel.toyRollDistance {
            let next = GridCell(col: cell.col + dc, row: cell.row + dr)
            if canHoldToy(next) && !items.contains(next) {
                cell = next
                path.append(cell)
                if cell == basket { break }        // in the basket: nothing further matters
                continue
            }
            // Blocked. Reverse and carry on with what's left of the roll — a real ball
            // would deflect, but on four directions a rebound is the honest equivalent,
            // and it's the behaviour that frees a wedged toy.
            guard bouncesLeft > 0 else { break }
            bouncesLeft -= 1
            dc = -dc; dr = -dr
            let back = GridCell(col: cell.col + dc, row: cell.row + dr)
            // Nowhere to rebound to either — it's boxed in on this axis, so it settles.
            guard canHoldToy(back), !items.contains(back), back != from || path.isEmpty else { break }
            cell = back
            path.append(cell)
            if cell == basket { break }
        }
        return path
    }

    /// Moves a toy to `to`. Returns true if it went into the basket, in which case the
    /// toy is collected rather than left sitting there.
    @discardableResult
    func moveItem(from: GridCell, to: GridCell) -> Bool {
        items.remove(from)
        if to == basket { return true }           // collected
        items.insert(to)
        return false
    }

    /// Toys still loose on the floor.
    var itemsRemaining: Int { items.count }

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
        // the HUD-covered rows and the outermost columns, where the camera's clamp
        // at the room edge would push them under the controls; if that leaves
        // nothing, we relax it as a fallback.
        func freeCells(onScreenOnly: Bool) -> [GridCell] {
            var out: [GridCell] = []
            for cell in reachable where cell != cube {
                if items.contains(cell) || cell == basket { continue }
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
