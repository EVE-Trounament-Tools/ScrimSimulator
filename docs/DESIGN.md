# scrim-recorder — design document

## 1. Overview

`scrim-recorder` records everything that happened on an EVE Online grid so a fight can later be
replayed and simulated. Three or four EVE clients sit stationary at spread positions on grid as
passive observers. OBS records their UI into one video file. An offline batch processor OCRs each
observer's overview, multilaterates every ship's position and velocity from the resulting distance
and radial-velocity readings, fuses in the client's on-disk game logs, and emits a recording.

Design posture, in one line: **nothing reads process memory.** Everything consumed is either
rendered on screen by the client for the player to look at, or written to disk by the client
itself — this stays firmly on the passive/observational side of CCP's third-party policy, unlike
approaches that attach to and read the client's process memory.

The OCR approach against the EVE UI is inspired by
[darkmatter2222/EVE-Online-Bot](https://github.com/darkmatter2222/EVE-Online-Bot), which reads UI
text with Tesseract behind manually-aligned ROI overlays. Notably it requires "UI set to 125%
scaling (tesseract needs this)" — a fragility this design avoids (§4.3).

### Goals

- Recover, at 1 Hz, every grid entity's position, velocity, pilot name, ship type and corp/
  alliance, purely from what observer clients render.
- Capture damage and effect events (webs, points, reps, guns, neuts, ECM) from combat logs.
- Capture per-ship shield/armor/hull state for anything an observer has locked.
- Produce a recording format that is stable, versioned, and inspectable by hand.
- Degrade gracefully rather than fail outright when fewer observers or anchors are available.

### Non-goals

- Any form of automation, input injection, or gameplay assistance. Passive capture only.
- Reading EVE client process memory, in any form.
- The simulator itself. This document specifies the format the simulator will read; the
  simulator is a separate project.

## 2. Principle

### 2.1 Position from distances

Each observer's overview shows the distance to every object on its grid. With observers at known
positions `oᵢ` and measured distances `dᵢ` to a ship at unknown `p`:

```
‖p − oᵢ‖ = dᵢ ,  i = 1..N
```

Three observers leave two mirror-image solutions; a fourth disambiguates. Solve by
Levenberg–Marquardt seeded from the previous tick's solution, which also makes the 3-observer case
usable (continuity picks the right root).

### 2.2 Velocity from radial velocities

The overview's **Radial Velocity** column is the rate of change of distance — i.e. the projection
of the ship's velocity onto the observer's line of sight, *provided the observer is stationary*
(hence "fixed positions"). That is linear in the unknown velocity `v`:

```
ûᵢ · v = rᵢ ,  ûᵢ = (p − oᵢ)/‖p − oᵢ‖
```

Four observers give an over-determined 4×3 linear system — one least-squares solve, no iteration.

### 2.3 Redundancy is the error-correction mechanism

Per observer the overview can show Distance, Velocity, Radial Velocity, Transversal Velocity and
Angular Velocity. Velocity is a global scalar `‖v‖`; transversal and angular are redundant with
each other given distance. So per ship per tick, four observers yield roughly **13 observations
constraining 6 unknowns** (`p`, `v`).

This surplus is the point. OCR misreads are not smooth — a dropped digit moves a value by an order
of magnitude — so robust least squares with outlier rejection (IRLS / RANSAC on small residual
sets) *detects and discards bad cells* rather than propagating them. Solver residual per entity is
recorded as a quality signal.

### 2.4 Frame establishment and the mirror problem

Observers are located per tick, not once, so drift needs no special handling:

1. **Mutual distances.** Each observer sees the other three on its overview. Six pairwise distances
   fix the tetrahedron's shape exactly (classical multidimensional scaling), up to translation,
   rotation and reflection.
2. **Celestial anchors.** Any celestial within a few hundred km displays in km and has exact SDE
   coordinates (`mapDenormalize`: x/y/z in metres, star at 0,0,0). Each such anchor is an extra
   known point.

Degradation ladder:

| Anchors in km range | Result |
| --- | --- |
| ≥2 celestials | Absolute SDE frame, chirality resolved. |
| 1 celestial | Absolute position, chirality ambiguous (reconstruction may be mirrored). |
| 0 | Relative frame only: geometry correct, orientation and handedness arbitrary. |

**Operational recommendation: fight the scrim near a gate, station or planet.** Scrims usually are
anyway, and it upgrades the recording to an absolute, non-mirrored frame for free. A mirrored
reconstruction is self-consistent and looks physically plausible but inverts every orbit
direction, so the manifest records which case applied and the replay must surface it.

### 2.5 Error budget

Distance display quantisation is the dominant term. EVE renders sub-10 km distances in metres and
larger ones in km with limited decimals, so quantisation `q` steps from ~1 m to ~100 m at the
10 km boundary; `σ_d ≈ q/√12` (≈29 m at 100 m quantisation). Position error is then roughly
`GDOP × σ_d`, where GDOP depends on how well the observers surround the fight — collinear
observers are catastrophic, a wide tetrahedron is ideal.

For observers spread over ~100 km around a fight of ~50 km extent, expect GDOP ≈ 2–5, i.e.
**order 10²–10³ m position error**. Velocity should be considerably better: radial velocity is
displayed in m/s and four readings are averaged.

These are estimates, refined empirically in §6, and the exact display-quantisation thresholds are
a calibration output, not a constant baked into the code.

## 3. Capture setup

This pipeline puts real requirements on the operator; they belong in the doc because a recording
made wrong is unrecoverable.

### 3.1 Observers

- 3-4 accounts, ideally 4. Cheap, fast-aligning ships; nothing that will be shot.
- **Spread wide and surround the fight.** Geometry drives accuracy more than anything else in
  this design. Avoid near-collinear placement.
- **Fully stopped** (not orbiting, not drifting). §2.2 assumes a stationary observer; a moving one
  silently poisons every radial-velocity reading it produces.
- **Lock as many grid objects as targeting range and slots allow.** Locked-target brackets render
  shield/armor/hull rings, which is this pipeline's only source of per-ship damage state (§4.6).
  Four observers × ~7-8 locks covers a typical scrim.

### 3.2 Client UI

- **Two overview windows** per client: one preset showing ships, a second showing celestials
  (gates, stations, planets, moons) for the anchors in §2.4. EVE supports multiple overview
  windows; one tab cannot show both without compromise.
- Columns enabled: Distance, Name, Type, Velocity, Radial Velocity, Transversal Velocity, plus
  Corp/Alliance for identity.
- Overview window as **tall as possible** — visible row count is a hard cap on how many ships an
  observer can contribute (§7). Sort by distance.
- Identical UI scale and layout across all four clients, so one ROI template set covers all.
- The EVE clock must be visible in at least one client (§4.2).

### 3.3 OBS

The single highest-risk area: video compression destroys small text, and a downscaled canvas
destroys it irrecoverably.

- **Composite crops, not whole screens.** Build one scene with a crop filter per ROI (each
  client's two overview windows, locked-target row, HUD, and one EVE clock) tiled at **1:1
  pixels**. A 4-up of full 1080p clients would force a 4K canvas; cropped ROIs fit in roughly
  1600×1000 with no loss of the pixels that matter.
- **Canvas resolution == output resolution.** Any "rescale output" setting silently resamples the
  text and must be off.
- **Near-lossless encode**: x264 CQP ≈ 12 or lossless, or NVENC lossless.
- **4:4:4 chroma if available.** 4:2:0 subsampling smears coloured overview text; if 4:4:4 isn't
  available, prefer ROIs where the glyph/background contrast survives luma alone.
- 30 fps is sufficient; 60 fps buys finer sub-second resolution.

A `docs/` checklist plus a reference OBS scene collection should ship alongside this doc, and
stage S0 (§4.1) validates a recording against these requirements before wasting a processing run.

## 4. Pipeline stages

Batch processor. Input: one video file, the clients' game logs, the SDE, a layout config. Output:
one recording directory in the format of §5.

### 4.1 S0 — Layout calibration

One-time per OBS scene. Locate each client's overview table, its column boundaries and row pitch
in canvas coordinates. The overview's window chrome, header row and row separators are
high-contrast and machine-detectable, so this is assisted rather than manual: auto-detect, render
a proposed overlay, let the operator nudge it. Output is a static `layout.toml`.

Also validates the recording: resolution, no scaling, bitrate/QP sanity, all expected ROIs
present.

### 4.2 S1 — Decode and time base

Decode with ffmpeg, keeping presentation timestamps. OCR the **in-game EVE clock** ROI (UTC,
second precision) to map video PTS → wall clock. That mapping is what aligns video to the game
logs (§4.7) and lets tick boundaries land exactly on second boundaries, matching log granularity.
It also lets several OBS files be stitched into one session.

### 4.3 S2 — Glyph OCR

The overview font is fixed, pixel-stable and rendered on a known background — the case general OCR
engines are worst at and template matching is best at. A per-glyph classifier trained once on the
actual font is both far more accurate on small anti-aliased digits and orders of magnitude faster
than Tesseract. It also removes any dependence on a specific UI scale.

- Segment a cell into glyph boxes by column-wise ink projection; classify each against templates
  by normalised cross-correlation.
- Numeric columns use a digit/separator/unit alphabet only — a tiny, closed, high-confidence set.
- Name/type columns use the full alphabet plus a **fuzzy match against a candidate set** (pilots
  seen in local, ship type names from the SDE), which corrects nearly every residual error.
- Every cell carries a confidence; low-confidence cells are dropped, not guessed.

**Every frame is OCR'd, not one per second.** Because overview values update continuously, the
result is a dense per-`(observer, ship, column)` time series at video framerate. OCR misreads are
isolated spikes in an otherwise smooth signal, so a **Hampel/median filter** removes them — a
strictly better use of the redundancy than mode-voting within a tick, and it means the pipeline
could emit faster than 1 Hz if wanted.

Cost is roughly 60 fps × 4 observers × ~50 rows × ~6 columns ≈ 7×10⁴ cells per second of video.
At microseconds per cell and embarrassingly parallel across frames, this stays within a small
multiple of realtime — irrelevant for a batch job.

### 4.4 S3 — Row parsing and identity

Parse each cell to a typed value (distances normalised to metres, velocities to m/s), recovering
the unit suffix. Associate rows across observers and across time by `(pilot name, ship type)` with
fuzzy matching and temporal stickiness. Assign a **synthetic stable entity ID** per session;
resolving names to real character IDs is a separate, offline ESI pass.

### 4.5 S4/S5 — Solve

Per tick: establish the observer frame (§2.4), then solve each entity's `p` and `v` (§2.1–2.3)
with robust least squares seeded from the previous tick. Record per-entity residual, the number of
contributing observers, and a GDOP estimate.

### 4.6 S6 — Locked-target HP rings

Locked-target brackets draw shield/armor/hull as three concentric arcs, white where HP remains and
red where it's lost. Read them by sampling 100 points along each arc and taking the white share —
pixel geometry, not OCR. The brackets aren't at fixed spots (rows move as long names wrap, and
each client may run another UI scale), so each recorded block is calibrated once for ring scale
and columns, and rings are found again every tick. Whose ring it is comes from the label under
it (name, ship type, range), read with Tesseract and matched to the overview roster. Yields
per-ship damage state over time for every ship any observer has locked.

### 4.7 S7 — Game log fusion

The client writes `Documents/EVE/logs/Gamelogs/*.txt` inside the Wine prefix, in the form:

```
[ 2021.07.29 19:04:13 ] (combat) 120 to XXX (Damavik) - Caldari Navy Nova Rocket - Hits
```

Exact, already-parsed-by-the-client, second-resolution, no OCR: damage per volley with weapon and
target, plus warp scramble / web / neut / ECM notifications. This is the **only** realistic source
of effect data in this design — OCR cannot see a module cycling on a hostile ship.

Each observer's log covers only what that observer did and had done to it. Passive observers
generate little, so log coverage comes primarily from the *participants'* logs, which should be
collected after the scrim and fed in as additional inputs.

### 4.8 S8 — Emit

Write the recording, one raw stream per observer plus a merged, solved grid stream, in the format
of §5.

## 5. Recording format

```
recordings/<session-id>/
  manifest.json                  # schema version, solar system, session start (wall + monotonic
                                 # clock), frame kind and anchors used (§2.4), observer positions
  layout.json                    # ROI/layout config used for this session (from calibrate)
  grid.jsonl.zst                 # one JSON object per tick: the merged, solved grid state
  observers/<observerID>.jsonl.zst  # optional: raw per-observer overview rows, pre-solve
  names.json                     # optional, written by the offline ESI resolution pass
```

Full state every tick — no delta encoding. Full snapshots keep the format seekable, diffable, and
trivial for a simulator to consume.

### Tick record (`grid.jsonl.zst`)

```json
{
  "seq": 42,
  "t": 42.0,
  "wall": "2026-09-05T18:22:04Z",
  "solarSystemID": 30002187,
  "entities": [
    {
      "id": "synthetic-000042",
      "charID": null,
      "name": "Some Pilot", "shipType": "Rifter",
      "corp": "Some Corp", "alliance": "Some Alliance",
      "p": [-1.2345678901e11, 4.56789e10, -8.9012e9],
      "v": [1234.56, -87.12, 402.00],
      "sigma": 340.2, "observers": 4, "residual": 0.008, "gdop": 2.3,
      "hp": { "shield": 0.93, "armor": 1.0, "hull": 1.0 }
    }
  ],
  "effects": [
    { "t": 41.0, "src": "Some Pilot", "tgt": "Another Pilot",
      "kind": "damage", "weapon": "Caldari Navy Nova Rocket", "amount": 120, "hit": "Hits" }
  ]
}
```

Conventions:

- Positions are solar-system metres as `f64`, absolute (when the frame permits, §2.4), rounded to
  centimetres. Velocities are m/s.
- `id` is a synthetic, session-stable identifier; `charID` is populated only after the offline ESI
  resolution pass, and is `null` until then.
- `t` is seconds since session start on a monotonic clock; `wall` is informational only.
- `sigma`, `observers`, `residual`, `gdop` are populated only for a multilaterated entity — absent
  when an entity had too few contributing observers to solve (§7).
- `hp` is present only for an entity some observer has locked (§4.6).
- Unknown or unreadable fields are omitted, never zero-filled.
- `manifest.json` carries a `schemaVersion`; consumers must refuse unknown majors.

## 6. Validation

No live game-state ground truth is available, so validation leans on constructions where the
correct answer is known independently of the pipeline:

- **Synthetic.** Generate overview values from known ship tracks, render them with the real OBS
  settings, and assert the solver recovers the tracks. Exercises the whole chain without a client.
- **Golden frames.** A handful of real video frames committed as fixtures, with expected OCR
  output, so glyph-matcher regressions are caught immediately.
- **Known-geometry.** Orbit an object at a set radius and known speed; assert recovered radius,
  orbital period, and speed. Warp between two celestials at a known SDE separation and known warp
  speed; assert the solved track's displacement and duration match.
- **Bookmark-distance check.** An EVE bookmark's info panel shows an exact distance to its
  location. Place a bookmark at a surveyed spot and confirm the solved position for a ship parked
  there matches within tolerance — a real-world, independently-known reference point.
- **Self-consistency.** Solver residuals and the redundant Velocity/Transversal columns are
  checked every tick in production, so a bad recording announces itself rather than silently
  producing plausible-looking garbage.

## 7. Limits

- **Overview visibility caps coverage.** Only rows actually rendered can be read; a 50-ship fight
  against a 30-row overview loses the far end. Per-ship coverage degrades gracefully (4 observers →
  full solve, 3 → continuity-disambiguated, ≤2 → position not recoverable, entity still recorded
  with distances only).
- **Effects are log-derived**, so they carry the logs' second resolution and only cover what the
  logs mention. No module-cycle state for hostiles, and no visibility into fitted turrets that
  never fire.
- **Observers must not move.** A drifting observer corrupts radial velocity silently; the solver
  can detect it (mutual distances stop being constant) and should flag it loudly.
- **Cloaked and off-grid ships** are invisible, exactly as they are to the observers themselves.
- **Mirror ambiguity** when no celestial anchor is in km range (§2.4).
- **A bad OBS config is unrecoverable.** Hence S0 validating before processing.
- **UI restyling** by CCP invalidates glyph templates and the layout config, fixed by re-running
  calibration.

## 8. Architecture

Rust, cargo workspace, one binary plus focused library crates:

```
crates/
  videoin/         ffmpeg decode, PTS handling, ROI extraction
  glyph/           template training + matcher, cell segmentation, confidence
  overview/        layout config, row/column parsing, typed values, identity tracking,
                   locked-target HP ring reader
  geometry/        observer frame solve (MDS + anchors), multilateration, robust LSQ, GDOP
  gamelog/         Wine-prefix discovery, log tailing/parsing, event mapping
  recording/       tick schema (serde), JSONL+zstd writer, manifest, session layout
  scrim-recorder/  CLI: calibrate | validate | process | inspect
```

### CLI surface

| Command | Purpose |
| --- | --- |
| `scrim-recorder calibrate --video V` | S0: detect/adjust ROIs, train glyph templates, write `layout.toml`. |
| `scrim-recorder validate --video V` | Check the recording meets §3.3 before processing. |
| `scrim-recorder process --video V --logs DIR --sde SDE --out DIR` | Full run: S1-S8. |
| `scrim-recorder inspect DIR --tick N` | Pretty-print a recorded tick as a table. |

## 9. Milestones

| # | Deliverable |
| --- | --- |
| M0 | `videoin` + `validate`: decode, ROI extraction, OBS-config checks, EVE-clock time base. |
| M1 | `glyph`: template training from a real recording, cell segmentation, numeric columns at measured accuracy. |
| M2 | `overview`: layout config, row parsing, cross-observer identity, dense time series + Hampel filtering. |
| M3 | `geometry`: observer frame incl. celestial anchors and chirality, multilateration, robust LSQ, GDOP. |
| M4 | `gamelog` ingestion and fusion; locked-target HP rings. |
| M5 | Emit recordings per §5; `inspect`. |
| M6 | Validation harness (§6: synthetic, golden frames, known-geometry, bookmark-distance); publish measured error budget. |

## 10. Open questions

- Exact distance-display quantisation thresholds and whether they vary with UI scale — measured in
  M6, not assumed.
- Whether Radial Velocity is displayed with enough precision at low speeds to beat differentiating
  the distance series; if not, prefer the derivative.
- Whether locked-target brackets render HP rings at a consistent radius across UI scales.
- How much overview row capacity a practical 4-up OBS layout actually yields.
- Whether participants' game logs can be collected reliably enough post-scrim to rely on for
  effects, or whether observers should also be lightly engaged to generate their own.
