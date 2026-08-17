//
//  HouseInvariantTests.swift
//  QoobTests
//
//  The properties every generated house must have, checked by exhaustive search
//  rather than by sampling. These were all found the hard way — see the failure
//  each one pins in its comment.
//

import Testing
import Foundation
@testable import Qoob

/// Aspect ratios covering phone portrait through to iPad landscape. Houses are laid
/// out to fit the screen, so the ratio changes the partition and several bugs only
/// appeared at one shape.
private let aspects: [Double] = [0.46, 0.56, 0.75, 1.33]

/// Enough seeds to catch a 1-in-20 fault reliably without making the suite slow.
private let seedCount = 60

private func house(_ index: Int, aspect: Double) -> Level {
    Level.generate(aspect: aspect, seed: UInt64(index) &* 0x9E3779B97F4A7C15 &+ 4242)
}

@Suite("House invariants")
struct HouseInvariantTests {

    /// Every room can be entered.
    ///
    /// Pins the fault where furniture was placed across a doorway and sealed a room
    /// off entirely — 9 houses in 200 at the time. Furniture must never be
    /// load-bearing for connectivity: the house has to be walkable with every piece
    /// ignored, and adding pieces must not change that.
    @Test("every room is reachable", arguments: aspects)
    func everyRoomReachable(aspect: Double) {
        for i in 0..<seedCount {
            let level = house(i, aspect: aspect)
            let reached = PoseSearch.explore(level).cells
            for room in level.rooms {
                let roomCells = room.cells.filter { level.floor.contains($0) }
                guard !roomCells.isEmpty else { continue }
                #expect(roomCells.contains { reached.contains($0) },
                        "seed \(i) aspect \(aspect): \(room.kind.displayName) unreachable")
            }
        }
    }

    /// No state Qoob can reach leaves them with nothing to do.
    ///
    /// Pins the pit softlock: a one-cell hollow you could drop into and never climb
    /// out of, because climbing out needed a pose you couldn't reach from inside.
    /// The escape hatch exists for exactly this, so the search models it — if this
    /// fails, the hatch itself is broken.
    @Test("no reachable state is a dead end", arguments: aspects)
    func noSoftlocks(aspect: Double) {
        for i in 0..<seedCount {
            let level = house(i, aspect: aspect)
            let result = PoseSearch.explore(level)
            #expect(result.deadEnds.isEmpty,
                    "seed \(i) aspect \(aspect): \(result.deadEnds.count) dead-end states")
        }
    }

    /// Every tier of every outdoor mound can actually be stood on.
    ///
    /// Pins the fault where level-3 tiers were unreachable in 51% of houses: the
    /// cells connected, but arriving always left Qoob in a pose that couldn't make
    /// the next climb. Invisible to a cell-based flood fill.
    ///
    /// Deliberately over `level.hills` and not over every raised cell. `surface` also
    /// carries the tops of climbable furniture (`Level.swift`, where a piece writes
    /// `kind.levels` into it), and those are *not* required to be reachable — a
    /// four-level fridge top never is, since a climb is capped at one level. Mounds are
    /// the thing the generator promises you can get up, so mounds are what's asserted.
    @Test("every mound tier is climbable", arguments: aspects)
    func moundsClimbable(aspect: Double) {
        for i in 0..<seedCount {
            let level = house(i, aspect: aspect)
            guard !level.hills.isEmpty else { continue }
            let reached = PoseSearch.explore(level).cells
            for terrace in level.hills {
                let unreachable = terrace.cells.filter { !reached.contains($0) }
                #expect(unreachable.isEmpty,
                        "seed \(i) aspect \(aspect): \(unreachable.count) of \(terrace.cells.count) cells on a level-\(terrace.level) tier are unreachable")
            }
        }
    }

    /// Doorway cells are flat.
    ///
    /// A raised threshold turns a doorway into a climb, which needs a pose — and a
    /// doorway is the one cell in a house that must never require one, because it's
    /// the only way through.
    @Test("doorways are never raised", arguments: aspects)
    func doorwaysFlat(aspect: Double) {
        for i in 0..<seedCount {
            let level = house(i, aspect: aspect)
            for door in level.doorways {
                #expect(level.surface[door] ?? 0 == 0,
                        "seed \(i) aspect \(aspect): doorway \(door.col),\(door.row) is raised")
            }
        }
    }

    /// Furniture never blocks a doorway.
    ///
    /// The direct form of the sealed-room fault above. Checked separately so a
    /// failure says *why* rather than just "a room is unreachable".
    @Test("no furniture sits on a doorway", arguments: aspects)
    func furnitureOffDoorways(aspect: Double) {
        for i in 0..<seedCount {
            let level = house(i, aspect: aspect)
            let doors = Set(level.doorways)
            for piece in level.furniture {
                for cell in piece.cells {
                    #expect(!doors.contains(cell),
                            "seed \(i) aspect \(aspect): \(piece.kind.displayName) on a doorway")
                }
            }
        }
    }
}

@Suite("Determinism")
struct DeterminismTests {

    /// The same seed produces the same house, twice in one process.
    ///
    /// Pins a real fault: generation once iterated a `Set`, whose order isn't stable
    /// between runs, so the "deterministic" seed produced different houses. It
    /// matters because `present` rebuilds the scene from the level and anything
    /// unstable makes furniture change model or position as the camera moves.
    @Test("same seed, same house", arguments: aspects)
    func stableAcrossCalls(aspect: Double) {
        for i in 0..<20 {
            let a = house(i, aspect: aspect)
            let b = house(i, aspect: aspect)
            #expect(a.width == b.width && a.height == b.height)
            #expect(a.startCol == b.startCol && a.startRow == b.startRow)
            #expect(a.surface == b.surface, "seed \(i): mounds differ between calls")
            #expect(a.furniture.count == b.furniture.count, "seed \(i): furniture count differs")
            for (x, y) in zip(a.furniture, b.furniture) {
                #expect(x.kind == y.kind && x.origin == y.origin && x.facing == y.facing,
                        "seed \(i): furniture differs between calls")
            }
        }
    }

    /// Different seeds produce different houses.
    ///
    /// Cheap, but it catches the worst possible regression in a seeded generator:
    /// silently ignoring the seed.
    @Test("different seeds differ")
    func seedsMatter() {
        let signatures = Set((0..<40).map { i -> String in
            let l = house(i, aspect: 0.46)
            return "\(l.width)x\(l.height)|\(l.startCol),\(l.startRow)|\(l.furniture.count)|\(l.rooms.count)|\(l.surface.count)"
        })
        #expect(signatures.count > 20, "seeds are barely varying: \(signatures.count) of 40")
    }
}
