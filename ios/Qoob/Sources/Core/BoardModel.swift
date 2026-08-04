//
//  BoardModel.swift
//  Qoob
//
//  Pure grid model + merge logic. Rules borrow Endorfun's Unified Field:
//  match the cube's *top* face, wrong colours block entry, Life Force appears
//  one at a time, and Simple Blocks clear when merged. No rendering here.
//

import Foundation

/// One cell's game state.
struct CellModel {
    /// Colour on this square, if any (nil = empty / passable floor).
    var colorIndex: Int? = nil
    var role: TileRole? = nil
    var cleared: Bool = false
    /// Only the active Life Force pulses / can be merged; queued ones wait off-board.
    var isActiveLifeForce: Bool = false

    var isColouredObstacle: Bool {
        !cleared && colorIndex != nil && role != nil
    }
}

/// Result of attempting to merge the cube with the square under it.
enum MergeResult: Equatable {
    case none
    case lifeForce(colorIndex: Int, spawnedNext: Bool)
    case simpleBlock(colorIndex: Int)
}

/// A W×H grid of cells and the colour-matching rules over it.
final class BoardModel {

    let width: Int
    let height: Int
    private(set) var cells: [[CellModel]]     // cells[row][col]
    /// Life Force still to absorb (including the active one).
    private(set) var lifeForceRemaining: Int
    let blocked: Set<GridCell>                // furniture cells (impassable)
    private(set) var items: Set<GridCell>     // pushable toys' current cells
    let itemGoals: Set<GridCell>              // spots that score when covered
    private(set) var perched: [GridCell: GridCell]  // furniture cell → landing cell

    /// Ordered Life Force spawns after the first (which is already on the board).
    private var lifeForceQueue: [Target]

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

        // Simple Blocks — all present from the start.
        for b in level.blocks {
            guard b.row >= 0, b.row < height, b.col >= 0, b.col < width else { continue }
            cells[b.row][b.col].colorIndex = b.colorIndex
            cells[b.row][b.col].role = .simpleBlock
        }

        // Life Force — only the first is on the field; the rest wait in queue.
        lifeForceQueue = Array(level.lifeForce.dropFirst())
        lifeForceRemaining = level.lifeForce.count
        if let first = level.lifeForce.first {
            cells[first.row][first.col].colorIndex = first.colorIndex
            cells[first.row][first.col].role = .lifeForce
            cells[first.row][first.col].isActiveLifeForce = true
        }
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

    /// Colour required on the cube's *top* to enter this cell, if any.
    /// Empty / cleared cells need no match. Endorfun: wrong colour = blocked move.
    func requiredTopColor(col: Int, row: Int) -> Int? {
        guard contains(col: col, row: row) else { return nil }
        let c = cells[row][col]
        guard !c.cleared, let color = c.colorIndex, c.role != nil else { return nil }
        if c.role == .lifeForce && !c.isActiveLifeForce { return nil }
        return color
    }

    /// True if the cube may roll onto (col, row) with the given top-face colour.
    func canEnter(col: Int, row: Int, topColor: Int) -> Bool {
        guard passable(col: col, row: row) else { return false }
        if let needed = requiredTopColor(col: col, row: row) {
            return needed == topColor
        }
        return true
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

    var isComplete: Bool { lifeForceRemaining == 0 }

    /// Colour of the currently active Life Force, if any — for the HUD legend.
    func activeLifeForceSymbol() -> Int? {
        for row in 0..<height {
            for col in 0..<width {
                let c = cells[row][col]
                if c.role == .lifeForce, c.isActiveLifeForce, !c.cleared, let idx = c.colorIndex {
                    return idx
                }
            }
        }
        return nil
    }

    /// Merge with the square under the cube using the *top* face colour.
    /// Absorbing Life Force may spawn the next one; returns its cell if so.
    @discardableResult
    func tryMerge(col: Int, row: Int, topColor: Int) -> (MergeResult, GridCell?) {
        guard contains(col: col, row: row) else { return (.none, nil) }
        var cell = cells[row][col]
        guard !cell.cleared,
              let color = cell.colorIndex,
              let role = cell.role,
              color == topColor else { return (.none, nil) }

        if role == .lifeForce && !cell.isActiveLifeForce {
            return (.none, nil)
        }

        cell.cleared = true
        cell.isActiveLifeForce = false
        cells[row][col] = cell

        switch role {
        case .simpleBlock:
            return (.simpleBlock(colorIndex: color), nil)

        case .lifeForce:
            lifeForceRemaining = max(0, lifeForceRemaining - 1)
            var spawned: GridCell? = nil
            if !lifeForceQueue.isEmpty {
                let next = lifeForceQueue.removeFirst()
                var nextCell = cells[next.row][next.col]
                nextCell.colorIndex = next.colorIndex
                nextCell.role = .lifeForce
                nextCell.cleared = false
                nextCell.isActiveLifeForce = true
                cells[next.row][next.col] = nextCell
                spawned = GridCell(col: next.col, row: next.row)
            }
            return (.lifeForce(colorIndex: color, spawnedNext: spawned != nil), spawned)
        }
    }
}
