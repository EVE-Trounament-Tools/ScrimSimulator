#!/usr/bin/env bash
# Render the README GIFs (docs/media/*.gif) from the demo match.
#
#   scripts/readme_gifs.sh                  # every scene
#   scripts/readme_gifs.sh measure orbit    # only these scenes (playback, measure, orbit)
#
# Each scene is scripted by simulator/tools/readme_gif.gd and recorded with Godot's Movie Maker,
# then converted to a GIF with ffmpeg. Needs a display (not headless) and the demo match's hull
# models already downloaded into simulator/sde/ (open the demo once in the simulator).
# Uses $GODOT if set, else `godot` on PATH (Godot 4.6).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
GODOT="${GODOT:-godot}"
CSV="$ROOT/resouces/demo/demo.positions.csv"
OUT="$ROOT/docs/media"
WIDTH=1600
HEIGHT=900
GIF_WIDTH=960
GIF_FPS=15

SCENES=("$@")
[[ ${#SCENES[@]} -gt 0 ]] || SCENES=(playback measure orbit)

TMP="$(mktemp -d)"
# Movie Maker records at the project's viewport size and ignores --resolution, so set it with a
# temporary override.cfg.
OVERRIDE="$ROOT/simulator/override.cfg"
trap 'rm -rf "$TMP" "$OVERRIDE"' EXIT
printf '[display]\nwindow/size/viewport_width=%d\nwindow/size/viewport_height=%d\n' \
    "$WIDTH" "$HEIGHT" > "$OVERRIDE"

if [[ ! -d simulator/.godot ]]; then
    echo "==> importing Godot project"
    "$GODOT" --headless --path simulator --import >/dev/null 2>&1 || true
fi

mkdir -p "$OUT"
for scene in "${SCENES[@]}"; do
    echo "==> $scene"
    rm -rf "$TMP/frames" && mkdir "$TMP/frames"
    "$GODOT" --path simulator --write-movie "$TMP/frames/f.png" --fixed-fps 30 \
        -s res://tools/readme_gif.gd -- --csv "$CSV" --scene "$scene" >/dev/null
    filters="fps=$GIF_FPS,scale=$GIF_WIDTH:-1:flags=lanczos"
    ffmpeg -loglevel error -y -framerate 30 -start_number 2 -i "$TMP/frames/f%08d.png" \
        -vf "$filters,palettegen=stats_mode=diff" "$TMP/palette.png"
    ffmpeg -loglevel error -y -framerate 30 -start_number 2 -i "$TMP/frames/f%08d.png" -i "$TMP/palette.png" \
        -lavfi "$filters [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
        -loop 0 "$OUT/$scene.gif"
    ls -lh "$OUT/$scene.gif"
done
