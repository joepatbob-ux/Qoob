//
//  GamePalette.swift
//  TiltCube
//
//  The six face colours plus the gentle, Endorfun-inspired affirmations that
//  surface as the player matches tiles. All original content — none of the
//  colours, words, or audio here are derived from the copyrighted game.
//

import UIKit

enum GamePalette {

    /// The six cube-face / tile colours. Index order is fixed and referenced
    /// everywhere by integer, so keep it stable.
    static let colors: [UIColor] = [
        UIColor(red: 0.94, green: 0.30, blue: 0.36, alpha: 1.0), // 0 rose
        UIColor(red: 0.98, green: 0.72, blue: 0.24, alpha: 1.0), // 1 amber
        UIColor(red: 0.42, green: 0.80, blue: 0.44, alpha: 1.0), // 2 leaf
        UIColor(red: 0.30, green: 0.72, blue: 0.86, alpha: 1.0), // 3 sky
        UIColor(red: 0.46, green: 0.44, blue: 0.86, alpha: 1.0), // 4 indigo
        UIColor(red: 0.90, green: 0.52, blue: 0.80, alpha: 1.0)  // 5 orchid
    ]

    static var count: Int { colors.count }

    static func color(_ index: Int) -> UIColor {
        colors[((index % count) + count) % count]
    }

    /// A calm background tint for the scene.
    static let background = UIColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1.0)

    /// Neutral (non-target) floor tile colour.
    static let neutralTile = UIColor(red: 0.16, green: 0.17, blue: 0.22, alpha: 1.0)

    /// Short positive affirmations shown on each successful match.
    static let mantras: [String] = [
        "breathe",
        "be here now",
        "you are enough",
        "let it flow",
        "calm and clear",
        "one step at a time",
        "soften",
        "trust yourself",
        "this moment",
        "gently onward",
        "open",
        "you've got this"
    ]

    static func randomMantra() -> String {
        mantras.randomElement() ?? "breathe"
    }
}
