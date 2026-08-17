# Qoob — cleanup and test plan

Engineering plan for paying down what accumulated while the game was being built
quickly. Product ideas live in `ROADMAP.md`; this is about correctness, testability
and the state of the repo.

## Settled decisions

| Decision | Value | Consequence |
|---|---|---|
| Deployment target | **iOS 18** | No image-based-lighting fallback; one lighting path. Drops iOS 16/17 devices. |
| Project generation | **XcodeGen** (2.46.0, installed) | `project.yml` is the single source of truth. `.xcodeproj` stays untracked; a clone runs `xcodegen generate` first. New files are free — they just need a regenerate. |
| Test framework | **Swift Testing** | Per the project's code-style guidance. Xcode 27 / Swift 6.4. |

## Sequencing

```
Phase 1 ✅ ──► Phase 2a ──► Phase 2b ──► Phase 3
                                          (refactors, gated on green tests)
Phase 4 ──┐
Phase 5 ──┼── independent, any time
Phase 6 ──┘
```

Phase 3 is deliberately last: the refactors are behaviour-preserving, and there is
currently nothing that would tell us if they weren't.

---

## Phase 1 — Make a fresh clone buildable ✅

Done in `610d549`. The repo could not be cloned and built: `.xcodeproj` is
gitignored, `project.yml` claimed the opposite, and both it and the docs pointed at
`ios/Qoob`, a path removed by the restructure.

- Fixed the stale paths and the false "checked-in Qoob.xcodeproj" comment
- Settled the deployment target (was 17 in `project.yml`, 16 in the built project)
- Deleted `MotionManager.swift`, dead since tilt was removed
- Dropped `hasEnvironmentLight` and the `fillScale` compensation

**Verified:** fresh clone → `xcodegen generate` → `xcodebuild` → BUILD SUCCEEDED.

---

## Phase 2a — Extract the model-sizing rule into Core

The renderer sizes a model by height, then clamps it so it can't sprawl past the
cells it blocks. That arithmetic has caused more visual bugs than anything else —
the doll's-chair at 0.62 cells, the planter filling 33% of its footprint, the
clamp silently breaking `surface` so perched toys floated — and it currently lives
where no test can reach it.

Move the arithmetic (not the mesh analysis) into `Core`:

```swift
struct ModelFit {
    let scale: Float          // uniform scale applied to the model
    let surface: Float        // top height in world units; must equal kind.height
    let quarterTurns: Int     // rotation to face `facing`
}

func modelFit(extents: SIMD3<Float>, kind: FurnitureKind,
              footprint: (cols: Int, rows: Int), facing: Facing,
              backAxis: Axis) -> ModelFit
```

`modelBackAxis` stays in the renderer — it needs mesh mass and RealityKit types.
Only the pure part moves, which is the part that has been wrong.

**Acceptance:** renderer behaviour unchanged (one device screenshot per room kind),
and the function is callable from tests with no RealityKit dependency.

---

## Phase 2b — `QoobTests` and six regression suites

Add a `QoobTests` unit-test target to `project.yml`. Write a shared **pose-gated
search helper** first: reachability here is over `(cell, orientation)` pairs, not
cells, because a climb is only legal from certain poses. Flood-fill over cells
disagrees with the real movement rules, and every invariant bug this session hid in
that gap. That helper was hand-written about eight times during development; it
belongs in one place.

| Suite | What it pins | Status |
|---|---|---|
| `HouseInvariants` | Every room enterable, every mound climbable, no softlock, doorways flat, no furniture on a doorway. 60 seeds × 4 aspect ratios. | ✅ |
| `Determinism` | Same seed → identical house; different seeds differ. A Set-iteration-order bug once made seeds unstable. | ✅ |
| `FurnitureTable` + `ModelFit` | Footprints, whole heights, per-room caps, a one-level step in every indoor room; the clamp reporting its shaved height honestly, long-axis alignment, facing, refusal of degenerate models. | ✅ |
| `ToyPhysics` | Paths stay at floor level, never onto another toy, bounded by the roll budget, no toy wedged, basket collects, perched toys land safely. | ✅ |
| `Blueprints` | Codable fidelity, missing-key tolerance, authored houses reachable and softlock-free, doorway furniture dropped, `makeLevel` deterministic. | ✅ |
| ~~`RegressionPins`~~ | **Dropped.** The idea was to pin the exact seeds that exposed each bug — but those seeds weren't recorded, and now the bugs are fixed they pass like any other. Pinning a passing seed adds nothing over the 240-house sweeps, which already cover the same classes exhaustively. | ✂️ |

**32 tests in 6 suites, ~115s.** Two limitations worth knowing:

- There is **no `Level` → `HouseBlueprint` conversion** in the project, only `makeLevel()`
  one way, so the literal round-trip in the original plan can't be written. The
  blueprint suite checks Codable fidelity plus the properties of the level produced,
  which covers the same risk.
- `FurnitureTable` deliberately does **not** load the bundled models. That's what
  extracting `ModelFit` bought: the rule is checked against synthetic extents, with no
  RealityKit, asset catalogue or device. The real models were verified once by hand
  over 400 combinations (see `3e64290`).

Bugs that were previously found by hand and are now pinned by the sweeps above:

- rooms sealed by furniture across a doorway (9 houses in 200)
- a pit you could drop into and not climb out of
- level-3 mound tiers unreachable 51% of the time
- an escape hatch that opened for drops but not climbs
- furniture facing computed and then discarded
- model variants clumping — three identical armchairs in 16% of rooms
- a weak cell hash: 62% neighbour correlation against 25% ideal

**Acceptance met, both parts.** Green, and mutation-tested rather than assumed:

- Injecting a box onto a doorway turned `no furniture sits on a doorway` red in all
  240 houses — and also tripped `same seed, same house`, because the injection keyed
  off `Set.first` and so reproduced the very Set-ordering instability that test pins.
- Dropping the floor-level requirement from `canHoldToy` turned the toy-path test red
  with 349 issues.
- One mutation did **nothing**: disabling the doorway guard in `fits` left the suite
  green, so something downstream already prevents it and that guard is unverifiable
  belt-and-braces. Recorded rather than removed — and a reminder that a mutation that
  fails to fail is information, not a formality.

Two of the suites' assertions were wrong on the first attempt and the code was right
both times (see `55844ee`, `546ac9d`). Worth remembering: a new failing test is not
evidence the code is broken.

---

## Phase 3 — Behaviour-preserving refactors ✅

Gated on Phase 2b being green. Nothing here should change what the game does.

| Target | Was | Action | Status |
|---|---|---|---|
| `SettingsView.swift` | 711 lines | Level builder out to `LevelBuilderView.swift` (now 132 lines) | ✅ |
| `Level.swift` | 1,600 lines | Generator (1,060) / `HouseBlueprint.swift` (543) / `SeededGenerator.swift` (24) | ✅ |
| `RealityKitRenderer.swift` | 2,813 lines | Material builders out to `RenderMaterials.swift` (2,679 lines left) | ◐ partial — see below |
| `GameController` state | `Level!`, `BoardModel!`, `CubeState!` | One `Game?` holding all three non-optionally | ✅ |

### Why the renderer is *not* being split by MARK section

The original plan said `+Lighting`, `+Terrain`, `+Furniture` and so on. Having measured
it, that's the wrong move: `RealityKitRenderer` has **65 private stored properties and
92 private methods**, and an extension in another file cannot see `private` members. A
section split would mean promoting most of that to module-wide visibility — trading a
long file for no encapsulation, which is the worse of the two problems.

What *can* come out is anything genuinely stateless or with a narrow interface. The
material builders qualified (they map arguments to a material and touch nothing else)
and have gone. Remaining candidate: model loading and its cache, which has state but a
one-line interface (`name → Entity`) and would extract as a `ModelLibrary` type.

That's a real design change rather than a cosmetic move, so it's listed as its own
item rather than smuggled in under "refactor".

### Verification for this phase

Tests don't catch visual regressions, so each rendering change also gets a device
screenshot. After the material extraction: floor tiling, wall materials, the unlit
target pad and toys all correct, with no UV-transform bleed or leftover emission —
which are the two specific bugs the `reset*` helpers exist to prevent.

**Acceptance per step:** build + full suite green + one device screenshot. Tests
won't catch visual regressions, so the screenshot isn't optional.

---

## Phase 4 — Close the open visual issues

- **Lamp intensity.** Currently 24000 lumens, an educated guess: 5200 produced no
  visible pool at all and 60000 washed the floor out, but the lamp was never fully
  in frame. Needs a look with the lamp centred.
- **The near-black circular object — identified, no fix applied.** It is
  `coffeeTable2`: a *round* table (1.94 x 1.94 footprint, so it reads as a disc from
  directly above) whose material carries no texture and a base colour of
  rgb(0.23, 0.16, 0.08) — luminance 0.17, against roughly 0.40 for the colours in
  `FurnitureKind.color`. The pale shapes on it in the screenshots are perched toys.
  Confirmed by generating seed 6653367501949354550 and finding a coffee table with
  perched toys at exactly the cells the disc occupied.

  A general "lighten any model darker than its kind intends" rule was written and then
  **backed out**: measuring first showed **26 of 38** untextured furniture materials
  fall below even a conservative 0.22 floor — bushes at 0.03, plus counters, dressers
  and planters. Those look right in play because they are *sub*-materials with a
  lighter dominant surface; `coffeeTable2` is unusual only in being a single dark
  material covering the whole piece. Any such rule would therefore repaint most of the
  furniture library, which is a worse outcome than one dark table.

  It is a real legibility fault — a *climbable* piece that reads as a hole at night has
  to be seen to be used — but the fix belongs in the content, not a renderer
  heuristic: either re-tone that one asset or drop the variant from rotation. That's a
  taste call.
- **`liftEmissionForNight` is not a no-op** — checked and closed. Loaded models come
  in as `PhysicallyBasedMaterial`, so the cast succeeds. The basket and litterbox turn
  out to have no bundled model at all (`Model_basket` and `Model_litterbox` don't
  exist), so both are drawn procedurally with `pbr(...)` — also
  `PhysicallyBasedMaterial`. Both are therefore lifted as intended.
- **`present` hitch.** ~1.3s warm, ~5s cold, visible when entering a new house.
  Measure where it goes before choosing between an async build, entity reuse, or
  covering it with a transition.

---

## Phase 5 — CI

GitHub Actions on push to `main`: install XcodeGen, generate, build, test. This is
what makes Phase 2b load-bearing rather than something only ever run by hand.

---

## Phase 6 — Documentation rewrite

`README.md` and `BUILD.md` both describe a substantially older game, so they need
rewriting rather than patching:

- README: `SceneKitRenderer`, a `ProgressStore.swift` that doesn't exist, tilt
  controls, themed levels "cycling every 3 levels", "from level 4 on some toys are
  perched", per-level best times, and `up = butt` on the cube.
- BUILD.md: a first-build watch-list about "SceneKit numeric types" and being
  "developed in a Linux environment", and a tuning table citing
  `MotionManager.threshold`, `SceneKitRenderer.topDownTilt` and
  `shadowRadius`/`shadowColor` — none of which exist.
- `ROADMAP.md` has the same drift ("cycles every 3 levels", "appears from level 4").

Keep BUILD.md's asset, variant, facing and ground-texture sections — those are
current and hard-won.
