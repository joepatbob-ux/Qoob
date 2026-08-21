//
//  SkySystem.swift
//  Qoob
//
//  Per-frame driver for live weather — the `WindSystem` analogue. Turns a
//  fetched `SkySnapshot` (or the absence of one) into a `SkyModifier` and a
//  `SkyCondition` every tick, throttles how often the expensive part of a
//  relight is asked for, and schedules lightning strikes during a storm.
//  Owned and polled by `GameController`; knows nothing about RealityKit,
//  WeatherKit, or CoreLocation — see `LocalWeatherProvider` for that edge.
//

import Foundation

/// A fetched weather snapshot, decoupled from however it was actually
/// fetched. Foundation-only, so it's trivial to build by hand in tests.
struct SkySnapshot: Equatable {
    var condition: SkyCondition
    var sun: SolarWindow
    var fetchedAt: Date
}

/// What a relight needs to do: always update the cheap directional lights,
/// and occasionally re-bake the environment map too.
enum SkyRelight {
    case cheap(SkyModifier)
    case full(SkyModifier)

    var modifier: SkyModifier {
        switch self {
        case .cheap(let m), .full(let m): return m
        }
    }
}

@MainActor
final class SkySystem {
    private(set) var condition: SkyCondition = .clear
    private(set) var modifier: SkyModifier = .neutral

    private var sun = SolarWindow(sunrise: nil, sunset: nil, validFor: .distantPast)
    private var lastBakedModifier: SkyModifier = .neutral
    private var lastBakeAt: Double = -.infinity
    private var lastPublishedCondition: SkyCondition?
    private var pendingRelight: SkyRelight?

    private var nextStrikeAt: Double?
    private var rng = SeededGenerator(seed: 1)

    /// Hands the system whatever the provider last fetched, or `nil` if the
    /// feature is off, permission was denied, or every fetch has failed — any
    /// of which just means "no weather", not "no game".
    func ingest(_ snapshot: SkySnapshot?, now: Date) {
        guard let snapshot, isFresh(snapshot, now: now) else {
            setCondition(.clear)
            sun = SolarWindow(sunrise: nil, sunset: nil, validFor: .distantPast)
            return
        }
        setCondition(snapshot.condition)
        sun = snapshot.sun
    }

    private func isFresh(_ snapshot: SkySnapshot, now: Date) -> Bool {
        now.timeIntervalSince(snapshot.fetchedAt) < VisualTuning.sky.refreshInterval * 3
    }

    private func setCondition(_ newValue: SkyCondition) {
        guard newValue != condition else { return }
        if newValue == .thunderstorm {
            // A fresh, real-feeling strike pattern each storm rather than the
            // exact same sequence every time — reseeded from wall time, not
            // read every frame.
            rng = SeededGenerator(seed: UInt64(Date().timeIntervalSince1970.magnitude * 1000))
        }
        nextStrikeAt = nil
        condition = newValue
    }

    /// Recomputes `modifier` and the lightning schedule. Cheap: safe to call
    /// once every frame regardless of whether anything actually changed.
    func update(now: Date, monotonic: Double, isNightPreset: Bool) {
        let phase = sun.phase(at: now)
        let goldenness = sun.goldenness(at: now)
        let fresh = SkyModifier.make(condition: condition, phase: phase,
                                     goldenness: goldenness, isNightPreset: isNightPreset)
        if fresh != modifier {
            modifier = fresh
            let cfg = VisualTuning.sky
            let needsBake = modifier.differsMeaningfully(from: lastBakedModifier, epsilon: cfg.bakeEpsilon)
                && monotonic - lastBakeAt >= cfg.minBakeInterval
            pendingRelight = needsBake ? .full(modifier) : .cheap(modifier)
            if needsBake { lastBakedModifier = modifier; lastBakeAt = monotonic }
        }

        if condition == .thunderstorm {
            if nextStrikeAt == nil { scheduleNextStrike(after: monotonic) }
        } else {
            nextStrikeAt = nil
        }
    }

    /// Consumes the pending relight, if any. Call once per `update`.
    func consumeRelight() -> SkyRelight? {
        defer { pendingRelight = nil }
        return pendingRelight
    }

    /// Consumes a condition change — returns non-nil only the first time
    /// it's asked after the condition actually moved.
    func consumeConditionChange() -> SkyCondition? {
        guard condition != lastPublishedCondition else { return nil }
        lastPublishedCondition = condition
        return condition
    }

    /// A due lightning strike, if one has come up since the last poll.
    func pollLightning(monotonic: Double) -> LightningFlash? {
        guard condition == .thunderstorm, let due = nextStrikeAt, monotonic >= due else { return nil }
        scheduleNextStrike(after: monotonic)
        let peak = 0.4 + 0.6 * unit()
        let distance = clamp(1 - peak * 0.7 + 0.2 * unit(), 0, 1)
        return LightningFlash(peak: peak, duration: 0.35,
                              secondStroke: rng.next() % 3 == 0,
                              thunderDelay: 0.6 + distance * 4.4,
                              thunderDistance: distance)
    }

    private func scheduleNextStrike(after monotonic: Double) {
        let cfg = VisualTuning.sky
        nextStrikeAt = monotonic + cfg.lightningMinInterval
            + (cfg.lightningMaxInterval - cfg.lightningMinInterval) * unit()
    }

    /// 0...1 from the shared deterministic RNG.
    private func unit() -> Double { Double(rng.next() % 1_000_000) / 1_000_000 }

    /// Back to neutral/clear — e.g. when the setting is switched off.
    func reset() {
        condition = .clear
        modifier = .neutral
        lastBakedModifier = .neutral
        sun = SolarWindow(sunrise: nil, sunset: nil, validFor: .distantPast)
        nextStrikeAt = nil
        pendingRelight = .full(.neutral)
    }
}

private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }
