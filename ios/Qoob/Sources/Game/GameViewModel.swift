//
//  GameViewModel.swift
//  Qoob
//
//  Observable bridge between the game and the SwiftUI HUD / score menu.
//

import SwiftUI

enum GamePhase {
    case ready
    case playing
    case won
}

@MainActor
final class GameViewModel: ObservableObject {
    @Published var phase: GamePhase = .ready
    @Published var score: Int = 0
    @Published var levelIndex: Int = 0
    @Published var environmentName: String = Environment.forLevel(0).displayName
    @Published var elapsed: TimeInterval = 0
    @Published var tilesRemaining: Int = 0
    @Published var itemsRemaining: Int = 0
    @Published var targetLegend: [Int] = []
    @Published var topFaceIndex: Int = 0
    @Published var mantra: String = ""
    @Published var showMantra: Bool = false
    @Published var motionUnavailable: Bool = false

    // Level / run stats
    @Published var movesThisLevel: Int = 0
    @Published var mergesThisLevel: Int = 0
    @Published var movesSinceLastScore: Int = 0
    /// Running average of moves between scoring events this level (nil until 2nd score).
    @Published var avgMovesBetweenScoresThisLevel: Double? = nil

    // Bests for the level in view
    @Published var bestTime: TimeInterval? = nil
    @Published var bestScore: Int = 0
    @Published var bestMoves: Int? = nil
    @Published var lastTime: TimeInterval? = nil
    @Published var isNewBest: Bool = false

    // Aggregate (refreshed when the score menu opens)
    @Published var levelsCleared: Int = 0
    @Published var averageMovesBetweenScores: Double? = nil
    @Published var averageTimePerLevel: TimeInterval? = nil

    // Preferences
    @Published var tiltEnabled: Bool = true
    @Published var buttonLayout: ButtonLayout = .dPad
    @Published var showScoreMenu: Bool = false

    private let progress = ProgressStore()
    private var movesBetweenScoresSum = 0

    /// Set by GameView so the HUD can drive the game.
    weak var controller: GameController?

    init() {
        tiltEnabled = progress.tiltEnabled
        buttonLayout = progress.buttonLayout
        refreshAggregates()
    }

    func startTapped() {
        controller?.startGame(atLevel: phase == .won ? levelIndex + 1 : levelIndex)
    }

    func roll(_ direction: RollDirection) {
        controller?.requestRoll(direction)
    }

    func openScoreMenu() {
        refreshAggregates()
        bestTime = progress.bestTime(level: levelIndex)
        bestScore = progress.bestScore(level: levelIndex)
        bestMoves = progress.bestMoves(level: levelIndex)
        showScoreMenu = true
    }

    func setTiltEnabled(_ on: Bool) {
        tiltEnabled = on
        progress.tiltEnabled = on
    }

    func setButtonLayout(_ layout: ButtonLayout) {
        buttonLayout = layout
        progress.buttonLayout = layout
    }

    func resetLevelCounters() {
        movesThisLevel = 0
        mergesThisLevel = 0
        movesSinceLastScore = 0
        avgMovesBetweenScoresThisLevel = nil
        movesBetweenScoresSum = 0
    }

    func noteMove() {
        movesThisLevel += 1
        movesSinceLastScore += 1
        progress.recordMove()
    }

    func noteScoreEvent() {
        mergesThisLevel += 1
        let gap = movesSinceLastScore
        movesBetweenScoresSum += gap
        if mergesThisLevel > 0 {
            avgMovesBetweenScoresThisLevel = Double(movesBetweenScoresSum) / Double(mergesThisLevel)
        }
        movesSinceLastScore = 0
        progress.recordScoreEvent(movesSincePrevious: gap)
    }

    func refreshAggregates() {
        levelsCleared = progress.levelsCleared
        averageMovesBetweenScores = progress.averageMovesBetweenScores
        averageTimePerLevel = progress.averageTimePerLevel
    }

    func flash(mantra text: String) {
        mantra = text
        withAnimation(.easeInOut(duration: 0.4)) { showMantra = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            withAnimation(.easeInOut(duration: 0.6)) { self?.showMantra = false }
        }
    }
}
