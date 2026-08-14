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

    private static var cache: [String: UIImage] = [:]
    private static let px: CGFloat = 256

    /// A tileable floor texture for `theme`, or nil for themes that aren't
    /// texture-based (`.default` defers to the environment — see
    /// `roomFloor(for:)`; `.checkerboard` is coloured per-cell by the renderer).
    static func floorTexture(_ theme: FloorTheme) -> UIImage? {
        switch theme {
        case .default, .checkerboard:
            return nil
        case .carpet:
            return cached("carpet", carpet)
        case .hardwood:
            return cached("hardwood", hardwood)
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

    // MARK: - Per-room floors ("Room Default")

    /// The floor that belongs to a given room, drawn in code so every space
    /// reads as its own place. This is what `.default` resolves to: previously
    /// it looked for `floor_<room>` / `carpet_albedo` assets that don't exist
    /// and fell through to a flat colour, which made every room a grey void.
    static func roomFloor(for environment: Environment) -> UIImage {
        switch environment {
        case .livingRoom: return cached("room.livingRoom", plushRug)
        case .kitchen:    return cached("room.kitchen", kitchenTile)
        case .bedroom:    return cached("room.bedroom", bedroomCarpet)
        case .yard:       return cached("room.yard", lawn)
        }
    }

    /// Matching normal map, so the room floors catch the light with some relief.
    static func roomFloorNormal(for environment: Environment) -> UIImage? {
        switch environment {
        case .kitchen: return cached("roomN.kitchen", kitchenTileNormal)
        case .yard:    return cached("roomN.yard", lawnNormal)
        // The soft floors read better with pure albedo speckle; a normal map on
        // top of fine speckle just reads as noise at this camera distance.
        case .livingRoom, .bedroom: return nil
        }
    }

    /// The two alternating colours for the checkerboard floor.
    static func checkerColor(dark: Bool) -> UIColor {
        dark ? UIColor(red: 0.20, green: 0.22, blue: 0.27, alpha: 1)
             : UIColor(red: 0.90, green: 0.89, blue: 0.84, alpha: 1)
    }

    // MARK: - Generation

    private static func cached(_ key: String, _ make: () -> UIImage) -> UIImage {
        if let img = cache[key] { return img }
        let img = make()
        cache[key] = img
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

    // MARK: - Room floors
    //
    // Each of these tiles seamlessly across the per-cell UVs the renderer sets
    // up, and is drawn with a fixed seed so a room looks the same every launch.
    // All detail is high-frequency or edge-aligned; anything mid-frequency would
    // show its repeat at this camera distance.

    /// Living room: a deep wool rug — warm dark base, dense speckle, plus a
    /// faint woven cross-hatch so it reads as pile rather than noise.
    private static func plushRug() -> UIImage {
        renderer().image { rctx in
            let ctx = rctx.cgContext
            ctx.setFillColor(UIColor(red: 0.17, green: 0.15, blue: 0.21, alpha: 1).cgColor)
            ctx.fill(fullRect)

            var rng = SeededGenerator(seed: 0x5A6E_1D0)
            speckle(ctx, &rng, count: 4200, radius: 1.3, maxAlpha: 0.07)

            // Woven cross-hatch: short strokes on a loose grid, both directions.
            for _ in 0..<520 {
                let x = CGFloat(rng.next() % UInt64(px))
                let y = CGFloat(rng.next() % UInt64(px))
                let horizontal = rng.next() % 2 == 0
                let len = 3 + CGFloat(rng.next() % 5)
                ctx.setStrokeColor(UIColor(white: rng.next() % 2 == 0 ? 1 : 0,
                                           alpha: 0.05).cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: x, y: y))
                ctx.addLine(to: horizontal ? CGPoint(x: x + len, y: y)
                                           : CGPoint(x: x, y: y + len))
                ctx.strokePath()
            }
        }
    }

    /// Kitchen: pale ceramic tile. One tile per texture repeat, with grout on the
    /// top and left edges so tiling produces a continuous grid, plus a soft
    /// mottle in the glaze.
    private static func kitchenTile() -> UIImage {
        renderer().image { rctx in
            let ctx = rctx.cgContext
            ctx.setFillColor(UIColor(red: 0.84, green: 0.83, blue: 0.79, alpha: 1).cgColor)
            ctx.fill(fullRect)

            var rng = SeededGenerator(seed: 0x71_1E00)
            // Glaze mottle: large, very faint blooms.
            for _ in 0..<70 {
                let x = CGFloat(rng.next() % UInt64(px))
                let y = CGFloat(rng.next() % UInt64(px))
                let r = 8 + CGFloat(rng.next() % 26)
                ctx.setFillColor(UIColor(white: rng.next() % 2 == 0 ? 1 : 0,
                                         alpha: 0.035).cgColor)
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
            speckle(ctx, &rng, count: 900, radius: 0.9, maxAlpha: 0.05)

            grout(ctx, width: 7, color: UIColor(red: 0.62, green: 0.61, blue: 0.58, alpha: 1))
        }
    }

    /// Relief for the kitchen tile: flat, with the grout channel pressed in on
    /// the same two edges so the grid catches a highlight.
    private static func kitchenTileNormal() -> UIImage {
        renderer().image { rctx in
            let ctx = rctx.cgContext
            flatNormal(ctx)
            // Left edge: surface falls away to the left (red below 0.5).
            ctx.setFillColor(UIColor(red: 0.24, green: 0.5, blue: 1.0, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 7, height: px))
            // Top edge: falls away upward (green below 0.5).
            ctx.setFillColor(UIColor(red: 0.5, green: 0.24, blue: 1.0, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: px, height: 7))
        }
    }

    /// Bedroom: a soft, warm carpet — lighter and pinker than the living room,
    /// with longer pile strands.
    private static func bedroomCarpet() -> UIImage {
        renderer().image { rctx in
            let ctx = rctx.cgContext
            ctx.setFillColor(UIColor(red: 0.25, green: 0.19, blue: 0.26, alpha: 1).cgColor)
            ctx.fill(fullRect)

            var rng = SeededGenerator(seed: 0xBED_0C42)
            speckle(ctx, &rng, count: 3600, radius: 1.5, maxAlpha: 0.07)

            // Pile: short strands leaning in a consistent direction, so the
            // carpet has a subtle nap.
            for _ in 0..<700 {
                let x = CGFloat(rng.next() % UInt64(px))
                let y = CGFloat(rng.next() % UInt64(px))
                let len = 2 + CGFloat(rng.next() % 4)
                ctx.setStrokeColor(UIColor(white: rng.next() % 3 == 0 ? 1 : 0,
                                           alpha: 0.06).cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: x, y: y))
                ctx.addLine(to: CGPoint(x: x + len * 0.4, y: y + len))
                ctx.strokePath()
            }
        }
    }

    /// Yard: mown lawn — layered greens with fine blade strokes in two
    /// directions, so it reads as grass from directly above.
    private static func lawn() -> UIImage {
        renderer().image { rctx in
            let ctx = rctx.cgContext
            ctx.setFillColor(UIColor(red: 0.29, green: 0.45, blue: 0.24, alpha: 1).cgColor)
            ctx.fill(fullRect)

            var rng = SeededGenerator(seed: 0x1A_4E00)
            // Broad patches of lighter/darker green, for unevenness.
            for _ in 0..<90 {
                let x = CGFloat(rng.next() % UInt64(px))
                let y = CGFloat(rng.next() % UInt64(px))
                let r = 10 + CGFloat(rng.next() % 30)
                let lighter = rng.next() % 2 == 0
                ctx.setFillColor(UIColor(red: lighter ? 0.42 : 0.20,
                                         green: lighter ? 0.58 : 0.36,
                                         blue: lighter ? 0.30 : 0.18,
                                         alpha: 0.20).cgColor)
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
            // Blades: short strokes, mostly upright with a scatter of angles.
            for _ in 0..<2600 {
                let x = CGFloat(rng.next() % UInt64(px))
                let y = CGFloat(rng.next() % UInt64(px))
                let len = 3 + CGFloat(rng.next() % 6)
                let lean = (CGFloat(rng.next() % 100) / 100.0 - 0.5) * 3
                let lighter = rng.next() % 3 != 0
                ctx.setStrokeColor(UIColor(red: lighter ? 0.46 : 0.19,
                                           green: lighter ? 0.62 : 0.33,
                                           blue: lighter ? 0.30 : 0.16,
                                           alpha: 0.55).cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: x, y: y))
                ctx.addLine(to: CGPoint(x: x + lean, y: y - len))
                ctx.strokePath()
            }
        }
    }

    /// Relief for the lawn: random blade-direction tilts, which under the key
    /// light gives the grass a broken, organic sparkle.
    private static func lawnNormal() -> UIImage {
        renderer().image { rctx in
            let ctx = rctx.cgContext
            flatNormal(ctx)

            var rng = SeededGenerator(seed: 0x1A_4E2E)
            for _ in 0..<2200 {
                let x = CGFloat(rng.next() % UInt64(px))
                let y = CGFloat(rng.next() % UInt64(px))
                let len = 3 + CGFloat(rng.next() % 6)
                let strength = 0.14 + CGFloat(rng.next() % 100) / 100.0 * 0.26
                let left = rng.next() % 2 == 0
                ctx.setStrokeColor(UIColor(red: left ? 0.5 - strength : 0.5 + strength,
                                           green: 0.5 + strength * 0.4,
                                           blue: 1.0, alpha: 0.6).cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: x, y: y))
                ctx.addLine(to: CGPoint(x: x, y: y - len))
                ctx.strokePath()
            }
        }
    }

    // MARK: - Drawing helpers

    /// Fine light/dark speckle. High-frequency, so tile seams stay invisible.
    private static func speckle(_ ctx: CGContext, _ rng: inout SeededGenerator,
                                count: Int, radius: CGFloat, maxAlpha: CGFloat) {
        for _ in 0..<count {
            let x = CGFloat(rng.next() % UInt64(px))
            let y = CGFloat(rng.next() % UInt64(px))
            let light = rng.next() % 2 == 0
            let alpha = maxAlpha * 0.4 + CGFloat(rng.next() % 100) / 100.0 * maxAlpha * 0.6
            ctx.setFillColor(UIColor(white: light ? 1 : 0, alpha: alpha).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius,
                                       width: 2 * radius, height: 2 * radius))
        }
    }

    /// Grout on the top and left edges only: when the texture repeats once per
    /// cell, adjacent copies share a single continuous line.
    private static func grout(_ ctx: CGContext, width: CGFloat, color: UIColor) {
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: px))
        ctx.fill(CGRect(x: 0, y: 0, width: px, height: width))
    }

    /// Fills with the tangent-space "no deviation" normal, RGB (0.5, 0.5, 1).
    private static func flatNormal(_ ctx: CGContext) {
        ctx.setFillColor(UIColor(red: 0.5, green: 0.5, blue: 1.0, alpha: 1).cgColor)
        ctx.fill(fullRect)
    }
}
