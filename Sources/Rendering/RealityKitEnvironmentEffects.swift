//
//  RealityKitEnvironmentEffects.swift
//  Qoob
//
//  The RealityKit port of the visual-polish layer: Qoob's soft-body squash, the
//  silhouette fur tufts, and the outdoor grass — all driven by the shared,
//  engine-agnostic `WindSystem` (Environment/WindSystem.swift) and tuned from
//  `VisualTuning`. It is the RealityKit counterpart of the old SceneKit
//  EnvironmentEffectsController + QoobVisualController, ported node-for-node
//  onto RealityKit `Entity`s.
//
//    RealityKitEnvironmentEffects
//      ├─ WindSystem     (shared driver)
//      ├─ Fur            (8 corner tufts on Qoob's art node)
//      ├─ Grass          (clumps for outdoor / yard levels)
//      └─ SoftBody       (Qoob's plush squash / breathing on the art node)
//
//  It runs on its OWN per-frame `SceneEvents.Update` subscription (mirroring
//  FrameAnimator) so every effect advances from one centralized clock. Set
//  `active = false` (via the renderer's setEnvironmentActive) to pause all work
//  off screen. Geometry uses thin boxes rather than cones so it stays on the
//  project's single (iOS-16-capable) code path — a small cosmetic simplification
//  from the SceneKit original.
//

import RealityKit
import UIKit
import Combine

@MainActor
final class RealityKitEnvironmentEffects {

    private let wind: WindSystem
    private let fur: FurEffect
    private let grass: GrassEffect
    private let softBody: SoftBodyEffect

    /// When false, per-frame work is skipped (used off screen to save power).
    var active: Bool = true

    private var subscription: (any Cancellable)?

    init() {
        self.wind = WindSystem()
        self.fur = FurEffect()
        self.grass = GrassEffect()
        self.softBody = SoftBodyEffect()
    }

    /// Begin driving effects from `view`'s per-frame update event.
    func attach(to view: ARView) {
        subscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.tick(dt: event.deltaTime)
        }
    }

    /// (Re)build every effect for a freshly presented level.
    func rebuild(level: Level, board: BoardModel,
                 cubeContainer: Entity, cubeArt: Entity,
                 boardAnchor: Entity, cubeSize: Float) {
        fur.attach(container: cubeContainer, art: cubeArt, cubeSize: cubeSize)
        grass.build(level: level, board: board, into: boardAnchor)
        grass.bindCube(cubeContainer)
        softBody.attach(container: cubeContainer, art: cubeArt)
    }

    /// Kick off Qoob's squash/rebound envelope at the start of a visual roll.
    func beginRoll(duration: TimeInterval) {
        softBody.beginRoll(duration: duration)
    }

    private func tick(dt: TimeInterval) {
        guard active else { return }
        wind.update(dt: dt)
        let sample = wind.sample()
        softBody.update(dt: dt)
        fur.update(time: wind.time, wind: sample)
        grass.update(dt: dt, time: wind.time, wind: sample)
    }
}

// MARK: - Fur: silhouette tufts on Qoob

/// A handful of soft tufts on Qoob's eight corners. They ruffle with the shared
/// wind so the *silhouette* moves while the cube body stays solid and readable.
/// The tufts are children of the art node, so they squash and roll with Qoob.
@MainActor
final class FurEffect {

    var config: FurConfig

    private weak var container: Entity?
    private var tufts: [Tuft] = []

    private struct Tuft {
        let pivot: Entity          // at the corner; we rotate this to ruffle
        let growth: SIMD3<Float>   // outward unit direction the tuft points
        let phase: Double
        let rate: Double
    }

    init(config: FurConfig = VisualTuning.fur) {
        self.config = config
    }

    func attach(container: Entity, art: Entity, cubeSize: Float) {
        tufts.forEach { $0.pivot.removeFromParent() }
        tufts.removeAll()
        self.container = container

        guard config.enabled else { return }

        let h = cubeSize / 2.0
        let corners: [SIMD3<Float>] = [
            [-1, -1, -1], [1, -1, -1], [-1, 1, -1], [1, 1, -1],
            [-1, -1,  1], [1, -1,  1], [-1, 1,  1], [1, 1,  1]
        ]

        for (i, c) in corners.enumerated() {
            let g = normalize(c)
            let pivot = Entity()
            pivot.position = c * h
            pivot.addChild(makeTuft(growth: g))
            art.addChild(pivot)

            tufts.append(Tuft(pivot: pivot,
                              growth: g,
                              phase: Double(i) * 0.79,
                              rate: config.swayRate * (0.85 + 0.05 * Double(i))))
        }
    }

    /// Lean each tuft toward the (Qoob-local) wind direction, plus a tiny idle
    /// ruffle. Barely visible in calm air, leaning during gusts.
    func update(time: Double, wind: WindSample) {
        guard config.enabled, let container = container, !tufts.isEmpty else { return }

        // Wind is a world-space ground vector; convert into the cube's local
        // frame so tufts lean correctly whatever orientation Qoob rolled to.
        let worldWind = f3(wind.dx, 0, wind.dz)
        let windLocal = container.convert(direction: worldWind, from: nil)

        for t in tufts {
            let idle = config.baseSway * sin(time * t.rate + t.phase)
            let bend = Float(min(config.maxBend, config.windResponse * wind.strength + abs(idle)))

            // Bend axis is perpendicular to both the tuft's growth direction and
            // the wind — tilting the tuft's tip toward the wind.
            let axis = cross(t.growth, windLocal)
            let mag = length(axis)
            if mag < 1e-5 {
                // Wind ~parallel to the tuft: idle wobble about a stable axis.
                t.pivot.orientation = simd_quatf(angle: Float(idle), axis: [1, 0, 0])
            } else {
                t.pivot.orientation = simd_quatf(angle: bend, axis: axis / mag)
            }
        }
    }

    /// A single soft tuft: a slim box pointing outward along `growth`. (A box,
    /// not a cone, so we stay on one deployment path — see file header.)
    private func makeTuft(growth g: SIMD3<Float>) -> Entity {
        let h = Float(config.tuftHeight)
        let w = Float(config.tuftBaseRadius) * 2
        let mesh = MeshResource.generateBox(width: w, height: h, depth: w, cornerRadius: w * 0.5)
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: 0.86, green: 0.83, blue: 0.80, alpha: 1))
        m.roughness = 1.0
        m.metallic = 0.0
        let box = ModelEntity(mesh: mesh, materials: [m])
        box.position = [0, h / 2, 0]          // base at the pivot, grows +Y

        // Orient +Y onto the outward corner direction.
        let holder = Entity()
        holder.addChild(box)
        holder.orientation = simd_quatf(from: [0, 1, 0], to: g)
        return holder
    }
}

// MARK: - Grass

/// One swaying grass clump. Holds its own phase/rate (so a field desyncs) and a
/// smoothed interaction-bend that eases back to zero after Qoob passes.
@MainActor
final class GrassClump {
    let node: Entity           // pivot at the base (ground); rotate to sway
    let basePos: SIMD3<Float>
    let phase: Double
    let rate: Double
    let strengthScale: Double  // per-clump wind susceptibility

    var bendX: Double = 0      // smoothed lean from Qoob's proximity (ground vec)
    var bendZ: Double = 0

    init(node: Entity, basePos: SIMD3<Float>, phase: Double, rate: Double,
         strengthScale: Double) {
        self.node = node
        self.basePos = basePos
        self.phase = phase
        self.rate = rate
        self.strengthScale = strengthScale
    }
}

/// Builds and animates the outdoor grass. Grass exists only for `.yard` levels;
/// indoors this holds nothing and does no per-frame work. Qoob's world position
/// is read live so nearby clumps bend away as it passes.
@MainActor
final class GrassEffect {

    var config: GrassConfig
    private var clumps: [GrassClump] = []
    private weak var cube: Entity?

    init(config: GrassConfig = VisualTuning.grass) {
        self.config = config
    }

    func clear() {
        clumps.forEach { $0.node.removeFromParent() }
        clumps.removeAll()
    }

    /// (Re)build grass for a level. No-op unless it's an outdoor (yard) level.
    func build(level: Level, board: BoardModel, into parent: Entity) {
        clear()
        // Grass grows where there's grass. Per cell now the house has several rooms:
        // the yard sprouts tufts and the patio beside it doesn't, rather than the whole
        // house taking its cue from whichever room Qoob happened to start in.
        guard level.rooms.contains(where: { $0.kind.ground == .grass }) else { return }

        var rng = SeededGenerator(seed: 0x6A55 &+ level.seed &* 2246822519)
        let w = board.width, h = board.height

        // Cells kept clear of grass (readability + fairness).
        var occupied = level.blocked
        for t in level.targets { occupied.insert(GridCell(col: t.col, row: t.row)) }
        for c in level.items { occupied.insert(c) }
        if let basket = level.basket { occupied.insert(basket) }
        occupied.insert(GridCell(col: level.startCol, row: level.startRow))

        // Sparse short tufts on free interior cells (these interact with Qoob).
        for row in 0..<h {
            for col in 0..<w {
                if clumps.count >= config.maxClumps { break }
                let cell = GridCell(col: col, row: row)
                // Only inside the room. A cut-away corner is outside the fence, so
                // grass there belongs to the border ring below, not underfoot.
                if !board.isFloor(col: col, row: row) { continue }
                if board.environment(at: cell).ground != .grass { continue }
                if occupied.contains(cell) { continue }
                if frac(&rng) > config.interiorDensity { continue }
                let jx = (frac(&rng) - 0.5) * 0.5
                let jz = (frac(&rng) - 0.5) * 0.5
                addClump(at: f3(Double(col) + jx, 0, Double(row) + jz),
                         height: config.interiorHeight, rng: &rng, into: parent)
            }
        }

        // A lush ring just outside the room for a diorama feel (never underfoot),
        // rooted slightly below the play tiles' top surface.
        //
        // Follows the room's outline rather than its bounding box: any cell that
        // isn't floor but touches floor. For a cut shape the two differ, and ringing
        // the box would leave grass sprouting in mid-air across the cut-away corner
        // while the actual fence line had none.
        let borderY = -0.12
        for col in -1...w {
            for row in -1...h {
                if clumps.count >= config.maxClumps { break }
                if board.isFloor(col: col, row: row) { continue }
                let neighbours = [GridCell(col: col + 1, row: row), GridCell(col: col - 1, row: row),
                                  GridCell(col: col, row: row + 1), GridCell(col: col, row: row - 1)]
                // Only fringes a lawn — the border ring shouldn't sprout along the
                // kitchen's outside wall.
                guard neighbours.contains(where: { board.isFloor(col: $0.col, row: $0.row)
                                                   && board.environment(at: $0).ground == .grass })
                else { continue }
                if frac(&rng) > config.borderDensity { continue }
                let jx = (frac(&rng) - 0.5) * 0.6
                let jz = (frac(&rng) - 0.5) * 0.6
                addClump(at: f3(Double(col) + jx, borderY, Double(row) + jz),
                         height: config.borderHeight, rng: &rng, into: parent)
            }
        }
    }

    /// The renderer hands us Qoob's container so proximity can be read per frame.
    func bindCube(_ cube: Entity?) { self.cube = cube }

    /// Sway every clump with the shared wind (desynced per clump) and bend those
    /// near Qoob away from it, easing back afterward. Combines additively.
    func update(dt: Double, time: Double, wind: WindSample) {
        guard !clumps.isEmpty else { return }

        let R = config.interactionRadius
        let ease = min(1, config.recovery * max(0, dt))
        let cubePos = cube?.position(relativeTo: nil)

        for c in clumps {
            let desync = 1 + 0.25 * sin(time * c.rate + c.phase)
            let windGain = config.swayAmount * c.strengthScale * desync
            let windX = wind.dx * windGain
            let windZ = wind.dz * windGain

            var targetX = 0.0, targetZ = 0.0
            if let cp = cubePos {
                let ax = Double(c.basePos.x - cp.x)
                let az = Double(c.basePos.z - cp.z)
                let dist = sqrt(ax * ax + az * az)
                if dist > 1e-4 && dist < R {
                    let f = (1 - dist / R) * config.interactionStrength
                    targetX = ax / dist * f
                    targetZ = az / dist * f
                }
            }
            c.bendX += (targetX - c.bendX) * ease
            c.bendZ += (targetZ - c.bendZ) * ease

            applyLean(to: c.node, x: windX + c.bendX, z: windZ + c.bendZ)
        }
    }

    /// Tilt a base-pivoted node so its top leans toward the ground vector (x,z)
    /// by |(x,z)| radians (clamped).
    private func applyLean(to node: Entity, x: Double, z: Double) {
        let mag = sqrt(x * x + z * z)
        if mag < 1e-5 {
            node.orientation = simd_quatf(angle: 0, axis: [1, 0, 0])
            return
        }
        let angle = Float(min(config.maxLean, mag))
        // Axis perpendicular to the lean direction, in the ground plane.
        let axis = normalize(f3(z / mag, 0, -x / mag))
        node.orientation = simd_quatf(angle: angle, axis: axis)
    }

    /// Build a clump of a few blades, base pivoting at the ground.
    private func addClump(at pos: SIMD3<Float>, height: Double,
                          rng: inout SeededGenerator, into parent: Entity) {
        // One shared material per clump (slight colour variation).
        var mat = PhysicallyBasedMaterial()
        let hueJitter = (frac(&rng) - 0.5) * 0.05
        let briJitter = (frac(&rng) - 0.5) * 0.12
        mat.baseColor = .init(tint: UIColor(hue: CGFloat(0.28 + hueJitter),
                                            saturation: 0.55,
                                            brightness: CGFloat(0.52 + briJitter),
                                            alpha: 1))
        mat.roughness = 1.0
        mat.metallic = 0.0

        let pivot = Entity()
        let blades = max(1, config.bladesPerClump)
        for _ in 0..<blades {
            let bh = Float(height * (0.8 + 0.4 * frac(&rng)))
            let mesh = MeshResource.generateBox(width: 0.03, height: bh, depth: 0.03,
                                                cornerRadius: 0.015)
            let blade = ModelEntity(mesh: mesh, materials: [mat])
            let bx = Float((frac(&rng) - 0.5) * 0.18)
            let bz = Float((frac(&rng) - 0.5) * 0.18)
            blade.position = [bx, bh / 2, bz]                  // base on the ground plane
            let lean = Float((frac(&rng) - 0.5) * 0.4)         // baked per-blade fan
            let yaw = Float(frac(&rng) * 2 * .pi)
            blade.orientation = simd_quatf(angle: lean, axis: normalize([cos(yaw), 0, sin(yaw)]))
            pivot.addChild(blade)
        }

        pivot.position = pos
        parent.addChild(pivot)

        clumps.append(GrassClump(node: pivot,
                                 basePos: pos,
                                 phase: frac(&rng) * 2 * .pi,
                                 rate: config.swayRate * (1 - config.swayVariation * 0.5
                                                          + config.swayVariation * frac(&rng)),
                                 strengthScale: 0.7 + 0.6 * frac(&rng)))
    }
}

// MARK: - Qoob soft-body

/// Gives Qoob its plush-cube feel WITHOUT touching the roll logic. It drives
/// only the cube's *art* node (child of the rolling container the game logic
/// reads), so gameplay, the pivot-edge roll and grid snapping are unaffected.
/// Everything is a `(vert, horiz)` scale distributed onto the art node so the
/// squash always reads as world-vertical whatever face is up; clamped so the up
/// face stays readable — a soft plush cube, never jelly.
@MainActor
final class SoftBodyEffect {

    var config: QoobSoftBodyConfig

    private weak var container: Entity?
    private weak var art: Entity?
    private var clock: Double = 0
    private var rollStart: Double?
    private var rollDuration: Double = 0.16

    init(config: QoobSoftBodyConfig = VisualTuning.qoob) {
        self.config = config
    }

    func attach(container: Entity, art: Entity) {
        self.container = container
        self.art = art
        rollStart = nil
        art.scale = [1, 1, 1]
    }

    /// Kick off the squash/rebound envelope, timed to the roll's duration.
    func beginRoll(duration: TimeInterval) {
        rollDuration = max(0.01, duration)
        rollStart = clock
    }

    func update(dt: Double) {
        clock += max(0, dt)
        guard art != nil else { return }
        if let start = rollStart, clock - start >= totalRollTime { rollStart = nil }
        let (vert, horiz) = currentFactors()
        applyOrientedScale(vert: vert, horiz: horiz)
    }

    // MARK: Envelope

    private var totalRollTime: Double {
        let c = config
        return rollDuration + c.landDuration + c.reboundDuration + c.settleDuration
    }

    private var anticipationTime: Double {
        min(config.anticipationDuration, rollDuration * 0.5)
    }

    private struct Key { var t: Double; var vert: Double; var horiz: Double }

    private func currentFactors() -> (Double, Double) {
        let c = config

        guard let start = rollStart else {
            // Idle: gentle vertical breathing (volume-preserving-ish).
            let b = c.breatheAmplitude * sin(clock * (2 * .pi / max(0.01, c.breathePeriod)))
            return (clampV(1 + b), clampV(1 - b * 0.5))
        }

        let t = clock - start
        let tA = anticipationTime
        let tLand = rollDuration + c.landDuration
        let tRebound = tLand + c.reboundDuration
        let tEnd = tRebound + c.settleDuration

        let crouch = c.anticipationCrouch
        let squash = c.squashAmount
        let rebound = c.reboundAmount

        let keys: [Key] = [
            Key(t: 0,            vert: 1,           horiz: 1),
            Key(t: tA,           vert: 1 - crouch,  horiz: 1 + crouch * 0.6),
            Key(t: rollDuration, vert: 1,           horiz: 1),
            Key(t: tLand,        vert: 1 - squash,  horiz: 1 + squash * 0.6),
            Key(t: tRebound,     vert: 1 + rebound, horiz: 1 - rebound * 0.6),
            Key(t: tEnd,         vert: 1,           horiz: 1)
        ]

        let (v, h) = interpolate(keys, at: t)
        return (clampV(v), clampV(h))
    }

    private func interpolate(_ keys: [Key], at t: Double) -> (Double, Double) {
        guard let first = keys.first, let last = keys.last else { return (1, 1) }
        if t <= first.t { return (first.vert, first.horiz) }
        if t >= last.t { return (last.vert, last.horiz) }
        for i in 1..<keys.count {
            let a = keys[i - 1], b = keys[i]
            if t <= b.t {
                let u = smoothstep(a.t, b.t, t)
                return (lerp(a.vert, b.vert, u), lerp(a.horiz, b.horiz, u))
            }
        }
        return (last.vert, last.horiz)
    }

    private func clampV(_ x: Double) -> Double {
        let m = config.maxDeformation
        return min(1 + m, max(1 - m, x))
    }

    // MARK: Apply

    /// Distribute (vert, horiz) onto the art node's local scale so the vertical
    /// factor always applies to whichever local axis currently points up.
    private func applyOrientedScale(vert: Double, horiz: Double) {
        guard let art = art else { return }

        // World "up" expressed in the container's local space.
        var upLocal = SIMD3<Float>(0, 1, 0)
        if let container = container {
            upLocal = container.convert(direction: [0, 1, 0], from: nil)
        }
        let wx = min(1, abs(Double(upLocal.x)))
        let wy = min(1, abs(Double(upLocal.y)))
        let wz = min(1, abs(Double(upLocal.z)))

        func mix(_ w: Double) -> Double { horiz * (1 - w) + vert * w }
        art.scale = f3(mix(wx), mix(wy), mix(wz))
    }
}

// MARK: - Small math helpers

@inline(__always) private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
}

/// Classic smoothstep between two edges, clamped to [0, 1].
@inline(__always) private func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    guard e1 > e0 else { return x < e0 ? 0 : 1 }
    let t = min(1, max(0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)
}

/// Deterministic 0…1 draw from the level's seeded RNG.
@inline(__always) private func frac(_ rng: inout SeededGenerator) -> Double {
    Double(rng.next() % 10_000) / 10_000.0
}
