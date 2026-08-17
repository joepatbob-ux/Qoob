# Qoob — roadmap / parked ideas

Living design notes so ideas aren't lost. Nothing here is committed scope; it's a menu
to pull from. Engineering work — tests, refactors, tooling — lives in `PLAN.md`.

## Shipped

**Environments.** `Environment.swift` gives each room a kind: living room, kitchen,
bedroom, yard, patio, sandpit. Each sets its floor, ground and backdrop mood and the
furniture that may go in it. A house is partitioned into rooms rather than cycling
through themes — there are no levels to cycle on.

Still to do: per-environment ambient audio; more room kinds.

**Knock-off-the-furniture.** Some toys start perched on furniture (`PerchedToy`).
Rolling into the furniture knocks the toy to the floor for +100, after which it's a
normal pushable toy.

Still to do: "break vs land safe" variants; toys that must be knocked off before their
pad can be filled; a distinct knock-off sound.

**Stepped mounds.** Outdoor verticality in whole-cube tiers, since a 90° pivot only
lands a face flat on an exact cube height. Yards are deliberately propless — the relief
comes from terrain rather than scattered benches.

**The level builder.** A plan-view editor that emits the same `Level` the generator
does, so authored houses are indistinguishable to the rest of the game.

**Night.** Dark mode is a lights-off night rather than the day rig dimmed: the ceiling
term goes to almost nothing, the key comes in low and cool, a window sits at the
horizon, and table lamps carry real point lights.

## Parked ideas

- **Themed goals** — replace the abstract glowing pad with in-world spots: a food
  bowl, a sunbeam, a cat bed, so the objective reads diegetically.
- **Finding the target.** One pad, one basket and one litterbox in a house of ~1000
  cells, with no indicator. Options: an edge-of-screen arrow, a minimap, or letting the
  camera pull back briefly on entering a house. Currently the weakest part of play.
- **Special tiles** — slippery (keep rolling), teleport (a cat flap), holes.
- **Distinct audio** for push vs match vs knock-off.
- **Per-environment music.**
- **Game Center leaderboards.** Note there is no score persistence at all right now —
  the old `ProgressStore` was removed along with levels, so this needs somewhere to
  save to first.
- **A smoother house transition.** `present` costs ~1.3s warm and ~5s cold, which
  shows as a hitch when the litterbox opens a new house. Either build asynchronously,
  reuse entities, or cover it deliberately.
