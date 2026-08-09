//
//  GameController.swift
//  Qoob
//
//  The engine-agnostic game orchestrator. It owns game state (BoardModel,
//  CubeState), the frame loop, the elapsed clock, scoring, input, audio and haptics,
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
        let level = Level.generate(index: index, aspect: renderer.viewportAspect)
        currentLevel = level
        board = BoardModel(level: level)
        cube = CubeState(col: level.startCol, row: level.startRow,
                         colors: Level.startingFaces())

        renderer.applyFloorTheme(viewModel.floorTheme)
        renderer.setBoardTilt(viewModel.boardTilt.radians)
        renderer.present(level: level, board: board, cube: cube)

        // Treat the current pose as neutral, so however the device is held now
        // is "flat".
        motion.calibrate()

        isRolling = false
        streak = 0
        nextRollAllowedAt = 0
        viewModel.levelIndex = index
        viewModel.environmentName = level.environment.displayName
        if index == 0 {
            viewModel.score = 0
            viewModel.scoreMatches = 0
            viewModel.scoreStreak = 0
            viewModel.scoreToys = 0
            viewModel.scoreKnockoffs = 0
            viewModel.toysPushed = 0
            viewModel.knockoffs = 0
        }
        viewModel.tilesRemaining = board.remaining
        viewModel.itemsRemaining = board.itemsRemaining
        viewModel.elapsed = 0
        levelStartTime = CACurrentMediaTime()
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
        // No time limit — this is a meditative game. The clock counts up only so
        // per-level "best time" records stay meaningful; it never ends the level.
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
        guard board.passable(col: target.col, row: target.row) else {
            // Blocked. If it's furniture with a perched toy, knock it off (the
            // cat still doesn't move onto the furniture).
            if let landing = board.knockOff(at: target) {
                renderer.knockOffToy(fromFurnitureAt: target, to: landing, duration: rollDuration)
                viewModel.score += 100
                viewModel.scoreKnockoffs += 100
                viewModel.knockoffs += 1
                sfx { audio.playMatch(streak: 1) }
                haptic { Haptics.match() }
            }
            nextRollAllowedAt = now + restBetweenRolls
            return
        }

        // A target tile refuses the cube unless the face that *will* land on it
        // matches — so the cat can only step onto the right depiction. Predict
        // the down face after this roll without mutating live state.
        if let wanted = board.target(at: target) {
            var predicted = cube
            predicted.applyRoll(direction)
            if predicted.downColorIndex != wanted {
                renderer.rejectRoll(direction)
                haptic { Haptics.blocked() }
                nextRollAllowedAt = now + restBetweenRolls
                return
            }
        }

        // If a toy sits on the target cell, try to push it one cell further.
        if board.hasItem(target) {
            let beyond = GridCell(col: target.col + dCol, row: target.row + dRow)
            guard board.passable(col: beyond.col, row: beyond.row),
                  !board.hasItem(beyond) else {
                // Toy is against a wall / furniture / another toy — can't push.
                nextRollAllowedAt = now + restBetweenRolls
                return
            }
            let landedOnGoal = board.moveItem(from: target, to: beyond)
            renderer.moveItem(from: target, to: beyond, duration: rollDuration)
            if landedOnGoal {
                viewModel.score += 150
                viewModel.scoreToys += 150
                viewModel.toysPushed += 1
                viewModel.itemsRemaining = board.itemsRemaining
                sfx { audio.playMatch(streak: 2) }
                haptic { Haptics.match() }
            } else {
                viewModel.itemsRemaining = board.itemsRemaining
            }
        }

        isRolling = true
        haptic { Haptics.roll() }

        renderer.animateRoll(direction, to: target, duration: rollDuration) { [weak self] in
            guard let self = self else { return }
            self.cube.applyRoll(direction)          // logical state follows the visual roll
            self.nextRollAllowedAt = CACurrentMediaTime() + self.restBetweenRolls
            self.resolveMatch()
            self.isRolling = false
        }
    }

    /// Tests the tile under the cube; scores and rewards a match.
    private func resolveMatch() {
        guard let board = board, let cube = cube else { return }
        let matched = board.tryMatch(col: cube.col, row: cube.row,
                                     downColor: cube.downColorIndex)
        if matched {
            streak += 1
            let bonus = (streak - 1) * 25
            viewModel.score += 100 + bonus               // streak bonus
            viewModel.scoreMatches += 100
            viewModel.scoreStreak += bonus
            renderer.clearTile(col: cube.col, row: cube.row, colorIndex: cube.downColorIndex)
            sfx { audio.playMatch(streak: streak - 1) }
            haptic { Haptics.match() }
            viewModel.flash(mantra: GamePalette.randomMantra())
            // Endless: a fresh target of a random symbol appears elsewhere.
            if let spawned = board.spawnTarget(avoiding: cube.cell) {
                renderer.addTarget(col: spawned.col, row: spawned.row, colorIndex: spawned.colorIndex)
            }
            viewModel.tilesRemaining = board.remaining
        } else if board.cell(col: cube.col, row: cube.row)?.target == nil {
            // Landing on a neutral/cleared tile gently cools the streak.
            streak = 0
        }
    }


    // MARK: - Feedback (gated by Settings)

    private func sfx(_ play: () -> Void) { if viewModel.soundEnabled { play() } }
    private func haptic(_ tap: () -> Void) { if viewModel.hapticsEnabled { tap() } }

    // MARK: - Control

    func pause() { motion.stop(); renderer.setEnvironmentActive(false) }
    func resume() { motion.start(); motion.calibrate(); renderer.setEnvironmentActive(true) }
    func recalibrate() { motion.calibrate() }

    /// Live floor-theme change from Settings.
    func setFloorTheme(_ theme: FloorTheme) { renderer.applyFloorTheme(theme) }

    /// Live board-tilt change from Settings.
    func setBoardTilt(_ tilt: BoardTilt) { renderer.setBoardTilt(tilt.radians) }

    deinit { displayLink?.invalidate() }
}
