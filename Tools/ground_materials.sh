#!/bin/bash
# Turns the Ground Material Bundle's 2048² PBR maps into app-sized imagesets.
#
# Only the base colour and the OpenGL-convention normal are taken. The AO and
# roughness maps are omitted deliberately: these tile across a whole room floor, so
# a baked AO adds nothing a light can't do, and a single roughness value reads the
# same at this camera height for a fraction of the bundle. HEIGHT is unusable — it
# needs tessellation/displacement, which the RealityKit material path here has no
# route to. NOR_DX is the DirectX-convention twin of NOR_GL (green channel flipped);
# RealityKit wants OpenGL.
#
# 512² because the floor is seen from a long way up and the source is 6–10MB a map:
# the full set is 162MB, which is not going in an app bundle.
set -e
CAT="${1:-Sources/Resources/Assets.xcassets}"
SRC="${2:-$HOME/Downloads/Ground Material Bundle - FREE}"
SIZE="${3:-512}"

put() {
  local name="$1" src="$2"
  local dir="$CAT/$name.imageset"
  mkdir -p "$dir"
  sips -Z "$SIZE" -s format png "$src" --out "$dir/$name.png" >/dev/null
  cat > "$dir/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "$name.png", "idiom" : "universal", "scale" : "1x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
  printf "  %-24s %s\n" "$name" "$(du -h "$dir/$name.png" | cut -f1)"
}

# Outdoor floors, one material per outdoor room kind. Named `floor_<Environment
# rawValue>` so `Environment.floorTextureName` finds them with no code change.
put floor_yard           "$SRC/Grass/Grass01/Grass01_DIFF.png"
put floor_yard_normal    "$SRC/Grass/Grass01/Grass01_NOR_GL.png"
put floor_sandpit        "$SRC/Sand/Sand01/Sand01_DIFF.png"
put floor_sandpit_normal "$SRC/Sand/Sand01/Sand01_NOR_GL.png"
put floor_patio          "$SRC/Gravel/Gravel01/Gravel01_DIFF.png"
put floor_patio_normal   "$SRC/Gravel/Gravel01/Gravel01_NOR_GL.png"
# Dirt for the cut face of a mound's bank.
put mound_bank           "$SRC/Dirt/Dirt01/Dirt01_DIFF.png"
put mound_bank_normal    "$SRC/Dirt/Dirt01/Dirt01_NOR_GL.png"
