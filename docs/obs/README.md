# OBS scene template

`scrim-recording.json` is an OBS scene collection for recording a match from three observer
clients on Linux. Its one scene, `Scrim`, on a 3712×1600 canvas, holds seven Window Capture
(Xcomposite) sources: the three observers' overviews, one observer's Local chat, and three blocks
of locked targets for tracking ship HP (two 3×3 grids and one column of two, 20 targets in all).

```
+----------------+----------------+-----------+-----------+
|                |   Observer B   | Targets 1 | Targets 2 |
|   Observer A   |  (1280×800)    | 3×3       | 3×3       |
|  (1280×1200)   |                | (576×928) | (576×928) |
|                +----------------+           |           |
|                |   Observer C   |           |           |
|                |  (1280×800)    +-----------+-----------+
+----------------+                | Targets 3 |
| Chat (1280×400)|                | 1×2       |
|                |                | (576×672) |
+----------------+----------------+-----------+
```

The overview and chat sources are fitted into their slots with "scale to inner bounds", so whatever
you capture keeps its aspect ratio and is anchored to the slot's top-left corner. The Targets
sources use "maximum size only" instead: a block that fits its slot is recorded at 1:1, and only one
cropped too large is scaled down to fit. The items are locked so they can't be dragged out of place
by accident.

## Setup

1. **Scene Collection → Import**, choose `scrim-recording.json`, then select "Scrim Recording" from
   the Scene Collection menu.
2. For each Observer source, open **Properties** and pick that observer's `EVE - <name>` window.
   Window IDs change every session, so the template leaves them blank.
3. The captures are already cropped for the window layout in [`docs/eve`](../eve/README.md):
   2486×1374 windowed, UI scale 1.75. If your observers use that layout, leave the crops as they
   are. If not, change Crop Top/Left/Right/Bottom in Properties until only the overview is left, so
   its text is drawn as large as possible in the slot. Crop off the title bar too.
4. Point **Chat** at one of the observer windows as well. It's cropped to that client's Local chat
   window (messages only; the input box can go). `scrim-positions --chat-log` reads it to match
   the recording against the chat log and find the EVE time. Keep the chat at the client's
   default font size so Tesseract can read it.
5. Point each **Targets** source at an observer window whose locked targets it should record. A
   source can use any observer, and several can share one. In that client, arrange the locked
   targets in the block's shape: three rows of three for Targets 1 and 2, a column of two for
   Targets 3. Then crop the source to exactly that block: the brackets with their
   shield/armor/hull rings and the pilot names underneath. At UI scale 1.75 one bracket, with its
   name and distance, is about 190×300, so a 3×3 grid comes to about 574×928 and the column of two
   to about 194×588. Don't let a crop go past its slot (576×928, or 576×672 for Targets 3), or the
   block gets scaled down. The template's crops were measured on clients with the target bar at
   the top left of the screen. If yours is somewhere else, adjust them.
6. **Settings → Video**: base (canvas) and output resolution both **3712×1600**, so the output is
   never rescaled. **Settings → Output → Recording**: near-lossless encode (x264 CQP ≈ 12, or
   lossless), 30 or 60 fps. See [DESIGN.md §3.3](../DESIGN.md#33-obs) for why.

## Processing

`scene.json` describes the same three slots as panels A, B and C for `scrim-positions`, the chat
slot as `chat`, and the three Targets slots as `targets` (Targets 1–3 in order):

```sh
scrim-positions --scene docs/obs/scene.json match.mkv
scrim-positions --scene docs/obs/scene.json --chat-log Local_….txt match.mkv   # one match, EVE timestamps
```

The slots are a starting point. A panel must contain the overview's header row and its rows, and
nothing below them that could be read as extra rows (a tab strip, another window). If your cropped
capture doesn't fill its slot, shrink that panel's `rect` to fit. The same goes for `chat`: the
closer it hugs the chat messages, the less else Tesseract has to read. Nothing reads `targets`
yet; it records where the HP blocks are for when something does.
