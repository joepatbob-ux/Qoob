//
//  CoreTypes.swift
//  Qoob
//
//  Pure game-core types. NOTHING here imports a rendering engine (SceneKit,
//  RealityKit, Metal) — the core describes *what* the game is doing and a
//  GameRenderer decides *how* to draw it. Keeping this boundary clean is what
//  lets the renderer be swapped later (e.g. for detailed 3D models) without
//  touching gameplay.
//

import Foundation

/// The six sides of the cube, named in world space (Y up; the renderer is
/// responsible for orienting the camera so these read sensibly on screen).
enum Face: Int, CaseIterable {
    case up, down, left, right, front, back
}

/// A cell on the grid.
struct GridCell: Equatable {
    var col: Int
    var row: Int
}

/// A roll across one grid cell. This is pure *game* semantics — grid movement
/// and how the faces permute. Anything visual (pivot edge, rotation axis) lives
/// in the renderer, derived from the same case.
enum RollDirection: CaseIterable {
    case right   // +col
    case left    // -col
    case forward // -row  (away from the player / up the board)
    case back    // +row  (toward the player / down the board)

    var gridDelta: (dCol: Int, dRow: Int) {
        switch self {
        case .right:   return (1, 0)
        case .left:    return (-1, 0)
        case .forward: return (0, -1)
        case .back:    return (0, 1)
        }
    }
}

/// The cube's logical state: where it sits and which colour is on each face.
/// Rolling permutes the faces exactly as a physical die. The renderer animates
/// the same roll visually, so the two never drift.
struct CubeState {
    var col: Int
    var row: Int
    var colors: [Face: Int]

    /// Palette index currently on the bottom face — the one a tile must match.
    var downColorIndex: Int { colors[.down] ?? 0 }

    var cell: GridCell { GridCell(col: col, row: row) }

    /// Advances position and permutes faces for a roll. Derived from a 90°
    /// pivot of a unit die (see README's roll table).
    mutating func applyRoll(_ direction: RollDirection) {
        let (dCol, dRow) = direction.gridDelta
        col += dCol
        row += dRow

        let old = colors
        switch direction {
        case .right:
            colors[.right] = old[.up];   colors[.down] = old[.right]
            colors[.left]  = old[.down]; colors[.up]   = old[.left]
        case .left:
            colors[.left]  = old[.up];   colors[.down] = old[.left]
            colors[.right] = old[.down]; colors[.up]   = old[.right]
        case .forward:
            colors[.back]  = old[.up];   colors[.down] = old[.back]
            colors[.front] = old[.down]; colors[.up]   = old[.front]
        case .back:
            colors[.front] = old[.up];   colors[.down] = old[.front]
            colors[.back]  = old[.down]; colors[.up]   = old[.back]
        }
    }
}
