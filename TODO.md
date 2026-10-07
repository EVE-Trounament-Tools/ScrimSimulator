## Position pipeline (crates)
- may bug when ship comes close enough that distance becomes m instead of km
- bug where some ships seem to be moved out of bounds erroneously
- gpu acceleration
- the ~/Videos/AG7/2026-10-04 05-58-36.mkv: finding the match with ScrimTrimmer step takes far too much time compared to triming a normal gamepaly vid with the scrimTrimmer
- hp tracking will break with even a tiny change to the setup, need a way to correct for this or a more robust way to calculate it from the image data

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
