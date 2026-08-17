//
//  Haptics.swift
//  Qoob
//
//  Light tactile feedback for rolls and matches. No-ops on devices without a
//  Taptic Engine (and on the Simulator).
//
//  `UIImpactFeedbackGenerator` is `API_UNAVAILABLE(tvos)` — there's nothing in an
//  Apple TV to tap — so on tvOS the whole enum compiles down to empty calls and
//  the callers (which already gate on the player's Haptics setting) stay as they
//  are. A Mac has no Taptic Engine either, but the API exists under Catalyst and
//  quietly does nothing, so it needs no branch.
//

import UIKit

#if os(tvOS)

enum Haptics {
    static func prepare() {}
    static func roll() {}
    static func match() {}
    static func blocked() {}
}

#else

enum Haptics {
    private static let roller = UIImpactFeedbackGenerator(style: .light)
    private static let matcher = UIImpactFeedbackGenerator(style: .medium)

    /// Call once (e.g. at level start) to reduce first-tap latency.
    static func prepare() {
        roller.prepare()
        matcher.prepare()
    }

    static func roll() {
        roller.impactOccurred(intensity: 0.6)
        roller.prepare()
    }

    static func match() {
        matcher.impactOccurred()
        matcher.prepare()
    }

    /// A soft nudge when a roll is refused (wrong face for a target tile).
    static func blocked() {
        roller.impactOccurred(intensity: 0.3)
        roller.prepare()
    }
}

#endif
