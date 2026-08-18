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
    private let pad = ControllerInput()
    private let audio = AudioEngine()

    // Game state
    /// The house being played, or nil before the first `startGame`.
    ///
    /// One optional rather than three implicitly-unwrapped ones. These are always set
    /// together in `play(_:)` and there is no meaningful state where a board exists
    /// without a cube — but three separate `!` properties could express exactly that,
    /// and would have crashed rather than failed to compile if it ever happened. The
    /// window is real: `init` starts the display link, so the tick can fire before any
    /// house exists.
    ///
    /// `board` is a class, so it mutates through a `let` binding; `cube` is a struct, so
    /// rolling it has to write back through `self.game`.
    private struct Game {
        let level: Level
        let board: BoardModel
        var cube: CubeState
    }
    private var game: Game?
    /// Set while a hand-built house is being played, so the litterbox lays the same
    /// house out again instead of generating a stranger.
    private var authored: HouseBlueprint?
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

    // Roll pacing: a brief rest between rolls so a held control walks at a
    // pleasant cadence rather than firing as fast as the frame loop can ask.
    private let rollDuration: TimeInterval = 0.16
    private let restBetweenRolls: TimeInterval = 0.05
    private var nextRollAllowedAt: CFTimeInterval = 0

    init(renderer: GameRenderer, viewModel: GameViewModel) {
        self.renderer = renderer
        self.viewModel = viewModel

        audio.setEnabled(viewModel.soundEnabled)
        startDisplayLink()
    }

    // MARK: - Lifecycle

    /// Builds a fresh room and starts play in it.
    ///
    /// A new seed each time, so the room is different every session rather than the
    /// one board a fixed level index used to produce. Pass a seed to reproduce a
    /// particular room.
    func startGame(seed: UInt64? = nil) {
        // A generated house replaces an authored one: the builder's house is played
        // until you explicitly start a random one.
        authored = nil
        let roomSeed = seed ?? UInt64.random(in: .min ... .max)
        play(Level.generate(aspect: renderer.viewportAspect, seed: roomSeed))
    }

    /// Plays a house laid out in the level builder.
    ///
    /// Held on to, so reaching the litterbox lays this house out again rather than
    /// throwing away the thing the player just built. Returns false if the blueprint
    /// has no rooms and so isn't a house at all.
    @discardableResult
    func startGame(blueprint: HouseBlueprint) -> Bool {
        guard let level = blueprint.makeLevel() else { return false }
        authored = blueprint
        play(level)
        return true
    }

    /// The house being played, as something the level builder can edit.
    func currentBlueprint() -> HouseBlueprint? {
        guard let level = game?.level else { return nil }
        return authored ?? HouseBlueprint(level, name: level.environment.displayName)
    }

    private func play(_ level: Level) {
        let board = BoardModel(level: level)
        let cube = CubeState(col: level.startCol, row: level.startRow, level: 0,
                             colors: Level.startingFaces())
        game = Game(level: level, board: board, cube: cube)

        renderer.applyFloorTheme(viewModel.floorTheme)
        renderer.setCatStyle(viewModel.catStyle)
        renderer.setRoomAppearance(viewModel.roomAppearance)
        renderer.setBoardTilt(viewModel.boardTilt.radians)
        renderer.present(level: level, board: board, cube: cube)

        isRolling = false
        streak = 0
        rollsSinceMatch = 0
        nextRollAllowedAt = 0
        viewModel.environmentName = level.environment.displayName
        // A new room is a new run, so the score starts over. This used to be gated on
        // `index == 0`, which — with the index never leaving 0 — meant every start.
        viewModel.score = 0
        viewModel.scoreMatches = 0
        viewModel.scoreStreak = 0
        viewModel.scoreToys = 0
        viewModel.scoreKnockoffs = 0
        viewModel.toysPushed = 0
        viewModel.knockoffs = 0
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

    /// Swaps the whole house for a freshly generated one.
    ///
    /// This is what makes the world feel endless: rooms aren't remembered, so there's
    /// nothing to rearrange — the next house simply isn't this one.
    ///
    /// `renderer.present`, which `startGame` calls into, rebuilds the whole scene and
    /// costs a few hundred milliseconds even warm (measured: ~440ms in-simulator,
    /// mostly the board mesh and the cube's own materials, neither of which is
    /// cached). Unlike the launch splash, nothing here covers that by construction, so
    /// this raises a cover of its own first, gives it a beat to actually reach the
    /// screen, then does the swap behind it.
    private func enterNewHouse() {
        sfx { audio.playMatch(streak: 3) }
        haptic { Haptics.match() }
        viewModel.isEnteringHouse = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(200))
            // An authored house is the one the player asked for, so it comes back
            // rather than being swapped for a generated stranger.
            if let authored = self.authored { self.startGame(blueprint: authored) } else { self.startGame() }
            try? await Task.sleep(for: .milliseconds(150))
            self.viewModel.isEnteringHouse = false
            self.isRolling = false
        }
    }

    // MARK: - Frame loop

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        // Via a proxy: CADisplayLink retains its target, so targeting `self`
        // directly would make the controller immortal — it (and the renderer and
        // audio engine it owns) would never deallocate, and
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

        // Held inputs, in preference order. All three report the direction currently
        // held rather than firing events, so `requestRoll`'s pacing turns a held
        // thumb or a held d-pad into the same steady walk rather than a scramble —
        // and there is only one cadence to get right.
        //
        // Touch wins: a thumb on the pad is the most explicit statement of intent
        // there is. Controllers and keyboards need no setting: if one is being held,
        // that's consent enough, and it's the only way to play on an Apple TV.
        if let direction = viewModel.heldDirection {
            requestRoll(direction)
        } else if let direction = pad.rollDirection() {
            requestRoll(direction)
        }
    }

    private func currentElapsed() -> TimeInterval {
        bankedElapsed + max(0, CACurrentMediaTime() - runStartTime)
    }

    /// Whether any of the four rolls is currently legal, pose rules included.
    ///
    /// Only used to decide whether the escape hatch should open, so it deliberately
    /// does *not* consult the hatch itself — that would recurse, and would always
    /// answer yes.
    private func hasAnyLegalMove(board: BoardModel, cube: CubeState) -> Bool {
        RollDirection.allCases.contains { direction in
            let (dCol, dRow) = direction.gridDelta
            let target = GridCell(col: cube.col + dCol, row: cube.row + dRow)
            guard board.canMove(from: cube.cell, to: target) else { return false }
            let climb = board.surfaceLevel(at: target) - cube.level
            if climb > 0 { return cube.canClimb(direction) }
            if climb < 0 { return cube.canDrop(direction) }
            return true
        }
    }

    // MARK: - Rolling (single entry point for the pad, swipes and controllers)

    func requestRoll(_ direction: RollDirection) {
        guard viewModel.phase == .playing, let game else { return }
        let (board, cube) = (game.board, game.cube)
        let now = CACurrentMediaTime()
        guard !isRolling, now >= nextRollAllowedAt else { return }

        let (dCol, dRow) = direction.gridDelta
        let target = GridCell(col: cube.col + dCol, row: cube.row + dRow)
        let targetLevel = board.surfaceLevel(at: target)
        let climb = targetLevel - cube.level

        // Changing level takes more than a clear step — Qoob has to be in the pose for
        // it, the way a cat gathers itself before going up or off. Moving along the
        // same level is free; only up and down ask anything.
        //
        // The escape hatch: if no roll at all is legal, the pose stops being asked for —
        // in *either* direction.
        //
        // It used to open only for drops, on the reasoning that being stuck could only
        // mean standing on a one-cell top with nowhere to turn around. That was half the
        // picture. The mirror case is a one-cell hollow at floor level ringed by two-level
        // furniture: you drop in legally, and getting out needs a climb pose you can't
        // reach, because changing pose means rolling and there is nowhere to roll. No
        // drop is available either — you're already at the bottom — so the old hatch
        // never opened and the game was over with no way to carry on. A state-space
        // search over the pose rules found one such state in 52 houses.
        //
        // Opening it for climbs can't be exploited: `hasAnyLegalMove` deliberately
        // ignores the hatch, so it only ever fires when nothing else at all is possible.
        let poseAllows: Bool
        if climb > 0 {
            poseAllows = cube.canClimb(direction) || !hasAnyLegalMove(board: board, cube: cube)
        } else if climb < 0 {
            poseAllows = cube.canDrop(direction) || !hasAnyLegalMove(board: board, cube: cube)
        } else {
            poseAllows = true
        }

        guard board.canMove(from: cube.cell, to: target), poseAllows else {
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

        // Target tiles no longer refuse the cube: Qoob rolls wherever they like
        // and a tile is satisfied when the face that happens to land on it
        // matches (see `resolveMatch`). Nothing to check here — the only things
        // that stop a roll are walls, furniture and unpushable toys.

        // A toy in the way gets shoved, and rolls until something stops it.
        if board.hasItem(target) {
            let path = board.toyPath(from: target, direction: direction)
            guard let landing = path.last else {
                // Boxed in on this axis with nowhere even to rebound. Rare now that a
                // toy bounces, but a toy in a one-cell nook can still refuse.
                renderer.rejectRoll(direction)
                haptic { Haptics.blocked() }
                nextRollAllowedAt = now + restBetweenRolls
                return
            }
            let collected = board.moveItem(from: target, to: landing)
            // The whole path, so the toy visibly travels and rebounds rather than
            // teleporting to where it ended up.
            renderer.moveItem(from: target, along: path, duration: rollDuration,
                              collected: collected)
            viewModel.itemsRemaining = board.itemsRemaining
            if collected {
                viewModel.score += 150
                viewModel.scoreToys += 150
                viewModel.toysPushed += 1
                sfx { audio.playMatch(streak: 2) }
                haptic { Haptics.match() }
            }
        }

        isRolling = true
        haptic { Haptics.roll() }

        renderer.animateRoll(direction, to: target, toLevel: targetLevel,
                             duration: rollDuration) { [weak self] in
            guard let self = self else { return }
            self.game?.cube.applyRoll(direction)    // logical state follows the visual roll
            self.game?.cube.level = targetLevel
            self.nextRollAllowedAt = CACurrentMediaTime() + self.restBetweenRolls
            self.resolveMatch()
            // Reaching the litterbox ends this house and opens the next one. Checked
            // after `resolveMatch` so a tile satisfied on the way in still scores.
            // `isRolling` stays true across the swap — `enterNewHouse` clears it once
            // the new house is actually ready — so a roll can't land mid-transition.
            if let game = self.game, let box = game.level.litterbox, game.cube.cell == box {
                self.enterNewHouse()
            } else {
                self.isRolling = false
            }
        }
    }

    /// Tests the tile under the cube; scores and rewards a match.
    private func resolveMatch() {
        guard let game else { return }
        let (board, cube) = (game.board, game.cube)
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
    /// the frame loop, cosmetic animation, the soundscape, and the clock. Called
    /// when the app leaves the foreground and while a sheet covers the board — a
    /// held control must not roll Qoob out of sight.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        if viewModel.phase == .playing { bankedElapsed = currentElapsed() }
        stopDisplayLink()
        audio.stop()
        renderer.setEnvironmentActive(false)
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        runStartTime = CACurrentMediaTime()
        audio.setEnabled(viewModel.soundEnabled)
        renderer.setEnvironmentActive(true)
        startDisplayLink()
    }

    /// Live sound on/off from Settings. The ambient pad is part of "sound", so
    /// it has to start and stop with the toggle — gating only the bells left the
    /// drone playing after the player switched sound off.
    func setSoundEnabled(_ enabled: Bool) {
        audio.setEnabled(enabled)
    }

    /// Live floor-theme change from Settings.
    func setFloorTheme(_ theme: FloorTheme) { renderer.applyFloorTheme(theme) }

    func setCatStyle(_ style: CatStyle) { renderer.setCatStyle(style) }

    func setRoomAppearance(_ appearance: RoomAppearance) { renderer.setRoomAppearance(appearance) }

    /// Live board-tilt change from Settings.
    func setBoardTilt(_ tilt: BoardTilt) { renderer.setBoardTilt(tilt.radians) }

    deinit {
        displayLink?.invalidate()
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
