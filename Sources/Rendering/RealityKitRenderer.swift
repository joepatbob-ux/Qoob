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
    /// Three more directions, so the horizontal light isn't a single axis and nothing has
    /// an unlit side — see `setupLighting`.
    private let sideLight = Entity()
    private let backLight = Entity()
    private let underLight = Entity()

    private var boardAnchor = Entity()
    private var cubeEntity = Entity()
    private var cubeArt = Entity()

    /// The cell Qoob is standing on, and the exact grid-aligned orientation they
    /// are standing in. Both are the renderer's own record of where the cube
    /// *should* be, so every animation that touches the cube can end by snapping
    /// back to a known-good pose rather than to wherever the last frame left it.
    /// The basis is integer-valued (a product of 90° rotations), so replaying it
    /// can never drift the way baking a world transform each roll does.
    private var cubeCell = GridCell(col: 0, row: 0)
    private var cubeBasis = matrix_identity_float3x3

    /// Tile entities + their glow highlights, keyed by "col,row".
    /// The ring-and-icon marker floating over each live target, keyed by "col,row".
    private var markerEntities: [String: Entity] = [:]

    /// Pushable toy entities keyed by their current cell; the goal cells.
    private var itemEntities: [GridCell: Entity] = [:]
    /// Where the toy basket is, so a knocked-off toy landing in it can be collected.
    private var basketCell: GridCell?
    /// Perched (knock-off) toy entities keyed by their furniture cell.
    private var perchedEntities: [GridCell: Entity] = [:]

    /// Current environment theme (floor / backdrop / furniture set).
    private var environment: Environment = .livingRoom

    /// Player-selected floor style (Settings). `.default` uses the environment.
    private var floorTheme: FloorTheme = .default
    private var catStyle: CatStyle = .cream
    private var roomAppearance: RoomAppearance = .system
    /// Live weather/solar adjustment layered on top of the day/night preset
    /// (Settings › "Match local weather"). `.neutral` renders byte-identical
    /// to today — see `SkyModifier`.
    private var skyModifier: SkyModifier = .neutral
    /// Bumped on every environment-map bake request, so a slow bake can't
    /// land after (and override) a newer one — see `updateEnvironmentLighting`.
    private var envBakeGeneration: UInt64 = 0
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
        // The camera-mode initialiser belongs to the AR session, which only iOS and
        // Catalyst have; on tvOS there's no camera to fall back from, so the plain
        // initialiser is the only one — and non-AR is all it ever does.
        #if os(tvOS)
        let gameView = ResizeReportingARView(frame: .zero)
        #else
        let gameView = ResizeReportingARView(frame: .zero, cameraMode: .nonAR,
                                            automaticallyConfigureSession: false)
        #endif
        view = gameView
        super.init()
        gameView.onViewportChange = { [weak self] in self?.viewportDidChange() }
        view.environment.background = .color(GamePalette.background(appearance))
        // Camera grain is an AR-passthrough effect; the option doesn't exist on tvOS.
        #if !os(tvOS)
        view.renderOptions.insert(.disableCameraGrain)
        #endif
        view.scene.addAnchor(root)
        root.addChild(cameraEntity)
        setupCamera()
        setupLighting()
        animator.attach(to: view)
        // The camera eases toward Qoob every frame rather than being animated per
        // roll, so a second roll landing mid-ease just moves the target.
        animator.onFrame = { [weak self] dt in self?.followCamera(dt: dt) }
        effects.attach(to: view)
        observeAppearanceChanges()
    }

    // MARK: - Light / dark

    /// Which look to draw, taken from the system appearance.
    private var appearance: Appearance {
        switch roomAppearance {
        case .system:
            return view.traitCollection.userInterfaceStyle == .light ? .light : .dark
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    /// RealityKit resolves a material's colour when the material is built, so a
    /// dynamic `UIColor` would be frozen at whatever appearance was active at level
    /// start. Everything colour-bearing is rebuilt on the switch instead.
    private func observeAppearanceChanges() {
        view.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (view: ARView, _: UITraitCollection) in
            MainActor.assumeIsolated { [weak self] in self?.applyAppearance() }
        }
    }

    private func applyAppearance() {
        view.environment.background = .color(environment.background(appearance))
        setupLighting()                     // key/fill differ between the two looks
        applyFloorTheme(floorTheme)         // re-skins the ground and every tile
        restyleQoob()
        // The target icon is drawn per appearance, so rebuild each live marker.
        for (cell, index) in targetIndexByCell {
            removeTargetMarker(col: cell.col, row: cell.row)
            addTargetMarker(col: cell.col, row: cell.row, index: index)
        }
    }

    func setRoomAppearance(_ appearance: RoomAppearance) {
        roomAppearance = appearance
        applyAppearance()
    }

    func setCatStyle(_ style: CatStyle) {
        catStyle = style
        restyleQoob()
    }

    /// Layers a live-weather/solar adjustment onto the current day/night preset.
    /// `.cheap` only re-aims the already-inexpensive directional lights and nudges
    /// the (already-baked) IBL's exposure and the background tint; `.full`
    /// additionally re-bakes the environment map, the one genuinely expensive step
    /// here — `SkySystem` decides how often that's actually worth asking for.
    func applySky(_ relight: SkyRelight) {
        skyModifier = relight.modifier
        setupDirectionalLights()
        view.environment.lighting.intensityExponent = light.exponent
        view.environment.background = .color(skyTintedBackground())
        if case .full = relight {
            updateEnvironmentLighting()
        }
    }

    /// The room's own background, nudged toward the sky's tint (an overcast
    /// slate, a snow-lit pale grey-blue, ...) — a plain colour blend, no re-bake.
    private func skyTintedBackground() -> UIColor {
        let base = environment.background(appearance)
        guard skyModifier.backgroundBlend > 0 else { return base }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard base.getRed(&r, green: &g, blue: &b, alpha: &a) else { return base }
        let t = CGFloat(skyModifier.backgroundBlend)
        let tint = skyModifier.backgroundTint
        return UIColor(red: r + (CGFloat(tint.x) - r) * t,
                       green: g + (CGFloat(tint.y) - g) * t,
                       blue: b + (CGFloat(tint.z) - b) * t,
                       alpha: a)
    }

    /// Which symbol each live target tile is showing, so tiles can be re-skinned on
    /// an appearance change without asking the game core to replay the level.
    private var targetIndexByCell: [GridCell: Int] = [:]

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
        markerEntities.removeAll()
        targetIndexByCell.removeAll()
        // The whole scene is rebuilt here, so the dynamic-light budget starts over.
        lampLightsUsed = 0
        itemEntities.removeAll()
        toyOffsets.removeAll()
        perchedEntities.removeAll()
        furnitureSurfaceHeight.removeAll()
        nearWalls.removeAll()
        nearWallCells.removeAll()
        basketCell = level.basket
        houseSeed = level.seed

        environment = level.environment
        view.environment.background = .color(environment.background(appearance))

        currentBoard = board
        boardAnchor = Entity()
        root.addChild(boardAnchor)
        buildBoard(board)
        buildRugs(level)
        buildFurniture(level)
        buildItems(level)
        buildPerched(level)
        buildLitterbox(level)

        cubeEntity = makeCubeNode(colors: cube.colors)
        cubeCell = GridCell(col: cube.col, row: cube.row)
        cubeLevel = cube.level
        cubeBasis = matrix_identity_float3x3
        cubeEntity.position = worldPosition(col: cubeCell.col, row: cubeCell.row, level: cubeLevel)
        cubeEntity.transform.rotation = simd_quatf(cubeBasis)
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
                     toLevel: Int,
                     duration: TimeInterval,
                     completion: @escaping () -> Void) {

        // A blocked-roll nudge may still be writing `cubeEntity.position` every
        // frame. Left running, it would fight the pivot and its completion would
        // later snap the cube back to the cell it started the nudge in. Drop it
        // and start from the true cell centre, so the pivot edge is exact.
        animator.cancelRuns(for: cubeEntity)
        cubeEntity.position = worldPosition(col: cubeCell.col, row: cubeCell.row, level: cubeLevel)

        effects.beginRoll(duration: duration)
        // A climb is the same 90° roll about a different edge: pivot on the *top*
        // leading edge and the cube swings up onto the step instead of along the floor.
        // Everything else — the rotation, and so which face lands down — is identical,
        // which is why `CubeState.applyRoll` needs no notion of height at all.
        let climbing = toLevel > cubeLevel
        let offset = pivotOffset(direction, climbing: climbing)
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
            // Bake back onto the root, then snap to the exact cell centre *and*
            // the exact grid-aligned orientation.
            //
            // Baking the world transform alone drifts. This bake is timed off the
            // clock, so it can land a hair before the pivot's animation has
            // finished, and each roll's leftover fraction of a degree compounds
            // until Qoob is visibly sitting askew on the grid. Replaying the
            // integer basis instead means the pose is exact on every roll.
            self.cubeEntity.setParent(self.root, preservingWorldTransform: true)
            pivot.removeFromParent()
            self.rollPivot = nil
            self.cubeCell = target
            self.cubeBasis = Self.rollBasis(direction) * self.cubeBasis
            self.cubeEntity.transform.rotation = simd_quatf(self.cubeBasis)

            // A drop can't be a 90° pivot — no edge exists that swings a cube one
            // level *down* and still lands it flat (the pivot would have to sit in
            // mid-air below the cube). So the roll lands level, and the fall is a
            // separate short drop afterwards, with the soft-body squash to sell it.
            let landsAt = climbing ? toLevel : self.cubeLevel
            self.cubeEntity.position = self.worldPosition(col: target.col, row: target.row,
                                                          level: landsAt)
            let fall = landsAt - toLevel
            if fall > 0 {
                self.dropCube(to: target, level: toLevel, from: landsAt, completion: completion)
            } else {
                self.cubeLevel = toLevel
                completion()
            }
        }
    }

    /// Drops Qoob the levels a roll left them hanging over, easing in like a fall and
    /// squashing on the landing.
    private func dropCube(to cell: GridCell, level: Int, from: Int,
                          completion: @escaping () -> Void) {
        let start = worldPosition(col: cell.col, row: cell.row, level: from)
        let end = worldPosition(col: cell.col, row: cell.row, level: level)
        // Longer for a bigger fall, but sub-linear — a drop off the fridge shouldn't
        // take four times as long as one off the coffee table.
        let drop = min(0.34, 0.10 + 0.06 * Double(from - level))
        effects.beginRoll(duration: drop)
        animator.run(cubeEntity, duration: drop, ease: .easeIn, step: { e, t in
            e.position = mix(start, end, t: SIMD3<Float>(repeating: t))
        }, completion: { [weak self] in
            self?.cubeLevel = level
            self?.cubeEntity.position = end
            completion()
        })
    }

    /// The level Qoob is currently standing on.
    private var cubeLevel: Int = 0

    /// Bumped whenever a roll starts or the scene is rebuilt, so a roll's
    /// deferred bake can tell whether it's still the current one.
    private var rollGeneration: UInt64 = 0
    /// The pivot the in-flight roll swings around, held so a rebuild can remove
    /// it instead of leaving it orphaned under `root`.
    private var rollPivot: Entity?

    /// A matched square goes straight back to being floor, with nothing left to
    /// mark that it was ever a target.
    ///
    /// There was a flourish here — the tile flashed its colour, popped up, and the
    /// highlight frame expanded and faded away. Two reasons it's gone. It isn't
    /// wanted: a picked-up square shouldn't be marked. And the fade never worked
    /// anyway, because the frame's endless pulser stayed attached and rewrote its
    /// opacity every frame, fighting the animation that was trying to fade it out.
    func clearTile(col: Int, row: Int) {
        removeTargetMarker(col: col, row: row)
    }

    func addTarget(col: Int, row: Int, colorIndex: Int) {
        let key = "\(col),\(row)"
        // A small lift to draw the eye to where the new target appeared. It used to
        // nudge the floor tile under it; floors are one slab per room now, so the pad
        // itself does the hop — which reads better anyway, since it's the thing that
        // just arrived.

        removeTargetMarker(col: col, row: row)
        addTargetMarker(col: col, row: row, index: colorIndex)
        if let marker = markerEntities[key] {
            let base = marker.position
            animator.run(marker, duration: 0.28, ease: .linear, step: { e, t in
                e.position = base + f3(0, Double(sin(Double(t) * .pi) * 0.10), 0)
            }, completion: { [weak marker] in marker?.position = base })
        }
    }

    func rejectRoll(_ direction: RollDirection) {
        // A small nudge toward the blocked cell, then a settle back — no move.
        //
        // The nudge is measured from the cell centre rather than from wherever
        // the cube happens to be. A second blocked input arriving mid-nudge used
        // to take the already-nudged position as its own base and settle back to
        // that, so a run of blocked rolls (holding a tilt into a wall, say)
        // walked Qoob off the grid a fraction of a cell at a time.
        animator.cancelRuns(for: cubeEntity)
        let off = pivotOffset(direction)
        let dx = off.x * 0.16
        let dz = off.z * 0.16
        let base = worldPosition(col: cubeCell.col, row: cubeCell.row, level: cubeLevel)
        cubeEntity.position = base
        animator.run(cubeEntity, duration: 0.19, ease: .easeOut, step: { e, t in
            let bump = Float(sin(Double(t) * .pi))
            e.position = base + f3(Double(dx * bump), 0, Double(dz * bump))
        }, completion: { [weak self] in self?.cubeEntity.position = base })
    }

    func moveItem(from: GridCell, along path: [GridCell], duration: TimeInterval,
                  collected: Bool) {
        guard let node = itemEntities[from], let landing = path.last else { return }
        itemEntities[from] = nil
        if !collected { itemEntities[landing] = node }

        // One leg per cell, chained, so a rebound reads as a rebound: the toy visibly
        // reaches the wall and comes back rather than sliding diagonally to wherever it
        // finished. Slightly quicker per cell than a roll, and easing out over the whole
        // run so it decelerates like something losing momentum.
        let legs = path.count
        let perLeg = max(0.05, duration * 0.85)
        let offset = toyOffset(node, seed: from)
        let hop = toyRadius * 0.55

        func leg(_ index: Int, from origin: GridCell, previousDelta: (col: Int, row: Int)?) {
            guard index < legs else {
                if collected { collectToy(node) }
                return
            }
            let to = path[index]
            let delta = (col: to.col - origin.col, row: to.row - origin.row)
            // This leg goes back the way the last one came, so the toy has just hit
            // something. A hop over the rebound is what makes that read as a bounce
            // rather than as the toy changing its mind.
            let bounced = previousDelta.map { $0 != delta } ?? false

            let start = itemPosition(col: origin.col, row: origin.row, offset: offset)
            // A collected toy finishes square in the middle of the basket. Dropping in a
            // quarter-cell off centre would clip the rim it's meant to fall through.
            let landingOffset = (collected && index == legs - 1) ? .zero : offset
            let dest = itemPosition(col: to.col, row: to.row, offset: landingOffset)
            let axis = f3(Double(delta.row), 0, Double(-delta.col))
            let startRot = node.transform.rotation
            // Later legs are slower — the toy is running out of push.
            let slow = perLeg * (1.0 + 0.25 * Double(index))
            animator.run(node, duration: slow, ease: index == legs - 1 ? .easeOut : .linear,
                         step: { e, t in
                var p = mix(start, dest, t: SIMD3<Float>(repeating: t))
                if bounced { p.y += hop * Float(sin(t * .pi)) }
                e.position = p
                // Half a turn per cell, and the same for a cube pet as for the ball.
                //
                // Pets used to get `0.22 * sin(t * .pi)` — a wobble that returns to zero,
                // so the toy arrived in the orientation it left in and read as *sliding*.
                // Since every toy in the game is a pet (the ball is only the fallback for
                // when no pets are bundled), nothing in the game actually rolled. Half a
                // turn also lands a cube on a face, which suits a world made of them.
                e.transform.rotation = quat(.pi * t, axis) * startRot
            }, completion: { leg(index + 1, from: to, previousDelta: delta) })
        }
        leg(0, from: from, previousDelta: nil)
    }

    /// Drops a toy into the basket and retires it: a short sink with a squash, so it
    /// reads as going *in* rather than just vanishing on arrival.
    private func collectToy(_ node: Entity) {
        let base = node.position
        let baseScale = node.scale
        let sink = toyRadiusForDrop        // read outside the closure, so it needn't capture self
        animator.run(node, duration: 0.26, ease: .easeIn, step: { e, t in
            e.position = base + f3(0, Double(-sink * t), 0)
            e.scale = baseScale * Float(1 - 0.35 * Double(t))
        }, completion: { [weak node] in node?.removeFromParent() })
    }

    /// How far a collected toy sinks. Just past its own radius, so it's out of sight
    /// inside the basket before it's removed.
    private var toyRadiusForDrop: Float { toyRadius * 1.6 }

    func knockOffToy(fromFurnitureAt perch: GridCell, to landing: GridCell, duration: TimeInterval) {
        guard let node = perchedEntities[perch] else { return }
        perchedEntities[perch] = nil
        itemEntities[landing] = node    // it's now a normal pushable toy

        let start = node.position
        // Keeps the offset it had on the furniture, so a knocked-off toy lands scattered
        // like the rest rather than snapping to the middle of its new cell.
        let dest = itemPosition(col: landing.col, row: landing.row,
                                offset: toyOffset(node, seed: perch))
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
            if landing == self.basketCell { self.collectToy(node) }
        })
    }

    // MARK: - Scene setup

    // RealityKit light intensity is in lux and scales very differently from
    // SceneKit's arbitrary units; these are tuned by eye against the old look.
    private func setupLighting() {
        // Image-based lighting first, and it's the part that does the most work.
        //
        // Two directional lights can't light a room. A directional light is a sun: it
        // arrives from exactly one direction, so a surface facing away from it gets
        // nothing but whatever the fill happens to give, and every object drops one hard
        // shadow. A real room is lit from everywhere at once — ceiling, walls and floor
        // all bouncing — which is why an interior reads as soft. An environment map is
        // how you say "light comes from every direction", so that's what the ambient is
        // now, instead of a second directional pretending to be one.
        updateEnvironmentLighting()
        setupDirectionalLights()
    }

    /// The key + three fills only — split out of `setupLighting` so a live-weather
    /// relight (`applySky`) can re-aim these every frame for free without also
    /// paying for `updateEnvironmentLighting`'s async re-bake.
    private func setupDirectionalLights() {
        // The key is now a hint of direction rather than the light source. It was 3400
        // lux against a 2100 fill, which is a 1.6:1 ratio and reads as a sunny window on
        // one wall; the shadows were nearly black because nothing else reached into them.
        // Dropped to roughly a third of that, with the environment carrying the base
        // level, the same shadow becomes a soft grey — the shadow map is still hard-edged
        // (RealityKit exposes no softness) but a light shadow reads as a soft one.
        let key = DirectionalLightComponent(color: light.keyColour, intensity: keyIntensity)
        keyLight.components.set(key)
        keyLight.look(at: .zero, from: light.keyFrom, upVector: f3(0, 1, 0), relativeTo: nil)
        root.addChild(keyLight)
        updateShadow()

        // Fills from three more directions, so the horizontal light isn't a single axis
        // and no side of anything is left unlit. None of them casts a shadow: more
        // shadow-casters would mean more hard-edged shadows, which is the opposite of
        // what's wanted — they're here to *fill* the key's shadow, not to add their own.
        //
        // Set low and coming from several sides, they behave like bounce off walls, on
        // top of the environment map's ambient.
        let fills: [(light: Entity, from: SIMD3<Float>, colour: UIColor, level: Float)] = [
            (fillLight,  f3(4, 5, -3),  coolFill,        fillIntensity),        // opposite the key
            (sideLight,  f3(5, 3, 4),   light.spillColour, sideIntensity),      // across, warm
            (backLight,  f3(-5, 3, -4), coolFill,        sideIntensity * 0.8),  // behind
            (underLight, f3(0, 1, 5),   light.spillColour, sideIntensity * 0.6),// low, toward camera
        ]
        for entry in fills {
            entry.light.components.set(
                DirectionalLightComponent(color: entry.colour, intensity: entry.level))
            entry.light.look(at: .zero, from: entry.from, upVector: f3(0, 1, 0), relativeTo: nil)
            root.addChild(entry.light)
        }
    }

    /// Builds the room's environment map and hands it to the view as image-based light.
    ///
    /// Rebuilt on an appearance change along with the directionals, since a night-time
    /// room bounces much less light and bounces it cooler.
    /// Built asynchronously, because the synchronous initialiser is iOS 27 and this ships
    /// to iOS 16. Arriving a frame or two late is invisible: it's the ambient level, and
    /// it lands well before the splash lifts.
    private func updateEnvironmentLighting() {
        guard let image = roomEnvironmentImage() else { return }
        // Logarithmic: the factor applied is 2^exponent, and 0 means "use the texture's
        // own values". The map is authored at the level the room wants, so this only
        // trims between light and dark mode.
        let exponent = light.exponent
        // Live weather can ask for this repeatedly as the sky changes; each bake takes
        // a beat, so a slow one finishing after a newer request would otherwise splat
        // stale lighting back over whatever's current. Only the most recent request's
        // result is ever applied.
        envBakeGeneration &+= 1
        let generation = envBakeGeneration
        Task { @MainActor [weak self] in
            guard let resource = try? await EnvironmentResource(equirectangular: image,
                                                               withName: "QoobRoom"),
                  let self, self.envBakeGeneration == generation else { return }
            self.view.environment.lighting.resource = resource
            self.view.environment.lighting.intensityExponent = exponent
        }
    }

    /// How the room is lit, as both the environment map and the key light read it.
    ///
    /// Day and night are stated separately rather than as a brightness multiplier, because
    /// they aren't the same room dimmed — they're lit by different things from different
    /// places. Dimming daylight gives you an overcast afternoon, not a night.
    private struct RoomLight {
        /// The three bands of the environment map, top to bottom, as radiance.
        var ceiling: SIMD3<Double>
        var wall: SIMD3<Double>
        var floorBounce: SIMD3<Double>
        /// A bright patch standing for a window, and where it sits: `u` is longitude,
        /// `v` is latitude with 0 straight up and 1 straight down.
        var window: SIMD3<Double>
        var windowAt: SIMD2<Double>
        var windowRadius: Double
        /// A second, warmer patch: a ceiling fixture by day, a door left ajar at night.
        var spill: SIMD3<Double>
        var spillAt: SIMD2<Double>
        var spillRadius: Double
        /// Where the key comes from, and what colour it is.
        var keyFrom: SIMD3<Float>
        var keyColour: UIColor
        /// The colour of the warm fills, matching whatever `spill` represents.
        var spillColour: UIColor
        /// Trim on the environment map, applied as 2^exponent.
        var exponent: Float

        /// Lights on. The ceiling is the brightest thing in the room, which is what a
        /// working light fitting and a bright day both look like from inside.
        static let day = RoomLight(
            ceiling: SIMD3(0.96, 0.93, 0.88),
            wall: SIMD3(0.46, 0.45, 0.45),
            floorBounce: SIMD3(0.20, 0.19, 0.18),
            window: SIMD3(0.85, 0.92, 1.00),
            windowAt: SIMD2(0.22, 0.40), windowRadius: 0.42,
            spill: SIMD3(0.55, 0.48, 0.38),
            spillAt: SIMD2(0.72, 0.22), spillRadius: 0.34,   // high up: a ceiling fitting
            keyFrom: SIMD3(-3, 6, 3),                        // steep, like a fitting overhead
            keyColour: UIColor(red: 1.00, green: 0.96, blue: 0.90, alpha: 1),
            spillColour: UIColor(red: 1.00, green: 0.96, blue: 0.90, alpha: 1),
            exponent: 0.3)

        /// Lights off, night. Everything about the shape is inverted from `day`.
        ///
        /// The ceiling is nearly black, because with the fitting off there's nothing
        /// lighting it — that one change does more than any amount of dimming. The
        /// brightest thing is a window at the *horizon* rather than above, and the key
        /// rakes in low through it, which is what gives night its long shadows. The warm
        /// patch stays, small and low, as a door left ajar onto a lit hall: without it the
        /// whole room goes monochrome blue, which reads as underwater rather than indoors.
    /// The numbers below are a second pass. The first was faithful to a dark room and
    /// unplayable with it: Qoob came out a blue-grey blob and whole objects vanished into
    /// a near-black floor. Qoob has to be the most legible thing on screen — that isn't
    /// negotiable, it's how you play — so the *window* and the key came up while the
    /// ceiling stayed almost black. Keeping the ceiling dark is what preserves the
    /// lights-off read; brightening it would just have made it dusk again.
    /// Third pass: brighter again, and deliberately *not* by lifting the ceiling.
    ///
    /// The ceiling term is what says "the light is off", so raising it is the one change
    /// that would undo the whole effect. What went up instead is the bounce — `wall` and
    /// especially `floorBounce` — plus the directional fills. Bounce lifts the mid-tones
    /// and, crucially, the insides of shadows, which is where the old night crushed to
    /// black: `floorBounce` is nearly doubled, and the floor is where the game is
    /// actually played. Brighter without a second sun.
        static let night = RoomLight(
            ceiling: SIMD3(0.085, 0.092, 0.125),
            wall: SIMD3(0.145, 0.165, 0.225),
            floorBounce: SIMD3(0.075, 0.082, 0.105),
            window: SIMD3(0.62, 0.72, 0.96),
            windowAt: SIMD2(0.22, 0.52), windowRadius: 0.34,  // at eye level, and tighter
            spill: SIMD3(0.34, 0.23, 0.13),
            spillAt: SIMD2(0.68, 0.58), spillRadius: 0.22,    // low and small: a doorway
            keyFrom: SIMD3(-7, 2.2, 4),                       // low and raking: moonlight
            keyColour: UIColor(red: 0.76, green: 0.84, blue: 1.00, alpha: 1),
            spillColour: UIColor(red: 1.00, green: 0.86, blue: 0.68, alpha: 1),
            exponent: 0.1)

        /// A copy with a live-weather `SkyModifier` layered on top.
        ///
        /// `floorBounce` and the `spill` patch are deliberately never touched: they're
        /// what keep a room's day/night *identity* intact while the sky above it
        /// changes, and what keeps an indoor room's ceiling fitting or lit doorway
        /// reading as indoors rather than also flattening under an overcast sky.
        /// `SkyModifier`'s own doc comment covers why this can brighten/warm/cool but
        /// never darken a room below `self`.
        func applying(_ modifier: SkyModifier) -> RoomLight {
            var copy = self
            copy.window = window * modifier.windowTint * modifier.windowGain
            copy.windowAt.y = min(0.92, max(0.08, windowAt.y + modifier.windowElevationDelta))
            copy.windowRadius = windowRadius * modifier.windowRadiusScale
            copy.ceiling = ceiling * modifier.ceilingScale
            copy.wall = wall * modifier.wallScale
            copy.keyColour = Self.tinted(keyColour, by: modifier.keyTint)
            copy.exponent = exponent + modifier.exponentDelta
            return copy
        }

        /// Per-channel tint, unlike `scaled(_:by:)` elsewhere which applies one
        /// factor to all three channels alike.
        private static func tinted(_ color: UIColor, by tint: SIMD3<Double>) -> UIColor {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return color }
            return UIColor(red: min(1, r * CGFloat(tint.x)),
                           green: min(1, g * CGFloat(tint.y)),
                           blue: min(1, b * CGFloat(tint.z)),
                           alpha: a)
        }
    }

    private var light: RoomLight {
        (appearance == .light ? RoomLight.day : RoomLight.night).applying(skyModifier)
    }

    /// A latitude/longitude image of what a room looks like from the inside, used only
    /// as a light source — it's never seen, because the background stays a flat colour.
    ///
    /// Three bands and two soft patches, which is enough to read as domestic. The patches
    /// are what make it *multi*-directional — without them a pure vertical gradient lights
    /// everything identically from all sides and objects lose their form entirely.
    private func roomEnvironmentImage() -> CGImage? {
        let w = 128, h = 64
        let room = light
        // Radiance, not sRGB paint: these are the values the IBL integrates.
        // The wall band is the one to be careful with. At a flat mid-grey it lights every
        // surface from every side equally, which reads as haze: the whole room lost
        // contrast and the colours went muddy. Kept well below the ceiling so there's
        // still a clear top-down gradient for surfaces to shade against.
        let ceiling = room.ceiling
        let wall = room.wall
        let bounce = room.floorBounce
        let window = room.window
        let fixture = room.spill

        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        /// Soft circular patch, wrapping in longitude so there's no seam.
        func patch(_ u: Double, _ v: Double, at cu: Double, _ cv: Double, radius: Double) -> Double {
            var du = abs(u - cu)
            if du > 0.5 { du = 1 - du }                  // shortest way round
            let d = sqrt(du * du * 4 + (v - cv) * (v - cv))   // u spans 2× the angle v does
            return max(0, 1 - d / radius) * max(0, 1 - d / radius)   // smooth falloff
        }
        for y in 0..<h {
            let v = (Double(y) + 0.5) / Double(h)        // 0 = straight up, 1 = straight down
            // Ceiling → wall over the top half, wall → floor bounce over the bottom.
            let base = v < 0.5
                ? mix(ceiling, wall, t: SIMD3(repeating: smoothstep(v / 0.5)))
                : mix(wall, bounce, t: SIMD3(repeating: smoothstep((v - 0.5) / 0.5)))
            for x in 0..<w {
                let u = (Double(x) + 0.5) / Double(w)
                var c = base
                c += window * patch(u, v, at: room.windowAt.x, room.windowAt.y,
                                    radius: room.windowRadius)
                c += fixture * patch(u, v, at: room.spillAt.x, room.spillAt.y,
                                     radius: room.spillRadius)
                let i = (y * w + x) * 4
                pixels[i]     = UInt8(min(255, max(0, c.x * 255)))
                pixels[i + 1] = UInt8(min(255, max(0, c.y * 255)))
                pixels[i + 2] = UInt8(min(255, max(0, c.z * 255)))
            }
        }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    private func smoothstep(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    /// The cool fill, opposite whatever the key is. Slightly cool against a slightly warm
    /// key is a cheap way to keep a flat top-down scene from reading as uniformly grey; at
    /// night the whole rig is cool already, so this leans further blue to match the moon.
    ///
    /// Light mode keeps it nearly white on purpose. It runs much brighter there, and at
    /// that strength a strong blue took over — the cream cat came out blue-grey.
    private var coolFill: UIColor {
        switch appearance {
        case .dark:  return UIColor(red: 0.62, green: 0.74, blue: 1.00, alpha: 1)
        case .light: return UIColor(red: 0.96, green: 0.97, blue: 1.00, alpha: 1)
        }
    }

    /// Directional levels, now that the environment map carries the base light.
    ///
    /// The three together come to about 2200 lux against the 5500 the old key and fill
    /// added up to. They're for shaping — enough to tell which way is up and give the
    /// furniture an edge — not for lighting the room.
    /// The key is deliberately still the brightest single source. Cut to 1200 against
    /// 1650 of fill it went too far the other way: soft, multi-directional and completely
    /// ungrounded — Qoob and the furniture stopped casting any contact shadow at all and
    /// floated. A real room is soft but things still sit on the floor, so the key keeps
    /// about a 1.6:1 lead over the total fill. What changed versus the original is the
    /// *absolute* level and the number of directions, not the idea of having a key.
    /// Night is a *quarter* of the day level, not two-thirds of it. Moonlight through a
    /// window is a few hundred lux at most against a few thousand for a lit room, and
    /// getting that ratio wrong is what made the old dark mode read as dusk. The fills go
    /// down further still: at night there's very little in the room bouncing anything.
    /// Night was raised on the second look: the fills roughly doubled and the key came up
    /// with them, keeping about the same 1.7:1 lead the day rig has so the room stays
    /// grounded rather than going flat. The fills are what reach into the key's shadows,
    /// so this is the other half of stopping night crush to black — the first half being
    /// `RoomLight.night`'s bounce.
    // Scaled by `skyModifier`'s intensity fields, which `SkyModifier.make` keeps
    // clamped to `>= 1` — live weather can raise these (an overcast sky is a big
    // soft light source) but never cut them below today's baseline.
    private var keyIntensity: Float {
        (appearance == .light ? 2100 : 1250) * Float(skyModifier.keyIntensityScale)
    }
    private var fillIntensity: Float {
        (appearance == .light ? 520 : 300) * Float(skyModifier.fillIntensityScale)
    }
    private var sideIntensity: Float {
        (appearance == .light ? 330 : 210) * Float(skyModifier.fillIntensityScale)
    }

    private func setupCamera() {
        // The 3-arg init defaults its field-of-view orientation to vertical
        // (the orientation-taking variant is iOS 18+); vertical matches the
        // framing math in `aimCamera`.
        let cam = PerspectiveCameraComponent(near: 0.1, far: 200,
                                             fieldOfViewInDegrees: Float(cameraFOV))
        cameraEntity.components.set(cam)
    }

    private let cameraFOV: Double = 50            // vertical field of view (°)
    // Slack on the fixed zoom. Lives on `Level` because room sizing has to agree
    // with it exactly — a room is sized to exceed this view, so if the two drifted
    // apart a room could come out smaller than the screen after all.
    private var boardBleed: Double { Level.viewSlack }

    func setBoardTilt(_ radians: Double) {
        boardTiltRadians = radians
        aimCamera()
    }

    /// Re-aims the camera when the viewport changes shape — rotating the device, or
    /// resizing the window on iPad and the Mac.
    ///
    /// Only the framing changes. The room's own dimensions come from the aspect
    /// ratio at level start (see `Level.generate`), and reshaping it mid-level would
    /// move Qoob and every target out from under the player. The zoom is fixed to a
    /// cell count, so a reshaped viewport simply sees more of the room along its
    /// longer axis.
    private func viewportDidChange() {
        guard boardCols > 1 || boardRows > 1 else { return }   // nothing presented yet
        aimCamera()
    }

    func setEnvironmentActive(_ active: Bool) {
        effects.active = active
    }

    /// Height that makes `Level.visibleShortCells` span the viewport's short side.
    ///
    /// A fixed zoom, deliberately independent of room size: the camera no longer
    /// frames the whole room (it can't — rooms are bigger than the window), so
    /// instead a cell is the same size on screen at every level and the room simply
    /// runs off the edges. The field of view is vertical, so in portrait the short
    /// side is the width and the aspect divides in.
    private var cameraDistance: Double {
        let halfV = tan(cameraFOV * .pi / 180 / 2)
        let cells = Double(Level.visibleShortCells) * boardBleed
        let aspect = viewportAspect > 0 ? viewportAspect : 1
        return aspect >= 1 ? cells / (2 * halfV) : cells / (2 * halfV * aspect)
    }

    /// Half-extents of what the camera can see on the floor plane, in cells.
    private func viewHalfExtents(at h: Double) -> (x: Double, z: Double) {
        let halfV = tan(cameraFOV * .pi / 180 / 2)
        let halfZ = h * halfV
        let aspect = viewportAspect > 0 ? viewportAspect : 1
        return (halfZ * aspect, halfZ)
    }

    /// Screen space the HUD covers, in points: the score/timer/settings row along the
    /// top and the control wheel along the bottom. Sizes mirror `ControlMetrics`, and
    /// the safe-area insets are added because both sit inside them.
    private var hudCoverPoints: (top: Double, bottom: Double) {
        let insets = view.safeAreaInsets
        let headerRow = 48.0 + 16.0                 // the pill row, plus the stack's padding
        let regular = view.bounds.width >= 700      // matches ControlMetrics.regular
        let wheel = (regular ? 164.0 : 116.0) + 28.0
        return (Double(insets.top) + headerRow, Double(insets.bottom) + wheel)
    }

    /// That coverage as cells at the current zoom, plus breathing room so Qoob isn't
    /// tucked right up against the HUD's edge.
    private func hudInsetCells() -> (top: Double, bottom: Double, side: Double) {
        let clear = 0.8
        let size = view.bounds.size
        guard size.height > 1 else { return (3.0 + clear, 4.0 + clear, 1.2) }
        let cellsPerPoint = viewHalfExtents(at: cameraDistance).z * 2 / Double(size.height)
        let cover = hudCoverPoints
        // The sides carry no controls, so they only need enough to stop a standing
        // cube's top face projecting out of the frame.
        return (cover.top * cellsPerPoint + clear,
                cover.bottom * cellsPerPoint + clear,
                1.2)
    }

    /// Where the camera should be looking: centred on `cell`, held inside the room,
    /// and never so far that Qoob ends up off frame or behind the HUD.
    private func cameraFocus(on cell: GridCell) -> (x: Double, z: Double) {
        let h = cameraDistance
        let half = viewHalfExtents(at: h)
        let inset = hudInsetCells()

        /// `clearLow` is the clearance Qoob needs from the frame edge at the *lower*
        /// world coordinate — screen top for rows, since up = -Z — and `clearHigh`
        /// from the other. They differ for rows because the control wheel covers far
        /// more of the screen than the header does.
        func focus(_ v: Double, span: Int, halfView: Double,
                   clearLow: Double, clearHigh: Double) -> Double {
            // Cells sit on integer coordinates and tiles span ±0.5, so the room runs
            // from -0.5 to (count - 0.5).
            let lo = -0.5, hi = Double(span) - 0.5
            // Prefer not to look past the room's walls. The centring branch is a
            // fallback only: rooms are sized to exceed the view on both axes, so it
            // should never be taken — it's here so a room that somehow came out small
            // (an odd viewport mid-resize) is framed rather than clamped to nonsense.
            var f = hi - lo > halfView * 2
                ? min(max(v, lo + halfView), hi - halfView)
                : (lo + hi) / 2

            // But not at the cost of Qoob. Once the clamp above pins the view edge to
            // a wall, Qoob in the outermost cells drifts to the edge of the screen —
            // where a standing cube's top face projects out of a perspective frustum
            // even with its floor cell in view, and where the header or the wheel is
            // sitting anyway. Give way far enough to hold them clear; seeing a little
            // floor past a wall costs nothing next to losing sight of the player.
            let f_max = v + max(0, halfView - clearLow)
            let f_min = v - max(0, halfView - clearHigh)
            f = min(max(f, f_min), f_max)
            return f
        }
        return (focus(Double(cell.col), span: boardCols, halfView: half.x,
                      clearLow: inset.side, clearHigh: inset.side),
                focus(Double(cell.row), span: boardRows, halfView: half.z,
                      clearLow: inset.top, clearHigh: inset.bottom))
    }

    /// Snaps the camera to its focus without easing — on level start, a viewport
    /// change or a tilt change, where easing from the old framing would look like a
    /// stray pan.
    private func aimCamera() {
        let focus = cameraFocus(on: cubeCell)
        cameraFocusX = focus.x
        cameraFocusZ = focus.z
        applyCamera()
        updateWallVisibility()
    }

    /// Eases the camera toward Qoob. Exponential smoothing on the focus point, so
    /// it settles quickly after a roll without the fixed-duration animation fighting
    /// a second roll that lands before the first has finished easing.
    private func followCamera(dt: TimeInterval) {
        guard boardCols > 1 || boardRows > 1 else { return }
        let focus = cameraFocus(on: cubeCell)
        let dx = focus.x - cameraFocusX, dz = focus.z - cameraFocusZ
        // Close enough that another frame of easing wouldn't move a pixel.
        if abs(dx) < 0.0005 && abs(dz) < 0.0005 {
            if cameraFocusX != focus.x || cameraFocusZ != focus.z {
                cameraFocusX = focus.x; cameraFocusZ = focus.z
                applyCamera()
            }
            return
        }
        let k = 1 - exp(-cameraFollowRate * dt)
        cameraFocusX += dx * k
        cameraFocusZ += dz * k
        applyCamera()
    }

    /// How fast the camera closes on Qoob, in e-folds per second. Tuned against
    /// `GameController.rollDuration` so it arrives about as the roll lands.
    private let cameraFollowRate: Double = 9

    private var cameraFocusX: Double = 0
    private var cameraFocusZ: Double = 0

    /// Points the camera at the current focus.
    private func applyCamera() {
        let h = cameraDistance
        let cx = cameraFocusX, cz = cameraFocusZ
        if boardTiltRadians <= 0.0001 {
            // Looking straight down with up = -Z keeps screen up = -row.
            cameraEntity.look(at: f3(cx, 0, cz), from: f3(cx, h, cz),
                              upVector: f3(0, 0, -1), relativeTo: nil)
        } else {
            let zOffset = h * tan(boardTiltRadians)
            cameraEntity.look(at: f3(cx, 0, cz), from: f3(cx, h, cz + zOffset),
                              upVector: f3(0, 1, 0), relativeTo: nil)
        }
        cameraHeight = h
        updateShadow()
    }

    /// How far above the board the camera ended up. The shadow needs it — see
    /// `updateShadow`.
    private var cameraHeight: Double = 0

    /// Sizes the key light's shadow to actually reach the board.
    ///
    /// `DirectionalLightComponent.Shadow` defaults `maximumDistance` to 5 metres,
    /// measured out from the camera. The camera sits about 18 units above a board
    /// 16 units long, so at the default almost nothing was inside the shadow's
    /// range: shadows rendered in a narrow band near the top of the board and then
    /// stopped dead, which showed up as a hard vertical line down the board's edge
    /// and a dark wedge beside Qoob. Covering the camera's distance to the board
    /// plus the board's own extent puts the whole scene inside the map.
    private func updateShadow() {
        // Sized to what the camera can actually see, not to the whole room. Rooms are
        // now far larger than the view, and stretching the shadow map across a 19×28
        // room to light the one screenful in front of you spends all its resolution
        // on floor nobody is looking at.
        let half = viewHalfExtents(at: cameraHeight)
        let reach = cameraHeight + max(half.x, half.z) * 2 + Double(wallHeight)
        keyLight.components.set(
            DirectionalLightComponent.Shadow(maximumDistance: Float(max(10, reach)),
                                             depthBias: 2.0)
        )
    }

    // MARK: - Geometry

    private func worldPosition(col: Int, row: Int, level: Int) -> SIMD3<Float> {
        f3(Double(col), Double(level) + Double(cubeSize) / 2.0, Double(row))
    }

    /// Qoob: a container entity (this is what rolls / gets positioned & baked)
    /// holding an `art` child (deformation applied there so it never disturbs the
    /// roll transform the game logic reads from the container).
    ///
    /// They *move* like a cube — one cell per roll, pivoting on a bottom edge — but
    /// they aren't drawn as one. The body is a soft plush loaf, and each side carries
    /// the sculpted body part its symbol depicts.
    private func makeCubeNode(colors: [Face: Int]) -> Entity {
        let container = Entity()
        container.name = "cube"

        let art = Entity()
        art.name = "cubeArt"
        container.addChild(art)
        cubeArt = art

        // A loose `cube_cat.*` file is treated as a deliberate override; the
        // placeholder Data Set in the asset catalogue is not used, since it's a
        // single-material rounded box that the sculpted loaf below supersedes.
        if let model = loadOverrideModel() {
            art.addChild(model)
        } else {
            buildCatBody(on: art)
        }

        addCatFeatures(colors: colors, on: art)

        // Idle breathing + roll squash are owned by the soft-body effect
        // (RealityKitEnvironmentEffects), which drives this art node's scale.
        //
        // There used to be a UV-scroll "shimmer" here, drifting the coat's texture
        // so highlights played across the fur strands. The strands are gone, so it
        // had nothing left to move — and it was rebuilding a material every frame
        // for each of the forty-odd pieces Qoob is now made of.
        return container
    }

    /// Qoob's body: a heavily-rounded box, so they read as a soft plush loaf rather
    /// than a die while still filling the unit cell the roll geometry assumes.
    ///
    /// The proportions stay cubic on purpose. Qoob pivots about a bottom edge at
    /// y = -0.5, so a body that wasn't square in profile would swing about a point
    /// off its own surface and look like it was hinged on thin air.
    private func buildCatBody(on art: Entity) {
        art.addChild(coatPart(.generateBox(size: cubeSize, cornerRadius: bodyCornerRadius),
                              .body))
    }

    /// How soft Qoob's corners are, as a fraction of their size. At 0.5 they'd be a
    /// sphere; this is round enough to read as a squishy loaf while the middles of
    /// their sides stay broad enough to carry ears, paws and markings.
    private var bodyCornerRadius: Float { cubeSize * 0.34 }

    /// The half-width of the flat area in the middle of a side.
    private var flatHalfExtent: Float { cubeSize / 2 - bodyCornerRadius }

    /// How far out of a side the body's surface sits at a given offset across it.
    ///
    /// Features can't just be parked at a fixed depth: past `flatHalfExtent` the
    /// rounded corner falls away, and the rounder Qoob gets the more it falls. This
    /// returns the exact surface of the rounded box, so an ear or a paw pad seated
    /// with it stays planted however far off-centre it sits.
    private func surfaceDepth(x: Float, y: Float) -> Float {
        let h = cubeSize / 2
        let r = bodyCornerRadius
        let flat = h - r
        // Distance into the rounded region along each axis.
        let ax = max(0, abs(x) - flat)
        let ay = max(0, abs(y) - flat)
        let remaining = r * r - ax * ax - ay * ay
        guard remaining > 0 else { return flat }
        return flat + sqrt(remaining)
    }

    // MARK: - Cat features
    //
    // There are no decals any more. Every side used to carry a flat colour-coded
    // glyph plane, which read as stickers pasted onto a box — and edge-on they
    // showed as bright coloured bars along the silhouette. Each side is instead
    // *sculpted* as the thing its symbol depicts: their head, their rear and tail, their
    // paws, and coat markings on the spine and flanks. Qoob's own anatomy is now
    // the readout, so the player still identifies which side is which.
    //
    // Features are welded to the art node, so they roll with Qoob and get squashed
    // by the soft-body effect along with the rest of them. Placement is driven by
    // the symbol map rather than hard-coded, so the sculpt always agrees with
    // however `Level.startingFaces` assigns them.

    private func addCatFeatures(colors: [Face: Int], on art: Entity) {
        for face in Face.allCases {
            let symbol = CatSymbol.from(colors[face] ?? 0)

            // A frame at the body's *centre*, oriented so local +Z points out of
            // this side and local +Y is "up" across it. Features then give an (x, y)
            // across the side and `seat` finds the depth, so nothing floats off the
            // curve however round Qoob gets.
            let (_, orientation) = faceFrame(face, offset: 0)
            let panel = Entity()
            panel.orientation = orientation

            switch symbol {
            case .face:     sculptFace(on: panel)
            case .butt:     sculptRump(on: panel)
            case .paws:     sculptPaws(on: panel)
            case .dot:      sculptSpot(on: panel)
            case .ring:     sculptRing(on: panel)
            case .triangle: sculptThreeSpots(on: panel)
            }
            art.addChild(panel)
        }

        // Ears last, and on the body rather than a side: they're pinched out of the
        // loaf's own top corners, so they belong to the silhouette, not to a face.
        addEars(colors: colors, on: art)
    }

    // MARK: Coat roles
    //
    // Each piece of Qoob is tagged with what it *is* rather than what colour it
    // currently has, so an appearance switch can re-tint them in place. Rebuilding
    // instead would drop their roll orientation and orphan the soft-body and fur
    // effects, which hold references to their art node.

    private enum CoatRole: String {
        case body, marking, skin, eye, whisker
    }

    private func coatMaterial(_ role: CoatRole) -> PhysicallyBasedMaterial {
        switch role {
        case .body:    return furMaterial(tint: CatCoat.body(catStyle))
        case .marking: return furMaterial(tint: CatCoat.marking(catStyle))
        case .skin:    return pbr(CatCoat.nose(catStyle), roughness: 0.78)
        case .eye:     return pbr(CatCoat.eye(catStyle), roughness: 0.28)
        case .whisker: return pbr(CatCoat.whisker(catStyle), roughness: 0.5)
        }
    }

    /// A tagged mesh, so `restyleQoob` can find it again.
    private func coatPart(_ mesh: MeshResource, _ role: CoatRole) -> ModelEntity {
        let part = ModelEntity(mesh: mesh, materials: [coatMaterial(role)])
        part.name = role.rawValue
        return part
    }

    /// Re-tints Qoob for the current appearance: cream cat in light, black cat with
    /// blue eyes in dark.
    private func restyleQoob() {
        forEachModel(cubeArt) { model in
            guard let role = CoatRole(rawValue: model.name) else { return }
            model.model?.materials = [self.coatMaterial(role)]
        }
    }

    // MARK: Coat markings
    //
    // The three abstract symbols become markings in Qoob's coat — a spot, a ring
    // and three spots — rather than glyphs stuck on them. They're shallow patches
    // that hug the surface, so they read as fur colour from above and don't break
    // their outline the way the old decal planes did.

    private func sculptSpot(on panel: Entity) {
        panel.addChild(markingPatch(radius: 0.16, x: 0, y: 0))
    }

    private func sculptRing(on panel: Entity) {
        // Built from a circle of small patches: there's no torus primitive, and a
        // ring of dabs reads more like a natural coat marking anyway.
        let dabs = 14
        for i in 0..<dabs {
            let angle = Float(i) / Float(dabs) * 2 * .pi
            panel.addChild(markingPatch(radius: 0.042,
                                        x: cos(angle) * 0.16, y: sin(angle) * 0.16))
        }
    }

    private func sculptThreeSpots(on panel: Entity) {
        for (dx, dy) in [(Float(0), Float(0.16)), (-0.16, -0.12), (0.16, -0.12)] {
            panel.addChild(markingPatch(radius: 0.08, x: dx, y: dy))
        }
    }

    /// A single marking: a sphere squashed almost flat and seated on the surface, so
    /// it paints onto the coat rather than protruding from it.
    private func markingPatch(radius: Float, x: Float, y: Float) -> ModelEntity {
        let patch = coatPart(.generateSphere(radius: radius), .marking)
        seat(patch, x: x, y: y)
        patch.scale = f3(1, 1, 0.10)
        return patch
    }

    /// Places an entity with its *centre* on the body's surface, at an offset across
    /// the current side — so it sits half-embedded and half-proud, which is what a
    /// feature growing out of the body looks like. `proud` lifts it further out.
    ///
    /// Note there is deliberately no "sink" here. Pushing features inward by their
    /// own radius buried them completely once the body got properly round: at this
    /// corner radius the surface is 0.5 out at the middle of a side, so a flattened
    /// patch sunk by its radius ends up entirely inside the coat.
    private func seat(_ entity: Entity, x: Float, y: Float, proud: Float = 0) {
        entity.position = f3(Double(x), Double(y), Double(surfaceDepth(x: x, y: y) + proud))
    }

    /// Ears pinched out of the loaf's top corners.
    ///
    /// They used to be wedges parked on the face, in a contrasting tone, which read
    /// as hardware bolted to a box. On the cushion plush this is modelled on, the
    /// ears are the cushion's own corners drawn up into soft points — so these are
    /// built in the *body's* frame at the two top corners of the head side, in the
    /// body's own colour, as a taper of shrinking spheres that merges into the
    /// corner it grows from.
    private func addEars(colors: [Face: Int], on art: Entity) {
        // Whichever side carries the face is the front of the head; the ears sit on
        // the top corners shared by that side and the spine.
        guard let headFace = Face.allCases.first(where: {
            CatSymbol.from(colors[$0] ?? 0) == .face
        }) else { return }

        let (_, orientation) = faceFrame(headFace, offset: 0)
        let holder = Entity()
        holder.orientation = orientation

        for side in [Float(-1), 1] {
            let corner = f3(Double(side) * 0.30, 0.30, 0.24)
            let tip = f3(Double(side) * 0.44, 0.56, 0.16)

            let beads = 5
            for i in 0..<beads {
                let t = Float(i) / Float(beads - 1)
                let bead = coatPart(.generateSphere(radius: 0.115 * (1 - 0.62 * t)), .body)
                bead.position = mix(corner, tip, t: SIMD3<Float>(repeating: t))
                holder.addChild(bead)
            }

            // A dab of skin tone inside each ear, the way the plush has a paler
            // inner ear — small enough that it never reads as a second marking.
            let inner = coatPart(.generateSphere(radius: 0.05), .skin)
            inner.position = mix(corner, tip, t: SIMD3<Float>(repeating: 0.45))
                + f3(0, 0, 0.05)
            inner.scale = f3(1, 1.3, 0.45)
            holder.addChild(inner)
        }
        art.addChild(holder)
    }

    /// The head: a minimal face — two almond eyes and a small nose, nothing more.
    ///
    /// Deliberately sparse, following the plush: the previous version had a big
    /// domed muzzle that swallowed the middle of the side and left them looking
    /// snouted rather than cat-like.
    private func sculptFace(on panel: Entity) {
        for side in [Float(-1), 1] {
            let eye = coatPart(.generateSphere(radius: 0.062), .eye)
            seat(eye, x: side * 0.155, y: 0.075)
            eye.scale = f3(0.85, 1.25, 0.30)      // almond, not round
            panel.addChild(eye)
        }

        let nose = coatPart(.generateSphere(radius: 0.055), .skin)
        seat(nose, x: 0, y: -0.075)
        nose.scale = f3(1.25, 0.9, 0.45)
        panel.addChild(nose)

        // Whiskers: three a side, in the coat's opposing colour — dark on the cream
        // cat, white on the black one. An earlier pass drew them in a low-contrast
        // grey and they read as specks of dirt; at a pixel or two wide, full contrast
        // is what makes a whisker a line instead of a smudge.
        //
        // They fan from beside the nose rather than from the outer edge of the side,
        // so they stay on the flat of the face and don't wrap around their corner.
        for side in [Float(-1), 1] {
            for (i, dy) in [Float(0.02), -0.035, -0.09].enumerated() {
                let whisker = coatPart(.generateBox(width: 0.26, height: 0.022, depth: 0.022,
                                                    cornerRadius: 0.011), .whisker)
                seat(whisker, x: side * 0.20, y: dy, proud: 0.012)
                whisker.orientation = quat(side * Float(i - 1) * -0.26, f3(0, 0, 1))
                panel.addChild(whisker)
            }
        }
    }

    /// The backside: just the tail, curling up over their back.
    ///
    /// Haunches were tried here and removed. As broad shallow domes they competed
    /// with everything else on the side and read as grey ovals stuck on rather
    /// than as a cat. The tail alone says "rear end" immediately.
    private func sculptRump(on panel: Entity) {
        // The tail is one swept tube: a single mesh, circular rings threaded along
        // the curve and tapered base to tip.
        //
        // Two earlier attempts built it from separate solids — a line of small
        // spheres, then a chain of ellipsoids stretched along the curve. Both read
        // as corduroy: however much they overlapped, each solid showed its own
        // silhouette and caught its own highlight, so the tail looked like a
        // caterpillar or a spring. One mesh with shared normals has no joints to
        // crease.
        let samples = 16
        let points = (0..<samples).map { tailPoint(Float($0) / Float(samples - 1)) }

        if let mesh = tubeMesh(along: points, radius: tailRadius) {
            let tail = coatPart(mesh, .body)
            panel.addChild(tail)
        }

        // Rounded ends: the tube is open, and these are cheaper than capping it.
        let tip = coatPart(.generateSphere(radius: tailRadius(1)), .body)
        tip.position = points[samples - 1]
        panel.addChild(tip)

        let root = coatPart(.generateSphere(radius: tailRadius(0)), .body)
        root.position = points[0]
        panel.addChild(root)

        // Three short, crossed stitches form the plush-style asterisk.
        for angle in [Float(0), .pi / 3, -.pi / 3] {
            let stitch = coatPart(
                .generateBox(width: 0.14, height: 0.025, depth: 0.018,
                             cornerRadius: 0.012),
                .skin
            )
            seat(stitch, x: 0, y: -0.06, proud: 0.012)
            stitch.orientation = quat(angle, f3(0, 0, 1))
            panel.addChild(stitch)
        }
    }

    /// Sweeps a tapered circular tube along `points`.
    ///
    /// Rings are oriented by parallel transport rather than against a fixed world
    /// axis: carrying the previous ring's orientation forward keeps the tube from
    /// twisting where the curve turns, and avoids the degenerate case of a tangent
    /// that happens to line up with the reference axis.
    private func tubeMesh(along points: [SIMD3<Float>],
                          radius: (Float) -> Float,
                          sides: Int = 12) -> MeshResource? {
        guard points.count >= 2 else { return nil }

        // Central difference, so each ring faces along the curve rather than along
        // one of the segments meeting at it.
        let tangents: [SIMD3<Float>] = points.indices.map { i in
            let previous = points[max(0, i - 1)]
            let next = points[min(points.count - 1, i + 1)]
            let delta = next - previous
            return simd_length(delta) > 1e-6 ? simd_normalize(delta) : SIMD3<Float>(0, 1, 0)
        }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        positions.reserveCapacity(points.count * sides)
        normals.reserveCapacity(points.count * sides)

        // Seed the first ring's "up" from whichever world axis the tangent leans on
        // least, so the cross product is well conditioned.
        var reference: SIMD3<Float> = {
            let t = tangents[0]
            let seed: SIMD3<Float> = abs(t.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 0, 1)
            return simd_normalize(seed - t * simd_dot(seed, t))
        }()

        for i in points.indices {
            let tangent = tangents[i]
            var normal = reference - tangent * simd_dot(reference, tangent)
            if simd_length(normal) < 1e-5 {
                let fallback = SIMD3<Float>(0, 0, 1)
                normal = fallback - tangent * simd_dot(fallback, tangent)
            }
            normal = simd_normalize(normal)
            reference = normal
            let binormal = simd_cross(tangent, normal)

            let r = radius(Float(i) / Float(points.count - 1))
            for s in 0..<sides {
                let angle = Float(s) / Float(sides) * 2 * .pi
                let outward = normal * cos(angle) + binormal * sin(angle)
                positions.append(points[i] + outward * r)
                normals.append(outward)
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity((points.count - 1) * sides * 6)
        for i in 0..<(points.count - 1) {
            for s in 0..<sides {
                let next = (s + 1) % sides
                let a = UInt32(i * sides + s)
                let b = UInt32(i * sides + next)
                let c = UInt32((i + 1) * sides + s)
                let d = UInt32((i + 1) * sides + next)
                // Counter-clockwise seen from outside, so the front faces point out.
                // Reversed, the tube renders its interior and shows up black.
                indices += [a, b, c, b, d, c]
            }
        }

        var descriptor = MeshDescriptor(name: "tail")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// The tail's path across the rump, `t` running base (0) to tip (1).
    ///
    /// Rooted above the pucker, where a tail actually attaches, then sweeping up and
    /// curling to one side while lifting away from the body — so from straight above
    /// it reads as a tail rather than a line drawn on them.
    private func tailPoint(_ t: Float) -> SIMD3<Float> {
        let curl = t * 2.0                      // radians swept
        let reach: Float = 0.30
        let rootY: Float = 0.10
        // The base starts *inside* the body, so the tube's open end and its plug are
        // buried rather than sitting proud as a bump on the rump.
        return SIMD3<Float>(sin(curl) * reach,
                            rootY + (1 - cos(curl)) * reach * 1.1,
                            surfaceDepth(x: 0, y: rootY) - 0.07 + 0.22 * t * t)
    }

    /// Thick at the base, fine at the tip.
    private func tailRadius(_ t: Float) -> Float { 0.075 * (1 - 0.6 * t) }

    /// Four paw pads, so landing this side up genuinely reads as paws in the air.
    ///
    /// The four are placed symmetrically about the middle of the side. They used to
    /// be laid out by hand at rows -0.15 and +0.21, which isn't centred, and each
    /// pad's toes push its own outline further up still — so the whole set sat high
    /// and off to one side, and the pads that wrapped around Qoob's rounded corner
    /// looked scattered rather than like a tidy set of paws.
    private func sculptPaws(on panel: Entity) {
        let padRadius: Float = 0.095
        let toeRadius: Float = 0.034
        let toeReach: Float = 0.135      // how far a pad's toes sit above it
        let spread: Float = 0.16         // each paw's distance from the middle

        // A pad-and-toes unit runs from -padRadius up to +toeReach + toeRadius, so
        // its own centre is above the pad. Offsetting by that keeps the four units —
        // not just the four pads — symmetric about the middle of the side.
        let unitCentre = (toeReach + toeRadius - padRadius) / 2

        for sx in [Float(-1), 1] {
            for sy in [Float(-1), 1] {
                let dx = sx * spread
                let dy = sy * spread - unitCentre

                let pad = coatPart(.generateSphere(radius: padRadius), .skin)
                seat(pad, x: dx, y: dy)
                pad.scale = f3(1, 1, 0.45)
                panel.addChild(pad)

                // Toe beans, the middle one reaching slightly further than its
                // neighbours so the three read as a curve rather than a straight bar.
                for tx in [Float(-0.075), 0, 0.075] {
                    let toe = coatPart(.generateSphere(radius: toeRadius), .skin)
                    seat(toe, x: dx + tx,
                         y: dy + (tx == 0 ? toeReach : toeReach - 0.018))
                    toe.scale = f3(1, 1, 0.45)
                    panel.addChild(toe)
                }
            }
        }
    }

    /// A deliberately-supplied body mesh: a loose `cube_cat.usdz` / `.usdc` /
    /// `.reality` dropped into the bundle. Returns nil normally, so the sculpted
    /// loaf in `buildCatBody` is used.
    ///
    /// The `CubeCatModel` Data Set in the asset catalogue is intentionally *not*
    /// consulted: it's a single mesh with one flat material — a plain rounded box
    /// with no cat in it — and the sculpted body supersedes it. Drop in a real cat
    /// model as a loose file and it takes over, keeping its own materials.
    private func loadOverrideModel() -> Entity? {
        var url: URL?
        for ext in ["usdz", "usdc", "reality"] {
            if let found = Bundle.main.url(forResource: "cube_cat", withExtension: ext) {
                url = found
                break
            }
        }
        guard let url, let loaded = try? Entity.load(contentsOf: url) else { return nil }

        let bounds = loaded.visualBounds(relativeTo: nil)
        let maxDim = max(bounds.extents.x, max(bounds.extents.y, bounds.extents.z))
        guard maxDim > 0 else { return nil }

        let holder = Entity()
        let s = cubeSize / maxDim
        loaded.scale = SIMD3<Float>(repeating: s)
        loaded.position = -bounds.center * s
        holder.addChild(loaded)
        return holder
    }

    /// Position + orientation of a frame sitting on the given side of the body:
    /// local +Z points out of it, local +Y is "up" across it. Sculpted features are
    /// built in that frame.
    private func faceFrame(_ face: Face, offset h: Float) -> (SIMD3<Float>, simd_quatf) {
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

    /// Qoob's coat: soft matte fabric, the way a cushion plush actually looks.
    ///
    /// This used to be a fur surface — a tiled strand normal map, anisotropic
    /// highlights and a strong clearcoat, all aimed at faking fur without shell
    /// geometry. Two problems. The strand normals scattered light away from the
    /// camera hard enough to turn a 0.94-albedo cream coat into mid-grey, well
    /// darker than the floor beside it. And the plush this now follows has no
    /// visible strands at all: it's smooth fabric. Dropping the normal map and the
    /// anisotropy both fixes the value and matches the reference.
    ///
    /// `sheen` stays — that's what gives fabric its soft rim — scaled by how dark
    /// the coat is, so the black cat isn't rimmed back to grey.
    private func furMaterial(tint: UIColor? = nil) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        let tint = tint ?? CatCoat.body(catStyle)

        // A very faint speckle, so the coat isn't a dead flat fill.
        let albedo = BundledTextures.fur ?? ProceduralFur.albedo()
        if let tex = loadTexture(albedo, semantic: .color) {
            m.baseColor = .init(tint: tint, texture: repeatTexture(tex))
        } else {
            m.baseColor = .init(tint: tint)
        }
        m.textureCoordinateTransform = .init(scale: SIMD2<Float>(furTiling, furTiling))

        m.roughness = 0.88          // matte fabric, not a glossy toy
        m.metallic = 0.0
        m.sheen = .init(tint: UIColor(white: CGFloat(sheenStrength(for: tint)), alpha: 1))
        return m
    }

    /// Sheen and clearcoat, scaled by the coat's own brightness so dark coats stay
    /// dark. Never quite zero — even black plush catches a little light on the nap.
    private func sheenStrength(for tint: UIColor) -> Float {
        var white: CGFloat = 1
        var alpha: CGFloat = 1
        guard tint.getWhite(&white, alpha: &alpha) else { return 1 }
        return Float(0.12 + 0.88 * white)
    }

    /// How many times the fur texture tiles across one cube face.
    private let furTiling: Float = 3.0


    /// The floor texture for a room's surface. `.checkerboard` returns nil (it was
    /// coloured per cell, and there are no per-cell tiles any more).
    ///
    /// `.default` means "whatever this room's floor is", which now resolves to a
    /// procedurally-drawn per-room floor. A bundled `floor_<room>` asset still
    /// wins if you drop one in.
    /// The seed of the house on screen, so a floor variant is chosen per house.
    private var houseSeed: UInt64 = 0

    /// Bundled floor variants per room kind: `floor_livingRoom`, `floor_livingRoom2`…
    /// Probed and cached, the same way furniture variants are.
    private var floorVariantCounts: [String: Int] = [:]

    /// Which of a room kind's floor textures this house uses.
    ///
    /// Chosen from the house seed rather than per room, because a house is carpeted
    /// once: two living rooms in the same house should match, and the next house can
    /// have a different carpet. Deterministic, so the scene rebuild `present` does
    /// can't refloor the room mid-play.
    private func floorVariantName(_ base: String) -> String {
        let count: Int = {
            if let known = floorVariantCounts[base] { return known }
            var n = 1
            while n < 4, BundledTextures.image(base + "\(n + 1)") != nil { n += 1 }
            floorVariantCounts[base] = n
            return n
        }()
        guard count > 1 else { return base }
        var h = houseSeed &+ 0x9E37_79B9_7F4A_7C15
        h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
        h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
        h ^= h >> 31
        let index = Int(h % UInt64(count))
        return index == 0 ? base : base + "\(index + 1)"
    }

    private func floorTexture(for env: Environment) -> UIImage? {
        if let themed = ProceduralTextures.floorTexture(floorTheme) { return themed }
        if floorTheme == .checkerboard { return nil }
        // This room's own drop-in asset, else this room's procedural floor. The generic
        // `carpet_albedo` used to sit between them, which meant any room without a
        // `floor_<room>` asset of its own got carpet — so the moment someone dropped a
        // carpet PNG in, the sandpit and the patio would be carpeted. It only ever
        // looked right because both placeholder imagesets are empty.
        return BundledTextures.image(floorVariantName(env.floorTextureName))
            ?? ProceduralTextures.roomFloor(for: env, appearance)
    }

    private func floorNormal(for env: Environment) -> UIImage? {
        if let themed = ProceduralTextures.floorNormal(floorTheme) { return themed }
        if floorTheme == .checkerboard { return nil }
        // A dropped-in `floor_<room>_normal` wins, matching how `floorTexture` prefers
        // `floor_<room>`. Without this the base colour could come from a real material
        // while its relief stayed procedural, which is worse than either on its own —
        // grass photographed at 2048 lit by a normal map drawn for carpet.
        //
        // Same correction as `floorTexture` otherwise: the room's own relief, not
        // carpet's. A carpet normal map over sand or paving would emboss a weave
        // into stone.
        // Matched to whichever base-colour variant this house drew, so a carpet's weave
        // and its relief can't come from different materials.
        return BundledTextures.image(floorVariantName(env.floorTextureName) + "_normal")
            ?? BundledTextures.image(env.floorTextureName + "_normal")
            ?? ProceduralTextures.roomFloorNormal(for: env)
    }

    /// A ground plane under the whole board: floor texture if supplied, else
    /// the environment's ground colour.
    private func addGround(_ board: BoardModel) {
        let extent = Float(max(board.width, board.height)) + 6
        let mesh = MeshResource.generatePlane(width: extent, depth: extent)
        var mat: PhysicallyBasedMaterial
        if let tex = floorTexture(for: environment), let res = loadTexture(tex, semantic: .color) {
            mat = PhysicallyBasedMaterial()
            mat.baseColor = .init(tint: .white, texture: repeatTexture(res))
            if let n = floorNormal(for: environment), let nres = loadTexture(n, semantic: .normal) {
                mat.normal = .init(texture: repeatTexture(nres))
            }
            mat.textureCoordinateTransform = groundTextureTransform(
                extent: extent,
                centre: SIMD2<Float>(Float(board.width - 1) / 2, Float(board.height - 1) / 2))
            mat.roughness = 0.95
            resetEmission(&mat)
        } else {
            mat = pbr(environment.groundColor(appearance), roughness: 1.0)
        }
        let node = ModelEntity(mesh: mesh, materials: [mat])
        // Sits just under the tile tops rather than below the slab. At a full
        // tile-thickness lower, the slab's side faces caught the light and drew a
        // step around the board — an edge the play area shouldn't have. It also
        // shows through where the room's outline is cut away, reading as the floor
        // continuing past the walls.
        node.position = f3(Double(board.width - 1) / 2.0,
                           Double(-tileThickness) * 0.15,
                           Double(board.height - 1) / 2.0)
        boardAnchor.addChild(node)
        groundEntity = node
    }

    /// UV transform that makes the surrounding ground continue the board's own floor
    /// pattern instead of restarting it.
    ///
    /// The ground used to scale its UVs by `extent`, giving one texture repeat per
    /// world unit, while the tiles use `floorTexScale` — one repeat per two units.
    /// The two densities met at the board edge and the mismatch read as a seam
    /// running around the play area. Matching the scale *and* phasing the offset to
    /// the grid makes the floor one continuous surface.
    private func groundTextureTransform(extent: Float,
                                        centre: SIMD2<Float>) -> PhysicallyBasedMaterial.TextureCoordinateTransform {
        let s = Float(floorTexScale)
        // A tile at `col` maps world x to UV s * (x + 0.5); the plane's UV 0 sits at
        // its own left/near edge, `extent / 2` before the board's centre.
        let offset = SIMD2<Float>(s * (centre.x - extent / 2 + 0.5),
                                  s * (centre.y - extent / 2 + 0.5))
        return .init(offset: offset, scale: SIMD2<Float>(s * extent, s * extent))
    }

    /// A plain floor tile. Continuous floor across cells: offset each tile's
    /// UVs by its grid coords so the (seamless) pattern flows unbroken.
    /// How many copies of the floor texture span one board cell (see the
    /// SceneKit note). ~0.5 → one carpet copy every two cells.
    private let floorTexScale: Double = 0.5

    func applyFloorTheme(_ theme: FloorTheme) {
        floorTheme = theme

        // Re-skin the ground plane.
        if let ground = groundEntity {
            let extent = Float(max(boardCols, boardRows)) + 6
            var mat: PhysicallyBasedMaterial
            if let tex = floorTexture(for: environment), let res = loadTexture(tex, semantic: .color) {
                mat = PhysicallyBasedMaterial()
                mat.baseColor = .init(tint: .white, texture: repeatTexture(res))
                if let n = floorNormal(for: environment), let nres = loadTexture(n, semantic: .normal) {
                    mat.normal = .init(texture: repeatTexture(nres))
                }
                mat.textureCoordinateTransform = groundTextureTransform(
                    extent: extent,
                    centre: SIMD2<Float>(Float(boardCols - 1) / 2, Float(boardRows - 1) / 2))
                mat.roughness = 0.95
            } else {
                mat = pbr(environment.groundColor(appearance), roughness: 1.0)
            }
            ground.model?.materials = [mat]
        }

        // Nothing per-cell to re-skin: the floors are one slab per room, rebuilt with
        // the board. A live theme change would need `present` again — and there's no
        // theme picker any more, so this only ever runs at level start.
    }


    // MARK: - Furniture

    private func buildFurniture(_ level: Level) {
        // Variants are dealt out in turn per kind, not hashed per piece.
        //
        // Hashing each piece independently is uniform on average and still clumps where
        // it shows: four armchairs drawn independently from four models put three or more
        // of the same model in a room about a fifth of the time — measured at 16% — which
        // is the mass-produced look this was meant to fix. Dealing them in turn makes the
        // spread a guarantee: four armchairs get four different models. Pieces come out of
        // the generator room by room, so the rotation delivers its variety where a player
        // can see it in one screenful.
        var dealt: [FurnitureKind: Int] = [:]
        for piece in level.furniture {
            let base = piece.kind.modelBaseName
            let count = variantCount(base)
            let n = dealt[piece.kind] ?? startVariant(for: piece.kind, seed: level.seed, count: count)
            dealt[piece.kind] = n + 1
            let index = count > 1 ? n % count : 0
            let modelName = index == 0 ? base : base + "\(index + 1)"

            let (node, surface) = furnitureModel(piece, modelName: modelName)
                ?? (placeholderFurniture(piece), Float(piece.kind.height))
            if piece.kind == .lamp { switchOn(lamp: node, surface: surface) }
            node.position = f3(piece.centerCol, 0, piece.centerRow)
            boardAnchor.addChild(node)
            // Recorded per cell so `furnitureHeight` seats perched toys on the
            // surface actually drawn, not on the placeholder block's height.
            for cell in piece.cells { furnitureSurfaceHeight[cell] = surface }
        }
    }

    /// Top surface of the furniture drawn at each occupied cell.
    private var furnitureSurfaceHeight: [GridCell: Float] = [:]

    /// Held so per-cell look-ups (which room is this cell in?) work outside `present`.
    private weak var currentBoard: BoardModel?

    /// The room a cell belongs to, falling back to the starting room before the board
    /// has been handed over.
    private func environment(at col: Int, _ row: Int) -> Environment {
        currentBoard?.environment(at: GridCell(col: col, row: row)) ?? environment
    }

    /// Gap left around a piece so neighbouring furniture doesn't visually fuse.
    private let furnitureMargin: Float = 0.12

    /// How far a model may exceed the cells it blocks, as a multiple of them. A little
    /// overhang looks natural — furniture doesn't sit on a grid — but past this it
    /// starts hiding floor that's actually walkable.
    private let furnitureOverhang: Float = 1.25

    private func placeholderFurniture(_ piece: Furniture) -> Entity {
        let margin = furnitureMargin
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

    /// Loads `<kind>.usdz` if bundled, sized against Qoob. Falls back to the
    /// placeholder block when the kind has no model.
    ///
    /// Scaled uniformly to `kind.height` — a real furniture height at Qoob's scale —
    /// and *not* fitted to its cell footprint. Fitting to cells was the mistake: it
    /// made every piece as small as the grid squares it happened to occupy, so a
    /// fridge came out shorter than the cat standing next to it. Sizing by height
    /// against a known scale is the only way the room reads at the right proportions;
    /// the footprint stays what the piece blocks, and a wide piece may now overhang
    /// its cells a little, which looks far better than a doll's-house fridge.
    private func furnitureModel(_ piece: Furniture,
                                modelName: String) -> (node: Entity, surface: Float)? {
        guard let loaded = loadModel(modelName) else { return nil }
        let bounds = loaded.visualBounds(relativeTo: nil)

        // The sizing rule itself lives in Core so it can be tested without a renderer —
        // it rejects a degenerate model itself, which is the signal to fall back to the
        // placeholder block.
        // see `ModelFit`. Only the part that needs the mesh stays here: which way the
        // model's back points, which takes analysing where its tall mass sits.
        guard let fit = ModelFit.fit(extents: bounds.extents,
                                     cols: piece.cols, rows: piece.rows,
                                     targetHeight: Float(piece.kind.height),
                                     hasFacing: piece.kind.hasFacing,
                                     facing: piece.facing,
                                     modelBack: piece.kind.hasFacing
                                        ? modelBackAxis(loaded, name: modelName) : nil,
                                     cubeSize: cubeSize,
                                     overhang: furnitureOverhang) else { return nil }
        let turns = fit.quarterTurns
        let s = fit.scale

        loaded.scale = SIMD3<Float>(repeating: s)
        // Centred on X/Z and resting on the floor.
        loaded.position = f3(Double(-bounds.center.x * s),
                             Double(-bounds.min.y * s),
                             Double(-bounds.center.z * s))

        let holder = Entity()
        holder.addChild(loaded)
        // Safe to spin the holder: the model is centred on X/Z beneath it, so a
        // Y rotation through the origin turns it in place.
        if turns != 0 {
            holder.transform.rotation = quat(Float(turns) * .pi / 2, f3(0, 1, 0))
        }
        return (holder, fit.surface)
    }

    // MARK: - Pushable toys

    private func itemPosition(col: Int, row: Int,
                              offset: SIMD3<Float> = .zero) -> SIMD3<Float> {
        f3(Double(col), Double(toyRadius), Double(row)) + offset
    }

    /// Where each toy sits inside its cell. Keyed by the entity rather than by the cell,
    /// so the offset travels with a toy when it's pushed instead of being recomputed at
    /// the far end and making it jump sideways on arrival.
    private var toyOffsets: [ObjectIdentifier: SIMD3<Float>] = [:]

    /// Toys live on their own half-cell grid: a quarter of a cell off centre on both
    /// axes, so each one sits nearer a corner of its cell than the middle of it.
    ///
    /// Purely where a toy is *drawn*. Everything the game reasons about is still whole
    /// cells — the push, the basket, what Qoob rolls into — but a floor of toys each
    /// dead-centre in its square reads as a layout, and the grid it shares with the
    /// furniture becomes obvious. Off the centre by a half step they read as dropped.
    ///
    /// Derived from the toy's first cell and then remembered, so the scene rebuild that
    /// `present` does can't reshuffle them.
    private func toyOffset(_ node: Entity, seed: GridCell) -> SIMD3<Float> {
        let key = ObjectIdentifier(node)
        if let known = toyOffsets[key] { return known }
        // A bit each per axis, off a properly avalanched hash — see `cellHash`.
        let mixed = Self.cellHash(seed)
        let step = cubeSize * 0.25
        let offset = f3(Double(mixed & 1 == 0 ? -step : step), 0,
                        Double((mixed >> 1) & 1 == 0 ? -step : step))
        toyOffsets[key] = offset
        return offset
    }

    private func buildItems(_ level: Level) {
        if let basket = level.basket {
            let node = makeBasket()
            liftEmissionForNight(node)
            node.position = f3(Double(basket.col), 0, Double(basket.row))
            boardAnchor.addChild(node)
        }
        for cell in level.items {
            let toy = makeToy(at: cell)
            toy.position = itemPosition(col: cell.col, row: cell.row,
                                        offset: toyOffset(toy, seed: cell))
            boardAnchor.addChild(toy)
            itemEntities[cell] = toy
        }
    }

    private func buildPerched(_ level: Level) {
        for p in level.perched {
            let h = furnitureHeight(at: p.perch, in: level)
            let toy = makeToy(at: p.perch)
            // Off-centre on the furniture too, which is if anything more natural: a toy
            // left exactly in the middle of a sofa cushion looks placed.
            toy.position = f3(Double(p.perch.col), Double(h) + Double(toyRadius),
                              Double(p.perch.row)) + toyOffset(toy, seed: p.perch)
            boardAnchor.addChild(toy)
            perchedEntities[p.perch] = toy
        }
    }

    private func furnitureHeight(at cell: GridCell, in level: Level) -> Float {
        if let surface = furnitureSurfaceHeight[cell] { return surface }
        for piece in level.furniture where piece.cells.contains(cell) {
            return Float(piece.kind.height)
        }
        return 0
    }

    // MARK: - Bundled model lookup

    /// Data Set name prefix for the bundled models — `Model_sofa`, `Model_animal-cat`.
    private static let modelAssetPrefix = "Model_"

    /// A well-mixed hash of a grid cell, for the choices that have to be stable per cell
    /// — which model, which pet, which corner of the cell — but should look unrelated
    /// between neighbours.
    ///
    /// The obvious `col &* primeA ^ row &* primeB` is not good enough, and it showed:
    /// neighbouring cells picked the same value 62% of the time against the 25% two
    /// independent choices would give, and every row came out identical to the one below
    /// it. Multiplying by a constant only carries information *upward* through the word,
    /// so the low bits that a small `% count` or `& 1` actually reads barely change from
    /// one cell to the next — which is how a room ended up with three identical armchairs
    /// while the totals across a hundred houses looked perfectly even.
    ///
    /// This is SplitMix64's finaliser, whose whole job is to avalanche the high bits back
    /// down into the low ones.
    private static func cellHash(_ cell: GridCell) -> UInt64 {
        var h = UInt64(bitPattern: Int64(cell.col)) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(bitPattern: Int64(cell.row)) &* 0xD6E8_FEB8_6659_FD93
        h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
        h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
        return h ^ (h >> 31)
    }

    /// How many alternative models a kind has bundled, found by probing for
    /// `Model_sofa`, `Model_sofa2`, `Model_sofa3`… and cached.
    ///
    /// Probed rather than declared so the count can never disagree with what actually
    /// shipped: drop a `Model_sofa4` into the catalogue and it joins the rotation, and a
    /// kind with only one model keeps working with no special case.
    private var variantCounts: [String: Int] = [:]

    private func variantCount(_ base: String) -> Int {
        if let known = variantCounts[base] { return known }
        var count = 1
        // Capped low deliberately: this is a miss-until-it-fails probe, and four
        // alternatives is already more than a room ever shows at once.
        while count < 4, NSDataAsset(name: Self.modelAssetPrefix + base + "\(count + 1)") != nil {
            count += 1
        }
        variantCounts[base] = count
        return count
    }

    /// A board direction as a world vector. `col` runs along X and `row` along Z, so
    /// `.back` (increasing row, toward the viewer) is +Z.

    /// Which way a model's back faces in its own space, as one of ±X / ±Z — or nil when
    /// the model is symmetric enough that it has no discernible front.
    ///
    /// Worked out from the mesh rather than tabulated per model, because a table would be
    /// one more thing to keep in step every time a variant is added, and would say nothing
    /// about models from a pack nobody has used yet.
    ///
    /// The signal is where the *tall* mass sits. For seating that's literally the back —
    /// a sofa's backrest is the only part at full height. For casework it works for a
    /// different reason that points the same way: drawer fronts and fridge doors stick out,
    /// which pushes the bounding box's centre towards the front, leaving the carcass
    /// looking biased towards the back. Measured across all 28 bundled models this
    /// separates them cleanly — every sofa, armchair, bench and bed reads −Z, every
    /// dresser, counter and fridge reads +Z, and tables, stools, shrubs and trees come out
    /// symmetric, which is correct: they have no front.
    private func modelBackAxis(_ entity: Entity, name: String) -> SIMD3<Float>? {
        if let known = backAxisCache[name] { return known }
        var points: [SIMD3<Float>] = []
        Self.collectPositions(entity, into: &points)
        var result: SIMD3<Float>?
        defer { backAxisCache[name] = result }
        guard points.count > 8 else { return nil }

        let xs = points.map(\.x), ys = points.map(\.y), zs = points.map(\.z)
        guard let minY = ys.min(), let maxY = ys.max(),
              let minX = xs.min(), let maxX = xs.max(),
              let minZ = zs.min(), let maxZ = zs.max() else { return nil }
        let width = max(maxX - minX, 0.0001), depth = max(maxZ - minZ, 0.0001)
        let cut = minY + (maxY - minY) * 0.55
        let high = points.filter { $0.y >= cut }
        guard high.count > 4 else { return nil }
        let hx = high.map(\.x).reduce(0, +) / Float(high.count)
        let hz = high.map(\.z).reduce(0, +) / Float(high.count)
        // As a fraction of the model's own extent, so the threshold means the same thing
        // whatever scale the source pack authored at.
        let biasX = (hx - (minX + maxX) / 2) / width
        let biasZ = (hz - (minZ + maxZ) / 2) / depth
        let strength = max(abs(biasX), abs(biasZ))
        // Below this the model is symmetric and any direction picked would be noise.
        guard strength >= 0.04 else { return nil }
        if abs(biasX) > abs(biasZ) {
            result = SIMD3(biasX > 0 ? 1 : -1, 0, 0)
        } else {
            result = SIMD3(0, 0, biasZ > 0 ? 1 : -1)
        }
        return result
    }

    /// Cached per model name — the mesh walk is cheap but there's no reason to repeat it
    /// for every sofa in the house. Nil is cached too, so a symmetric model isn't
    /// re-measured each time it appears.
    private var backAxisCache: [String: SIMD3<Float>?] = [:]

    /// Every vertex position in a hierarchy, in the root's own space.
    private static func collectPositions(_ entity: Entity, into out: inout [SIMD3<Float>],
                                         transform: simd_float4x4 = matrix_identity_float4x4) {
        let m = transform * entity.transform.matrix
        if let model = entity.components[ModelComponent.self] {
            for mesh in model.mesh.contents.models {
                for part in mesh.parts {
                    for p in part.positions {
                        let v = m * SIMD4<Float>(p.x, p.y, p.z, 1)
                        out.append(SIMD3<Float>(v.x, v.y, v.z))
                    }
                }
            }
        }
        for child in entity.children {
            collectPositions(child, into: &out, transform: m)
        }
    }

    /// Where a kind's variant rotation starts, so two houses don't always open with the
    /// same sofa. Derived from the house seed and the kind's position in `allCases` —
    /// *not* its `hashValue`, which Swift seeds per process, so it would pick a different
    /// model every launch of the same house.
    private func startVariant(for kind: FurnitureKind, seed: UInt64, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let kindIndex = FurnitureKind.allCases.firstIndex(of: kind) ?? 0
        var h = seed &+ UInt64(kindIndex) &* 0x9E37_79B9_7F4A_7C15
        h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
        h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
        h ^= h >> 31
        return Int(h % UInt64(count))
    }

    /// Finds a bundled mesh by base name. A loose file at the bundle root is
    /// checked first, so the documented drop-in override still works (see
    /// BUILD.md): drop `sofa.usdz` in and it beats the shipped one.
    private func modelURL(_ name: String) -> URL? {
        for ext in ["usdz", "usdc", "reality"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        }
        return dataSetModelURL(name)
    }

    /// The models ship as asset-catalogue Data Sets (the catalogue is already a
    /// folder reference, so adding to it needs no project change). `Entity.load`
    /// only takes a URL and `NSDataAsset` only hands back bytes, so the data is
    /// spilled to a temporary file first.
    ///
    /// RealityKit does have a `Data`-based initialiser, but it's `async`, and the
    /// scene is built synchronously — adopting it would make scene construction
    /// async all the way up for no visible gain at these file sizes (~30KB each).
    private func dataSetModelURL(_ name: String) -> URL? {
        guard let asset = NSDataAsset(name: Self.modelAssetPrefix + name) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QoobModels", isDirectory: true)
        let url = dir.appendingPathComponent(name).appendingPathExtension("usdz")
        // Always rewritten rather than reused: the temporary directory can outlive
        // an app update, and a stale mesh from the previous build would silently win.
        // `modelCache` means this happens at most once per model per launch.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? asset.data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    /// Parsed meshes, held so a board with half a dozen toys reads each file once.
    /// Callers get a clone and are free to scale and seat it; the prototype stays
    /// untouched so later clones start from the model as authored.
    private var modelCache: [String: Entity] = [:]

    private func loadModel(_ name: String) -> Entity? {
        if let prototype = modelCache[name] { return prototype.clone(recursive: true) }
        guard let url = modelURL(name),
              let loaded = try? Entity.load(contentsOf: url) else { return nil }
        modelCache[name] = loaded
        return loaded.clone(recursive: true)
    }

    /// The bundled cube pets. Listed rather than discovered because Data Sets
    /// aren't enumerable the way a resource directory is; `Tools/obj2usdz.swift`
    /// generates the assets and this is the matching manifest. A name with no
    /// Data Set behind it is skipped at load, so a stale entry degrades quietly.
    private static let petModelNames = [
        "animal-beaver", "animal-bee", "animal-bunny", "animal-cat",
        "animal-caterpillar", "animal-chick", "animal-cow", "animal-crab",
        "animal-deer", "animal-dog", "animal-elephant", "animal-fish",
        "animal-fox", "animal-giraffe", "animal-hog", "animal-koala",
        "animal-lion", "animal-monkey", "animal-panda", "animal-parrot",
        "animal-penguin", "animal-pig", "animal-polar", "animal-tiger",
    ]

    /// Marks a toy built from a pet model, so the push animation can keep it on
    /// its feet (a ball may land any way up; a pet may not).
    private static let petToyName = "petToy"

    // MARK: - Toys

    /// A toy for the cat to push: one of the bundled cube pets, or the procedural
    /// yarn ball when none are bundled.
    private func makeToy(at cell: GridCell) -> Entity {
        makePetToy(at: cell) ?? makeBallToy()
    }

    /// The original yarn ball, kept as the fallback.
    private func makeBallToy() -> Entity {
        let ball = MeshResource.generateSphere(radius: toyRadius)
        let mat = pbr(UIColor(red: 0.86, green: 0.30, blue: 0.42, alpha: 1), roughness: 0.8)
        return ModelEntity(mesh: ball, materials: [mat])
    }

    /// A cube pet sized to the ball it replaces, standing on its feet.
    private func makePetToy(at cell: GridCell) -> Entity? {
        let names = Self.petModelNames
        guard !names.isEmpty else { return nil }

        // Chosen from the cell, not at random: the scene is rebuilt whenever the
        // viewport changes shape, and a fresh draw shouldn't reshuffle which pet
        // is sitting where.
        let pick = Int(Self.cellHash(cell) % UInt64(names.count))
        guard let loaded = loadModel(names[pick]) else { return nil }

        let b = loaded.visualBounds(relativeTo: nil)
        let widest = max(b.extents.x, b.extents.z)
        guard widest > 0 else { return nil }

        // Match the ball's footprint so the goal pads still frame it and the
        // pushing reads at the same scale.
        let s = (toyRadius * 2) / widest
        loaded.scale = SIMD3<Float>(repeating: s)
        // Toys are positioned by their centre at y = toyRadius (the ball's radius),
        // so drop the pet's feet to -toyRadius to stand it on the floor — or on a
        // furniture surface, which is placed the same way.
        loaded.position = f3(Double(-b.center.x * s),
                             Double(-toyRadius - b.min.y * s),
                             Double(-b.center.z * s))

        let holder = Entity()
        holder.name = Self.petToyName
        holder.addChild(loaded)
        return holder
    }

    /// Tints a toy's emission when it's sitting on (or has reached) a goal.
    /// Puts a real light inside a standard lamp, and lights its shade.
    ///
    /// A **spotlight**, aimed down, and that choice is forced: `PointLightComponent` has
    /// no `Shadow` type at all, so a point light illuminates without casting anything.
    /// The lamp lit the floor while every shadow in the room still came from the
    /// directional key — light from one place, shadows from another. Only
    /// `SpotLightComponent` and `DirectionalLightComponent` can cast, so the lamp is a
    /// spotlight, and its shadows now radiate away from the lamp as they should.
    ///
    /// A shade throws most of its light down in a cone anyway, so this is closer to the
    /// real fitting than an omnidirectional bulb was. The cone is deliberately wide —
    /// 55° to 105° — because a narrow one reads as a theatre spot rather than a lamp, and
    /// the falloff between inner and outer angle is what softens the edge of the pool.
    ///
    /// Only lit in dark mode. The lamp stays in the room by day as furniture, switched
    /// off, which is both true to life and means the daytime rooms gained a piece.
    private func switchOn(lamp node: Entity, surface: Float) {
        guard appearance == .dark else { return }
        // RealityKit allows eight dynamic lights, and only lifts that on Apple6+ GPUs.
        // The key and three fills take four, so four are left — and houses average three
        // lamps with up to two per room, which would otherwise sail past the limit and
        // start dropping lights unpredictably. Past the cap a lamp still shows a lit
        // shade, so it reads as on; it just doesn't light the room.
        guard lampLightsUsed < Self.maxLampLights else {
            liftEmission(node, colour: Self.lampGlow, intensity: 0.75)
            return
        }
        lampLightsUsed += 1

        let bulb = Entity()
        // Just under the top of the shade, where the bulb would be.
        bulb.position = f3(0, Double(surface) * 0.82, 0)
        // A spotlight points along its own -Z, so it needs turning to face -Y.
        bulb.transform.rotation = quat(-.pi / 2, f3(1, 0, 0))
        var spot = SpotLightComponent(
            color: Self.lampLight,
            // Lumens. Kept from the point-light tuning, where 5200 — a bright domestic
            // bulb — produced no visible pool at all and 60000 washed the floor out.
            // A cone concentrates what a sphere spread everywhere, so this reads brighter
            // than the same figure did before.
            intensity: 24000,
            innerAngleInDegrees: 55,
            outerAngleInDegrees: 105,
            // In world units, and a cell is one — so the pool is a few cells across and
            // the room beyond it stays night.
            attenuationRadius: 7)
        spot.attenuationFalloffExponent = 1.6
        bulb.components.set(spot)

        // A shadow is a full extra render of the scene's shadow-casters from that
        // light's point of view, every frame — nothing else a lamp does costs
        // remotely as much. `maxLampLights` (4) is sized against RealityKit's
        // *hardware* light-count ceiling; shadows have no such API limit to hide
        // behind, so left uncapped, four lamps plus the key directional's own
        // shadow meant five full shadow passes a frame on top of everything else
        // the scene draws — enough to measurably heat the device in play. Past
        // `maxLampShadows` a lamp still lights the room (and still glows), it just
        // doesn't throw its own shadow — the room's shadows come from the key and
        // whichever lamps are still under budget.
        if lampShadowsUsed < Self.maxLampShadows {
            lampShadowsUsed += 1
            bulb.components.set(SpotLightComponent.Shadow())
        }
        node.addChild(bulb)
        // The shade has to look lit, or the pool of light appears from nowhere.
        liftEmission(node, colour: Self.lampGlow, intensity: 0.75)
    }

    /// Warm tungsten, and the slightly paler tint the shade itself takes.
    private static let lampLight = UIColor(red: 1.00, green: 0.87, blue: 0.68, alpha: 1)
    private static let lampGlow = UIColor(red: 1.00, green: 0.90, blue: 0.72, alpha: 1)

    /// See `switchOn(lamp:surface:)` — four directionals are already spoken for.
    private static let maxLampLights = 4

    /// See `switchOn(lamp:surface:)` — a shadow costs a full extra render pass, so this
    /// stays far below `maxLampLights`.
    private static let maxLampShadows = 1

    /// Reset per `present`, since the whole scene is rebuilt there.
    private var lampLightsUsed = 0
    private var lampShadowsUsed = 0

    /// Lifts a subtree's emission so it stays readable with the lights off.
    ///
    /// Used on the basket and the litterbox, which are the two things the player aims at.
    /// Both are ordinary lit geometry — a dark woven basket and a low box — so at night
    /// they sank into the floor and the objective disappeared. The target pads never had
    /// this problem because they're `unlitMaterial`, and this is the same decision applied
    /// to the other two: what you're aiming at is legible whatever the light is doing.
    /// A low value, so they read as catching the light rather than as glowing.
    private func liftEmissionForNight(_ node: Entity) {
        guard appearance == .dark else { return }
        // Cool, so it reads as catching the moonlight rather than as being lit from inside.
        liftEmission(node, colour: UIColor(red: 0.62, green: 0.70, blue: 0.92, alpha: 1),
                     intensity: 0.22)
    }

    /// Sets the emissive slot across a subtree.
    private func liftEmission(_ node: Entity, colour: UIColor, intensity: Float) {
        for model in modelEntities(in: node) {
            guard var materials = model.model?.materials, !materials.isEmpty else { continue }
            for i in materials.indices {
                guard var mat = materials[i] as? PhysicallyBasedMaterial else { continue }
                mat.emissiveColor = .init(color: colour)
                mat.emissiveIntensity = intensity
                materials[i] = mat
            }
            model.model?.materials = materials
        }
    }

    private func setToyGlow(_ node: Entity, on: Bool) {
        // A pet toy is a holder with the loaded model (and its own sub-parts)
        // underneath, so walk the subtree rather than assuming this node carries
        // the geometry itself.
        for model in modelEntities(in: node) {
            guard var materials = model.model?.materials, !materials.isEmpty else { continue }
            for i in materials.indices {
                guard var mat = materials[i] as? PhysicallyBasedMaterial else { continue }
                mat.emissiveColor = .init(color: .white)
                mat.emissiveIntensity = on ? 0.35 : 0.0
                materials[i] = mat
            }
            model.model?.materials = materials
        }
    }

    /// Every `ModelEntity` in a subtree, the root included.
    private func modelEntities(in entity: Entity) -> [ModelEntity] {
        var out: [ModelEntity] = []
        if let model = entity as? ModelEntity { out.append(model) }
        for child in entity.children { out.append(contentsOf: modelEntities(in: child)) }
        return out
    }

    /// The litterbox: a shallow tray of grit, and the way into the next house.
    ///
    /// Drawn rather than modelled — a low rim with a fill inside it, which at this
    /// camera angle reads as a tray from directly above. Deliberately not one of the
    /// pulsing pads: those mean "put something here", and this one means "leave".
    private func buildLitterbox(_ level: Level) {
        guard let cell = level.litterbox else { return }
        let holder = Entity()
        holder.position = f3(Double(cell.col), 0, Double(cell.row))

        let side = cubeSize * 0.92
        let rimHeight = cubeSize * 0.16
        let rim = ModelEntity(
            mesh: .generateBox(width: side, height: rimHeight, depth: side, cornerRadius: 0.06),
            materials: [pbr(UIColor(red: 0.36, green: 0.40, blue: 0.46, alpha: 1), roughness: 0.8)])
        rim.position = f3(0, Double(rimHeight) / 2.0, 0)
        holder.addChild(rim)

        // The grit sits just above the rim's midline so the rim reads as a lip round it.
        let grit = ModelEntity(
            mesh: .generatePlane(width: side * 0.82, depth: side * 0.82),
            materials: [pbr(UIColor(red: 0.82, green: 0.76, blue: 0.62, alpha: 1), roughness: 1.0)])
        grit.position = f3(0, Double(rimHeight) * 0.92, 0)
        holder.addChild(grit)

        liftEmissionForNight(holder)
        boardAnchor.addChild(holder)
    }

    /// Rugs, laid flat on the floor.
    ///
    /// Built before the furniture so a piece standing on one draws over it, which is what
    /// you'd expect of a coffee table on a rug. They carry no collision at all — the
    /// board model has never heard of them — so Qoob rolls straight across.
    private func buildRugs(_ level: Level) {
        for rug in level.rugs {
            guard let loaded = loadModel("rug\(["A", "B", "C"][rug.variant % 3])") else { continue }
            let b = loaded.visualBounds(relativeTo: nil)
            guard b.extents.x > 0, b.extents.z > 0 else { continue }

            // Sized to the patch it covers rather than by height: a rug's thickness is
            // incidental, its footprint is the point. The models are 3×2 at native scale,
            // so this is usually a scale of 1.
            let targetW = Float(rug.cols) * cubeSize - furnitureMargin
            let targetD = Float(rug.rows) * cubeSize - furnitureMargin
            let modelLongOnX = b.extents.x >= b.extents.z
            let patchLongOnX = rug.cols >= rug.rows
            let quarterTurn = modelLongOnX != patchLongOnX
            let footW = quarterTurn ? b.extents.z : b.extents.x
            let footD = quarterTurn ? b.extents.x : b.extents.z
            let s = min(targetW / footW, targetD / footD)

            loaded.scale = SIMD3<Float>(repeating: s)
            // A hair above the floor slab, or the two planes fight for the same depth.
            loaded.position = f3(Double(-b.center.x * s), 0.004, Double(-b.center.z * s))

            let holder = Entity()
            holder.addChild(loaded)
            if quarterTurn { holder.transform.rotation = quat(.pi / 2, f3(0, 1, 0)) }
            holder.position = f3(rug.centerCol, 0, rug.centerRow)
            boardAnchor.addChild(holder)
        }
    }

    /// The toy basket: the one place toys are pushed to.
    ///
    /// Drawn as a woven-looking tub if no model is bundled, and replaced wholesale by
    /// `basket.usdz` if one is — the same drop-in slot the furniture uses, sized to the
    /// cell and stood on the floor.
    private func makeBasket() -> Entity {
        if let loaded = loadModel("basket") {
            let b = loaded.visualBounds(relativeTo: nil)
            let widest = max(b.extents.x, b.extents.z)
            if widest > 0, b.extents.y > 0 {
                // A basket is about Qoob's height — a cat can see over the rim.
                let s = min(cubeSize * 0.95 / widest, cubeSize * 0.8 / b.extents.y)
                loaded.scale = SIMD3<Float>(repeating: s)
                loaded.position = f3(Double(-b.center.x * s), Double(-b.min.y * s),
                                     Double(-b.center.z * s))
                let holder = Entity()
                holder.addChild(loaded)
                return holder
            }
        }

        let holder = Entity()
        let side = cubeSize * 0.86
        let height = cubeSize * 0.55
        let wall = cubeSize * 0.1
        let colour = UIColor(red: 0.72, green: 0.55, blue: 0.34, alpha: 1)   // wicker

        // Four sides and a base rather than one box, so it reads as open-topped from
        // above — which is the only angle that matters here.
        for (dx, dz) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
            let along = dx != 0
            let mesh = MeshResource.generateBox(width: along ? wall : side,
                                                height: height,
                                                depth: along ? side : wall,
                                                cornerRadius: wall * 0.3)
            let panel = ModelEntity(mesh: mesh, materials: [pbr(colour, roughness: 0.9)])
            panel.position = f3(dx * Double(side - wall) / 2.0,
                                Double(height) / 2.0,
                                dz * Double(side - wall) / 2.0)
            holder.addChild(panel)
        }
        let base = ModelEntity(
            mesh: .generateBox(width: side, height: wall, depth: side, cornerRadius: 0),
            materials: [pbr(colour.withAlphaComponent(0.95), roughness: 1.0)])
        base.position = f3(0, Double(wall) / 2.0, 0)
        holder.addChild(base)
        return holder
    }

    // MARK: - Board & highlights

    private func buildBoard(_ board: BoardModel) {
        addGround(board)
        buildWalls(board)
        buildFloors(board)
        buildHills(board)

        for row in 0..<board.height {
            for col in 0..<board.width where board.isFloor(col: col, row: row) {
                if let target = board.cells[row][col].target {
                    addTargetMarker(col: col, row: row, index: target)
                }
            }
        }
    }

    /// One floor slab per room, rather than one per cell.
    ///
    /// This was a box per cell — 96 of them on the old small board, which was fine, and
    /// nearly 1200 once the board became a whole house, which froze the app for seconds
    /// on load. Each was its own `ModelEntity` and its own material.
    ///
    /// A room is a rectangle of one surface, so it can be a single plane with the
    /// texture tiled across it by a UV transform — the same trick the surrounding ground
    /// already used. That's five slabs and five materials for a house, and it makes the
    /// per-room flooring simpler rather than harder: the material is chosen once for the
    /// room instead of being recomputed per cell.
    ///
    /// Doorway cells sit between rooms and belong to no rectangle, so they get their own
    /// small slab each. There are only ever a handful.
    private func buildFloors(_ board: BoardModel) {
        for room in board.rooms {
            let w = Float(room.cols.count) * cubeSize
            let d = Float(room.rows.count) * cubeSize
            let mesh = MeshResource.generatePlane(width: w, depth: d)
            let node = ModelEntity(mesh: mesh, materials: [roomFloorMaterial(room.kind,
                                                                            cols: room.cols,
                                                                            rows: room.rows)])
            node.position = f3(Double(room.cols.lowerBound) + Double(room.cols.count - 1) / 2.0,
                               0,
                               Double(room.rows.lowerBound) + Double(room.rows.count - 1) / 2.0)
            boardAnchor.addChild(node)
        }
        for door in board.doorways {
            let mesh = MeshResource.generatePlane(width: cubeSize, depth: cubeSize)
            let env = board.environment(at: door)
            let node = ModelEntity(mesh: mesh,
                                   materials: [roomFloorMaterial(env,
                                                                 cols: door.col..<(door.col + 1),
                                                                 rows: door.row..<(door.row + 1))])
            node.position = f3(Double(door.col), 0, Double(door.row))
            boardAnchor.addChild(node)
        }
    }

    /// The cut earth face of a mound's bank.
    ///
    /// A real dirt material if one's bundled, because this is the one surface where the
    /// relief genuinely shows: the risers are the only near-vertical faces outdoors, so
    /// they catch the light at a grazing angle where a normal map reads strongly, while
    /// the flat ground either side of them is lit almost head-on and barely shows its own.
    /// Falls back to the flat darkened ground colour it used to be.
    private func bankMaterial(_ env: Environment) -> PhysicallyBasedMaterial {
        guard let dirt = BundledTextures.image("mound_bank"),
              let res = loadTexture(dirt, semantic: .color) else {
            return pbr(scaled(env.groundColor(appearance), by: 0.62), roughness: 0.98)
        }
        var m = PhysicallyBasedMaterial()
        // Tinted toward the room's own ground so a grass bank and a sand bank still
        // belong to their yard rather than both reading as generic mud.
        m.baseColor = .init(tint: scaled(env.groundColor(appearance), by: 1.15),
                            texture: repeatTexture(res))
        if let n = BundledTextures.image("mound_bank_normal"),
           let nres = loadTexture(n, semantic: .normal) {
            m.normal = .init(texture: repeatTexture(nres))
        }
        // One repeat per cell, so the grain is the same size on a 5-cell bank as a 9-cell.
        m.textureCoordinateTransform = .init(scale: SIMD2<Float>(repeating: 1))
        m.roughness = 0.98
        resetEmission(&m)
        return m
    }

    /// The same colour, darker. Multiplied rather than blended toward black so the hue
    /// survives: a bank under grass should read as earth, not as grey.
    private func scaled(_ color: UIColor, by factor: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return color }
        return UIColor(red: r * factor, green: g * factor, blue: b * factor, alpha: a)
    }

    /// The mounds in the outdoor rooms: a bank of earth with the room's own ground laid
    /// over the top.
    ///
    /// Two entities per tier rather than one textured box. A box takes a single material
    /// on all six faces, and grass running down the vertical sides of a bank looks like a
    /// mistake — an earth cut is what's actually there. So the body is a tapered bank in a
    /// darkened ground colour and the walkable top is a plane carrying the same texture,
    /// phased to the mound's own position so the pattern runs on from the flat ground it
    /// rises out of.
    ///
    /// The bank is a smoothly curved rise (`moundMesh`), not a box or a straight-sided
    /// frustum: wide and rounded at the base, narrowing to exactly the lid's footprint at
    /// the top, with the taper easing in and out rather than cutting a straight ramp
    /// between two sharp creases. Qoob still climbs it in the same whole-cube-height
    /// rolls as before — this only changes the terrain art between tiers, not
    /// `tier.level` or how a roll resolves.
    ///
    /// Drawn a hair proud of the top face, because a plane exactly coplanar with the bank's
    /// own top z-fights.
    ///
    /// The lid is inset, and that's what makes a mound visible at all. The camera looks
    /// straight down by default, so a terrace shows only its top face — and with the
    /// room's own ground on it, at the bank's full width, the first version was literally
    /// invisible: sand on sand, with the dark bank hidden behind its own lid. Pulling the
    /// lid in leaves the bank's slope showing as a ring around the plateau, the way a
    /// contour line does.
    ///
    /// This matters more than looks. Qoob climbs exactly one level per roll, so how high
    /// something is *is* the puzzle, and a step you can't see is a step you can't plan.
    private func buildHills(_ board: BoardModel) {
        func encloses(_ tier: Terrace, contains other: Terrace) -> Bool {
            other.origin.col >= tier.origin.col &&
            other.origin.row >= tier.origin.row &&
            other.origin.col + other.cols <= tier.origin.col + tier.cols &&
            other.origin.row + other.rows <= tier.origin.row + tier.rows
        }
        for tier in board.hills {
            let env = board.environment(at: tier.origin)
            let w = Float(tier.cols) * cubeSize
            let d = Float(tier.rows) * cubeSize
            let h = Float(tier.level) * cubeSize

            // `level` is an absolute height, not a rise over whatever's beneath this
            // tier — a nested second tier sitting on top of a first still reports its
            // own full height. A frustum built from 0 to `h` for that tier would bury
            // most of its taper inside the tier below, leaving only a thin, barely
            // tapered sliver exposed above the rim — which reads as a near-vertical
            // step again, defeating the whole point of a slope. So the bank spans only
            // the actual rise: from the top of whatever tier (if any) fully encloses
            // this one, up to this tier's own height.
            let floor = board.hills
                .filter { $0.level < tier.level && encloses($0, contains: tier) }
                .map { Float($0.level) * cubeSize }
                .max() ?? 0
            let rise = h - floor

            // How much narrower the top is than the base. The lid has to be exactly
            // this size too — the mesh's top ring is a plain rectangle (see `moundMesh`),
            // so a lid any smaller leaves a hole and any larger leaves it floating past
            // the slope's own rim.
            //
            // A straight-sided taper of `inset == rise` leans only 27° off vertical, and
            // on device that measured no differently from a plain wall: ordinary camera
            // perspective foreshortens a flat vertical wall's top edge by about that much
            // on its own, so the "taper" was invisible against the noise it was supposed
            // to stand out from. Doubling the rise's reach to a 45° average lean gives
            // `moundMesh`'s curve enough room to bow. Capped to leave at least a sliver of
            // flat plateau on the smallest tiers, so the lid plane's width never goes to
            // zero or negative.
            let minPlateau = cubeSize * 0.3
            let maxInset = max(min(w, d) - minPlateau, 0)
            let inset = min(max(cubeSize * 0.34, rise * 2), maxInset)

            guard let bankMesh = moundMesh(baseWidth: w, baseDepth: d,
                                           topWidth: w - inset, topDepth: d - inset,
                                           height: rise) else { continue }
            let bank = ModelEntity(mesh: bankMesh, materials: [bankMaterial(env)])
            bank.position = f3(0, Double(floor), 0)

            let cols = tier.origin.col..<(tier.origin.col + tier.cols)
            let rows = tier.origin.row..<(tier.origin.row + tier.rows)
            let lid = ModelEntity(mesh: .generatePlane(width: w - inset, depth: d - inset),
                                  materials: [roomFloorMaterial(env, cols: cols, rows: rows)])
            lid.position = f3(0, Double(h) + 0.004, 0)

            let holder = Entity()
            holder.addChild(bank)
            holder.addChild(lid)
            holder.position = f3(tier.centerCol, 0, tier.centerRow)
            boardAnchor.addChild(holder)
        }
    }

    /// A mound's actual silhouette: a stack of rounded-rectangle rings swept straight
    /// up, wide at the base and narrowing to exactly `topWidth` x `topDepth` at
    /// `height` — a real curved rise rather than a box (vertical all the way up, reads
    /// as a stepped cliff) or a straight-sided frustum (a flat ramp meeting the ground
    /// and the plateau at two sharp creases, which measured no differently from a wall
    /// under the game's own camera; see `buildHills`).
    ///
    /// Two curves run through the stack, not one. Ring height climbs *linearly* with
    /// ring index, so the rings are evenly spaced; each ring's footprint (and how
    /// rounded its corners are) shrinks along `smoothstep` of that same height
    /// fraction. Coupling footprint to an eased function of height — rather than
    /// sizing and height off the same raw step — is what makes the profile a genuine
    /// curve instead of a straight ramp re-parametrized: `smoothstep` has zero slope
    /// at both ends, so the surface lies flat against the ground at the toe and flat
    /// against the plateau at the brow, with no crease at either seam. Had both height
    /// and footprint shared the same eased parameter instead, they'd cancel back out
    /// to a straight line — a curve needs the two to disagree.
    ///
    /// Corner rounding eases out to nothing by the last ring, so the rim is a plain
    /// rectangle — exactly what the lid plane is, with no gap or overhang at the seam.
    /// The base stays rounded, blending into the flat ground around it rather than
    /// meeting it at a right-angled corner.
    ///
    /// Normals come from the built surface by finite difference rather than a closed
    /// form: nothing this shape does (rounding, tapering, un-rounding) has one, and a
    /// numeric normal is automatically smooth wherever the surface is.
    private func moundMesh(baseWidth: Float, baseDepth: Float,
                           topWidth: Float, topDepth: Float, height: Float,
                           rings: Int = 10, segmentsPerCorner: Int = 4) -> MeshResource? {
        guard height > 0 else { return nil }
        let topW = max(topWidth, 0), topD = max(topDepth, 0)
        let baseCorner = min(baseWidth, baseDepth) * 0.3

        func smoothstep(_ t: Float) -> Float { t * t * (3 - 2 * t) }
        func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

        var rows: [[SIMD3<Float>]] = []
        for i in 0..<rings {
            let t = Float(i) / Float(rings - 1)
            let y = height * t
            let sizeT = smoothstep(t)
            let hw = lerp(baseWidth, topW, sizeT) / 2
            let hd = lerp(baseDepth, topD, sizeT) / 2
            let corner = baseCorner * (1 - sizeT)
            let outline = roundedRectOutline(halfWidth: hw, halfDepth: hd,
                                             cornerRadius: corner, segmentsPerCorner: segmentsPerCorner)
            rows.append(outline.map { SIMD3($0.x, y, $0.y) })
        }

        let segs = rows[0].count
        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        for ring in rows {
            var u: Float = 0
            for j in ring.indices {
                if j > 0 { u += simd_distance(ring[j], ring[j - 1]) }
                uvs.append(SIMD2(u, ring[j].y))
            }
        }
        for ring in rows { positions += ring }

        // Central difference along the ring and up the stack; one-sided at the two
        // open ends, since the mesh caps neither — the ground and the lid do.
        var normals: [SIMD3<Float>] = []
        for i in 0..<rings {
            for j in 0..<segs {
                let here = rows[i][j]
                let around = rows[i][(j + 1) % segs] - rows[i][(j - 1 + segs) % segs]
                let up = rows[min(rings - 1, i + 1)][j] - rows[max(0, i - 1)][j]

                var normal = simd_cross(up, around)
                if simd_length(normal) < 1e-8 { normal = SIMD3(here.x, 0, here.z) }
                normal = simd_normalize(normal)
                // The horizontal direction from the vertical axis out to this point is
                // always the way the surface should face; anything that disagrees with
                // it slipped in with the wrong sign somewhere upstream.
                if simd_dot(normal, SIMD3(here.x, 0, here.z)) < 0 { normal = -normal }
                normals.append(normal)
            }
        }

        var indices: [UInt32] = []
        for i in 0..<(rings - 1) {
            for j in 0..<segs {
                let j2 = (j + 1) % segs
                let a = UInt32(i * segs + j)
                let b = UInt32(i * segs + j2)
                let c = UInt32((i + 1) * segs + j)
                let d = UInt32((i + 1) * segs + j2)
                indices += [a, c, b, b, c, d]
            }
        }

        var descriptor = MeshDescriptor(name: "mound")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// A closed outline of a rectangle with rounded corners, sampled at a fixed point
    /// count regardless of size — so every ring in a tapering sweep like `moundMesh`
    /// has matching indices to stitch against its neighbours. Traced clockwise as seen
    /// from above (+x+z, +x-z, -x-z, -x+z), the same winding `moundMesh`'s stitching
    /// assumes.
    private func roundedRectOutline(halfWidth: Float, halfDepth: Float,
                                    cornerRadius: Float, segmentsPerCorner: Int) -> [SIMD2<Float>] {
        let r = max(0, min(cornerRadius, min(halfWidth, halfDepth)))
        let centers: [SIMD2<Float>] = [
            SIMD2(halfWidth - r, halfDepth - r),      // toward +x+z
            SIMD2(halfWidth - r, -(halfDepth - r)),   // toward +x-z
            SIMD2(-(halfWidth - r), -(halfDepth - r)),// toward -x-z
            SIMD2(-(halfWidth - r), halfDepth - r),   // toward -x+z
        ]
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(centers.count * segmentsPerCorner)
        for (k, center) in centers.enumerated() {
            let start = (1 - Float(k)) * .pi / 2   // 90°, 0°, -90°, -180°
            for s in 0..<segmentsPerCorner {
                let angle = start - Float(s) / Float(segmentsPerCorner) * (.pi / 2)
                points.append(center + SIMD2(cos(angle), sin(angle)) * r)
            }
        }
        return points
    }

    /// A room's floor material, with the texture phased so the pattern runs continuously
    /// from one room into the next rather than restarting at every threshold.
    private func roomFloorMaterial(_ env: Environment,
                                   cols: Range<Int>, rows: Range<Int>) -> PhysicallyBasedMaterial {
        guard let tex = floorTexture(for: env), let res = loadTexture(tex, semantic: .color) else {
            return pbr(env.floorColor(appearance), roughness: 0.85)
        }
        var m = PhysicallyBasedMaterial()
        let s = Float(floorTexScale)
        m.baseColor = .init(tint: .white, texture: repeatTexture(res))
        if let n = floorNormal(for: env), let nres = loadTexture(n, semantic: .normal) {
            m.normal = .init(texture: repeatTexture(nres))
        }
        // Scale so one repeat covers the same distance it did per cell, and offset by the
        // room's own position so neighbouring rooms' patterns line up at the door.
        m.textureCoordinateTransform = .init(
            offset: SIMD2<Float>(Float(cols.lowerBound) * s, Float(rows.lowerBound) * s),
            scale: SIMD2<Float>(s * Float(cols.count), s * Float(rows.count)))
        m.roughness = 0.95
        resetEmission(&m)
        return m
    }

    // MARK: - Walls

    /// Tall enough to enclose the room and read as a wall from above, short enough
    /// that at an angled camera it doesn't swallow the floor behind it.
    private var wallHeight: Float { cubeSize * 1.15 }

    /// Walls on the near (+row) side, which face the camera. Held so they can be
    /// hidden when the board is tilted — see `updateWallVisibility`.
    private var nearWalls: [Entity] = []

    /// Runs walls around the house, one wall per wall.
    ///
    /// Built from the cells that *are* wall — every non-floor cell touching floor —
    /// rather than from the edges of the floor cells beside them.
    ///
    /// The edge-based version drew a thin slab on the boundary of each floor cell, which
    /// is right for the outside of the house but wrong between two rooms: the gap
    /// dividing them is one cell wide, so the room above emitted a slab at its bottom
    /// edge, the room below emitted another at its top edge, and the divider came out as
    /// two parallel lines with a hollow cell between them. Treating the gap as the wall
    /// gives one solid wall the width of the cell it occupies, and the perimeter falls
    /// out of the same pass.
    private func buildWalls(_ board: BoardModel) {
        // One ring beyond the box, so the outside of the house gets walls too.
        var wallCells: Set<GridCell> = []
        var wallEnvironment: [GridCell: Environment] = [:]
        for row in -1...board.height {
            for col in -1...board.width {
                let cell = GridCell(col: col, row: row)
                guard !board.isFloor(col: col, row: row) else { continue }
                // Only cells that actually border the house — the rest is outside space.
                let neighbours = [GridCell(col: col + 1, row: row), GridCell(col: col - 1, row: row),
                                  GridCell(col: col, row: row + 1), GridCell(col: col, row: row - 1)]
                let touching = neighbours.filter { board.isFloor(col: $0.col, row: $0.row) }
                guard let first = touching.min(by: { ($0.row, $0.col) < ($1.row, $1.col) })
                else { continue }
                wallCells.insert(cell)
                // Takes its look from the room it borders. A divider borders two; the
                // lower-indexed one wins, which is arbitrary but stable for a given house
                // rather than flickering between rebuilds.
                wallEnvironment[cell] = board.environment(at: first)
                // "Near" means it sits between the camera and the floor it bounds, i.e.
                // the floor is above it. Those are the ones a tilted camera looks through.
                if board.isFloor(col: col, row: row - 1) { nearWallCells.insert(cell) }
            }
        }

        // Merged into as few boxes as possible: horizontal runs first, then vertical runs
        // from what's left, then whatever singles remain. A house perimeter comes out as
        // a handful of slabs instead of a couple of hundred cells.
        //
        // A run only extends while the room it borders stays the same. One entity carries
        // one material, so merging across a boundary paints the whole length in the first
        // cell's colour — which showed up as a stretch of yard fence rendered in kitchen
        // plaster because the run happened to start beside the kitchen.
        var remaining = wallCells
        for row in -1...board.height {
            var col = -1
            while col <= board.width {
                let start = GridCell(col: col, row: row)
                guard remaining.contains(start) else { col += 1; continue }
                let env = wallEnvironment[start]
                let from = col
                while remaining.contains(GridCell(col: col, row: row)),
                      wallEnvironment[GridCell(col: col, row: row)] == env { col += 1 }
                let to = col - 1
                guard to > from else { continue }        // singles are left to the passes below
                let cells = (from...to).map { GridCell(col: $0, row: row) }
                cells.forEach { remaining.remove($0) }
                addWallBlock(cells: cells, horizontal: true, board: board,
                             env: env ?? environment)
            }
        }
        for col in -1...board.width {
            var row = -1
            while row <= board.height {
                let start = GridCell(col: col, row: row)
                guard remaining.contains(start) else { row += 1; continue }
                let env = wallEnvironment[start]
                let from = row
                while remaining.contains(GridCell(col: col, row: row)),
                      wallEnvironment[GridCell(col: col, row: row)] == env { row += 1 }
                let to = row - 1
                let cells = (from...to).map { GridCell(col: col, row: $0) }
                cells.forEach { remaining.remove($0) }
                addWallBlock(cells: cells, horizontal: false, board: board,
                             env: env ?? environment)
            }
        }
        updateWallVisibility()
    }

    /// Which wall cells sit between the camera and the floor they bound.
    private var nearWallCells: Set<GridCell> = []

    /// One wall, filling the cells it occupies.
    private func addWallBlock(cells: [GridCell], horizontal: Bool,
                              board: BoardModel, env: Environment) {
        guard let first = cells.first, let last = cells.last else { return }
        let h = wallHeight
        let span = Float(cells.count) * cubeSize
        let mesh = horizontal
            ? MeshResource.generateBox(width: span, height: h, depth: cubeSize)
            : MeshResource.generateBox(width: cubeSize, height: h, depth: span)
        let node = ModelEntity(mesh: mesh,
                               materials: [pbr(env.wallColor(appearance), roughness: 0.92)])
        node.position = f3(Double(first.col + last.col) / 2.0,
                           Double(h) / 2.0,
                           Double(first.row + last.row) / 2.0)
        boardAnchor.addChild(node)
        // Hidden together when tilted if any of its cells is a near one — a merged run
        // is one entity, so it can only be shown or hidden as a whole.
        if cells.contains(where: { nearWallCells.contains($0) }) { nearWalls.append(node) }
    }

    /// Hides the near walls once the board is tilted.
    ///
    /// Looking straight down, all four walls read as a border and none of them is in
    /// the way. Lean the camera and the near wall is between it and the room — it
    /// would cover the bottom rows and Qoob with them. Dropping just that side is
    /// what keeps a tilted room readable.
    private func updateWallVisibility() {
        let showNear = boardTiltRadians <= 0.0001
        for wall in nearWalls { wall.isEnabled = showNear }
    }

    /// Marks a target: a pulsing ring with the symbol's icon inside it, hovering
    /// just above the floor. Both are self-lit, alpha-blended planes, so the floor
    /// shows through between them — a target adds to the room rather than replacing
    /// a patch of it.
    private func addTargetMarker(col: Int, row: Int, index: Int) {
        let marker = Entity()
        marker.position = f3(Double(col), 0.02, Double(row))

        marker.addChild(makeTargetPad(index: index))

        boardAnchor.addChild(marker)
        markerEntities["\(col),\(row)"] = marker
        targetIndexByCell[GridCell(col: col, row: row)] = index
    }

    /// Takes a target's marker away, pulsers and all.
    private func removeTargetMarker(col: Int, row: Int) {
        let key = "\(col),\(row)"
        if let marker = markerEntities[key] {
            forEachModel(marker) { animator.removePulsers(for: $0) }
            marker.removeFromParent()
            markerEntities[key] = nil
        }
        targetIndexByCell[GridCell(col: col, row: row)] = nil
    }

    /// The pulsing square frame.
    /// A target's landing spot: one solid pad carrying the symbol, breathing in
    /// scale so it reads as live without the opacity dropping far enough to let the
    /// floor show through and undo the point of it being solid.
    private func makeTargetPad(index: Int) -> Entity {
        let mesh = MeshResource.generatePlane(width: cubeSize * 0.94, depth: cubeSize * 0.94)
        let node = ModelEntity(mesh: mesh, materials: [unlitMaterial(SymbolTextures.pad(index))])
        setUnlitOpacity(node, 1.0)
        let baseScale = node.scale
        animator.addPulser(node) { e, t in
            let p = 0.5 + 0.5 * sin(t / 0.9 * .pi)
            e.scale = baseScale * Float(1.0 + 0.07 * p)
            setUnlitOpacity(e, Float(0.88 + 0.12 * p))
        }
        return node
    }

    // MARK: - Roll geometry (RealityKit-specific mapping of RollDirection)

    /// Offset (relative to the cube centre, edge length 1) of the bottom edge
    /// the cube pivots around.
    private func pivotOffset(_ d: RollDirection, climbing: Bool = false) -> SIMD3<Float> {
        // Bottom leading edge normally; the top one when climbing, which lifts the
        // cube exactly one cube height onto the step.
        let y: Double = climbing ? 0.5 : -0.5
        switch d {
        case .right:   return f3( 0.5, y,  0.0)
        case .left:    return f3(-0.5, y,  0.0)
        case .forward: return f3( 0.0, y, -0.5)
        case .back:    return f3( 0.0, y,  0.5)
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

    /// The same 90° roll as `rollRotation`, written out as an exact rotation
    /// matrix (columns; every entry is 0 or ±1). Used to keep a drift-free record
    /// of Qoob's orientation — see `cubeBasis`. Left-multiplied, matching the
    /// world-space `quat(angle, axis) * rotation` the pivot applies.
    private static func rollBasis(_ d: RollDirection) -> simd_float3x3 {
        switch d {
        case .right:   return simd_float3x3(columns: (f3(0, -1, 0), f3(1,  0, 0), f3(0,  0, 1)))
        case .left:    return simd_float3x3(columns: (f3(0,  1, 0), f3(-1, 0, 0), f3(0,  0, 1)))
        case .forward: return simd_float3x3(columns: (f3(1,  0, 0), f3(0,  0, -1), f3(0, 1, 0)))
        case .back:    return simd_float3x3(columns: (f3(1,  0, 0), f3(0,  0, 1), f3(0, -1, 0)))
        }
    }

    // MARK: - Helpers

    /// Visits every ModelEntity in a hierarchy (self included).
    private func forEachModel(_ entity: Entity, _ body: (ModelEntity) -> Void) {
        if let model = entity as? ModelEntity { body(model) }
        for child in entity.children { forEachModel(child, body) }
    }

}

/// An `ARView` that reports when its size changes, so the renderer can re-frame
/// the board for the new viewport.
///
/// RealityKit offers no hook for this — the camera framing is worked out once, in
/// `aimCamera`, from the view's bounds. Without a nudge on rotation the board
/// stayed framed for the old shape: a portrait board on a landscape iPad ended up
/// with its ends cropped off screen.
private final class ResizeReportingARView: ARView {
    var onViewportChange: (() -> Void)?

    /// Layout runs for plenty of reasons that leave the size alone; only a real
    /// change is worth re-aiming for.
    private var lastReportedSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastReportedSize else { return }
        lastReportedSize = bounds.size
        onViewportChange?()
    }
}
