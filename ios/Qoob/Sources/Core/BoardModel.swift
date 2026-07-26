//
//  BoardModel.swift
//  Qoob
//
//  Pure grid model + match logic. No rendering — the renderer builds tile
//  visuals from this and is told (via GameRenderer.clearTile) when a target is
//  satisfied.
//

import Foundation

/// One cell's game state.
struct CellModel {
    var target: Int?          // palette index this tile wants, or nil (neutral)
    var cleared: Bool = false
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

    init(level: Level) {
        width = level.width
        height = level.height
        blocked = level.blocked
        items = Set(level.items)
        itemGoals = Set(level.itemGoals)
        cells = Array(
            repeating: Array(repeating: CellModel(), count: level.width),
            count: level.height
        )
        for t in level.targets where t.row >= 0 && t.row < height && t.col >= 0 && t.col < width {
            cells[t.row][t.col].target = t.colorIndex
        }
        remaining = level.targets.count
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

    var totalItems: Int { items.count }
    var itemsOnGoals: Int { items.intersection(itemGoals).count }
    var itemsRemaining: Int { max(0, totalItems - itemsOnGoals) }

    func cell(col: Int, row: Int) -> CellModel? {
        guard contains(col: col, row: row) else { return nil }
        return cells[row][col]
    }

    var isComplete: Bool { remaining == 0 }

    /// Distinct symbol indices still needed (uncleared targets), sorted — for
    /// the HUD "still to find" legend.
    func remainingTargetSymbols() -> [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        for row in 0..<height {
            for col in 0..<width {
                let c = cells[row][col]
                if let t = c.target, !c.cleared, !seen.contains(t) {
                    seen.insert(t)
                    out.append(t)
                }
            }
        }
        return out.sorted()
    }

    /// Attempts to satisfy the tile under the cube. Returns `true` if a target
    /// was newly cleared (down face matched an uncleared target).
    func tryMatch(col: Int, row: Int, downColor: Int) -> Bool {
        guard contains(col: col, row: row) else { return false }
        guard let target = cells[row][col].target,
              !cells[row][col].cleared,
              target == downColor else { return false }

        cells[row][col].cleared = true
        remaining = max(0, remaining - 1)
        return true
    }
}
