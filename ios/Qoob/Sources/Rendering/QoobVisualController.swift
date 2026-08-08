//
//  QoobVisualController.swift
//  Qoob
//
//  Gives Qoob its soft, plush-cube feel WITHOUT touching the roll logic. It
//  drives only the cube's *art* node — the child of the rolling container that
//  the game logic never reads — so gameplay, the pivot-edge roll, and grid
//  snapping are completely unaffected.
//
//  What it does, per roll:
//    • a quick anticipation gather as the roll starts,
//    • subtle give while tipping,
//    • a short squash when the face lands,
//    • a small rebound / overshoot,
//    • a quick settle back to a perfect cube,
//  and, when idle, a slow "breathing" swell so Qoob reads as alive.
//
//  Everything is expressed as two scalars — a `vert` (world-vertical) factor and
//  a `horiz` factor — then distributed onto the art node's local X/Y/Z scale
//  according to which local axis currently points up in the world. Because every
//  roll is exactly 90°, Qoob rests axis-aligned, so this yields a true vertical
//  squash regardless of which face is up. Deformation is clamped so the player
//  can always read the up face — this is a soft plush cube, never jelly.
//
//  This is intentionally an *isolated, scale-based* implementation (as the brief
//  allows): a later mesh/shader deformation can replace `applyOrientedScale`
//  alone, leaving the timing envelope untouched.
//

import SceneKit

@MainActor
final class QoobVisualController {

    var config: QoobSoftBodyConfig

    /// The rolling container (read for orientation only — never mutated here).
    private weak var container: SCNNode?
    /// The art node we deform (scale only).
    private weak var art: SCNNode?

    /// Monotonic clock advanced by `update(dt:)`.
    private var clock: Double = 0

    /// Active roll deformation, if any.
    private var rollStart: Double?
    private var rollDuration: Double = 0.16

    init(config: QoobSoftBodyConfig = VisualTuning.qoob) {
        self.config = config
    }

    /// Bind to a freshly built cube. Resets any in-flight deformation.
    func attach(container: SCNNode, art: SCNNode) {
        self.container = container
        self.art = art
        rollStart = nil
        art.scale = v3(1, 1, 1)
    }

    /// Kick off the squash/rebound envelope, timed to the roll's duration.
    /// Call at the *start* of the visual roll; the landing squash lands as the
    /// face meets the ground.
    func beginRoll(duration: TimeInterval) {
        rollDuration = max(0.01, duration)
        rollStart = clock
    }

    /// Advance and apply the deformation. Called once per frame from the
    /// renderer's centralized effects loop.
    func update(dt: Double) {
        clock += max(0, dt)
        guard art != nil else { return }

        // Retire a finished roll so idle breathing resumes.
        if let start = rollStart, clock - start >= totalRollTime {
            rollStart = nil
        }

        let (vert, horiz) = currentFactors()
        applyOrientedScale(vert: vert, horiz: horiz)
    }

    // MARK: - Envelope

    /// Total length of the roll deformation envelope. Matches the last keyframe
    /// time in `currentFactors()`: the envelope runs from the roll start, lands
    /// at `rollDuration`, then rebounds and settles. (Anticipation is a sub-slice
    /// of the roll window, not added on top — see `anticipationTime`.)
    private var totalRollTime: Double {
        let c = config
        return rollDuration + c.landDuration + c.reboundDuration + c.settleDuration
    }

    /// Anticipation is a sub-slice of the roll itself (never longer than it), so
    /// it never adds input latency.
    private var anticipationTime: Double {
        min(config.anticipationDuration, rollDuration * 0.5)
    }

    private struct Key { var t: Double; var vert: Double; var horiz: Double }

    /// The (vert, horiz) scale factors right now.
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

        // Keyframes: neutral → crouch → (tip back toward neutral) → land squash
        // → rebound overshoot → settle to a perfect cube.
        let crouch = c.anticipationCrouch
        let squash = c.squashAmount
        let rebound = c.reboundAmount

        let keys: [Key] = [
            Key(t: 0,          vert: 1,           horiz: 1),
            Key(t: tA,         vert: 1 - crouch,  horiz: 1 + crouch * 0.6),
            Key(t: rollDuration, vert: 1,         horiz: 1),
            Key(t: tLand,      vert: 1 - squash,  horiz: 1 + squash * 0.6),
            Key(t: tRebound,   vert: 1 + rebound, horiz: 1 - rebound * 0.6),
            Key(t: tEnd,       vert: 1,           horiz: 1)
        ]

        let (v, h) = interpolate(keys, at: t)
        return (clampV(v), clampV(h))
    }

    /// Smoothstep-interpolate the keyframe list at time `t`.
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

    /// Keep any single factor within the readability clamp around 1.
    private func clampV(_ x: Double) -> Double {
        let m = config.maxDeformation
        return min(1 + m, max(1 - m, x))
    }

    // MARK: - Apply

    /// Distribute (vert, horiz) onto the art node's local scale so that the
    /// vertical factor always applies to whichever local axis currently points
    /// up in the world.
    private func applyOrientedScale(vert: Double, horiz: Double) {
        guard let art = art else { return }

        // World "up" expressed in the container's local space. At rest this is a
        // signed unit basis vector; mid-roll it interpolates smoothly.
        var upLocal = v3(0, 1, 0)
        if let container = container {
            upLocal = container.presentation.convertVector(v3(0, 1, 0), from: nil)
        }
        let wx = min(1, abs(Double(upLocal.x)))
        let wy = min(1, abs(Double(upLocal.y)))
        let wz = min(1, abs(Double(upLocal.z)))

        // weight 1 → vertical factor, weight 0 → horizontal factor.
        func mix(_ w: Double) -> Double { horiz * (1 - w) + vert * w }
        art.scale = v3(mix(wx), mix(wy), mix(wz))
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
