//
//  RealityKitHelpers.swift
//  Qoob
//
//  RealityKit-side utilities for the RealityKitRenderer: SIMD vector/quaternion
//  sugar, texture loading, and a small per-frame animation subsystem that
//  replaces SceneKit's SCNAction (sequence / group / repeatForever).
//
//  RealityKit has no built-in action queue like SCNAction. `FrameAnimator`
//  subscribes once to the scene's per-frame Update event and drives two kinds
//  of animation from the accumulated time:
//    • pulsers — endless, parametric loops (breathing scale, highlight pulse)
//    • finite  — one-shot timed animations with an easing curve + completion
//               (used for multi-turn spins that `Entity.move(to:)`'s shortest-
//               path slerp can't express). Simple eased single moves use the
//               built-in `move(to:relativeTo:duration:timingFunction:)`.
//

import RealityKit
import UIKit
import Combine

// MARK: - Vector / quaternion sugar

@inline(__always)
func f3(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Float> {
    SIMD3<Float>(Float(x), Float(y), Float(z))
}

/// Axis-angle quaternion (axis is normalised for you).
@inline(__always)
func quat(_ angle: Float, _ axis: SIMD3<Float>) -> simd_quatf {
    simd_quatf(angle: angle, axis: normalize(axis))
}

/// Sets an unlit entity's opacity by adjusting its material's transparent
/// blending. Used instead of `OpacityComponent`, which is iOS 18+ — this works
/// back to iOS 16. No-op for entities whose first material isn't unlit.
@MainActor
func setUnlitOpacity(_ entity: Entity, _ opacity: Float) {
    guard let model = entity as? ModelEntity,
          var mat = model.model?.materials.first as? UnlitMaterial else { return }
    mat.blending = .transparent(opacity: .init(floatLiteral: opacity))
    model.model?.materials = [mat]
}

// MARK: - Textures

/// A RealityKit `TextureResource` from a UIImage, or nil if it can't be made.
/// `semantic` should be `.color` for albedo/emissive art and `.normal` for
/// tangent-space normal maps (so RealityKit picks the right pixel format).
func loadTexture(_ image: UIImage?, semantic: TextureResource.Semantic) -> TextureResource? {
    guard let cg = image?.cgImage else { return nil }
    let options = TextureResource.CreateOptions(semantic: semantic)
    return try? TextureResource.generate(from: cg, options: options)
}

// MARK: - Easing

enum Ease {
    case linear, inOut, easeIn, easeOut

    func apply(_ t: Float) -> Float {
        let x = min(max(t, 0), 1)
        switch self {
        case .linear:  return x
        case .inOut:   return x * x * (3 - 2 * x)          // smoothstep
        case .easeIn:  return x * x
        case .easeOut: return 1 - (1 - x) * (1 - x)
        }
    }
}

// MARK: - FrameAnimator

@MainActor
final class FrameAnimator {

    /// An endless, time-driven loop bound to an entity. Auto-removed once the
    /// entity leaves the scene (its `parent` becomes nil).
    private struct Pulser {
        weak var entity: Entity?
        let phase: Double
        let apply: (Entity, Double) -> Void   // (entity, accumulatedTime + phase)
    }

    /// A one-shot timed animation. `step` receives the eased progress 0...1.
    private final class Finite {
        weak var entity: Entity?
        var elapsed: Double = 0
        let duration: Double
        let ease: Ease
        let step: (Entity, Float) -> Void
        let completion: (() -> Void)?
        init(entity: Entity, duration: Double, ease: Ease,
             step: @escaping (Entity, Float) -> Void, completion: (() -> Void)?) {
            self.entity = entity; self.duration = duration; self.ease = ease
            self.step = step; self.completion = completion
        }
    }

    private var subscription: (any Cancellable)?
    private var pulsers: [Pulser] = []
    private var finite: [Finite] = []
    private var time: Double = 0

    /// Begin driving animations from `view`'s per-frame update event.
    func attach(to view: ARView) {
        subscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.tick(dt: event.deltaTime)
        }
    }

    /// Drop every animation (e.g. when rebuilding a level).
    func reset() {
        pulsers.removeAll()
        finite.removeAll()
    }

    // MARK: Registration

    /// Registers an endless loop. `apply` is called each frame with the
    /// accumulated scene time (plus `phase`), so use sin/cos for pulses.
    func addPulser(_ entity: Entity, phase: Double = 0,
                   _ apply: @escaping (Entity, Double) -> Void) {
        pulsers.append(Pulser(entity: entity, phase: phase, apply: apply))
    }

    func removePulsers(for entity: Entity) {
        pulsers.removeAll { $0.entity == nil || $0.entity === entity }
    }

    /// Runs a one-shot animation over `duration`, calling `step(entity, easedT)`
    /// each frame and `completion` once it finishes.
    func run(_ entity: Entity, duration: Double, ease: Ease = .inOut,
             step: @escaping (Entity, Float) -> Void, completion: (() -> Void)? = nil) {
        if duration <= 0 {
            step(entity, 1); completion?(); return
        }
        finite.append(Finite(entity: entity, duration: duration, ease: ease,
                             step: step, completion: completion))
    }

    // MARK: Per-frame

    private func tick(dt: TimeInterval) {
        time += dt

        // Endless pulses. Prune any whose entity has left the scene.
        for p in pulsers {
            if let e = p.entity, e.parent != nil { p.apply(e, time + p.phase) }
        }
        pulsers.removeAll { $0.entity == nil || $0.entity?.parent == nil }

        // Finite animations. Collect completions to fire after pruning so a
        // completion that mutates the scene can't disturb this pass.
        var completions: [() -> Void] = []
        finite.removeAll { anim in
            guard let e = anim.entity, e.parent != nil else { return true }
            anim.elapsed += dt
            let raw = Float(min(1, anim.elapsed / anim.duration))
            anim.step(e, anim.ease.apply(raw))
            if raw >= 1 {
                if let c = anim.completion { completions.append(c) }
                return true
            }
            return false
        }
        for c in completions { c() }
    }
}
