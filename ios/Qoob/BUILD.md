# Building Qoob

## Prerequisites
- A **Mac with Xcode 15+**.
- A **real iPhone/iPad** to use tilt (the Simulator has no gyroscope — the game
  auto-falls back to swipe + on-screen D-pad there, so it still runs).

## Generate & open (recommended)
```bash
cd ios/Qoob
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
As bundled resource files: `cube_cat.usdz`, and `<furnitureKind>.usdz`
(e.g. `sofa.usdz`, `fridge.usdz`). See README for details.
