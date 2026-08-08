//
//  EnvironmentEffectsController.swift
//  Qoob
//
//  Everything that reacts to the shared `WindSystem`: Qoob's fur tufts and the
//  outdoor grass. One controller owns the wind and hands the same `WindSample`
//  to both, so there is a single, centralized environmental update — no
//  per-object timers.
//
//    EnvironmentEffectsController
//      ├─ WindSystem            (shared driver — see Environment/)
//      ├─ FurController         (silhouette tufts on Qoob)
//      └─ VegetationController  (grass clumps for outdoor levels)
//
//  Add new wind-reactive objects (flowers, leaves, pollen) by giving them an
//  `update(time:wind:)` and calling it from `update(dt:cubeWorldPosition:)`.
//
//  Perf: work is proportional to a small, capped number of tufts (8) and grass
//  clumps (≤ GrassConfig.maxClumps). Grass is built only for outdoor levels, and
//  each clump is flattened to a single geometry. The whole thing pauses off
//  screen via the renderer's `setEnvironmentActive`.
//

import SceneKit
import UIKit

// MARK: - Top-level effects controller

@MainActor
final class EnvironmentEffectsController {

    let wind: WindSystem
    let fur: FurController
    let vegetation: VegetationController

    init(wind: WindSystem = WindSystem(),
         fur: FurController = FurController(),
         vegetation: VegetationController = VegetationController()) {
        self.wind = wind
        self.fur = fur
        self.vegetation = vegetation
    }

    /// Attach fur tufts to a freshly built cube.
    func attachFur(container: SCNNode, art: SCNNode, cubeSize: CGFloat) {
        fur.attach(container: container, art: art, cubeSize: cubeSize)
    }

    /// Rebuild grass for a new level (no-op for indoor environments).
    func buildVegetation(level: Level, board: BoardModel, into parent: SCNNode) {
        vegetation.build(level: level, board: board, into: parent)
    }

    func clear() {
        vegetation.clear()
    }

    /// Advance the shared wind, then update every consumer. One call per frame.
    func update(dt: Double, cubeWorldPosition: SCNVector3?) {
        wind.update(dt: dt)
        let sample = wind.sample()
        fur.update(time: wind.time, wind: sample)
        vegetation.update(dt: dt, time: wind.time, wind: sample,
                          cubeWorldPosition: cubeWorldPosition)
    }
}

// MARK: - Fur: silhouette tufts on Qoob

/// A handful of soft tufts on Qoob's corners. They ruffle with the shared wind
/// so the *silhouette* moves while the cube body stays solid and readable. The
/// tufts are children of the art node, so they squash and roll with Qoob.
@MainActor
final class FurController {

    var config: FurConfig

    private weak var container: SCNNode?
    private var tufts: [Tuft] = []

    private struct Tuft {
        let pivot: SCNNode        // at the corner; we rotate this to ruffle
        let growth: Vec3          // outward unit direction the tuft points
        let phase: Double
        let rate: Double
    }

    init(config: FurConfig = VisualTuning.fur) {
        self.config = config
    }

    /// Build tufts on the eight corners of the cube's art node.
    func attach(container: SCNNode, art: SCNNode, cubeSize: CGFloat) {
        tufts.forEach { $0.pivot.removeFromParentNode() }
        tufts.removeAll()
        self.container = container

        guard config.enabled else { return }

        let h = Double(cubeSize) / 2.0
        let corners: [(Double, Double, Double)] = [
            (-1, -1, -1), (1, -1, -1), (-1, 1, -1), (1, 1, -1),
            (-1, -1,  1), (1, -1,  1), (-1, 1,  1), (1, 1,  1)
        ]

        for (i, c) in corners.enumerated() {
            let g = normalize((c.0, c.1, c.2))
            let pivot = SCNNode()
            pivot.position = v3(c.0 * h, c.1 * h, c.2 * h)
            pivot.addChildNode(makeTuftNode(growth: g))
            art.addChildNode(pivot)

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

        // Wind is a world-space ground vector; convert it into the cube's local
        // frame so tufts lean correctly whatever orientation Qoob has rolled to.
        let worldWind = v3(wind.dx, 0, wind.dz)
        let lw = container.presentation.convertVector(worldWind, from: nil)
        let windLocal: Vec3 = (Double(lw.x), Double(lw.y), Double(lw.z))

        for t in tufts {
            let idle = config.baseSway * sin(time * t.rate + t.phase)
            let bend = min(config.maxBend, config.windResponse * wind.strength + abs(idle))

            // Bend axis is perpendicular to both the tuft's growth direction and
            // the wind — this tilts the tuft's tip toward the wind.
            var axis = cross(t.growth, windLocal)
            let mag = length(axis)
            if mag < 1e-5 {
                // Wind ~parallel to the tuft: just an idle wobble about a stable
                // local axis so it never goes fully still.
                t.pivot.rotation = v4(1, 0, 0, idle)
            } else {
                axis = (axis.0 / mag, axis.1 / mag, axis.2 / mag)
                t.pivot.rotation = v4(axis.0, axis.1, axis.2, bend)
            }
        }
    }

    /// A single soft tuft: a short tapered cone pointing along `growth`.
    private func makeTuftNode(growth g: Vec3) -> SCNNode {
        let h = config.tuftHeight
        let r = config.tuftBaseRadius
        let cone = SCNCone(topRadius: CGFloat(r * 0.12),
                           bottomRadius: CGFloat(r),
                           height: CGFloat(h))
        cone.radialSegmentCount = 6
        cone.heightSegmentCount = 1

        let m = SCNMaterial()
        // A soft, warm pale fur that reads over any face colour.
        m.diffuse.contents = UIColor(red: 0.86, green: 0.83, blue: 0.80, alpha: 1)
        m.roughness.contents = 1.0
        m.metalness.contents = 0.0
        cone.firstMaterial = m

        // Cone points +Y by default; base sits at its centre. Lift it so the
        // base meets the pivot, then rotate +Y onto the outward direction.
        let coneNode = SCNNode(geometry: cone)
        coneNode.position = v3(0, h / 2.0, 0)
        coneNode.castsShadow = false

        let holder = SCNNode()
        holder.addChildNode(coneNode)
        holder.rotation = rotationFromYToward(g)
        return holder
    }
}

// MARK: - Grass

/// One swaying grass clump. Holds its own phase/rate (so a field desyncs) and a
/// smoothed interaction-bend that eases back to zero after Qoob passes.
@MainActor
final class GrassClump {
    let node: SCNNode          // pivot at the base (ground); rotate to sway
    let basePos: SCNVector3
    let phase: Double
    let rate: Double
    let strengthScale: Double  // per-clump wind susceptibility

    // Smoothed lean (radians) from Qoob's proximity, as a ground vector.
    var bendX: Double = 0
    var bendZ: Double = 0

    init(node: SCNNode, basePos: SCNVector3, phase: Double, rate: Double,
         strengthScale: Double) {
        self.node = node
        self.basePos = basePos
        self.phase = phase
        self.rate = rate
        self.strengthScale = strengthScale
    }
}

/// Builds and animates the outdoor grass. Grass exists only for `.yard` levels;
/// indoors this controller holds nothing and does no per-frame work.
@MainActor
final class VegetationController {

    var config: GrassConfig
    private var clumps: [GrassClump] = []

    init(config: GrassConfig = VisualTuning.grass) {
        self.config = config
    }

    func clear() {
        clumps.forEach { $0.node.removeFromParentNode() }
        clumps.removeAll()
    }

    /// (Re)build grass for a level. No-op unless it's an outdoor (yard) level.
    func build(level: Level, board: BoardModel, into parent: SCNNode) {
        clear()
        guard level.environment == .yard else { return }

        var rng = SeededGenerator(seed: 0x6A55 &+ UInt64(level.index) &* 2246822519)
        let w = board.width, h = board.height

        // Cells that should stay clear of grass (readability + fairness).
        var occupied = level.blocked
        for t in level.targets { occupied.insert(GridCell(col: t.col, row: t.row)) }
        for c in level.items { occupied.insert(c) }
        for g in level.itemGoals { occupied.insert(g) }
        occupied.insert(GridCell(col: level.startCol, row: level.startRow))

        // Sparse, short tufts on free interior cells (these interact with Qoob).
        for row in 0..<h {
            for col in 0..<w {
                if clumps.count >= config.maxClumps { break }
                let cell = GridCell(col: col, row: row)
                if occupied.contains(cell) { continue }
                if frac(&rng) > config.interiorDensity { continue }
                let jx = (frac(&rng) - 0.5) * 0.5
                let jz = (frac(&rng) - 0.5) * 0.5
                addClump(at: v3(Double(col) + jx, 0, Double(row) + jz),
                         height: config.interiorHeight, rng: &rng, into: parent)
            }
        }

        // A lush ring just outside the board for a diorama feel (never underfoot).
        // Rooted at the surrounding ground plane, which sits slightly below the
        // play tiles' top surface.
        let borderY = -0.12
        for col in -1...w {
            for row in -1...h {
                if clumps.count >= config.maxClumps { break }
                let onBorder = (col == -1 || col == w || row == -1 || row == h)
                if !onBorder { continue }
                if frac(&rng) > config.borderDensity { continue }
                let jx = (frac(&rng) - 0.5) * 0.6
                let jz = (frac(&rng) - 0.5) * 0.6
                addClump(at: v3(Double(col) + jx, borderY, Double(row) + jz),
                         height: config.borderHeight, rng: &rng, into: parent)
            }
        }
    }

    /// Sway every clump with the shared wind (desynced per clump) and bend those
    /// near Qoob away from it, easing back afterward. Combines additively.
    func update(dt: Double, time: Double, wind: WindSample,
                cubeWorldPosition: SCNVector3?) {
        guard !clumps.isEmpty else { return }

        let R = config.interactionRadius
        let ease = min(1, config.recovery * max(0, dt))

        for c in clumps {
            // Wind lean as a ground vector: magnitude ~ swayAmount·strength.
            let desync = 1 + 0.25 * sin(time * c.rate + c.phase)
            let windGain = config.swayAmount * c.strengthScale * desync
            let windX = wind.dx * windGain
            let windZ = wind.dz * windGain

            // Interaction target: push the top away from Qoob when close.
            var targetX = 0.0, targetZ = 0.0
            if let cp = cubeWorldPosition {
                let ax = Double(c.basePos.x - cp.x)
                let az = Double(c.basePos.z - cp.z)
                let dist = sqrt(ax * ax + az * az)
                if dist > 1e-4 && dist < R {
                    let f = (1 - dist / R) * config.interactionStrength
                    targetX = ax / dist * f
                    targetZ = az / dist * f
                }
            }
            // Ease the interaction bend toward its target (0 → springs back).
            c.bendX += (targetX - c.bendX) * ease
            c.bendZ += (targetZ - c.bendZ) * ease

            applyLean(to: c.node, x: windX + c.bendX, z: windZ + c.bendZ)
        }
    }

    /// Tilt a base-pivoted node so its top leans toward the ground vector (x,z)
    /// by |(x,z)| radians (clamped).
    private func applyLean(to node: SCNNode, x: Double, z: Double) {
        let mag = sqrt(x * x + z * z)
        if mag < 1e-5 {
            node.rotation = v4(1, 0, 0, 0)
            return
        }
        let angle = min(config.maxLean, mag)
        // Axis perpendicular to the lean direction, in the ground plane.
        let ax = z / mag
        let az = -x / mag
        node.rotation = v4(ax, 0, az, angle)
    }

    /// Build a clump of a few blades, flattened to one geometry, base at ground.
    private func addClump(at pos: SCNVector3, height: Double,
                          rng: inout SeededGenerator, into parent: SCNNode) {
        // One shared material per clump (slight colour variation) keeps the
        // flattened clump to a single draw.
        let mat = SCNMaterial()
        let hueJitter = (frac(&rng) - 0.5) * 0.05
        let briJitter = (frac(&rng) - 0.5) * 0.12
        mat.diffuse.contents = UIColor(hue: CGFloat(0.28 + hueJitter),
                                       saturation: 0.55,
                                       brightness: CGFloat(0.52 + briJitter),
                                       alpha: 1)
        mat.roughness.contents = 1.0
        mat.metalness.contents = 0.0

        // Build blades at the origin so the flattened result pivots at its base.
        let temp = SCNNode()
        let blades = max(1, config.bladesPerClump)
        for _ in 0..<blades {
            let bh = height * (0.8 + 0.4 * frac(&rng))
            let blade = SCNCone(topRadius: 0.004, bottomRadius: 0.02, height: CGFloat(bh))
            blade.radialSegmentCount = 4
            blade.heightSegmentCount = 1
            blade.firstMaterial = mat

            let bnode = SCNNode(geometry: blade)
            let bx = (frac(&rng) - 0.5) * 0.18
            let bz = (frac(&rng) - 0.5) * 0.18
            bnode.position = v3(bx, bh / 2.0, bz)   // base sits on the ground plane
            let lean = (frac(&rng) - 0.5) * 0.4     // baked per-blade fan
            let yaw = frac(&rng) * 2 * Double.pi
            bnode.rotation = v4(cos(yaw), 0, sin(yaw), lean)
            bnode.castsShadow = false
            temp.addChildNode(bnode)
        }

        let flat = temp.flattenedClone()
        flat.position = pos
        flat.castsShadow = false
        parent.addChildNode(flat)

        clumps.append(GrassClump(node: flat,
                                 basePos: pos,
                                 phase: frac(&rng) * 2 * Double.pi,
                                 rate: config.swayRate * (1 - config.swayVariation * 0.5
                                                          + config.swayVariation * frac(&rng)),
                                 strengthScale: 0.7 + 0.6 * frac(&rng)))
    }
}

// MARK: - Tiny vector helpers (Double triples; kept file-local)

private typealias Vec3 = (Double, Double, Double)

private func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
    (a.1 * b.2 - a.2 * b.1,
     a.2 * b.0 - a.0 * b.2,
     a.0 * b.1 - a.1 * b.0)
}

private func dot(_ a: Vec3, _ b: Vec3) -> Double {
    a.0 * b.0 + a.1 * b.1 + a.2 * b.2
}

private func length(_ a: Vec3) -> Double {
    sqrt(dot(a, a))
}

private func normalize(_ a: Vec3) -> Vec3 {
    let l = length(a)
    guard l > 1e-9 else { return (0, 1, 0) }
    return (a.0 / l, a.1 / l, a.2 / l)
}

/// Axis-angle rotation that maps local +Y onto the unit direction `g`.
private func rotationFromYToward(_ g: Vec3) -> SCNVector4 {
    let up: Vec3 = (0, 1, 0)
    var axis = cross(up, g)
    let mag = length(axis)
    if mag < 1e-6 {
        // Parallel (g == +Y) or anti-parallel (g == -Y).
        return dot(up, g) > 0 ? v4(1, 0, 0, 0) : v4(1, 0, 0, .pi)
    }
    axis = (axis.0 / mag, axis.1 / mag, axis.2 / mag)
    let angle = acos(max(-1, min(1, dot(up, g))))
    return v4(axis.0, axis.1, axis.2, angle)
}

/// Deterministic 0…1 draw from the level's seeded RNG.
private func frac(_ rng: inout SeededGenerator) -> Double {
    Double(rng.next() % 10_000) / 10_000.0
}
