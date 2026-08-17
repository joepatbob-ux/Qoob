//
//  ModelFit.swift
//  Qoob
//
//  How a bundled 3D model is sized and turned to fit the piece of furniture it
//  represents. Pure arithmetic — no RealityKit, no entities — so it can be tested
//  against a model's measured extents without a renderer or a device.
//
//  This lives in Core rather than in the renderer because it is the single most
//  bug-prone rule in the project. Every one of these was a real fault:
//
//   - a dining chair sized to one level came out 0.62 of a cell wide, doll's
//     furniture beside a full-cell cat (the kitchen uses a backless stool instead,
//     because with no backrest total height *is* seat height)
//   - a planter filling 33% of its footprint
//   - the overhang clamp silently shaving a piece's height, so `surface` no longer
//     matched `kind.levels` and perched toys floated
//   - facing being discarded for 18% of pieces by a parity test that protected
//     nothing
//
//  None of those were visible from reading the renderer, and all of them are
//  visible from a handful of numbers.
//

import Foundation

/// The result of fitting a model to a footprint: how much to scale it, how far to
/// turn it, and how high the top ends up.
struct ModelFit: Equatable {
    /// Uniform scale to apply to the model.
    let scale: Float

    /// Height of the model's top after scaling, in world units.
    ///
    /// Taken from the scale actually used rather than from the kind's declared
    /// height, because the overhang clamp can shave a piece down — and a perched toy
    /// has to sit on the surface that got *drawn*, not the one that was intended.
    /// When these disagree the piece is the wrong height, which matters more than it
    /// sounds: height is what Qoob climbs.
    let surface: Float

    /// Quarter turns anticlockwise about Y.
    let quarterTurns: Int

    /// Whether the turn swaps the model's X and Z extents.
    var swapsAxes: Bool { quarterTurns % 2 == 1 }
}

extension RollDirection {
    /// Unit vector on the board: +X right, +Z back.
    var boardVector: SIMD3<Float> {
        switch self {
        case .right:   return SIMD3(1, 0, 0)
        case .left:    return SIMD3(-1, 0, 0)
        case .back:    return SIMD3(0, 0, 1)
        case .forward: return SIMD3(0, 0, -1)
        }
    }
}

extension ModelFit {
    /// Fits a model of the given extents to a `cols` × `rows` footprint at
    /// `targetHeight`.
    ///
    /// Sized by **height**, not fitted to the footprint. Fitting to cells was the
    /// original mistake: it made every piece as small as the grid squares it happened
    /// to occupy, so a fridge came out shorter than the cat beside it. Sizing by height
    /// against a known scale is the only way a room reads at the right proportions.
    ///
    /// Then clamped so a piece can't sprawl more than `overhang` past the cells it
    /// blocks. A little overhang looks natural — furniture doesn't sit on a grid — but
    /// past that it hides floor the cat can actually stand on: a bed scaled purely by
    /// height covers 3×4 cells, so blocking 2×3 left it draped over Qoob.
    ///
    /// - Parameters:
    ///   - extents: the model's bounding-box size, unscaled.
    ///   - modelBack: which way the model's back points, if it could be determined.
    ///     Supplied by the renderer, which needs mesh mass to work it out.
    /// - Returns: `nil` for a degenerate model (any extent zero), which is the caller's
    ///   signal to fall back to a placeholder.
    static func fit(extents: SIMD3<Float>,
                    cols: Int, rows: Int,
                    targetHeight: Float,
                    hasFacing: Bool,
                    facing: RollDirection?,
                    modelBack: SIMD3<Float>?,
                    cubeSize: Float,
                    overhang: Float) -> ModelFit? {
        let mw = extents.x, mh = extents.y, md = extents.z
        guard mw > 0, mh > 0, md > 0 else { return nil }

        // Footprints are randomly oriented (a sofa is 4×2 or 2×4) and a model pack has
        // no consistent long axis — one sofa runs along X, a bed along Z. Turning the
        // model a quarter so its own long side lies along the footprint's is the
        // fallback, without which a 4-cell sofa sits across its slot.
        let modelLongOnX = mw >= md
        let footprintLongOnX = cols >= rows
        let longSwap = modelLongOnX != footprintLongOnX

        let allowW = Float(cols) * cubeSize * overhang
        let allowD = Float(rows) * cubeSize * overhang
        let byHeight = targetHeight / mh

        /// The scale a given orientation would end up at, after the overhang clamp.
        func scale(swapped: Bool) -> Float {
            let footW = swapped ? md : mw
            let footD = swapped ? mw : md
            return min(byHeight, min(allowW / footW, allowD / footD))
        }

        var turns = longSwap ? 1 : 0

        // Where the piece has a front and the model shows which way that is, point the
        // front along `facing` instead. This subsumes the long-axis fix, since a sofa's
        // length runs across its front.
        if hasFacing, let facing, let modelBack {
            let front = -modelBack
            let target = facing.boardVector
            // Angles as atan2(x, z); a rotation about +Y adds to the angle.
            let delta = atan2(target.x, target.z) - atan2(front.x, front.z)
            var q = Int((delta / (.pi / 2)).rounded()) % 4
            if q < 0 { q += 4 }
            // Honour it unless turning that way would make the overhang clamp bite: a
            // piece drawn at the wrong height is a worse fault than one facing the wrong
            // way.
            //
            // Comparing the resulting *scale* rather than the axis parity matters.
            // Refusing on parity alone threw the facing away for 18% of pieces, nearly
            // all of them square — a 1×1 nightstand or a 3×3 armchair loses nothing by
            // having its axes swapped, so there was never anything to protect.
            if scale(swapped: q % 2 == 1) >= scale(swapped: longSwap) - 0.0001 { turns = q }
        }

        let s = scale(swapped: turns % 2 == 1)
        return ModelFit(scale: s, surface: mh * s, quarterTurns: turns)
    }
}
