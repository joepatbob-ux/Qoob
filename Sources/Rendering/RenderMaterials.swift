//
//  RenderMaterials.swift
//  Qoob
//
//  Material builders. Free functions rather than renderer methods because none of
//  them touch renderer state — they map arguments to a material and nothing else,
//  which is also what makes them the only part of the renderer worth pulling out
//  without weakening its encapsulation.
//
//  Deliberately NOT part of a wider "split the renderer into extensions" exercise.
//  RealityKitRenderer has 65 private stored properties and 92 private methods, and an
//  extension in another file cannot see `private` members — so splitting it by MARK
//  section would mean promoting most of that state to module-wide visibility. That
//  trades a long file for no encapsulation, which is the worse of the two problems.
//

import RealityKit
import UIKit
import Metal

/// A self-lit unlit material carrying an alpha-blended glyph/art texture.
func unlitMaterial(_ image: UIImage?) -> UnlitMaterial {
    var m = UnlitMaterial()
    if let tex = loadTexture(image, semantic: .color) {
        m.color = .init(tint: .white, texture: .init(tex))
    } else {
        m.color = .init(tint: .white)
    }
    m.blending = .transparent(opacity: 1.0)
    return m
}

/// Solid or textured PBR helper.
///
/// Emission and the UV transform are always assigned, even to their neutral
/// values — see `resetUnusedSlots`.
func pbr(_ color: UIColor, roughness: Float = 0.85, metallic: Float = 0,
                 emissive: UIColor? = nil) -> PhysicallyBasedMaterial {
    var m = PhysicallyBasedMaterial()
    m.baseColor = .init(tint: color)
    m.roughness = .init(floatLiteral: roughness)
    m.metallic = .init(floatLiteral: metallic)
    if let e = emissive {
        m.emissiveColor = .init(color: e)
        m.emissiveIntensity = 1.0
    } else {
        resetEmission(&m)
    }
    resetTextureTransform(&m)
    return m
}

// MARK: Material slot hygiene
//
// Replacing the materials on an existing `ModelComponent` does *not* clear the
// slots the new material leaves untouched — whatever the previous material set
// stays in effect on the GPU. That produced two visible bugs on tiles, which
// wear the floor material and a target material alternately:
//
//  • A newly-spawned target rendered as a magnified corner of its own art,
//    because the floor's per-cell UV transform (scale 0.5, offset by grid
//    position) was still applied to it. Reading the material back in Swift
//    showed an identity transform, which is what made this confusing: the
//    struct was clean, the render wasn't.
//  • A cleared target left a pale glowing square behind, because the target
//    material's emission was never switched off.
//
// So every material that *doesn't* want these slots states so explicitly.

func resetEmission(_ m: inout PhysicallyBasedMaterial) {
    m.emissiveColor = .init(color: .black)
    m.emissiveIntensity = 0
}

func resetTextureTransform(_ m: inout PhysicallyBasedMaterial) {
    m.textureCoordinateTransform = .init(offset: .zero, scale: .one)
}

/// A repeat-wrapped texture parameter (so UV offsets tile continuously).
func repeatTexture(_ resource: TextureResource) -> MaterialParameters.Texture {
    let desc = MTLSamplerDescriptor()
    desc.sAddressMode = .repeat
    desc.tAddressMode = .repeat
    desc.magFilter = .linear
    desc.minFilter = .linear
    desc.mipFilter = .linear
    return .init(resource, sampler: .init(desc))
}
