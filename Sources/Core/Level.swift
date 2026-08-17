//
//  Level.swift
//  Qoob
//
//  A room: a rectilinear outline of floor cells, a cube start cell, target tiles,
//  furniture and toys. Bigger than the window on both axes, so the camera follows
//  Qoob around it rather than framing the whole thing.
//
//  There are no levels. There never really were — `levelIndex` was set to 0 and
//  never incremented, so every "difficulty by level" term silently evaluated to its
//  index-0 value and the toy and knock-off mechanics were switched off entirely
//  (`min(index / 3, 3)` == 0). Everything is now scaled to the room's own floor
//  area, which is the thing that actually determines how much a room can hold.
//

import Foundation

struct Target {
    let col: Int
    let row: Int
    let colorIndex: Int
}

/// A toy perched on a furniture cell; rolling the cat into that furniture
/// knocks it onto `landing` (a free floor cell) for bonus points.
struct PerchedToy {
    let perch: GridCell     // the furniture cell it sits on
    let landing: GridCell   // where it falls to
}

/// A rug laid on the floor. Decoration only: it doesn't block, raise or score, and the
/// board model never sees it.
struct Rug {
    let origin: GridCell      // min corner
    let cols: Int
    let rows: Int
    /// Which of the bundled rug models to draw.
    let variant: Int

    var cells: [GridCell] {
        (0..<rows).flatMap { r in (0..<cols).map { GridCell(col: origin.col + $0, row: origin.row + r) } }
    }
    var centerCol: Double { Double(origin.col) + Double(cols - 1) / 2.0 }
    var centerRow: Double { Double(origin.row) + Double(rows - 1) / 2.0 }
}

/// A raised patch of outdoor ground: one step of a mound.
///
/// Whole cube heights, and that isn't a simplification — it's the same constraint the
/// furniture is under. A climb is a 90° pivot about the step's top edge, which only
/// lands a face flat if the step is exactly one cube. A smoothly sloped hill would
/// leave Qoob balanced on a corner with no face down, and "which face is down" is the
/// whole game. So a hill is a terrace, and a tall hill is terraces stacked inside each
/// other — which also guarantees it can be climbed, since each tier is reachable from
/// the one below.
///
/// Deliberately not `Furniture`: nothing about a mound is a piece of furniture, and
/// giving it a `FurnitureKind` would put it in `blocked` and stop targets landing on
/// it. Getting up a hill to reach a tile is the point.
struct Terrace {
    let origin: GridCell      // min corner
    let cols: Int
    let rows: Int
    /// Standable height, in cube units.
    let level: Int

    var cells: [GridCell] {
        (0..<rows).flatMap { r in (0..<cols).map { GridCell(col: origin.col + $0, row: origin.row + r) } }
    }
    var centerCol: Double { Double(origin.col) + Double(cols - 1) / 2.0 }
    var centerRow: Double { Double(origin.row) + Double(rows - 1) / 2.0 }
}

/// One room of the house: a rectangle of floor with a kind, which decides its ground,
/// its walls and what furniture goes in it.
struct HouseRoom {
    let kind: Environment
    let cols: Range<Int>
    let rows: Range<Int>

    func contains(_ c: GridCell) -> Bool { cols.contains(c.col) && rows.contains(c.row) }
    var cells: [GridCell] { rows.flatMap { r in cols.map { GridCell(col: $0, row: r) } } }
}

struct Level {
    /// The seed this room was generated from. Kept so other systems that need their
    /// own deterministic randomness — target respawns, grass scatter — can derive it
    /// from the room rather than from a level number that no longer exists.
    let seed: UInt64
    /// Bounding box of the room. `floor` is the part of it that's actually room;
    /// for anything but `.rectangle` the box has cells that aren't.
    let width: Int
    let height: Int
    /// Every cell that is floor. The room's outline is the boundary of this set,
    /// which is what the renderer runs walls along and what the board treats as
    /// on-board — so a cut-away corner is as impassable as the world's edge.
    let floor: Set<GridCell>
    /// The rooms of the house, in no particular order.
    let rooms: [HouseRoom]
    /// The cells punched through dividing walls to join rooms. Floor, but not part of
    /// any room's rectangle, so they take their look from whichever room they adjoin.
    let doorways: Set<GridCell>
    let startCol: Int
    let startRow: Int
    let targets: [Target]
    let furniture: [Furniture]
    /// Every furniture cell. Used when placing things — nothing else goes on
    /// furniture — but *not* as the movement rule: most furniture can be climbed.
    let blocked: Set<GridCell>
    /// Furniture with no standable top (a bush, a planter). These are walls.
    let solid: Set<GridCell>
    /// Standable surface level per cell, for cells raised above the floor — the top
    /// of a climbable piece, or of a mound. Floor cells are absent and read as level 0.
    let surface: [GridCell: Int]
    /// Stepped mounds in the outdoor rooms, lowest tier first. Terrain, not furniture:
    /// they're in `surface` so they can be climbed and stood on, but not in `blocked`,
    /// so a target can sit on top of one.
    let hills: [Terrace]
    let items: [GridCell]        // pushable toys' start cells
    /// The one basket the toys are pushed into. Nil only if there was nowhere to put it.
    let basket: GridCell?
    let environment: Environment
    let perched: [PerchedToy]    // toys sitting on furniture to knock off
    /// Roll onto this and the whole house is replaced by a fresh one. Nil only if the
    /// generator couldn't find anywhere for it, which shouldn't happen.
    let litterbox: GridCell?
    /// Rugs: pure decoration. Not furniture — nothing about them blocks, raises or
    /// scores, so they're kept out of `blocked`, `solid` and `surface` entirely and the
    /// board never hears about them. `origin` is the min corner of a 3×2 patch.
    let rugs: [Rug]
    let targetRows: Range<Int>   // rows where targets may appear (not under the HUD)
    let targetCols: Range<Int>   // columns where targets may appear (not bled off screen)

    /// Every target colour is reachable by rolling (the cube carries all six
    /// colours), and every target *cell* is placed only in the region the cube
    /// can actually reach around the furniture — so levels are always solvable.
    static func generate(aspect: Double = 0.46, seed: UInt64) -> Level {
        var rng = SeededGenerator(seed: seed)

        // The camera holds a fixed zoom (`visibleShortCells`) rather than framing the
        // whole room, so a cell is the same size on screen at every level and rooms
        // are free to extend past the window. Every room is bigger than the view on
        // *both* axes — there is always more room off screen — so the camera always
        // has somewhere to follow Qoob to and no room ever sits still.
        let view = viewCells(aspect: aspect)
        let viewShort = min(view.x, view.y), viewLong = max(view.x, view.y)

        // Orientation follows the viewport, but the ratio is capped at 1.5: at a
        // phone's true 1:2.2 a room comes out a corridor.
        //
        // That cap is what sets the minimum size. Clearing the view's short side is
        // easy; clearing its *long* side while staying this square means the short
        // side has to be the long extent divided by the ratio, which is the larger
        // demand and the one that binds. On a phone that's a 14×21 room where the
        // view is 8.6×18.8 — square enough to read as a room, big enough to scroll.
        let rawRatio = aspect >= 1 ? aspect : 1 / aspect
        let ratio = min(max(rawRatio, 1.0), 1.5)
        let minShort = max(viewShort + roomOverscan, (viewLong + roomOverscan) / ratio)

        // That figure is one *room*. The house is a few of them, so the box is scaled
        // up and then partitioned — which keeps each room near a screenful while the
        // house as a whole is emphatically bigger than the window.
        let spread = 1.0 + Double(rng.next() % 40) / 100.0      // 1.00 – 1.39
        let shortCells = Int((minShort * houseScale * spread).rounded(.up))
        let longCells  = Int((Double(shortCells) * ratio).rounded())
        let width  = aspect >= 1 ? longCells : shortCells
        let height = aspect >= 1 ? shortCells : longCells

        // --- Partition the box into rooms, and open doors between them ---
        let house = makeHouse(width: width, height: height, rng: &rng)
        let rooms = house.rooms
        let floor = house.floor
        let cellCount = floor.count

        // Start in the middle of the house, or the nearest floor to it — the centre of
        // the box can land in a dividing wall or in the dropped-off corner.
        let start = nearestFloor(to: GridCell(col: width / 2, row: height / 2), in: floor)
        // The room Qoob begins in decides the opening backdrop and lighting mood; every
        // other room's look is applied per cell.
        let env = rooms.first { $0.contains(start) }?.kind ?? rooms[0].kind

        // Reserve the rows the header and D-pad can overlay, so targets never spawn
        // under the controls. Fall back to the whole board if reserving would leave
        // too little room.
        //
        // Fixed insets rather than a fraction of the room: the camera follows Qoob
        // now, so a target is near the centre of the screen by the time you reach it
        // and the HUD only ever covers the room's outermost rows — the ones where the
        // camera has clamped and the room's edge is at the screen's edge. Scaling
        // this with room size would rule out half of a large room for no reason.
        let topReserved = 2
        let bottomReserved = 3
        var rowLo = topReserved
        var rowHi = height - bottomReserved
        if rowHi - rowLo < 3 { rowLo = 0; rowHi = height }
        let targetRows = rowLo..<rowHi

        // Keep targets off the outermost columns. The camera clamps at the room's
        // edge, so when Qoob is up against a wall they sit off-centre on screen and
        // a target beside them can fall under the HUD — the same reason the rows
        // above are reserved.
        var colLo = 1
        var colHi = width - 1
        if colHi - colLo < 3 { colLo = 0; colHi = width }
        let targetCols = colLo..<colHi

        // The cells a doorway opens onto, either side. Nothing that raises the ground may
        // stand here — not furniture, not terrain — so every threshold is flat on both
        // sides and crossing between rooms never asks for a pose. See `fits`.
        let doorApron: Set<GridCell> = Set(house.doorways.flatMap { door in
            [(1, 0), (-1, 0), (0, 1), (0, -1)].map {
                GridCell(col: door.col + $0.0, row: door.row + $0.1)
            }
        }).subtracting(house.doorways)

        // --- Outdoor relief: stepped mounds ---
        // Built before the furniture, so a bench can't end up half way up a bank. Only
        // outdoors: a terrace in a living room would be a plinth, not a hill.
        var hills: [Terrace] = []
        var hillLevel: [GridCell: Int] = [:]
        for room in rooms where room.kind.isOutdoor {
            let want = 1 + Int(rng.next() % 2)
            var made = 0
            var attempts = 0
            while made < want && attempts < 60 {
                attempts += 1
                // Sized to the room rather than to a fixed range, always leaving three
                // cells of margin so there's ground to walk around it. A fixed 7–11 range
                // read well but simply didn't fit the smaller yards, and mound coverage
                // fell from 89% of them to 62% — a lot of yards left flat.
                let maxW = min(11, room.cols.count - 3)
                let maxD = min(11, room.rows.count - 3)
                guard maxW >= 5, maxD >= 5 else { break }
                let w = 5 + Int(rng.next() % UInt64(maxW - 4))
                let d = 5 + Int(rng.next() % UInt64(maxD - 4))
                let col = room.cols.lowerBound + 1 + Int(rng.next() % UInt64(room.cols.count - w - 1))
                let row = room.rows.lowerBound + 1 + Int(rng.next() % UInt64(room.rows.count - d - 1))
                let base = Terrace(origin: GridCell(col: col, row: row),
                                   cols: w, rows: d, level: 1)
                guard base.cells.allSatisfy({
                    room.contains($0) && !house.doorways.contains($0)
                        && !doorApron.contains($0)
                        && hillLevel[$0] == nil && $0 != start
                }) else { continue }

                // Tiers step in one cell per level, for as many levels as there's room
                // for. That's the closest thing to a gradual incline this game can have.
                //
                // It can't be a smooth ramp, and not for want of trying: a climb is a 90°
                // pivot about the step's top edge, which lands a face flat only if the
                // rise is exactly one cube. On a fractional slope Qoob finishes tilted on
                // a corner with no face down — and which face is down is the whole game.
                // So the rise is always one cube and the only question is how much *run*
                // goes with it. One cell per level is the gentlest the grid allows, and it
                // turns what used to be a two-step plinth into a stepped mound: an 8×8
                // patch now rises 8×8, 6×6, 4×4 over three levels instead of jumping
                // straight to a 4×4 top.
                // Two cells of run per one-cube rise, which is the flattest slope this
                // grid can express — and *why* the mounds got bigger.
                //
                // The rise is fixed at one cube (see above), so how gradual a mound looks
                // is entirely how much run goes with each step. A one-cell inset was tried
                // first and is the opposite of gradual: it's the steepest possible, 45° in
                // section. Two cells halves that. It also fixes a pose problem — getting
                // onto a tier needs face-up with paws pointing at it, and the only way to
                // change pose is to roll, so the ring below a tier has to be roomy enough
                // to turn around on. On one-cell rings the third tier came out reachable
                // only 51% of the time: a visible summit nobody could ever stand on.
                var tiers = [base]
                for (inset, level) in [(2, 2), (4, 3)] where level <= maxTerraceLevel {
                    let tw = w - inset * 2, td = d - inset * 2
                    // Below two cells a tier is a pinnacle rather than a step.
                    guard tw >= 2, td >= 2 else { break }
                    tiers.append(Terrace(origin: GridCell(col: col + inset, row: row + inset),
                                         cols: tw, rows: td, level: level))
                }
                for tier in tiers {
                    for cell in tier.cells { hillLevel[cell] = max(hillLevel[cell] ?? 0, tier.level) }
                }
                hills.append(contentsOf: tiers)
                made += 1
            }
        }

        // --- Furnish each room from its own set ---
        // Per room, not per house: a kitchen gets counters and a bedroom gets a bed,
        // and each room carries its own quotas so one sofa in the lounge doesn't stop
        // the den having one.
        var furniture: [Furniture] = []
        var blocked = Set<GridCell>()
        var solidSoFar = Set<GridCell>()
        // Seeded with the mounds, so the reachability guard in `place` weighs a piece
        // against the relief that's already there.
        var surfaceSoFar: [GridCell: Int] = hillLevel

        // Furniture is kept off the doorway aprons (computed above, and shared with the
        // mounds) for two reasons, both found by measurement rather than by taste:
        //
        // 1. A piece taller than one level standing where a door opens is a wall, because
        //    a climb is a single 90° pivot about the step's top edge. One parked across a
        //    room's only doorway sealed that room for the whole game — 9 houses in 200.
        //    `place`'s budget missed it: it allows losing up to a third of the house, and
        //    one sealed room in five is a fifth.
        //
        // 2. Exempting *climbable* pieces looked safe — you can get over a one-level
        //    stool, and the flood fill agrees. But the flood fill only checks heights; the
        //    game also demands a pose to change level, and crossing a threshold by
        //    climbing on and dropping off needs two of them in sequence. A 2×2 stool
        //    covering both cells of a yard's only doorway made that yard — 190 cells —
        //    unenterable in play while looking perfectly connected to every check the
        //    generator had. Furniture on a threshold is simply never worth the risk.

        /// The cells immediately around a piece, excluding the piece itself.
        func ring(_ f: Furniture) -> Set<GridCell> {
            Set(f.cells.flatMap { c in
                [(1, 0), (-1, 0), (0, 1), (0, -1)].map {
                    GridCell(col: c.col + $0.0, row: c.row + $0.1)
                }
            }).subtracting(f.cells)
        }

        /// `touching` is allowed only for a companion, which is *meant* to sit against
        /// its anchor — a nightstand beside a bed. Everything else keeps a cell clear.
        func fits(_ f: Furniture, touching: Bool = false) -> Bool {
            // Nothing butts up against anything else. Two pieces side by side make one
            // longer obstacle, and a chain of three makes a barricade you have to walk
            // the length of — which is what "obstructive" actually looks like. Measured
            // at 21% of pieces touching another before this. A gap of one cell means
            // every piece can be walked around rather than only past.
            if !touching, !ring(f).isDisjoint(with: blocked) { return false }
            for cell in f.cells {
                // Floor membership replaces the bounds check: a cell outside the
                // room's outline is no more available than one off the grid.
                if !floor.contains(cell) { return false }
                if cell == start { return false }
                if blocked.contains(cell) { return false }
                // A doorway has to stay walkable, or a room seals itself shut.
                if house.doorways.contains(cell) { return false }
                if doorApron.contains(cell) { return false }
                // Furniture stands on the ground, not on a bank — a bench placed across
                // the edge of a mound would have half its legs in mid-air.
                if hillLevel[cell] != nil { return false }
            }
            return true
        }

        /// Whether the whole of one of the piece's long sides is against non-floor —
        /// i.e. it's lying along a wall rather than adrift — and which way it then faces.
        /// Dividing walls count, so a sofa can back onto the wall between two rooms.
        func wallBacking(_ f: Furniture) -> RollDirection? {
            func clear(_ cells: [GridCell]) -> Bool { cells.allSatisfy { !floor.contains($0) } }
            if f.cols >= f.rows {
                let above = (0..<f.cols).map { GridCell(col: f.origin.col + $0, row: f.origin.row - 1) }
                let below = (0..<f.cols).map { GridCell(col: f.origin.col + $0, row: f.origin.row + f.rows) }
                if clear(above) { return .back }        // wall behind, faces +row
                if clear(below) { return .forward }
            } else {
                let left  = (0..<f.rows).map { GridCell(col: f.origin.col - 1, row: f.origin.row + $0) }
                let right = (0..<f.rows).map { GridCell(col: f.origin.col + f.cols, row: f.origin.row + $0) }
                if clear(left)  { return .right }
                if clear(right) { return .left }
            }
            return nil
        }

        // Each tier's cells, so `place` can check a mound hasn't been walled off.
        let hillTiers = hills.map(\.cells)

        var placedOf: [FurnitureKind: Int] = [:]

        /// Commits a piece if it fits and doesn't cut the house up.
        func place(_ piece: Furniture, touching: Bool = false) -> Bool {
            guard fits(piece, touching: touching),
                  (placedOf[piece.kind] ?? 0) < piece.kind.maxPerRoom else { return false }
            // Only the pieces that are *walls* can cut the house up — a climbable piece
            // is a raised path, not a barrier — so it's counted as reachable, not removed.
            var candidateSolid = solidSoFar
            var candidateSurface = surfaceSoFar
            for c in piece.cells {
                if piece.kind.isClimbable { candidateSurface[c] = piece.kind.levels }
                else { candidateSolid.insert(c) }
            }
            let reach = reachable(from: start, floor: floor,
                                  solid: candidateSolid, surface: candidateSurface)
            if reach.count < cellCount - cellCount / 3 { return false }   // don't wall off too much
            // And, separately: every room must be enterable *without ever changing
            // level* — so the flood is re-run with every raised cell treated as a wall.
            //
            // Two bugs pushed this from "every room keeps a standable cell" to this
            // stronger form, and both came from trusting the height-only flood fill:
            //
            // • Losing a whole room is often well under the third the budget above
            //   allows — a patio of 250 cells in a house of 1500 is 17% — so an
            //   arrangement that walled a room off entirely was waved through.
            //
            // • Worse, the height-only flood says a one-level piece is passable, because
            //   it is: `maxClimb` is 1. But the *game* also demands a pose to change
            //   level, and crossing a low piece means climbing on and dropping off, two
            //   poses in sequence. A single coffee table across a nine-wide living room
            //   left that room unenterable in play while every check the generator had
            //   reported it as connected.
            //
            // Hence the rule: furniture is never load-bearing for connectivity. It adds
            // optional verticality on top of a house you can already walk around flat.
            // Mounds are exempt on purpose — they're checked against `reach` below,
            // since climbing one is the entire point of it.
            let raised = candidateSurface.compactMap { $0.value > 0 ? $0.key : nil }
            let flat = reachable(from: start, floor: floor,
                                 solid: candidateSolid.union(raised), surface: [:])
            if !rooms.allSatisfy({ $0.cells.contains(where: flat.contains) }) { return false }

            // Never leave a pit: a cell Qoob can drop into and not climb out of.
            //
            // Drops are unlimited and climbs are capped at one level, and that asymmetry
            // is what makes this possible. A one-cell gap between two two-level pieces,
            // walled on the other sides, is enterable — you fall in from either of them —
            // and then every neighbour is two levels up, so `canMove` refuses all four
            // directions and the game is over with no way to carry on.
            //
            // The escape hatch in the controller can't save this one: it waives the
            // *pose*, and here it's `canMove` itself that fails. It has to be prevented
            // here. Only cells the piece touches can have changed, so the check is local
            // rather than a sweep of the house.
            func isPit(_ c: GridCell) -> Bool {
                guard floor.contains(c), !candidateSolid.contains(c) else { return false }
                let here = candidateSurface[c] ?? 0
                return ![(1, 0), (-1, 0), (0, 1), (0, -1)].contains { (dc, dr) in
                    let n = GridCell(col: c.col + dc, row: c.row + dr)
                    guard floor.contains(n), !candidateSolid.contains(n) else { return false }
                    return (candidateSurface[n] ?? 0) - here <= maxClimb
                }
            }
            let touched = Set(piece.cells.flatMap { c in
                [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)].map {
                    GridCell(col: c.col + $0.0, row: c.row + $0.1)
                }
            })
            if touched.contains(where: isPit) { return false }
            // Nor cut off a mound. A room can keep plenty of reachable cells and still
            // lose a corner pocket, and a mound stranded in one is dead scenery — the
            // whole point of relief is climbing it. Measured at 1 house in 35 before this.
            if !hillTiers.allSatisfy({ $0.contains(where: reach.contains) }) { return false }
            furniture.append(piece)
            placedOf[piece.kind, default: 0] += 1
            blocked = blocked.union(piece.cells)
            solidSoFar = candidateSolid
            surfaceSoFar = candidateSurface
            return true
        }

        for room in rooms {
            // Quotas are per room, so each room may have its own sofa.
            placedOf = [:]
            let area = room.cells.count
            let quota = room.kind.furnishingQuota(area: area)
            var placedHere = 0

            func randomPiece(_ kind: FurnitureKind) -> Furniture {
                let fp = kind.footprints[Int(rng.next() % UInt64(kind.footprints.count))]
                let col = room.cols.lowerBound
                    + Int(rng.next() % UInt64(max(1, room.cols.count)))
                let row = room.rows.lowerBound
                    + Int(rng.next() % UInt64(max(1, room.rows.count)))
                return Furniture(kind: kind, origin: GridCell(col: col, row: row),
                                 cols: fp.cols, rows: fp.rows)
            }

            // 1 & 2 — wall-backed anchors, each with its companion in the space it faces.
            let wallKinds = room.kind.furnitureKinds.filter { $0.prefersWall }
            var attempts = 0
            let attemptLimit = max(240, quota * 60)
            while placedHere < quota && attempts < attemptLimit && !wallKinds.isEmpty {
                attempts += 1
                let kind = wallKinds[Int(rng.next() % UInt64(wallKinds.count))]
                let candidate = randomPiece(kind)
                // The facing is worked out here and now kept on the piece, so the renderer
                // can point the model the same way the companion was placed.
                guard let faces = wallBacking(candidate),
                      place(candidate.facing(faces)) else { continue }
                let piece = candidate
                placedHere += 1

                guard let (companionKind, gap) = kind.companion,
                      room.kind.furnitureKinds.contains(companionKind) else { continue }
                for fp in companionKind.footprints {
                    let origin: GridCell
                    switch faces {
                    case .back:
                        origin = GridCell(col: piece.origin.col + (piece.cols - fp.cols) / 2,
                                          row: piece.origin.row + piece.rows + gap)
                    case .forward:
                        origin = GridCell(col: piece.origin.col + (piece.cols - fp.cols) / 2,
                                          row: piece.origin.row - gap - fp.rows)
                    case .right:
                        origin = GridCell(col: piece.origin.col + piece.cols + gap,
                                          row: piece.origin.row + (piece.rows - fp.rows) / 2)
                    case .left:
                        origin = GridCell(col: piece.origin.col - gap - fp.cols,
                                          row: piece.origin.row + (piece.rows - fp.rows) / 2)
                    }
                    // A companion sits in the space its anchor faces, so it looks back at
                    // it: a chair pulled up to a table faces the table, not away from it.
                    //
                    // The only placement allowed to touch another piece. A nightstand is
                    // supposed to be *against* the bed; held a cell off it would read as
                    // having been shoved aside.
                    if place(Furniture(kind: companionKind, origin: origin,
                                       cols: fp.cols, rows: fp.rows,
                                       facing: opposite(faces)),
                             touching: gap == 0) {
                        placedHere += 1
                        break
                    }
                }
            }

            // 3 — the free-standing pieces, anywhere in the room they fit.
            let freeKinds = room.kind.furnitureKinds.filter { !$0.prefersWall }
            attempts = 0
            let midCol = Double(room.cols.lowerBound) + Double(room.cols.count - 1) / 2
            let midRow = Double(room.rows.lowerBound) + Double(room.rows.count - 1) / 2
            while placedHere < quota && attempts < attemptLimit && !freeKinds.isEmpty {
                attempts += 1
                let kind = freeKinds[Int(rng.next() % UInt64(freeKinds.count))]
                let piece = randomPiece(kind)
                // Nothing backs a free-standing piece, so it faces in towards the middle
                // of the room — which is where the rest of the furniture is arranged and
                // where anyone in the room would be. An armchair adrift in a corner
                // looking at the skirting board is the thing this avoids.
                let facing = kind.hasFacing
                    ? towards(col: midCol, row: midRow, from: piece)
                    : nil
                if place(piece.facing(facing)) { placedHere += 1 }
            }

            // Every indoor room ends up with at least one step, over quota if need be.
            //
            // Without one, nothing in the room can be climbed at all: a climb gains
            // exactly one level and every other piece here is two or more. That was the
            // original kitchen bug, and it came back by a different route — the
            // wall-backed pass can fill the whole quota on its own (three counters, a
            // fridge and an oven is five pieces) and starve the free-standing pass that
            // the steps live in, which left 31% of kitchens with nothing to get onto.
            //
            // A guarantee rather than a tuned probability, because it's a property the
            // room needs, not a look to be balanced.
            let hasStep = { furniture.contains {
                room.contains($0.origin) && $0.kind.isClimbable && $0.kind.levels == 1
            } }
            if !room.kind.isOutdoor, room.kind.furnitureKinds.contains(.box), !hasStep() {
                var tries = 0
                while tries < 120 && !hasStep() {
                    tries += 1
                    _ = place(randomPiece(.box))
                }
            }
        }

        // Split the placed furniture into what Qoob can get onto and what stays a
        // wall, and record the height of every standable top.
        var solid = Set<GridCell>()
        var surface: [GridCell: Int] = hillLevel
        for piece in furniture {
            for cell in piece.cells {
                if piece.kind.isClimbable { surface[cell] = piece.kind.levels }
                else { solid.insert(cell) }
            }
        }

        let reach = reachable(from: start, floor: floor, solid: solid, surface: surface)

        // --- Targets, only on reachable free cells ---
        let freeReachable = reach.subtracting([start])
        // One target at a time. `BoardModel.spawnTarget` puts a fresh one somewhere
        // else each time this one is satisfied, so the count holds at one for the
        // whole session: always exactly one thing to go and find.
        let targetCount = min(1, max(1, freeReachable.count))

        var placed = Set<GridCell>()
        var targets: [Target] = []
        var tAttempts = 0
        // Sorted, not just `Array(...)`: `Set` iteration order depends on a
        // per-process hash seed, so indexing an unsorted pool with the seeded
        // RNG made a level index generate a *different* board every launch —
        // defeating the whole point of the deterministic generator.
        let pool = sortedCells(freeReachable)
        // Targets draw only from cells that are actually on screen and clear of
        // the HUD: inside the reserved rows and away from the bled-off columns.
        let restricted = freeReachable.filter {
            targetRows.contains($0.row) && targetCols.contains($0.col)
        }
        let targetPool = sortedCells(restricted.isEmpty ? freeReachable : restricted)
        while targets.count < targetCount && tAttempts < 800 && !targetPool.isEmpty {
            tAttempts += 1
            let cell = targetPool[Int(rng.next() % UInt64(targetPool.count))]
            if placed.contains(cell) { continue }
            placed.insert(cell)
            let color = Int(rng.next() % UInt64(GamePalette.count))
            targets.append(Target(col: cell.col, row: cell.row, colorIndex: color))
        }

        // --- The toy basket, and the toys ---
        // One basket per house rather than a goal pad per toy. Toys are scattered on the
        // floor and pushed to it, so the objective is a place you can see rather than a
        // set of marks to memorise.
        //
        // Toys used to be positioned so a single push solved each one — item at G−d with
        // room to stand at G−2d. That geometry existed because a push moved a toy exactly
        // one cell; now a push sends it rolling until it hits something, so the toys just
        // need somewhere open to start.
        let itemCount = max(3, min(7, cellCount / 140))
        var items: [GridCell] = []
        var usedItems = blocked.union(placed).union([start])

        // The basket goes against a wall, out of the traffic in the middle of a room but
        // reachable from three sides, and always on the floor.
        var basket: GridCell?
        let basketPool = sortedCells(reach.subtracting(usedItems))
            .filter { cell in
                guard (surface[cell] ?? 0) == 0 else { return false }
                let neighbours = [GridCell(col: cell.col + 1, row: cell.row),
                                  GridCell(col: cell.col - 1, row: cell.row),
                                  GridCell(col: cell.col, row: cell.row + 1),
                                  GridCell(col: cell.col, row: cell.row - 1)]
                // Against exactly one wall: a corner would let a toy wedge beside it.
                return neighbours.filter { !floor.contains($0) }.count == 1
            }
        let basketChoices = basketPool.isEmpty
            ? sortedCells(reach.subtracting(usedItems)).filter { (surface[$0] ?? 0) == 0 }
            : basketPool
        if !basketChoices.isEmpty {
            basket = basketChoices[Int(rng.next() % UInt64(basketChoices.count))]
            usedItems.insert(basket!)
        }

        // Toys: anywhere open on the floor, and not right up against the basket, so the
        // first push is a real push rather than a tap-in.
        var iAttempts = 0
        while items.count < itemCount && iAttempts < 400 && !pool.isEmpty {
            iAttempts += 1
            let cell = pool[Int(rng.next() % UInt64(pool.count))]
            if usedItems.contains(cell) || (surface[cell] ?? 0) != 0 { continue }
            if let basket, abs(cell.col - basket.col) + abs(cell.row - basket.row) < 3 { continue }
            items.append(cell)
            usedItems.insert(cell)
        }

        // --- Perched toys on furniture (knock-off bonus) ---
        // Likewise the knock-off bonus, which was `min(index / 4, 2)` — also always
        // zero. Bounded by the furniture actually placed, since each needs a piece.
        let perchCount = min(max(2, min(4, cellCount / 300)), max(0, furniture.count))
        var perched: [PerchedToy] = []
        var pAttempts = 0
        let dirs = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        while perched.count < perchCount && pAttempts < 200 && !furniture.isEmpty {
            pAttempts += 1
            let piece = furniture[Int(rng.next() % UInt64(furniture.count))]
            let perch = piece.cells[Int(rng.next() % UInt64(piece.cells.count))]
            let (dc, dr) = dirs[Int(rng.next() % 4)]
            let landing = GridCell(col: perch.col + dc, row: perch.row + dr)
            if !floor.contains(landing) { continue }
            if blocked.contains(landing) || !reach.contains(landing) { continue }
            if (surface[landing] ?? 0) != 0 { continue }     // toys land on the floor
            if landing == start || usedItems.contains(landing) { continue }
            if perched.contains(where: { $0.perch == perch || $0.landing == landing }) { continue }
            perched.append(PerchedToy(perch: perch, landing: landing))
            usedItems.insert(landing)
        }

        // --- The litterbox: the way out of this house and into the next ---
        // Indoors if the house has an indoor room, and kept clear of everything else so
        // rolling onto it can't be confused with satisfying a tile or shoving a toy.
        var litterbox: GridCell?
        let litterPool = sortedCells(reach.subtracting(usedItems)
            .subtracting(placed)
            .subtracting([start])
            .filter { (surface[$0] ?? 0) == 0 && $0 != basket && !items.contains($0) })
        let indoorPool = litterPool.filter { cell in
            rooms.first { $0.contains(cell) }?.kind.isOutdoor == false
        }
        let pool2 = indoorPool.isEmpty ? litterPool : indoorPool
        if !pool2.isEmpty {
            litterbox = pool2[Int(rng.next() % UInt64(pool2.count))]
        }

        // --- Rugs ---
        // Indoors only, on open floor clear of furniture, and clear of the basket and
        // litterbox so those still read as the things you're aiming at. Laid flat and
        // walked straight over — a rug the cat had to go around would be a trap.
        var rugs: [Rug] = []
        let rugSpots = sortedCells(reach)
        var rugAttempts = 0
        let rugTarget = max(1, rooms.filter { !$0.kind.isOutdoor }.count)
        while rugs.count < rugTarget && rugAttempts < 300 {
            rugAttempts += 1
            let origin = rugSpots[Int(rng.next() % UInt64(rugSpots.count))]
            let landscape = rng.next() % 2 == 0
            let cols = landscape ? 3 : 2, rows = landscape ? 2 : 3
            let patch = (0..<rows).flatMap { r in
                (0..<cols).map { GridCell(col: origin.col + $0, row: origin.row + r) }
            }
            // Wholly inside one indoor room: straddling a doorway would drape a rug
            // through a wall.
            guard let room = rooms.first(where: { $0.contains(origin) }), !room.kind.isOutdoor,
                  patch.allSatisfy({ room.contains($0) && !blocked.contains($0)
                                     && (surface[$0] ?? 0) == 0
                                     && $0 != basket && $0 != litterbox
                                     && !items.contains($0) })
            else { continue }
            guard !rugs.contains(where: { existing in
                patch.contains(where: { existing.cells.contains($0) })
            }) else { continue }
            rugs.append(Rug(origin: origin, cols: cols, rows: rows,
                            variant: Int(rng.next() % 3)))
        }

        return Level(seed: seed,
                     width: width, height: height,
                     floor: floor, rooms: rooms, doorways: house.doorways,
                     startCol: start.col, startRow: start.row,
                     targets: targets,
                     furniture: furniture,
                     blocked: blocked,
                     solid: solid,
                     surface: surface,
                     hills: hills,
                     items: items,
                     basket: basket,
                     environment: env,
                     perched: perched,
                     litterbox: litterbox,
                     rugs: rugs,
                     targetRows: targetRows,
                     targetCols: targetCols)
    }

    /// The reverse direction.
    static func opposite(_ direction: RollDirection) -> RollDirection {
        switch direction {
        case .right:   return .left
        case .left:    return .right
        case .forward: return .back
        case .back:    return .forward
        }
    }

    /// Which cardinal direction points from a piece towards a point, taking whichever
    /// axis it is further away on — so a piece well to one side turns to look across the
    /// room rather than along the wall it is nearest.
    static func towards(col: Double, row: Double, from piece: Furniture) -> RollDirection {
        let dCol = col - piece.centerCol
        let dRow = row - piece.centerRow
        if abs(dCol) >= abs(dRow) { return dCol >= 0 ? .right : .left }
        return dRow >= 0 ? .back : .forward
    }

    /// Which way a piece should face given what is behind it: away from the wall its back
    /// is against, if one of its sides is fully against non-floor.
    ///
    /// Shared with the level builder, so a hand-placed sofa is pointed by the same rule as
    /// a generated one without anybody having to say which way round it goes.
    static func wallFacing(_ piece: Furniture, floor: Set<GridCell>) -> RollDirection? {
        func clear(_ cells: [GridCell]) -> Bool { cells.allSatisfy { !floor.contains($0) } }
        let above = (0..<piece.cols).map { GridCell(col: piece.origin.col + $0, row: piece.origin.row - 1) }
        let below = (0..<piece.cols).map { GridCell(col: piece.origin.col + $0, row: piece.origin.row + piece.rows) }
        let left  = (0..<piece.rows).map { GridCell(col: piece.origin.col - 1, row: piece.origin.row + $0) }
        let right = (0..<piece.rows).map { GridCell(col: piece.origin.col + piece.cols, row: piece.origin.row + $0) }
        // The long side first: a sofa against a wall lies along it.
        if piece.cols >= piece.rows {
            if clear(above) { return .back }
            if clear(below) { return .forward }
            if clear(left)  { return .right }
            if clear(right) { return .left }
        } else {
            if clear(left)  { return .right }
            if clear(right) { return .left }
            if clear(above) { return .back }
            if clear(below) { return .forward }
        }
        return nil
    }

    /// How tall a mound may get. Each level is a separate one-cube step Qoob has to
    /// re-pose for, so this is a difficulty knob as much as a visual one.
    static let maxTerraceLevel = 3

    /// How many levels Qoob can gain in a single roll.
    ///
    /// One, and it can't be more: a climb is a 90° pivot about the step's top edge,
    /// which lifts the cube exactly one cube height. Two levels in one move would need
    /// a different motion entirely, and would land Qoob without a face down.
    ///
    /// It's also the source of the vertical puzzle — a 2-high sofa can't be taken from
    /// the floor, so the 1-high coffee table beside it becomes the way up.
    static let maxClimb = 1

    /// Cells across the viewport's short side. The camera holds this zoom whatever
    /// size the room is, so this is effectively "one screenful" and the unit rooms
    /// are measured against.
    static let visibleShortCells = 8

    /// Slack on that zoom — the view actually spans `visibleShortCells` times this.
    /// Shared with the renderer, which sits the camera back far enough to achieve it.
    static let viewSlack = 1.08

    /// How far a room must exceed the view on each axis, in cells. Enough that the
    /// camera always has somewhere to pan, so no room is ever small enough to sit
    /// still and be framed whole.
    static let roomOverscan = 2.0

    /// The view's extent in cells for a given viewport aspect ratio (width/height).
    ///
    /// Follows from the fixed zoom alone: the short side spans `visibleShortCells`
    /// plus slack and the long side follows the aspect. Deliberately independent of
    /// the camera's field of view — that only decides how far back the camera sits to
    /// achieve this extent, so room sizing doesn't need to know about it.
    static func viewCells(aspect: Double) -> (x: Double, y: Double) {
        let short = Double(visibleShortCells) * viewSlack
        let a = aspect > 0 ? aspect : 0.46
        return a >= 1 ? (short * a, short) : (short, short / a)
    }

    /// How much bigger the whole house is than one room's minimum.
    static let houseScale = 2.0
    /// A room narrower than this in either direction isn't worth splitting further —
    /// below it you get corridors rather than rooms.
    static let minRoomSpan = 8

    /// Partitions the box into rooms and opens doors between them.
    ///
    /// Binary split, leaving a one-cell gap between halves. That gap is simply *not*
    /// floor, which is what makes the interior walls free: the renderer already runs a
    /// wall along every boundary between floor and not-floor, so dividing walls and the
    /// doorways punched through them both fall out of the same pass.
    static func makeHouse(width: Int, height: Int,
                          rng: inout SeededGenerator)
                          -> (rooms: [HouseRoom], floor: Set<GridCell>, doorways: Set<GridCell>) {

        // --- 1. Split into leaf rectangles ---
        var leaves: [(cols: Range<Int>, rows: Range<Int>)] = [(0..<width, 0..<height)]
        var guardCount = 0
        while leaves.count < 5 && guardCount < 40 {
            guardCount += 1
            // Always split the biggest leaf, so rooms come out comparable in size
            // rather than one hall and three cupboards.
            guard let idx = leaves.indices.max(by: {
                leaves[$0].cols.count * leaves[$0].rows.count
                    < leaves[$1].cols.count * leaves[$1].rows.count
            }) else { break }
            let leaf = leaves[idx]
            let splitVertically = leaf.cols.count >= leaf.rows.count
            let span = splitVertically ? leaf.cols : leaf.rows
            // Need room for two rooms and the wall between them.
            guard span.count >= minRoomSpan * 2 + 1 else { break }

            // Cut somewhere in the middle third, so neither side is a slither.
            let slack = span.count - (minRoomSpan * 2 + 1)
            let at = span.lowerBound + minRoomSpan + Int(rng.next() % UInt64(slack + 1))
            leaves.remove(at: idx)
            if splitVertically {
                leaves.append((span.lowerBound..<at, leaf.rows))
                leaves.append(((at + 1)..<span.upperBound, leaf.rows))
            } else {
                leaves.append((leaf.cols, span.lowerBound..<at))
                leaves.append((leaf.cols, (at + 1)..<span.upperBound))
            }
        }

        // --- 2. Drop a leaf, so the house isn't a plain rectangle ---
        // Only with enough rooms left to still be a house, and only a corner one, so
        // what remains can't be split in two.
        if leaves.count >= 4 {
            let corners = leaves.indices.filter { i in
                let l = leaves[i]
                return (l.cols.lowerBound == 0 || l.cols.upperBound == width)
                    && (l.rows.lowerBound == 0 || l.rows.upperBound == height)
            }
            if !corners.isEmpty, rng.next() % 3 != 0 {          // two houses in three
                leaves.remove(at: corners[Int(rng.next() % UInt64(corners.count))])
            }
        }

        // --- 3. Assign each room a kind ---
        // A house is mostly indoors with somewhere to go outside. Sorting first keeps
        // the assignment stable for a given seed whatever order the splits produced.
        leaves.sort { ($0.rows.lowerBound, $0.cols.lowerBound) < ($1.rows.lowerBound, $1.cols.lowerBound) }
        let outdoorCount = leaves.count >= 3 ? 1 : 0
        var kinds: [Environment] = []
        for i in 0..<leaves.count {
            kinds.append(Environment.random(&rng, outdoor: i < outdoorCount))
        }
        // The outdoor room belongs on the outside of the house, not in the middle of it.
        if outdoorCount > 0 {
            let edge = leaves.indices.filter { i in
                let l = leaves[i]
                return l.cols.lowerBound == 0 || l.cols.upperBound == width
                    || l.rows.lowerBound == 0 || l.rows.upperBound == height
            }
            if let pick = edge.first(where: { $0 != 0 }) ?? edge.first, pick != 0 {
                kinds.swapAt(0, pick)
            }
        }
        var rooms = zip(leaves, kinds).map { HouseRoom(kind: $1, cols: $0.cols, rows: $0.rows) }

        var floor = Set<GridCell>()
        for room in rooms { floor.formUnion(room.cells) }

        // --- 4. Doors: a spanning tree over rooms that share a dividing wall ---
        // Built from actual adjacency rather than from the split history, so dropping a
        // leaf in step 2 can't leave a room sealed off.
        var doorways = Set<GridCell>()
        var adjacency: [(a: Int, b: Int, cells: [GridCell])] = []
        for i in rooms.indices {
            for j in rooms.indices where j > i {
                if let shared = wallBetween(rooms[i], rooms[j]) {
                    adjacency.append((i, j, shared))
                }
            }
        }
        var joined: Set<Int> = rooms.isEmpty ? [] : [0]
        var progressed = true
        while joined.count < rooms.count && progressed {
            progressed = false
            for link in adjacency {
                let hasA = joined.contains(link.a), hasB = joined.contains(link.b)
                guard hasA != hasB, !link.cells.isEmpty else { continue }
                // Middle of the shared wall, and a second cell where there's space, so a
                // doorway reads as a doorway rather than a mousehole.
                let mid = link.cells.count / 2
                doorways.insert(link.cells[mid])
                if link.cells.count >= 4 { doorways.insert(link.cells[mid + 1]) }
                joined.insert(hasA ? link.b : link.a)
                progressed = true
            }
        }
        // Any room the spanning pass couldn't reach has no wall shared with the rest —
        // it would be a sealed box, so it isn't part of the house.
        if joined.count < rooms.count {
            let orphans = Set(rooms.indices).subtracting(joined)
            for i in orphans.sorted(by: >) {
                floor.subtract(rooms[i].cells)
                rooms.remove(at: i)
            }
        }
        floor.formUnion(doorways)
        return (rooms, floor, doorways)
    }

    /// The cells of the one-cell wall between two rooms, if they're separated by
    /// exactly one and overlap along it. Ordered, so picking the middle is meaningful.
    /// `fileprivate`, not `private`: `HouseBlueprint` at the foot of this file uses it
    /// to auto-connect an authored house, and Swift's `private` doesn't reach across
    /// to a sibling type even in the same file.
    fileprivate static func wallBetween(_ a: HouseRoom, _ b: HouseRoom) -> [GridCell]? {
        // The overlap bounds are compared *before* a range is made from them. Two rooms
        // can be neighbours along one axis and not overlap at all on the other — an L of
        // rooms around a corner — and `Range` traps outright when built low > high, so
        // checking `isEmpty` afterwards is too late. That crashed on whichever seeds
        // happened to produce such a pair.
        // Side by side: one wall column between them, overlapping rows.
        if a.cols.upperBound + 1 == b.cols.lowerBound || b.cols.upperBound + 1 == a.cols.lowerBound {
            let col = a.cols.upperBound + 1 == b.cols.lowerBound ? a.cols.upperBound : b.cols.upperBound
            let lo = max(a.rows.lowerBound, b.rows.lowerBound)
            let hi = min(a.rows.upperBound, b.rows.upperBound)
            guard lo < hi else { return nil }
            return (lo..<hi).map { GridCell(col: col, row: $0) }
        }
        // Stacked: one wall row between them, overlapping columns.
        if a.rows.upperBound + 1 == b.rows.lowerBound || b.rows.upperBound + 1 == a.rows.lowerBound {
            let row = a.rows.upperBound + 1 == b.rows.lowerBound ? a.rows.upperBound : b.rows.upperBound
            let lo = max(a.cols.lowerBound, b.cols.lowerBound)
            let hi = min(a.cols.upperBound, b.cols.upperBound)
            guard lo < hi else { return nil }
            return (lo..<hi).map { GridCell(col: $0, row: row) }
        }
        return nil
    }

    /// 4-neighbour flood fill across a set of cells.
    fileprivate static func connected(from start: GridCell, within cells: Set<GridCell>) -> Set<GridCell> {
        guard cells.contains(start) else { return [] }
        var seen: Set<GridCell> = [start]
        var stack = [start]
        let deltas = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        while let cur = stack.popLast() {
            for (dc, dr) in deltas {
                let n = GridCell(col: cur.col + dc, row: cur.row + dr)
                if cells.contains(n), !seen.contains(n) { seen.insert(n); stack.append(n) }
            }
        }
        return seen
    }

    /// The floor cell closest to `cell` — used for the start position, since the
    /// centre of the bounding box can fall inside a cut.
    fileprivate static func nearestFloor(to cell: GridCell, in floor: Set<GridCell>) -> GridCell {
        if floor.contains(cell) { return cell }
        // Sorted so the choice is stable: `Set` order isn't.
        return floor.sorted {
            let a = abs($0.col - cell.col) + abs($0.row - cell.row)
            let b = abs($1.col - cell.col) + abs($1.row - cell.row)
            return a != b ? a < b : ($0.row, $0.col) < ($1.row, $1.col)
        }.first ?? cell
    }

    /// Cells in a stable row-major order, so a seeded RNG indexing them picks
    /// the same cell on every launch.
    private static func sortedCells(_ cells: Set<GridCell>) -> [GridCell] {
        cells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
    }

    /// Cells Qoob can actually get to from `start`, climbing at most `maxClimb`
    /// levels per step and dropping any distance.
    ///
    /// Asymmetric on purpose: you can fall off the fridge but not hop onto it. That
    /// can't strand anyone, because a drop is always available and the floor is always
    /// below — but it does mean a tall piece with nothing beside it is unreachable, so
    /// this is what target placement has to be filtered through or a room could ask
    /// for a tile that can't be stood on.
    static func reachable(from start: GridCell, floor: Set<GridCell>,
                          solid: Set<GridCell>, surface: [GridCell: Int]) -> Set<GridCell> {
        func standable(_ c: GridCell) -> Bool { floor.contains(c) && !solid.contains(c) }
        guard standable(start) else { return [] }
        var seen: Set<GridCell> = [start]
        var stack = [start]
        let deltas = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        while let cur = stack.popLast() {
            let here = surface[cur] ?? 0
            for (dc, dr) in deltas {
                let n = GridCell(col: cur.col + dc, row: cur.row + dr)
                if seen.contains(n) || !standable(n) { continue }
                if (surface[n] ?? 0) - here > maxClimb { continue }
                seen.insert(n)
                stack.append(n)
            }
        }
        return seen
    }

    /// Qoob's layout at level start, arranged so the sculpt is anatomically
    /// sensible: their face looks forward, their backside is directly opposite it,
    /// their paws are underneath, and the abstract markings sit on their spine and
    /// two flanks.
    ///
    /// The butt used to be on `.up` — on top of their head, with an abstract mark
    /// where their rear should be. Which symbol starts on which face is arbitrary
    /// for fairness, so this only affects how they read.
    static func startingFaces() -> [Face: Int] {
        [.front: CatSymbol.face.rawValue,      // head, looking ahead
         .back:  CatSymbol.butt.rawValue,       // rear + tail, opposite the head
         .down:  CatSymbol.paws.rawValue,       // paws underneath
         .up:    CatSymbol.triangle.rawValue,   // three spots along the spine
         .left:  CatSymbol.dot.rawValue,        // spot on the left flank
         .right: CatSymbol.ring.rawValue]       // ring on the right flank
    }
}

// MARK: - Authored houses

/// A house someone laid out by hand in the level builder, rather than one the
/// generator produced.
///
/// Deliberately *only* the authored decisions — the room rectangles, the furniture,
/// the handful of special cells — and none of the derived sets a `Level` actually
/// runs on. `floor`, `blocked`, `solid`, `surface` and reachability are all worked
/// out in `makeLevel()` by the same rules `Level.generate` uses, so a hand-built
/// house can't reach a state the generated ones never do. That's also why the
/// blueprint is what gets saved to disk: it's the small, stable, meaningful part.
///
/// Rooms are rectangles because the renderer draws one floor slab per room, not one
/// per cell — 1176 tile entities is what used to freeze the app. Right angles only,
/// which is the shape the house was always meant to have anyway.
struct HouseBlueprint: Codable, Identifiable, Equatable {

    /// A room: a rectangle of floor with a kind, which decides its ground, its walls
    /// and (when generated) what furniture goes in it.
    struct Room: Codable, Identifiable, Equatable {
        var id: UUID
        var kind: Environment
        var col: Int
        var row: Int
        var cols: Int
        var rows: Int

        init(id: UUID = UUID(), kind: Environment, col: Int, row: Int, cols: Int, rows: Int) {
            self.id = id; self.kind = kind
            self.col = col; self.row = row; self.cols = cols; self.rows = rows
        }

        var houseRoom: HouseRoom {
            HouseRoom(kind: kind, cols: col..<(col + cols), rows: row..<(row + rows))
        }
        var cells: [GridCell] {
            (0..<rows).flatMap { r in (0..<cols).map { GridCell(col: col + $0, row: row + r) } }
        }
        func contains(_ c: GridCell) -> Bool {
            c.col >= col && c.col < col + cols && c.row >= row && c.row < row + rows
        }
        func overlaps(_ other: Room) -> Bool {
            col < other.col + other.cols && other.col < col + cols
                && row < other.row + other.rows && other.row < row + rows
        }
        func isInside(width: Int, height: Int) -> Bool {
            col >= 0 && row >= 0 && col + cols <= width && row + rows <= height
        }
    }

    /// One piece of furniture, at a chosen footprint orientation.
    struct Piece: Codable, Identifiable, Equatable {
        var id: UUID
        var kind: FurnitureKind
        var col: Int
        var row: Int
        var cols: Int
        var rows: Int
        /// Nil means "work it out from the walls" — see `makeLevel`.
        var facing: RollDirection?

        init(id: UUID = UUID(), kind: FurnitureKind, col: Int, row: Int,
             cols: Int, rows: Int, facing: RollDirection? = nil) {
            self.id = id; self.kind = kind
            self.col = col; self.row = row; self.cols = cols; self.rows = rows
            self.facing = facing
        }

        var furniture: Furniture {
            Furniture(kind: kind, origin: GridCell(col: col, row: row),
                      cols: cols, rows: rows, facing: facing)
        }
        var cells: [GridCell] { furniture.cells }
    }

    /// One step of a mound. Same fields as `Terrace`, plus an identity.
    struct TerraceSpec: Codable, Identifiable, Equatable {
        var id: UUID
        var col: Int
        var row: Int
        var cols: Int
        var rows: Int
        var level: Int

        init(id: UUID = UUID(), col: Int, row: Int, cols: Int, rows: Int, level: Int) {
            self.id = id
            self.col = col; self.row = row; self.cols = cols; self.rows = rows
            self.level = level
        }

        var cells: [GridCell] {
            (0..<rows).flatMap { r in (0..<cols).map { GridCell(col: col + $0, row: row + r) } }
        }
        var terrace: Terrace {
            Terrace(origin: GridCell(col: col, row: row), cols: cols, rows: rows, level: level)
        }
    }

    /// A rug. Same fields as `Rug`, plus an identity so the editor can address one.
    struct RugSpec: Codable, Identifiable, Equatable {
        var id: UUID
        var col: Int
        var row: Int
        var cols: Int
        var rows: Int
        var variant: Int

        init(id: UUID = UUID(), col: Int, row: Int, cols: Int, rows: Int, variant: Int) {
            self.id = id
            self.col = col; self.row = row; self.cols = cols; self.rows = rows
            self.variant = variant
        }

        var cells: [GridCell] {
            (0..<rows).flatMap { r in (0..<cols).map { GridCell(col: col + $0, row: row + r) } }
        }
        var rug: Rug {
            Rug(origin: GridCell(col: col, row: row), cols: cols, rows: rows, variant: variant)
        }
    }

    var id: UUID
    var name: String
    /// Only the target's cell and colour are drawn from this — everything else about
    /// an authored house is authored — but it's stored so replaying one is identical.
    var seed: UInt64
    var width: Int
    var height: Int
    var rooms: [Room]
    var furniture: [Piece]
    var rugs: [RugSpec]
    /// Stepped mounds. Outdoors only when generated; the builder lets you put one
    /// anywhere, and `validate()` says so rather than refusing.
    var hills: [TerraceSpec]
    var toys: [GridCell]
    /// Cells punched through a dividing wall. Floor, but not part of any room, so they
    /// take their look from whichever room they adjoin — exactly as generated doorways do.
    var doors: [GridCell]
    var start: GridCell?
    var basket: GridCell?
    var litterbox: GridCell?

    /// A blank house of a given size. The default is a little over two screenfuls
    /// each way, which is about what the generator produces.
    init(name: String = "New house", width: Int = 34, height: Int = 48) {
        self.id = UUID()
        self.name = name
        self.seed = 0x9E3779B97F4A7C15
        self.width = max(8, width)
        self.height = max(8, height)
        self.rooms = []
        self.furniture = []
        self.rugs = []
        self.hills = []
        self.toys = []
        self.doors = []
    }

    /// Decoded field by field rather than by synthesis, so a house saved before a field
    /// existed still opens. Synthesized decoding requires every key to be present, which
    /// would have made adding `hills` quietly destroy everything already on the shelf.
    /// Anything added from here on should use `decodeIfPresent` for the same reason.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        seed = try c.decode(UInt64.self, forKey: .seed)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        rooms = try c.decodeIfPresent([Room].self, forKey: .rooms) ?? []
        furniture = try c.decodeIfPresent([Piece].self, forKey: .furniture) ?? []
        rugs = try c.decodeIfPresent([RugSpec].self, forKey: .rugs) ?? []
        hills = try c.decodeIfPresent([TerraceSpec].self, forKey: .hills) ?? []
        toys = try c.decodeIfPresent([GridCell].self, forKey: .toys) ?? []
        doors = try c.decodeIfPresent([GridCell].self, forKey: .doors) ?? []
        start = try c.decodeIfPresent(GridCell.self, forKey: .start)
        basket = try c.decodeIfPresent(GridCell.self, forKey: .basket)
        litterbox = try c.decodeIfPresent(GridCell.self, forKey: .litterbox)
    }

    /// The house currently being played, as something editable. This is the way in
    /// that matters: you open the builder on a room you're standing in rather than on
    /// an empty grid.
    init(_ level: Level, name: String) {
        self.id = UUID()
        self.name = name
        self.seed = level.seed
        self.width = level.width
        self.height = level.height
        self.rooms = level.rooms.map {
            Room(kind: $0.kind,
                 col: $0.cols.lowerBound, row: $0.rows.lowerBound,
                 cols: $0.cols.count, rows: $0.rows.count)
        }
        self.furniture = level.furniture.map {
            Piece(kind: $0.kind, col: $0.origin.col, row: $0.origin.row,
                  cols: $0.cols, rows: $0.rows, facing: $0.facing)
        }
        self.rugs = level.rugs.map {
            RugSpec(col: $0.origin.col, row: $0.origin.row,
                    cols: $0.cols, rows: $0.rows, variant: $0.variant)
        }
        self.hills = level.hills.map {
            TerraceSpec(col: $0.origin.col, row: $0.origin.row,
                        cols: $0.cols, rows: $0.rows, level: $0.level)
        }
        self.toys = level.items
        self.doors = level.doorways.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        self.start = GridCell(col: level.startCol, row: level.startRow)
        self.basket = level.basket
        self.litterbox = level.litterbox
    }

    // MARK: Derivation

    func inBounds(_ c: GridCell) -> Bool {
        c.col >= 0 && c.col < width && c.row >= 0 && c.row < height
    }

    /// Every cell that is floor: the rooms, plus the doors punched between them.
    var floorCells: Set<GridCell> {
        var floor = Set<GridCell>()
        for room in rooms { floor.formUnion(room.cells) }
        floor.formUnion(doors.filter(inBounds))
        return floor
    }

    func room(at cell: GridCell) -> Room? { rooms.last { $0.contains(cell) } }
    func piece(at cell: GridCell) -> Piece? { furniture.last { $0.cells.contains(cell) } }
    func rug(at cell: GridCell) -> RugSpec? { rugs.last { $0.cells.contains(cell) } }

    /// Turns the blueprint into a playable `Level`, or nil if there's nothing to play.
    ///
    /// Everything authored is filtered against the floor as it goes: a piece hanging
    /// half off a room, a toy inside a wall or a basket somewhere Qoob can't reach is
    /// dropped rather than carried into a board that would then be unsolvable.
    /// `validate()` reports the same problems up front so nothing disappears silently.
    func makeLevel() -> Level? {
        guard !rooms.isEmpty else { return nil }
        var rng = SeededGenerator(seed: seed)

        let houseRooms = rooms.map(\.houseRoom)
        let doorCells = Set(doors.filter(inBounds))
        let floor = floorCells

        let start = self.start.flatMap { floor.contains($0) ? $0 : nil }
            ?? Level.nearestFloor(to: GridCell(col: width / 2, row: height / 2), in: floor)

        // Mounds, lowest tier first so a higher one placed over a lower wins. Only the
        // tiers wholly on floor: a terrace half in a wall would be a cliff.
        let laidHills = hills
            .sorted { $0.level < $1.level }
            .filter { spec in spec.cells.allSatisfy { floor.contains($0) && !doorCells.contains($0) } }
        var hillLevel: [GridCell: Int] = [:]
        for spec in laidHills {
            for cell in spec.cells { hillLevel[cell] = max(hillLevel[cell] ?? 0, spec.level) }
        }

        // Furniture, in author order, skipping anything that isn't wholly on room floor.
        // Never on a doorway: a piece across a door seals a room off. Never on a mound
        // either — furniture stands on the ground.
        var pieces: [Furniture] = []
        var blocked = Set<GridCell>()
        for spec in furniture {
            let cells = spec.cells
            guard cells.allSatisfy({
                floor.contains($0) && !doorCells.contains($0)
                    && !blocked.contains($0) && $0 != start && hillLevel[$0] == nil
            }) else { continue }
            // Nobody drawing a plan wants to also state which way every sofa points, so
            // an unstated facing is worked out from the walls by the same rule the
            // generator uses — and a stated one is left alone.
            let piece = spec.furniture
            pieces.append(piece.facing == nil
                          ? piece.facing(Level.wallFacing(piece, floor: floor))
                          : piece)
            blocked.formUnion(cells)
        }

        var solid = Set<GridCell>()
        var surface: [GridCell: Int] = hillLevel
        for piece in pieces {
            for cell in piece.cells {
                if piece.kind.isClimbable { surface[cell] = piece.kind.levels }
                else { solid.insert(cell) }
            }
        }

        let reach = Level.reachable(from: start, floor: floor, solid: solid, surface: surface)

        // The bands targets may spawn in, by the same rule the generator uses: clear of
        // the header and the D-pad, and off the outermost columns where the camera has
        // clamped and the HUD can cover a tile beside Qoob.
        var rowLo = 2, rowHi = height - 3
        if rowHi - rowLo < 3 { rowLo = 0; rowHi = height }
        let targetRows = rowLo..<rowHi
        var colLo = 1, colHi = width - 1
        if colHi - colLo < 3 { colLo = 0; colHi = width }
        let targetCols = colLo..<colHi

        func isOpenFloor(_ c: GridCell) -> Bool {
            reach.contains(c) && (surface[c] ?? 0) == 0 && c != start
        }
        let items = toys.filter(isOpenFloor)
        let basketCell = basket.flatMap { isOpenFloor($0) ? $0 : nil }
        let litterCell = litterbox.flatMap { isOpenFloor($0) && $0 != basketCell ? $0 : nil }

        var spoken = Set(items)
        spoken.insert(start)
        if let basketCell { spoken.insert(basketCell) }
        if let litterCell { spoken.insert(litterCell) }

        // One target, as the generator places: `BoardModel.spawnTarget` puts a fresh one
        // somewhere else each time this one is satisfied.
        var targets: [Target] = []
        let pool = reach.subtracting(spoken)
            .filter { targetRows.contains($0.row) && targetCols.contains($0.col) }
            .sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        if !pool.isEmpty {
            let cell = pool[Int(rng.next() % UInt64(pool.count))]
            targets.append(Target(col: cell.col, row: cell.row,
                                  colorIndex: Int(rng.next() % UInt64(GamePalette.count))))
            spoken.insert(cell)
        }

        // Knock-off toys, one per climbable piece that has open floor beside it. Derived
        // rather than authored: which cell of a sofa a toy sits on isn't a decision worth
        // making by hand, and the mechanic shouldn't vanish just because a house was.
        var perched: [PerchedToy] = []
        let deltas = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        // Note what isn't asked of the perch: that Qoob can stand on it. A knock-off is
        // a roll *into* the piece, not onto it — and most furniture is two levels, which
        // a single 90° pivot can't climb, so requiring a reachable perch left every sofa
        // in the house bare.
        pieceLoop: for piece in pieces where piece.kind.isClimbable {
            guard perched.count < 3 else { break }
            for cell in piece.cells {
                for (dc, dr) in deltas {
                    let landing = GridCell(col: cell.col + dc, row: cell.row + dr)
                    guard isOpenFloor(landing), !spoken.contains(landing),
                          !blocked.contains(landing) else { continue }
                    perched.append(PerchedToy(perch: cell, landing: landing))
                    spoken.insert(landing)
                    continue pieceLoop
                }
            }
        }

        // Rugs are pure decoration, so the only thing that disqualifies one is being
        // somewhere it can't lie flat: off the floor, or under a piece of furniture.
        let laidRugs = rugs.compactMap { spec -> Rug? in
            spec.cells.allSatisfy { floor.contains($0) && !blocked.contains($0) } ? spec.rug : nil
        }

        let env = rooms.first(where: { $0.contains(start) })?.kind ?? rooms[0].kind

        return Level(seed: seed,
                     width: width, height: height,
                     floor: floor, rooms: houseRooms, doorways: doorCells,
                     startCol: start.col, startRow: start.row,
                     targets: targets,
                     furniture: pieces,
                     blocked: blocked,
                     solid: solid,
                     surface: surface,
                     hills: laidHills.map(\.terrace),
                     items: items,
                     basket: basketCell,
                     environment: env,
                     perched: perched,
                     litterbox: litterCell,
                     rugs: laidRugs,
                     targetRows: targetRows,
                     targetCols: targetCols)
    }

    // MARK: Validation

    /// What's wrong with the house, in the order a person would want to fix it.
    ///
    /// Everything here is a thing `makeLevel()` would otherwise drop on the floor
    /// silently. Empty means it plays exactly as drawn.
    func validate() -> [String] {
        var out: [String] = []
        if rooms.isEmpty {
            return ["No rooms yet — pick a room type and drag out a rectangle."]
        }
        for (i, a) in rooms.enumerated() {
            if !a.isInside(width: width, height: height) {
                out.append("A \(a.kind.displayName.lowercased()) hangs off the edge of the house.")
                break
            }
            if rooms[(i + 1)...].contains(where: { a.overlaps($0) }) {
                out.append("Two rooms overlap.")
                break
            }
        }

        let floor = floorCells
        guard let level = makeLevel() else { return out }
        let reach = Level.reachable(from: GridCell(col: level.startCol, row: level.startRow),
                                    floor: floor, solid: level.solid, surface: level.surface)

        let stranded = rooms.filter { room in !room.cells.contains(where: reach.contains) }
        if !stranded.isEmpty {
            let names = Set(stranded.map { $0.kind.displayName }).sorted().joined(separator: ", ")
            out.append("Qoob can't reach: \(names). Add a door, or use Auto-connect.")
        }
        if start == nil {
            out.append("No start cell — Qoob will begin at the middle of the house.")
        } else if let s = start, !floor.contains(s) {
            out.append("The start cell isn't on any floor.")
        }
        if basket == nil {
            out.append("No basket, so there's nowhere to push the toys.")
        } else if level.basket == nil {
            out.append("The basket is somewhere Qoob can't reach.")
        }
        if litterbox == nil {
            out.append("No litterbox, so there's no way out of this house.")
        } else if level.litterbox == nil {
            out.append("The litterbox is somewhere Qoob can't reach.")
        }
        if level.items.count < toys.count {
            out.append("\(toys.count - level.items.count) toy(s) sit somewhere unreachable.")
        }
        if level.furniture.count < furniture.count {
            out.append("\(furniture.count - level.furniture.count) piece(s) of furniture "
                       + "overhang a wall, a door, a mound or each other.")
        }
        if level.hills.count < hills.count {
            out.append("\(hills.count - level.hills.count) mound(s) overhang a wall or a door.")
        }
        // A tier two levels up with nothing one level up beside it can't be climbed —
        // a climb is a single 90° pivot. The generator builds tiers strictly inside
        // each other so this can't happen; drawn by hand, it easily can.
        let marooned = hills.filter { spec in
            spec.level > Level.maxClimb && !spec.cells.contains(where: reach.contains)
        }
        if !marooned.isEmpty {
            out.append("\(marooned.count) mound tier(s) are too tall to climb — a step "
                       + "only gains one level, so draw a wider tier underneath.")
        }
        if level.targets.isEmpty {
            out.append("There's nowhere left to put a target tile.")
        }
        return out
    }

    /// Punches doors until every room can be reached from the first one.
    ///
    /// Works off actual connectedness rather than a room graph, so rooms that already
    /// touch, or that the author has already joined by hand, are left alone.
    mutating func autoConnect() {
        guard rooms.count > 1 else { return }
        var doorSet = Set(doors.filter(inBounds))
        for _ in 0..<(rooms.count * 2) {
            var floor = Set<GridCell>()
            for room in rooms { floor.formUnion(room.cells) }
            floor.formUnion(doorSet)
            guard let anchor = rooms.first?.cells.first else { return }
            let joined = Level.connected(from: anchor, within: floor)
            let outside = rooms.indices.filter { !rooms[$0].cells.contains(where: joined.contains) }
            if outside.isEmpty { break }

            var linked = false
            search: for i in outside {
                for j in rooms.indices where !outside.contains(j) {
                    guard let wall = Level.wallBetween(rooms[i].houseRoom, rooms[j].houseRoom),
                          !wall.isEmpty else { continue }
                    let mid = wall.count / 2
                    doorSet.insert(wall[mid])
                    // A second cell where there's space, so a doorway reads as a
                    // doorway rather than a mousehole.
                    if wall.count >= 4 { doorSet.insert(wall[mid + 1]) }
                    linked = true
                    break search
                }
            }
            // Nothing left that shares a one-cell wall with the joined part: the
            // remaining rooms are islands, and `validate()` says so.
            if !linked { break }
        }
        doors = doorSet.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
    }
}

/// Where authored houses live: one JSON file per house in Application Support.
///
/// Files rather than `UserDefaults` because a house is kilobytes, not a preference,
/// and one file each means a corrupt save loses one house instead of the shelf.
enum HouseLibrary {

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Houses", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Every saved house, newest name-order first pass, then alphabetical — stable, so
    /// the list doesn't reshuffle between visits.
    static func load() -> [HouseBlueprint] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: nil))
            ?? []
        let decoder = JSONDecoder()
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(HouseBlueprint.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    static func save(_ blueprint: HouseBlueprint) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(blueprint) else { return false }
        let url = directory.appendingPathComponent("\(blueprint.id.uuidString).json")
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    static func delete(_ blueprint: HouseBlueprint) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(blueprint.id.uuidString).json"))
    }
}

/// Small deterministic PRNG (SplitMix64) so a given level index always
/// generates the same board — handy for testing and fair for scoring.
struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
