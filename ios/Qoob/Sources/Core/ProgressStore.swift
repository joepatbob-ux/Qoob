//
//  ProgressStore.swift
//  Qoob
//
//  Persists best completion times and scores per level, plus the highest
//  level reached. Levels are generated deterministically from their index
//  (see Level.generate), so a given index is always the same board — which
//  makes per-level best times fair and comparable.
//
//  Pure Foundation (UserDefaults), no rendering dependency.
//

import Foundation

final class ProgressStore {

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func timeKey(_ level: Int) -> String { "qoob.bestTime.\(level)" }
    private func scoreKey(_ level: Int) -> String { "qoob.bestScore.\(level)" }
    private let highestKey = "qoob.highestLevel"

    /// Fastest completion for a level, or nil if never completed.
    func bestTime(level: Int) -> TimeInterval? {
        let v = defaults.double(forKey: timeKey(level))
        return v > 0 ? v : nil
    }

    func bestScore(level: Int) -> Int {
        defaults.integer(forKey: scoreKey(level))
    }

    /// Highest level index the player has completed (-1 if none).
    var highestLevel: Int {
        defaults.object(forKey: highestKey) as? Int ?? -1
    }

    /// Records a win. Returns `true` if it set a new best time.
    @discardableResult
    func recordWin(level: Int, time: TimeInterval, score: Int) -> Bool {
        var newBest = false
        if let prev = bestTime(level: level) {
            if time < prev { defaults.set(time, forKey: timeKey(level)); newBest = true }
        } else {
            defaults.set(time, forKey: timeKey(level)); newBest = true
        }
        if score > bestScore(level: level) {
            defaults.set(score, forKey: scoreKey(level))
        }
        if level > highestLevel {
            defaults.set(level, forKey: highestKey)
        }
        return newBest
    }
}
