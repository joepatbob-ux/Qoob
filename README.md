# Qoob — a cube-cat rolling puzzle

A calm, endless rolling puzzle starring a **cube-cat**: a die whose six faces each
depict a part of the cat. You roll it around a house — by swiping, using the
on-screen D-pad, or a connected game controller — to land the **pictured side
face-down** on the glowing target tile. There's no timer pressure and nothing to
lose; a clock counts up only so it means something if you want it to.

Houses are generated from a seed and are bigger than the screen, so the camera
follows Qoob rather than framing the whole thing. Reach the litterbox and the house
is replaced by a new one — the world is endless because nothing is remembered.

**The cube-cat's six faces** (`Core/CatSymbols.swift`, drawn procedurally — no image
assets needed):

| Face | Depiction |
|------|-----------|
| front | the cat's **face** |
| back | the **rear** and tail, opposite the head |
| down | four **paws**, underneath |
| up | **three spots** along the spine |
| left | a single **dot** on the flank |
| right | a **ring** on the other flank |

The starting layout is in `Level.startingFaces()`. Head and rear are opposite, and
paws start down — which matters, because "which face is down" is the whole game.

## Stack

- **SwiftUI** — HUD, menus, settings, the level builder
- **RealityKit** — all 3D: meshes, materials, image-based lighting, the roll animation
- **AVFoundation** — a procedural ambient pad and match bells
- **GameController** — optional MFi/DualSense/Xbox pad support
- No third-party packages.

## Build & run

**Requirements**

- **Xcode 26 or newer.** Not because of the deployment target — the app calls Liquid
  Glass (`glassEffect`) behind a runtime `#available(iOS 26.0, *)`, and a runtime
  guard still needs the symbol to exist in the SDK. Xcode 16 cannot compile it.
- Deployment target is **iOS 18** (tvOS 26).
- A simulator is fine. There's no motion or camera dependency.

**The project file is generated and not tracked**, so a fresh clone has nothing to
open until you run XcodeGen:

```bash
brew install xcodegen        # once
cd Qoob
xcodegen generate
open Qoob.xcodeproj
```

`project.yml` is the single source of truth for targets and build settings. Any new
file under `Sources/` or `Tests/` is picked up by a regenerate — the spec globs those
directories, so nothing needs adding by hand.

Two things worth knowing about regenerating:

- It resets `DEVELOPMENT_TEAM` to empty, so a device build needs your team
  re-selected under Signing & Capabilities. Simulator builds are unaffected.
- New files won't be compiled until you regenerate. If a test you just wrote seems
  not to run, that's why.

## Controls

Three schemes, usable together (toggle them in Settings):

- **Swipe** anywhere on the board — one roll per swipe, or hold at the end of a swipe
  to keep rolling.
- **On-screen D-pad** — hold a direction to walk at a steady cadence.
- **Game controller** — left stick or D-pad.

All three report the direction currently *held* rather than firing one-shot events,
so a held input rolls at one shared cadence set by the frame loop. There is no tilt
control; it was removed.

## How to play

- **Match the target tile.** Roll so the depicted face lands face-down on the glowing
  pad. Consecutive matches build a streak worth extra points.
- **Push toys into the basket.** Roll into a toy and it rolls ahead of you, rebounding
  off whatever stops it — which is what frees a toy wedged in a corner. Toys only ever
  travel at floor level.
- **Knock toys off the furniture.** Roll into a piece with a toy perched on it and the
  toy drops to the floor, where it becomes a normal pushable one.
- **Reach the litterbox** to end the house and open a new one.

Climbing is capped at **one level per roll**, and a climb only works from the gathered
pose — head up, paws pointing at the step — so that the roll lands Qoob standing on
top. A drop needs the mirror of that pose. If you ever end up somewhere with no legal
move, an escape hatch opens so you can't be stranded; the generator also
exhaustively verifies that no house contains such a state (see Tests).

## Architecture: engine-agnostic core, one renderer seam

The gameplay never depends on how it's drawn. A `GameRenderer` protocol is the only
contract between them:

```
GameController (orchestrator — imports no rendering engine)
     │  owns the Game value (Level + BoardModel + CubeState),
     │  the frame loop, clock, scoring, input, audio, haptics
     │
     ▼  drives, via the protocol:
GameRenderer  ──►  present(level:board:cube:)        build the scene
                   animateRoll(_:to:toLevel:…)       animate one roll
                   clearTile(col:row:)               matched-tile flourish
     ▲
     └── RealityKitRenderer   (the current implementation)
```

- **`Core/`** imports no rendering engine — it is the whole game as data and rules:
  the face model and roll permutation, matching, house generation, furniture,
  authored blueprints, and the model-sizing rule. This is what makes the test suite
  possible: every invariant runs with no RealityKit, no view and no device.
- **`Rendering/`** is the only place RealityKit lives.

## Project layout

```
Sources/
  App/
    QoobApp.swift              @main entry point
    ContentView.swift          HUD, menus, presentation
    GameControls.swift         D-pad and control chips
    SettingsView.swift         control scheme and feedback preferences
    LevelBuilderView.swift     plan-view house editor
  Core/                        ← no rendering-engine imports
    CoreTypes.swift            Face, RollDirection, GridCell, CubeState (roll math)
    BoardModel.swift           grid, matching, toy pushing, knock-off
    Level.swift                house generation, furniture placement, reachability
    HouseBlueprint.swift       authored houses + their on-disk library
    SeededGenerator.swift      SplitMix64 — the seed everything derives from
    Furniture.swift            kinds, footprints, heights, facing
    Environment.swift          room kinds and what furnishes each
    ModelFit.swift             how a 3D model is sized and turned to fit a footprint
    CatSymbols.swift           the six depictions, drawn procedurally
    GamePalette.swift          accent colours and mantras
  Rendering/                   ← the ONLY place RealityKit lives
    GameRenderer.swift         the protocol (the seam)
    RealityKitRenderer.swift   scene, lighting, camera, furniture, roll animation
    RenderMaterials.swift      stateless material builders
    RealityKitHelpers.swift    small conveniences, texture loading
    RealityKitEnvironmentEffects.swift  soft-body, grass, ambient motion
    ProceduralFur.swift        generated fur texture
    ProceduralTextures.swift   generated floors and glyphs
    BundledTextures.swift      optional asset-catalogue overrides
  Game/
    GameController.swift       state, frame loop, clock, scoring, input
    GameView.swift             SwiftUI ⇄ renderer bridge, swipe gestures
    GameViewModel.swift        observable state for the HUD
    ControllerInput.swift      MFi / DualSense / Xbox pads
    Haptics.swift              roll and match feedback
  Environment/
    WindSystem.swift           shared wind, so everything sways together
    VisualTuning.swift         all the feel constants, in one file
  Audio/
    AudioEngine.swift          procedural ambient pad and match bells
  Resources/
    Assets.xcassets            textures + bundled 3D models as Data Sets
    Info.plist
Tests/                         ← Swift Testing, over Core only
  PoseSearch.swift             exhaustive (cell, orientation) reachability search
  HouseInvariantTests.swift    reachability, softlocks, mounds, doorways
  ToyPhysicsTests.swift        push paths, wedging, basket, knock-off
  FurnitureTableTests.swift    the furniture table and ModelFit
  BlueprintTests.swift         authored houses and Codable fidelity
project.yml                    XcodeGen spec — the source of truth
PLAN.md                        engineering plan and its status
ROADMAP.md                     product ideas
```

## Houses

There are no levels, and there never really were: `levelIndex` was set to 0 and never
incremented, so every "difficulty by level" term silently evaluated to its index-0
value — which had switched the toy and knock-off mechanics off entirely. Everything is
now scaled to a room's own floor area, which is the thing that actually decides how
much it can hold.

A house is partitioned into rooms, each with a kind (`Environment.swift`) that decides
its floor, walls and what furnishes it: living room, kitchen, bedroom, yard, patio,
sandpit. Furniture heights are whole numbers of cube units — see the roll maths below
for why they have to be. Outdoors, verticality comes from **stepped mounds** rather
than props, in whole-cube tiers, because a 90° pivot can only land a face flat on an
exact cube height.

Every indoor room is guaranteed something one level high to climb on. Without it a
room's taller furniture is scenery: the kitchen once had nothing under two levels —
counter 2, table 2, fridge 4 — so none of it could be got onto.

## The level builder

Settings ▸ *Level builder…* opens a plan-view editor: drag out rooms, punch doors
through walls, place furniture, mounds, rugs, toys, the basket and the litterbox, then
validate and play.

It emits the **same `Level`** the generator does, so an authored house is
indistinguishable to the rest of the game. A blueprint stores only the authored
decisions — never the derived floor, blocked and surface sets — so `makeLevel()` can
apply the identical rules and a hand-built house can't reach a state a generated one
never could. That's also what gets saved to disk: the small, stable, meaningful part.

## The roll math (why the bottom face is always correct)

The cube tracks its six face symbols logically and animates from the **same**
`RollDirection`, so the two can't drift. Rolling permutes the faces exactly as a
physical die (edge length 1, pivoting on the bottom edge). For a roll to the **right**
(+X), a 90° rotation gives:

| new face | takes symbol of old |
|----------|---------------------|
| right    | up                  |
| down     | right               |
| left     | down                |
| up       | left                |

The other three directions are the same idea about the appropriate edge. The
permutation is `CubeState.applyRoll` (`Core/CoreTypes.swift`); the animation is
`RealityKitRenderer.animateRoll`, which pivots the cube about that bottom edge and
snaps to the exact grid centre afterwards to avoid drift.

This is also why **every furniture height is a whole number**. A 90° pivot only lands
a face flat if the step is an exact cube height — land on a 1.7-high sofa and Qoob
finishes balanced on a corner with no face down at all.

## Tests

```bash
xcodebuild test -project Qoob.xcodeproj -scheme Qoob \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

32 tests in 6 suites, using Swift Testing, over `Core/` only — no rendering, no
device. CI runs them on every push.

The central piece is `PoseSearch`: an exhaustive breadth-first search over
**(cell, orientation)** states. Reachability has to be pose-gated because a climb is
only legal from one pose and a drop from its mirror, so whether Qoob can reach
somewhere depends on which way up they arrive. A cell-based flood fill answers a
different question — and that gap is where every invariant bug found during
development lived, including mound tiers that were unreachable in half of all houses
while looking perfectly connected on paper.

The suites sweep 240 generated houses each (60 seeds × 4 aspect ratios) checking that
every room is reachable, no reachable state is a dead end, every mound tier can be
stood on, doorways stay flat, and no furniture blocks one.

## Relationship to the reverse-engineering work

This repository previously also held a reverse-engineering project for the original
*Endorfun* (still in history, before `c437aea`). Two findings from it shaped this game:

1. What was genuinely decoded there is the **ELV level-file audio sequencing** and the
   **rhythm-loop soundtrack** — the meditative audio. The tile-grid layout, win rule
   and scoring formula were **never** decoded; they live in an opaque binary, and the
   original assets are copyrighted and not present here.
2. Several "reconstructed" C modules described a generic 3D shooter — enemies,
   weapons, projectiles — none of which is in Endorfun. They were **not** used.

So Qoob is a clean-room, original take on the *idea* — roll a symbol cube on a grid,
meditative tone — rather than a port. All colours, words, audio and code are new.
