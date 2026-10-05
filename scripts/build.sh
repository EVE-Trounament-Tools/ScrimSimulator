#!/usr/bin/env bash
# Build release bundles: the Godot simulator (plus its glb-undraco model helper and the demo
# match) and, as a separate download, the scrim-positions OCR tool.
#
#   scripts/build.sh [linux|windows|all]    (default: all)
#
# Output: dist/scrim-simulator-<version>-<platform>-x86_64.zip
#         dist/scrim-positions-<version>-<platform>-x86_64.zip
# Runs on Ubuntu; Windows is cross-compiled (needs `mingw-w64`). Godot and its export templates
# are downloaded into .cache/ / the user's Godot data dir if not already present. Override the
# Godot binary with $GODOT.
#
# The simulator bundle's demo/ is copied into the user's match library on first run. By default
# it holds the checked-in demo match; set DEMO_LIBRARY to a match library directory (e.g.
# ~/.local/share/godot/app_userdata/simulator/matches) to ship all of it instead: folders,
# audio, gamelogs and sidecars. Set BUNDLE_SDE=1 to also ship simulator/sde/ (ship sizes, icons,
# models) so the bundle works offline.
set -euo pipefail

GODOT_VERSION="4.6"
GODOT_TAG="${GODOT_VERSION}-stable"
GODOT_RELEASES="https://github.com/godotengine/godot/releases/download/${GODOT_TAG}"
TEMPLATES_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/${GODOT_VERSION}.stable"
WIN_TARGET="x86_64-pc-windows-gnu"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="${1:-all}"
case "$TARGET" in
    linux|windows|all) ;;
    *) echo "usage: $0 [linux|windows|all]" >&2; exit 2 ;;
esac

VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo "v0.0.0")"
CACHE="$ROOT/.cache/godot"
DIST="$ROOT/dist"

log() { printf '==> %s\n' "$*"; }

ensure_godot() {
    if [[ -z "${GODOT:-}" ]]; then
        if command -v godot >/dev/null && godot --version 2>/dev/null | grep -q "^${GODOT_VERSION}\.stable"; then
            GODOT="$(command -v godot)"
        else
            GODOT="$CACHE/Godot_v${GODOT_TAG}_linux.x86_64"
            if [[ ! -x "$GODOT" ]]; then
                log "downloading Godot ${GODOT_TAG}"
                mkdir -p "$CACHE"
                curl -fL -o "$CACHE/godot.zip" "$GODOT_RELEASES/Godot_v${GODOT_TAG}_linux.x86_64.zip"
                unzip -o -q "$CACHE/godot.zip" -d "$CACHE"
                rm "$CACHE/godot.zip"
                chmod +x "$GODOT"
            fi
        fi
    fi
    if [[ ! -f "$TEMPLATES_DIR/version.txt" ]]; then
        log "downloading Godot ${GODOT_TAG} export templates"
        mkdir -p "$CACHE" "$TEMPLATES_DIR"
        curl -fL -o "$CACHE/templates.tpz" "$GODOT_RELEASES/Godot_v${GODOT_TAG}_export_templates.tpz"
        # The .tpz is a zip with everything under templates/.
        unzip -o -q "$CACHE/templates.tpz" -d "$CACHE/tpz"
        cp -r "$CACHE/tpz/templates/." "$TEMPLATES_DIR/"
        rm -rf "$CACHE/templates.tpz" "$CACHE/tpz"
    fi
    # A clean checkout has no .godot/ import cache; exports need it.
    if [[ ! -d simulator/.godot ]]; then
        log "importing Godot project"
        "$GODOT" --headless --path simulator --import >/dev/null
    fi
}

export_simulator() { # <preset> <path relative to simulator/>
    mkdir -p "simulator/$(dirname "$2")"
    "$GODOT" --headless --path simulator --export-release "$1" "$2"
}

write_simulator_readme() { # <dir> <sim exe> <undraco exe>
    cat > "$1/README.txt" <<EOF
Scrim Simulator ${VERSION}

$2
    Replay viewer for *.positions.csv files. The demo matches in demo/ are added to the match
    list on first run. Add your own with the "Add match..." button, by dropping a CSV onto
    the window, or open one from the command line:
        $2 -- --csv /path/to/match.positions.csv
    Ship sizes are downloaded from the EVE static data export into sde/ next to the
    executable on first run. Ships are drawn as their hull models with overview icons
    (toggle with M or in Settings); the icons and models are downloaded into sde/assets/,
    each hull the first time a match needs it.

$3
    Helper the simulator runs to decompress downloaded ship models. Keep it next to $2.

To turn your own recordings into *.positions.csv files, get the separate scrim-positions
download.

Source: https://github.com/AckbadP/ScrimSimulator
EOF
}

write_ocr_readme() { # <dir> <ocr exe> <gui exe>
    cat > "$1/README.txt" <<EOF
Scrim Positions ${VERSION}

$2
    OCRs a three-observer scrim recording into <video>.positions.csv:
        $2 --scene scene.json --out out/ match.mkv
    scene.json matches the OBS template in the source repository (docs/obs/); adjust its
    panel rectangles if your layout differs. Requires ffmpeg and ffprobe on PATH.
    Watch the result in the separate scrim-simulator download.

$3
    A window for running $2 on one recording: pick the video, chat log, output folder,
    optional combat logs folder and whether to save the audio. Remembers your choices.
    Keep it next to $2.

Source: https://github.com/AckbadP/ScrimSimulator
EOF
}

# Shipped in the simulator bundle and added to its match library on first run.
DEMO_CSV="resouces/demo/match_03.positions.csv"
DEMO_NAME="Demo match"

new_stage() { # <bundle name>: an empty dist/<name>/
    rm -rf "${DIST:?}/$1" "$DIST/$1.zip"
    mkdir -p "$DIST/$1"
}

zip_stage() { # <bundle name>
    (cd "$DIST" && zip -q -r "$1.zip" "$1")
    log "built dist/$1.zip"
}

package_simulator() { # <platform> <sim exe path> <undraco exe path>
    local name="scrim-simulator-${VERSION}-$1-x86_64"
    local stage="$DIST/$name"
    new_stage "$name"
    cp "$2" "$3" "$stage/"
    if [[ -n "${DEMO_LIBRARY:-}" ]]; then
        cp -r "$DEMO_LIBRARY/." "$stage/demo/"
    else
        # The CSV and its gamelogs dir must share a stem (MatchLibrary.logs_dir).
        mkdir -p "$stage/demo/$DEMO_NAME.positions.logs"
        cp "$DEMO_CSV" "$stage/demo/$DEMO_NAME.positions.csv"
        cp "${DEMO_CSV%.csv}.logs/"*.txt "$stage/demo/$DEMO_NAME.positions.logs/"
    fi
    if [[ "${BUNDLE_SDE:-}" == 1 ]]; then
        cp -r simulator/sde "$stage/"
    fi
    write_simulator_readme "$stage" "$(basename "$2")" "$(basename "$3")"
    zip_stage "$name"
}

package_ocr() { # <platform> <ocr exe path> <gui exe path>
    local name="scrim-positions-${VERSION}-$1-x86_64"
    local stage="$DIST/$name"
    new_stage "$name"
    cp "$2" "$3" docs/obs/scene.json "$stage/"
    write_ocr_readme "$stage" "$(basename "$2")" "$(basename "$3")"
    zip_stage "$name"
}

build_linux() {
    log "building scrim-positions (linux)"
    cargo build --release -p overview --bin scrim-positions -p positions-gui --bin scrim-positions-gui -p glb-undraco --bin glb-undraco
    log "exporting simulator (linux)"
    export_simulator "Linux" "export/linux/scrim-simulator.x86_64"
    package_simulator linux simulator/export/linux/scrim-simulator.x86_64 target/release/glb-undraco
    package_ocr linux target/release/scrim-positions target/release/scrim-positions-gui
}

build_windows() {
    if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
        echo "error: x86_64-w64-mingw32-gcc not found; install it with: sudo apt install mingw-w64" >&2
        exit 1
    fi
    if ! rustup target list --installed | grep -qx "$WIN_TARGET"; then
        rustup target add "$WIN_TARGET"
    fi
    log "building scrim-positions (windows)"
    cargo build --release -p overview --bin scrim-positions -p positions-gui --bin scrim-positions-gui -p glb-undraco --bin glb-undraco --target "$WIN_TARGET"
    log "exporting simulator (windows)"
    export_simulator "Windows Desktop" "export/windows/scrim-simulator.exe"
    package_simulator windows simulator/export/windows/scrim-simulator.exe "target/$WIN_TARGET/release/glb-undraco.exe"
    package_ocr windows "target/$WIN_TARGET/release/scrim-positions.exe" "target/$WIN_TARGET/release/scrim-positions-gui.exe"
}

ensure_godot
mkdir -p "$DIST"
[[ "$TARGET" == linux || "$TARGET" == all ]] && build_linux
[[ "$TARGET" == windows || "$TARGET" == all ]] && build_windows
log "done ($VERSION)"
