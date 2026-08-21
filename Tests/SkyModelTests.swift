//
//  SkyModelTests.swift
//  QoobTests
//
//  Coverage for the pure-model half of live weather (`SkyModel.swift`,
//  `SkySystem.swift`) — no RealityKit, no WeatherKit, no CoreLocation. The
//  policy-floor sweep is the one that matters most: it's what keeps a future
//  tuning change from quietly reopening the "Qoob turns into an illegible
//  blob" bug `RoomLight.night` was built to avoid.
//

import Testing
import Foundation
@testable import Qoob

/// Every (condition, phase, night-preset) combination `neverDarker` sweeps.
private let neverDarkerCases: [(condition: SkyCondition, phase: SolarPhase, isNightPreset: Bool)] = {
    var cases: [(condition: SkyCondition, phase: SolarPhase, isNightPreset: Bool)] = []
    for condition in SkyCondition.allCases {
        for phase: SolarPhase in [.night, .goldenRise, .day, .goldenSet] {
            for isNightPreset in [false, true] {
                cases.append((condition, phase, isNightPreset))
            }
        }
    }
    return cases
}()

@Suite("Sky model")
struct SkyModelTests {

    // MARK: - SolarWindow

    @Test("golden hour peaks exactly at sunrise/sunset and fades either side")
    func goldenPeaksAtEdges() {
        let sunrise = Date(timeIntervalSince1970: 6 * 3600)
        let sunset = Date(timeIntervalSince1970: 18 * 3600)
        let window = SolarWindow(sunrise: sunrise, sunset: sunset, validFor: sunrise)

        #expect(window.goldenness(at: sunrise) > 0.99)
        #expect(window.goldenness(at: sunset) > 0.99)
        // Well inside the 40-minute half-width.
        #expect(window.goldenness(at: sunrise.addingTimeInterval(20 * 60)) > 0.15)
        // Well outside it.
        #expect(window.goldenness(at: sunrise.addingTimeInterval(41 * 60)) < 0.05)
        // Midday and midnight both have no golden hour to speak of.
        let noon = Date(timeIntervalSince1970: 12 * 3600)
        #expect(window.goldenness(at: noon) < 0.01)
    }

    @Test("phase resolves to day at noon and night at midnight")
    func phaseAtNoonAndMidnight() {
        let sunrise = Date(timeIntervalSince1970: 6 * 3600)
        let sunset = Date(timeIntervalSince1970: 18 * 3600)
        let window = SolarWindow(sunrise: sunrise, sunset: sunset, validFor: sunrise)

        #expect(window.phase(at: Date(timeIntervalSince1970: 12 * 3600)) == .day)
        #expect(window.phase(at: Date(timeIntervalSince1970: 0)) == .night)
        #expect(window.phase(at: sunrise) == .goldenRise)
        #expect(window.phase(at: sunset) == .goldenSet)
    }

    @Test("missing sun times degrade to a stable default rather than crashing")
    func missingSunTimes() {
        let window = SolarWindow(sunrise: nil, sunset: nil, validFor: .distantPast)
        #expect(window.goldenness(at: Date()) == 0)
        #expect(window.daylight(at: Date()) == 1)
        #expect(window.phase(at: Date()) == .day)
    }

    @Test("a sunset before sunrise (bad data) never produces a negative daylight ramp")
    func badOrdering() {
        let window = SolarWindow(sunrise: Date(timeIntervalSince1970: 18 * 3600),
                                 sunset: Date(timeIntervalSince1970: 6 * 3600),
                                 validFor: .distantPast)
        let d = window.daylight(at: Date(timeIntervalSince1970: 12 * 3600))
        #expect(d >= 0 && d <= 1)
    }

    // MARK: - SkyModifier

    @Test("neutral is the exact multiplicative/additive identity")
    func neutralIsIdentity() {
        let m = SkyModifier.neutral
        #expect(m.windowGain == 1 && m.windowRadiusScale == 1)
        #expect(m.windowTint == SIMD3(1, 1, 1))
        #expect(m.windowElevationDelta == 0)
        #expect(m.ceilingScale == 1 && m.wallScale == 1)
        #expect(m.keyTint == SIMD3(1, 1, 1))
        #expect(m.keyIntensityScale == 1 && m.fillIntensityScale == 1)
        #expect(m.exponentDelta == 0)
        #expect(m.backgroundBlend == 0)
    }

    @Test("clear weather in plain daylight makes exactly the identity")
    func clearDayIsNeutral() {
        let m = SkyModifier.make(condition: .clear, phase: .day, goldenness: 0, isNightPreset: false)
        #expect(m == .neutral)
    }

    /// The policy floor: weather may brighten, warm, cool or flatten a room —
    /// never darken it below today's own baseline. Swept across every
    /// condition/phase/night combination so a future tuning change can't
    /// quietly reopen the legibility bug this exists to prevent.
    @Test("never darkens a room below today's baseline", arguments: neverDarkerCases)
    func neverDarker(_ testCase: (condition: SkyCondition, phase: SolarPhase, isNightPreset: Bool)) {
        let (condition, phase, isNightPreset) = testCase
        for goldenness in [0.0, 0.5, 1.0] {
            let m = SkyModifier.make(condition: condition, phase: phase,
                                     goldenness: goldenness, isNightPreset: isNightPreset)
            #expect(m.keyIntensityScale >= 1)
            #expect(m.fillIntensityScale >= 1)
            #expect(m.ceilingScale >= 0.85)
            // Tints should shift the mood, not swing it to something absurd.
            for c in [m.keyTint, m.windowTint, m.backgroundTint] {
                #expect(c.x > 0.4 && c.x < 1.7)
                #expect(c.y > 0.4 && c.y < 1.7)
                #expect(c.z > 0.4 && c.z < 1.7)
            }
            #expect(abs(m.windowElevationDelta) <= 1)
            #expect(m.backgroundBlend >= 0 && m.backgroundBlend <= 1)
        }
    }

    @Test("the night preset damps weather/golden-hour effects rather than ignoring them")
    func nightDampens() {
        let day = SkyModifier.make(condition: .rain, phase: .day, goldenness: 0, isNightPreset: false)
        let night = SkyModifier.make(condition: .rain, phase: .day, goldenness: 0, isNightPreset: true)
        // Damped toward neutral, but the day and night reads are different presets, so
        // don't expect them to line up beyond "night moved less far from 1 than day".
        #expect(abs(night.wallScale - 1) < abs(day.wallScale - 1))
        #expect(abs(night.wallScale - 1) > 0)
    }

    // MARK: - SkySystem

    @Test("ingesting nil returns the system to neutral and clear")
    @MainActor func ingestNil() {
        let sky = SkySystem()
        sky.ingest(SkySnapshot(condition: .thunderstorm,
                               sun: SolarWindow(sunrise: nil, sunset: nil, validFor: .distantPast),
                               fetchedAt: Date()),
                  now: Date())
        sky.update(now: Date(), monotonic: 0, isNightPreset: false)
        #expect(sky.condition == .thunderstorm)

        sky.ingest(nil, now: Date())
        sky.update(now: Date(), monotonic: 1, isNightPreset: false)
        #expect(sky.condition == .clear)
        #expect(sky.modifier == .neutral)
    }

    @Test("lightning only strikes during a thunderstorm, and within the configured bounds")
    @MainActor func lightningBounds() {
        let sky = SkySystem()
        // Not a storm: never strikes, however long we poll.
        sky.update(now: Date(), monotonic: 0, isNightPreset: false)
        for t in stride(from: 0.0, through: 500, by: 1) {
            #expect(sky.pollLightning(monotonic: t) == nil)
        }

        sky.ingest(SkySnapshot(condition: .thunderstorm,
                               sun: SolarWindow(sunrise: nil, sunset: nil, validFor: .distantPast),
                               fetchedAt: Date()),
                  now: Date())
        sky.update(now: Date(), monotonic: 1000, isNightPreset: false)

        var lastStrikeAt: Double?
        for t in stride(from: 1000.0, through: 1400, by: 0.5) {
            if let flash = sky.pollLightning(monotonic: t) {
                if let last = lastStrikeAt {
                    let gap = t - last
                    #expect(gap >= VisualTuning.sky.lightningMinInterval - 0.5)
                    #expect(gap <= VisualTuning.sky.lightningMaxInterval + 0.5)
                }
                lastStrikeAt = t
                #expect(flash.peak >= 0.4 && flash.peak <= 1.0)
                #expect(flash.thunderDistance >= 0 && flash.thunderDistance <= 1)
                #expect(flash.thunderDelay > 0)
            }
        }
        #expect(lastStrikeAt != nil)
    }

    @Test("a full relight is requested no more often than the configured floor")
    @MainActor func bakeThrottled() {
        let sky = SkySystem()
        var fullBakeTimes: [Double] = []
        let sunrise = Date(timeIntervalSince1970: 0)
        // `phase(at:)` only ever classifies golden hour when both edges are known
        // (see its doc comment), so this needs a real sunset too, however far away.
        let sunset = sunrise.addingTimeInterval(12 * 3600)
        // One-second steps straddling sunrise — far finer than the 20-second bake
        // floor, so this actually exercises the suppression rather than just
        // satisfying it by sampling coarser than the floor to begin with.
        for second in stride(from: -300, through: 300, by: 1) {
            let now = sunrise.addingTimeInterval(Double(second))
            sky.ingest(SkySnapshot(condition: .clear,
                                   sun: SolarWindow(sunrise: sunrise, sunset: sunset, validFor: sunrise),
                                   fetchedAt: now),
                      now: now)
            sky.update(now: now, monotonic: Double(second), isNightPreset: false)
            if case .full = sky.consumeRelight() { fullBakeTimes.append(Double(second)) }
        }
        #expect(fullBakeTimes.count >= 1)
        // `zip` with `dropFirst()` rather than an index range: a 0- or 1-element
        // array just yields no pairs instead of constructing an invalid range.
        for (a, b) in zip(fullBakeTimes, fullBakeTimes.dropFirst()) {
            #expect(b - a >= VisualTuning.sky.minBakeInterval)
        }
    }
}
