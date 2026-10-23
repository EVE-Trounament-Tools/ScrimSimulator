#!/usr/bin/env bash
# Add the checked-in demo match to the website's shared library (web/README.md), public, at the
# top level as "Demo match", unless it is already there. Run by deploy-web after the D1
# migrations; also works against a local `wrangler dev` setup.
#
#   scripts/seed_demo_web.sh [--remote|--local]    (default: --remote)
#
# "Already there" means a row at its path, or any row with the demo CSV's contents (so a demo an
# admin renamed or moved into a folder isn't added again). A deleted demo is added back. The
# rows are owned by no character (id 0), so only admins can rename or remove them.
set -euo pipefail

WHERE="${1:---remote}"
case "$WHERE" in
    --remote|--local) ;;
    *) echo "usage: $0 [--remote|--local]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_CSV="$ROOT/resouces/demo/demo.positions.csv"
DEMO_NAME="Demo match"
BUCKET="scrim-simulator"
cd "$ROOT/web/worker" # wrangler.toml

log() { printf '==> %s\n' "$*"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

# Library path -> source file. The CSV and its gamelogs dir must share a stem
# (MatchLibrary.logs_dir); logs dirs have no folder row of their own.
declare -A FILES=(
    ["$DEMO_NAME.positions.csv"]="$DEMO_CSV"
    ["$DEMO_NAME.positions.ogg"]="${DEMO_CSV%.csv}.ogg"
)
for f in "${DEMO_CSV%.csv}.logs/"*.txt; do
    FILES["$DEMO_NAME.positions.logs/$(basename "$f")"]="$f"
done

CSV_SHA="$(sha "$DEMO_CSV")"
n="$(npx wrangler d1 execute DB "$WHERE" --json --command \
    "SELECT COUNT(*) AS n FROM files WHERE path = '$DEMO_NAME.positions.csv' OR sha = '$CSV_SHA'" |
    jq '.[0].results[0].n')"
if [[ "$n" != 0 ]]; then
    log "demo match already in the library"
    exit 0
fi

# Paths have no quotes, shas are hex and sizes integers, so they are safe to inline.
t="$(date +%s)"
sql=""
ops=()
for path in "${!FILES[@]}"; do
    src="${FILES[$path]}"
    s="$(sha "$src")"
    # Content-addressed, as library.ts blobKey.
    npx wrangler r2 object put "$BUCKET/blobs/$s" "$WHERE" --file "$src"
    pub=0
    [[ "$path" == *.csv ]] && pub=1
    sql+="INSERT INTO files (path, sha, size, owner_id, owner_name, mtime, public) VALUES ('$path', '$s', $(stat -c %s "$src"), 0, 'Demo', $t, $pub) ON CONFLICT (path) DO NOTHING; "
    ops+=("\"put $path\"")
done
# As library.ts bumpVersion, so open browsers resync.
sql+="INSERT INTO kv (key, value) VALUES ('library_version', '1') ON CONFLICT (key) DO UPDATE SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT); "
sql+="INSERT INTO audit (at, char_id, char_name, action, detail) VALUES ($t, 0, 'deploy', 'library', '[$(IFS=,; echo "${ops[*]}")]');"
npx wrangler d1 execute DB "$WHERE" --command "$sql"
log "added the demo match to the library"
