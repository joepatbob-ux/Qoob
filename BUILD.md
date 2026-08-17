# Building Qoob

## Prerequisites
- A **Mac with Xcode 15+**.
- A **real iPhone/iPad** to use tilt (the Simulator has no gyroscope — the game
  auto-falls back to swipe + on-screen D-pad there, so it still runs).

## Generate & open (recommended)
```bash
cd Qoob
brew install xcodegen        # once
xcodegen generate
open Qoob.xcodeproj
```
Then in Xcode: select the `Qoob` target ▸ **Signing & Capabilities** ▸ pick your
Team, choose your device, and **Run**.

### Optional: commit the project so you never need XcodeGen again
```bash
git add Qoob.xcodeproj && git commit -m "Add generated Xcode project"
```
(`.xcodeproj` is currently gitignored; force-add it if you want it tracked:
`git add -f Qoob.xcodeproj`.)

## No-XcodeGen alternative
File ▸ New ▸ Project ▸ iOS App (SwiftUI). Delete its template `*App.swift` +
`ContentView.swift`, drag the `Sources/` folder in (Create groups), and set the
target's **Info.plist File** build setting to `Sources/Resources/Info.plist`.

## First-build watch-list
This codebase was written and reviewed without a compiler on hand (developed in a
Linux environment). It's been carefully checked, but if the first build flags
anything, the most likely spots — all quick fixes — are:
- **SceneKit numeric types** — everything funnels through the `v3(...)` helper and
  `SCNMatrix4Make*` with `Float`; if a line complains, wrap literals in `Float(...)`.
  The visual-polish layer also sets `node.rotation` via `SCNVector4(…)`; on iOS its
  components are `Float`, so bare literals are fine, but wrap in `Float(...)` if the
  SDK flags ambiguity.
- **A new SDK API nuance** (e.g. an `SCNAction`/`SCNMaterialProperty` signature).
- Nothing depends on third-party packages — it's pure SwiftUI + SceneKit +
  CoreMotion + AVFoundation.

## Tuning constants (for first playtest)
All feel is in plain constants — no logic changes needed to adjust:

| What | Where |
|------|-------|
| Roll speed / cadence | `GameController.rollDuration`, `restBetweenRolls` |
| Tilt sensitivity / inversion | `MotionManager.threshold`, `invertX`, `invertY` |
| Camera angle (top-down lean) | `SceneKitRenderer.topDownTilt` |
| **Soft-body / wind / fur / grass "feel"** | **`Environment/VisualTuning.swift` (one file, all constants)** |
| Cat breathing amount/speed | `VisualTuning.qoob` (`breatheAmplitude`, `breathePeriod`) |
| Squash / rebound / durations | `VisualTuning.qoob` (`squashAmount`, `reboundAmount`, `landDuration`…) |
| Fur response to wind | `VisualTuning.fur` (`windResponse`, `baseSway`) |
| Base wind / gusts | `VisualTuning.wind` (`baseStrength`, `gustStrength`, `gustInterval`) |
| Grass sway / recovery | `VisualTuning.grass` (`swayAmount`, `recovery`, `interactionStrength`) |
| Shadow softness | `setupLighting` (`shadowRadius`, `shadowColor`) |
| Furniture heights / colours | `Furniture.swift` |
| Environment floor/mood colours | `Environment.swift` |
| Difficulty curve (grid, targets, toys, furniture) | `Level.generate` |
| Push / knock-off points | `GameController.requestRoll` (150 / 100) |

## Drop-in art (all optional, all fall back to procedural)
Into `Sources/Resources/Assets.xcassets` (image sets already exist):
`fur_albedo`/`fur_normal`, `carpet_albedo`/`carpet_normal`, `floor_<env>`,
`cat_face`/`cat_butt`/`cat_paws`/`cat_dot`/`cat_ring`/`cat_triangle`.
As bundled resource files: `cube_cat.usdz` (Qoob's body), and
`<furnitureKind>.usdz` (e.g. `sofa.usdz`, `fridge.usdz`). See README for details.

## Bundled 3D models

Models ship inside `Sources/Resources/Assets.xcassets` as `Model_*.dataset` Data
Sets (the same mechanism as the pre-existing `CubeCatModel.dataset`):

| Data Sets | Contents | Used by |
|-----------|----------|---------|
| `Model_animal-*` (24) | cube pets | the toys Qoob pushes and the ones perched on furniture |
| `Model_<furnitureKind>` (16) | one per `FurnitureKind` | `furnitureModel(_:modelName:)`, replacing the placeholder block |
| `Model_<furnitureKind>2…4` (23) | alternative models for the same kind | dealt round-robin in `buildFurniture(_:)` |
| `Model_rug{A,B,C}` (3) | rugs | `buildRugs(_:)` |

## Ground textures

Floors look for `floor_<Environment rawValue>` and `floor_<…>_normal` imagesets, and
fall back to the procedural floor when neither is there. A room kind may have up to
four numbered variants (`floor_livingRoom2`, `…3`) — `floorVariantName(_:)` probes for
them and picks one **per house** from the house seed, so two living rooms in the same
house match and the next house is carpeted differently. `mound_bank` / `_normal` skin
the risers of outdoor mounds.

Two lessons from wiring photographic materials in:

- **Take base colour and the OpenGL normal; skip the rest.** AO does what a light
  already does on a tiling floor, one roughness value reads the same from this camera
  height, and HEIGHT needs displacement this material path can't do. `NOR_DX` is the
  DirectX twin of `NOR_GL` (green flipped) — RealityKit wants GL. 512² is plenty for a
  floor seen from that far up; the full 2048² sets ran to 162MB.
- **Tone them down.** Material libraries are shot for realism, not for a readable
  palette. The industrial carpets at full saturation made the floor the loudest thing
  on screen, beating both Qoob and the furniture. `Tools/tone_texture.swift` desaturates
  and resizes in one pass — 0.4 saturation kept the weave, which is the part worth
  having, and dropped the part that was fighting. Qoob has to be the most legible thing
  in the frame; a floor is background.

### Variants

A kind may have up to four models. `variantName(for:)` probes for `Model_sofa2`,
`Model_sofa3`… and caches the count, so dropping a `Model_sofa4` into the
catalogue puts it into rotation with no code change, and a kind with a single
model needs no special case. Which one a piece gets is hashed from its own grid
cell — stable across the rebuild that `present` does, so a sofa never changes
model when the camera moves.

**A variant must fit the kind's declared footprint at the kind's height.** The
renderer sizes a model by height and then clamps it so it can't sprawl more than
`furnitureOverhang` past the cells it blocks — so a variant with different
proportions doesn't look different, it comes out the *wrong height*, with its
`surface` no longer matching `kind.levels` and perched toys floating. Before
adding one, check it: scale = `kind.height / modelHeight`, then confirm
`modelWidth × scale ≤ cols × 1.25` and the same for depth, and that the result
fills at least ~70% of the footprint. A model that fills much less reads as
doll's furniture next to a full-cell cat — `chair_A` scaled to one level came out
0.62 of a cell wide, which is why the kitchen uses a backless stool instead: with
no backrest, total height *is* seat height.

**Facing needs no tagging.** `modelBackAxis(_:name:)` works out which way a model's
back points by finding where its *tall* mass sits — a backrest for seating, and for
casework the protruding drawer fronts that shift the bounding-box centre forward. So a
variant can come from any pack with any axis convention and still get pointed
correctly. If a model comes out within 4% of symmetric on both axes it's treated as
having no front and left unrotated, which is right for tables, stools, shrubs and
trees — and is also why the oven isn't pointed: its door is a real front but doesn't
show up in the tall mass, and an oven turned the wrong way would be worse than one
left square. Give a kind `hasFacing = false` if it genuinely reads the same from
every side.

Prefer variants from **different packs** for the same kind. Two models from one
pack usually share an atlas band, so they come out the same colour and read as
repeats from directly above — `armchair` and `armchair_pillows` differ only by
cushions, which is invisible top-down. Mixing KayKit with Quaternius gives
genuinely different silhouettes and palettes.

**Why Data Sets and not loose resource files:** the asset catalogue is a single
folder reference in the project, so `actool` compiles whatever is inside it and
adding models needs no `project.pbxproj` change at all. The cost is that
`NSDataAsset` hands back bytes rather than a URL, and `Entity.load` needs a URL —
so `dataSetModelURL(_:)` spills the data to a temporary file first. (RealityKit's
`Entity(from:contentType:)` takes `Data` directly but is `async`, and the scene is
built synchronously.)

A loose file at the bundle root still overrides the Data Set of the same name, so
the drop-in behaviour above is unchanged. Delete the Data Sets and the game falls
back to the procedural yarn ball and coloured blocks.

Adding a pet also means adding its name to `RealityKitRenderer.petModelNames` —
Data Sets can't be enumerated the way a resource directory can.

### Regenerating them
RealityKit's `Entity.load` only accepts USD, so source OBJ/FBX/glTF has to be
converted. `Tools/obj2usdz.swift` does it with nothing but the system frameworks
(Model I/O can't write USDZ on current macOS; SceneKit can). `--dataset` wraps
each result in a Data Set directly:

```bash
CAT=Sources/Resources/Assets.xcassets
# Furniture: =name maps the pack's filename onto FurnitureKind.modelBaseName
swift Tools/obj2usdz.swift --dataset "$CAT" "/path/to/pack/Couch_Large1.obj=sofa"
# Pets: keep the source names
swift Tools/obj2usdz.swift --dataset "$CAT" "/path/to/pack/OBJ format/"*.obj
```

The renderer scales and seats every model against its cell footprint at load
time, so models don't need normalising first — any Y-up mesh works.

One trap the tool works around: SceneKit resolves the texture paths named in a
`.mtl` against the **process working directory**, not the model's folder. Convert
by absolute path from elsewhere and you get a valid USDZ with an untextured
material and no error at all. The tool `chdir`s per file to avoid it.

### Credits
Every pack is **CC0** (public domain), so no attribution is required, but:
- Cube pets — [Kenney](https://kenney.nl)
- House interior furniture — [Quaternius](https://quaternius.com)
- Furniture Bits, Restaurant Bits, Forest Nature, Dungeon Pack — [KayKit / Kay Lousberg](https://www.kaylousberg.com)
