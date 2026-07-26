# TiltCube — a cube-cat tilt-and-roll puzzle for iOS

A calm, meditative rolling-puzzle game starring a **cube-cat**: a die whose six
faces each depict a part of the cat. You roll it around a grid — by **tilting
your iPhone/iPad** (gyroscope), swiping, or the on-screen D-pad — to land the
**pictured side face-down** on each glowing target tile. Clear every target
before the timer runs out. Gentle affirmations and a procedural ambient
soundtrack accompany each match.

**The cube-cat's six faces** (see `Core/CatSymbols.swift`, drawn procedurally so
no image assets are needed yet):

| Face | Depiction |
|------|-----------|
| front | the cat's **face** |
| up | the **butt** |
| down | **4 paws** |
| left | a single **dot** |
| right | a **ring** |
| back | **three dots** in a triangle |

Each tile shows the depiction you must roll onto it; the puzzle is tracking the
cat's orientation so the right side ends up on the bottom.

This is an **original game inspired by** the 1995 game *Endorfun* — its
cube-on-a-grid colour-matching feel and meditative tone. It contains **none** of
Endorfun's code, levels, art, or audio. See "Relationship to the reverse
engineering repo" below.

## Stack

- **SwiftUI** — app shell + HUD (score, timer, tiles-left, mantras, menus)
- **SceneKit** — 3D board, cube, lighting, roll animation
- **CoreMotion** — gyroscope/gravity → discrete roll direction
- **AVAudioEngine** — fully procedural ambient pad + pentatonic match bells
  (zero audio asset files)

No third-party dependencies.

## Build & run

You need a Mac with **Xcode 15+** and, to actually tilt-and-roll, a **real
device** (the Simulator has no gyroscope — the menu will warn you and you can
still see the board).

### Option A — XcodeGen (recommended)

```bash
brew install xcodegen        # once
cd ios/TiltCube
xcodegen generate
open TiltCube.xcodeproj
```

Select your device, set your signing team on the `TiltCube` target
(Signing & Capabilities), and Run.

### Option B — no extra tools

1. In Xcode: **File ▸ New ▸ Project… ▸ iOS ▸ App**. Name it `TiltCube`,
   Interface **SwiftUI**, Language **Swift**.
2. Delete the template's `ContentView.swift` and `*App.swift`.
3. Drag the `Sources/App`, `Sources/Game`, `Sources/Motion`, and
   `Sources/Audio` folders into the project (check *Copy items if needed* and
   *Create groups*).
4. Either use the generated Info.plist and add **Portrait** orientation, or set
   the target's **Info.plist File** build setting to
   `Sources/Resources/Info.plist`.
5. Run on a device.

## Controls

Three schemes, usable in any combination (toggle them on the menu or the
in-game chips):

- **Tilt** (real device only) — tilt right/left rolls right/left; tilt the top
  of the device away from you rolls forward (up the board), toward you rolls
  back. Whatever pose you hold when a level starts becomes "flat/neutral", so it
  works lying down or sitting up, and a held tilt keeps rolling one cell at a
  time.
- **Buttons** — an on-screen D-pad.
- **Swipe** — swipe anywhere on the board in a direction; always active.

On the Simulator (no gyroscope) tilt is disabled automatically and you play with
buttons/swipes.

## How to play

Roll the cat so the depiction on its **bottom** face matches the picture on a
glowing target tile — that clears it. The **FIND** legend at the top shows the
depictions still needed this level. Clear every target before time runs out.
Consecutive matches build a streak (higher score + a rising bell). Every roll
and match gives light haptic feedback, and the cat gently "breathes" while you
think.

### If a tilt rolls the cube the wrong way

Orientation math depends on how you hold the device. Two one-line toggles in
`Sources/Motion/MotionManager.swift`:

```swift
var invertX = false   // flip if left/right are reversed
var invertY = false   // flip if forward/back are reversed
var threshold = 0.28  // lower = more sensitive
```

## Architecture: engine-agnostic core + a renderer seam

The game is split so the **gameplay never depends on how it's drawn**. A
`GameRenderer` protocol is the only contract between them:

```
GameController (orchestrator, no rendering imports)
     │  owns BoardModel + CubeState, timer, scoring, input, audio, haptics
     │
     ▼  drives, via the protocol:
GameRenderer  ──►  present(level:board:cube:)          build visuals
                   animateRoll(_:to:duration:completion:)  animate one roll
                   clearTile(col:row:colorIndex:)      tile flourish
     ▲
     └── SceneKitRenderer  (the current implementation; Metal-backed)
```

- **`Core/`** imports no rendering engine at all — it's the whole game as data
  and rules (`CubeState` face model + roll permutation, `BoardModel` matching,
  `Level` generation, palette).
- **`Rendering/`** is the only place SceneKit lives. Everything visual —
  meshes, materials, camera, lights, the pivot-edge roll animation — is here.

**Why this matters for detailed 3D models / a possible Metal move:**

- *Detailed models now, still on SceneKit:* edit only `SceneKitRenderer.swift`.
  Swap `makeCubeNode`'s `SCNBox` for a node loaded from a USDZ/OBJ
  (`SCNScene(named: "cube.usdz")`), keeping the six face materials in the
  SCNBox order; do the same for tiles. Nothing in `Core/` or `GameController`
  changes. (SceneKit already renders through Metal — you don't need raw Metal
  for detailed models.)
- *Switch engines later:* write one new type conforming to `GameRenderer`
  (e.g. `RealityKitRenderer` or a custom `MetalRenderer`) and construct it in
  `GameView.makeUIView` instead of `SceneKitRenderer`. The core is untouched.

## Project layout

```
Sources/
  App/
    TiltCubeApp.swift      @main entry point
    ContentView.swift      SwiftUI HUD + menus + D-pad
  Core/                    ← no rendering-engine imports
    CoreTypes.swift        Face, RollDirection, GridCell, CubeState (roll math)
    BoardModel.swift       grid + symbol-match logic
    Level.swift            procedural level generation + cat face layout
    CatSymbols.swift       the six cube-cat depictions + generated textures
    GamePalette.swift      accent colours + mantras
  Rendering/               ← the ONLY place SceneKit lives
    GameRenderer.swift     the renderer protocol (the seam)
    SceneKitRenderer.swift SceneKit implementation (meshes, camera, animation)
    SceneKitHelpers.swift  SCNVector3 convenience
  Game/
    GameController.swift   orchestrator: state, loop, timer, scoring, input
    GameView.swift         SwiftUI ⇄ renderer bridge + swipe gestures
    GameViewModel.swift    observable state for the HUD
    Haptics.swift          light roll/match feedback
  Motion/
    MotionManager.swift    CoreMotion tilt → RollDirection
  Audio/
    AudioEngine.swift      procedural ambient pad + match bells
  Resources/
    Info.plist
project.yml                XcodeGen spec
```

## The roll math (why the bottom face is always correct)

The cube tracks its six face colours logically and animates visually from the
**same** `RollDirection`, so they never drift. Rolling permutes the faces
exactly as a physical die (edge length 1, pivoting on the bottom edge). For a
roll to the **right** (+X), a 90° rotation about the world Z axis gives:

| new face | takes colour of old |
|----------|---------------------|
| right    | up                  |
| down     | right               |
| left     | down                |
| up       | left                |

The other three directions are the same idea about the appropriate edge. The
permutation lives in `CubeState.applyRoll` (`Core/CoreTypes.swift`); the visual
animation lives in `SceneKitRenderer.animateRoll` (`Rendering/`), which
re-parents the cube under a temporary pivot node placed at that bottom edge,
rotates 90°, then bakes the transform back — so the cube tips over its edge
rather than spinning in place, and snaps to the exact grid centre after each
roll to avoid floating-point drift. Because both derive from the same
`RollDirection`, the logical bottom face and the visible bottom face never
diverge.

## Ideas for where to take it next

- Hand-designed levels / a level file format (instead of procedural).
- Special tiles: multi-colour, teleporters, ice (keep rolling), holes.
- Haptics on each roll and match (`UIImpactFeedbackGenerator`).
- Save progress + best times per level (Endorfun recorded winning times).
- Recorded spoken affirmations layered over the pad (Endorfun's real hook).
- Game Center leaderboards.

## Relationship to the reverse-engineering repo

The parent repository reverse-engineered the original *Endorfun*. Two important
findings shaped this project:

1. The genuinely decoded artefacts there are the **ELV level-file audio
   sequencing** and the **rhythm-loop soundtrack system** — the game's
   meditative audio. The actual **tile-grid layout, win rule, and scoring
   formula were never decoded** (they live in the opaque `.ELV` binary), and the
   original level/audio assets are copyrighted and not present.
2. Several of the "reconstructed" C modules (`endor_game_logic.c`,
   `endor_input_system.c`, `endor_main.c`, `endor_level_editor.c`) are
   **fabricated boilerplate describing a generic 3D shooter** — enemies,
   weapons, projectiles — none of which is in Endorfun. They were **not** used
   here.

So TiltCube is a clean-room, original reimagining of the *idea* (tilt-to-roll a
colour cube on a grid, meditative tone) rather than a port. All colours, words,
audio, and code are new.
