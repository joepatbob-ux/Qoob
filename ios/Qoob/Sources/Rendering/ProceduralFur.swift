//
//  ProceduralFur.swift
//  Qoob
//
//  Code-generated, tileable fur textures so the cube-cat reads as soft fur with
//  no art assets required. Two maps, both drawn with Core Graphics and cached:
//
//    • albedo — a near-white base flecked with fine speckle and faint vertical
//      strands. Kept mostly neutral so the material's baseColor tint controls
//      the actual fur colour.
//    • normal — a tangent-space normal map whose fine vertical ridges give the
//      surface a directional, strand-like micro-relief under lighting. This is
//      also what the shimmer effect scrolls (see `addTextureScroll`).
//
//  The renderer prefers bundled `fur_albedo` / `fur_normal` assets if present
//  (see BundledTextures) and falls back to these.
//

import UIKit

enum ProceduralFur {

    private static var albedoCache: UIImage?
    private static var normalCache: UIImage?
    private static let px: CGFloat = 256

    /// A near-white, subtly-speckled fur albedo (tint it via the material).
    static func albedo() -> UIImage {
        if let cached = albedoCache { return cached }
        let img = renderer(opaque: true).image { rctx in
            let ctx = rctx.cgContext
            ctx.setFillColor(UIColor(white: 0.92, alpha: 1).cgColor)
            ctx.fill(fullRect)

            var rng = SeededGenerator(seed: 0xF0A1_CA7)
            // Fine light/dark speckle — high frequency so seams are invisible.
            for _ in 0..<4000 {
                let x = CGFloat(rng.next() % UInt64(px))
                let y = CGFloat(rng.next() % UInt64(px))
                let light = rng.next() % 2 == 0
                let alpha = 0.04 + CGFloat(rng.next() % 100) / 100.0 * 0.10
                ctx.setFillColor(UIColor(white: light ? 1 : 0, alpha: alpha).cgColor)
                let r: CGFloat = 1.0
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
            // Faint vertical strands for a brushed-fur direction.
            for _ in 0..<220 {
                let x = CGFloat(rng.next() % UInt64(px))
                let dark = rng.next() % 2 == 0
                ctx.setStrokeColor(UIColor(white: dark ? 0 : 1, alpha: 0.05).cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x + CGFloat(Int(rng.next() % 5)) - 2, y: px))
                ctx.strokePath()
            }
        }
        albedoCache = img
        return img
    }

    /// A tangent-space normal map: flat blue base with vertical strand ridges
    /// that tilt the surface normals left/right, reading as fine fur.
    static func normal() -> UIImage {
        if let cached = normalCache { return cached }
        let img = renderer(opaque: true).image { rctx in
            let ctx = rctx.cgContext
            // Flat normal pointing straight out (+Z) → RGB (0.5, 0.5, 1.0).
            ctx.setFillColor(UIColor(red: 0.5, green: 0.5, blue: 1.0, alpha: 1).cgColor)
            ctx.fill(fullRect)

            var rng = SeededGenerator(seed: 0x0FA5_2E1)
            // Each strand is a thin vertical line whose red channel deviates from
            // 0.5, tilting the normal sideways so light catches the ridges.
            for _ in 0..<600 {
                let x = CGFloat(rng.next() % UInt64(px))
                let tiltLeft = rng.next() % 2 == 0
                let strength = 0.12 + CGFloat(rng.next() % 100) / 100.0 * 0.22
                let red = tiltLeft ? 0.5 - strength : 0.5 + strength
                let green = 0.5 + (CGFloat(rng.next() % 100) / 100.0 - 0.5) * 0.10
                ctx.setStrokeColor(UIColor(red: red, green: green, blue: 1.0, alpha: 0.5).cgColor)
                ctx.setLineWidth(CGFloat(1 + rng.next() % 2))
                let jitter = CGFloat(Int(rng.next() % 7)) - 3
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x + jitter, y: px))
                ctx.strokePath()
            }
        }
        normalCache = img
        return img
    }

    // MARK: - Drawing scaffolding

    private static func renderer(opaque: Bool) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1                 // fixed pixel size, independent of screen
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: CGSize(width: px, height: px), format: format)
    }

    private static var fullRect: CGRect { CGRect(x: 0, y: 0, width: px, height: px) }
}
