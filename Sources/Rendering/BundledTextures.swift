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
//    fur_albedo                    — Qoob's coat
//    carpet_albedo, carpet_normal  — floor
//
//  There is no per-symbol face art any more: Qoob's sides are sculpted as the
//  body parts their symbols depict rather than carrying flat glyph decals, so
//  the old `cat_face` / `cat_butt` / … overrides had nothing left to override.
//

import UIKit

enum BundledTextures {

    static func image(_ name: String) -> UIImage? { UIImage(named: name) }

    static var fur: UIImage?         { image("fur_albedo") }
    static var carpet: UIImage?      { image("carpet_albedo") }
    static var carpetNormal: UIImage? { image("carpet_normal") }
}
