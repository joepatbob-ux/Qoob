//
//  GameRenderer.swift
//  Qoob
//
//  The seam between the engine-agnostic game core and whatever draws it. The
//  core calls these methods; an implementation (SceneKitRenderer today, a
//  RealityKitRenderer or MetalRenderer tomorrow) decides how to render.
//
//  Design contract:
//   • The core owns all game state (BoardModel, CubeState) and rules.
//   • The renderer owns all visuals (meshes, materials, camera, lights,
//     animations) and never mutates game state.
//   • `animateRoll` is the only asynchronous call: it drives the visual roll
//     and invokes `completion` on the main thread once the cube has settled,
//     at which point the core advances its logical state and checks matches.
//
//  Swapping engines = writing one new type that conforms to this protocol.
//  Nothing in Core/ or GameController changes.
//

import Foundation

@MainActor
protocol GameRenderer: AnyObject {

    /// Build (or rebuild) all visuals for a fresh level: board tiles, the cube
    /// in its starting cell/orientation, camera framing and lighting.
    func present(level: Level, board: BoardModel, cube: CubeState)

    /// Animate the cube rolling one cell in `direction`, ending centred on
    /// `target`. Call `completion` on the main thread when the roll settles.
    /// The core has already validated that `target` is on the board.
    func animateRoll(_ direction: RollDirection,
                     to target: GridCell,
                     duration: TimeInterval,
                     completion: @escaping () -> Void)

    /// Play the "target satisfied" flourish for the tile at (col, row).
    func clearTile(col: Int, row: Int, colorIndex: Int)

    /// Slide a pushable toy one cell, in sync with the cube's roll.
    func moveItem(from: GridCell, to: GridCell, duration: TimeInterval)
}
