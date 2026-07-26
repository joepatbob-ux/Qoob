//
//  Level.swift
//  Qoob
//
//  A level is a grid size, a cube start cell, a time limit, and a set of
//  target tiles. Levels are generated procedurally so the game is endlessly
//  playable without any external asset files.
//

import Foundation

struct Target {
    let col: Int
    let row: Int
    let colorIndex: Int
}

struct Level {
    let index: Int
    let width: Int
    let height: Int
    let startCol: Int
    let startRow: Int
    let timeLimit: TimeInterval
    let targets: [Target]

    /// Every target colour is always reachable: the cube carries all six
    /// colours and any face can be rolled to the bottom, so a randomly
    /// coloured target set is always solvable.
    static func generate(index: Int, seed: UInt64? = nil) -> Level {
        var rng = SeededGenerator(seed: seed ?? UInt64(0xE7D0 &+ UInt64(index) &* 2654435761))

        // Grid grows gently with progression, capped for phone screens.
        let size = min(5 + index / 2, 8)
        let start = size / 2

        // More targets as levels advance.
        let targetCount = min(3 + index, size * size - 1)
        let time = TimeInterval(45 + targetCount * 6)

        var used = Set<Int>()
        used.insert(start * size + start) // keep the start cell clear
        var targets: [Target] = []

        var attempts = 0
        while targets.count < targetCount && attempts < 500 {
            attempts += 1
            let col = Int(rng.next() % UInt64(size))
            let row = Int(rng.next() % UInt64(size))
            let key = row * size + col
            if used.contains(key) { continue }
            used.insert(key)
            let color = Int(rng.next() % UInt64(GamePalette.count))
            targets.append(Target(col: col, row: row, colorIndex: color))
        }

        return Level(index: index,
                     width: size, height: size,
                     startCol: start, startRow: start,
                     timeLimit: time,
                     targets: targets)
    }

    /// The cube-cat's face layout at level start:
    /// front = face, up = butt, down = 4 paws, left = dot, right = ring,
    /// back = three dots (triangle). Indices are CatSymbol raw values.
    static func startingFaces() -> [Face: Int] {
        [.front: CatSymbol.face.rawValue,
         .up:    CatSymbol.butt.rawValue,
         .down:  CatSymbol.paws.rawValue,
         .left:  CatSymbol.dot.rawValue,
         .right: CatSymbol.ring.rawValue,
         .back:  CatSymbol.triangle.rawValue]
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
