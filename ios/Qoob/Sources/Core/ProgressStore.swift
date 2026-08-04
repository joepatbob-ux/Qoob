//
//  ProgressStore.swift
//  Qoob
//
//  Persists bests, gentle run stats, and player preferences (controls).
//  Levels are deterministic by index, so per-level bests stay comparable.
//

import Foundation

enum ButtonLayout: String, CaseIterable, Identifiable {
    case off
    case dPad
    case split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:   return "Off"
        case .dPad:  return "D-pad"
        case .split: return "Split"
        }
    }

    var detail: String {
        switch self {
        case .off:   return "Tilt and swipe only"
        case .dPad:  return "Clustered arrows"
        case .split: return "Up · down · left · right on the edges"
        }
    }
}

final class ProgressStore {

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func timeKey(_ level: Int) -> String { "qoob.bestTime.\(level)" }
    private func scoreKey(_ level: Int) -> String { "qoob.bestScore.\(level)" }
    private func movesKey(_ level: Int) -> String { "qoob.bestMoves.\(level)" }
    private let highestKey = "qoob.highestLevel"
    private let totalMovesKey = "qoob.totalMoves"
    private let totalScoreEventsKey = "qoob.totalScoreEvents"
    private let movesBetweenScoresKey = "qoob.movesBetweenScoresSum"
    private let totalCompletionsKey = "qoob.totalCompletions"
    private let totalPlayTimeKey = "qoob.totalPlayTime"
    private let tiltKey = "qoob.tiltEnabled"
    private let layoutKey = "qoob.buttonLayout"

    // MARK: - Per-level bests

    func bestTime(level: Int) -> TimeInterval? {
        let v = defaults.double(forKey: timeKey(level))
        return v > 0 ? v : nil
    }

    func bestScore(level: Int) -> Int {
        defaults.integer(forKey: scoreKey(level))
    }

    /// Fewest rolls to clear a level, or nil if never completed.
    func bestMoves(level: Int) -> Int? {
        let v = defaults.integer(forKey: movesKey(level))
        return v > 0 ? v : nil
    }

    /// Highest level index completed (-1 if none).
    var highestLevel: Int {
        defaults.object(forKey: highestKey) as? Int ?? -1
    }

    var levelsCleared: Int { max(0, highestLevel + 1) }

    // MARK: - Aggregate stats

    var totalMoves: Int { defaults.integer(forKey: totalMovesKey) }
    var totalScoreEvents: Int { defaults.integer(forKey: totalScoreEventsKey) }
    private var movesBetweenScoresSum: Int { defaults.integer(forKey: movesBetweenScoresKey) }
    var totalCompletions: Int { defaults.integer(forKey: totalCompletionsKey) }
    var totalPlayTime: TimeInterval { defaults.double(forKey: totalPlayTimeKey) }

    /// Average rolls between scoring merges across all play. Nil until first score.
    var averageMovesBetweenScores: Double? {
        guard totalScoreEvents > 0 else { return nil }
        return Double(movesBetweenScoresSum) / Double(totalScoreEvents)
    }

    var averageTimePerLevel: TimeInterval? {
        guard totalCompletions > 0 else { return nil }
        return totalPlayTime / Double(totalCompletions)
    }

    // MARK: - Recording

    func recordMove() {
        defaults.set(totalMoves + 1, forKey: totalMovesKey)
    }

    func recordScoreEvent(movesSincePrevious: Int) {
        defaults.set(totalScoreEvents + 1, forKey: totalScoreEventsKey)
        defaults.set(movesBetweenScoresSum + max(0, movesSincePrevious), forKey: movesBetweenScoresKey)
    }

    /// Records a win. Returns `true` if it set a new best time.
    @discardableResult
    func recordWin(level: Int, time: TimeInterval, score: Int, moves: Int) -> Bool {
        var newBest = false
        if let prev = bestTime(level: level) {
            if time < prev { defaults.set(time, forKey: timeKey(level)); newBest = true }
        } else {
            defaults.set(time, forKey: timeKey(level)); newBest = true
        }
        if score > bestScore(level: level) {
            defaults.set(score, forKey: scoreKey(level))
        }
        if let prevMoves = bestMoves(level: level) {
            if moves < prevMoves { defaults.set(moves, forKey: movesKey(level)) }
        } else if moves > 0 {
            defaults.set(moves, forKey: movesKey(level))
        }
        if level > highestLevel {
            defaults.set(level, forKey: highestKey)
        }
        defaults.set(totalCompletions + 1, forKey: totalCompletionsKey)
        defaults.set(totalPlayTime + time, forKey: totalPlayTimeKey)
        return newBest
    }

    // MARK: - Preferences

    var tiltEnabled: Bool {
        get {
            if defaults.object(forKey: tiltKey) == nil { return true }
            return defaults.bool(forKey: tiltKey)
        }
        set { defaults.set(newValue, forKey: tiltKey) }
    }

    var buttonLayout: ButtonLayout {
        get {
            guard let raw = defaults.string(forKey: layoutKey),
                  let layout = ButtonLayout(rawValue: raw) else { return .dPad }
            return layout
        }
        set { defaults.set(newValue.rawValue, forKey: layoutKey) }
    }
}
