# TiltCube — an Endorfun-inspired tilt-and-roll puzzle for iOS

A calm, meditative colour-matching game. You roll a six-coloured cube around a
grid by **physically tilting your iPhone or iPad** (gyroscope). Land the cube so
that its bottom face matches a glowing target tile to clear it. Clear every
target before the timer runs out. Gentle affirmations and a procedural ambient
soundtrack accompany each match.

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

## How to play

- **Tilt right/left** → cube rolls right/left.
- **Tilt the top of the device away from you** → cube rolls forward (up the board);
  tilt it toward you → cube rolls back.
- Whatever pose you're holding when a level starts becomes "flat/neutral", so it
  works lying down or sitting up.
- A held tilt keeps the cube rolling in that direction, one cell at a time.
- Match the cube's **bottom** face colour to a glowing ringed tile to clear it.
  Consecutive matches build a streak (higher score + a rising bell).

### If a tilt rolls the cube the wrong way

Orientation math depends on how you hold the device. Two one-line toggles in
`Sources/Motion/MotionManager.swift`:

```swift
var invertX = false   // flip if left/right are reversed
var invertY = false   // flip if forward/back are reversed
var threshold = 0.28  // lower = more sensitive
```

## Project layout

```
Sources/
  App/
    TiltCubeApp.swift     @main entry point
    ContentView.swift     SwiftUI HUD + menus
  Game/
    GameView.swift        SwiftUI ⇄ SCNView bridge
    GameController.swift   scene, camera, frame loop, timer, scoring
    GameViewModel.swift   observable state for the HUD
    Cube.swift            the rolling cube: roll math + face tracking (core)
    Board.swift           grid of tiles + match logic + tile visuals
    Level.swift           procedural level generation
    GamePalette.swift     six colours + mantras
  Motion/
    MotionManager.swift   CoreMotion tilt → RollDirection
  Audio/
    AudioEngine.swift     procedural ambient pad + match bells
  Resources/
    Info.plist
project.yml               XcodeGen spec
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

The other three directions are the same idea about the appropriate edge (see
`RollDirection` and `Cube.applyFacePermutation` in `Cube.swift`). The visual
animation re-parents the cube under a temporary pivot node placed at that bottom
edge, rotates 90°, then bakes the transform back — so the cube tips over its
edge rather than spinning in place, and snaps to the exact grid centre after
each roll to avoid floating-point drift.

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
