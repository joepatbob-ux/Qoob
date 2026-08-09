//
//  Haptics.swift
//  Qoob
//
//  Light tactile feedback for rolls and matches. No-ops on devices without a
//  Taptic Engine (and on the Simulator).
//

import UIKit

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
