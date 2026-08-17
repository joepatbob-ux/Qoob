//
//  BlueprintTests.swift
//  QoobTests
//
//  Authored houses. Two concerns: a blueprint survives a trip through JSON, and the
//  `Level` it builds obeys the same rules a generated one does.
//
//  Note there is no `Level` → `HouseBlueprint` conversion in the project — only
//  `makeLevel()`, one way — so this can't be a literal round-trip. What's checked
//  instead is Codable fidelity on the blueprint itself, plus the properties of the
//  level it produces.
//

import Testing
import Foundation
@testable import Qoob

/// A small authored house: two rooms side by side, joined by a door, with a step in
/// each and a couple of toys. Deliberately hand-built rather than generated, because
/// the point is that the authored path is held to the same standard.
private func twoRoomHouse() -> HouseBlueprint {
    var bp = HouseBlueprint(name: "Test house", width: 20, height: 14)
    bp.rooms = [
        .init(kind: .livingRoom, col: 1, row: 1, cols: 8, rows: 10),
        .init(kind: .bedroom,    col: 11, row: 1, cols: 8, rows: 10),
    ]
    // The dividing wall is column 9–10; punch a door through it.
    bp.doors = [GridCell(col: 9, row: 5), GridCell(col: 10, row: 5)]
    bp.start = GridCell(col: 3, row: 3)
    bp.furniture = [
        .init(kind: .sofa, col: 2, row: 8, cols: 4, rows: 2),
        .init(kind: .box, col: 3, row: 6, cols: 1, rows: 1),
        .init(kind: .bed, col: 12, row: 8, cols: 3, rows: 4),
        .init(kind: .box, col: 13, row: 6, cols: 1, rows: 1),
    ]
    bp.toys = [GridCell(col: 5, row: 3), GridCell(col: 14, row: 3)]
    bp.basket = GridCell(col: 7, row: 2)
    return bp
}

@Suite("Blueprints")
struct BlueprintTests {

    /// A blueprint survives JSON unchanged.
    ///
    /// It's `Equatable`, so this is exact rather than a spot-check of fields.
    @Test("a blueprint round-trips through JSON")
    func codableExact() throws {
        let original = twoRoomHouse()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HouseBlueprint.self, from: data)
        #expect(decoded == original, "blueprint changed passing through JSON")
    }

    /// A blueprint written by an older build, missing keys added since, still loads.
    ///
    /// This is the `decodeIfPresent` promise. Houses are saved to disk, so a decode
    /// that throws on an absent key doesn't degrade — it loses the file.
    @Test("a blueprint missing optional keys still decodes")
    func missingKeysTolerated() throws {
        // The minimum a house could plausibly have been saved with.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Old house",
          "seed": 12345,
          "width": 20,
          "height": 14,
          "rooms": [],
          "furniture": [],
          "rugs": [],
          "hills": [],
          "toys": [],
          "doors": []
        }
        """
        let decoded = try JSONDecoder().decode(HouseBlueprint.self,
                                               from: Data(json.utf8))
        #expect(decoded.name == "Old house")
        #expect(decoded.start == nil)
        #expect(decoded.basket == nil)
        #expect(decoded.litterbox == nil)
    }

    /// An empty blueprint refuses to build rather than producing a broken level.
    @Test("a blueprint with no rooms makes no level")
    func emptyRefused() {
        var bp = HouseBlueprint()
        bp.rooms = []
        #expect(bp.makeLevel() == nil)
    }

    /// An authored house builds.
    @Test("an authored house builds a level")
    func authoredBuilds() throws {
        let level = try #require(twoRoomHouse().makeLevel())
        #expect(level.rooms.count == 2)
        #expect(!level.floor.isEmpty)
        #expect(!level.furniture.isEmpty)
    }

    /// An authored house obeys the invariants a generated one does.
    ///
    /// The whole reason the builder produces a `Level` rather than its own thing: a
    /// hand-built house should be indistinguishable to the rest of the game. If this
    /// fails, the builder can author content the game can't play.
    @Test("an authored house is fully reachable and softlock-free")
    func authoredIsSound() throws {
        let level = try #require(twoRoomHouse().makeLevel())
        let result = PoseSearch.explore(level)

        #expect(result.deadEnds.isEmpty,
                "\(result.deadEnds.count) dead-end states in an authored house")

        for room in level.rooms {
            let cells = room.cells.filter { level.floor.contains($0) }
            #expect(cells.contains { result.cells.contains($0) },
                    "\(room.kind.displayName) unreachable in an authored house")
        }
    }

    /// Authored furniture off the floor, on a door or on a mound is dropped, not drawn.
    ///
    /// `makeLevel` filters rather than refuses, so a sloppy authored house degrades to
    /// a playable one. Pins that the filter actually runs: a piece placed straight
    /// across the doorway must not survive.
    @Test("furniture authored onto a doorway is dropped")
    func doorwayFurnitureDropped() throws {
        var bp = twoRoomHouse()
        bp.furniture.append(.init(kind: .box, col: 9, row: 5, cols: 1, rows: 1))
        let level = try #require(bp.makeLevel())
        let doorCells = Set(bp.doors)
        for piece in level.furniture {
            for cell in piece.cells {
                #expect(!doorCells.contains(cell),
                        "authored furniture survived on a doorway")
            }
        }
    }

    /// Building the same blueprint twice gives the same level.
    @Test("makeLevel is deterministic")
    func buildStable() throws {
        let bp = twoRoomHouse()
        let a = try #require(bp.makeLevel())
        let b = try #require(bp.makeLevel())
        #expect(a.floor == b.floor)
        #expect(a.surface == b.surface)
        #expect(a.furniture.count == b.furniture.count)
        for (x, y) in zip(a.furniture, b.furniture) {
            #expect(x.kind == y.kind && x.origin == y.origin && x.facing == y.facing)
        }
    }
}
