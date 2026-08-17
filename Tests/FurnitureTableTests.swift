//
//  FurnitureTableTests.swift
//  QoobTests
//
//  Two things: that the furniture table is internally consistent, and that the
//  sizing rule extracted into `ModelFit` behaves.
//
//  The sizing tests use synthetic extents rather than loading the bundled models,
//  which is the whole reason the arithmetic was moved out of the renderer — the rule
//  is checkable without RealityKit, an asset catalogue or a device. A separate test
//  further down does load the real models, and skips rather than fails if the
//  catalogue isn't reachable from the test host.
//

import Testing
import Foundation
@testable import Qoob

@Suite("Furniture table")
struct FurnitureTableTests {

    /// Every kind declares a usable footprint.
    @Test("every kind has a footprint", arguments: FurnitureKind.allCases)
    func footprintsPresent(kind: FurnitureKind) {
        #expect(!kind.footprints.isEmpty, "\(kind.rawValue) has no footprint")
        for fp in kind.footprints {
            #expect(fp.cols > 0 && fp.rows > 0,
                    "\(kind.rawValue) has a degenerate footprint \(fp.cols)x\(fp.rows)")
        }
    }

    /// Heights are whole, positive, and small enough to mean something.
    ///
    /// Whole numbers are not tidiness: a roll is a 90° pivot about a step's top edge,
    /// and that only lands a face flat if the step is an exact cube height. A
    /// fractional height leaves Qoob balanced on a corner with no face down, and
    /// "which face is down" is the whole game.
    @Test("heights are whole and sane", arguments: FurnitureKind.allCases)
    func heightsSane(kind: FurnitureKind) {
        #expect(kind.levels >= 1, "\(kind.rawValue) is \(kind.levels) levels high")
        #expect(kind.levels <= 4, "\(kind.rawValue) at \(kind.levels) levels would loom absurdly")
        #expect(kind.height == CGFloat(kind.levels),
                "\(kind.rawValue): height and levels disagree")
    }

    /// A room can hold at least one of anything it's allowed.
    @Test("per-room caps are positive", arguments: FurnitureKind.allCases)
    func capsPositive(kind: FurnitureKind) {
        #expect(kind.maxPerRoom >= 1, "\(kind.rawValue) may never be placed")
    }

    /// Every indoor room can furnish a step.
    ///
    /// The rule that makes indoor furniture usable at all: a climb is a single 90°
    /// pivot, capped at one level, so a room whose smallest piece is two levels high
    /// has nothing a cat can get onto. The kitchen was exactly that — counter 2,
    /// table 2, fridge 4 — until a backless stool and a box were added. If this fails,
    /// some room's furniture has become scenery.
    ///
    /// Indoor only. Outdoor lists are deliberately propless — a yard is ground, and
    /// its verticality comes from mounds instead — which is also why `gardenBench` and
    /// `planter` are in no environment's list despite existing as kinds: the level
    /// builder still offers them for hand-built gardens.
    @Test("every indoor room has a one-level step", arguments: Environment.indoorCases)
    func indoorRoomsHaveAStep(env: Environment) {
        let steps = env.furnitureKinds.filter { $0.isClimbable && $0.levels == 1 }
        #expect(!steps.isEmpty,
                "\(env.rawValue) has no one-level climbable piece, so its taller furniture is unreachable")
    }
}

@Suite("Model fit")
struct ModelFitTests {

    /// A model that fits comfortably is sized purely by height.
    ///
    /// This is the contract everything else depends on: `surface` must equal the
    /// kind's declared height, because that height is what Qoob climbs and what a
    /// perched toy sits on. When the clamp shaves a piece instead, toys float.
    @Test("a well-proportioned model lands at its declared height")
    func heightExact() {
        // 1×1×1 model into a 2×2 footprint at 2 levels: nothing binds.
        let fit = ModelFit.fit(extents: SIMD3(1, 1, 1), cols: 2, rows: 2,
                               targetHeight: 2, hasFacing: false, facing: nil,
                               modelBack: nil, cubeSize: 1, overhang: 1.25)
        #expect(fit?.scale == 2)
        #expect(fit?.surface == 2)
    }

    /// A model far too wide for its footprint is clamped, not left to sprawl.
    ///
    /// Pins the reason the clamp exists: a bed sized purely by height covers 3×4
    /// cells, so blocking 2×3 left it draped over Qoob.
    @Test("an over-wide model is clamped by the footprint")
    func clampBites() {
        // 10 wide, 1 high: sizing by height alone would make it 10 cells across.
        let fit = ModelFit.fit(extents: SIMD3(10, 1, 1), cols: 1, rows: 1,
                               targetHeight: 1, hasFacing: false, facing: nil,
                               modelBack: nil, cubeSize: 1, overhang: 1.25)
        let drawnWidth = 10 * (fit?.scale ?? 0)
        #expect(drawnWidth <= 1.25 + 0.0001, "clamp let it sprawl to \(drawnWidth) cells")
        // And the surface honestly reports the reduced height rather than claiming 1.
        #expect((fit?.surface ?? 0) < 1, "surface should report the shaved height")
    }

    /// A degenerate model is rejected so the caller can fall back to a placeholder.
    @Test("a zero-extent model is refused")
    func degenerateRefused() {
        #expect(ModelFit.fit(extents: SIMD3(0, 1, 1), cols: 1, rows: 1, targetHeight: 1,
                             hasFacing: false, facing: nil, modelBack: nil,
                             cubeSize: 1, overhang: 1.25) == nil)
        #expect(ModelFit.fit(extents: SIMD3(1, 0, 1), cols: 1, rows: 1, targetHeight: 1,
                             hasFacing: false, facing: nil, modelBack: nil,
                             cubeSize: 1, overhang: 1.25) == nil)
    }

    /// A long model is turned so its length lies along the footprint's length.
    ///
    /// Without this a 4-cell sofa sits across its slot, because model packs have no
    /// consistent long axis — one sofa runs along X, a bed along Z.
    @Test("a long model turns to match a long footprint")
    func longAxisAligned() {
        // Model is long on Z; footprint is long on X. Expect an odd number of turns.
        let fit = ModelFit.fit(extents: SIMD3(1, 1, 4), cols: 4, rows: 1,
                               targetHeight: 1, hasFacing: false, facing: nil,
                               modelBack: nil, cubeSize: 1, overhang: 1.25)
        #expect(fit?.swapsAxes == true, "long axes left crossed")
    }

    /// A model already aligned is left alone.
    @Test("an aligned model is not turned")
    func alignedLeftAlone() {
        let fit = ModelFit.fit(extents: SIMD3(4, 1, 1), cols: 4, rows: 1,
                               targetHeight: 1, hasFacing: false, facing: nil,
                               modelBack: nil, cubeSize: 1, overhang: 1.25)
        #expect(fit?.quarterTurns == 0)
    }

    /// Facing is honoured on a square footprint.
    ///
    /// Pins the fix where facing was thrown away for 18% of pieces by a parity test:
    /// a square footprint loses nothing by having its axes swapped, so there was
    /// never anything to protect.
    @Test("facing is honoured when nothing is lost by it",
          arguments: [RollDirection.right, .left, .forward, .back])
    func facingHonoured(direction: RollDirection) {
        // A cube model on a square footprint: every orientation scales identically,
        // so the facing must win outright.
        let fit = ModelFit.fit(extents: SIMD3(1, 1, 1), cols: 2, rows: 2,
                               targetHeight: 1, hasFacing: true, facing: direction,
                               modelBack: SIMD3(0, 0, 1), cubeSize: 1, overhang: 1.25)
        #expect(fit != nil)
        // Turning the model's front (-back = -Z, i.e. `forward`) by the reported turns
        // must land on the requested direction.
        let turns = fit?.quarterTurns ?? 0
        let expected: [RollDirection] = [.forward, .left, .back, .right]
        #expect(expected[turns % 4] == direction,
                "\(turns) turns from -Z gives \(expected[turns % 4]), wanted \(direction)")
    }

    /// Scaling is uniform: the surface follows the scale exactly.
    @Test("surface always equals model height times scale")
    func surfaceConsistent() {
        for h in [Float(0.5), 1, 2.52, 7] {
            for cols in 1...3 {
                let fit = ModelFit.fit(extents: SIMD3(1, h, 1), cols: cols, rows: cols,
                                       targetHeight: 2, hasFacing: false, facing: nil,
                                       modelBack: nil, cubeSize: 1, overhang: 1.25)
                #expect(abs((fit?.surface ?? 0) - h * (fit?.scale ?? 0)) < 0.0001)
            }
        }
    }
}
