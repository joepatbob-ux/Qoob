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
///
/// `Codable` so authored houses can be written to disk — the level builder saves a
/// blueprint made almost entirely of these.
struct GridCell: Hashable, Codable {
    var col: Int
    var row: Int
}

/// A roll across one grid cell. This is pure *game* semantics — grid movement
/// and how the faces permute. Anything visual (pivot edge, rotation axis) lives
/// in the renderer, derived from the same case.
/// Also used for which way a piece of furniture faces, which is why it carries a raw
/// value and `Codable`: an authored house saves its furniture's facing.
enum RollDirection: String, CaseIterable, Codable {
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
    /// Which surface level Qoob is standing on: 0 on the floor, higher on furniture.
    var level: Int = 0
    var colors: [Face: Int]

    /// Palette index currently on the bottom face — the one a tile must match.
    var downColorIndex: Int { colors[.down] ?? 0 }

    var cell: GridCell { GridCell(col: col, row: row) }

    /// The face currently pointing the way `direction` goes — the one that will land
    /// on the floor after that roll.
    ///
    /// Note `.forward` maps to `.back` and vice versa: `.front` faces increasing row,
    /// which is *toward* the viewer, while `.forward` travel decreases it. Read
    /// straight off `applyRoll`'s `colors[.down] = old[...]` line for each direction,
    /// so the two can't drift apart.
    static func leadingFace(_ direction: RollDirection) -> Face {
        switch direction {
        case .right:   return .right
        case .left:    return .left
        case .forward: return .back
        case .back:    return .front
        }
    }

    /// Which symbol is on the face pointing `direction`.
    func symbol(facing direction: RollDirection) -> Int {
        colors[CubeState.leadingFace(direction)] ?? 0
    }

    /// Which symbol is on top.
    var upSymbol: Int { colors[.up] ?? 0 }

    /// Whether Qoob is set to spring up onto something in `direction`: head up, feet
    /// pointing at it — a cat gathered to jump.
    ///
    /// It pays off on landing: the roll brings the leading face to the floor, so feet
    /// pointing at the step become feet on top of it. Qoob lands standing.
    func canClimb(_ direction: RollDirection) -> Bool {
        upSymbol == CatSymbol.face.rawValue
            && symbol(facing: direction) == CatSymbol.paws.rawValue
    }

    /// Whether Qoob is set to drop off an edge in `direction`: standing on their feet,
    /// looking the way they're about to go.
    ///
    /// Deliberately *not* "head up and feet down", which is what the descent pose
    /// sounds like but cannot exist. The head starts on `.front` and the paws on
    /// `.down` — perpendicular faces — and no rotation of a rigid cube brings two
    /// perpendicular faces opposite, so head-up-and-feet-down is unreachable from any
    /// orientation. Requiring it would refuse every descent for ever.
    ///
    /// Feet down with the head leading is the reachable mirror of `canClimb` — the two
    /// swap which face is up and which leads — and it's the better pose regardless: a
    /// cat at the edge is stood on its feet, looking down at where it means to land.
    /// It also can't strand anyone: a climb leaves the feet down and the head facing
    /// the way it climbed, which is already a legal drop straight on over the far side.
    func canDrop(_ direction: RollDirection) -> Bool {
        downColorIndex == CatSymbol.paws.rawValue
            && symbol(facing: direction) == CatSymbol.face.rawValue
    }

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
