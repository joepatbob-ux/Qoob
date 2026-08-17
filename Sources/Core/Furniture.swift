//
//  Furniture.swift
//  Qoob
//
//  Living-room obstacles the cat rolls around. Each piece occupies an
//  axis-aligned block of cells that the cube cannot enter. Pure model — the
//  renderer draws a placeholder (or a bundled model) from this description.
//

import UIKit

enum FurnitureKind: String, CaseIterable, Codable {
    // Living room
    case sofa, coffeeTable, armchair
    // Kitchen
    case counter, diningTable, fridge, oven, diningChair
    // Bedroom
    case bed, dresser, nightstand
    // Anywhere indoors
    case box, lamp
    // Yard
    case gardenBench, bush, planter, tree

    /// Placeholder colour (used when no 3D model is supplied).
    var color: UIColor {
        switch self {
        case .sofa:        return UIColor(red: 0.36, green: 0.45, blue: 0.52, alpha: 1) // slate
        case .coffeeTable: return UIColor(red: 0.52, green: 0.38, blue: 0.26, alpha: 1) // walnut
        case .armchair:    return UIColor(red: 0.70, green: 0.52, blue: 0.32, alpha: 1) // mustard
        case .counter:     return UIColor(red: 0.80, green: 0.78, blue: 0.72, alpha: 1) // laminate
        case .diningTable: return UIColor(red: 0.55, green: 0.40, blue: 0.28, alpha: 1) // oak
        case .fridge:      return UIColor(red: 0.86, green: 0.88, blue: 0.90, alpha: 1) // steel
        case .oven:        return UIColor(red: 0.42, green: 0.44, blue: 0.47, alpha: 1) // enamel
        case .diningChair: return UIColor(red: 0.62, green: 0.46, blue: 0.30, alpha: 1) // beech
        case .bed:         return UIColor(red: 0.40, green: 0.48, blue: 0.66, alpha: 1) // duvet blue
        case .dresser:     return UIColor(red: 0.48, green: 0.35, blue: 0.26, alpha: 1) // wood
        case .nightstand:  return UIColor(red: 0.52, green: 0.40, blue: 0.30, alpha: 1) // wood
        case .box:         return UIColor(red: 0.76, green: 0.58, blue: 0.36, alpha: 1) // cardboard
        case .lamp:        return UIColor(red: 0.96, green: 0.90, blue: 0.74, alpha: 1) // lit shade
        case .gardenBench: return UIColor(red: 0.46, green: 0.50, blue: 0.44, alpha: 1) // weathered
        case .bush:        return UIColor(red: 0.28, green: 0.50, blue: 0.28, alpha: 1) // foliage
        case .planter:     return UIColor(red: 0.68, green: 0.42, blue: 0.32, alpha: 1) // terracotta
        case .tree:        return UIColor(red: 0.34, green: 0.46, blue: 0.26, alpha: 1) // canopy
        }
    }

    /// Height in whole cube units — one unit is Qoob, one cell, about a 50cm cube.
    ///
    /// Whole numbers, and not for tidiness: the roll demands it. Qoob climbs by
    /// pivoting 90° about a step's top edge, and a 90° pivot only lands a face flat
    /// if the step is an exact cube height. Land on a 1.7-high sofa and Qoob finishes
    /// tilted on a corner with no face down — and "which face is down" is the whole
    /// game. At 50cm a unit these are still about right, a touch chunky, which suits
    /// a world built out of cubes. Bracketed is the height being modelled.
    var levels: Int {
        switch self {
        case .coffeeTable: return 1   // 50cm
        case .bed:         return 1   // 50cm to the top of the mattress
        case .nightstand:  return 1   // 50cm
        case .planter:     return 1   // 50cm
        // The kitchen's only step. Before this every kitchen piece was two levels or
        // more — counter 2, table 2, fridge 4 — and a climb is a single 90° pivot, so
        // there was literally nothing in a kitchen a cat could get onto.
        //
        // A stool rather than a dining chair, and for a measurable reason. The renderer
        // scales a model so its *total* height matches this figure, and `chair_A` is
        // 0.75 wide by 1.21 tall — that 1.21 being the top of the backrest. Matching it
        // to one level scaled the chair to 0.83, which came out 0.62 of a cell wide with
        // its seat at half a level: a doll's chair beside a full-cell cat, sat on at
        // backrest height. A stool has no back, so its height *is* its seat height, and
        // one level of it is 1.5 cells across — which reads correctly next to Qoob.
        case .diningChair: return 1   // 50cm to the seat, and the seat is the top
        // The same argument as the stool, generalised. Every room needs something one
        // level high or its two-level furniture can't be got onto at all, and a box is
        // the least contrived thing to leave lying about a house — and the most feline.
        case .box:         return 1   // 50cm, a box a cat would sit in
        case .sofa:        return 2   // 100cm over the back
        case .armchair:    return 2   // 100cm over the back
        case .counter:     return 2   // 100cm — worktop plus splashback
        case .diningTable: return 2   // 100cm
        case .dresser:     return 2   // 100cm
        case .gardenBench: return 2   // 100cm
        case .bush:        return 2   // 100cm
        case .oven:        return 2   // 100cm over the hob
        case .fridge:      return 4   // 200cm, and it should loom
        // 150cm to the top of the shade, which is where a standard lamp's light comes
        // from. Three levels also means it can't be climbed, which is correct: a cat
        // knocks a lamp over, it doesn't perch on one.
        case .lamp:        return 3   // 150cm
        case .tree:        return 4   // 200cm to the canopy — nothing a cat hops onto
        }
    }

    /// Height in world units.
    var height: CGFloat { CGFloat(levels) }

    /// Whether Qoob can get up onto this.
    ///
    /// A cat gets on anything with a flat top. Foliage has no surface to stand on, so
    /// bushes, planters and trees stay solid — walls with leaves.
    ///
    /// The shrubs come from Quaternius and the tree from KayKit, which is deliberate:
    /// KayKit's nature bushes are 24-face scatter props meant to be knee-high, and
    /// enlarged to a 1m shrub they render as bevelled green boxes. Its trees are the
    /// detailed pieces in that pack and hold up at full size.
    var isClimbable: Bool {
        switch self {
        // Nothing with a standable top. A tree has one in principle, but at four levels
        // it's out of reach anyway, and a cube cat balanced in a canopy would look wrong.
        case .bush, .planter, .tree, .lamp: return false
        default: return true
        }
    }

    /// Whether this belongs against a wall.
    ///
    /// Most big furniture does — a sofa floating in open floor is the single loudest
    /// signal that a room was scattered rather than arranged. The exceptions are the
    /// things that genuinely live in the middle: tables, and a chair pulled up to one.
    var prefersWall: Bool {
        switch self {
        // Trees grow where they grow — a row of them against the fence would read as
        // planted decking, not a garden.
        // A dining chair belongs at a table, not shoved against the skirting.
        // A box gets left wherever it was put down, which is the point of it.
        case .coffeeTable, .diningTable, .armchair, .diningChair, .box, .tree: return false
        default: return true
        }
    }

    /// How many of this kind a single room may have.
    ///
    /// Kinds used to be drawn uniformly *with replacement* from three per environment,
    /// which produced rooms with five coffee tables and kitchens with four fridges. A
    /// home has one fridge.
    var maxPerRoom: Int {
        switch self {
        // One cooker, same as one fridge.
        case .fridge, .bed, .diningTable, .oven: return 1
        // Two: a pair of lamps either side of a sofa or a bed is how rooms are lit.
        case .lamp: return 2
        case .sofa, .coffeeTable, .dresser, .nightstand, .gardenBench: return 2
        case .counter: return 3
        case .armchair, .planter, .diningChair: return 4
        // Three, but note the quota came down to suit it. A box is only 1×1, so it fits
        // almost anywhere — which means it can fill a quota that the big pieces used to
        // run out of attempts before reaching. Left alone that quietly pushed a bedroom
        // from 4.9 pieces to 7.4, so `furnishingQuota` was corrected to match; the cap
        // stays at three because a kitchen needs the odds of getting *a* step.
        case .box: return 3
        case .bush: return 6
        case .tree: return 3
        }
    }

    /// A piece that belongs with this one, and how far in front of it to sit.
    ///
    /// This is what actually makes a room read as designed rather than as legal: a
    /// coffee table in front of the sofa, a nightstand beside the bed. Placed relative
    /// to its anchor, in the space the anchor faces.
    var companion: (kind: FurnitureKind, gap: Int)? {
        switch self {
        case .sofa:        return (.coffeeTable, 1)
        case .bed:         return (.nightstand, 0)
        // A chair, not an armchair: `diningTable` only ever appears in a kitchen, and
        // `armchair` is living-room furniture, so this pairing never fired.
        case .diningTable: return (.diningChair, 0)
        default:           return nil
        }
    }

    /// Whether this piece has a front that ought to point somewhere sensible.
    ///
    /// Seating and beds obviously do — a sofa with its back to the room is the clearest
    /// sign nobody arranged it — but so does casework: a dresser's drawers or a fridge's
    /// door have to be reachable, which means facing out of the wall rather than into it.
    ///
    /// The rest genuinely have no front. A round table, a backless stool, a shrub and a
    /// tree look the same from every side, so pointing them is meaningless — and worth
    /// saying so explicitly, because the alternative is spending rotation on pieces where
    /// it can only ever fight the footprint.
    var hasFacing: Bool {
        switch self {
        case .sofa, .armchair, .gardenBench, .bed,
             .dresser, .counter, .fridge, .nightstand, .oven: return true
        case .coffeeTable, .diningTable, .diningChair, .box, .lamp,
             .bush, .planter, .tree: return false
        }
    }

    /// Whether this kind should render a back cushion (sofas/chairs/benches).
    var hasBack: Bool {
        switch self {
        case .sofa, .armchair, .gardenBench, .bed: return true
        default: return false
        }
    }

    /// Optional bundled model name (e.g. "sofa.usdz"); loaded if present.
    var modelBaseName: String { rawValue }

    /// Human-readable name, for the level builder's palette.
    var displayName: String {
        switch self {
        case .sofa:        return "Sofa"
        case .coffeeTable: return "Coffee table"
        case .armchair:    return "Armchair"
        case .counter:     return "Counter"
        case .diningTable: return "Dining table"
        case .fridge:      return "Fridge"
        case .oven:        return "Oven"
        case .diningChair: return "Stool"
        case .bed:         return "Bed"
        case .dresser:     return "Dresser"
        case .nightstand:  return "Nightstand"
        case .box:         return "Box"
        case .lamp:        return "Lamp"
        case .gardenBench: return "Bench"
        case .bush:        return "Bush"
        case .planter:     return "Planter"
        case .tree:        return "Tree"
        }
    }

    /// Possible footprints (cols × rows). Orientation is chosen at random.
    ///
    /// These are the cells the model actually covers once it's scaled to `height`,
    /// not a rough guess. They have to match: the renderer sizes a piece by height
    /// against Qoob, so if the footprint were smaller than the result the model would
    /// sprawl across neighbouring cells and hide floor the cat can stand on — the cat
    /// included. A bed is 3×3 because KayKit's `bed_double_A` at one level *is* 3×3
    /// cells — several of that pack's pieces are authored on a 1-unit grid, so they land
    /// at scale 1.00 and their footprint is simply their own size.
    var footprints: [(cols: Int, rows: Int)] {
        switch self {
        case .sofa:        return [(5, 3), (3, 5)]
        case .coffeeTable: return [(2, 2)]
        case .armchair:    return [(3, 3)]
        case .counter:     return [(5, 2), (2, 5)]
        case .diningTable: return [(3, 3)]
        case .fridge:      return [(2, 2)]
        // `oven` lands at native scale (0.99×) — KayKit's restaurant pieces share the
        // 1-unit grid — so its footprint is simply the model's own size. The stool is
        // scaled 2× to bring its seat up to one level, which puts it at 1.5 cells.
        case .oven:        return [(2, 2)]
        case .diningChair: return [(2, 2)]
        case .bed:         return [(3, 3)]
        case .dresser:     return [(4, 2), (2, 4)]
        case .nightstand:  return [(1, 1)]
        // A 1.0 cube at one level lands at scale 1.00 — exactly one cell, nothing to
        // reconcile. The two bigger variants are 1.5 cubes and come to the same thing.
        case .box:         return [(1, 1)]
        // 1.19× at three levels, so it fills its cell and overhangs a little.
        case .lamp:        return [(1, 1)]
        case .gardenBench: return [(3, 2), (2, 3)]
        case .bush:        return [(2, 2)]
        case .planter:     return [(1, 1)]
        case .tree:        return [(3, 3)]
        }
    }
}

struct Furniture {
    let kind: FurnitureKind
    let origin: GridCell   // min-corner cell
    let cols: Int
    let rows: Int
    /// Which way the piece's front points, in board directions. Nil for a piece with no
    /// meaningful front, or one nobody decided about.
    ///
    /// The generator already worked this out — `wallBacking` returns the direction a
    /// wall-backed piece faces — and then threw it away, using it only to decide where to
    /// put the companion. So the renderer never knew, and could only ever turn a model by
    /// a quarter to line its long side up with the footprint: the *sign* was never chosen.
    /// Every 5×3 sofa in the game therefore faced the same absolute direction whichever
    /// wall it was against, which is half of them with their back to the room.
    let facing: RollDirection?

    init(kind: FurnitureKind, origin: GridCell, cols: Int, rows: Int,
         facing: RollDirection? = nil) {
        self.kind = kind
        self.origin = origin
        self.cols = cols
        self.rows = rows
        self.facing = facing
    }

    /// The same piece pointed a different way.
    func facing(_ direction: RollDirection?) -> Furniture {
        Furniture(kind: kind, origin: origin, cols: cols, rows: rows, facing: direction)
    }

    var cells: [GridCell] {
        var out: [GridCell] = []
        for r in 0..<rows {
            for c in 0..<cols {
                out.append(GridCell(col: origin.col + c, row: origin.row + r))
            }
        }
        return out
    }

    /// Footprint centre in grid coordinates (may be a half-cell).
    var centerCol: Double { Double(origin.col) + Double(cols - 1) / 2.0 }
    var centerRow: Double { Double(origin.row) + Double(rows - 1) / 2.0 }
}
