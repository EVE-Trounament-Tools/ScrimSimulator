## Position pipeline (crates)
- may bug when ship comes close enough that distance becomes m instead of km
- bug where some ships seem to be moved out of bounds erroneously
- gpu acceleration
- the ~/Videos/AG7/2026-10-04 05-58-36.mkv: finding the match with ScrimTrimmer step takes far too much time compared to triming a normal gamepaly vid with the scrimTrimmer
- hp tracking will break with even a tiny change to the setup, need a way to correct for this or a more robust way to calculate it from the image data
- mirror ambiguity: a track and its mirror across the observers' plane give the same distances and speeds, so a pilot starting on/near the plane gets a coin-flip side (5 of 20 demo pilots switched sides between runs). Needs outside evidence, e.g. combat-log scrams (scrammer and target within ~10 km) or teammates' positions

## Test data (resouces)


## GUI
- instead of one unit 1km, should be 1 unit 1m
- add popup for 10s countdown
- selectable resolution
- ability to center on beacons
- button to re-center on center
- shift + arrow keys to seek forward or back 10s
- option to hide dead ships (or just movement of dead pilots)
- timeline shoulden't care about being podded, just ships dying
