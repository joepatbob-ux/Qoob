//
//  SkyModel.swift
//  Qoob
//
//  The pure-model half of live weather: how a moment's real sun position and
//  weather condition turn into small numeric adjustments layered on top of a
//  room's existing day/night lighting. No RealityKit, no UIKit, no WeatherKit
//  — see `LocalWeatherProvider` for the framework-facing edge and `SkySystem`
//  for the per-frame driver that ties this to the renderer.
//

import Foundation

/// Everything WeatherKit reports collapses into one of these five, since the
/// renderer only ever needs to pick a mood, not report a forecast.
enum SkyCondition: String, CaseIterable {
    case clear, cloudy, rain, snow, thunderstorm
}

/// Where the sun is in its day, in the coarse terms the lighting rig cares
/// about — not a solar-elevation calculation. See `SolarWindow`.
enum SolarPhase: String {
    case night, goldenRise, day, goldenSet
}

/// Just today's sunrise and sunset, from which everything else here is
/// derived by simple time-since/time-until arithmetic — no ephemeris, no
/// latitude/longitude trigonometry. Good enough for "is it golden hour", not
/// for where in the sky the sun actually sits.
struct SolarWindow: Equatable {
    var sunrise: Date?
    var sunset: Date?
    /// The calendar day these times belong to, so a stale snapshot (yesterday's
    /// sunrise, read after midnight) can be detected rather than misread.
    var validFor: Date

    /// 0...1 golden-hour proximity: 1 right at sunrise/sunset, fading to 0 over
    /// `VisualTuning.sky.goldenHalfWidth` seconds either side. Whichever of
    /// sunrise/sunset is nearer wins; 0 if neither time is known.
    func goldenness(at now: Date) -> Double {
        let half = VisualTuning.sky.goldenHalfWidth
        func ramp(_ edge: Date?) -> Double {
            guard let edge else { return 0 }
            let dt = abs(now.timeIntervalSince(edge))
            return smoothstep(1 - dt / half)
        }
        return max(ramp(sunrise), ramp(sunset))
    }

    /// 0...1 how "daytime" it is: 0 well before sunrise or well after sunset, 1
    /// in the middle of the day, ramping smoothly across `twilightHalfWidth`.
    /// Defaults to 1 (day) when either time is missing — a room with no known
    /// sun times keeps whatever preset the appearance setting already chose.
    func daylight(at now: Date) -> Double {
        guard let sunrise, let sunset, sunset > sunrise else { return 1 }
        let half = VisualTuning.sky.twilightHalfWidth
        let sinceRise = now.timeIntervalSince(sunrise)
        let untilSet = sunset.timeIntervalSince(now)
        return min(smoothstep(0.5 + sinceRise / (2 * half)),
                   smoothstep(0.5 + untilSet / (2 * half)))
    }

    /// The coarse phase a `goldenness`/`daylight` pair resolves to.
    func phase(at now: Date) -> SolarPhase {
        let g = goldenness(at: now)
        if g > 0.15, let sunrise, let sunset {
            let towardRise = abs(now.timeIntervalSince(sunrise))
            let towardSet = abs(now.timeIntervalSince(sunset))
            return towardRise <= towardSet ? .goldenRise : .goldenSet
        }
        return daylight(at: now) > 0.5 ? .day : .night
    }
}

/// A brief scheduled lightning strike: how bright, how long, whether it
/// double-strikes, and when + how the thunder that follows it should sound.
struct LightningFlash: Equatable {
    /// 0.4...1.0 — how strong this particular strike is.
    var peak: Double
    /// Seconds the visual flash lasts.
    var duration: Double
    var secondStroke: Bool
    /// Seconds after the flash the thunderclap should play — short for a near
    /// strike, several seconds for a distant one.
    var thunderDelay: TimeInterval
    /// 0 (overhead) ... 1 (distant), driving which thunder timbre plays.
    var thunderDistance: Double
}

/// The numeric adjustment a moment's real sky makes to a room's chosen
/// day/night preset — never a replacement for it. Every field is a gain,
/// tint, or small offset, so `.neutral` is an exact identity: with the
/// feature off, permission denied, or the fetch failed, a room renders
/// pixel-identical to today.
///
/// Deliberately cannot darken a room below its own baseline — no field
/// scales `floorBounce`, and every intensity scale is clamped to `>= 1`. Past
/// tuning passes on `RoomLight.night` fixed a real "Qoob turns into an
/// illegible blob" bug; weather is allowed to shift the mood, not reopen it.
struct SkyModifier: Equatable {
    var windowGain: Double = 1
    var windowTint = SIMD3<Double>(1, 1, 1)
    var windowRadiusScale: Double = 1
    /// Added to `windowAt.y` (0 = straight up, 1 = straight down) — positive
    /// pushes the window's bright patch toward the horizon, as a low sun does.
    var windowElevationDelta: Double = 0

    var ceilingScale: Double = 1
    var wallScale: Double = 1

    var keyTint = SIMD3<Double>(1, 1, 1)
    var keyIntensityScale: Double = 1
    var fillIntensityScale: Double = 1
    var exponentDelta: Float = 0

    var backgroundTint = SIMD3<Double>(1, 1, 1)
    var backgroundBlend: Double = 0

    static let neutral = SkyModifier()

    /// Whether the IBL-bearing fields differ enough from `other` to justify a
    /// full environment-map re-bake — the expensive part of a relight. Cheap
    /// fields (intensity, exponent, tint) don't gate this; they update every
    /// frame regardless of the bake throttle.
    func differsMeaningfully(from other: SkyModifier, epsilon: Double = 0.03) -> Bool {
        func far(_ a: Double, _ b: Double) -> Bool { abs(a - b) > epsilon }
        func far(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
            far(a.x, b.x) || far(a.y, b.y) || far(a.z, b.z)
        }
        return far(windowGain, other.windowGain)
            || far(windowTint, other.windowTint)
            || far(windowRadiusScale, other.windowRadiusScale)
            || far(windowElevationDelta, other.windowElevationDelta)
            || far(ceilingScale, other.ceilingScale)
            || far(wallScale, other.wallScale)
    }

    /// The single pure function that turns "what's the real sky doing" into
    /// this struct — the main unit-test target for the whole feature.
    ///
    /// `isNightPreset` scales everything down: `RoomLight.night`'s window
    /// already stands for the moon, not the sun, so weather and golden hour
    /// read as a hint there rather than a repaint.
    static func make(condition: SkyCondition, phase: SolarPhase,
                     goldenness: Double, isNightPreset: Bool) -> SkyModifier {
        var m = SkyModifier()

        // Golden hour: warms and lowers the window patch, brightens the key a
        // touch. Scaled by `goldenness`, so it fades in and out smoothly
        // rather than switching at a hard edge.
        if phase == .goldenRise || phase == .goldenSet {
            let g = goldenness
            m.windowTint = mix3(m.windowTint, SIMD3(1.35, 0.92, 0.58), t: g)
            m.keyTint = mix3(m.keyTint, SIMD3(1.25, 0.95, 0.72), t: g)
            m.windowElevationDelta = 0.14 * g
            m.windowGain *= 1 + 0.30 * g
            m.windowRadiusScale *= 1 - 0.15 * g
            m.keyIntensityScale *= 1 + 0.15 * g
            m.exponentDelta += Float(0.15 * g)
        }

        // Condition: shifts the room from "sunny" toward "overcast"/"stormy" —
        // flatter and cooler, and in cloud/rain/storm's case *brighter* fill
        // (an overcast sky is a huge soft light source) — never darker
        // overall. See the policy floor below.
        switch condition {
        case .clear:
            break
        case .cloudy:
            m.windowGain *= 0.80
            m.windowRadiusScale *= 1.50
            m.wallScale *= 1.18
            m.ceilingScale *= 0.95
            m.fillIntensityScale *= 1.20
            m.keyTint *= SIMD3(0.95, 0.97, 1.03)
        case .rain:
            m.windowGain *= 0.72
            m.windowRadiusScale *= 1.60
            m.wallScale *= 1.20
            m.ceilingScale *= 0.92
            m.fillIntensityScale *= 1.28
            m.keyTint *= SIMD3(0.90, 0.95, 1.05)
            m.backgroundTint = SIMD3(0.55, 0.58, 0.63)
            m.backgroundBlend = 0.25
        case .snow:
            m.windowGain *= 0.95
            m.wallScale *= 1.12
            m.fillIntensityScale *= 1.35
            m.keyTint *= SIMD3(0.97, 0.98, 1.02)
            m.backgroundTint = SIMD3(0.82, 0.85, 0.90)
            m.backgroundBlend = 0.20
        case .thunderstorm:
            m.windowGain *= 0.65
            m.windowRadiusScale *= 1.65
            m.wallScale *= 1.25
            m.ceilingScale *= 0.90
            m.fillIntensityScale *= 1.30
            m.keyTint *= SIMD3(0.88, 0.93, 1.06)
            m.backgroundTint = SIMD3(0.42, 0.45, 0.52)
            m.backgroundBlend = 0.35
        }

        if isNightPreset {
            m = lerpModifier(.neutral, m, t: VisualTuning.sky.nightModifierScale)
        }

        // Policy floor: weather may brighten, warm, cool or flatten a room —
        // never darken it below today's own baseline.
        m.keyIntensityScale = max(1, m.keyIntensityScale)
        m.fillIntensityScale = max(1, m.fillIntensityScale)
        m.ceilingScale = max(0.85, m.ceilingScale)
        return m
    }
}

private func smoothstep(_ t: Double) -> Double {
    let x = min(1, max(0, t))
    return x * x * (3 - 2 * x)
}

private func mix3(_ a: SIMD3<Double>, _ b: SIMD3<Double>, t: Double) -> SIMD3<Double> {
    a + (b - a) * t
}

private func lerpModifier(_ a: SkyModifier, _ b: SkyModifier, t: Double) -> SkyModifier {
    var m = SkyModifier()
    m.windowGain = a.windowGain + (b.windowGain - a.windowGain) * t
    m.windowTint = mix3(a.windowTint, b.windowTint, t: t)
    m.windowRadiusScale = a.windowRadiusScale + (b.windowRadiusScale - a.windowRadiusScale) * t
    m.windowElevationDelta = a.windowElevationDelta + (b.windowElevationDelta - a.windowElevationDelta) * t
    m.ceilingScale = a.ceilingScale + (b.ceilingScale - a.ceilingScale) * t
    m.wallScale = a.wallScale + (b.wallScale - a.wallScale) * t
    m.keyTint = mix3(a.keyTint, b.keyTint, t: t)
    m.keyIntensityScale = a.keyIntensityScale + (b.keyIntensityScale - a.keyIntensityScale) * t
    m.fillIntensityScale = a.fillIntensityScale + (b.fillIntensityScale - a.fillIntensityScale) * t
    m.exponentDelta = a.exponentDelta + (b.exponentDelta - a.exponentDelta) * Float(t)
    m.backgroundTint = mix3(a.backgroundTint, b.backgroundTint, t: t)
    m.backgroundBlend = a.backgroundBlend + (b.backgroundBlend - a.backgroundBlend) * t
    return m
}
