//
//  Cube.swift
//  TiltCube
//
//  The rolling player cube: a 6-colored-face die that rolls one grid cell
//  at a time. This file is the single source of truth for roll behaviour —
//  both the *logical* face tracking (used to test colour matches) and the
//  *visual* SceneKit animation are derived from the same `RollDirection`,
//  so they can never drift out of sync.
//

import Foundation
import SceneKit
import UIKit

/// The six sides of the cube, named in world space (Y up, camera looking
/// down the -Z axis so that -Z is "up the screen").
enum Face: Int, CaseIterable {
    case up, down, left, right, front, back
}

/// A single roll of the cube across one grid cell.
///
/// Grid convention: `col` maps to world **X** (+X = right), `row` maps to
/// world **Z** (+Z = toward the camera / down the screen). `.forward`
/// therefore moves the cube away from the player (up the screen).
enum RollDirection: CaseIterable {
    case right   // +X
    case left    // -X
    case forward // -Z  (away from player, up the screen)
    case back    // +Z  (toward the player, down the screen)

    /// Change in grid coordinates produced by this roll.
    var gridDelta: (dCol: Int, dRow: Int) {
        switch self {
        case .right:   return (1, 0)
        case .left:    return (-1, 0)
        case .forward: return (0, -1)
        case .back:    return (0, 1)
        }
    }

    /// Offset (relative to the cube's centre, cube edge length 1) of the
    /// bottom edge the cube pivots around while rolling.
    var pivotOffset: SCNVector3 {
        switch self {
        case .right:   return v3( 0.5, -0.5,  0.0)
        case .left:    return v3(-0.5, -0.5,  0.0)
        case .forward: return v3( 0.0, -0.5, -0.5)
        case .back:    return v3( 0.0, -0.5,  0.5)
        }
    }

    /// Axis the pivot rotates around, and the signed angle (radians).
    var rotation: (axis: SCNVector3, angle: CGFloat) {
        let quarter = CGFloat.pi / 2
        switch self {
        case .right:   return (v3(0, 0, 1), -quarter)
        case .left:    return (v3(0, 0, 1),  quarter)
        case .forward: return (v3(1, 0, 0), -quarter)
        case .back:    return (v3(1, 0, 0),  quarter)
        }
    }
}

/// The cube's model: its grid position and the colour sitting on each face.
///
/// `colors[face]` holds a palette index (see `GamePalette`). Rolling permutes
/// these entries exactly as a physical die would.
final class Cube {

    let node: SCNNode
    private(set) var col: Int
    private(set) var row: Int
    private(set) var isRolling = false

    /// Palette-index for each face.
    private(set) var colors: [Face: Int]

    /// Palette index currently facing down (the one that must match a tile).
    var downColorIndex: Int { colors[.down]! }

    // Cube edge length in world units.
    static let size: CGFloat = 1.0

    init(col: Int, row: Int, faceColors: [Face: Int]) {
        self.col = col
        self.row = row
        self.colors = faceColors
        self.node = Cube.makeNode(faceColors: faceColors)
        self.node.position = Cube.worldPosition(col: col, row: row)
    }

    // MARK: - Geometry

    /// World position of the cube's centre for a given grid cell. The cube
    /// rests on the board (whose top surface is at y = 0), so its centre sits
    /// at half its height.
    static func worldPosition(col: Int, row: Int) -> SCNVector3 {
        v3(Double(col), Double(size) / 2.0, Double(row))
    }

    /// Builds the visual cube. SCNBox exposes its six materials in the fixed
    /// order front(+Z), right(+X), back(-Z), left(-X), top(+Y), bottom(-Y).
    /// We assign palette colours in that order so the initial visual state
    /// matches the logical `faceColors`.
    private static func makeNode(faceColors: [Face: Int]) -> SCNNode {
        let box = SCNBox(width: size, height: size, length: size, chamferRadius: size * 0.06)

        let order: [Face] = [.front, .right, .back, .left, .up, .down]
        box.materials = order.map { face in
            let m = SCNMaterial()
            let color = GamePalette.color(faceColors[face]!)
            m.diffuse.contents = color
            m.emission.contents = color.withAlphaComponent(0.18) // gentle inner glow
            m.roughness.contents = 0.55
            m.metalness.contents = 0.0
            return m
        }

        let node = SCNNode(geometry: box)
        node.name = "cube"
        node.castsShadow = true
        return node
    }

    // MARK: - Rolling

    /// Rolls the cube one cell in `direction`, animating a 90° pivot around
    /// the appropriate bottom edge. `completion` runs after the roll settles,
    /// on the main thread.
    ///
    /// Returns `false` (without animating) if the cube is already rolling or
    /// the target cell is off the board.
    @discardableResult
    func roll(_ direction: RollDirection,
              on board: Board,
              duration: TimeInterval,
              completion: @escaping () -> Void) -> Bool {

        guard !isRolling else { return false }

        let (dCol, dRow) = direction.gridDelta
        let targetCol = col + dCol
        let targetRow = row + dRow
        guard board.contains(col: targetCol, row: targetRow) else { return false }

        isRolling = true

        guard let scene = node.scene else { isRolling = false; return false }

        // A temporary node placed at the pivot edge; rotating it swings the
        // cube around that edge (rather than spinning it in place).
        let pivot = SCNNode()
        pivot.position = SCNVector3(
            node.position.x + direction.pivotOffset.x,
            node.position.y + direction.pivotOffset.y,
            node.position.z + direction.pivotOffset.z
        )
        scene.rootNode.addChildNode(pivot)

        // Re-parent the cube under the pivot, preserving its world transform.
        let world = node.worldTransform
        pivot.addChildNode(node)
        node.transform = pivot.convertTransform(world, from: nil)

        let (axis, angle) = direction.rotation
        let spin = SCNAction.rotate(by: angle, around: axis, duration: duration)
        spin.timingMode = .easeInEaseOut

        pivot.runAction(spin) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }

                // Bake the cube back onto the root, keep its world transform.
                let baked = self.node.worldTransform
                scene.rootNode.addChildNode(self.node)
                self.node.transform = baked
                pivot.removeFromParentNode()

                // Advance logical state and snap to the exact grid centre to
                // prevent floating-point drift accumulating over many rolls.
                self.col = targetCol
                self.row = targetRow
                self.applyFacePermutation(direction)
                self.node.position = Cube.worldPosition(col: targetCol, row: targetRow)

                self.isRolling = false
                completion()
            }
        }
        return true
    }

    /// Permutes the face colours to mirror the physical roll. Derived from the
    /// same rotation as the visual animation (see the README's roll table).
    private func applyFacePermutation(_ direction: RollDirection) {
        let old = colors
        switch direction {
        case .right:
            colors[.right] = old[.up];   colors[.down] = old[.right]
            colors[.left]  = old[.down]; colors[.up]   = old[.left]
        case .left:
            colors[.left]  = old[.up];   colors[.down] = old[.left]
            colors[.right] = old[.down]; colors[.up]   = old[.right]
        case .forward:
            colors[.back]  = old[.up];   colors[.down] = old[.back]
            colors[.front] = old[.down]; colors[.up]   = old[.front]
        case .back:
            colors[.front] = old[.up];   colors[.down] = old[.front]
            colors[.back]  = old[.down]; colors[.up]   = old[.back]
        }
    }

    /// Places the cube at a cell instantly (used when (re)starting a level).
    func reset(col: Int, row: Int, faceColors: [Face: Int]) {
        self.col = col
        self.row = row
        self.colors = faceColors
        self.isRolling = false
        node.removeAllActions()
        node.transform = SCNMatrix4Identity
        node.position = Cube.worldPosition(col: col, row: row)

        let order: [Face] = [.front, .right, .back, .left, .up, .down]
        for (i, face) in order.enumerated() {
            node.geometry?.materials[i].diffuse.contents = GamePalette.color(faceColors[face]!)
            node.geometry?.materials[i].emission.contents = GamePalette.color(faceColors[face]!).withAlphaComponent(0.18)
        }
    }
}
