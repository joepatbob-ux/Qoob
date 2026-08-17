//
//  ToyPhysicsTests.swift
//  QoobTests
//
//  What a shoved toy is allowed to do. The rules are small but the failure mode is
//  nasty: a toy that comes to rest somewhere it can't be pushed out of is
//  unwinnable content in a game with no way to reset a house.
//

import Testing
import Foundation
@testable import Qoob

private func house(_ index: Int, aspect: Double = 0.46) -> Level {
    Level.generate(aspect: aspect, seed: UInt64(index) &* 0x9E3779B97F4A7C15 &+ 4242)
}

@Suite("Toy physics")
struct ToyPhysicsTests {

    /// A toy never comes to rest off the floor.
    ///
    /// Goal pads only exist at floor level, so a toy shoved up onto furniture or a
    /// mound could never be delivered. `canHoldToy` is the guard; this checks every
    /// cell of every path honours it, not just the last one.
    @Test("every cell a toy passes through is at floor level")
    func pathsStayOnTheFloor() {
        for i in 0..<40 {
            let level = house(i)
            let board = BoardModel(level: level)
            for toy in level.items {
                for direction in RollDirection.allCases {
                    for cell in board.toyPath(from: toy, direction: direction) {
                        #expect(board.surfaceLevel(at: cell) == 0,
                                "seed \(i): toy path reaches \(cell.col),\(cell.row) at height \(board.surfaceLevel(at: cell))")
                        #expect(board.canHoldToy(cell),
                                "seed \(i): toy path reaches a cell it can't rest on")
                    }
                }
            }
        }
    }

    /// A path never runs onto another toy.
    ///
    /// Two toys in one cell is unrecoverable: the game tracks them in a set, so the
    /// second one silently vanishes.
    @Test("a toy never rolls onto another toy")
    func pathsAvoidOtherToys() {
        for i in 0..<40 {
            let level = house(i)
            let board = BoardModel(level: level)
            let others = Set(level.items)
            for toy in level.items {
                for direction in RollDirection.allCases {
                    for cell in board.toyPath(from: toy, direction: direction) {
                        #expect(!others.contains(cell) || cell == toy,
                                "seed \(i): toy path lands on another toy at \(cell.col),\(cell.row)")
                    }
                }
            }
        }
    }

    /// A path is never longer than the roll allows.
    ///
    /// Bounded by `toyRollDistance`; a longer path means the loop can be driven past
    /// its budget, which would let a toy cross a whole house from one shove.
    @Test("paths respect the roll distance")
    func pathsBounded() {
        for i in 0..<40 {
            let level = house(i)
            let board = BoardModel(level: level)
            for toy in level.items {
                for direction in RollDirection.allCases {
                    let path = board.toyPath(from: toy, direction: direction)
                    #expect(path.count <= BoardModel.toyRollDistance,
                            "seed \(i): path of \(path.count) exceeds \(BoardModel.toyRollDistance)")
                }
            }
        }
    }

    /// Every loose toy can be moved in at least one direction.
    ///
    /// This is the invariant the rebound was introduced for. A push used to move a toy
    /// exactly one cell and refuse if that cell was taken, so a toy wedged in a corner
    /// had no legal push in any direction and stayed there for the rest of the game.
    /// If this fails, some house ships with an undeliverable toy.
    @Test("no toy starts wedged", arguments: [0.46, 0.75])
    func noWedgedToys(aspect: Double) {
        for i in 0..<40 {
            let level = house(i, aspect: aspect)
            let board = BoardModel(level: level)
            for toy in level.items {
                let movable = RollDirection.allCases.contains {
                    !board.toyPath(from: toy, direction: $0).isEmpty
                }
                #expect(movable,
                        "seed \(i) aspect \(aspect): toy at \(toy.col),\(toy.row) cannot be pushed at all")
            }
        }
    }

    /// A toy delivered to the basket is collected, not left sitting in it.
    @Test("reaching the basket collects the toy")
    func basketCollects() {
        for i in 0..<40 {
            let level = house(i)
            guard let basket = level.basket, let toy = level.items.first else { continue }
            let board = BoardModel(level: level)
            let before = board.itemsRemaining
            #expect(board.moveItem(from: toy, to: basket), "basket didn't collect")
            #expect(board.itemsRemaining == before - 1,
                    "seed \(i): toy count didn't drop on collection")
        }
    }

    /// Toys and the basket start on distinct cells.
    ///
    /// A toy generated already in the basket would be collected before the player
    /// touched it, and the target count would be wrong from the first frame.
    @Test("no toy starts in the basket or on a raised cell")
    func startsAreSane() {
        for i in 0..<60 {
            let level = house(i)
            let board = BoardModel(level: level)
            for toy in level.items {
                #expect(toy != level.basket, "seed \(i): a toy starts in the basket")
                #expect(board.surfaceLevel(at: toy) == 0,
                        "seed \(i): a toy starts raised at \(toy.col),\(toy.row)")
            }
            #expect(Set(level.items).count == level.items.count,
                    "seed \(i): two toys share a cell")
        }
    }

    /// Knocking a perched toy off puts it on the floor and makes it pushable.
    @Test("a knocked-off toy lands on the floor")
    func knockOffLands() {
        for i in 0..<60 {
            let level = house(i)
            let board = BoardModel(level: level)
            for perch in level.perched {
                guard let landing = board.perchedLanding(at: perch.perch) else { continue }
                #expect(board.canHoldToy(landing),
                        "seed \(i): perched toy would land somewhere it can't rest")
                #expect(board.surfaceLevel(at: landing) == 0,
                        "seed \(i): perched toy lands raised")
            }
        }
    }
}
