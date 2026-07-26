//
//  GamePalette.swift
//  TiltCube
//
//  Scene colours plus the gentle, Endorfun-inspired affirmations that surface
//  as the player matches tiles. The six face/tile accent colours come from the
//  cube-cat's symbols (see CatSymbols.swift). All original content.
//

import UIKit

enum GamePalette {

    /// Number of distinct faces/targets — one per cube-cat symbol.
    static var count: Int { CatSymbol.allCases.count }

    /// Accent colour for face/target index (the symbol's colour).
    static func color(_ index: Int) -> UIColor {
        CatSymbol.from(index).accent
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
