//
//  GamePalette.swift
//  Qoob
//
//  Scene colours plus the gentle, Endorfun-inspired affirmations that surface
//  as the player matches tiles. The six face/tile accent colours come from the
//  cube-cat's symbols (see CatSymbols.swift). All original content.
//

import UIKit

/// Which of the two looks the game is wearing. Everything that has a light and a
/// dark form — the rooms, and Qoob's own coat — takes one of these, resolved from
/// the system appearance by the renderer.
///
/// It's a plain enum rather than dynamic `UIColor`s because RealityKit resolves a
/// material's colour once, when the material is built: a dynamic colour would be
/// baked to whichever appearance happened to be active at level start and then
/// never change.
enum Appearance {
    case light, dark
}

enum GamePalette {

    /// Number of distinct faces/targets — one per cube-cat symbol.
    static var count: Int { CatSymbol.allCases.count }

    /// Accent colour for face/target index (the symbol's colour).
    static func color(_ index: Int) -> UIColor {
        CatSymbol.from(index).accent
    }

    /// A calm background tint for the scene, before a level picks its room.
    static func background(_ appearance: Appearance) -> UIColor {
        switch appearance {
        case .dark:  return UIColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1)
        case .light: return UIColor(red: 0.91, green: 0.90, blue: 0.88, alpha: 1)
        }
    }

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

/// Qoob's coat, in its two colourways: a cream plush cat for light mode and a
/// black one for dark. Modelled on the pair of cushion plushes this is based on —
/// the black cat's bright blue eyes are the one strong accent on it.
///
/// Markings invert with the coat. Dark spots on a black cat would be invisible,
/// and they're the only way to tell three of Qoob's six sides apart.
enum CatCoat {

    /// The body.
    static func body(_ appearance: Appearance) -> UIColor {
        switch appearance {
        case .light: return UIColor(red: 0.94, green: 0.92, blue: 0.88, alpha: 1)
        case .dark:  return UIColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1)
        }
    }

    /// Spots and rings — pitched well clear of the body either way, since these
    /// identify three of the six sides.
    static func marking(_ appearance: Appearance) -> UIColor {
        switch appearance {
        case .light: return UIColor(red: 0.42, green: 0.39, blue: 0.37, alpha: 1)
        case .dark:  return UIColor(red: 0.62, green: 0.62, blue: 0.66, alpha: 1)
        }
    }

    /// Nose, inner ear and paw pads. Pink on both coats, a touch deeper on the
    /// black cat so it doesn't glare.
    static func nose(_ appearance: Appearance) -> UIColor {
        switch appearance {
        case .light: return UIColor(red: 0.95, green: 0.72, blue: 0.73, alpha: 1)
        case .dark:  return UIColor(red: 0.82, green: 0.56, blue: 0.60, alpha: 1)
        }
    }

    /// Eyes: near-black on the cream cat, bright blue on the black one.
    static func eye(_ appearance: Appearance) -> UIColor {
        switch appearance {
        case .light: return UIColor(red: 0.20, green: 0.19, blue: 0.22, alpha: 1)
        case .dark:  return UIColor(red: 0.35, green: 0.68, blue: 0.95, alpha: 1)
        }
    }

    /// Whiskers, in the coat's opposing colour — dark on the cream cat, white on
    /// the black one. They were tried in a low-contrast grey first and read as
    /// specks of dirt; a whisker is only a pixel or two wide, so full contrast is
    /// the only thing that makes it a line rather than a smudge.
    static func whisker(_ appearance: Appearance) -> UIColor {
        switch appearance {
        case .light: return UIColor(red: 0.22, green: 0.20, blue: 0.21, alpha: 1)
        case .dark:  return UIColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)
        }
    }
}
