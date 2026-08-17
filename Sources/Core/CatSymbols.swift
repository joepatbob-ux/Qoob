//
//  CatSymbols.swift
//  Qoob
//
//  The six faces of the cube-cat, drawn procedurally so the game needs no
//  image assets yet. Each face's palette index (0–5, used throughout the game
//  core) maps to one CatSymbol here. When detailed 3D models arrive, these
//  glyphs are the reference for what each face depicts.
//
//  Face layout on the cube (see Level.startingFaces):
//    front = face · up = butt · down = 4 paws
//    left  = dot  · right = ring · back = three dots (triangle)
//
//  Textures are engine-agnostic UIImages (usable by SceneKit, RealityKit or a
//  Metal renderer) and are cached after first generation.
//

import UIKit

enum CatSymbol: Int, CaseIterable {
    case face = 0     // the cat's face
    case butt = 1     // the cat's rear
    case paws = 2     // four paws
    case dot = 3      // single dot   (left)
    case ring = 4     // a ring       (right)
    case triangle = 5 // three dots in a triangle (back)

    static func from(_ index: Int) -> CatSymbol {
        CatSymbol(rawValue: ((index % 6) + 6) % 6) ?? .face
    }

    /// Accent colour for this face (tile tint, glow, cube-face background).
    var accent: UIColor {
        switch self {
        case .face:     return UIColor(red: 0.95, green: 0.55, blue: 0.25, alpha: 1) // ginger
        case .butt:     return UIColor(red: 0.95, green: 0.60, blue: 0.72, alpha: 1) // pink
        case .paws:     return UIColor(red: 0.30, green: 0.72, blue: 0.68, alpha: 1) // teal
        case .dot:      return UIColor(red: 0.48, green: 0.48, blue: 0.86, alpha: 1) // indigo
        case .ring:     return UIColor(red: 0.95, green: 0.78, blue: 0.30, alpha: 1) // gold
        case .triangle: return UIColor(red: 0.52, green: 0.78, blue: 0.46, alpha: 1) // green
        }
    }

    var displayName: String {
        switch self {
        case .face: return "face"
        case .butt: return "butt"
        case .paws: return "paws"
        case .dot: return "dot"
        case .ring: return "ring"
        case .triangle: return "three dots"
        }
    }

    // MARK: - Glyph drawing

    /// Draws this symbol's shapes centred in `rect` using `ink`.
    func draw(in ctx: CGContext, rect: CGRect, ink: UIColor) {
        let s = min(rect.width, rect.height)
        ctx.setFillColor(ink.cgColor)
        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineCap(.round)

        // Helpers: coordinates relative to the rect centre, in units of `s`.
        func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + nx * s, y: rect.midY + ny * s)
        }
        func disc(_ nx: CGFloat, _ ny: CGFloat, _ nr: CGFloat) {
            let c = pt(nx, ny); let r = nr * s
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        func ringStroke(_ nx: CGFloat, _ ny: CGFloat, _ nr: CGFloat, _ lw: CGFloat) {
            let c = pt(nx, ny); let r = nr * s
            ctx.setLineWidth(lw * s)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        func triangleFill(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) {
            ctx.beginPath(); ctx.move(to: a); ctx.addLine(to: b); ctx.addLine(to: c)
            ctx.closePath(); ctx.fillPath()
        }
        func line(_ a: CGPoint, _ b: CGPoint, _ lw: CGFloat) {
            ctx.setLineWidth(lw * s); ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        }
        func paw(_ nx: CGFloat, _ ny: CGFloat, _ scale: CGFloat) {
            disc(nx, ny, 0.11 * scale)                       // main pad
            disc(nx - 0.10 * scale, ny - 0.13 * scale, 0.045 * scale) // toe beans
            disc(nx,                ny - 0.16 * scale, 0.045 * scale)
            disc(nx + 0.10 * scale, ny - 0.13 * scale, 0.045 * scale)
        }

        switch self {
        case .face:
            // ears
            triangleFill(pt(-0.34, -0.20), pt(-0.20, -0.36), pt(-0.10, -0.18))
            triangleFill(pt( 0.34, -0.20), pt( 0.20, -0.36), pt( 0.10, -0.18))
            // eyes
            disc(-0.16, -0.02, 0.055)
            disc( 0.16, -0.02, 0.055)
            // nose
            triangleFill(pt(-0.05, 0.10), pt(0.05, 0.10), pt(0.0, 0.17))
            // whiskers
            line(pt(-0.10, 0.13), pt(-0.40, 0.06), 0.02)
            line(pt(-0.10, 0.15), pt(-0.40, 0.15), 0.02)
            line(pt( 0.10, 0.13), pt( 0.40, 0.06), 0.02)
            line(pt( 0.10, 0.15), pt( 0.40, 0.15), 0.02)

        case .butt:
            // A cat's rear is an asterisk, so that's the whole glyph: six bold spokes
            // with the tail curling off the top.
            //
            // The cheeks are gone on purpose. Two filled discs either side merge into
            // one blob at any real size, and an asterisk drawn on top of them in the
            // same ink disappears completely — which is exactly what the original
            // 0.07-radius "pucker" did, and what a bigger one still did. There's only
            // one ink to draw with here, so the star has to stand alone to be seen.
            for i in 0..<3 {
                let angle = CGFloat(i) * .pi / 3
                let dx = cos(angle) * 0.27
                let dy = sin(angle) * 0.27
                line(pt(-dx, 0.06 - dy), pt(dx, 0.06 + dy), 0.075)
            }
            // Tail, curling up and away from behind it.
            ctx.setLineWidth(0.06 * s)
            ctx.beginPath()
            ctx.move(to: pt(0.05, -0.20))
            ctx.addCurve(to: pt(0.34, -0.44),
                         control1: pt(0.16, -0.40),
                         control2: pt(0.34, -0.24))
            ctx.strokePath()

        case .paws:
            paw(-0.20, -0.16, 1.0)
            paw( 0.20, -0.16, 1.0)
            paw(-0.20,  0.22, 1.0)
            paw( 0.20,  0.22, 1.0)

        case .dot:
            disc(0.0, 0.0, 0.15)

        case .ring:
            ringStroke(0.0, 0.0, 0.17, 0.06)

        case .triangle:
            disc( 0.0,  -0.17, 0.085)
            disc(-0.17,  0.13, 0.085)
            disc( 0.17,  0.13, 0.085)
        }
    }
}

private extension UIColor {
    /// A darker, richer version of this colour. The accents are pitched to glow on
    /// a dark slot, so used as ink straight onto a pale one the lighter ones (gold,
    /// pink) wash out — this keeps the hue and drops the brightness.
    func deepened() -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return self
        }
        return UIColor(hue: hue,
                       saturation: min(1, saturation * 1.25),
                       brightness: brightness * 0.62,
                       alpha: alpha)
    }

    /// Ink that stays legible on top of this colour: near-white over a dark fill,
    /// near-black over a light one. The accents run from deep indigo to pale gold, so
    /// a single fixed ink colour would disappear at one end of the set or the other.
    func contrastingInk() -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.55 ? UIColor(white: 0.13, alpha: 1)
                                : UIColor(white: 1.0, alpha: 0.96)
    }
}

/// Generates and caches the landing-spot textures.
///
/// The cube-face `decal` and HUD `icon` generators were removed along with the
/// face decals: Qoob's sides are sculpted now, so nothing consumed them.
enum SymbolTextures {

    private static var padCache: [Int: UIImage] = [:]

    private static let px: CGFloat = 256

    private static func renderer() -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1               // fixed pixel size, independent of screen
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: px, height: px), format: format)
    }

    /// A landing spot: the symbol's accent as a solid rounded square with the glyph
    /// large on top. This is what a target tile shows.
    ///
    /// It used to be a thin stroked outline with a small glyph floating inside it, on
    /// a transparent field so the floor read through. That was too quiet to be a
    /// destination — over a patterned floor, at this camera height, with the room
    /// scrolling past, an outline reads as decoration, and the glyph was small enough
    /// that a dot and a ring were hard to tell apart without stopping to look. Solid,
    /// with the glyph filling most of the pad, it's identifiable across the room.
    static func pad(_ index: Int) -> UIImage {
        if let cached = padCache[index] { return cached }
        let symbol = CatSymbol.from(index)
        let accent = symbol.accent

        let img = renderer().image { rctx in
            let ctx = rctx.cgContext
            let rect = CGRect(x: 0, y: 0, width: px, height: px)
                .insetBy(dx: px * 0.05, dy: px * 0.05)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: px * 0.17)
            accent.setFill()
            path.fill()
            // A deeper rim, so the pad keeps an edge where its accent lands close to
            // the floor's own colour — gold on a pale carpet, say.
            accent.deepened().setStroke()
            path.lineWidth = px * 0.035
            path.stroke()

            symbol.draw(in: ctx, rect: rect.insetBy(dx: px * 0.11, dy: px * 0.11),
                        ink: accent.contrastingInk())
        }
        padCache[index] = img
        return img
    }

}
