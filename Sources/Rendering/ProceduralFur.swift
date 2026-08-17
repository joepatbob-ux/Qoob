//
//  ProceduralFur.swift
//  Qoob
//
//  A code-generated, tileable coat texture so Qoob needs no art assets: a
//  near-white base flecked with fine speckle and faint strands, kept neutral so
//  the material's baseColor tint decides the actual coat colour.
//
//  There was a matching strand normal map here. It's gone: its randomised strand
//  tilts scattered light away from the camera hard enough to render a near-white
//  coat as mid-grey, and the plush Qoob now follows is smooth fabric with no
//  visible strands at all. See `RealityKitRenderer.furMaterial`.
//
//  The renderer prefers a bundled `fur_albedo` asset if present (see
//  BundledTextures) and falls back to this.
//

import UIKit

enum ProceduralFur {

    private static var albedoCache: UIImage?
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

    // MARK: - Drawing scaffolding

    private static func renderer(opaque: Bool) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1                 // fixed pixel size, independent of screen
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: CGSize(width: px, height: px), format: format)
    }

    private static var fullRect: CGRect { CGRect(x: 0, y: 0, width: px, height: px) }
}
