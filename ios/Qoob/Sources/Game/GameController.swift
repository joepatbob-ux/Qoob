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
    private var rollsSinceMatch = 0

    // Timing
    private var displayLink: CADisplayLink?
    /// When the current run of play began. Reset on resume so time spent paused
    /// or in the background doesn't land on the player's clock.
    private var runStartTime: CFTimeInterval = 0
    /// Play time banked by previous runs of this level (before pauses).
    private var bankedElapsed: TimeInterval = 0
    private var isPaused = false

    // Roll pacing: a brief rest between rolls so a held tilt "rolls downhill"
    // at a pleasant cadence rather than instantly.
    private let rollDuration: TimeInterval = 0.16
    private let restBetweenRolls: TimeInterval = 0.05
    private var nextRollAllowedAt: CFTimeInterval = 0

    init(renderer: GameRenderer, viewModel: GameViewModel) {
        self.renderer = renderer
        self.viewModel = viewModel

        motion.start()
        audio.setEnabled(viewModel.soundEnabled)

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
        rollsSinceMatch = 0
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
        bankedElapsed = 0
        runStartTime = CACurrentMediaTime()
        viewModel.phase = .playing
        Haptics.prepare()

        // Starting a level always means play is live, whatever we were paused by.
        isPaused = false
        startDisplayLink()

        // The starting cell is guaranteed target-free, but resolve for safety.
        resolveMatch()
    }

    // MARK: - Frame loop

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        // Via a proxy: CADisplayLink retains its target, so targeting `self`
        // directly would make the controller immortal — it (and the renderer,
        // motion manager and audio engine it owns) would never deallocate, and
        // `deinit`'s `invalidate()` could never run to break the cycle.
        let link = CADisplayLink(target: DisplayLinkProxy(self),
                                 selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func tick() {
        guard !isPaused, viewModel.phase == .playing else { return }

        // No time limit — this is a meditative game. The clock counts up only so
        // per-level "best time" records stay meaningful; it never ends the level.
        viewModel.elapsed = currentElapsed()

        if viewModel.tiltEnabled, let direction = motion.rollDirection() {
            requestRoll(direction)
        }
    }

    private func currentElapsed() -> TimeInterval {
        bankedElapsed + max(0, CACurrentMediaTime() - runStartTime)
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
            } else {
                // Nothing to knock off — nudge against the wall or furniture so
                // the block reads as intentional rather than as a dropped input.
                renderer.rejectRoll(direction)
                haptic { Haptics.blocked() }
            }
            nextRollAllowedAt = now + restBetweenRolls
            return
        }

        // Target tiles no longer refuse the cube: Qoob rolls wherever he likes
        // and a tile is satisfied when the face that happens to land on it
        // matches (see `resolveMatch`). Nothing to check here — the only things
        // that stop a roll are walls, furniture and unpushable toys.

        // If a toy sits on the target cell, try to push it one cell further.
        if board.hasItem(target) {
            let beyond = GridCell(col: target.col + dCol, row: target.row + dRow)
            guard board.passable(col: beyond.col, row: beyond.row),
                  !board.hasItem(beyond) else {
                // Toy is against a wall / furniture / another toy — can't push.
                renderer.rejectRoll(direction)
                haptic { Haptics.blocked() }
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
            renderer.clearTile(col: cube.col, row: cube.row)
            sfx { audio.playMatch(streak: streak - 1) }
            haptic { Haptics.match() }
            viewModel.flash(mantra: GamePalette.randomMantra())
            // Endless: a fresh target of a random symbol appears elsewhere.
            if let spawned = board.spawnTarget(avoiding: cube.cell) {
                renderer.addTarget(col: spawned.col, row: spawned.row, colorIndex: spawned.colorIndex)
            }
            viewModel.tilesRemaining = board.remaining
            rollsSinceMatch = 0
        } else {
            // Now that Qoob rolls freely, most landings are on plain floor, so
            // resetting the streak on every neutral tile would make it
            // unreachable. Instead it only cools after a long dry spell.
            rollsSinceMatch += 1
            if rollsSinceMatch >= Self.rollsToCoolStreak {
                streak = 0
                rollsSinceMatch = 0
            }
        }
    }

    /// Consecutive non-matching landings before the streak cools. Generous, so
    /// wandering between targets doesn't feel punished.
    private static let rollsToCoolStreak = 12


    // MARK: - Feedback (gated by Settings)

    private func sfx(_ play: () -> Void) { if viewModel.soundEnabled { play() } }
    private func haptic(_ tap: () -> Void) { if viewModel.hapticsEnabled { tap() } }

    // MARK: - Control

    /// Stops everything that costs power or would act behind the player's back:
    /// the frame loop, the motion feed, cosmetic animation, the soundscape, and
    /// the clock. Called when the app leaves the foreground and while a sheet
    /// covers the board (a held tilt must not roll Qoob out of sight).
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        if viewModel.phase == .playing { bankedElapsed = currentElapsed() }
        stopDisplayLink()
        motion.stop()
        audio.stop()
        renderer.setEnvironmentActive(false)
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        runStartTime = CACurrentMediaTime()
        motion.start()
        // However the device is being held now counts as neutral, so coming back
        // to the game doesn't immediately fling Qoob across the board.
        motion.calibrate()
        audio.setEnabled(viewModel.soundEnabled)
        renderer.setEnvironmentActive(true)
        startDisplayLink()
    }

    func recalibrate() { motion.calibrate() }

    /// Live sound on/off from Settings. The ambient pad is part of "sound", so
    /// it has to start and stop with the toggle — gating only the bells left the
    /// drone playing after the player switched sound off.
    func setSoundEnabled(_ enabled: Bool) {
        audio.setEnabled(enabled)
    }

    /// Live floor-theme change from Settings.
    func setFloorTheme(_ theme: FloorTheme) { renderer.applyFloorTheme(theme) }

    /// Live board-tilt change from Settings.
    func setBoardTilt(_ tilt: BoardTilt) { renderer.setBoardTilt(tilt.radians) }

    deinit {
        displayLink?.invalidate()
        motion.stop()
        audio.stop()
    }
}

/// A retain-cycle break for `CADisplayLink`, which keeps a strong reference to
/// its target. The link retains the proxy; the proxy only weakly knows the
/// controller, so the controller stays free to deallocate.
private final class DisplayLinkProxy: NSObject {
    private weak var controller: GameController?

    init(_ controller: GameController) {
        self.controller = controller
        super.init()
    }

    @objc func tick() {
        MainActor.assumeIsolated { controller?.tick() }
    }
}
