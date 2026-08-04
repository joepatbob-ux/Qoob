//
//  GamePalette.swift
//  Qoob
//
//  Classic Soft visual system: warm linen field, quiet ink, soft pastels.
//  Meditative and minimal — the cute cat sits in a calm, paper-like world.
//  Affirmations are original; tone is gentle, never punishing.
//

import UIKit

enum GamePalette {

    /// Number of distinct faces/targets — one per cube-cat symbol.
    static var count: Int { CatSymbol.allCases.count }

    /// Accent colour for face/target index (the symbol's colour).
    static func color(_ index: Int) -> UIColor {
        CatSymbol.from(index).accent
    }

    // MARK: - Classic Soft surfaces

    /// Scene / menu backdrop — warm paper.
    static let background = UIColor(red: 0.94, green: 0.91, blue: 0.86, alpha: 1.0)

    /// Default play-tile colour (no texture).
    static let neutralTile = UIColor(red: 0.90, green: 0.86, blue: 0.80, alpha: 1.0)

    /// Soft cream fur base when no fur texture is bundled.
    static let catFur = UIColor(red: 0.96, green: 0.90, blue: 0.82, alpha: 1.0)

    /// Ink for glyphs / HUD on light surfaces.
    static let ink = UIColor(red: 0.22, green: 0.20, blue: 0.18, alpha: 1.0)

    /// Quieter secondary ink.
    static let inkMuted = UIColor(red: 0.45, green: 0.42, blue: 0.38, alpha: 1.0)

    /// Soft ceramic for Simple Blocks (tinted per colour in the renderer).
    static let ceramic = UIColor(red: 0.93, green: 0.90, blue: 0.86, alpha: 1.0)

    /// Short positive affirmations shown on each successful merge.
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
        "you've got this",
        "you are safe",
        "you are strong",
        "all is well",
        "soft and steady",
        "you create joy",
        "trust your path",
        "feel the rhythm",
        "you are free",
        "nurture yourself",
        "open to more joy",
        "you are whole",
        "move with ease",
    ]

    static func randomMantra() -> String {
        mantras.randomElement() ?? "breathe"
    }
}
