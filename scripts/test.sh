#!/usr/bin/env bash
# Run the simulator's headless test suite (simulator/tests/).
#
#   scripts/test.sh                 # every test file
#   scripts/test.sh match_data      # only test files whose name contains "match_data"
#
# Uses $GODOT if set, else `godot` on PATH (Godot 4.6).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
GODOT="${GODOT:-godot}"

# The demo match is public: no real names, no legal ships.
python3 scripts/check_demo_data.py

# A clean checkout has no .godot/ import cache; class_name lookups (MatchData, ...) need it.
if [[ ! -d simulator/.godot ]]; then
    echo "==> importing Godot project"
    "$GODOT" --headless --path simulator --import >/dev/null 2>&1 || true
fi

exec "$GODOT" --headless --path simulator --script res://tests/run_tests.gd -- "$@"
