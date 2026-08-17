//
//  HouseBlueprint.swift
//  Qoob
//
//  Houses laid out by hand in the level builder, and the on-disk library of them.
//
//  Split out of Level.swift, which had grown to 1,600 lines covering three separate
//  concerns. The blueprint deliberately holds *only* authored decisions and none of
//  the derived sets a `Level` runs on — see the type's own comment for why that
//  matters, and BlueprintTests for the guarantee it buys.
//

import Foundation

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
