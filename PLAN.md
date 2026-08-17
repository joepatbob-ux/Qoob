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

| Suite | What it pins |
|---|---|
| `HouseInvariants` | Every room enterable, every mound climbable, no softlock, no pit you can enter and not leave, doorway thresholds flat. N seeds × 4 aspect ratios. |
| `Determinism` | Same seed → identical house, twice in one process and across the rebuild `present` does. A Set-iteration-order bug once made seeds unstable. |
| `BlueprintRoundTrip` | `Level` → `HouseBlueprint` → `Level` preserves floor, furniture, facing and mounds; Codable survives; missing keys tolerated as `decodeIfPresent` promises. |
| `FurnitureTable` | Every kind has a non-empty footprint, sane levels, a model in the catalogue; `modelFit` yields exactly `kind.height` and fills ≥70% of the footprint. |
| `ToyPhysics` | Push paths stay on flat ground, bounce correctly, never end raised or on furniture. |
| `RegressionPins` | The specific seeds that exposed each bug below, so they cannot come back silently. |

Bugs that were found by hand and are currently unprotected:

- rooms sealed by furniture across a doorway (9 houses in 200)
- a pit you could drop into and not climb out of
- level-3 mound tiers unreachable 51% of the time
- an escape hatch that opened for drops but not climbs
- furniture facing computed and then discarded
- model variants clumping — three identical armchairs in 16% of rooms
- a weak cell hash: 62% neighbour correlation against 25% ideal

**Acceptance, two parts.** `xcodebuild test` green — and then deliberately
reintroduce two of the bugs above and confirm the suite goes red. A test that has
never failed is not known to work.

---

## Phase 3 — Behaviour-preserving refactors

Gated on Phase 2b being green. Nothing here should change what the game does.

| Target | Now | Action |
|---|---|---|
| `RealityKitRenderer.swift` | 2,813 lines | Split into `+Lighting`, `+Terrain`, `+Furniture`, `+Toys`, `+Materials`, `+ModelLoading` |
| `Level.swift` | 1,600 lines | Split into generator / `HouseBlueprint` / `HouseLibrary` |
| `SettingsView.swift` | 711 lines | Move the level builder out. It only lives there because new files were believed to be expensive — they aren't. |
| `GameController` state | `Level!`, `BoardModel!`, `CubeState!` | One non-optional `Game` value set once, removing a latent-crash class. Every method already guards them. |

**Acceptance per step:** build + full suite green + one device screenshot. Tests
won't catch visual regressions, so the screenshot isn't optional.

---

## Phase 4 — Close the open visual issues

- **Lamp intensity.** Currently 24000 lumens, an educated guess: 5200 produced no
  visible pool at all and 60000 washed the floor out, but the lamp was never fully
  in frame. Needs a look with the lamp centred.
- **The near-black circular object.** Recurs in several night frames, about one
  cell across, unidentified.
- **`liftEmissionForNight` may be a no-op.** It casts to
  `PhysicallyBasedMaterial` and silently skips anything else, so a loaded model
  with a different material type gets nothing. Never confirmed it took on the
  basket, which is one of the two things the player aims at.
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
