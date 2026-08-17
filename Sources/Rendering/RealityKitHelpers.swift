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
///
/// Generating a texture is expensive and the same image is asked for over and
/// over — every floor tile shares one texture, and an appearance change
/// re-skins the whole board at once — so results are cached by image identity
/// plus semantic.
func loadTexture(_ image: UIImage?, semantic: TextureResource.Semantic) -> TextureResource? {
    guard let image, let cg = image.cgImage else { return nil }

    let key = TextureCacheKey(image: ObjectIdentifier(image),
                              semantic: semanticTag(semantic))
    if let hit = textureCache[key] { return hit.resource }

    let options = TextureResource.CreateOptions(semantic: semantic)
    guard let resource = makeTexture(cg, options: options) else { return nil }
    // The entry keeps the image alive as well: the key is the image's address,
    // so letting it deallocate would let a later image reuse that address and
    // collide with this entry.
    textureCache[key] = CachedTexture(image: image, resource: resource)
    return resource
}

/// Builds the texture with whichever spelling the platform has.
///
/// `TextureResource.generate(from:options:)` was replaced by `init(image:...)` in
/// iOS 18, and on tvOS — which RealityKit only reached in 26 — the old call was
/// never available at all. Note the initialiser has both a sync and an async
/// overload; this is a synchronous context, so it resolves to the sync one.
///
/// Deliberately not `@MainActor`: `loadTexture` is nonisolated (it's called from
/// the texture-building helpers), and RealityKit's creation calls are
/// `@preconcurrency @MainActor`, which Swift 5 mode allows from here. Annotating
/// this helper would make the existing call sites illegal.
private func makeTexture(_ cg: CGImage,
                         options: TextureResource.CreateOptions) -> TextureResource? {
    if #available(iOS 18.0, macCatalyst 18.0, tvOS 26.0, *) {
        return try? TextureResource(image: cg, options: options)
    }
    #if os(tvOS)
    return nil          // unreachable: tvOS starts at 26
    #else
    return try? TextureResource.generate(from: cg, options: options)
    #endif
}

/// Image identity + semantic. `TextureResource.Semantic` isn't `Hashable`, so it
/// travels as a small integer tag (see `semanticTag`).
private struct TextureCacheKey: Hashable {
    var image: ObjectIdentifier
    var semantic: Int
}

private struct CachedTexture {
    var image: UIImage              // held so the key's identity stays unique
    var resource: TextureResource
}

private func semanticTag(_ semantic: TextureResource.Semantic) -> Int {
    switch semantic {
    case .color:  return 0
    case .normal: return 1
    default:      return 2
    }
}

private var textureCache: [TextureCacheKey: CachedTexture] = [:]

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

    /// Called once per frame with that frame's delta time.
    ///
    /// Unlike a pulser this survives `reset()`, because the camera follow has to
    /// keep easing across a level rebuild and isn't attached to any one entity.
    var onFrame: ((TimeInterval) -> Void)?

    /// Drop every animation (e.g. when rebuilding a level).
    func reset() {
        pulsers.removeAll()
        finite.removeAll()
    }

    /// Drops any one-shot animations still running on `entity`, without firing
    /// their completions. Use before starting something that writes the same
    /// transform, so the two don't fight — and so a stale completion can't snap
    /// the entity back to a position that is no longer current.
    func cancelRuns(for entity: Entity) {
        finite.removeAll { $0.entity == nil || $0.entity === entity }
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

        onFrame?(dt)

        // Endless pulses. Prune any whose entity has left the scene.
        for p in pulsers {
            if let e = p.entity, e.parent != nil { p.apply(e, time + p.phase) }
        }
        pulsers.removeAll { $0.entity == nil || $0.entity?.parent == nil }

        // Finite animations. `step` and `completion` are caller-supplied and may
        // register further animations (a bounce chained off a tumble, say), so
        // advance a snapshot and rebuild `finite` afterwards rather than
        // mutating the live array while iterating it. Completions fire last, so
        // one that reshapes the scene can't disturb this pass.
        let running = finite
        var survivors: [Finite] = []
        var completions: [() -> Void] = []
        survivors.reserveCapacity(running.count)

        for anim in running {
            guard let e = anim.entity, e.parent != nil else { continue }
            anim.elapsed += dt
            let raw = Float(min(1, anim.elapsed / anim.duration))
            anim.step(e, anim.ease.apply(raw))
            if raw >= 1 {
                if let c = anim.completion { completions.append(c) }
            } else {
                survivors.append(anim)
            }
        }
        // Anything registered during this pass isn't in `running`; keep it.
        let added = finite.filter { anim in !running.contains { $0 === anim } }
        finite = survivors + added

        for c in completions { c() }
    }
}
