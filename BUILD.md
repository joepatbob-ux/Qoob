# Building Qoob

## Requirements

- **Xcode 26 or newer.** Not because of the deployment target: the app calls Liquid
  Glass (`glassEffect` in `GameControls.swift`) behind a runtime
  `#available(iOS 26.0, *)`, and a runtime guard still needs the symbol to exist in the
  SDK. Xcode 16 fails with `cannot find 'Glass' in scope`. CI asserts this up front so
  the failure is one line rather than four pages.
- Deployment target **iOS 18** (tvOS 26).
- A simulator is fine — nothing here needs a device.

## Generate & open

The `.xcodeproj` is generated and **not tracked**, so a clone has nothing to open
until XcodeGen has run:

```bash
brew install xcodegen        # once
cd Qoob
xcodegen generate
open Qoob.xcodeproj
```

Then pick your Team under the `Qoob` target ▸ Signing & Capabilities if you're
building to a device, choose a destination, and Run.

`project.yml` is the single source of truth. It globs `Sources/` and `Tests/`, so a
new file needs only a regenerate — no project editing.

### Two regenerate gotchas

- **Signing resets.** `DEVELOPMENT_TEAM` is empty in the spec, so regenerating clears
  your team and device builds fail with "requires a development team" until you pick it
  again. Simulator builds are unaffected. Put your team ID in `project.yml` if the
  friction annoys you.
- **New files don't compile until you regenerate.** If a test you just wrote appears
  not to run — the count doesn't go up — this is why.

## Live weather (WeatherKit)

Settings' "Match local weather" needs a real Team ID and the WeatherKit capability
enabled on that team's App ID — neither of which XcodeGen or this repo can set up for
you:

1. A paid Apple Developer Program membership (WeatherKit isn't on the free tier).
2. Register a real App ID on the [Apple Developer portal](https://developer.apple.com/account)
   (the placeholder `com.example.qoob` will never provision) and enable **WeatherKit**
   on it under App Services.
3. Put your Team ID and the real bundle identifier into `project.yml`
   (`DEVELOPMENT_TEAM`, `PRODUCT_BUNDLE_IDENTIFIER` — and the `QoobTests` target's
   bundle ID, which is derived from it) and regenerate.

Without this, the toggle still works — it just can't reach WeatherKit, so it falls
back to today's fixed day/night lighting (`LocalWeatherProvider.status` reports
`.unavailable`, surfaced as a footnote in Settings). Everything about the feature
*except the live fetch itself* is fully testable without it — see `SkySystem`/
`SkyModel.swift`'s unit tests and `LocalWeatherProvider`'s `#if DEBUG` override.

## Tests

```bash
xcodebuild test -project Qoob.xcodeproj -scheme Qoob \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

32 tests in 6 suites (Swift Testing), covering `Core/` only — no rendering, no device.
Roughly two minutes locally. See the README's Tests section for what they pin and why
reachability has to be pose-gated.

CI (`.github/workflows/ci.yml`) runs build + test on every push. It resolves a
simulator from `simctl` at runtime rather than naming one, because both of its first
two failures were a pinned name going stale.

## Tuning constants

All feel is in plain constants — no logic changes needed to adjust:

| What | Where |
|------|-------|
| Roll speed / cadence | `GameController.rollDuration`, `restBetweenRolls` |
| **Soft-body / wind / fur / grass feel** | **`Environment/VisualTuning.swift` — one file, all constants** |
| Cat breathing amount and speed | `VisualTuning.qoob` (`breatheAmplitude`, `breathePeriod`) |
| Squash / rebound / durations | `VisualTuning.qoob` (`squashAmount`, `reboundAmount`, `landDuration`) |
| Fur response to wind | `VisualTuning.fur` (`windResponse`, `baseSway`) |
| Base wind and gusts | `VisualTuning.wind` (`baseStrength`, `gustStrength`, `gustInterval`) |
| Grass sway and recovery | `VisualTuning.grass` (`swayAmount`, `recovery`, `interactionStrength`) |
| Lighting, day and night | `RealityKitRenderer.RoomLight` — two named descriptions, not one rig dimmed |
| Table-lamp brightness | `switchOn(lamp:surface:)` — point-light intensity in lumens |
| Camera lean | `RealityKitRenderer.setBoardTilt` (driven from Settings) |
| Furniture heights, footprints, facing | `Core/Furniture.swift` |
| Room floors and mood colours | `Core/Environment.swift` |
| How much a room holds | `Level.generate` — scaled to floor area, not a level index |
| Push and knock-off points | `GameController.requestRoll` (150 / 100) |

## Drop-in art (all optional, all fall back to procedural)

Into `Sources/Resources/Assets.xcassets` (image sets already exist):
`fur_albedo`/`fur_normal`, `carpet_albedo`/`carpet_normal`, `floor_<env>`,
`cat_face`/`cat_butt`/`cat_paws`/`cat_dot`/`cat_ring`/`cat_triangle`.

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
