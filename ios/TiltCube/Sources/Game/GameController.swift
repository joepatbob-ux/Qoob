//
//  GameController.swift
//  TiltCube
//
//  Owns the SceneKit scene, builds the board and cube, reads tilt each frame,
//  drives rolling + colour matching, and runs the level timer. Publishes state
//  changes to the SwiftUI HUD via GameViewModel.
//

import SceneKit
import QuartzCore
import UIKit

@MainActor
final class GameController: NSObject {

    let scnView: SCNView
    private let viewModel: GameViewModel
    private let motion = MotionManager()
    private let audio = AudioEngine()

    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    private var board: Board!
    private var cube: Cube!

    private var displayLink: CADisplayLink?

    // Timing
    private var levelDeadline: CFTimeInterval = 0
    private var currentLevel: Level!

    // Roll pacing: brief rest between rolls so a held tilt "rolls downhill"
    // at a pleasant cadence rather than instantly.
    private let rollDuration: TimeInterval = 0.16
    private let restBetweenRolls: TimeInterval = 0.05
    private var nextRollAllowedAt: CFTimeInterval = 0

    // Match streak drives the rising bell + bonus scoring.
    private var streak: Int = 0

    init(view: SCNView, viewModel: GameViewModel) {
        self.scnView = view
        self.viewModel = viewModel
        super.init()

        scnView.scene = scene
        scnView.backgroundColor = GamePalette.background
        scnView.antialiasingMode = .multisampling4X
        scnView.isPlaying = true
        scnView.rendersContinuously = true

        setupLighting()
        setupCamera()

        motion.start()
        viewModel.motionUnavailable = !motion.isAvailable
        audio.start()

        startDisplayLink()
    }

    // MARK: - Scene setup

    private func setupLighting() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 520
        ambient.light!.color = UIColor(white: 0.9, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 780
        key.light!.castsShadow = true
        key.light!.shadowMode = .deferred
        key.light!.shadowColor = UIColor(white: 0, alpha: 0.35)
        key.eulerAngles = v3(-Double.pi / 3, Double.pi / 6, 0)
        scene.rootNode.addChildNode(key)
    }

    private func setupCamera() {
        cameraNode.camera = SCNCamera()
        cameraNode.camera!.fieldOfView = 42
        cameraNode.camera!.zNear = 0.1
        cameraNode.camera!.zFar = 200
        scene.rootNode.addChildNode(cameraNode)
    }

    /// Positions the camera above and toward the player so that -Z reads as
    /// "up the screen" and +X reads as "right".
    private func aimCamera(at board: Board) {
        let c = board.worldCenter
        let span = Double(max(board.width, board.height))
        cameraNode.position = v3(Double(c.x), span * 1.15, Double(c.z) + span * 1.15)
        cameraNode.look(at: v3(Double(c.x), 0, Double(c.z)))
    }

    // MARK: - Game lifecycle

    func startGame(atLevel index: Int) {
        // Tear down any previous board/cube.
        board?.rootNode.removeFromParentNode()
        cube?.node.removeFromParentNode()

        let level = Level.generate(index: index)
        currentLevel = level

        board = Board(level: level)
        scene.rootNode.addChildNode(board.rootNode)

        cube = Cube(col: level.startCol, row: level.startRow,
                    faceColors: Level.startingFaces())
        scene.rootNode.addChildNode(cube.node)

        aimCamera(at: board)

        // Use the current pose as neutral, so however they hold the device now
        // is "flat".
        motion.calibrate()

        streak = 0
        viewModel.levelIndex = index
        viewModel.score = index == 0 ? 0 : viewModel.score
        viewModel.tilesRemaining = board.remaining
        viewModel.timeRemaining = level.timeLimit
        levelDeadline = CACurrentMediaTime() + level.timeLimit
        nextRollAllowedAt = 0
        viewModel.phase = .playing

        // Check the tile the cube starts on (it may already match).
        _ = resolveMatchAtCube()
    }

    // MARK: - Frame loop

    private func startDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        guard viewModel.phase == .playing else { return }

        // Timer
        let now = CACurrentMediaTime()
        let remaining = max(0, levelDeadline - now)
        viewModel.timeRemaining = remaining
        if remaining <= 0 {
            endGame(won: false)
            return
        }

        // Rolling
        guard let cube = cube, !cube.isRolling, now >= nextRollAllowedAt else { return }
        guard let direction = motion.rollDirection() else { return }

        let didRoll = cube.roll(direction, on: board, duration: rollDuration) { [weak self] in
            guard let self = self else { return }
            self.nextRollAllowedAt = CACurrentMediaTime() + self.restBetweenRolls
            _ = self.resolveMatchAtCube()
            if self.board.isComplete {
                self.endGame(won: true)
            }
        }
        if !didRoll {
            // Blocked by a wall — nudge the retry window so we don't spin.
            nextRollAllowedAt = now + restBetweenRolls
        }
    }

    /// Tests the tile under the cube; scores + rewards a match.
    @discardableResult
    private func resolveMatchAtCube() -> Bool {
        guard let cube = cube, let board = board else { return false }
        let matched = board.tryMatch(col: cube.col, row: cube.row,
                                     downColor: cube.downColorIndex)
        if matched {
            streak += 1
            let points = 100 + (streak - 1) * 25   // streak bonus
            viewModel.score += points
            viewModel.tilesRemaining = board.remaining
            audio.playMatch(streak: streak - 1)
            viewModel.flash(mantra: GamePalette.randomMantra())
        } else {
            // Landing on a neutral/cleared tile gently cools the streak.
            if board.cell(col: cube.col, row: cube.row)?.target == nil {
                streak = 0
            }
        }
        return matched
    }

    private func endGame(won: Bool) {
        viewModel.phase = won ? .won : .lost
        if won {
            let timeBonus = Int(max(0, viewModel.timeRemaining)) * 10
            viewModel.score += timeBonus
            audio.playWin()
        }
    }

    // MARK: - Teardown

    func pause() { motion.stop() }
    func resume() { motion.start(); motion.calibrate() }

    func recalibrate() { motion.calibrate() }

    deinit {
        displayLink?.invalidate()
    }
}
