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
import QuartzCore

@MainActor
final class SceneKitRenderer: NSObject, GameRenderer {

    /// The view SwiftUI embeds. Owned by the renderer.
    let view = SCNView()

    private let scene = SCNScene()
    private let cameraNode = SCNNode()

    private var boardNode = SCNNode()
    private var cubeNode = SCNNode()
    /// The cube's deformable art node (child of `cubeNode`); soft-body + fur
    /// attach here. Never read by game logic.
    private var cubeArtNode = SCNNode()

    // MARK: Visual-polish layer (purely cosmetic; see Environment/ + these
    // controllers). Centralized so all environmental animation shares one loop.
    private let qoob = QoobVisualController()
    private let effects = EnvironmentEffectsController()
    private var effectsLink: CADisplayLink?
    private var lastEffectsTime: CFTimeInterval = 0

    /// Tile nodes + their glow rings, keyed by "col,row" for the clear flourish.
    private var tileNodes: [String: SCNNode] = [:]
    private var ringNodes: [String: SCNNode] = [:]

    /// Pushable toy nodes keyed by their current cell; the goal cells.
    private var itemNodes: [GridCell: SCNNode] = [:]
    private var itemGoalCells: Set<GridCell> = []
    /// Perched (knock-off) toy nodes keyed by their furniture cell.
    private var perchedNodes: [GridCell: SCNNode] = [:]

    /// Current environment theme (floor / backdrop / furniture set).
    private var environment: Environment = .livingRoom

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
        startEffectsLink()
    }

    // MARK: - GameRenderer

    func present(level: Level, board: BoardModel, cube: CubeState) {
        boardNode.removeFromParentNode()
        cubeNode.removeFromParentNode()
        tileNodes.removeAll()
        ringNodes.removeAll()
        itemNodes.removeAll()
        perchedNodes.removeAll()
        itemGoalCells = Set(level.itemGoals)

        environment = level.environment
        view.backgroundColor = environment.background

        boardNode = SCNNode()
        buildBoard(board)
        buildFurniture(level)
        buildItems(level)
        buildPerched(level)
        effects.buildVegetation(level: level, board: board, into: boardNode)
        scene.rootNode.addChildNode(boardNode)

        cubeNode = makeCubeNode(colors: cube.colors)
        cubeNode.position = worldPosition(col: cube.col, row: cube.row)
        scene.rootNode.addChildNode(cubeNode)

        // Bind the cosmetic soft-body + fur to the freshly built cube.
        qoob.attach(container: cubeNode, art: cubeArtNode)
        effects.attachFur(container: cubeNode, art: cubeArtNode, cubeSize: cubeSize)

        aimCamera(board: board)
    }

    func animateRoll(_ direction: RollDirection,
                     to target: GridCell,
                     duration: TimeInterval,
                     completion: @escaping () -> Void) {

        // Kick off Qoob's soft-body squash/rebound, timed to this roll. Purely
        // cosmetic — it only touches the art node, never the roll transform.
        qoob.beginRoll(duration: duration)

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

    func moveItem(from: GridCell, to: GridCell, duration: TimeInterval) {
        guard let node = itemNodes[from] else { return }
        itemNodes[from] = nil
        itemNodes[to] = node

        let dest = itemPosition(col: to.col, row: to.row)
        let slide = SCNAction.move(to: dest, duration: duration)
        slide.timingMode = .easeInEaseOut
        // A little roll as it slides, for life.
        let rollAxis = v3(Double(to.row - from.row), 0, Double(from.col - to.col))
        let spin = SCNAction.rotate(by: .pi, around: rollAxis, duration: duration)
        node.runAction(SCNAction.group([slide, spin]))

        if itemGoalCells.contains(to) {
            node.geometry?.firstMaterial?.emission.contents =
                UIColor(white: 1, alpha: 0.35)
        } else {
            node.geometry?.firstMaterial?.emission.contents = UIColor.black
        }
    }

    func knockOffToy(fromFurnitureAt perch: GridCell, to landing: GridCell, duration: TimeInterval) {
        guard let node = perchedNodes[perch] else { return }
        perchedNodes[perch] = nil
        itemNodes[landing] = node    // it's now a normal pushable toy

        let dest = itemPosition(col: landing.col, row: landing.row)
        let fall = SCNAction.move(to: dest, duration: duration)
        fall.timingMode = .easeIn    // accelerate as it tumbles off
        let axis = v3(Double(landing.row - perch.row), 0, Double(perch.col - landing.col))
        let tumble = SCNAction.rotate(by: 2 * .pi, around: axis, duration: duration)
        let bounce = SCNAction.sequence([
            SCNAction.scale(to: 1.15, duration: 0.06),
            SCNAction.scale(to: 1.0, duration: 0.10)
        ])
        node.runAction(SCNAction.sequence([SCNAction.group([fall, tumble]), bounce]))

        if itemGoalCells.contains(landing) {
            node.geometry?.firstMaterial?.emission.contents = UIColor(white: 1, alpha: 0.35)
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

    /// Near top-down camera looking down at the living-room floor.
    /// `topDownTilt` is how far off straight-down the view leans (0 = perfectly
    /// overhead; a small tilt gives furniture some dimension and avoids the
    /// look-at gimbal at exact vertical). -row reads as "up the screen",
    /// +col as "right".
    private let topDownTilt = 0.22   // radians (~12.5°); raise for more angle

    private func aimCamera(board: BoardModel) {
        let cx = Double(board.width - 1) / 2.0
        let cz = Double(board.height - 1) / 2.0
        let span = Double(max(board.width, board.height))
        let height = span * 2.0
        let zOffset = height * tan(topDownTilt)   // small lean toward the player
        cameraNode.camera?.fieldOfView = 52
        cameraNode.position = v3(cx, height, cz + zOffset)
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
    ///     art (soft-body squash/rebound + idle breathing are applied here by
    ///          QoobVisualController, so they never disturb the roll transform
    ///          the game logic reads from the container)
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
        // Hand the art node to the soft-body controller, which now owns all of
        // its scale animation (idle breathing + roll squash/rebound), replacing
        // the old inline breathe action so the two never fight.
        cubeArtNode = art

        if let model = loadCubeModel() {
            // A supplied 3D model. It must already depict the six faces in the
            // layout from Level.startingFaces (front = face, up = butt, …), so
            // the rolling logic and the visible faces stay in agreement.
            model.castsShadow = true
            art.addChildNode(model)
        } else {
            buildProceduralCube(colors: colors, on: art)
        }

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

    /// The floor texture for the current environment: a per-environment floor
    /// PNG if supplied, else the global carpet, else nil (→ flat colour).
    private func floorTexture() -> UIImage? {
        BundledTextures.image(environment.floorTextureName) ?? BundledTextures.carpet
    }

    /// A ground plane under the whole board: floor texture if supplied, else
    /// the environment's ground colour.
    private func addGround(_ board: BoardModel) {
        let extent = Double(max(board.width, board.height)) + 6
        let plane = SCNPlane(width: CGFloat(extent), height: CGFloat(extent))
        let m = SCNMaterial()
        if let tex = floorTexture() {
            m.diffuse.contents = tex
            setTiling(m.diffuse, SCNMatrix4MakeScale(Float(extent), Float(extent), 1))
            m.roughness.contents = 0.95
        } else {
            m.diffuse.contents = environment.groundColor
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

    /// Draws each furniture obstacle: a bundled model if provided (e.g.
    /// sofa.usdz), else a simple stylised placeholder box sized to its
    /// footprint.
    private func buildFurniture(_ level: Level) {
        for piece in level.furniture {
            let node = furnitureModel(piece) ?? placeholderFurniture(piece)
            node.position = v3(piece.centerCol, 0, piece.centerRow)
            boardNode.addChildNode(node)
        }
    }

    private func placeholderFurniture(_ piece: Furniture) -> SCNNode {
        let margin: CGFloat = 0.12
        let w = CGFloat(piece.cols) * cubeSize - margin
        let d = CGFloat(piece.rows) * cubeSize - margin
        let h = piece.kind.height

        let box = SCNBox(width: w, height: h, length: d, chamferRadius: 0.08)
        let mat = SCNMaterial()
        mat.diffuse.contents = piece.kind.color
        mat.roughness.contents = 0.9
        box.firstMaterial = mat

        let node = SCNNode(geometry: box)
        node.position = v3(0, Double(h) / 2.0, 0)     // sit on the floor
        node.castsShadow = true

        let holder = SCNNode()
        holder.addChildNode(node)

        // A soft back cushion on pieces that have one, along the long edge.
        if piece.kind.hasBack {
            let backThick: CGFloat = 0.2
            let along = piece.cols >= piece.rows          // long axis is X?
            let back = SCNBox(width: along ? w : backThick,
                              height: h * 0.9,
                              length: along ? backThick : d,
                              chamferRadius: 0.06)
            let bm = SCNMaterial()
            bm.diffuse.contents = piece.kind.color.withAlphaComponent(0.85)
            bm.roughness.contents = 0.9
            back.firstMaterial = bm
            let backNode = SCNNode(geometry: back)
            let edge = Double((along ? d : w) / 2.0) - Double(backThick) / 2.0
            backNode.position = along ? v3(0, Double(h) * 0.65, -edge)
                                      : v3(-edge, Double(h) * 0.65, 0)
            backNode.castsShadow = true
            holder.addChildNode(backNode)
        }
        return holder
    }

    /// Loads `<kind>.usdz/.usdc/.scn` if bundled, scaled to the footprint.
    private func furnitureModel(_ piece: Furniture) -> SCNNode? {
        let base = piece.kind.modelBaseName
        var scene: SCNScene?
        for ext in ["usdz", "usdc", "scn"] {
            if let url = Bundle.main.url(forResource: base, withExtension: ext) {
                scene = try? SCNScene(url: url, options: nil)
                if scene != nil { break }
            }
        }
        guard let loaded = scene else { return nil }
        let flat = loaded.rootNode.flattenedClone()
        let (minB, maxB) = flat.boundingBox
        let dx = maxB.x - minB.x, dz = maxB.z - minB.z
        let targetW = Float(CGFloat(piece.cols) * cubeSize - 0.12)
        let targetD = Float(CGFloat(piece.rows) * cubeSize - 0.12)
        guard dx > 0, dz > 0 else { return nil }
        let s = min(targetW / dx, targetD / dz)
        flat.scale = SCNVector3(s, s, s)
        // Rest on the floor, centred on X/Z.
        flat.position = SCNVector3(-(minB.x + maxB.x) / 2 * s,
                                   -minB.y * s,
                                   -(minB.z + maxB.z) / 2 * s)
        let holder = SCNNode()
        holder.addChildNode(flat)
        return holder
    }

    // MARK: - Pushable toys

    private let toyRadius: CGFloat = 0.28

    private func itemPosition(col: Int, row: Int) -> SCNVector3 {
        v3(Double(col), Double(toyRadius), Double(row))
    }

    private func buildItems(_ level: Level) {
        for goal in level.itemGoals {
            let pad = makeItemGoalPad()
            pad.position = v3(Double(goal.col), 0.03, Double(goal.row))
            boardNode.addChildNode(pad)
        }
        for cell in level.items {
            let toy = makeToy()
            toy.position = itemPosition(col: cell.col, row: cell.row)
            boardNode.addChildNode(toy)
            itemNodes[cell] = toy
        }
    }

    /// Toys perched on top of furniture, ready to be knocked off.
    private func buildPerched(_ level: Level) {
        for p in level.perched {
            let h = furnitureHeight(at: p.perch, in: level)
            let toy = makeToy()
            toy.position = v3(Double(p.perch.col), Double(h) + Double(toyRadius), Double(p.perch.row))
            boardNode.addChildNode(toy)
            perchedNodes[p.perch] = toy
        }
    }

    private func furnitureHeight(at cell: GridCell, in level: Level) -> CGFloat {
        for piece in level.furniture where piece.cells.contains(cell) {
            return piece.kind.height
        }
        return 0
    }

    /// A yarn-ball toy the cat pushes.
    private func makeToy() -> SCNNode {
        let ball = SCNSphere(radius: toyRadius)
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(red: 0.86, green: 0.30, blue: 0.42, alpha: 1) // yarn red
        m.roughness.contents = 0.8
        ball.firstMaterial = m
        let node = SCNNode(geometry: ball)
        node.castsShadow = true
        return node
    }

    /// A glowing floor pad marking where a toy should be pushed.
    private func makeItemGoalPad() -> SCNNode {
        let disc = SCNCylinder(radius: toyRadius * 1.25, height: 0.03)
        let m = SCNMaterial()
        m.diffuse.contents = UIColor.white.withAlphaComponent(0.15)
        m.emission.contents = UIColor(red: 0.95, green: 0.85, blue: 0.45, alpha: 0.55)
        disc.firstMaterial = m
        let node = SCNNode(geometry: disc)   // cylinder axis is Y → already flat
        node.castsShadow = false
        node.runAction(SCNAction.repeatForever(SCNAction.sequence([
            SCNAction.fadeOpacity(to: 0.55, duration: 0.9),
            SCNAction.fadeOpacity(to: 1.0, duration: 0.9)
        ])))
        return node
    }

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
                } else if let tex = floorTexture() {
                    // Continuous floor across cells: offset each tile's UVs by
                    // its grid coords so the (seamless) pattern flows unbroken.
                    let uv = SCNMatrix4MakeTranslation(Float(col), Float(row), 0)
                    mat.diffuse.contents = tex
                    setTiling(mat.diffuse, uv)
                    if let n = BundledTextures.carpetNormal {
                        mat.normal.contents = n
                        setTiling(mat.normal, uv)
                    }
                    mat.roughness.contents = 0.95
                } else {
                    mat.diffuse.contents = environment.floorColor
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

    // MARK: - Environmental effects loop (centralized)

    /// One display link drives ALL cosmetic environmental animation — Qoob's
    /// soft-body/breathing, fur, and grass — so there is never a per-object
    /// timer. It is separate from the game's own loop and carries no game logic.
    private func startEffectsLink() {
        let link = CADisplayLink(target: self, selector: #selector(stepEffects))
        link.add(to: .main, forMode: .common)
        effectsLink = link
        lastEffectsTime = CACurrentMediaTime()
    }

    @objc private func stepEffects() {
        let now = CACurrentMediaTime()
        var dt = now - lastEffectsTime
        lastEffectsTime = now
        if dt < 0 { dt = 0 }
        if dt > 0.1 { dt = 0.1 }   // clamp after stalls / backgrounding

        qoob.update(dt: dt)
        // Track the cube's live (possibly mid-roll) position for grass reaction.
        let cubePos = cubeNode.parent != nil ? cubeNode.presentation.worldPosition : nil
        effects.update(dt: dt, cubeWorldPosition: cubePos)
    }

    /// Pause/resume environmental processing (e.g. when the scene is off screen).
    func setEnvironmentActive(_ active: Bool) {
        effectsLink?.isPaused = !active
        if active { lastEffectsTime = CACurrentMediaTime() }
    }

    deinit { effectsLink?.invalidate() }
}
