//
//  BoardModel.swift
//  TiltCube
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

    init(level: Level) {
        width = level.width
        height = level.height
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

    func cell(col: Int, row: Int) -> CellModel? {
        guard contains(col: col, row: row) else { return nil }
        return cells[row][col]
    }

    var isComplete: Bool { remaining == 0 }

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
