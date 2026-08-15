//
//  GameRenderer.swift
//  Qoob
//
//  The seam between the engine-agnostic game core and whatever draws it. The
//  core calls these methods; an implementation (RealityKitRenderer today, a
//  MetalRenderer or other engine tomorrow) decides how to render.
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

    /// The renderer's viewport aspect ratio (width ÷ height). The core uses it
    /// to shape the board so it fills the screen. Returns a sensible portrait
    /// default before the view has been laid out.
    var viewportAspect: Double { get }

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

    /// The target at (col, row) has been satisfied: return the cell to neutral
    /// floor. Nothing should be left marking that it was a target.
    func clearTile(col: Int, row: Int)

    /// A fresh target has appeared: dress the neutral tile at (col, row) with
    /// the depiction and its pulsing highlight.
    func addTarget(col: Int, row: Int, colorIndex: Int)

    /// A roll was refused (wrong face for a target tile): nudge the cube in
    /// `direction` and let it settle back, so the block reads as intentional.
    func rejectRoll(_ direction: RollDirection)

    /// Slide a pushable toy one cell, in sync with the cube's roll.
    func moveItem(from: GridCell, to: GridCell, duration: TimeInterval)

    /// A toy perched on furniture tumbles onto the floor at `landing`, then
    /// becomes a normal pushable toy.
    func knockOffToy(fromFurnitureAt perch: GridCell, to landing: GridCell, duration: TimeInterval)

    /// Enable/disable purely-cosmetic environmental animation (wind, fur, grass,
    /// Qoob's soft-body). Renderers may pause this off screen to save power; the
    /// default is a no-op so a minimal renderer needn't implement it.
    func setEnvironmentActive(_ active: Bool)

    /// Restyle the floor to `theme`, live: re-skins the ground and every neutral
    /// tile (target tiles keep their depiction). Also used at level start.
    func applyFloorTheme(_ theme: FloorTheme)

    /// Lean the camera `radians` off straight-down (0 = top-down). Re-aims live.
    func setBoardTilt(_ radians: Double)
}

extension GameRenderer {
    func setEnvironmentActive(_ active: Bool) {}
}
