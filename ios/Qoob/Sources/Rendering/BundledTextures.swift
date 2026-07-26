//
//  BundledTextures.swift
//  Qoob
//
//  Optional material textures loaded from the asset catalog. Every getter
//  returns nil when the asset is absent, so the renderer can fall back to its
//  procedural look. Drop PNGs with these names into Assets.xcassets to light
//  them up — no code change needed.
//
//  Expected image names:
//    fur_albedo, fur_normal        — cat body (tinted per face by accent colour)
//    carpet_albedo, carpet_normal  — floor
//    cat_face, cat_butt, cat_paws, cat_dot, cat_ring, cat_triangle
//                                  — optional hand-made face art (else glyphs)
//

import UIKit

enum BundledTextures {

    static func image(_ name: String) -> UIImage? { UIImage(named: name) }

    static var fur: UIImage?         { image("fur_albedo") }
    static var furNormal: UIImage?   { image("fur_normal") }
    static var carpet: UIImage?      { image("carpet_albedo") }
    static var carpetNormal: UIImage? { image("carpet_normal") }

    /// Hand-made art for a face's symbol, if provided.
    static func faceArt(_ index: Int) -> UIImage? {
        image(CatSymbol.from(index).assetName)
    }
}
