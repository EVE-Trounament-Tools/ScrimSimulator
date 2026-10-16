//! Per-pilot position, speed and direction from a three-observer scrim recording. Every frame of
//! the video shows the three observers' overviews at once (an OBS scene described by a
//! `scene.json`, see `overview::panel`). Each panel is OCR'd and tracked independently, and the
//! per-observer tracks are merged into one roster by pilot name. Each pilot's three distances per
//! tick, with their speed, are then solved into a smoothed track (`overview::solve`): the observers
//! sit on three of the centre->corner diagonals of a 100 km cube that every pilot starts inside,
//! all the same distance from its centre (on the corners, or further out), and which diagonals and
//! how far out are inferred from the data (or the distance given with `--observer-distance-km`). The
//! observers don't move during a video, so with several matches every match is OCR'd first and
//! the observers' layout is inferred once from all of them.
//! The overview measures distance from the observer's hull edge, so the observers' hull radius
//! (`--observer-radius-m`, a Paladin's by default) is added to every distance before solving.
//! Where a track grazes the observers' plane and the distances can't tell which side it left for,
//! `overview::plane_exit` turns it clockwise unless the match (boundary, start, incoming motion,
//! scrams in the combat logs) says otherwise, and the CSV's `plane_exit,plane_exit_id,plane`
//! columns record the choice so the simulator can flip it.
//! Speed is the overview's own Velocity column. Direction is the slope of the solved positions,
//! because the overview shows speed only as a scalar.
//!
//! With `--chat-log`, the recording is matched against an EVE Local chat log by ScrimTrimmer
//! (`third_party/ScrimTrimmer`, via `scripts/scrim_trimmer_bridge.py`): it finds the EVE time at
//! video second 0 from the scene's `chat` rect and the match's CD -> WF/GF window, only that window
//! is OCR'd, and every CSV row gets its EVE time (`eve_time`) so the data can be lined up with
//! other EVE logs. A video holding several matches is processed one match (`--match N`) or all of
//! them (`--match all`) per run; with `all`, each match's outputs are named `<video>_NN.*`, where
//! an OBS-style `<video>` name ("2026-10-04 05-58-36") is cut to its date (`output_stem`).
//!
//! The audio of the processed window is saved next to the CSV as `<video>.mp3` (as ScrimTrimmer's
//! `--extract-audio` does), so it starts with the data and the simulator pairs the two by name.
//!
//! With `--combat-log` (and EVE times), every given EVE gamelog with combat during the match is
//! cut down to the match and saved in `<video>.positions.logs/` next to the CSV, the folder the
//! simulator reads a match's combat logs from.
//!
//! When the scene has `targets` blocks (locked-target brackets, `overview::targets`), every
//! ring's shield/armor/hull is read each tick, its label is OCR'd with Tesseract to tell whose
//! it is, and the CSV's `shield`, `armor` and `hull` columns carry each pilot's HP (0-1) wherever
//! some observer had them locked.

use anyhow::{bail, ensure, Context, Result};
use chrono::{DateTime, NaiveDate, NaiveDateTime, NaiveTime, TimeDelta, Utc};
use clap::Parser;
use glyph::Font;
use overview::layout::{Layout, Rect};
use overview::panel::{calibrate, crop_scaled, PanelSpec, Scene};
use overview::row::{read_rows, RowReading};
use overview::ship_types::ShipTypes;
use overview::gamelog;
use overview::plane_exit::{self, Exit, PilotTrack, Plane, Scram, Turn};
use overview::solve::{self, direction, infer_observers, solve_track, Fix, Reading};
use overview::targets::{
    label_image, match_label, ocr_label, read_rings, BlockGeometry, Candidate, Hp, Label, LabelCache, Ring,
};
use overview::track::{hampel_flags, Sample, Track, Tracker, CAPSULE};
use overview::util::levenshtein;
use rayon::prelude::*;
use std::collections::{BTreeMap, HashMap};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[derive(Parser)]
#[command(name = "scrim-positions", about = "OCR three observers' overviews into per-pilot positions")]
struct Cli {
    /// Scene config: each observer panel's rect (and optionally its calibrated scale).
    #[arg(long)]
    scene: PathBuf,
    /// Frames per second to sample (decoded by ffmpeg at this rate). 1 Hz matches DESIGN.md's
    /// tick rate.
    #[arg(long, default_value_t = 1.0)]
    fps: f64,
    /// Output directory for `<video>.positions.csv` and the same window's audio, `<video>.mp3`.
    #[arg(long, default_value = "resouces/matches/out")]
    out: PathBuf,
    /// Don't extract the processed window's audio to `<video>.mp3`.
    #[arg(long)]
    no_audio: bool,
    /// Also write each pilot's raw per-tick distances and speed to `<video>.readings.csv`
    /// (`t,pilot,d_a,d_b,d_c,speed_mps`) as the overview shows them (before the observer radius
    /// is added), for offline analysis.
    #[arg(long)]
    dump_readings: bool,
    /// EVE gamelog (`Documents/EVE/logs/Gamelogs/*.txt`), or a folder of them (repeatable).
    /// Each log with combat during the match is trimmed to it and saved in
    /// `<video>.positions.logs/`. Needs EVE times (`--chat-log` or `--t0`).
    #[arg(long = "combat-log", value_name = "PATH")]
    combat_logs: Vec<PathBuf>,
    /// How far the observers are from the cube's centre, along its centre->corner diagonals, in
    /// km (all three the same; 86.6 is on the corners). Fitted from the match when not given.
    #[arg(long = "observer-distance-km", value_name = "KM")]
    observer_distance_km: Option<f64>,
    /// The observers' hull radius in metres (all three the same; 0-10000, default a Paladin's).
    /// The overview measures from the observer's hull edge, so this is added to every distance
    /// before solving.
    #[arg(long = "observer-radius-m", value_name = "M", default_value_t = PALADIN_RADIUS_M, value_parser = parse_observer_radius)]
    observer_radius_m: f64,
    /// EVE Local chat log covering the recording (repeatable). Finds the match's CD -> WF/GF
    /// window and the EVE time base with ScrimTrimmer; only the match is processed, and the CSV
    /// gains an `eve_time` column.
    #[arg(long = "chat-log", value_name = "FILE")]
    chat_logs: Vec<PathBuf>,
    /// EVE time (UTC) at video second 0. With `--chat-log`, `HH:MM:SS` (skips detecting it from
    /// the chat region). Without, a full `YYYY-MM-DDTHH:MM:SSZ`: the whole video is processed and
    /// stamped with EVE times from it.
    #[arg(long)]
    t0: Option<String>,
    /// Which CD -> WF/GF pair to process (1-based) when the video holds more than one, or `all`
    /// to process each of them into its own `<video>_NN.*` outputs.
    #[arg(long = "match", value_name = "N|all")]
    match_sel: Option<MatchSel>,
    /// Use tournament system messages ("30 seconds until match start", "Match completed!") as
    /// the match window instead of CD and WF/GF.
    #[arg(long)]
    tournament: bool,
    /// Don't check that the chat log was written while the video was recorded (judged by the
    /// video file's modification time); for a copy of the recording that lost its file time.
    #[arg(long)]
    no_date_check: bool,
    /// Decode the video on the GPU with this ffmpeg `-hwaccel` (e.g. `cuda` for NVDEC, `vaapi`),
    /// leaving the CPU cores to OCR. Same frames either way; ffmpeg falls back to software decode
    /// when the accelerator isn't available.
    #[arg(long, env = "SCRIM_HWACCEL", value_name = "API")]
    hwaccel: Option<String>,
    /// Tesseract executable, for reading locked targets' labels.
    #[arg(long, env = "SCRIM_TESSERACT", default_value = "tesseract")]
    tesseract: PathBuf,
    /// Python interpreter that runs the ScrimTrimmer bridge.
    #[arg(long, env = "SCRIM_PYTHON", default_value = "python3")]
    python: String,
    /// The ScrimTrimmer bridge script.
    #[arg(long, default_value = concat!(env!("CARGO_MANIFEST_DIR"), "/../../scripts/scrim_trimmer_bridge.py"))]
    trimmer_bridge: PathBuf,
    videos: Vec<PathBuf>,
}

/// A Paladin's hull radius (SDE), the default observer.
const PALADIN_RADIUS_M: f64 = 250.0;
/// The largest `--observer-radius-m` accepted.
const MAX_OBSERVER_RADIUS_M: f64 = 10_000.0;

/// `--observer-radius-m`: metres, 0 to [`MAX_OBSERVER_RADIUS_M`].
fn parse_observer_radius(s: &str) -> Result<f64, String> {
    let m: f64 = s.trim().parse().map_err(|e| format!("{e}"))?;
    if (0.0..=MAX_OBSERVER_RADIUS_M).contains(&m) {
        Ok(m)
    } else {
        Err(format!("must be between 0 and {MAX_OBSERVER_RADIUS_M} m"))
    }
}

/// Which of a video's matches `--match` picks.
#[derive(Clone, Copy, Debug, PartialEq)]
enum MatchSel {
    /// The `n`th (1-based).
    One(usize),
    All,
}

impl std::str::FromStr for MatchSel {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, String> {
        if s.eq_ignore_ascii_case("all") {
            return Ok(Self::All);
        }
        match s.parse() {
            Ok(n @ 1..) => Ok(Self::One(n)),
            _ => Err(format!("{s:?} is not a match number (1, 2, …) or `all`")),
        }
    }
}

/// The part of a video to process, and the EVE time of its first frame (when known).
#[derive(Debug, PartialEq)]
struct Window {
    start_s: f64,
    end_s: Option<f64>,
    eve_origin: Option<DateTime<Utc>>,
}

/// What `scrim_trimmer_bridge.py` prints.
#[derive(serde::Deserialize)]
struct BridgeOutput {
    t0_utc: String,
    t0_source: String,
    pairs: Vec<(u32, u32)>,
}

/// Run the ScrimTrimmer bridge on `video` and pick its match windows, each with its 1-based
/// number when `--match all` picked more than one (so its outputs need their own names).
fn match_windows(cli: &Cli, scene: &Scene, video: &Path) -> Result<Vec<(Option<usize>, Window)>> {
    let mut cmd = Command::new(&cli.python);
    cmd.arg(&cli.trimmer_bridge).arg(video);
    for log in &cli.chat_logs {
        cmd.arg("--chat-log").arg(log);
    }
    if let Some(t0) = &cli.t0 {
        cmd.args(["--t0", t0]);
    } else {
        let Some(chat) = scene.chat else {
            bail!(
                "the scene has no `chat` rect, needed to find the EVE time from the chat log \
                 (see docs/obs/README.md), and no --t0 was given"
            );
        };
        let (w, h, _) = videoin::probe(video)?;
        let fractions = [chat.x as f64 / w as f64, chat.y as f64 / h as f64,
            (chat.x + chat.w) as f64 / w as f64, (chat.y + chat.h) as f64 / h as f64];
        cmd.arg("--chat-region").args(fractions.map(|f| format!("{f:.6}")));
    }
    if cli.tournament {
        cmd.arg("--tournament");
    }
    if cli.no_date_check {
        cmd.arg("--no-date-check");
    }
    println!("== {}: finding the match with ScrimTrimmer", video.display());
    let output = cmd
        .stderr(Stdio::inherit())
        .output()
        .with_context(|| format!("running {} {}", cli.python, cli.trimmer_bridge.display()))?;
    ensure!(output.status.success(), "ScrimTrimmer bridge failed ({})", output.status);
    let bridge: BridgeOutput =
        serde_json::from_slice(&output.stdout).context("parsing the ScrimTrimmer bridge's output")?;
    let t0: DateTime<Utc> = DateTime::parse_from_rfc3339(&bridge.t0_utc)
        .with_context(|| format!("bridge t0 {:?}", bridge.t0_utc))?
        .into();
    let picked = pick_pairs(&bridge.pairs, cli.match_sel)?;
    println!("  t0 {} ({})", bridge.t0_utc, bridge.t0_source);
    let numbered = picked.len() > 1;
    Ok(picked
        .into_iter()
        .map(|(i, (cd, wf))| {
            println!("  match {i}: {cd}s -> {wf}s of video");
            let window = Window {
                start_s: cd as f64,
                end_s: Some(wf as f64),
                eve_origin: Some(t0 + TimeDelta::seconds(cd as i64)),
            };
            (numbered.then_some(i), window)
        })
        .collect())
}

/// The `(cd, wf)` pairs to process, each with its 1-based number: the only one, the `n`th, or all.
fn pick_pairs(pairs: &[(u32, u32)], sel: Option<MatchSel>) -> Result<Vec<(usize, (u32, u32))>> {
    let numbered = pairs.iter().copied().enumerate().map(|(i, p)| (i + 1, p));
    match (pairs, sel) {
        ([], _) => bail!("no CD -> WF/GF pair found in the chat log within the video"),
        (_, Some(MatchSel::All)) => Ok(numbered.collect()),
        (_, Some(MatchSel::One(n))) => match pairs.get(n.wrapping_sub(1)) {
            Some(&p) => Ok(vec![(n, p)]),
            None => bail!("--match {n}, but the video has {} match(es): {pairs:?}", pairs.len()),
        },
        ([only], None) => Ok(vec![(1, *only)]),
        (_, None) => bail!(
            "the video has {} matches (video seconds {pairs:?}); pick one with --match N, or \
             process each with --match all",
            pairs.len()
        ),
    }
}

/// Output name for a video named `stem`: an OBS-style "YYYY-MM-DD HH-MM-SS" name keeps only its
/// date ("2026-10-04 05-58-36" -> "2026-10-04"); any other name is used as is.
fn output_stem(stem: &str) -> String {
    let (Some(date), Some(rest)) = (stem.get(..10), stem.get(10..)) else {
        return stem.to_string();
    };
    let is_time = |s: &str| NaiveTime::parse_from_str(s, "%H-%M-%S").is_ok();
    match rest.strip_prefix([' ', '_']).and_then(|r| r.get(..8).map(|t| (t, &r[8..]))) {
        Some((time, tail)) if NaiveDate::parse_from_str(date, "%Y-%m-%d").is_ok() && is_time(time) => {
            format!("{date}{tail}")
        }
        _ => stem.to_string(),
    }
}

/// `--t0` without a chat log: a full UTC date and time.
fn parse_t0_utc(s: &str) -> Result<DateTime<Utc>> {
    if let Ok(t) = DateTime::parse_from_rfc3339(s) {
        return Ok(t.into());
    }
    NaiveDateTime::parse_from_str(s.trim_end_matches('Z'), "%Y-%m-%dT%H:%M:%S")
        .map(|t| t.and_utc())
        .with_context(|| format!("--t0 {s:?}: without --chat-log it must be YYYY-MM-DDTHH:MM:SSZ"))
}

/// EVE time of a CSV tick `t` seconds after `origin`, to the millisecond.
fn eve_time(origin: DateTime<Utc>, t: f64) -> String {
    (origin + TimeDelta::milliseconds((t * 1000.0).round() as i64))
        .format("%Y-%m-%dT%H:%M:%S%.3fZ")
        .to_string()
}

/// How many leading frames to try calibrating on before giving up — the first frame of a match
/// can catch a panel mid-redraw.
const CALIBRATION_ATTEMPTS: usize = 10;

/// A per-observer track shorter than this fraction of the video's sampled frames, that matches
/// no roster pilot, is OCR noise (a badly misread name opening its own track) and is dropped.
const MIN_TRACK_FRACTION: f64 = 0.05;

/// Max edit distance between two observers' spellings of the same pilot. Looser than the
/// tracker's own within-observer tolerance (1): each observer reads the name at a different scale
/// and so settles on its own look-alike misread (`ZIO`/`ZJO`, `abcd1`/`abcdL`), and two such
/// independent single-glyph misreads put the canonical spellings 2 apart. Short names stay at 1
/// so two genuinely different short names can't merge.
fn roster_tolerance(name: &str) -> usize {
    if name.chars().count() >= 6 {
        2
    } else {
        1
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    if cli.videos.is_empty() {
        bail!("no videos given");
    }
    let scene = Scene::load(&cli.scene)
        .with_context(|| format!("loading scene {}", cli.scene.display()))?;
    if scene.panels.len() != 3 {
        bail!("scene has {} panels; trilateration needs exactly 3 observers", scene.panels.len());
    }
    let font = Font::builtin().context("training built-in font")?;
    std::fs::create_dir_all(&cli.out)
        .with_context(|| format!("creating {}", cli.out.display()))?;

    if cli.chat_logs.is_empty() && cli.match_sel.is_some() {
        bail!("--match needs --chat-log");
    }
    if let (false, Some(t0)) = (cli.chat_logs.is_empty(), &cli.t0) {
        NaiveTime::parse_from_str(t0, "%H:%M:%S")
            .with_context(|| format!("--t0 {t0:?}: with --chat-log it must be HH:MM:SS"))?;
    }

    let mut failed = 0;
    for video in &cli.videos {
        let windows = if !cli.chat_logs.is_empty() {
            match_windows(&cli, &scene, video)
        } else {
            cli.t0.as_deref().map(parse_t0_utc).transpose().map(|eve_origin| {
                vec![(None, Window { start_s: 0.0, end_s: None, eve_origin })]
            })
        }
        .with_context(|| format!("finding the match in {}", video.display()))?;
        let stem = output_stem(&video.file_stem().unwrap_or_default().to_string_lossy());
        let n = windows.len();
        // The observers don't move during a video, so every match is OCR'd first and the
        // layout is inferred once from all of them: a match whose start can't tell the
        // layout apart borrows the evidence of the others.
        let mut reads: Vec<(Option<usize>, MatchRead)> = Vec::new();
        for (i, window) in windows {
            let Some(i) = i else {
                reads.push((None, read_match(&cli, &scene, &font, video, &stem, window)?));
                continue;
            };
            println!("== match {i}/{n} of {}", video.display());
            // One bad match shouldn't lose the others.
            match read_match(&cli, &scene, &font, video, &format!("{stem}_{i:02}"), window) {
                Ok(m) => reads.push((Some(i), m)),
                Err(e) => {
                    eprintln!("  error: match {i}: {e:#}");
                    failed += 1;
                }
            }
        }
        if reads.is_empty() {
            continue;
        }
        let pilots: Vec<Vec<Reading>> =
            reads.iter().flat_map(|(_, m)| m.readings.iter().map(|r| r.as_readings(cli.observer_radius_m))).collect();
        let fit = infer_observers(&pilots, cli.observer_distance_km.map(|km| km * 1000.0));
        println!(
            "== {}: observers ({} m hull radius), from {} match(es)",
            video.display(),
            cli.observer_radius_m,
            reads.len()
        );
        let names: Vec<&str> = scene.panels.iter().map(|p| p.name.as_str()).collect();
        print_corners(&names, &fit);
        for (i, m) in &reads {
            let Some(i) = i else {
                write_match(&cli, video, m, fit.corners)?;
                continue;
            };
            println!("== match {i}/{n} of {}", video.display());
            if let Err(e) = write_match(&cli, video, m, fit.corners) {
                eprintln!("  error: match {i}: {e:#}");
                failed += 1;
            }
        }
    }
    ensure!(failed == 0, "{failed} match(es) failed");
    Ok(())
}

/// OCR one match window of `video`, up to the per-pilot readings; outputs are named `<out_stem>.*`.
fn read_match(cli: &Cli, scene: &Scene, font: &Font, video: &Path, out_stem: &str, window: Window) -> Result<MatchRead> {
    process_video(video, scene, font, cli, out_stem, window)
        .with_context(|| format!("processing {}", video.display()))
}

/// Solve an OCR'd match with the observers at `corners` and save its CSV, audio and combat logs.
/// The combat logs are saved first: their scrams are evidence for the plane exits in the CSV.
fn write_match(cli: &Cli, video: &Path, m: &MatchRead, corners: [solve::V3; 3]) -> Result<()> {
    let (out_stem, window) = (m.out_stem.as_str(), &m.window);
    let eve_span = match_eve_span(m);
    if !cli.no_audio {
        save_audio(video, &cli.out, out_stem, window);
    }
    let mut logs = Vec::new();
    if !cli.combat_logs.is_empty() {
        match eve_span {
            Some(span) => logs = save_combat_logs(&cli.combat_logs, &cli.out, out_stem, span),
            None => eprintln!(
                "  warning: no EVE times (give --chat-log or --t0); combat logs not saved"
            ),
        }
    }
    solve_match(m, corners, cli.observer_radius_m, &cli.out, &logs)
}

/// Extract the window's audio to `<out>/<out_stem>.mp3`. Audio is an extra, so a failure (or a
/// recording without an audio track) is reported and the positions CSV is kept.
fn save_audio(video: &Path, out: &Path, out_stem: &str, window: &Window) {
    let path = out.join(format!("{out_stem}.mp3"));
    match videoin::extract_audio(video, window.start_s, window.end_s, &path) {
        Ok(true) => println!("  wrote {}", path.display()),
        Ok(false) => println!("  {} has no audio track; no audio saved", video.display()),
        Err(e) => eprintln!("  warning: audio extraction failed: {e:#}"),
    }
}

/// Save the part of each gamelog in `logs` (files, or folders of them) logged during `span` (EVE
/// times of the first and last CSV rows) to `<out>/<out_stem>.positions.logs/`, skipping logs
/// with no combat in it. Like audio, combat logs are an extra: failures are reported and the CSV
/// is kept. Returns the saved logs.
fn save_combat_logs(
    logs: &[PathBuf],
    out: &Path,
    out_stem: &str,
    span: (DateTime<Utc>, DateTime<Utc>),
) -> Vec<PathBuf> {
    let dest = out.join(format!("{out_stem}.positions.logs"));
    let (first, last) = (span.0.naive_utc(), span.1.naive_utc());
    // A rerun replaces the previous run's logs rather than adding to them.
    if let Ok(old) = std::fs::read_dir(&dest) {
        for entry in old.flatten() {
            if entry.path().extension().is_some_and(|e| e.eq_ignore_ascii_case("txt")) {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
    let mut saved = std::collections::BTreeSet::new();
    for log in logs {
        if !log.is_dir() {
            // Picked by hand, so say what became of it.
            match save_combat_log(log, &dest, first, last) {
                Ok(Some(path)) => {
                    println!("  saved {}", path.display());
                    saved.insert(path);
                }
                Ok(None) => println!("  {}: no combat during the match", log.display()),
                Err(e) => eprintln!("  warning: {}: {e:#}", log.display()),
            }
            continue;
        }
        let entries = match std::fs::read_dir(log) {
            Ok(e) => e,
            Err(e) => {
                eprintln!("  warning: reading {}: {e}", log.display());
                continue;
            }
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.extension().is_some_and(|e| e.eq_ignore_ascii_case("txt")) {
                continue;
            }
            // Cheap skips before reading a whole Gamelogs folder: a log started after the match
            // (its name starts with the session's EVE start time), or last written before it (a
            // copied log gets a new mtime, so this can only let extra logs through).
            let name = path.file_name().unwrap_or_default().to_string_lossy();
            if name.get(..15).and_then(|s| NaiveDateTime::parse_from_str(s, "%Y%m%d_%H%M%S").ok())
                .is_some_and(|start| start > last)
            {
                continue;
            }
            if entry.metadata().and_then(|m| m.modified()).is_ok_and(|m| {
                DateTime::<Utc>::from(m) < span.0 - TimeDelta::minutes(1)
            }) {
                continue;
            }
            match save_combat_log(&path, &dest, first, last) {
                Ok(Some(path)) => {
                    println!("  saved {}", path.display());
                    saved.insert(path);
                }
                Ok(None) => {}
                Err(e) => eprintln!("  warning: {}: {e:#}", path.display()),
            }
        }
    }
    println!("  {} combat log(s) with combat during the match", saved.len());
    saved.into_iter().collect()
}

/// Save gamelog `log` trimmed to `first..=last` in `dest`, returning where; None if it has no
/// combat then. An identical log already there (the same file given twice) is reused; a
/// different one with the same name (from another folder) gets a " (2)", … suffix.
fn save_combat_log(
    log: &Path,
    dest: &Path,
    first: NaiveDateTime,
    last: NaiveDateTime,
) -> Result<Option<PathBuf>> {
    let bytes = std::fs::read(log).context("reading")?;
    let Some(text) = trim_gamelog(&String::from_utf8_lossy(&bytes), first, last) else {
        bail!("not an EVE gamelog (no Listener header)");
    };
    if !text.lines().any(|l| l.contains("] (combat) ")) {
        return Ok(None);
    }
    std::fs::create_dir_all(dest).with_context(|| format!("creating {}", dest.display()))?;
    let stem = log.file_stem().unwrap_or_default().to_string_lossy();
    for n in 1.. {
        let name = if n == 1 { format!("{stem}.txt") } else { format!("{stem} ({n}).txt") };
        let path = dest.join(name);
        match std::fs::read_to_string(&path) {
            Ok(existing) if existing == text => return Ok(Some(path)),
            Ok(_) => continue,
            Err(_) => {
                std::fs::write(&path, &text).with_context(|| format!("writing {}", path.display()))?;
                return Ok(Some(path));
            }
        }
    }
    unreachable!()
}

/// Gamelog `text` cut down to its header and the lines logged between EVE times `first` and
/// `last` (a multi-line message's extra lines go with it), as the simulator's `CombatLog.trim`
/// does. None if `text` isn't a gamelog (no `Listener:` header).
fn trim_gamelog(text: &str, first: NaiveDateTime, last: NaiveDateTime) -> Option<String> {
    let mut out = String::new();
    let (mut header, mut listener, mut keep) = (true, false, false);
    for line in text.split_inclusive('\n') {
        let time = line
            .strip_prefix("[ ")
            .and_then(|l| l.get(..19))
            .and_then(|s| NaiveDateTime::parse_from_str(s, "%Y.%m.%d %H:%M:%S").ok());
        header = header && time.is_none();
        if header {
            listener = listener || line.trim().starts_with("Listener:");
            out.push_str(line);
            continue;
        }
        if let Some(t) = time {
            keep = t >= first && t <= last;
        }
        if keep {
            out.push_str(line);
        }
    }
    listener.then_some(out)
}

/// One observer panel, calibrated for this video.
struct Panel<'a> {
    spec: &'a PanelSpec,
    scale: f32,
    layout: Layout,
}

/// One match, OCR'd and merged into pilots, waiting for the observers' corners to be solved.
struct MatchRead {
    out_stem: String,
    window: Window,
    per_observer: Vec<Vec<Track>>,
    roster: Vec<Pilot>,
    readings: Vec<PilotReadings>,
    hp: Vec<BTreeMap<u64, Hp>>,
    times: Vec<f64>,
}

fn process_video(
    video: &Path,
    scene: &Scene,
    font: &Font,
    cli: &Cli,
    out_stem: &str,
    window: Window,
) -> Result<MatchRead> {
    let (fps, hwaccel, out) = (cli.fps, cli.hwaccel.as_deref(), cli.out.as_path());
    let started = std::time::Instant::now();
    let batch_size = 2 * rayon::current_num_threads();
    // Decode on a background thread, one batch ahead, so ffmpeg keeps decoding while a batch is
    // OCR'd instead of stalling on a full pipe.
    let mut decoder =
        videoin::Decoder::open_range_hw(video, Some(fps), window.start_s, window.end_s, hwaccel)?
            .prefetch(batch_size);
    println!(
        "== {}: {}x{}, sampling at {fps} fps",
        video.display(),
        decoder.width,
        decoder.height
    );

    // Each panel calibrates on the first of the window's leading frames it can; one still
    // failing after that (its header hidden all along, e.g. by a hover tooltip) falls back to
    // another part of the video, since the client layout doesn't change between matches.
    let mut pending = Vec::new();
    let mut found: Vec<Option<(f32, Layout)>> = vec![None; scene.panels.len()];
    let mut errors: Vec<String> = vec![String::new(); scene.panels.len()];
    while found.iter().any(Option::is_none) && pending.len() < CALIBRATION_ATTEMPTS {
        let Some(frame) = decoder.next_frame()? else { break };
        let attempts: Vec<(usize, Result<(f32, Layout)>)> = (0..scene.panels.len())
            .into_par_iter()
            .filter(|&i| found[i].is_none())
            .map(|i| (i, calibrate(&frame.image, &scene.panels[i], font)))
            .collect();
        for (i, attempt) in attempts {
            match attempt {
                Ok(fit) => found[i] = Some(fit),
                Err(e) => errors[i] = format!("{e:#}"),
            }
        }
        pending.push(frame);
    }
    for (i, fit) in found.iter_mut().enumerate() {
        if fit.is_none() {
            let spec = &scene.panels[i];
            eprintln!(
                "  panel {} didn't calibrate in the first {} frames ({}); trying elsewhere in the video",
                spec.name,
                pending.len(),
                errors[i]
            );
            *fit = Some(calibrate_elsewhere(video, &window, spec, font, hwaccel)?);
        }
    }
    let panels: Vec<Panel> = scene
        .panels
        .iter()
        .zip(found)
        .map(|(spec, fit)| {
            let (scale, layout) = fit.expect("every panel calibrated");
            Panel { spec, scale, layout }
        })
        .collect();
    for p in &panels {
        println!(
            "  panel {}: scale {:.4}, row pitch {:.2}",
            p.spec.name, p.scale, p.layout.row_pitch
        );
    }

    let mut trackers: Vec<Tracker> = panels.iter().map(|_| Tracker::new()).collect();
    let mut targets = TargetReader::new(&scene.targets, &cli.tesseract);
    let mut times = Vec::new();
    loop {
        while pending.len() < batch_size {
            match decoder.next_frame()? {
                Some(f) => pending.push(f),
                None => break,
            }
        }
        if pending.is_empty() {
            break;
        }
        let jobs: Vec<(usize, usize)> = (0..pending.len())
            .flat_map(|f| (0..panels.len()).map(move |p| (f, p)))
            .collect();
        let rows: Vec<Vec<RowReading>> = jobs
            .par_iter()
            .map(|&(f, p)| {
                let panel = &panels[p];
                let crop = crop_scaled(&pending[f].image, panel.spec.rect, panel.scale);
                read_rows(&crop, &panel.layout, font)
            })
            .collect();
        for (&(f, p), r) in jobs.iter().zip(&rows) {
            trackers[p].observe(pending[f].t, r);
        }
        targets.observe(&pending);
        times.extend(pending.iter().map(|f| f.t));
        pending.clear();
        eprint!("\r  {} frames ({:.0}s of video)", times.len(), times.last().unwrap_or(&0.0));
    }
    eprintln!();

    let per_observer: Vec<Vec<Track>> = trackers.into_iter().map(Tracker::finish).collect();
    let roster = build_roster(&per_observer, times.len());

    let readings: Vec<PilotReadings> =
        roster.iter().map(|p| pilot_readings(&per_observer, p, &times)).collect();
    if readings.iter().all(|r| r.distances.is_empty()) {
        bail!("no pilot was seen by all three observers in the same tick");
    }
    if cli.dump_readings {
        let path = out.join(format!("{out_stem}.readings.csv"));
        std::fs::write(&path, readings_csv(&roster, &readings))?;
        println!("  wrote {}", path.display());
    }
    let hp = targets.pilot_hp(&per_observer, &roster);
    println!("  read {} frames in {:.0}s", times.len(), started.elapsed().as_secs_f64());
    Ok(MatchRead { out_stem: out_stem.to_string(), window, per_observer, roster, readings, hp, times })
}

/// EVE times of the match's first and last ticks, when known.
fn match_eve_span(m: &MatchRead) -> Option<(DateTime<Utc>, DateTime<Utc>)> {
    let (origin, first, last) = (m.window.eve_origin?, m.times.first()?, m.times.last()?);
    let at = |t: f64| origin + TimeDelta::milliseconds((t * 1000.0).round() as i64);
    Some((at(*first), at(*last)))
}

/// Solve every pilot's track with the observers at `corners`, settle its ambiguous plane exits
/// (`overview::plane_exit`, with the scrams in `logs` as evidence) and write
/// `<out_stem>.positions.csv`.
fn solve_match(
    m: &MatchRead,
    corners: [solve::V3; 3],
    observer_radius_m: f64,
    out: &Path,
    logs: &[PathBuf],
) -> Result<()> {
    let MatchRead { out_stem, window, per_observer, roster, readings, hp, times } = m;
    let plane = Plane::from_observers(corners);
    let mut tracks: Vec<PilotTrack> = roster
        .iter()
        .zip(readings)
        .map(|(pilot, r)| {
            let fixes = solve_track(corners, &r.as_readings(observer_radius_m));
            let capsule = fixes.iter().map(|f| ship_type_at(per_observer, pilot, f.t) == CAPSULE).collect();
            PilotTrack { fixes, capsule }
        })
        .collect();
    let scrams = window.eve_origin.map_or_else(Vec::new, |origin| load_scrams(logs, roster, origin));
    let exits = plane_exit::resolve(&plane, &mut tracks, &scrams, match_start(readings));
    let solved: Vec<Vec<Fix>> = tracks.into_iter().map(|t| t.fixes).collect();

    let path = out.join(format!("{out_stem}.positions.csv"));
    std::fs::write(
        &path,
        positions_csv(per_observer, roster, readings, &solved, hp, window.eve_origin, &plane, &exits),
    )?;
    print_summary(per_observer, roster, readings, &solved);
    print_exits(roster, &exits, scrams.len());
    if let Some((first, last)) = match_eve_span(m) {
        println!("  EVE time {} -> {}", fmt_eve(first), fmt_eve(last));
    }
    println!("  wrote {} ({} frames)", path.display(), times.len());
    Ok(())
}

fn fmt_eve(t: DateTime<Utc>) -> String {
    t.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string()
}

/// Overview speed above which a ship has started moving (ships waiting out the countdown read
/// 0-1 m/s), as the simulator's `MatchData.MOVE_SPEED_MPS`.
const MOVE_SPEED_MPS: f64 = 10.0;

/// The tick the match starts: the first any pilot's overview speed passes [`MOVE_SPEED_MPS`].
fn match_start(readings: &[PilotReadings]) -> f64 {
    readings
        .iter()
        .flat_map(|r| r.distances.iter().filter(|(t, _)| r.speed.get(&t.to_bits()).is_some_and(|&v| v > MOVE_SPEED_MPS)))
        .map(|(t, _)| *t)
        .fold(f64::INFINITY, f64::min)
}

/// The warp scramble/disruption attempts in `logs` between two of the roster's pilots, at match
/// times (`origin` is the EVE time of t = 0).
fn load_scrams(logs: &[PathBuf], roster: &[Pilot], origin: DateTime<Utc>) -> Vec<Scram> {
    let names: Vec<&str> = roster.iter().map(|p| p.name.as_str()).collect();
    let mut out: Vec<Scram> = Vec::new();
    for path in logs {
        let Ok(bytes) = std::fs::read(path) else { continue };
        let log = gamelog::parse(&String::from_utf8_lossy(&bytes));
        let listener = gamelog::resolve_pilot(&log.listener, &names);
        let who = |name: &str| if name.is_empty() { listener } else { gamelog::resolve_pilot(name, &names) };
        for s in &log.scrams {
            let (Some(source), Some(target)) = (who(&s.source), who(&s.target)) else { continue };
            let t = (s.eve.and_utc() - origin).num_milliseconds() as f64 / 1000.0;
            let scram = Scram { t, source, target, disruption: s.disruption, source_ship: s.source_ship.clone() };
            // Both pilots' logs show the same attempt.
            if !out.iter().any(|o| o.t == t && o.source == source && o.target == target && o.disruption == s.disruption) {
                out.push(scram);
            }
        }
    }
    out
}

/// One line for the plane exits, and one per exit that evidence turned counterclockwise.
fn print_exits(roster: &[Pilot], exits: &[Vec<Exit>], n_scrams: usize) {
    let total: usize = exits.iter().map(Vec::len).sum();
    let ccw: usize = exits.iter().flatten().filter(|e| e.turn == Turn::Ccw).count();
    println!("  plane exits: {total} ({ccw} counterclockwise; {n_scrams} scram(s) as evidence)");
    for (pilot, exits) in roster.iter().zip(exits) {
        for (k, e) in exits.iter().enumerate().filter(|(_, e)| e.turn == Turn::Ccw) {
            println!("    {} exit {} at t={:.0}: {}", pilot.name, k + 1, e.t, e.reasons.join("; "));
        }
    }
}

/// How far apart, and how far either side of the match window, [`calibrate_elsewhere`] looks.
const FALLBACK_STEP_S: f64 = 60.0;
const FALLBACK_STEPS: usize = 30;
/// How many frames [`calibrate_elsewhere`] calibrates on before keeping the best.
const FALLBACK_FITS: usize = 5;

/// Calibrate panel `spec` on frames from outside `window`: one frame every [`FALLBACK_STEP_S`],
/// alternately before and after the window, nearest first. Of the first [`FALLBACK_FITS`] that
/// calibrate, the one showing the longest list wins: a layout only reads a few rows past the
/// last one its calibration frame showed (`Layout::list_bottom`), and between matches the
/// overview may list only a handful of ships.
fn calibrate_elsewhere(
    video: &Path,
    window: &Window,
    spec: &PanelSpec,
    font: &Font,
    hwaccel: Option<&str>,
) -> Result<(f32, Layout)> {
    let mut fits: Vec<(f64, (f32, Layout))> = Vec::new();
    let mut past_end = false;
    'search: for k in 1..=FALLBACK_STEPS {
        let step = k as f64 * FALLBACK_STEP_S;
        let before = window.start_s - step;
        let after = window.end_s.map(|e| e + step).filter(|_| !past_end);
        for t in [Some(before).filter(|&t| t >= 0.0), after].into_iter().flatten() {
            let mut decoder = videoin::Decoder::open_range_hw(video, Some(1.0), t, Some(t + 1.0), hwaccel)?;
            let Some(frame) = decoder.next_frame()? else {
                past_end |= t > window.start_s;
                continue;
            };
            if let Ok(fit) = calibrate(&frame.image, spec, font) {
                fits.push((t, fit));
                if fits.len() >= FALLBACK_FITS {
                    break 'search;
                }
            }
        }
    }
    let Some((t, fit)) = fits.into_iter().max_by_key(|(_, (_, layout))| layout.list_bottom) else {
        bail!("panel {:?} didn't calibrate anywhere within {FALLBACK_STEPS} minutes of the match", spec.name);
    };
    println!("  panel {} calibrated on the frame at {t:.0}s of the video", spec.name);
    Ok(fit)
}

/// Seconds either side of a fix used to fit its direction.
const DIRECTION_HALF_WINDOW_S: f64 = 3.0;

fn print_corners(names: &[&str], fit: &solve::ObserverFit) {
    let fmt = |corners: [solve::V3; 3]| {
        let mut s = String::new();
        for (n, c) in names.iter().zip(corners) {
            let _ = write!(s, " {n}=({:.0},{:.0},{:.0})", c[0] / 1e3 + 0.0, c[1] / 1e3 + 0.0, c[2] / 1e3 + 0.0);
        }
        s
    };
    let speed = fit.cost.speed_err.map_or("n/a".to_string(), |e| format!("{e:.3}"));
    println!(
        "  observers (km):{}  fit cost {:.0} m (start {:.0} m, speed error {speed}), next shape {:.0} m",
        fmt(fit.corners),
        fit.score,
        fit.cost.start_m,
        fit.runner_up
    );
    let plane = plane_exit::Plane::from_observers(fit.corners);
    let gap = plane.offset([solve::CUBE_M / 2.0; 3]).abs();
    println!(
        "  observers {:.1} km from the centre ({:.1} km past the corners); their plane is {:.1} km from the centre, the arena edge {:.0} km",
        fit.r_m / 1e3,
        (fit.r_m - solve::CORNER_R_M) / 1e3,
        gap / 1e3,
        plane_exit::BOUNDARY_RADIUS_M / 1e3
    );
    if let Some(next) = fit.runner_up_corners {
        println!("  next shape (km):{}", fmt(next));
    }
    if fit.is_ambiguous() {
        eprintln!("  warning: corner choice is ambiguous; another observer layout fits almost as well");
    }
    if gap < plane_exit::BOUNDARY_RADIUS_M + SAFE_PLANE_MARGIN_M {
        println!(
            "  note: the observers' plane cuts the arena, so a ship that flies along it can be mirrored. \
             On three corners of one face, {:.0} km or more from the centre keeps it outside.",
            safe_observer_distance_m() / 1e3
        );
    }
}

/// How far past the arena edge the observers' plane should be: the distances' rounding blurs
/// which side a ship is on within a few km of it.
const SAFE_PLANE_MARGIN_M: f64 = 5_000.0;

/// Observers this far out along the diagonals of three corners of one face keep their plane
/// [`SAFE_PLANE_MARGIN_M`] outside the arena: the plane is `R / √3` from the centre.
fn safe_observer_distance_m() -> f64 {
    (plane_exit::BOUNDARY_RADIUS_M + SAFE_PLANE_MARGIN_M) * 3f64.sqrt()
}

/// One pilot's per-tick inputs to the solve: the ticks where all three observers have an
/// unflagged distance, and the ticks with a usable speed.
struct PilotReadings {
    distances: Vec<(f64, [f64; 3])>,
    speed: BTreeMap<u64, f64>,
}

/// `--dump-readings` output: one row per pilot per tick with all three distances as the overview
/// shows them (hull-edge, without the observer radius).
fn readings_csv(roster: &[Pilot], readings: &[PilotReadings]) -> String {
    let mut csv = String::from("t,pilot,d_a,d_b,d_c,speed_mps\n");
    for (pilot, r) in roster.iter().zip(readings) {
        for &(t, [a, b, c]) in &r.distances {
            let speed = r.speed.get(&t.to_bits()).map_or(String::new(), |v| format!("{v:.0}"));
            let _ = writeln!(csv, "{t:.3},{},{a:.0},{b:.0},{c:.0},{speed}", pilot.name);
        }
    }
    csv
}

impl PilotReadings {
    /// This pilot's distance ticks with their speeds, as corner inference and the solve take them:
    /// the overview's hull-edge distances plus the observers' hull radius, so centre to centre.
    fn as_readings(&self, observer_radius_m: f64) -> Vec<Reading> {
        self.distances
            .iter()
            .map(|&(t, d)| Reading {
                t,
                d: d.map(|x| x + observer_radius_m),
                speed_mps: self.speed.get(&t.to_bits()).copied(),
            })
            .collect()
    }
}

/// Collect a pilot's distance triples and speeds per tick. Speed is the median of the observers'
/// unflagged Velocity readings, because speed is the same whichever observer reads it.
fn pilot_readings(per_observer: &[Vec<Track>], pilot: &Pilot, times: &[f64]) -> PilotReadings {
    let dist: Vec<_> =
        (0..3).map(|o| observer_series(per_observer, pilot, o, |s| s.distance_m)).collect();
    let vel: Vec<_> =
        (0..3).map(|o| observer_series(per_observer, pilot, o, |s| s.speed_mps)).collect();
    let unflagged = |s: &BTreeMap<u64, (f64, bool)>, t: f64| {
        s.get(&t.to_bits()).filter(|(_, f)| !f).map(|&(v, _)| v)
    };
    let mut out = PilotReadings { distances: Vec::new(), speed: BTreeMap::new() };
    for &t in times {
        if let [Some(a), Some(b), Some(c)] = [0, 1, 2].map(|o| unflagged(&dist[o], t)) {
            out.distances.push((t, [a, b, c]));
        }
        let mut v: Vec<f64> = vel.iter().filter_map(|s| unflagged(s, t)).collect();
        if !v.is_empty() {
            v.sort_by(f64::total_cmp);
            let m = v.len() / 2;
            let median = if v.len() % 2 == 1 { v[m] } else { (v[m - 1] + v[m]) / 2.0 };
            out.speed.insert(t.to_bits(), median);
        }
    }
    out
}

/// One real pilot, merged across observers: which `(observer, track index)` pairs are theirs.
struct Pilot {
    name: String,
    members: Vec<(usize, usize)>,
}

/// Merge every observer's tracks into one roster by name. Longest tracks go first, so a pilot's
/// canonical name is its best-observed spelling, and the short splinter tracks a bad misread
/// opens (see `tests/video_sample.rs`) fold into an existing pilot instead of founding one.
fn build_roster(per_observer: &[Vec<Track>], n_frames: usize) -> Vec<Pilot> {
    let mut order: Vec<(usize, usize)> = per_observer
        .iter()
        .enumerate()
        .flat_map(|(o, tracks)| (0..tracks.len()).map(move |t| (o, t)))
        .collect();
    order.sort_by_key(|&(o, t)| std::cmp::Reverse(per_observer[o][t].samples.len()));

    let min_samples = ((n_frames as f64 * MIN_TRACK_FRACTION) as usize).max(3);
    let mut roster: Vec<Pilot> = Vec::new();
    for (o, t) in order {
        let track = &per_observer[o][t];
        let nearest = roster
            .iter_mut()
            .map(|p| (levenshtein(&p.name, &track.name), p))
            .filter(|(d, p)| *d <= roster_tolerance(&p.name))
            .min_by_key(|(d, _)| *d);
        match nearest {
            Some((_, pilot)) => pilot.members.push((o, t)),
            None if founds_pilot(track, min_samples) => roster.push(Pilot {
                name: track.name.clone(),
                members: vec![(o, t)],
            }),
            None => {} // OCR noise: too short to found a pilot, close to none
        }
    }
    roster.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    roster
}

/// Whether an unmatched track is real enough to be its own pilot: long enough, with enough
/// readable distances, and a name EVE could actually issue (3+ characters). Junk rows — e.g. a
/// lone `"j"` read off stray ink below the list — fail at least one of these.
fn founds_pilot(track: &Track, min_samples: usize) -> bool {
    let distances = track.samples.iter().filter(|s| s.distance_m.is_some()).count();
    track.name.chars().count() >= MIN_NAME_CHARS && distances >= min_samples
}

/// EVE character names are at least 3 characters long.
const MIN_NAME_CHARS: usize = 3;

/// Ship type for a pilot at time `t`: voted across their tracks by sample count, switching to
/// `Capsule` from the earliest pod any observer saw.
fn ship_type_at(per_observer: &[Vec<Track>], pilot: &Pilot, t: f64) -> String {
    let podded_at = pilot
        .members
        .iter()
        .filter_map(|&(o, i)| per_observer[o][i].capsule_events.first().copied())
        .fold(f64::INFINITY, f64::min);
    if t >= podded_at {
        return CAPSULE.to_string();
    }
    let mut votes: BTreeMap<&str, usize> = BTreeMap::new();
    for &(o, i) in &pilot.members {
        let tr = &per_observer[o][i];
        if let Some(ty) = tr.lost_ship.as_deref().or(tr.ship_type.as_deref()) {
            *votes.entry(ty).or_default() += tr.samples.len();
        }
    }
    votes
        .into_iter()
        .max_by_key(|&(_, n)| n)
        .map(|(ty, _)| ty.to_string())
        .unwrap_or_default()
}

/// One observer's series of one sample field (distance or speed) for a pilot: every member
/// track's samples from that observer, keyed by sample time (a splinter track only ever covers frames the main track missed — each
/// frame's row lands in exactly one track — so there is nothing to reconcile), with Hampel spike
/// flags.
fn observer_series(
    per_observer: &[Vec<Track>],
    pilot: &Pilot,
    observer: usize,
    field: impl Fn(&Sample) -> Option<f64>,
) -> BTreeMap<u64, (f64, bool)> {
    let mut by_t: BTreeMap<u64, f64> = BTreeMap::new();
    for &(o, i) in pilot.members.iter().filter(|m| m.0 == observer) {
        for s in &per_observer[o][i].samples {
            if let Some(d) = field(s) {
                by_t.entry(s.t.to_bits()).or_insert(d);
            }
        }
    }
    // f64 bit patterns sort like the values themselves for non-negative times.
    let values: Vec<Option<f64>> = by_t.values().map(|&d| Some(d)).collect();
    let flags = hampel_flags(&values, 5, 3.0);
    by_t.into_iter().zip(flags).map(|((t, d), f)| (t, (d, f))).collect()
}

/// One ring read in one frame, with its label when it was read.
struct TargetSample {
    t: f64,
    hp: Hp,
    label: Option<Label>,
}

/// Reads the scene's locked-target blocks frame by frame (`overview::targets`), and afterwards
/// works out whose HP each ring was.
struct TargetReader<'a> {
    rects: &'a [Rect],
    tesseract: &'a Path,
    /// Each block's geometry, once a frame with a ring in it calibrated it.
    geoms: Vec<Option<BlockGeometry>>,
    cache: LabelCache,
    /// Tesseract failed; rings are still read, but nothing can say whose they are.
    ocr_failed: bool,
    samples: Vec<TargetSample>,
}

impl<'a> TargetReader<'a> {
    fn new(rects: &'a [Rect], tesseract: &'a Path) -> TargetReader<'a> {
        TargetReader {
            rects,
            tesseract,
            geoms: vec![None; rects.len()],
            cache: LabelCache::new(rects.len()),
            ocr_failed: false,
            samples: Vec::new(),
        }
    }

    fn block(&self, frame: &videoin::Frame, b: usize) -> image::RgbImage {
        crop_scaled(&frame.image, self.rects[b], 1.0)
    }

    /// Read one batch of frames, in order: calibrate any block not yet calibrated, read every
    /// ring, and OCR the labels of each block whose rings changed.
    fn observe(&mut self, frames: &[videoin::Frame]) {
        for frame in frames {
            let todo: Vec<usize> = (0..self.rects.len()).filter(|&b| self.geoms[b].is_none()).collect();
            if todo.is_empty() {
                break;
            }
            let found: Vec<(usize, Option<BlockGeometry>)> =
                todo.par_iter().map(|&b| (b, BlockGeometry::calibrate(&self.block(frame, b)))).collect();
            for (b, geom) in found {
                if let Some(g) = geom {
                    println!(
                        "  targets {}: ring scale {:.3}, {} column(s) (from t={:.0}s)",
                        b + 1,
                        g.scale,
                        g.columns.len(),
                        frame.t
                    );
                    self.geoms[b] = Some(g);
                }
            }
        }

        let jobs: Vec<(usize, usize)> = (0..frames.len())
            .flat_map(|f| (0..self.rects.len()).filter(|&b| self.geoms[b].is_some()).map(move |b| (f, b)))
            .collect();
        let rings: Vec<Vec<Ring>> = jobs
            .par_iter()
            .map(|&(f, b)| read_rings(&self.block(&frames[f], b), self.geoms[b].as_ref().expect("calibrated")))
            .collect();
        let centers: Vec<Vec<(f32, f32)>> = rings.iter().map(|r| r.iter().map(|r| r.center).collect()).collect();

        // Which jobs' labels to read: jobs are frame-major, so this walks the frames in order.
        let mut reads = Vec::new();
        for (j, &(f, b)) in jobs.iter().enumerate() {
            if !self.ocr_failed && self.cache.needs_read(b, frames[f].t, &centers[j]) {
                self.cache.plan(b, frames[f].t, &centers[j]);
                reads.push(j);
            }
        }
        let ocr: Vec<(usize, usize)> = reads.iter().flat_map(|&j| (0..rings[j].len()).map(move |i| (j, i))).collect();
        let labels: Vec<Result<Label>> = ocr
            .par_iter()
            .map(|&(j, i)| {
                let (f, b) = jobs[j];
                let scale = self.geoms[b].as_ref().expect("calibrated").scale;
                match label_image(&self.block(&frames[f], b), &centers[j], i, scale) {
                    Some(img) => ocr_label(&img, self.tesseract),
                    None => Ok(Label::default()),
                }
            })
            .collect();
        let mut by_job: HashMap<usize, Vec<Label>> = HashMap::new();
        for (&(j, _), label) in ocr.iter().zip(labels) {
            let label = label.unwrap_or_else(|e| {
                if !self.ocr_failed {
                    eprintln!("  warning: can't read locked targets' labels, so their HP is left out: {e:#}");
                    self.ocr_failed = true;
                }
                Label::default()
            });
            by_job.entry(j).or_default().push(label);
        }

        for (j, &(f, b)) in jobs.iter().enumerate() {
            let t = frames[f].t;
            if let Some(labels) = by_job.remove(&j) {
                self.cache.store(b, &centers[j], labels);
            }
            let labels = self.cache.labels(b, &centers[j]);
            for (i, ring) in rings[j].iter().enumerate() {
                self.samples.push(TargetSample { t, hp: ring.hp, label: labels.map(|l| l[i].clone()) });
            }
        }
    }

    /// Each roster pilot's HP per tick (keyed by `t.to_bits()`): every ring whose label matches
    /// the pilot (`overview::targets::match_label`), the median per arc when several observers
    /// had them locked, then a 3-tick running median to drop one-tick misreads (combat text
    /// drawn across a ring).
    fn pilot_hp(&self, per_observer: &[Vec<Track>], roster: &[Pilot]) -> Vec<BTreeMap<u64, Hp>> {
        let mut per_pilot: Vec<BTreeMap<u64, Vec<Hp>>> = vec![BTreeMap::new(); roster.len()];
        if self.samples.is_empty() {
            return vec![BTreeMap::new(); roster.len()];
        }
        let ship_types = ShipTypes::builtin();
        let distances: Vec<BTreeMap<u64, Vec<f64>>> = roster.iter().map(|p| pilot_distances(per_observer, p)).collect();
        let mut candidates: HashMap<u64, Vec<(String, Vec<f64>)>> = HashMap::new();
        let (mut matched, mut unmatched) = (0usize, 0usize);
        for s in &self.samples {
            let Some(label) = &s.label else { continue };
            let key = s.t.to_bits();
            let at_t = candidates.entry(key).or_insert_with(|| {
                roster
                    .iter()
                    .zip(&distances)
                    .map(|(p, d)| (ship_type_at(per_observer, p, s.t), d.get(&key).cloned().unwrap_or_default()))
                    .collect()
            });
            let cands: Vec<Candidate> = roster
                .iter()
                .zip(at_t.iter())
                .map(|(p, (ty, d))| Candidate { name: &p.name, ship_type: ty, ranges_m: d.clone() })
                .collect();
            match match_label(label, &cands, &ship_types) {
                Some(i) => {
                    per_pilot[i].entry(key).or_default().push(s.hp);
                    matched += 1;
                }
                None => unmatched += 1,
            }
        }
        let pilots = per_pilot.iter().filter(|m| !m.is_empty()).count();
        println!(
            "  locked targets: HP for {pilots} pilot(s) from {matched} ring readings; {unmatched} readings matched no pilot, {} had no label",
            self.samples.iter().filter(|s| s.label.is_none()).count()
        );
        per_pilot.into_iter().map(|m| smooth_hp(&m)).collect()
    }
}

/// A pilot's distance from each observer that read one, per tick (keyed by `t.to_bits()`).
fn pilot_distances(per_observer: &[Vec<Track>], pilot: &Pilot) -> BTreeMap<u64, Vec<f64>> {
    let mut out: BTreeMap<u64, Vec<f64>> = BTreeMap::new();
    for &(o, i) in &pilot.members {
        for s in &per_observer[o][i].samples {
            if let Some(d) = s.distance_m {
                out.entry(s.t.to_bits()).or_default().push(d);
            }
        }
    }
    out
}

/// The median of each arc across `hps`.
fn median_hp(hps: &[Hp]) -> Hp {
    let m = |f: fn(&Hp) -> f32| median(hps.iter().map(|h| f(h) as f64).collect()).unwrap_or_default() as f32;
    Hp { shield: m(|h| h.shield), armor: m(|h| h.armor), hull: m(|h| h.hull) }
}

/// Per tick, the median of the readings, then of it and its neighbouring ticks.
fn smooth_hp(readings: &BTreeMap<u64, Vec<Hp>>) -> BTreeMap<u64, Hp> {
    let ticks: Vec<(u64, Hp)> = readings.iter().map(|(&t, v)| (t, median_hp(v))).collect();
    (0..ticks.len())
        .map(|k| {
            let window: Vec<Hp> = ticks[k.saturating_sub(1)..(k + 2).min(ticks.len())].iter().map(|&(_, h)| h).collect();
            (ticks[k].0, median_hp(&window))
        })
        .collect()
}

fn csv_field(s: &str) -> String {
    if s.contains([',', '"', '\n']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

/// One line per (tick, pilot) with a position fix. Speed is blank where no observer could read
/// it. Direction is blank where the ship is stationary or too few fixes surround the tick.
/// Shield, armor and hull (`hp`, per pilot) are blank where no observer had the pilot locked. With
/// `eve_origin` (the EVE time at `t` = 0), each line ends with its EVE time.
#[allow(clippy::too_many_arguments)]
fn positions_csv(
    per_observer: &[Vec<Track>],
    roster: &[Pilot],
    readings: &[PilotReadings],
    solved: &[Vec<Fix>],
    hp: &[BTreeMap<u64, Hp>],
    eve_origin: Option<DateTime<Utc>>,
    plane: &Plane,
    exits: &[Vec<Exit>],
) -> String {
    let plane_field = format!("{:.6} {:.6} {:.6} {:.0}", plane.n[0], plane.n[1], plane.n[2], plane.d);
    let mut rows: Vec<(f64, String)> = Vec::new();
    for ((((pilot, r), fixes), hp), exits) in roster.iter().zip(readings).zip(solved).zip(hp).zip(exits) {
        for (i, f) in fixes.iter().enumerate() {
            let mut line = format!(
                "{:.3},{},{},{:.0},{:.0},{:.0},",
                f.t,
                csv_field(&pilot.name),
                csv_field(&ship_type_at(per_observer, pilot, f.t)),
                f.p[0],
                f.p[1],
                f.p[2]
            );
            if let Some(v) = r.speed.get(&f.t.to_bits()) {
                let _ = write!(line, "{v}");
            }
            match direction(fixes, i, DIRECTION_HALF_WINDOW_S) {
                Some(d) => {
                    let _ = write!(line, ",{:.4},{:.4},{:.4}", d[0], d[1], d[2]);
                }
                None => line.push_str(",,,"),
            }
            let _ = write!(line, ",{:.0}", f.residual_m);
            match hp.get(&f.t.to_bits()) {
                Some(h) => {
                    let _ = write!(line, ",{:.3},{:.3},{:.3}", h.shield, h.armor, h.hull);
                }
                None => line.push_str(",,,"),
            }
            if let Some(origin) = eve_origin {
                let _ = write!(line, ",{}", eve_time(origin, f.t));
            }
            // The exit whose tail this fix is in (its fixes after the one nearest the plane).
            match exits.iter().enumerate().rev().find(|(_, e)| i > e.idx && i < e.end) {
                Some((k, e)) => {
                    let _ = write!(line, ",{},{},{plane_field}", e.turn.as_str(), k + 1);
                }
                None => line.push_str(",,,"),
            }
            line.push('\n');
            rows.push((f.t, line));
        }
    }
    // Tick-major like the old wide CSV; the sort is stable, so pilots stay in roster order.
    rows.sort_by(|a, b| a.0.total_cmp(&b.0));
    let mut out =
        String::from("t,pilot,ship_type,x_m,y_m,z_m,speed_mps,dir_x,dir_y,dir_z,residual_m,shield,armor,hull");
    out.push_str(if eve_origin.is_some() { ",eve_time" } else { "" });
    out.push_str(",plane_exit,plane_exit_id,plane\n");
    out.extend(rows.into_iter().map(|(_, l)| l));
    out
}

fn median(mut v: Vec<f64>) -> Option<f64> {
    v.sort_by(f64::total_cmp);
    v.get(v.len() / 2).copied()
}

fn print_summary(
    per_observer: &[Vec<Track>],
    roster: &[Pilot],
    readings: &[PilotReadings],
    solved: &[Vec<Fix>],
) {
    println!(
        "\n  {:<22} {:<20} {:>5} {:>20} {:>9} {:>17}",
        "pilot", "type", "fixes", "start km (x,y,z)", "resid m", "speed med/max m/s"
    );
    for ((pilot, r), fixes) in roster.iter().zip(readings).zip(solved) {
        let start = fixes
            .first()
            .map(|f| format!("{:.0},{:.0},{:.0}", f.p[0] / 1e3, f.p[1] / 1e3, f.p[2] / 1e3))
            .unwrap_or_else(|| "-".into());
        let resid = median(fixes.iter().map(|f| f.residual_m).collect())
            .map_or("-".into(), |v| format!("{v:.0}"));
        let speeds: Vec<f64> = r.speed.values().copied().collect();
        let max = speeds.iter().copied().fold(f64::NAN, f64::max);
        let speed = median(speeds).map_or("-".into(), |m| format!("{m:.0}/{max:.0}"));
        println!(
            "  {:<22} {:<20} {:>5} {:>20} {:>9} {:>17}",
            pilot.name,
            ship_type_at(per_observer, pilot, f64::NEG_INFINITY),
            fixes.len(),
            start,
            resid,
            speed
        );
    }
    let n_tracks: usize = per_observer.iter().map(Vec::len).sum();
    let n_kept: usize = roster.iter().map(|p| p.members.len()).sum();
    println!("  ({} of {n_tracks} per-observer tracks merged into {} pilots; rest dropped as noise)", n_kept, roster.len());
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utc(s: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(s).unwrap().into()
    }

    #[test]
    fn readings_add_the_observer_radius() {
        let mut r = PilotReadings { distances: vec![(1.5, [10_000.0, 20_000.0, 0.0])], speed: BTreeMap::new() };
        r.speed.insert(1.5f64.to_bits(), 300.0);
        let got = r.as_readings(250.0);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].t, 1.5);
        assert_eq!(got[0].d, [10_250.0, 20_250.0, 250.0]);
        assert_eq!(got[0].speed_mps, Some(300.0));
        assert_eq!(r.as_readings(0.0)[0].d, [10_000.0, 20_000.0, 0.0]);
    }

    #[test]
    fn observer_radius_is_bounded() {
        assert_eq!(parse_observer_radius("0"), Ok(0.0));
        assert_eq!(parse_observer_radius("250"), Ok(250.0));
        assert_eq!(parse_observer_radius("10000"), Ok(10_000.0));
        for bad in ["-1", "10000.5", "NaN", "inf", "big"] {
            assert!(parse_observer_radius(bad).is_err(), "{bad}");
        }
        let cli = Cli::try_parse_from(["scrim-positions", "--scene", "s.json", "v.mkv"]).unwrap();
        assert_eq!(cli.observer_radius_m, PALADIN_RADIUS_M);
    }

    #[test]
    fn eve_time_formats_ticks_across_midnight() {
        let origin = utc("2026-04-04T23:59:58Z");
        assert_eq!(eve_time(origin, 0.0), "2026-04-04T23:59:58.000Z");
        assert_eq!(eve_time(origin, 1.5), "2026-04-04T23:59:59.500Z");
        assert_eq!(eve_time(origin, 3.0), "2026-04-05T00:00:01.000Z");
    }

    #[test]
    fn t0_without_log_needs_a_date() {
        assert_eq!(parse_t0_utc("2026-04-04T17:43:55Z").unwrap(), utc("2026-04-04T17:43:55Z"));
        assert_eq!(parse_t0_utc("2026-04-04T17:43:55").unwrap(), utc("2026-04-04T17:43:55Z"));
        assert!(parse_t0_utc("17:43:55").is_err());
    }

    #[test]
    fn pair_selection() {
        use MatchSel::{All, One};
        assert!(pick_pairs(&[], None).is_err());
        assert!(pick_pairs(&[], Some(All)).is_err());
        assert_eq!(pick_pairs(&[(4, 38)], None).unwrap(), [(1, (4, 38))]);
        let two = [(8, 41), (59, 95)];
        assert!(pick_pairs(&two, None).is_err());
        assert_eq!(pick_pairs(&two, Some(One(2))).unwrap(), [(2, (59, 95))]);
        assert!(pick_pairs(&two, Some(One(0))).is_err());
        assert!(pick_pairs(&two, Some(One(3))).is_err());
        assert_eq!(pick_pairs(&two, Some(All)).unwrap(), [(1, (8, 41)), (2, (59, 95))]);
    }

    #[test]
    fn match_sel_parses() {
        assert_eq!("all".parse(), Ok(MatchSel::All));
        assert_eq!("ALL".parse(), Ok(MatchSel::All));
        assert_eq!("2".parse(), Ok(MatchSel::One(2)));
        assert!("0".parse::<MatchSel>().is_err());
        assert!("x".parse::<MatchSel>().is_err());
    }

    #[test]
    fn output_stem_drops_time() {
        assert_eq!(output_stem("2026-10-04 05-58-36"), "2026-10-04");
        assert_eq!(output_stem("2026-10-04_05-58-36 drac"), "2026-10-04 drac");
        assert_eq!(output_stem("match"), "match");
        assert_eq!(output_stem("2026-10-04 notatime"), "2026-10-04 notatime");
    }

    #[test]
    fn bridge_output_parses() {
        let b: BridgeOutput = serde_json::from_str(
            r#"{"t0_utc": "2026-04-04T17:52:22Z", "t0_source": "provided", "duration_s": 99.6,
                "pairs": [[8, 41], [59, 95]]}"#,
        )
        .unwrap();
        assert_eq!(b.pairs, vec![(8, 41), (59, 95)]);
        assert_eq!(b.t0_utc, "2026-04-04T17:52:22Z");
    }

    #[test]
    fn gamelog_trimmed_to_match() {
        let log = "------\r\n  Gamelog\r\n  Listener: Some Pilot\r\n  Session Started: 2026.04.04 17:00:00\r\n------\r\n\
            [ 2026.04.04 17:43:58 ] (combat) before\r\n\
            [ 2026.04.04 17:44:00 ] (combat) during\r\n\
            [ 2026.04.04 17:44:01 ] (notify) multi\r\nline\r\n\
            [ 2026.04.04 17:45:01 ] (combat) after\r\n";
        let t = |s| NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S").unwrap();
        let trimmed = trim_gamelog(log, t("2026-04-04 17:44:00"), t("2026-04-04 17:45:00")).unwrap();
        assert!(trimmed.starts_with("------\r\n  Gamelog\r\n  Listener: Some Pilot\r\n"));
        assert!(trimmed.contains("(combat) during\r\n"));
        assert!(trimmed.ends_with("(notify) multi\r\nline\r\n"));
        assert!(!trimmed.contains("before") && !trimmed.contains("after"));
        assert!(trim_gamelog("[ 2026.04.04 17:44:00 ] (combat) x\n", t("2026-04-04 17:44:00"),
            t("2026-04-04 17:45:00")).is_none());
    }

    #[test]
    fn scene_chat_rect_is_optional() {
        let without: Scene = serde_json::from_str(r#"{"panels": []}"#).unwrap();
        assert!(without.chat.is_none());
        let with: Scene =
            serde_json::from_str(r#"{"panels": [], "chat": {"x": 0, "y": 1200, "w": 1280, "h": 400}}"#)
                .unwrap();
        assert_eq!(with.chat.unwrap().y, 1200);
    }

    #[test]
    fn hp_takes_the_median_across_observers_and_ticks() {
        let hp = |s: f32| Hp { shield: s, armor: 1.0, hull: 1.0 };
        let mut readings: BTreeMap<u64, Vec<Hp>> = BTreeMap::new();
        for (t, v) in [(0.0f64, vec![hp(0.9)]), (1.0, vec![hp(0.9), hp(0.2), hp(0.8)]), (2.0, vec![hp(0.0)]), (3.0, vec![hp(0.8)])] {
            readings.insert(t.to_bits(), v);
        }
        let smooth = smooth_hp(&readings);
        let at = |t: f64| smooth[&t.to_bits()].shield;
        // Tick 1's median is 0.8; tick 2's lone 0.0 is a one-tick dip, smoothed away.
        assert_eq!([at(0.0), at(1.0), at(2.0), at(3.0)], [0.9, 0.8, 0.8, 0.8]);
    }

    #[test]
    fn scene_target_blocks_are_optional() {
        let without: Scene = serde_json::from_str(r#"{"panels": []}"#).unwrap();
        assert!(without.targets.is_empty());
        let with: Scene = serde_json::from_str(
            r#"{"panels": [], "targets": [{"x": 2560, "y": 928, "w": 576, "h": 672}]}"#,
        )
        .unwrap();
        assert_eq!(with.targets.len(), 1);
        assert_eq!(with.targets[0].x, 2560);
    }
}
