# Qoob — roadmap / parked ideas

Living design notes so ideas aren't lost. Nothing here is committed scope; it's
a menu to pull from.

## Environments (themed content) — planned

Progress the cat through **different environments**, not just one living room:

- **Rooms of a house**: living room, kitchen, bedroom, bathroom, hallway — each
  with its own floor (carpet / tile / wood), furniture set, palette, and props.
- **A yard / outdoors**: grass floor, fences, a garden bed, a pond obstacle,
  flower-pot obstacles.
- Later: other environments entirely (rooftop, shop, etc.).

Suggested shape (fits the existing seam cleanly):
- A `Theme`/`Environment` type in `Core` describing floor material key, furniture
  kinds allowed, accent palette, ambient tint, and (optional) music.
- `Level.generate` takes/derives an environment from the level index (e.g. every
  N levels advances the room), and only spawns that environment's furniture set.
- `SceneKitRenderer` reads the theme for floor + ambient; furniture/obstacle
  models are keyed by environment (`kitchen_counter.usdz`, `yard_fence.usdz`, …)
  reusing the existing bundled-model fallback pattern.
- No game-core rule changes — it's a content/skin layer over the current board.

## Knock-off-the-furniture (mechanic enhancement)

The push-toy mechanic (shipped) is the floor version. The very-cat idea:

- Some toys start **on top of furniture** (a vase on the coffee table).
- Rolling the cat against that furniture edge **knocks the toy onto the floor**
  (a adjacent free cell), after which it becomes a normal pushable toy.
- Bonus flair: a little tumble animation + sound; maybe some items "break" (no
  points) vs. land safe (points) depending on the drop cell.

Implementation sketch: furniture pieces gain optional `topItem` cells; a roll
into a furniture cell that carries a top item triggers a knock-off (spawn a toy
on a chosen adjacent free cell) instead of a plain blocked bump.

## Other parked ideas

- **Themed goals**: replace the abstract glowing tiles with in-world spots — a
  food bowl, a sunbeam, a cat bed — so the objective reads diegetically.
- **Walls / room framing**: baseboards + a rug to frame the play floor.
- **Special tiles**: slippery (keep rolling), teleport (cat flap), holes.
- **Game Center**: leaderboards (records already persist in `ProgressStore`).
- **Real art**: drop-in USDZ cat + furniture, fur/carpet textures, per-face art
  (hooks already in place — see README).
- **Haptics/audio polish**: distinct sounds for push vs. match vs. knock-off.
