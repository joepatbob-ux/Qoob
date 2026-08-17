//
//  WindSystem.swift
//  Qoob
//
//  A shared, reusable environmental wind driver. It is pure model — no SceneKit,
//  no view, no per-object timers — so it is NOT coupled to Qoob or to any one
//  renderer. Anything that should react to the breeze (Qoob's fur, grass,
//  future flowers / leaves / pollen / particles) reads the same `WindSample`
//  and scales it by its own gain.
//
//  Motion is smooth and organic (layered sines + a shaped gust envelope), never
//  jittery random noise. Advance it once per frame with `update(dt:)` from a
//  single, centralized clock (the renderer's effects display link), then read
//  `sample()` as many times as you like that frame.
//

import Foundation

/// A snapshot of the wind at one instant, on the ground (X/Z) plane.
struct WindSample {
    /// Heading the wind blows toward (radians).
    var direction: Double
    /// Overall strength, ~0…`maxStrength`.
    var strength: Double
    /// Just the gust envelope, 0…1 (handy for effects that react to gusts only).
    var gust: Double
    /// Ground-plane components, already scaled by `strength`.
    var dx: Double
    var dz: Double
}

/// Produces a smoothly varying `WindSample` over time. One instance is shared
/// by every environmental effect.
final class WindSystem {

    /// Live tuning. Mutable so you can gust the whole scene on demand later.
    var config: WindConfig

    /// Seconds of accumulated wind time. Consumers may read this to add their
    /// own per-object phase offsets (so a field of grass doesn't move in sync).
    private(set) var time: Double = 0

    private(set) var current: WindSample

    init(config: WindConfig = VisualTuning.wind) {
        self.config = config
        // Seed with a valid sample so first-frame readers get sane values.
        self.current = WindSample(direction: config.baseDirection,
                                  strength: config.baseStrength,
                                  gust: 0,
                                  dx: cos(config.baseDirection) * config.baseStrength,
                                  dz: sin(config.baseDirection) * config.baseStrength)
    }

    /// Advance the wind clock and recompute the current sample. Call once/frame.
    func update(dt: Double) {
        time += max(0, dt)
        current = compute(at: time)
    }

    /// The most recently computed sample.
    func sample() -> WindSample { current }

    // MARK: - Procedural model

    private func compute(at t: Double) -> WindSample {
        let c = config

        // Heading meanders around the base direction via layered sines (organic,
        // not random) so gusts arrive from slightly varying angles.
        let direction = c.baseDirection + c.directionDrift * fbmSine(t * c.directionDriftRate)

        // A gentle base breeze that never fully dies, shimmering slowly.
        let shimmer = 0.65 + 0.35 * (0.5 + 0.5 * sin(t * c.variationRate))
        let breeze = c.baseStrength * shimmer

        // A shaped gust: a clean half-sine hump of `gustDuration` once per
        // `gustInterval`, its peak slowly varying so it never feels mechanical.
        let g = gustEnvelope(at: t)

        let strength = min(c.maxStrength, breeze + c.gustStrength * g)

        return WindSample(direction: direction,
                          strength: strength,
                          gust: g,
                          dx: cos(direction) * strength,
                          dz: sin(direction) * strength)
    }

    /// 0…1 gust envelope: a smooth rise-and-fall once per interval, with a
    /// slowly drifting peak so repeats don't read as a loop.
    private func gustEnvelope(at t: Double) -> Double {
        let c = config
        guard c.gustInterval > 0, c.gustDuration > 0 else { return 0 }
        let localT = t.truncatingRemainder(dividingBy: c.gustInterval)
        guard localT < c.gustDuration else { return 0 }
        let hump = sin(.pi * localT / c.gustDuration)         // 0→1→0
        let peakVariation = 0.7 + 0.3 * (0.5 + 0.5 * sin(t * 0.13))
        return max(0, hump) * peakVariation
    }

    /// Small fractal-ish sum of sines in roughly [-1, 1]; smooth and organic.
    private func fbmSine(_ t: Double) -> Double {
        sin(t) * 0.6 + sin(t * 2.3 + 1.7) * 0.3 + sin(t * 4.1 + 4.2) * 0.1
    }
}
