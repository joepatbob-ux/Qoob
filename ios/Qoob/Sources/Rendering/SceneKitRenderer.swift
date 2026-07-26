//
//  SceneKitRenderer.swift
//  Qoob
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
        // Forward mode so the cat casts a real, soft shadow onto the carpet/
        // floor (deferred is a screen-space overlay and reads flatter).
        key.light!.shadowMode = .forward
        key.light!.shadowColor = UIColor(white: 0, alpha: 0.34)
        key.light!.shadowRadius = 8            // soft penumbra
        key.light!.shadowSampleCount = 16      // smooth edges
        key.light!.shadowMapSize = CGSize(width: 2048, height: 2048)
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

        if let model = loadCubeModel() {
            // A supplied 3D model. It must already depict the six faces in the
            // layout from Level.startingFaces (front = face, up = butt, …), so
            // the rolling logic and the visible faces stay in agreement.
            model.castsShadow = true
            art.addChildNode(model)
        } else {
            buildProceduralCube(colors: colors, on: art)
        }

        // Idle "breathing" wobble — a slow, gentle scale pulse.
        let breathe = SCNAction.sequence([
            easedScale(to: 1.03, duration: 1.6),
            easedScale(to: 1.0, duration: 1.6)
        ])
        art.runAction(SCNAction.repeatForever(breathe))

        return container
    }

    /// The procedural cube-cat: a chamfered box tinted per face + oriented
    /// glyph/art decals. Used when no 3D model is supplied.
    private func buildProceduralCube(colors: [Face: Int], on art: SCNNode) {
        let box = SCNBox(width: cubeSize, height: cubeSize, length: cubeSize,
                         chamferRadius: cubeSize * 0.06)
        let order: [Face] = [.front, .right, .back, .left, .up, .down]
        box.materials = order.map { bodyMaterial(colors[$0] ?? 0) }
        let bodyNode = SCNNode(geometry: box)
        bodyNode.castsShadow = true
        art.addChildNode(bodyNode)

        let half = Double(cubeSize) / 2.0 + 0.004   // proud of the face, avoids z-fighting
        for face in Face.allCases {
            let index = colors[face] ?? 0
            let plane = SCNPlane(width: cubeSize * 0.86, height: cubeSize * 0.86)
            let m = SCNMaterial()
            m.diffuse.contents = BundledTextures.faceArt(index) ?? SymbolTextures.decal(index)
            m.isDoubleSided = false
            plane.firstMaterial = m
            let decal = SCNNode(geometry: plane)
            decal.castsShadow = false
            let (pos, euler) = decalPlacement(face, offset: half)
            decal.position = pos
            decal.eulerAngles = euler
            art.addChildNode(decal)
        }
    }

    /// Loads `cube_cat.usdz` from the bundle if present, normalised to fit a
    /// unit cube centred at the origin. Returns nil (→ procedural cube) if the
    /// model isn't bundled. Drop `cube_cat.usdz` into the project to use it.
    private func loadCubeModel() -> SCNNode? {
        let exts = ["usdz", "usdc", "scn"]
        var scene: SCNScene?
        for ext in exts {
            if let url = Bundle.main.url(forResource: "cube_cat", withExtension: ext) {
                scene = try? SCNScene(url: url, options: nil)
                if scene != nil { break }
            }
        }
        guard let loaded = scene else { return nil }

        let flat = loaded.rootNode.flattenedClone()
        let (minB, maxB) = flat.boundingBox
        let dx = maxB.x - minB.x, dy = maxB.y - minB.y, dz = maxB.z - minB.z
        let maxDim = max(dx, max(dy, dz))
        guard maxDim > 0 else { return nil }

        let s = Float(cubeSize) / maxDim
        flat.scale = SCNVector3(s, s, s)
        flat.position = SCNVector3(-(minB.x + maxB.x) / 2 * s,
                                   -(minB.y + maxB.y) / 2 * s,
                                   -(minB.z + maxB.z) / 2 * s)
        let holder = SCNNode()
        holder.addChildNode(flat)
        return holder
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

    // MARK: - Materials & tiling

    /// Cube-body material for one face: fur (tinted by the face's accent
    /// colour) if the texture exists, otherwise a flat accent colour.
    private func bodyMaterial(_ index: Int) -> SCNMaterial {
        let accent = GamePalette.color(index)
        let m = SCNMaterial()
        if let fur = BundledTextures.fur {
            m.diffuse.contents = fur
            m.multiply.contents = accent               // tint the grey fur per face
            setTiling(m.diffuse, SCNMatrix4MakeScale(1.5, 1.5, 1))
            if let n = BundledTextures.furNormal {
                m.normal.contents = n
                setTiling(m.normal, SCNMatrix4MakeScale(1.5, 1.5, 1))
            }
            m.roughness.contents = 0.9
        } else {
            m.diffuse.contents = accent
            m.roughness.contents = 0.5
        }
        m.emission.contents = accent.withAlphaComponent(0.08)
        m.metalness.contents = 0.0
        return m
    }

    private func setTiling(_ prop: SCNMaterialProperty, _ transform: SCNMatrix4) {
        prop.wrapS = .repeat
        prop.wrapT = .repeat
        prop.contentsTransform = transform
    }

    /// A carpet ground plane under the whole board (or a subtle flat colour).
    private func addGround(_ board: BoardModel) {
        let extent = Double(max(board.width, board.height)) + 6
        let plane = SCNPlane(width: CGFloat(extent), height: CGFloat(extent))
        let m = SCNMaterial()
        if let carpet = BundledTextures.carpet {
            m.diffuse.contents = carpet
            setTiling(m.diffuse, SCNMatrix4MakeScale(Float(extent), Float(extent), 1))
            if let n = BundledTextures.carpetNormal {
                m.normal.contents = n
                setTiling(m.normal, SCNMatrix4MakeScale(Float(extent), Float(extent), 1))
            }
            m.roughness.contents = 0.95
        } else {
            m.diffuse.contents = GamePalette.background
            m.roughness.contents = 1.0
        }
        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2
        node.position = v3(Double(board.width - 1) / 2.0,
                           -Double(tileThickness) - 0.02,
                           Double(board.height - 1) / 2.0)
        node.castsShadow = false
        boardNode.addChildNode(node)
    }

    private let tileThickness: CGFloat = 0.12

    private func buildBoard(_ board: BoardModel) {
        addGround(board)
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
                    mat.roughness.contents = 0.85
                } else if let carpet = BundledTextures.carpet {
                    // Continuous carpet across cells: offset each tile's UVs by
                    // its grid coords so the (seamless) pattern flows unbroken.
                    let uv = SCNMatrix4MakeTranslation(Float(col), Float(row), 0)
                    mat.diffuse.contents = carpet
                    setTiling(mat.diffuse, uv)
                    if let n = BundledTextures.carpetNormal {
                        mat.normal.contents = n
                        setTiling(mat.normal, uv)
                    }
                    mat.roughness.contents = 0.95
                } else {
                    mat.diffuse.contents = GamePalette.neutralTile
                    mat.roughness.contents = 0.85
                }
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
