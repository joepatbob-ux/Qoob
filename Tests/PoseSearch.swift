//
//  PoseSearch.swift
//  QoobTests
//
//  Exhaustive search over the states Qoob can actually reach.
//
//  The one thing to understand about this file: **reachability here is over
//  (cell, orientation) pairs, not cells.** A climb is only legal from the gathered
//  pose (head up, paws pointing at the step) and a drop only from its mirror, so
//  whether Qoob can get somewhere depends on which way up they arrive. Flood-fill
//  over cells answers a different question, and every invariant bug found while the
//  generator was being written lived precisely in that gap: a mound whose top tier
//  was reachable on paper because the cells connect, but not in play because you
//  always arrive facing the wrong way.
//
//  This mirrors `GameController.hasAnyLegalMove` and `requestRoll`. If those rules
//  change, this has to change with them — which is the point of having it once.
//

import Foundation
@testable import Qoob

/// A search state: where Qoob is, and which way up.
///
/// The orientation has to be part of the key. Keying on the cell alone collapses
/// six distinct states into one and reports places reachable that aren't.
struct PoseKey: Hashable {
    let col: Int
    let row: Int
    let faces: [Int]

    init(_ cube: CubeState) {
        col = cube.col
        row = cube.row
        // Ordered by the face's raw value so the key is stable.
        faces = Face.allCases.sorted { $0.rawValue < $1.rawValue }.map { cube.colors[$0] ?? -1 }
    }
}

/// The result of exploring a house from its start.
struct PoseSearchResult {
    /// Every reachable `(cell, orientation)` state.
    let states: Set<PoseKey>
    /// Cells standable in at least one reachable orientation.
    let cells: Set<GridCell>
    /// States from which no move at all is possible — a softlock. Should be empty.
    let deadEnds: [PoseKey]
}

enum PoseSearch {
    /// Whether a roll is legal ignoring the escape hatch.
    ///
    /// Mirrors the `hasAnyLegalMove` closure in `GameController`: geometry first, then
    /// the pose gate for a climb or a drop. Flat moves have no pose requirement.
    static func isStrictlyLegal(_ direction: RollDirection,
                                board: BoardModel, cube: CubeState) -> Bool {
        let (dCol, dRow) = direction.gridDelta
        let target = GridCell(col: cube.col + dCol, row: cube.row + dRow)
        guard board.canMove(from: cube.cell, to: target) else { return false }
        let climb = board.surfaceLevel(at: target) - cube.level
        if climb > 0 { return cube.canClimb(direction) }
        if climb < 0 { return cube.canDrop(direction) }
        return true
    }

    /// Whether any strictly-legal move exists — the condition the escape hatch waits on.
    static func hasStrictMove(board: BoardModel, cube: CubeState) -> Bool {
        RollDirection.allCases.contains { isStrictlyLegal($0, board: board, cube: cube) }
    }

    /// Whether a roll is legal *as the game plays it*, escape hatch included.
    ///
    /// The hatch opens only when nothing strict is available, which is why it can't be
    /// exploited to skip the pose rules — and why it has to be modelled here, or the
    /// search reports softlocks the player would never experience.
    static func isLegal(_ direction: RollDirection,
                        board: BoardModel, cube: CubeState) -> Bool {
        let (dCol, dRow) = direction.gridDelta
        let target = GridCell(col: cube.col + dCol, row: cube.row + dRow)
        guard board.canMove(from: cube.cell, to: target) else { return false }
        let climb = board.surfaceLevel(at: target) - cube.level
        if climb == 0 { return true }
        let posed = climb > 0 ? cube.canClimb(direction) : cube.canDrop(direction)
        return posed || !hasStrictMove(board: board, cube: cube)
    }

    /// Breadth-first over reachable poses from `start`.
    static func explore(board: BoardModel, start: CubeState) -> PoseSearchResult {
        var seen: Set<PoseKey> = [PoseKey(start)]
        var cells: Set<GridCell> = [start.cell]
        var deadEnds: [PoseKey] = []
        var queue = [start]
        var head = 0

        while head < queue.count {
            let cube = queue[head]; head += 1
            var moved = false
            for direction in RollDirection.allCases {
                guard isLegal(direction, board: board, cube: cube) else { continue }
                moved = true
                var next = cube
                next.applyRoll(direction)
                next.level = board.surfaceLevel(at: next.cell)
                let key = PoseKey(next)
                if seen.insert(key).inserted {
                    cells.insert(next.cell)
                    queue.append(next)
                }
            }
            if !moved { deadEnds.append(PoseKey(cube)) }
        }
        return PoseSearchResult(states: seen, cells: cells, deadEnds: deadEnds)
    }

    /// Explores a generated level from its own start position.
    static func explore(_ level: Level) -> PoseSearchResult {
        let board = BoardModel(level: level)
        var cube = CubeState(col: level.startCol, row: level.startRow,
                             colors: Level.startingFaces())
        cube.level = board.surfaceLevel(at: cube.cell)
        return explore(board: board, start: cube)
    }
}
