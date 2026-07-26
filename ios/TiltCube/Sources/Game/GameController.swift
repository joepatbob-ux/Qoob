//
//  GameController.swift
//  TiltCube
//
//  The engine-agnostic game orchestrator. It owns game state (BoardModel,
//  CubeState), the frame loop, the timer, scoring, input, audio and haptics,
//  and drives a `GameRenderer` for all visuals. It imports no rendering engine
//  — swap SceneKitRenderer for another GameRenderer and this file is unchanged.
//

import Foundation
import QuartzCore

@MainActor
final class GameController {

    private let renderer: GameRenderer
    private let viewModel: GameViewModel
    private let motion = MotionManager()
    private let audio = AudioEngine()

    // Game state
    private var board: BoardModel!
    private var cube: CubeState!
    private var currentLevel: Level!
    private var isRolling = false
    private var streak = 0

    // Timing
    private var displayLink: CADisplayLink?
    private var levelDeadline: CFTimeInterval = 0

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

        // Publish sensor availability on the next runloop tick — mutating
        // @Published state synchronously during view creation would trip
        // SwiftUI's "modifying state during view update" warning.
        let available = motion.isAvailable
        DispatchQueue.main.async { [viewModel] in
            viewModel.motionUnavailable = !available
            if !available {
                // No gyroscope (e.g. Simulator): fall back to manual controls.
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

        // Treat the current pose as neutral, so however the device is held now
        // is "flat".
        motion.calibrate()

        isRolling = false
        streak = 0
        nextRollAllowedAt = 0
        viewModel.levelIndex = index
        viewModel.score = index == 0 ? 0 : viewModel.score
        viewModel.tilesRemaining = board.remaining
        viewModel.targetLegend = board.remainingTargetSymbols()
        viewModel.timeRemaining = level.timeLimit
        levelDeadline = CACurrentMediaTime() + level.timeLimit
        viewModel.phase = .playing
        Haptics.prepare()

        // The starting cell is guaranteed target-free, but resolve for safety.
        resolveMatch()
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
        let remaining = max(0, levelDeadline - now)
        viewModel.timeRemaining = remaining
        if remaining <= 0 {
            endGame(won: false)
            return
        }

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
        guard board.contains(col: target.col, row: target.row) else {
            // Blocked by a wall — nudge the retry window so we don't spin.
            nextRollAllowedAt = now + restBetweenRolls
            return
        }

        isRolling = true
        Haptics.roll()

        renderer.animateRoll(direction, to: target, duration: rollDuration) { [weak self] in
            guard let self = self else { return }
            self.cube.applyRoll(direction)          // logical state follows the visual roll
            self.nextRollAllowedAt = CACurrentMediaTime() + self.restBetweenRolls
            self.resolveMatch()
            self.isRolling = false
            if self.board.isComplete {
                self.endGame(won: true)
            }
        }
    }

    /// Tests the tile under the cube; scores and rewards a match.
    private func resolveMatch() {
        guard let board = board, let cube = cube else { return }
        let matched = board.tryMatch(col: cube.col, row: cube.row,
                                     downColor: cube.downColorIndex)
        if matched {
            streak += 1
            viewModel.score += 100 + (streak - 1) * 25   // streak bonus
            viewModel.tilesRemaining = board.remaining
            viewModel.targetLegend = board.remainingTargetSymbols()
            renderer.clearTile(col: cube.col, row: cube.row, colorIndex: cube.downColorIndex)
            audio.playMatch(streak: streak - 1)
            Haptics.match()
            viewModel.flash(mantra: GamePalette.randomMantra())
        } else if board.cell(col: cube.col, row: cube.row)?.target == nil {
            // Landing on a neutral/cleared tile gently cools the streak.
            streak = 0
        }
    }

    private func endGame(won: Bool) {
        viewModel.phase = won ? .won : .lost
        if won {
            viewModel.score += Int(max(0, viewModel.timeRemaining)) * 10  // time bonus
            audio.playWin()
        }
    }

    // MARK: - Control

    func pause() { motion.stop() }
    func resume() { motion.start(); motion.calibrate() }
    func recalibrate() { motion.calibrate() }

    deinit { displayLink?.invalidate() }
}
