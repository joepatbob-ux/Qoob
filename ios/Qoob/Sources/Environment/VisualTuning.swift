//
//  VisualTuning.swift
//  Qoob
//
//  ONE place for every "feel" constant added by the visual-polish layer:
//  Qoob's soft-body squash, the shared wind, the fur, and the grass. None of
//  these values touch gameplay, level logic, camera behaviour, or the roll
//  itself — they only affect how things *look*.
//
//  Tweak a number here, rebuild, and the effect changes; no logic edits needed.
//  Values are deliberately conservative (subtle > showy). Bump the *amount*
//  fields up if you want a stronger effect.
//
//  Pure model — no SceneKit/UIKit types, so it stays engine-agnostic and can be
//  read by any renderer.
//

import Foundation

// MARK: - Wind (shared environmental driver)

/// Parameters for the shared `WindSystem`. Consumers (fur, grass, and any
/// future plant/pollen/leaf) read the wind it produces and scale it by their
/// own gain — so tuning here changes the *whole* scene's breeze at once.
struct WindConfig {
    /// Nominal heading the breeze blows toward, on the ground plane (radians;
    /// 0 = +X / "right", .pi/2 = +Z / "toward the player").
    var baseDirection: Double = 0.6
    /// How far the heading wanders from `baseDirection` (radians).
    var directionDrift: Double = 0.5
    /// How quickly the heading wanders (higher = faster meander).
    var directionDriftRate: Double = 0.05

    /// Gentle ever-present breeze strength (0…1-ish). Keep small.
    var baseStrength: Double = 0.12
    /// Speed of the base breeze's slow shimmer.
    var variationRate: Double = 0.25

    /// Extra strength a gust adds at its peak (added on top of `baseStrength`).
    var gustStrength: Double = 0.5
    /// Seconds a single gust takes to rise and fall.
    var gustDuration: Double = 2.2
    /// Average seconds between gusts.
    var gustInterval: Double = 9.0

    /// Hard ceiling on total strength, so nothing ever gets blown flat.
    var maxStrength: Double = 1.0
}

// MARK: - Qoob soft-body

/// Qoob's plush-cube deformation. Everything is a scale around the cube's
/// centre, distributed so the squash always reads as world-*vertical* no matter
/// which face is up. Amounts are fractions of the cube size.
struct QoobSoftBodyConfig {
    // Idle "breathing" — a slow, barely-there swell so Qoob reads as alive.
    var breatheAmplitude: Double = 0.025   // ±2.5% height
    var breathePeriod: Double = 3.4        // seconds per full breath

    // Anticipation — a quick gather right as a roll begins (reads as a crouch).
    var anticipationDuration: Double = 0.045
    var anticipationCrouch: Double = 0.035 // squash down before tipping

    // Landing — the squash when a face slaps the ground.
    var landDuration: Double = 0.06
    var squashAmount: Double = 0.09        // ← main "squash amount" knob

    // Rebound — a small overshoot back the other way.
    var reboundDuration: Double = 0.09
    var reboundAmount: Double = 0.05       // ← main "rebound amount" knob

    // Settle — ease back to a perfect cube.
    var settleDuration: Double = 0.13

    /// Safety clamp: deformation never exceeds this, so the player can always
    /// read which face is up (keeps it a cube, not jelly).
    var maxDeformation: Double = 0.14
}

// MARK: - Fur (silhouette tufts on Qoob)

/// Small tufts on Qoob's corners that ruffle in the wind — the *silhouette*
/// moves while the cube body stays structurally solid.
struct FurConfig {
    var enabled: Bool = true

    // Kept small on purpose. At 0.16 the eight corner tufts stood well clear of
    // Qoob's outline and read as white spikes or scratches around him rather than
    // as fur — the more so now that his body is otherwise clean.
    var tuftHeight: Double = 0.07          // how far a tuft sticks out
    var tuftBaseRadius: Double = 0.030     // thickness at the root

    /// Max lean (radians) a tuft reaches at full wind. ← main "fur response" knob.
    var windResponse: Double = 0.32
    /// Idle ruffle amplitude (radians) with no wind — barely noticeable.
    var baseSway: Double = 0.05
    /// Idle ruffle speed.
    var swayRate: Double = 1.7
    /// Absolute cap on tuft lean so fur never folds flat.
    var maxBend: Double = 0.45
}

// MARK: - Grass (outdoor vegetation)

/// Grass clumps for outdoor (yard) levels. They pivot near their base, sway
/// with the shared wind at slightly different rates, and bend away from Qoob.
struct GrassConfig {
    /// Max lean (radians) from wind at full strength. ← main "grass sway" knob.
    var swayAmount: Double = 0.35
    /// Base per-clump oscillation speed (each clump varies around this).
    var swayRate: Double = 1.3
    /// How much rate/phase varies clump-to-clump (0…1) so they desync.
    var swayVariation: Double = 0.5

    /// How fast grass springs back after Qoob passes (higher = snappier).
    /// ← main "grass recovery" knob.
    var recovery: Double = 6.0
    /// How close (world units) Qoob must be to start pushing a clump.
    var interactionRadius: Double = 1.3
    /// Max bend (radians) Qoob's proximity adds.
    var interactionStrength: Double = 0.5

    /// Probability a free interior cell grows a (short) clump.
    var interiorDensity: Double = 0.16
    /// Probability a border-ring cell grows a (taller) clump.
    var borderDensity: Double = 0.55

    var bladesPerClump: Int = 4
    var interiorHeight: Double = 0.15
    var borderHeight: Double = 0.26

    /// Absolute cap on clump count, for performance headroom on phones.
    var maxClumps: Int = 44

    /// Hard cap on total lean (wind + interaction) so grass never lies flat.
    var maxLean: Double = 0.75
}

// MARK: - Aggregated defaults

/// The single set of live defaults. Controllers read from here unless handed a
/// custom config, so editing these fields re-tunes the whole game.
enum VisualTuning {
    static var wind = WindConfig()
    static var qoob = QoobSoftBodyConfig()
    static var fur = FurConfig()
    static var grass = GrassConfig()
}
