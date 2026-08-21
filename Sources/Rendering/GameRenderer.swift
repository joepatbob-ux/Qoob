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

    /// Animate the cube rolling one cell in `direction`, ending centred on `target`
    /// standing on surface level `toLevel` (0 = floor, higher = on furniture). Call
    /// `completion` on the main thread once the cube has settled — which for a drop is
    /// after the fall, not after the roll. The core has already validated the move,
    /// including that any climb is within `Level.maxClimb`.
    func animateRoll(_ direction: RollDirection,
                     to target: GridCell,
                     toLevel: Int,
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

    /// Send a shoved toy along `path`, one leg per cell, so a rebound reads as a
    /// rebound. `collected` means the last cell is the basket, and the toy should be
    /// dropped in and retired rather than left sitting there.
    func moveItem(from: GridCell, along path: [GridCell], duration: TimeInterval,
                  collected: Bool)

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

    func setCatStyle(_ style: CatStyle)

    func setRoomAppearance(_ appearance: RoomAppearance)

    /// Lean the camera `radians` off straight-down (0 = top-down). Re-aims live.
    func setBoardTilt(_ radians: Double)

    /// Layers a live-weather/solar adjustment onto the current day/night
    /// preset (Settings › "Match local weather"). `.cheap` only touches
    /// already-inexpensive lights; `.full` additionally re-bakes the
    /// environment map, so the core throttles how often it asks for that —
    /// see `SkySystem`. Optional: a renderer with no sky model of its own
    /// simply ignores this.
    func applySky(_ relight: SkyRelight)

    /// The outdoor weather mood has changed (e.g. clear → rain) — a cue for
    /// spatial effects like precipitation, distinct from `applySky`'s
    /// lighting-only concern. Optional, defaults to a no-op.
    func setSkyCondition(_ condition: SkyCondition)

    /// A lightning strike just occurred: flash briefly, using only lights the
    /// renderer already has. Optional, defaults to a no-op.
    func flashLightning(_ flash: LightningFlash)
}

extension GameRenderer {
    func setEnvironmentActive(_ active: Bool) {}
    func applySky(_ relight: SkyRelight) {}
    func setSkyCondition(_ condition: SkyCondition) {}
    func flashLightning(_ flash: LightningFlash) {}
}
