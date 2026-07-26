//
//  Board.swift
//  TiltCube
//
//  The grid the cube rolls on. Each cell may carry a target colour that the
//  player clears by landing the matching cube face on it.
//

import Foundation
import SceneKit
import UIKit

/// One cell of the board.
struct Cell {
    /// Palette index this tile wants, or `nil` for a neutral (decorative) tile.
    var target: Int?
    /// Whether a target tile has already been satisfied.
    var cleared: Bool = false
    /// The SceneKit node for the tile surface (set when the board is built).
    weak var node: SCNNode?
    weak var ring: SCNNode?
}

/// A W×H grid of cells plus the SceneKit geometry that renders it.
final class Board {

    let width: Int
    let height: Int
    private(set) var cells: [[Cell]]        // cells[row][col]
    let rootNode = SCNNode()

    /// Number of target tiles still to clear.
    private(set) var remaining: Int = 0

    init(level: Level) {
        self.width = level.width
        self.height = level.height
        self.cells = Array(
            repeating: Array(repeating: Cell(), count: level.width),
            count: level.height
        )

        for target in level.targets {
            guard contains(col: target.col, row: target.row) else { continue }
            cells[target.row][target.col].target = target.colorIndex
        }
        remaining = level.targets.count

        buildNodes()
    }

    func contains(col: Int, row: Int) -> Bool {
        col >= 0 && col < width && row >= 0 && row < height
    }

    func cell(col: Int, row: Int) -> Cell? {
        guard contains(col: col, row: row) else { return nil }
        return cells[row][col]
    }

    /// The centre of the board in world space (used to aim the camera).
    var worldCenter: SCNVector3 {
        v3(Double(width - 1) / 2.0, 0, Double(height - 1) / 2.0)
    }

    // MARK: - Matching

    /// Attempts to clear the tile under the cube. Returns `true` if a target
    /// was newly satisfied (i.e. the down face matched an uncleared target).
    func tryMatch(col: Int, row: Int, downColor: Int) -> Bool {
        guard contains(col: col, row: row) else { return false }
        var cell = cells[row][col]
        guard let target = cell.target, !cell.cleared, target == downColor else { return false }

        cell.cleared = true
        cells[row][col] = cell
        remaining = max(0, remaining - 1)
        animateClear(cell: cell)
        return true
    }

    var isComplete: Bool { remaining == 0 }

    // MARK: - Geometry

    private func buildNodes() {
        let tileThickness: CGFloat = 0.12
        let gap: CGFloat = 0.06

        for row in 0..<height {
            for col in 0..<width {
                let size = Cube.size - gap
                let box = SCNBox(width: size, height: tileThickness,
                                 length: size, chamferRadius: 0.03)
                let mat = SCNMaterial()
                if let target = cells[row][col].target {
                    mat.diffuse.contents = GamePalette.color(target).withAlphaComponent(0.85)
                    mat.emission.contents = GamePalette.color(target).withAlphaComponent(0.12)
                } else {
                    mat.diffuse.contents = GamePalette.neutralTile
                }
                mat.roughness.contents = 0.85
                box.firstMaterial = mat

                let tile = SCNNode(geometry: box)
                // Board surface sits at y = 0; tile centre just below it.
                tile.position = v3(Double(col), -Double(tileThickness) / 2.0, Double(row))
                rootNode.addChildNode(tile)
                cells[row][col].node = tile

                // A subtle ring marks unsolved target tiles.
                if cells[row][col].target != nil {
                    let ring = makeRing(color: GamePalette.color(cells[row][col].target!))
                    ring.position = v3(Double(col), 0.01, Double(row))
                    ring.eulerAngles.x = -.pi / 2
                    rootNode.addChildNode(ring)
                    cells[row][col].ring = ring
                }
            }
        }
    }

    private func makeRing(color: UIColor) -> SCNNode {
        let ring = SCNTorus(ringRadius: Cube.size * 0.32, pipeRadius: 0.025)
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.white.withAlphaComponent(0.9)
        mat.emission.contents = color.withAlphaComponent(0.7)
        ring.firstMaterial = mat
        let node = SCNNode(geometry: ring)
        // Gentle pulse to draw the eye.
        let pulse = SCNAction.sequence([
            SCNAction.scale(to: 1.12, duration: 0.9),
            SCNAction.scale(to: 1.0, duration: 0.9)
        ])
        node.runAction(SCNAction.repeatForever(pulse))
        return node
    }

    private func animateClear(cell: Cell) {
        guard let tile = cell.node, let target = cell.target else { return }
        // Brighten the tile and retire its ring with a soft flourish.
        let color = GamePalette.color(target)
        let mat = tile.geometry?.firstMaterial
        mat?.diffuse.contents = color
        mat?.emission.contents = color.withAlphaComponent(0.55)

        let bump = SCNAction.sequence([
            SCNAction.moveBy(x: 0, y: 0.08, z: 0, duration: 0.12),
            SCNAction.moveBy(x: 0, y: -0.08, z: 0, duration: 0.18)
        ])
        tile.runAction(bump)

        if let ring = cell.ring {
            ring.runAction(SCNAction.sequence([
                SCNAction.group([
                    SCNAction.scale(to: 1.8, duration: 0.35),
                    SCNAction.fadeOut(duration: 0.35)
                ]),
                SCNAction.removeFromParentNode()
            ]))
        }
    }
}
