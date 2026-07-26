//
//  SceneKitRenderer.swift
//  TiltCube
//
//  The SceneKit implementation of GameRenderer. All SceneKit knowledge lives
//  here: scene graph, camera, lighting, tile + cube geometry, the pivot-edge
//  roll animation, and the tile-cleared flourish.
//
//  To use detailed 3D models later, this is the only file that changes: swap
//  `makeCubeNode`'s SCNBox for `SCNScene(named: "cube.usdz")`'s node (keeping
//  the six face materials in the SCNBox order), and swap `makeTileNode`
//  similarly. The game core is unaffected.
//
//  To move to a different engine, write a sibling type conforming to
//  GameRenderer; nothing else changes.
//

import SceneKit
import UIKit

@MainActor
final class SceneKitRenderer: NSObject, GameRenderer {

    /// The view SwiftUI embeds. Owned by the renderer.
    let view = SCNView()

    private let scene = SCNScene()
    private let cameraNode = SCNNode()

    private var boardNode = SCNNode()
    private var cubeNode = SCNNode()

    /// Tile nodes + their glow rings, keyed by "col,row" for the clear flourish.
    private var tileNodes: [String: SCNNode] = [:]
    private var ringNodes: [String: SCNNode] = [:]

    /// Cube edge length in world units.
    private let cubeSize: CGFloat = 1.0

    override init() {
        super.init()
        view.scene = scene
        view.backgroundColor = GamePalette.background
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true
        view.rendersContinuously = true
        setupLighting()
        setupCamera()
    }

    // MARK: - GameRenderer

    func present(level: Level, board: BoardModel, cube: CubeState) {
        boardNode.removeFromParentNode()
        cubeNode.removeFromParentNode()
        tileNodes.removeAll()
        ringNodes.removeAll()

        boardNode = SCNNode()
        buildBoard(board)
        scene.rootNode.addChildNode(boardNode)

        cubeNode = makeCubeNode(colors: cube.colors)
        cubeNode.position = worldPosition(col: cube.col, row: cube.row)
        scene.rootNode.addChildNode(cubeNode)

        aimCamera(board: board)
    }

    func animateRoll(_ direction: RollDirection,
                     to target: GridCell,
                     duration: TimeInterval,
                     completion: @escaping () -> Void) {

        let offset = pivotOffset(direction)
        let pivot = SCNNode()
        pivot.position = SCNVector3(cubeNode.position.x + offset.x,
                                    cubeNode.position.y + offset.y,
                                    cubeNode.position.z + offset.z)
        scene.rootNode.addChildNode(pivot)

        // Re-parent the cube under the pivot, preserving its world transform,
        // so rotating the pivot swings the cube around the bottom edge.
        let world = cubeNode.worldTransform
        pivot.addChildNode(cubeNode)
        cubeNode.transform = pivot.convertTransform(world, from: nil)

        let (axis, angle) = rotation(direction)
        let spin = SCNAction.rotate(by: angle, around: axis, duration: duration)
        spin.timingMode = .easeInEaseOut

        pivot.runAction(spin) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Bake back onto the root and snap to the exact grid centre to
                // avoid floating-point drift over many rolls.
                let baked = self.cubeNode.worldTransform
                self.scene.rootNode.addChildNode(self.cubeNode)
                self.cubeNode.transform = baked
                pivot.removeFromParentNode()
                self.cubeNode.position = self.worldPosition(col: target.col, row: target.row)
                completion()
            }
        }
    }

    func clearTile(col: Int, row: Int, colorIndex: Int) {
        let key = "\(col),\(row)"
        let color = GamePalette.color(colorIndex)

        if let tile = tileNodes[key] {
            // Keep the depiction; brighten the slot to mark it satisfied.
            tile.geometry?.firstMaterial?.emission.contents = color.withAlphaComponent(0.5)
            tile.runAction(SCNAction.sequence([
                SCNAction.moveBy(x: 0, y: 0.08, z: 0, duration: 0.12),
                SCNAction.moveBy(x: 0, y: -0.08, z: 0, duration: 0.18)
            ]))
        }
        if let ring = ringNodes[key] {
            ring.runAction(SCNAction.sequence([
                SCNAction.group([
                    SCNAction.scale(to: 1.8, duration: 0.35),
                    SCNAction.fadeOut(duration: 0.35)
                ]),
                SCNAction.removeFromParentNode()
            ]))
            ringNodes[key] = nil
        }
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

    /// Places the camera above and toward the player so that -row reads as "up
    /// the screen" and +col reads as "right".
    private func aimCamera(board: BoardModel) {
        let cx = Double(board.width - 1) / 2.0
        let cz = Double(board.height - 1) / 2.0
        let span = Double(max(board.width, board.height))
        cameraNode.position = v3(cx, span * 1.15, cz + span * 1.15)
        cameraNode.look(at: v3(cx, 0, cz))
    }

    // MARK: - Geometry

    private func worldPosition(col: Int, row: Int) -> SCNVector3 {
        v3(Double(col), Double(cubeSize) / 2.0, Double(row))
    }

    /// SCNBox exposes materials in the order front(+Z), right(+X), back(-Z),
    /// left(-X), top(+Y), bottom(-Y). Assigning palette colours in that order
    /// matches the logical CubeState face colours.
    ///
    /// Structure:
    ///   cube (container — this is what rolls / gets positioned & baked)
    ///     art (breathing wobble applied here, so it never disturbs the roll
    ///          transform the game logic reads from the container)
    ///       body  — chamfered SCNBox tinted per face with the accent colours
    ///       decal×6 — an explicitly-oriented plane per face carrying the glyph
    ///
    /// Using oriented decal planes (rather than textures on the SCNBox faces)
    /// gives precise control of each glyph's "up" direction, sidestepping
    /// SCNBox's per-face UV quirks.
    private func makeCubeNode(colors: [Face: Int]) -> SCNNode {
        let container = SCNNode()
        container.name = "cube"

        let art = SCNNode()
        art.name = "cubeArt"
        container.addChildNode(art)

        // Body: accent colour per face.
        let box = SCNBox(width: cubeSize, height: cubeSize, length: cubeSize,
                         chamferRadius: cubeSize * 0.06)
        let order: [Face] = [.front, .right, .back, .left, .up, .down]
        box.materials = order.map { face in
            let color = GamePalette.color(colors[face] ?? 0)
            let m = SCNMaterial()
            m.diffuse.contents = color
            m.emission.contents = color.withAlphaComponent(0.10)
            m.roughness.contents = 0.5
            m.metalness.contents = 0.0
            return m
        }
        let bodyNode = SCNNode(geometry: box)
        bodyNode.castsShadow = true
        art.addChildNode(bodyNode)

        // Glyph decals, one oriented plane per face.
        let half = Double(cubeSize) / 2.0 + 0.004   // proud of the face, avoids z-fighting
        for face in Face.allCases {
            let plane = SCNPlane(width: cubeSize * 0.86, height: cubeSize * 0.86)
            let m = SCNMaterial()
            m.diffuse.contents = SymbolTextures.decal(colors[face] ?? 0)
            m.isDoubleSided = false
            plane.firstMaterial = m
            let decal = SCNNode(geometry: plane)
            decal.castsShadow = false
            let (pos, euler) = decalPlacement(face, offset: half)
            decal.position = pos
            decal.eulerAngles = euler
            art.addChildNode(decal)
        }

        // Idle "breathing" wobble — a slow, gentle scale pulse.
        let breathe = SCNAction.sequence([
            easedScale(to: 1.03, duration: 1.6),
            easedScale(to: 1.0, duration: 1.6)
        ])
        art.runAction(SCNAction.repeatForever(breathe))

        return container
    }

    private func easedScale(to scale: CGFloat, duration: TimeInterval) -> SCNAction {
        let a = SCNAction.scale(to: scale, duration: duration)
        a.timingMode = .easeInEaseOut
        return a
    }

    /// Position + Euler angles that place a decal plane (default normal +Z,
    /// up +Y) flat on the given cube face, with its "up" chosen so the glyph
    /// reads naturally (e.g. the top face's up points away from the camera).
    private func decalPlacement(_ face: Face, offset h: Double) -> (SCNVector3, SCNVector3) {
        let q = Double.pi / 2
        switch face {
        case .front: return (v3(0, 0,  h), v3(0, 0, 0))
        case .back:  return (v3(0, 0, -h), v3(0, .pi, 0))
        case .right: return (v3( h, 0, 0), v3(0,  q, 0))
        case .left:  return (v3(-h, 0, 0), v3(0, -q, 0))
        case .up:    return (v3(0,  h, 0), v3(-q, 0, 0))
        case .down:  return (v3(0, -h, 0), v3( q, 0, 0))
        }
    }

    private func buildBoard(_ board: BoardModel) {
        let tileThickness: CGFloat = 0.12
        let gap: CGFloat = 0.06
        let size = cubeSize - gap

        for row in 0..<board.height {
            for col in 0..<board.width {
                let cell = board.cells[row][col]
                let box = SCNBox(width: size, height: tileThickness,
                                 length: size, chamferRadius: 0.03)
                let mat = SCNMaterial()
                if let target = cell.target {
                    // Show the depiction the player must land face-down here.
                    mat.diffuse.contents = SymbolTextures.tile(target)
                    mat.emission.contents = GamePalette.color(target).withAlphaComponent(0.10)
                } else {
                    mat.diffuse.contents = GamePalette.neutralTile
                }
                mat.roughness.contents = 0.85
                box.firstMaterial = mat

                let tile = SCNNode(geometry: box)
                tile.position = v3(Double(col), -Double(tileThickness) / 2.0, Double(row))
                boardNode.addChildNode(tile)
                tileNodes["\(col),\(row)"] = tile

                if let target = cell.target {
                    let highlight = makeHighlight(index: target)
                    highlight.position = v3(Double(col), 0.02, Double(row))
                    boardNode.addChildNode(highlight)
                    ringNodes["\(col),\(row)"] = highlight
                }
            }
        }
    }

    /// A flat, pulsing square frame that hovers just above an unsolved target
    /// tile. A frame (not a ring) so it never reads as the "ring" cat face.
    private func makeHighlight(index: Int) -> SCNNode {
        let plane = SCNPlane(width: cubeSize * 0.96, height: cubeSize * 0.96)
        let mat = SCNMaterial()
        mat.diffuse.contents = SymbolTextures.frame(index)
        mat.emission.contents = SymbolTextures.frame(index)   // self-lit so it glows
        mat.isDoubleSided = true
        mat.blendMode = .add
        plane.firstMaterial = mat

        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2                         // lay flat on the board
        node.opacity = 0.9
        node.runAction(SCNAction.repeatForever(SCNAction.sequence([
            SCNAction.group([
                SCNAction.scale(to: 1.08, duration: 0.9),
                SCNAction.fadeOpacity(to: 0.55, duration: 0.9)
            ]),
            SCNAction.group([
                SCNAction.scale(to: 1.0, duration: 0.9),
                SCNAction.fadeOpacity(to: 0.9, duration: 0.9)
            ])
        ])))
        return node
    }

    // MARK: - Roll geometry (SceneKit-specific mapping of RollDirection)

    /// Offset (relative to the cube centre, edge length 1) of the bottom edge
    /// the cube pivots around.
    private func pivotOffset(_ d: RollDirection) -> SCNVector3 {
        switch d {
        case .right:   return v3( 0.5, -0.5,  0.0)
        case .left:    return v3(-0.5, -0.5,  0.0)
        case .forward: return v3( 0.0, -0.5, -0.5)
        case .back:    return v3( 0.0, -0.5,  0.5)
        }
    }

    /// Rotation axis + signed angle for a 90° roll.
    private func rotation(_ d: RollDirection) -> (axis: SCNVector3, angle: CGFloat) {
        let quarter = CGFloat.pi / 2
        switch d {
        case .right:   return (v3(0, 0, 1), -quarter)
        case .left:    return (v3(0, 0, 1),  quarter)
        case .forward: return (v3(1, 0, 0), -quarter)
        case .back:    return (v3(1, 0, 0),  quarter)
        }
    }
}
