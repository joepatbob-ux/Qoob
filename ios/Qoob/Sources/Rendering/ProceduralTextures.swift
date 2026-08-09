//
//  ProceduralTextures.swift
//  Qoob
//
//  Procedurally generated floor looks, selectable in Settings. Everything here
//  is drawn in code (Core Graphics) so the game needs no art assets. Textures
//  are designed to tile across the per-cell UVs the renderer already uses, and
//  are cached after first generation.
//
//  `.default` keeps the environment's own floor (bundled texture or colour).
//  `.checkerboard` is drawn per-cell by the renderer (see `checkerColor`), so
//  it has no texture image. The rest return a tileable UIImage.
//

import UIKit

/// A selectable floor style. Raw values persist the choice in UserDefaults.
enum FloorTheme: String, CaseIterable, Identifiable {
    case `default`
    case checkerboard
    case carpet
    case hardwood
    case greyCarpet   // bundled PBR material (basecolor + normal)
    case grass        // bundled PBR material (basecolor + normal)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .default:      return "Room Default"
        case .checkerboard: return "Checkerboard"
        case .carpet:       return "Plush Carpet"
        case .hardwood:     return "Hardwood"
        case .greyCarpet:   return "Grey Carpet"
        case .grass:        return "Grass"
        }
    }
}

enum ProceduralTextures {

    private static var cache: [FloorTheme: UIImage] = [:]
    private static let px: CGFloat = 256

    /// A tileable floor texture for `theme`, or nil for themes that aren't
    /// texture-based (`.default` defers to the environment; `.checkerboard` is
    /// coloured per-cell by the renderer).
    static func floorTexture(_ theme: FloorTheme) -> UIImage? {
        switch theme {
        case .default, .checkerboard:
            return nil
        case .carpet:
            return cached(theme, carpet)
        case .hardwood:
            return cached(theme, hardwood)
        case .greyCarpet:
            return UIImage(named: "CarpetGreyBasecolor")   // bundled asset
        case .grass:
            return UIImage(named: "GrassBaseColor")        // bundled asset
        }
    }

    /// The tangent-space normal map for a theme, if it ships one.
    static func floorNormal(_ theme: FloorTheme) -> UIImage? {
        switch theme {
        case .greyCarpet: return UIImage(named: "CarpetGreyNormal")
        case .grass:      return UIImage(named: "GrassNormal")
        default:          return nil
        }
    }

    /// The two alternating colours for the checkerboard floor.
    static func checkerColor(dark: Bool) -> UIColor {
        dark ? UIColor(red: 0.20, green: 0.22, blue: 0.27, alpha: 1)
             : UIColor(red: 0.90, green: 0.89, blue: 0.84, alpha: 1)
    }

    // MARK: - Generation

    private static func cached(_ theme: FloorTheme, _ make: () -> UIImage) -> UIImage {
        if let img = cache[theme] { return img }
        let img = make()
        cache[theme] = img
        return img
    }

    private static func renderer() -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1                 // fixed pixel size, independent of screen
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: px, height: px), format: format)
    }

    private static var fullRect: CGRect { CGRect(x: 0, y: 0, width: px, height: px) }

    /// Plush carpet: a warm base flecked with fine light/dark speckle. The
    /// speckle is high-frequency, so tile seams are imperceptible.
    private static func carpet() -> UIImage {
        renderer().image { rctx in
            let ctx = rctx.cgContext
            ctx.setFillColor(UIColor(red: 0.31, green: 0.45, blue: 0.49, alpha: 1).cgColor)
            ctx.fill(fullRect)

            var rng = SeededGenerator(seed: 0xCA49_7E1)
            for _ in 0..<3000 {
                let x = CGFloat(rng.next() % UInt64(px))
                let y = CGFloat(rng.next() % UInt64(px))
                let light = rng.next() % 2 == 0
                let alpha = 0.06 + CGFloat(rng.next() % 100) / 100.0 * 0.10
                ctx.setFillColor(UIColor(white: light ? 1 : 0, alpha: alpha).cgColor)
                let r: CGFloat = 1.2
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
        }
    }

    /// Hardwood: a warm brown base with continuous horizontal grain (so it
    /// tiles across width) and a dark seam at the top edge (so vertical tiling
    /// reads as one plank per cell).
    private static func hardwood() -> UIImage {
        renderer().image { rctx in
            let ctx = rctx.cgContext
            ctx.setFillColor(UIColor(red: 0.55, green: 0.37, blue: 0.21, alpha: 1).cgColor)
            ctx.fill(fullRect)

            var rng = SeededGenerator(seed: 0x0AA5_D00)
            for _ in 0..<80 {
                let y = CGFloat(rng.next() % UInt64(px))
                let dark = rng.next() % 2 == 0
                let alpha = 0.04 + CGFloat(rng.next() % 100) / 100.0 * 0.08
                ctx.setStrokeColor(UIColor(white: dark ? 0 : 1, alpha: alpha).cgColor)
                ctx.setLineWidth(CGFloat(1 + rng.next() % 2))
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: px, y: y))
                ctx.strokePath()
            }

            // Plank seam along the top edge → a groove between cells when tiled.
            ctx.setStrokeColor(UIColor(white: 0, alpha: 0.38).cgColor)
            ctx.setLineWidth(2)
            ctx.move(to: CGPoint(x: 0, y: 1))
            ctx.addLine(to: CGPoint(x: px, y: 1))
            ctx.strokePath()
        }
    }
}
