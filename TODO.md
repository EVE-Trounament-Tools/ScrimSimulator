## Position pipeline (crates)
- may bug when ship comes close enough that distance becomes m instead of km
- bug where some ships seem to be moved out of bounds erroneously
- gpu acceleration
- the ~/Videos/AG7/2026-10-04 05-58-36.mkv: finding the match with ScrimTrimmer step takes far too much time compared to triming a normal gamepaly vid with the scrimTrimmer
- hp tracking will break with even a tiny change to the setup, need a way to correct for this or a more robust way to calculate it from the image data

## CI
- Godot segfaults intermittently in the headless test suite on small machines, during
  `test_main::test_ship_menu_damage_breakdown_windows` (the first `damage_button.pressed` opens a
  `DamageBreakdown` window). It shows up as exit code 134/139 in the test step of `test.yml` (every
  tag since v1.0.1) and `deploy-web.yml` (which now retries the tests up to 3 times on a crash).
  - Reproduce: `taskset -c 0,1 godot --headless --path simulator --script res://tests/run_tests.gd -- test_main`
    (prefix `stdbuf -o0`, or output to a file is buffered and the last lines before the crash are lost).
    Crashes in roughly 1 run of 2–3 when limited to 2 CPUs; never seen with all cores.
  - Tried:
    - The test alone, with every other `test_main` test disabled: never crashes (0/8).
    - Every test up to and including it, the later ones disabled: no crash in 8 runs.
    - A standalone loop opening and closing 300 `DamageBreakdown` windows (and plain `Window`s): no crash.
    - Godot 4.6.3 instead of 4.6: still crashes (5/10).
  - The official Linux builds have no debug symbols, so the backtrace is just addresses. Next step: build
    Godot 4.6 from source with `debug_symbols=yes` to see where it crashes, then work around it or
    report it upstream.
  - Getting worse as of v2.2.0: crashed in 5 of 6 CI runs on the tag (all 3 `deploy-web` attempts,
    the `test` run and its rerun; only the `deploy-web` rerun got through), each time at the same
    point. The `test` workflow for v2.2.0 is still red because of it. `test.yml` has no retry, so
    it could at least get the same retry as `deploy-web.yml`.

## Test data (resouces)


## GUI
- pause, play, and navigation of video along with timeline
- stop updating position of ships once it becomes a capsule
- backtrack in time of 100km jump to calculate mjd activation
- instead of one unit 1km, should be 1 unit 1m
- web interface for simulator
- add popup for 10s countdown
- selectable resolution
- ability to center on beacons
- button to re-center on center
- when a ship dies it should show just a bar for the speed and distance rather than the true distance
- shift + arrow keys to seek forward or back 10s
- option to hide dead ships (or just movement of dead pilots)
- timeline shoulden't care about being podded, just ships dying
add bars for armor, shield, and hull
- For the ocr gui, I should need to just set a folder and the tool should look for the relevant logs, I shoulden't need to manually select the log files
- display hp data
- Update overview to mirror what is done for AT streams
