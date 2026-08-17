# Qoob — roadmap / parked ideas

Living design notes so ideas aren't lost. Nothing here is committed scope; it's
a menu to pull from.

## Environments (themed content) — SHIPPED v1

`Environment.swift` themes each level: **Living Room → Kitchen → Bedroom → Yard**
(cycles every 3 levels). Each sets its floor colour, ground colour, backdrop
mood, and furniture set (living room: sofa/coffee table/armchair; kitchen:
counter/dining table/fridge; bedroom: bed/dresser/nightstand; yard: bench/bush/
planter). Optional per-environment floor textures via `floor_<env>` asset slots.

Still to do: per-environment music/ambient audio; more environments; themed
obstacle *models* (drop-in `bed.usdz` etc. already works via the fallback).

## Knock-off-the-furniture — SHIPPED v1

Some toys start **perched on furniture** (`PerchedToy`). Rolling the cat into
that furniture **knocks the toy onto the floor** (a tumble animation) for +100,
after which it's a normal pushable toy. Appears from level 4.

Still to do: "break vs. land safe" variants; toys that must be knocked off before
their pad can be filled; distinct knock-off sound.

## Other parked ideas

- **Themed goals**: replace the abstract glowing tiles with in-world spots — a
  food bowl, a sunbeam, a cat bed — so the objective reads diegetically.
- **Walls / room framing**: baseboards + a rug to frame the play floor.
- **Special tiles**: slippery (keep rolling), teleport (cat flap), holes.
- **Game Center**: leaderboards (records already persist in `ProgressStore`).
- **Real art**: drop-in USDZ cat + furniture, fur/carpet textures, per-face art
  (hooks already in place — see README).
- **Haptics/audio polish**: distinct sounds for push vs. match vs. knock-off.
