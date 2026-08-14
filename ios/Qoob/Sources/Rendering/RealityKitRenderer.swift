//
//  RealityKitRenderer.swift
//  Qoob
//
//  The RealityKit implementation of GameRenderer. All RealityKit knowledge lives
//  here: the ARView (non-AR / fully virtual), entity graph, camera, lighting,
//  tile + cube geometry, the pivot-edge roll animation, and the tile-cleared
//  flourish. It mirrors SceneKitRenderer section-for-section so the two are easy
//  to compare.
//
//  The game core is unaffected — this type conforms to GameRenderer and nothing
//  in Core/ or GameController changes. SceneKit's SCNAction is replaced by the
//  per-frame `FrameAnimator` (see RealityKitHelpers.swift); simple eased moves
//  use RealityKit's built-in `move(to:relativeTo:duration:timingFunction:)`.
//

import RealityKit
import ARKit
import UIKit
import Metal

@MainActor
final class RealityKitRenderer: NSObject, GameRenderer {

    /// The view SwiftUI embeds. Owned by the renderer.
    let view: ARView

    /// World anchor everything hangs off. Grid coordinates == world coordinates
    /// because this anchor sits at the origin with identity transform.
    private let root = AnchorEntity(world: .zero)
    private let cameraEntity = Entity()
    private let keyLight = Entity()
    private let fillLight = Entity()

    private var boardAnchor = Entity()
    private var cubeEntity = Entity()
    private var cubeArt = Entity()

    /// Tile entities + their glow highlights, keyed by "col,row".
    private var tileEntities: [String: ModelEntity] = [:]
    private var ringEntities: [String: Entity] = [:]

    /// Pushable toy entities keyed by their current cell; the goal cells.
    private var itemEntities: [GridCell: Entity] = [:]
    private var itemGoalCells: Set<GridCell> = []
    /// Perched (knock-off) toy entities keyed by their furniture cell.
    private var perchedEntities: [GridCell: Entity] = [:]

    /// Current environment theme (floor / backdrop / furniture set).
    private var environment: Environment = .livingRoom

    /// Player-selected floor style (Settings). `.default` uses the environment.
    private var floorTheme: FloorTheme = .default
    /// The ground plane under the board, kept so the floor can be re-skinned.
    private var groundEntity: ModelEntity?

    /// Board dimensions + camera lean, kept so the camera can be re-aimed live.
    private var boardCols = 1
    private var boardRows = 1
    private var boardTiltRadians: Double = 0

    /// Cube edge length in world units.
    private let cubeSize: Float = 1.0
    private let tileThickness: Float = 0.12
    private let toyRadius: Float = 0.28

    private let animator = FrameAnimator()

    /// Wind-driven cosmetic effects (fur, grass, Qoob's soft-body). Runs on its
    /// own per-frame loop; pause it with `setEnvironmentActive`.
    private let effects = RealityKitEnvironmentEffects()

    var viewportAspect: Double {
        let size = view.bounds.size
        guard size.width > 1, size.height > 1 else { return 0.46 }
        return Double(size.width / size.height)
    }

    override init() {
        view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        super.init()
        view.environment.background = .color(GamePalette.background)
        view.renderOptions.insert(.disableCameraGrain)
        view.scene.addAnchor(root)
        root.addChild(cameraEntity)
        setupCamera()
        setupLighting()
        animator.attach(to: view)
        effects.attach(to: view)
    }

    // MARK: - GameRenderer

    func present(level: Level, board: BoardModel, cube: CubeState) {
        animator.reset()
        // Retire any roll still in flight: its deferred bake would otherwise
        // land on the *new* cube and teleport it to the old roll's target cell,
        // and its pivot would be orphaned in the scene.
        rollGeneration &+= 1
        rollPivot?.removeFromParent()
        rollPivot = nil

        boardAnchor.removeFromParent()
        cubeEntity.removeFromParent()
        tileEntities.removeAll()
        ringEntities.removeAll()
        itemEntities.removeAll()
        perchedEntities.removeAll()
        itemGoalCells = Set(level.itemGoals)

        environment = level.environment
        view.environment.background = .color(environment.background)

        boardAnchor = Entity()
        root.addChild(boardAnchor)
        buildBoard(board)
        buildFurniture(level)
        buildItems(level)
        buildPerched(level)

        cubeEntity = makeCubeNode(colors: cube.colors)
        cubeEntity.position = worldPosition(col: cube.col, row: cube.row)
        root.addChild(cubeEntity)

        boardCols = board.width
        boardRows = board.height
        aimCamera()

        effects.rebuild(level: level, board: board,
                        cubeContainer: cubeEntity, cubeArt: cubeArt,
                        boardAnchor: boardAnchor, cubeSize: cubeSize)
    }

    func animateRoll(_ direction: RollDirection,
                     to target: GridCell,
                     duration: TimeInterval,
                     completion: @escaping () -> Void) {

        effects.beginRoll(duration: duration)
        let offset = pivotOffset(direction)
        let pivot = Entity()
        pivot.position = cubeEntity.position + offset
        root.addChild(pivot)

        // Re-parent the cube under the pivot, preserving world transform, so
        // rotating the pivot swings the cube around its bottom edge.
        cubeEntity.setParent(pivot, preservingWorldTransform: true)

        let (axis, angle) = rollRotation(direction)
        var dest = pivot.transform
        dest.rotation = quat(angle, axis) * pivot.transform.rotation
        pivot.move(to: dest, relativeTo: pivot.parent, duration: duration,
                   timingFunction: .easeInOut)

        rollGeneration &+= 1
        rollPivot = pivot
        let generation = rollGeneration

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.rollGeneration == generation else { return }
            // Bake back onto the root and snap to the exact grid centre to avoid
            // floating-point drift over many rolls.
            self.cubeEntity.setParent(self.root, preservingWorldTransform: true)
            pivot.removeFromParent()
            self.rollPivot = nil
            self.cubeEntity.position = self.worldPosition(col: target.col, row: target.row)
            completion()
        }
    }

    /// Bumped whenever a roll starts or the scene is rebuilt, so a roll's
    /// deferred bake can tell whether it's still the current one.
    private var rollGeneration: UInt64 = 0
    /// The pivot the in-flight roll swings around, held so a rebuild can remove
    /// it instead of leaving it orphaned under `root`.
    private var rollPivot: Entity?

    func clearTile(col: Int, row: Int, colorIndex: Int) {
        let key = "\(col),\(row)"
        let color = GamePalette.color(colorIndex)

        if let tile = tileEntities[key] {
            // Flash the depiction, pop it up, then dissolve back to plain floor.
            if var mat = tile.model?.materials.first as? PhysicallyBasedMaterial {
                mat.emissiveColor = .init(color: color)
                mat.emissiveIntensity = 0.6
                tile.model?.materials = [mat]
            }
            let base = tile.position
            animator.run(tile, duration: 0.30, ease: .linear, step: { e, t in
                e.position = base + f3(0, Double(sin(Double(t) * .pi) * 0.10), 0)
            }, completion: { [weak self, weak tile] in
                guard let self, let tile else { return }
                tile.position = base
                tile.model?.materials = [self.neutralTileMaterial(col: col, row: row)]
            })
        }
        if let ring = ringEntities[key] {
            let base = ring.scale
            animator.run(ring, duration: 0.35, ease: .easeOut, step: { e, t in
                e.scale = base * (1 + 0.8 * t)
                setUnlitOpacity(e, 1 - t)
            }, completion: { [weak ring] in ring?.removeFromParent() })
            ringEntities[key] = nil
        }
    }

    func addTarget(col: Int, row: Int, colorIndex: Int) {
        let key = "\(col),\(row)"
        if let tile = tileEntities[key] {
            tile.model?.materials = [targetTileMaterial(colorIndex)]
            let base = tile.position
            animator.run(tile, duration: 0.28, ease: .linear, step: { e, t in
                e.position = base + f3(0, Double(sin(Double(t) * .pi) * 0.06), 0)
            }, completion: { [weak tile] in tile?.position = base })
        }
        ringEntities[key]?.removeFromParent()
        addHighlight(col: col, row: row, index: colorIndex)
        if let ring = ringEntities[key] {
            setUnlitOpacity(ring, 0)
            animator.run(ring, duration: 0.3, ease: .easeOut, step: { e, t in
                setUnlitOpacity(e, Float(t) * 0.9)
            })
        }
    }

    func rejectRoll(_ direction: RollDirection) {
        // A small nudge toward the blocked cell, then a settle back — no move.
        let off = pivotOffset(direction)
        let dx = off.x * 0.16
        let dz = off.z * 0.16
        let base = cubeEntity.position
        animator.run(cubeEntity, duration: 0.19, ease: .easeOut, step: { e, t in
            let bump = Float(sin(Double(t) * .pi))
            e.position = base + f3(Double(dx * bump), 0, Double(dz * bump))
        }, completion: { [weak self] in self?.cubeEntity.position = base })
    }

    func moveItem(from: GridCell, to: GridCell, duration: TimeInterval) {
        guard let node = itemEntities[from] else { return }
        itemEntities[from] = nil
        itemEntities[to] = node

        let start = node.position
        let dest = itemPosition(col: to.col, row: to.row)
        // A little roll as it slides, for life.
        let axis = f3(Double(to.row - from.row), 0, Double(from.col - to.col))
        let startRot = node.transform.rotation
        animator.run(node, duration: duration, ease: .inOut, step: { e, t in
            e.position = mix(start, dest, t: SIMD3<Float>(repeating: t))
            e.transform.rotation = quat(.pi * t, axis) * startRot
        })

        setToyGlow(node, on: itemGoalCells.contains(to))
    }

    func knockOffToy(fromFurnitureAt perch: GridCell, to landing: GridCell, duration: TimeInterval) {
        guard let node = perchedEntities[perch] else { return }
        perchedEntities[perch] = nil
        itemEntities[landing] = node    // it's now a normal pushable toy

        let start = node.position
        let dest = itemPosition(col: landing.col, row: landing.row)
        let axis = f3(Double(landing.row - perch.row), 0, Double(perch.col - landing.col))
        let startRot = node.transform.rotation
        // Accelerate as it tumbles off, two full turns, then a small bounce.
        animator.run(node, duration: duration, ease: .easeIn, step: { e, t in
            e.position = mix(start, dest, t: SIMD3<Float>(repeating: t))
            e.transform.rotation = quat(2 * .pi * t, axis) * startRot
        }, completion: { [weak self, weak node] in
            guard let self, let node else { return }
            let settled = node.scale
            self.animator.run(node, duration: 0.16, ease: .easeOut, step: { e, t in
                let s = Float(1 + 0.15 * sin(Double(t) * .pi))
                e.scale = settled * s
            })
            if self.itemGoalCells.contains(landing) { self.setToyGlow(node, on: true) }
        })
    }

    // MARK: - Scene setup

    // RealityKit light intensity is in lux and scales very differently from
    // SceneKit's arbitrary units; these are tuned by eye against the old look.
    private func setupLighting() {
        // 6000 lux is overcast-daylight bright, which flattened the floor into a
        // pale wash and left nothing for the textures to shade against. Indoor
        // levels, with a wider key/fill ratio, give the rooms some depth.
        let key = DirectionalLightComponent(color: warmKey, intensity: 2600)
        keyLight.components.set(key)
        keyLight.components.set(DirectionalLightComponent.Shadow())
        keyLight.look(at: .zero, from: f3(-3, 6, 3), upVector: f3(0, 1, 0), relativeTo: nil)
        root.addChild(keyLight)

        // A soft, cooler fill from the opposite side lifts the shadows (a
        // stand-in for SceneKit's ambient term); no shadow of its own.
        //
        // NOTE: on the Simulator a hard dark wedge appears beside Qoob. It is not
        // a lit shadow — raising this fill doesn't lighten it — but the Simulator
        // failing to compile `meshShadowCasterProgrammableBlending` (it can't read
        // from a rendertarget, which transparent shadow casters need, and our
        // decals are alpha-blended). Needs checking on real hardware before
        // anyone tries to "fix" it in the lighting.
        let fill = DirectionalLightComponent(color: coolFill, intensity: 900)
        fillLight.components.set(fill)
        fillLight.look(at: .zero, from: f3(4, 5, -3), upVector: f3(0, 1, 0), relativeTo: nil)
        root.addChild(fillLight)
    }

    /// Slightly warm key, slightly cool fill — cheap way to keep a flat top-down
    /// scene from reading as uniformly grey.
    private var warmKey: UIColor { UIColor(red: 1.0, green: 0.96, blue: 0.90, alpha: 1) }
    private var coolFill: UIColor { UIColor(red: 0.80, green: 0.86, blue: 1.0, alpha: 1) }

    private func setupCamera() {
        // The 3-arg init defaults its field-of-view orientation to vertical
        // (the orientation-taking variant is iOS 18+); vertical matches the
        // framing math in `aimCamera`.
        let cam = PerspectiveCameraComponent(near: 0.1, far: 200,
                                             fieldOfViewInDegrees: Float(cameraFOV))
        cameraEntity.components.set(cam)
    }

    private let cameraFOV: Double = 50            // vertical field of view (°)
    // How much of the board the view spans. This used to be 0.92 — the board
    // overflowed the screen on every side for a full-bleed look — but that put
    // the outer ring of cells off screen, and Qoob could roll into it and
    // disappear behind the toolbar. Above 1.0 the whole board fits with a margin
    // of surrounding floor, which also reads more like a room you're looking into.
    private let boardBleed: Double = 1.08

    func setBoardTilt(_ radians: Double) {
        boardTiltRadians = radians
        aimCamera()
    }

    func setEnvironmentActive(_ active: Bool) {
        effects.active = active
    }

    /// Straight top-down camera framing the board to fill the screen edge-to-
    /// edge (see the matching note in SceneKitRenderer). Looking straight down
    /// with up = -Z keeps screen up = -row (up the board).
    private func aimCamera() {
        let cx = Double(boardCols - 1) / 2.0
        let cz = Double(boardRows - 1) / 2.0

        let boardW = Double(boardCols) * boardBleed
        let boardH = Double(boardRows) * boardBleed
        let aspect = viewportAspect > 0 ? viewportAspect : boardW / boardH

        let halfV = tan(cameraFOV * .pi / 180 / 2)
        let hForHeight = boardH / (2 * halfV)
        let hForWidth  = boardW / (2 * halfV * aspect)
        let h = min(hForHeight, hForWidth)

        if boardTiltRadians <= 0.0001 {
            cameraEntity.look(at: f3(cx, 0, cz), from: f3(cx, h, cz),
                              upVector: f3(0, 0, -1), relativeTo: nil)
        } else {
            let zOffset = h * tan(boardTiltRadians)
            cameraEntity.look(at: f3(cx, 0, cz), from: f3(cx, h, cz + zOffset),
                              upVector: f3(0, 1, 0), relativeTo: nil)
        }
    }

    // MARK: - Geometry

    private func worldPosition(col: Int, row: Int) -> SIMD3<Float> {
        f3(Double(col), Double(cubeSize) / 2.0, Double(row))
    }

    /// The cube: a container entity (this is what rolls / gets positioned &
    /// baked) holding an `art` child (breathing wobble applied here so it never
    /// disturbs the roll transform the game logic reads from the container).
    private func makeCubeNode(colors: [Face: Int]) -> Entity {
        let container = Entity()
        container.name = "cube"

        let art = Entity()
        art.name = "cubeArt"
        container.addChild(art)
        cubeArt = art

        if let model = loadCubeModel() {
            // A supplied rounded-cube mesh (plain grey). Overlay the six colour-
            // coded symbol tiles as decals so faces stay readable.
            art.addChild(model)
            addFaceDecals(colors: colors, on: art, colored: true, faceScale: 0.70)
        } else {
            buildProceduralCube(colors: colors, on: art)
        }

        addCatFeatures(colors: colors, on: art)

        // Idle breathing + roll squash are owned by the soft-body effect
        // (RealityKitEnvironmentEffects), which drives this art node's scale.

        // Living shimmer: slowly drift the fur's UVs so highlights play across
        // the strands. A "moving texture" — cheap (UV scroll, no Metal) and
        // simulator-safe. Applies only to the fur (PBR) meshes, not the decals.
        forEachModel(art) { model in
            if model.model?.materials.first is PhysicallyBasedMaterial {
                self.addTextureScroll(model, velocity: SIMD2<Float>(0.015, 0.0))
            }
        }
        return container
    }

    // MARK: - Cat features
    //
    // The bundled `cube_cat.usdz` is a single mesh with one flat material, so
    // none of the cat is in the asset — it's sculpted here instead.
    //
    // Qoob is a genuine cube-cat: every face is sculpted as the body part its
    // symbol depicts, so whichever face lands up is what you see from above —
    // his face, his backside with the tail, four paws in the air, or a smooth
    // flank. Features are welded to the art node, so they roll with him and get
    // squashed by the soft-body effect along with the rest of him.
    //
    // Placement is driven by the symbol map rather than hard-coded to `.front`,
    // so the sculpt always agrees with the decals however `Level.startingFaces`
    // assigns them.

    private func addCatFeatures(colors: [Face: Int], on art: Entity) {
        // Features are tinted a shade deeper than the body. Sculpted in the body's
        // own ivory they separated only by shading, which at this size read as
        // noise; a little tonal contrast makes them legible as form.
        let fur = furMaterial(tint: catMarking)
        let pink = pbr(catPink, roughness: 0.78)

        for face in Face.allCases {
            let symbol = CatSymbol.from(colors[face] ?? 0)

            // Reuse the decal frame: at the face centre, with local +Z pointing
            // out of the face and local +Y as the glyph's "up". Relief is then
            // built in comfortable 2D-ish terms.
            let (position, orientation) = decalPlacement(face, offset: cubeSize / 2)
            let panel = Entity()
            panel.position = position
            panel.orientation = orientation

            switch symbol {
            case .face:     sculptFace(on: panel, fur: fur, pink: pink)
            case .butt:     sculptRump(on: panel, body: furMaterial(), fur: fur, pink: pink)
            case .paws:     sculptPaws(on: panel, pink: pink)
            case .dot, .ring, .triangle:
                break       // flanks stay smooth, so the die still reads as a die
            }
            art.addChild(panel)
        }
    }

    /// The head: two ears at the top corners and a muzzle over the drawn nose.
    /// Relief only — protrusions stay shallow so they read as anatomy rather than
    /// as hardware bolted to a box.
    private func sculptFace(on panel: Entity, fur: PhysicallyBasedMaterial,
                            pink: PhysicallyBasedMaterial) {
        for side in [Float(-1), 1] {
            let ear = Entity()

            let outer = ModelEntity(mesh: .generateBox(width: 0.26, height: 0.30, depth: 0.14,
                                                       cornerRadius: 0.05),
                                    materials: [fur])
            ear.addChild(outer)

            let inner = ModelEntity(mesh: .generateBox(width: 0.13, height: 0.15, depth: 0.05,
                                                       cornerRadius: 0.03),
                                    materials: [pink])
            inner.position = f3(0, 0.01, 0.07)
            ear.addChild(inner)

            // Top corners of the face, splayed outward and leaning out of it.
            ear.position = f3(Double(side) * 0.29, 0.27, 0.03)
            ear.orientation = quat(side * -0.34, f3(0, 0, 1)) * quat(0.30, f3(1, 0, 0))
            panel.addChild(ear)
        }

        // Muzzle: a flattened dome sitting over the glyph's nose.
        let muzzle = ModelEntity(mesh: .generateSphere(radius: 0.11), materials: [pink])
        muzzle.position = f3(0, -0.10, 0.03)
        muzzle.scale = f3(1.5, 0.85, 0.5)
        panel.addChild(muzzle)
    }

    /// The backside: just the tail, curling off the face.
    ///
    /// Haunches were tried here and removed. As broad shallow domes they landed
    /// right on top of the face's glyph and the two competed — the result read as
    /// grey ovals stuck to a pink square rather than as a cat. The tail alone,
    /// against the drawn glyph, says "rear end" immediately.
    private func sculptRump(on panel: Entity, body: PhysicallyBasedMaterial,
                            fur: PhysicallyBasedMaterial, pink: PhysicallyBasedMaterial) {
        // Closely-spaced overlapping segments, so it reads as one continuous curl
        // rather than a dotted line. A tail is meant to extend past the body, so
        // unlike the ears it can protrude freely without looking bolted on.
        let segments = 14
        for i in 0..<segments {
            let t = Float(i) / Float(segments - 1)
            let segment = ModelEntity(mesh: .generateSphere(radius: 0.062 * (1 - 0.5 * t)),
                                      materials: [fur])
            // A hooked curl: out and up, then back over itself, staying near the
            // face plane so the whole length shows from directly above.
            let angle = Double(t) * 2.4
            let reach = Double(0.16 + 0.18 * Double(t))
            segment.position = f3(sin(angle) * reach * 0.9,
                                  0.10 + (1 - cos(angle)) * reach * 0.75,
                                  Double(0.045 + 0.02 * t))
            panel.addChild(segment)
        }

        let pucker = ModelEntity(mesh: .generateSphere(radius: 0.05), materials: [pink])
        pucker.position = f3(0, -0.04, 0.045)
        pucker.scale = f3(1, 1, 0.5)
        panel.addChild(pucker)
    }

    /// Four paw pads, so landing this face up genuinely reads as paws in the air.
    private func sculptPaws(on panel: Entity, pink: PhysicallyBasedMaterial) {
        for (dx, dy) in [(-0.20, -0.16), (0.20, -0.16), (-0.20, 0.22), (0.20, 0.22)] {
            let pad = ModelEntity(mesh: .generateSphere(radius: 0.10), materials: [pink])
            pad.position = f3(dx, dy, 0.02)
            pad.scale = f3(1, 1, 0.45)
            panel.addChild(pad)

            // Toe beans.
            for tx in [-0.09, 0.0, 0.09] {
                let toe = ModelEntity(mesh: .generateSphere(radius: 0.037), materials: [pink])
                toe.position = f3(dx + tx, dy + (tx == 0 ? 0.15 : 0.125), 0.02)
                toe.scale = f3(1, 1, 0.45)
                panel.addChild(toe)
            }
        }
    }

    /// Qoob's coat: a warm ivory body with slightly deeper markings on the
    /// sculpted parts, and pink for the bare skin (inner ear, muzzle, paw pads).
    private var catIvory: UIColor { UIColor(red: 0.90, green: 0.87, blue: 0.81, alpha: 1) }
    private var catMarking: UIColor { UIColor(red: 0.72, green: 0.66, blue: 0.60, alpha: 1) }
    private var catPink: UIColor { UIColor(red: 0.93, green: 0.68, blue: 0.70, alpha: 1) }

    /// The procedural cube-cat: a chamfered box tinted to ivory + oriented
    /// glyph decals. Used when no 3D model is available.
    private func buildProceduralCube(colors: [Face: Int], on art: Entity) {
        let mesh = MeshResource.generateBox(size: cubeSize, cornerRadius: cubeSize * 0.06)
        let body = ModelEntity(mesh: mesh, materials: [furMaterial()])
        art.addChild(body)
        addFaceDecals(colors: colors, on: art, colored: true, faceScale: 0.80)
    }

    /// Places an oriented decal plane on each of the six faces. `colored` uses
    /// the colour-tile depiction (tinted square + white glyph, for a grey mesh);
    /// otherwise a white glyph.
    private func addFaceDecals(colors: [Face: Int], on art: Entity,
                               colored: Bool, faceScale: Float) {
        let half = cubeSize / 2.0 + 0.004    // proud of the face, avoids z-fighting
        for face in Face.allCases {
            let index = colors[face] ?? 0
            let image: UIImage? = colored
                ? SymbolTextures.icon(index)
                : (BundledTextures.faceArt(index) ?? SymbolTextures.decal(index))
            let mesh = MeshResource.generatePlane(width: cubeSize * faceScale,
                                                  height: cubeSize * faceScale)
            let decal = ModelEntity(mesh: mesh, materials: [unlitMaterial(image)])
            let (pos, rot) = decalPlacement(face, offset: half)
            decal.position = pos
            decal.orientation = rot
            art.addChild(decal)
        }
    }

    /// Locates the cube mesh: a loose bundled file if present, else the
    /// `CubeCatModel` asset-catalog Data Set (a USDZ written to a temp file so
    /// RealityKit can open it by URL).
    private func cubeModelURL() -> URL? {
        for ext in ["usdz", "usdc", "reality"] {
            if let url = Bundle.main.url(forResource: "cube_cat", withExtension: ext) { return url }
        }
        if let asset = NSDataAsset(name: "CubeCatModel") {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cube_cat.usdz")
            if (try? asset.data.write(to: tmp)) != nil { return tmp }
        }
        return nil
    }

    /// Loads the cube mesh, normalised to fit a unit cube centred at the origin,
    /// warmed to a soft ivory. Returns nil (→ procedural cube) if unavailable.
    private func loadCubeModel() -> Entity? {
        guard let url = cubeModelURL(),
              let loaded = try? Entity.load(contentsOf: url) else { return nil }

        let bounds = loaded.visualBounds(relativeTo: nil)
        let maxDim = max(bounds.extents.x, max(bounds.extents.y, bounds.extents.z))
        guard maxDim > 0 else { return nil }

        let holder = Entity()
        let s = cubeSize / maxDim
        loaded.scale = SIMD3<Float>(repeating: s)
        loaded.position = -bounds.center * s
        recolor(loaded, with: furMaterial())
        holder.addChild(loaded)
        return holder
    }

    /// Position + orientation that place a decal plane (default normal +Z,
    /// up +Y) flat on the given cube face, with its "up" chosen so the glyph
    /// reads naturally.
    private func decalPlacement(_ face: Face, offset h: Float) -> (SIMD3<Float>, simd_quatf) {
        let q = Float.pi / 2
        let x = f3(1, 0, 0), y = f3(0, 1, 0)
        switch face {
        case .front: return (f3(0, 0, Double(h)),  simd_quatf(angle: 0, axis: y))
        case .back:  return (f3(0, 0, Double(-h)), quat(.pi, y))
        case .right: return (f3(Double(h), 0, 0),  quat(q, y))
        case .left:  return (f3(Double(-h), 0, 0), quat(-q, y))
        case .up:    return (f3(0, Double(h), 0),  quat(-q, x))
        case .down:  return (f3(0, Double(-h), 0), quat(q, x))
        }
    }

    // MARK: - Materials & tiling

    /// The cube-cat's fur: a tuned PBR surface. A tiled fur albedo + tangent-
    /// space normal give strand micro-relief; `sheen` adds the soft fabric rim
    /// light that reads as fuzz; `anisotropy` stretches highlights along the
    /// strand direction; a faint `clearcoat` gives a healthy-coat sheen. This
    /// fakes fur convincingly without shell geometry (which would need a
    /// device-only CustomMaterial). Bundled `fur_albedo` / `fur_normal` assets
    /// win if present, else procedural fur (ProceduralFur) is used.
    private func furMaterial(tint: UIColor? = nil) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        let tint = tint ?? catIvory

        let albedo = BundledTextures.fur ?? ProceduralFur.albedo()
        if let tex = loadTexture(albedo, semantic: .color) {
            m.baseColor = .init(tint: tint, texture: repeatTexture(tex))
        } else {
            m.baseColor = .init(tint: tint)
        }
        let normal = BundledTextures.furNormal ?? ProceduralFur.normal()
        if let n = loadTexture(normal, semantic: .normal) {
            m.normal = .init(texture: repeatTexture(n))
        }
        m.textureCoordinateTransform = .init(scale: SIMD2<Float>(furTiling, furTiling))

        m.roughness = 0.72
        m.metallic = 0.0
        m.sheen = .init(tint: UIColor(white: 1.0, alpha: 1))
        m.anisotropyLevel = .init(floatLiteral: 0.4)
        m.anisotropyAngle = .init(floatLiteral: 0.0)
        m.clearcoat = .init(floatLiteral: 0.25)
        m.clearcoatRoughness = .init(floatLiteral: 0.85)
        return m
    }

    /// How many times the fur texture tiles across one cube face.
    private let furTiling: Float = 3.0

    /// A self-lit unlit material carrying an alpha-blended glyph/art texture.
    private func unlitMaterial(_ image: UIImage?) -> UnlitMaterial {
        var m = UnlitMaterial()
        if let tex = loadTexture(image, semantic: .color) {
            m.color = .init(tint: .white, texture: .init(tex))
        } else {
            m.color = .init(tint: .white)
        }
        m.blending = .transparent(opacity: 1.0)
        return m
    }

    /// Solid or textured PBR helper.
    private func pbr(_ color: UIColor, roughness: Float = 0.85, metallic: Float = 0,
                     emissive: UIColor? = nil) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.roughness = .init(floatLiteral: roughness)
        m.metallic = .init(floatLiteral: metallic)
        if let e = emissive {
            m.emissiveColor = .init(color: e)
            m.emissiveIntensity = 1.0
        }
        return m
    }

    /// A repeat-wrapped texture parameter (so UV offsets tile continuously).
    private func repeatTexture(_ resource: TextureResource) -> MaterialParameters.Texture {
        let desc = MTLSamplerDescriptor()
        desc.sAddressMode = .repeat
        desc.tAddressMode = .repeat
        desc.magFilter = .linear
        desc.minFilter = .linear
        desc.mipFilter = .linear
        return .init(resource, sampler: .init(desc))
    }

    /// The floor texture for the current look. `.checkerboard` returns nil here
    /// (coloured per-cell in `neutralTileMaterial`).
    ///
    /// `.default` means "whatever this room's floor is", which now resolves to a
    /// procedurally-drawn per-room floor. A bundled `floor_<room>` asset still
    /// wins if you drop one in.
    private func floorTexture() -> UIImage? {
        if let themed = ProceduralTextures.floorTexture(floorTheme) { return themed }
        if floorTheme == .checkerboard { return nil }
        return BundledTextures.image(environment.floorTextureName)
            ?? BundledTextures.carpet
            ?? ProceduralTextures.roomFloor(for: environment)
    }

    private func floorNormal() -> UIImage? {
        if let themed = ProceduralTextures.floorNormal(floorTheme) { return themed }
        if floorTheme == .checkerboard { return nil }
        if floorTheme != .default { return BundledTextures.carpetNormal }
        return BundledTextures.carpetNormal
            ?? ProceduralTextures.roomFloorNormal(for: environment)
    }

    /// A ground plane under the whole board: floor texture if supplied, else
    /// the environment's ground colour.
    private func addGround(_ board: BoardModel) {
        let extent = Float(max(board.width, board.height)) + 6
        let mesh = MeshResource.generatePlane(width: extent, depth: extent)
        var mat: PhysicallyBasedMaterial
        if let tex = floorTexture(), let res = loadTexture(tex, semantic: .color) {
            mat = PhysicallyBasedMaterial()
            mat.baseColor = .init(tint: .white, texture: repeatTexture(res))
            if let n = floorNormal(), let nres = loadTexture(n, semantic: .normal) {
                mat.normal = .init(texture: repeatTexture(nres))
            }
            mat.textureCoordinateTransform = .init(scale: SIMD2<Float>(extent, extent))
            mat.roughness = 0.95
        } else {
            mat = pbr(environment.groundColor, roughness: 1.0)
        }
        let node = ModelEntity(mesh: mesh, materials: [mat])
        node.position = f3(Double(board.width - 1) / 2.0,
                           Double(-tileThickness) - 0.02,
                           Double(board.height - 1) / 2.0)
        boardAnchor.addChild(node)
        groundEntity = node
    }

    /// A tile dressed as a target: the depiction the player wants to land on.
    private func targetTileMaterial(_ index: Int) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        if let res = loadTexture(SymbolTextures.tile(index), semantic: .color) {
            m.baseColor = .init(tint: .white, texture: .init(res))
            // The tile art is now a dark slot with a bright glyph, so drive
            // emission from the same image: the glyph and rim glow while the slot
            // around them stays dark. A flat emissive tint (the old 0.10) just
            // washed the whole tile and left it looking like a patch of rug.
            m.emissiveColor = .init(texture: .init(res))
            m.emissiveIntensity = 0.6
        } else {
            m.emissiveColor = .init(color: GamePalette.color(index))
            m.emissiveIntensity = 0.25
        }
        m.roughness = 0.85
        return m
    }

    /// A plain floor tile. Continuous floor across cells: offset each tile's
    /// UVs by its grid coords so the (seamless) pattern flows unbroken.
    private func neutralTileMaterial(col: Int, row: Int) -> PhysicallyBasedMaterial {
        if floorTheme == .checkerboard {
            let dark = (col + row) % 2 == 0
            return pbr(ProceduralTextures.checkerColor(dark: dark), roughness: 0.9)
        }
        if let tex = floorTexture(), let res = loadTexture(tex, semantic: .color) {
            var m = PhysicallyBasedMaterial()
            let s = Float(floorTexScale)
            m.baseColor = .init(tint: .white, texture: repeatTexture(res))
            if let n = floorNormal(), let nres = loadTexture(n, semantic: .normal) {
                m.normal = .init(texture: repeatTexture(nres))
            }
            m.textureCoordinateTransform = .init(offset: SIMD2<Float>(Float(col) * s, Float(row) * s),
                                                 scale: SIMD2<Float>(s, s))
            m.roughness = 0.95
            return m
        }
        return pbr(environment.floorColor, roughness: 0.85)
    }

    /// How many copies of the floor texture span one board cell (see the
    /// SceneKit note). ~0.5 → one carpet copy every two cells.
    private let floorTexScale: Double = 0.5

    func applyFloorTheme(_ theme: FloorTheme) {
        floorTheme = theme

        // Re-skin the ground plane.
        if let ground = groundEntity {
            let extent = Float(max(boardCols, boardRows)) + 6
            var mat: PhysicallyBasedMaterial
            if let tex = floorTexture(), let res = loadTexture(tex, semantic: .color) {
                mat = PhysicallyBasedMaterial()
                mat.baseColor = .init(tint: .white, texture: repeatTexture(res))
                if let n = floorNormal(), let nres = loadTexture(n, semantic: .normal) {
                    mat.normal = .init(texture: repeatTexture(nres))
                }
                mat.textureCoordinateTransform = .init(scale: SIMD2<Float>(extent, extent))
                mat.roughness = 0.95
            } else {
                mat = pbr(environment.groundColor, roughness: 1.0)
            }
            ground.model?.materials = [mat]
        }

        // Re-skin every neutral tile. Target tiles (those carrying a highlight)
        // keep their depiction.
        for (key, tile) in tileEntities where ringEntities[key] == nil {
            let (col, row) = cellCoords(fromKey: key)
            tile.model?.materials = [neutralTileMaterial(col: col, row: row)]
        }
    }

    private func cellCoords(fromKey key: String) -> (Int, Int) {
        let parts = key.split(separator: ",")
        let col = Int(parts.first ?? "0") ?? 0
        let row = Int(parts.last ?? "0") ?? 0
        return (col, row)
    }

    // MARK: - Furniture

    private func buildFurniture(_ level: Level) {
        for piece in level.furniture {
            let node = furnitureModel(piece) ?? placeholderFurniture(piece)
            node.position = f3(piece.centerCol, 0, piece.centerRow)
            boardAnchor.addChild(node)
        }
    }

    private func placeholderFurniture(_ piece: Furniture) -> Entity {
        let margin: Float = 0.12
        let w = Float(piece.cols) * cubeSize - margin
        let d = Float(piece.rows) * cubeSize - margin
        let h = Float(piece.kind.height)

        let box = MeshResource.generateBox(width: w, height: h, depth: d, cornerRadius: 0.08)
        let body = ModelEntity(mesh: box, materials: [pbr(piece.kind.color, roughness: 0.9)])
        body.position = f3(0, Double(h) / 2.0, 0)   // sit on the floor

        let holder = Entity()
        holder.addChild(body)

        // A soft back cushion on pieces that have one, along the long edge.
        if piece.kind.hasBack {
            let backThick: Float = 0.2
            let along = piece.cols >= piece.rows
            let back = MeshResource.generateBox(width: along ? w : backThick,
                                                height: h * 0.9,
                                                depth: along ? backThick : d,
                                                cornerRadius: 0.06)
            let mat = pbr(piece.kind.color.withAlphaComponent(0.85), roughness: 0.9)
            let backNode = ModelEntity(mesh: back, materials: [mat])
            let edge = (along ? d : w) / 2.0 - backThick / 2.0
            backNode.position = along ? f3(0, Double(h) * 0.65, Double(-edge))
                                      : f3(Double(-edge), Double(h) * 0.65, 0)
            holder.addChild(backNode)
        }
        return holder
    }

    /// Loads `<kind>.usdz` if bundled, scaled to the footprint (normally nil —
    /// no furniture models ship, so the placeholder is used).
    private func furnitureModel(_ piece: Furniture) -> Entity? {
        guard let url = Bundle.main.url(forResource: piece.kind.modelBaseName, withExtension: "usdz"),
              let loaded = try? Entity.load(contentsOf: url) else { return nil }
        let bounds = loaded.visualBounds(relativeTo: nil)
        let targetW = Float(piece.cols) * cubeSize - 0.12
        let targetD = Float(piece.rows) * cubeSize - 0.12
        guard bounds.extents.x > 0, bounds.extents.z > 0 else { return nil }
        let s = min(targetW / bounds.extents.x, targetD / bounds.extents.z)
        loaded.scale = SIMD3<Float>(repeating: s)
        // Rest on the floor, centred on X/Z.
        loaded.position = f3(Double(-bounds.center.x * s),
                             Double(-bounds.min.y * s),
                             Double(-bounds.center.z * s))
        let holder = Entity()
        holder.addChild(loaded)
        return holder
    }

    // MARK: - Pushable toys

    private func itemPosition(col: Int, row: Int) -> SIMD3<Float> {
        f3(Double(col), Double(toyRadius), Double(row))
    }

    private func buildItems(_ level: Level) {
        for goal in level.itemGoals {
            let pad = makeItemGoalPad()
            pad.position = f3(Double(goal.col), 0.03, Double(goal.row))
            boardAnchor.addChild(pad)
        }
        for cell in level.items {
            let toy = makeToy()
            toy.position = itemPosition(col: cell.col, row: cell.row)
            boardAnchor.addChild(toy)
            itemEntities[cell] = toy
        }
    }

    private func buildPerched(_ level: Level) {
        for p in level.perched {
            let h = furnitureHeight(at: p.perch, in: level)
            let toy = makeToy()
            toy.position = f3(Double(p.perch.col), Double(h) + Double(toyRadius), Double(p.perch.row))
            boardAnchor.addChild(toy)
            perchedEntities[p.perch] = toy
        }
    }

    private func furnitureHeight(at cell: GridCell, in level: Level) -> Float {
        for piece in level.furniture where piece.cells.contains(cell) {
            return Float(piece.kind.height)
        }
        return 0
    }

    /// A yarn-ball toy the cat pushes.
    private func makeToy() -> Entity {
        let ball = MeshResource.generateSphere(radius: toyRadius)
        let mat = pbr(UIColor(red: 0.86, green: 0.30, blue: 0.42, alpha: 1), roughness: 0.8)
        return ModelEntity(mesh: ball, materials: [mat])
    }

    /// Tints a toy's emission when it's sitting on (or has reached) a goal.
    private func setToyGlow(_ node: Entity, on: Bool) {
        guard let model = node as? ModelEntity,
              var mat = model.model?.materials.first as? PhysicallyBasedMaterial else { return }
        mat.emissiveColor = .init(color: .white)
        mat.emissiveIntensity = on ? 0.35 : 0.0
        model.model?.materials = [mat]
    }

    /// A glowing floor pad marking where a toy should be pushed.
    private func makeItemGoalPad() -> Entity {
        let mesh = MeshResource.generatePlane(width: toyRadius * 2.5, depth: toyRadius * 2.5,
                                              cornerRadius: toyRadius * 1.25)
        let mat = unlitMaterial(nil)
        var m = mat
        m.color = .init(tint: UIColor(red: 0.95, green: 0.85, blue: 0.45, alpha: 0.55))
        let node = ModelEntity(mesh: mesh, materials: [m])
        animator.addPulser(node) { e, t in
            let o = 0.55 + 0.45 * (0.5 + 0.5 * sin(t / 0.9 * .pi))
            setUnlitOpacity(e, Float(o))
        }
        return node
    }

    // MARK: - Board & highlights

    private func buildBoard(_ board: BoardModel) {
        addGround(board)
        // Flush, flat tiles → a continuous floor with no drawn grid lines.
        let size = cubeSize
        for row in 0..<board.height {
            for col in 0..<board.width {
                let cell = board.cells[row][col]
                let mesh = MeshResource.generateBox(width: size, height: tileThickness,
                                                    depth: size, cornerRadius: 0)
                let material: RealityKit.Material = (cell.target != nil)
                    ? targetTileMaterial(cell.target!)
                    : neutralTileMaterial(col: col, row: row)
                let tile = ModelEntity(mesh: mesh, materials: [material])
                tile.position = f3(Double(col), Double(-tileThickness) / 2.0, Double(row))
                boardAnchor.addChild(tile)
                tileEntities["\(col),\(row)"] = tile

                if let target = cell.target {
                    addHighlight(col: col, row: row, index: target)
                }
            }
        }
    }

    private func addHighlight(col: Int, row: Int, index: Int) {
        let highlight = makeHighlight(index: index)
        highlight.position = f3(Double(col), 0.02, Double(row))
        boardAnchor.addChild(highlight)
        ringEntities["\(col),\(row)"] = highlight
    }

    /// A flat, pulsing square frame that hovers just above an unsolved target
    /// tile (self-lit so it glows). A frame, not a ring.
    private func makeHighlight(index: Int) -> Entity {
        let mesh = MeshResource.generatePlane(width: cubeSize * 0.96, depth: cubeSize * 0.96)
        let node = ModelEntity(mesh: mesh, materials: [unlitMaterial(SymbolTextures.frame(index))])
        setUnlitOpacity(node, 0.9)
        let baseScale = node.scale
        animator.addPulser(node) { e, t in
            let p = 0.5 + 0.5 * sin(t / 0.9 * .pi)
            e.scale = baseScale * Float(1.0 + 0.08 * p)
            setUnlitOpacity(e, Float(0.55 + 0.35 * (1 - p)))
        }
        return node
    }

    // MARK: - Roll geometry (RealityKit-specific mapping of RollDirection)

    /// Offset (relative to the cube centre, edge length 1) of the bottom edge
    /// the cube pivots around.
    private func pivotOffset(_ d: RollDirection) -> SIMD3<Float> {
        switch d {
        case .right:   return f3( 0.5, -0.5,  0.0)
        case .left:    return f3(-0.5, -0.5,  0.0)
        case .forward: return f3( 0.0, -0.5, -0.5)
        case .back:    return f3( 0.0, -0.5,  0.5)
        }
    }

    /// Rotation axis + signed angle for a 90° roll.
    private func rollRotation(_ d: RollDirection) -> (axis: SIMD3<Float>, angle: Float) {
        let quarter = Float.pi / 2
        switch d {
        case .right:   return (f3(0, 0, 1), -quarter)
        case .left:    return (f3(0, 0, 1),  quarter)
        case .forward: return (f3(1, 0, 0), -quarter)
        case .back:    return (f3(1, 0, 0),  quarter)
        }
    }

    // MARK: - Helpers

    /// Recolours every ModelEntity in a hierarchy with a single material.
    private func recolor(_ entity: Entity, with material: RealityKit.Material) {
        if let model = entity as? ModelEntity, model.model != nil {
            let count = max(1, model.model!.materials.count)
            model.model!.materials = Array(repeating: material, count: count)
        }
        for child in entity.children { recolor(child, with: material) }
    }

    /// Visits every ModelEntity in a hierarchy (self included).
    private func forEachModel(_ entity: Entity, _ body: (ModelEntity) -> Void) {
        if let model = entity as? ModelEntity { body(model) }
        for child in entity.children { forEachModel(child, body) }
    }

    /// Continuously scrolls a PBR entity's primary UV offset (a "moving
    /// texture"): each frame the offset advances by `velocity × elapsedTime`,
    /// preserving the material's existing tiling scale. With a repeat-wrapped
    /// sampler the offset wraps seamlessly. Pure UV animation — no Metal, and
    /// it runs on the simulator. Used for the cube's fur shimmer, but works on
    /// any PBR entity (e.g. a future flowing-water floor).
    private func addTextureScroll(_ entity: ModelEntity, velocity: SIMD2<Float>) {
        let scale = (entity.model?.materials.first as? PhysicallyBasedMaterial)?
            .textureCoordinateTransform.scale ?? SIMD2<Float>(1, 1)
        animator.addPulser(entity) { e, t in
            guard let model = e as? ModelEntity,
                  var mat = model.model?.materials.first as? PhysicallyBasedMaterial else { return }
            mat.textureCoordinateTransform = .init(offset: velocity * Float(t), scale: scale)
            model.model?.materials = [mat]
        }
    }
}
