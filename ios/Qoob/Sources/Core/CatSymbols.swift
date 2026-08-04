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

    /// Soft pastel accent — readable for matching, calm on a linen field.
    var accent: UIColor {
        switch self {
        case .face:     return UIColor(red: 0.92, green: 0.62, blue: 0.42, alpha: 1) // apricot
        case .butt:     return UIColor(red: 0.90, green: 0.68, blue: 0.74, alpha: 1) // blush
        case .paws:     return UIColor(red: 0.52, green: 0.72, blue: 0.68, alpha: 1) // sage
        case .dot:      return UIColor(red: 0.58, green: 0.62, blue: 0.82, alpha: 1) // periwinkle
        case .ring:     return UIColor(red: 0.90, green: 0.76, blue: 0.42, alpha: 1) // honey
        case .triangle: return UIColor(red: 0.62, green: 0.74, blue: 0.52, alpha: 1) // moss
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

    /// Asset-catalog image name for optional hand-made face art. If present in
    /// the bundle it replaces the procedural glyph for this face.
    var assetName: String {
        switch self {
        case .face: return "cat_face"
        case .butt: return "cat_butt"
        case .paws: return "cat_paws"
        case .dot: return "cat_dot"
        case .ring: return "cat_ring"
        case .triangle: return "cat_triangle"
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
            // two cheeks
            disc(-0.15, 0.02, 0.20)
            disc( 0.15, 0.02, 0.20)
            // tail curling up
            ctx.setLineWidth(0.06 * s)
            ctx.beginPath()
            ctx.move(to: pt(0.0, -0.02))
            ctx.addCurve(to: pt(0.30, -0.34),
                         control1: pt(0.05, -0.28),
                         control2: pt(0.30, -0.12))
            ctx.strokePath()
            // little pucker
            disc(0.0, 0.05, 0.045)

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

/// Generates and caches the cube-face and tile textures for each symbol index.
enum SymbolTextures {

    private static var faceCache: [Int: UIImage] = [:]   // decals
    private static var tileCache: [Int: UIImage] = [:]
    private static var frameCache: [Int: UIImage] = [:]
    private static var iconCache: [Int: UIImage] = [:]

    private static let px: CGFloat = 256

    private static func renderer() -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1               // fixed pixel size, independent of screen
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: px, height: px), format: format)
    }

    /// Cube-face **decal**: soft ink glyph on transparent — reads on cream fur
    /// and lightly tinted faces without neon outlines.
    static func decal(_ index: Int) -> UIImage {
        if let cached = faceCache[index] { return cached }
        let symbol = CatSymbol.from(index)
        let img = renderer().image { rctx in
            let ctx = rctx.cgContext
            let full = CGRect(x: 0, y: 0, width: px, height: px)
            let inset = full.insetBy(dx: px * 0.14, dy: px * 0.14)
            ctx.setShadow(offset: CGSize(width: 0, height: px * 0.008), blur: px * 0.02,
                          color: UIColor(white: 0, alpha: 0.12).cgColor)
            symbol.draw(in: ctx, rect: inset, ink: GamePalette.ink.withAlphaComponent(0.88))
        }
        faceCache[index] = img
        return img
    }

    /// A compact HUD chip: ink glyph on a soft pastel rounded square.
    static func icon(_ index: Int) -> UIImage {
        if let cached = iconCache[index] { return cached }
        let symbol = CatSymbol.from(index)
        let img = renderer().image { rctx in
            let ctx = rctx.cgContext
            let full = CGRect(x: 0, y: 0, width: px, height: px)
            let bg = full.insetBy(dx: px * 0.06, dy: px * 0.06)
            let path = UIBezierPath(roundedRect: bg, cornerRadius: px * 0.28)
            symbol.accent.withAlphaComponent(0.55).setFill()
            path.fill()
            UIColor(white: 1, alpha: 0.35).setFill()
            path.fill()
            let inset = full.insetBy(dx: px * 0.24, dy: px * 0.24)
            symbol.draw(in: ctx, rect: inset, ink: GamePalette.ink.withAlphaComponent(0.85))
        }
        iconCache[index] = img
        return img
    }

    /// Life Force tile: cream square with a soft accent glyph.
    static func tile(_ index: Int) -> UIImage {
        if let cached = tileCache[index] { return cached }
        let symbol = CatSymbol.from(index)
        let img = renderer().image { rctx in
            let ctx = rctx.cgContext
            let full = CGRect(x: 0, y: 0, width: px, height: px)
            ctx.setFillColor(UIColor(red: 0.97, green: 0.95, blue: 0.91, alpha: 1).cgColor)
            ctx.fill(full)
            // soft inner wash of the accent
            ctx.setFillColor(symbol.accent.withAlphaComponent(0.18).cgColor)
            ctx.fill(full.insetBy(dx: px * 0.04, dy: px * 0.04))
            let inset = full.insetBy(dx: px * 0.20, dy: px * 0.20)
            symbol.draw(in: ctx, rect: inset, ink: GamePalette.ink.withAlphaComponent(0.75))
        }
        tileCache[index] = img
        return img
    }

    /// Soft rounded frame for the active Life Force pulse.
    static func frame(_ index: Int) -> UIImage {
        if let cached = frameCache[index] { return cached }
        let symbol = CatSymbol.from(index)
        let img = renderer().image { rctx in
            let rect = CGRect(x: 0, y: 0, width: px, height: px)
                .insetBy(dx: px * 0.10, dy: px * 0.10)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: px * 0.20)
            path.lineWidth = px * 0.035
            symbol.accent.withAlphaComponent(0.85).setStroke()
            path.stroke()
        }
        frameCache[index] = img
        return img
    }
}
