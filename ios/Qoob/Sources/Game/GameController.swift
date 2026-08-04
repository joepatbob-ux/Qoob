//
//  GameController.swift
//  Qoob
//
//  Engine-agnostic orchestrator. Merge rules follow Endorfun's guide: the
//  cube's *top* face must match a coloured square to enter/absorb it; Life
//  Force appears one at a time; Simple Blocks clear for points.
//

import Foundation
import QuartzCore

@MainActor
final class GameController {

    private let renderer: GameRenderer
    private let viewModel: GameViewModel
    private let motion = MotionManager()
    private let audio = AudioEngine()
    private let progress = ProgressStore()

    // Game state
    private var board: BoardModel!
    private var cube: CubeState!
    private var currentLevel: Level!
    private var isRolling = false
    private var streak = 0

    // Timing
    private var displayLink: CADisplayLink?
    private var levelStartTime: CFTimeInterval = 0

    // Roll pacing: a brief rest between rolls so a held tilt "rolls downhill"
    // at a pleasant cadence rather than instantly.
    private let rollDuration: TimeInterval = 0.16
    private let restBetweenRolls: TimeInterval = 0.05
    private var nextRollAllowedAt: CFTimeInterval = 0

    init(renderer: GameRenderer, viewModel: GameViewModel) {
        self.renderer = renderer
        self.viewModel = viewModel

        motion.start()
        audio.start()

        let available = motion.isAvailable
        DispatchQueue.main.async { [viewModel] in
            viewModel.motionUnavailable = !available
            if !available {
                viewModel.tiltEnabled = false
            }
        }

        startDisplayLink()
    }

    // MARK: - Lifecycle

    func startGame(atLevel index: Int) {
        let level = Level.generate(index: index)
        currentLevel = level
        board = BoardModel(level: level)
        cube = CubeState(col: level.startCol, row: level.startRow,
                         colors: Level.startingFaces())

        renderer.present(level: level, board: board, cube: cube)

        motion.calibrate()

        isRolling = false
        streak = 0
        nextRollAllowedAt = 0
        viewModel.levelIndex = index
        viewModel.environmentName = level.environment.displayName
        viewModel.score = index == 0 ? 0 : viewModel.score
        publishBoardHUD()
        viewModel.elapsed = 0
        viewModel.bestTime = progress.bestTime(level: index)
        viewModel.bestScore = progress.bestScore(level: index)
        viewModel.bestMoves = progress.bestMoves(level: index)
        viewModel.lastTime = nil
        viewModel.isNewBest = false
        viewModel.resetLevelCounters()
        levelStartTime = CACurrentMediaTime()
        viewModel.phase = .playing
        Haptics.prepare()

        resolveMerge()
    }

    // MARK: - Frame loop

    private func startDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        guard viewModel.phase == .playing else { return }

        let now = CACurrentMediaTime()
        viewModel.elapsed = max(0, now - levelStartTime)

        if viewModel.tiltEnabled, let direction = motion.rollDirection() {
            requestRoll(direction)
        }
    }

    // MARK: - Rolling (single entry point for tilt, swipe and D-pad)

    func requestRoll(_ direction: RollDirection) {
        guard viewModel.phase == .playing, let board = board, let cube = cube else { return }
        let now = CACurrentMediaTime()
        guard !isRolling, now >= nextRollAllowedAt else { return }

        let (dCol, dRow) = direction.gridDelta
        let target = GridCell(col: cube.col + dCol, row: cube.row + dRow)

        // Furniture: impassable. May still knock a perched toy off.
        if board.isBlocked(col: target.col, row: target.row) {
            if let landing = board.knockOff(at: target) {
                renderer.knockOffToy(fromFurnitureAt: target, to: landing, duration: rollDuration)
                viewModel.score += 100
                viewModel.noteScoreEvent()
                audio.playMatch(streak: 1)
                Haptics.match()
            } else {
                Haptics.roll() // soft bump
            }
            nextRollAllowedAt = now + restBetweenRolls
            return
        }

        guard board.contains(col: target.col, row: target.row) else {
            nextRollAllowedAt = now + restBetweenRolls
            return
        }

        // Endorfun rule: wrong top colour cannot enter a coloured square.
        // Predict the top face *after* this roll — that's what lands on the tile.
        var preview = cube!
        preview.applyRoll(direction)
        let topAfterRoll = preview.upColorIndex
        guard board.canEnter(col: target.col, row: target.row, topColor: topAfterRoll) else {
            Haptics.roll()
            nextRollAllowedAt = now + restBetweenRolls
            return
        }

        // If a toy sits on the target cell, try to push it one cell further.
        if board.hasItem(target) {
            let beyond = GridCell(col: target.col + dCol, row: target.row + dRow)
            guard board.passable(col: beyond.col, row: beyond.row),
                  !board.hasItem(beyond),
                  board.requiredTopColor(col: beyond.col, row: beyond.row) == nil else {
                nextRollAllowedAt = now + restBetweenRolls
                return
            }
            let landedOnGoal = board.moveItem(from: target, to: beyond)
            renderer.moveItem(from: target, to: beyond, duration: rollDuration)
            if landedOnGoal {
                viewModel.score += 150
                viewModel.itemsRemaining = board.itemsRemaining
                viewModel.noteScoreEvent()
                audio.playMatch(streak: 2)
                Haptics.match()
            } else {
                viewModel.itemsRemaining = board.itemsRemaining
            }
        }

        isRolling = true
        viewModel.noteMove()
        Haptics.roll()

        renderer.animateRoll(direction, to: target, duration: rollDuration) { [weak self] in
            guard let self = self else { return }
            self.cube.applyRoll(direction)
            self.viewModel.topFaceIndex = self.cube.upColorIndex
            self.nextRollAllowedAt = CACurrentMediaTime() + self.restBetweenRolls
            self.resolveMerge()
            self.isRolling = false
            if self.board.isComplete {
                self.endGame()
            }
        }
    }

    /// Merge with the square under the cube using the top face (Endorfun rule).
    private func resolveMerge() {
        guard let board = board, let cube = cube else { return }
        let (result, spawned) = board.tryMerge(col: cube.col, row: cube.row,
                                               topColor: cube.upColorIndex)
        switch result {
        case .none:
            if board.cell(col: cube.col, row: cube.row)?.colorIndex == nil
                || board.cell(col: cube.col, row: cube.row)?.cleared == true {
                streak = 0
            }

        case .lifeForce(let colorIndex, _):
            streak += 1
            viewModel.score += 100 + (streak - 1) * 25
            viewModel.noteScoreEvent()
            renderer.clearTile(col: cube.col, row: cube.row, colorIndex: colorIndex)
            if let next = spawned, let nextColor = board.cell(col: next.col, row: next.row)?.colorIndex {
                renderer.revealLifeForce(col: next.col, row: next.row, colorIndex: nextColor)
            }
            audio.playMatch(streak: streak - 1)
            Haptics.match()
            viewModel.flash(mantra: GamePalette.randomMantra())
            publishBoardHUD()

        case .simpleBlock(let colorIndex):
            streak += 1
            viewModel.score += 50 + (streak - 1) * 10
            viewModel.noteScoreEvent()
            renderer.clearTile(col: cube.col, row: cube.row, colorIndex: colorIndex)
            audio.playMatch(streak: max(0, streak - 1))
            Haptics.match()
            viewModel.flash(mantra: GamePalette.randomMantra())
            publishBoardHUD()
        }
    }

    private func publishBoardHUD() {
        viewModel.tilesRemaining = board.lifeForceRemaining
        viewModel.itemsRemaining = board.itemsRemaining
        if let symbol = board.activeLifeForceSymbol() {
            viewModel.targetLegend = [symbol]
        } else {
            viewModel.targetLegend = []
        }
        viewModel.topFaceIndex = cube.upColorIndex
    }

    private func endGame() {
        let timeTaken = viewModel.elapsed
        let moves = viewModel.movesThisLevel
        viewModel.lastTime = timeTaken
        viewModel.isNewBest = progress.recordWin(level: viewModel.levelIndex,
                                                 time: timeTaken,
                                                 score: viewModel.score,
                                                 moves: moves)
        viewModel.bestTime = progress.bestTime(level: viewModel.levelIndex)
        viewModel.bestScore = progress.bestScore(level: viewModel.levelIndex)
        viewModel.bestMoves = progress.bestMoves(level: viewModel.levelIndex)
        viewModel.refreshAggregates()
        audio.playWin()
        viewModel.phase = .won
    }

    // MARK: - Control

    func pause() { motion.stop() }
    func resume() { motion.start(); motion.calibrate() }
    func recalibrate() { motion.calibrate() }

    deinit { displayLink?.invalidate() }
}
