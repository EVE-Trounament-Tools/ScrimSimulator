//! A window for running `scrim-positions` on one recording: pick the video, the observer's Local
//! chat log, the output folder, optionally the gamelogs of the pilots in the match, and whether
//! to save the audio. Gamelogs with combat during the chat log's session are found in the Gamelogs
//! folder and added on their own whenever the chat log or folder changes. The choices are
//! remembered between sessions (eframe's app storage). The tool runs as a child process found
//! next to this executable (or on `PATH`), and its output is shown as it runs. A thumbnail of the
//! video with the scene's rectangles drawn on it shows whether the scene matches the recording.

#![cfg_attr(windows, windows_subsystem = "windows")]

use chrono::{DateTime, NaiveDateTime, TimeDelta, Utc};
use eframe::egui;
use image::RgbImage;
use overview::panel::Scene;
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{channel, Receiver, Sender};

const SETTINGS_KEY: &str = "settings";

/// Everything the user picks; persisted between sessions.
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(default)]
struct Settings {
    video: String,
    chat_log: String,
    out_dir: String,
    /// The run's subfolder of `out_dir`; not persisted, so each session starts at today's date.
    #[serde(skip)]
    run_name: String,
    /// Gamelogs to attach to the match.
    combat_log_files: Vec<String>,
    /// The Gamelogs folder: searched for logs matching the chat log, and where the combat log
    /// picker opens.
    combat_log_dir: String,
    /// The entries of `combat_log_files` found by searching `combat_log_dir`, replaced by the
    /// next search; the rest were picked by hand.
    found_logs: Vec<String>,
    extract_audio: bool,
    scene: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            video: String::new(),
            chat_log: String::new(),
            out_dir: String::new(),
            run_name: chrono::Local::now().format("%m-%d").to_string(),
            combat_log_files: Vec::new(),
            found_logs: Vec::new(),
            combat_log_dir: default_gamelogs().map(path_string).unwrap_or_default(),
            extract_audio: true,
            scene: default_scene().map(path_string).unwrap_or_default(),
        }
    }
}

fn path_string(p: PathBuf) -> String {
    p.to_string_lossy().into_owned()
}

/// EVE's gamelogs folder in the user's Documents, if it exists.
fn default_gamelogs() -> Option<PathBuf> {
    let home = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME"))?;
    let dir = Path::new(&home).join("Documents/EVE/logs/Gamelogs");
    dir.is_dir().then_some(dir)
}

/// The `Listener:` and `Session Started:` header values of a gamelog's first 4 KiB.
fn gamelog_header(path: &str) -> std::io::Result<(Option<String>, Option<String>)> {
    let mut head = Vec::new();
    std::fs::File::open(path)?.take(4096).read_to_end(&mut head)?;
    let head = String::from_utf8_lossy(&head);
    let field = |key: &str| {
        head.lines().find_map(|l| l.trim().strip_prefix(key).map(|v| v.trim().to_owned()))
    };
    Ok((field("Listener:"), field("Session Started:")))
}

/// How a gamelog is shown in the list: its character and session start (from the header), since
/// the file names are only a date and a character ID.
fn gamelog_label(path: &str) -> String {
    let file = Path::new(path).file_name().unwrap_or_default().to_string_lossy().into_owned();
    match gamelog_header(path) {
        Err(e) => format!("{file}  ({e})"),
        Ok((Some(who), Some(when))) => format!("{who}  ·  {when}  ·  {file}"),
        Ok((Some(who), None)) => format!("{who}  ·  {file}"),
        _ => format!("{file}  (not an EVE gamelog)"),
    }
}

/// The time at the start of a log line, `[ 2026.09.26 15:12:59 ] …` (chat log lines may start
/// with a BOM).
fn line_time(line: &str) -> Option<NaiveDateTime> {
    let s = line.trim_start_matches('\u{feff}').strip_prefix("[ ")?.get(..19)?;
    NaiveDateTime::parse_from_str(s, "%Y.%m.%d %H:%M:%S").ok()
}

/// A chat log's text: EVE writes them as UTF-16LE with a BOM.
fn decode_chat_log(bytes: &[u8]) -> String {
    match bytes.strip_prefix(&[0xFF, 0xFE]) {
        Some(rest) => {
            let units: Vec<u16> =
                rest.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
            String::from_utf16_lossy(&units)
        }
        None => String::from_utf8_lossy(bytes).into_owned(),
    }
}

/// The EVE times a chat log covers: its session start (header) to its last message.
fn chat_span(text: &str) -> Result<(NaiveDateTime, NaiveDateTime), String> {
    let start = text
        .lines()
        .find_map(|l| l.trim().strip_prefix("Session started:"))
        .and_then(|v| NaiveDateTime::parse_from_str(v.trim(), "%Y.%m.%d %H:%M:%S").ok())
        .ok_or("not an EVE chat log (no Session started header)")?;
    let end = text.lines().rev().find_map(line_time).unwrap_or(start);
    Ok((start, end))
}

/// Whether gamelog `text` (with a `Listener:` header) has combat between `start` and `end`.
fn has_combat(text: &str, start: NaiveDateTime, end: NaiveDateTime) -> bool {
    text.lines().any(|l| l.trim().starts_with("Listener:"))
        && text.lines().any(|l| {
            l.get(24..).is_some_and(|rest| rest.starts_with("(combat) "))
                && line_time(l).is_some_and(|t| t >= start && t <= end)
        })
}

/// The gamelogs in `dir` with combat between `start` and `end`, sorted. Cheap skips first, as
/// `scrim-positions` does: a log started after `end` (its name starts with the session's EVE start
/// time), or last written before `start`.
fn find_gamelogs(dir: &Path, start: NaiveDateTime, end: NaiveDateTime) -> std::io::Result<Vec<String>> {
    let mut found = Vec::new();
    for entry in std::fs::read_dir(dir)?.flatten() {
        let path = entry.path();
        if !path.extension().is_some_and(|e| e.eq_ignore_ascii_case("txt")) {
            continue;
        }
        let name = path.file_name().unwrap_or_default().to_string_lossy();
        if name.get(..15).and_then(|s| NaiveDateTime::parse_from_str(s, "%Y%m%d_%H%M%S").ok())
            .is_some_and(|t| t > end)
        {
            continue;
        }
        let since = start.and_utc() - TimeDelta::minutes(1);
        if entry.metadata().and_then(|m| m.modified()).is_ok_and(|m| DateTime::<Utc>::from(m) < since) {
            continue;
        }
        let Ok(bytes) = std::fs::read(&path) else { continue };
        if has_combat(&String::from_utf8_lossy(&bytes), start, end) {
            found.push(path_string(path));
        }
    }
    found.sort();
    Ok(found)
}

/// What a search of the Gamelogs folder found: the logs, and the chat log's span.
type Found = Result<(Vec<String>, NaiveDateTime, NaiveDateTime), String>;

/// Search `dir` for the gamelogs matching chat log `chat`.
fn search(chat: &Path, dir: &Path) -> Found {
    let bytes = std::fs::read(chat).map_err(|e| format!("reading the chat log: {e}"))?;
    let (start, end) = chat_span(&decode_chat_log(&bytes))?;
    let logs = find_gamelogs(dir, start, end).map_err(|e| format!("reading {}: {e}", dir.display()))?;
    Ok((logs, start, end))
}

/// `scene.json` next to this executable (as in the release zip), else the source tree's.
fn default_scene() -> Option<PathBuf> {
    let beside = std::env::current_exe().ok()?.parent()?.join("scene.json");
    let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs/obs/scene.json");
    [beside, source].into_iter().find(|p| p.is_file()).map(|p| p.canonicalize().unwrap_or(p))
}

/// Width of the decoded thumbnail; the frame is scaled down to it before becoming a texture.
const THUMB_WIDTH: u32 = 480;

/// A frame grabbed for the thumbnail: the full frame's size, and the frame scaled down.
type Thumb = Result<([u32; 2], RgbImage), String>;

/// A frame of `video` a few seconds in (the first frame may still be black), else its first.
fn grab_thumbnail(video: &Path) -> Thumb {
    let first = |start: f64| -> Result<Option<videoin::Frame>, String> {
        let mut dec = videoin::Decoder::open_range(video, None, start, Some(start + 0.5))
            .map_err(|e| format!("{e:#}"))?;
        dec.next_frame().map_err(|e| format!("{e:#}"))
    };
    let frame = match first(5.0)? {
        Some(f) => f,
        None => first(0.0)?.ok_or("the video has no frames")?,
    };
    let (w, h) = frame.image.dimensions();
    let th = (THUMB_WIDTH as u64 * h as u64 / w.max(1) as u64).max(1) as u32;
    Ok(([w, h], image::imageops::thumbnail(&frame.image, THUMB_WIDTH, th)))
}

/// What the thumbnail outlines: each of `scene`'s rectangles with its label, scaled by `k` from
/// frame pixels to points relative to the image's corner, and whether it reaches past a frame
/// of size `frame` (a scene made for another layout or resolution).
fn overlay_rects(scene: &Scene, frame: [u32; 2], k: f32) -> Vec<(String, egui::Rect, bool)> {
    let panels = scene.panels.iter().map(|p| (p.name.clone(), p.rect));
    let chat = scene.chat.iter().map(|r| ("chat".to_owned(), *r));
    let targets = scene.targets.iter().enumerate().map(|(i, r)| (format!("targets {}", i + 1), *r));
    panels
        .chain(chat)
        .chain(targets)
        .map(|(label, r)| {
            let rect = egui::Rect::from_min_size(
                egui::pos2(r.x as f32 * k, r.y as f32 * k),
                egui::vec2(r.w as f32 * k, r.h as f32 * k),
            );
            let outside = r.x as u64 + r.w as u64 > frame[0] as u64 || r.y as u64 + r.h as u64 > frame[1] as u64;
            (label, rect, outside)
        })
        .collect()
}

/// The `scrim-positions` executable next to this one, else whatever `PATH` finds.
fn scrim_positions() -> PathBuf {
    let name = format!("scrim-positions{}", std::env::consts::EXE_SUFFIX);
    std::env::current_exe()
        .ok()
        .and_then(|exe| Some(exe.parent()?.join(&name)))
        .filter(|p| p.is_file())
        .unwrap_or_else(|| PathBuf::from(name))
}

/// A piece of the child's output: a finished line, or a `\r`-terminated progress line that the
/// next piece replaces.
enum Output {
    Line(String),
    Progress(String),
}

/// Forward `pipe` to `tx` split into lines, waking the UI for each.
fn forward(mut pipe: impl Read + Send + 'static, tx: Sender<Output>, ctx: egui::Context) {
    std::thread::spawn(move || {
        let mut buf = [0u8; 4096];
        let mut line = Vec::new();
        while let Ok(n @ 1..) = pipe.read(&mut buf) {
            for &b in &buf[..n] {
                if b != b'\n' && b != b'\r' {
                    line.push(b);
                    continue;
                }
                let text = String::from_utf8_lossy(&line).into_owned();
                line.clear();
                let msg = if b == b'\n' { Output::Line(text) } else { Output::Progress(text) };
                if tx.send(msg).is_err() {
                    return;
                }
            }
            ctx.request_repaint();
        }
        if !line.is_empty() {
            let _ = tx.send(Output::Line(String::from_utf8_lossy(&line).into_owned()));
        }
        ctx.request_repaint();
    });
}

struct Run {
    child: Child,
    output: Receiver<Output>,
}

struct App {
    settings: Settings,
    run: Option<Run>,
    log: Vec<String>,
    /// The last log line is a progress line, replaced by the next output.
    progress: bool,
    /// `gamelog_label` of each combat log, read once.
    labels: HashMap<String, String>,
    /// The Gamelogs folder search in progress.
    scan: Option<Receiver<Found>>,
    /// The (chat log, folder) last searched; another search starts when they change.
    scanned: Option<(String, String)>,
    /// What the last search found, or why it failed.
    scan_status: String,
    /// The thumbnail frame being grabbed.
    thumb_grab: Option<Receiver<Thumb>>,
    /// The video last grabbed from; another grab starts when it changes.
    thumbed: Option<String>,
    /// The thumbnail and the full frame's size, or why there is none.
    thumb: Option<Result<(egui::TextureHandle, [u32; 2]), String>>,
    /// The scene file last loaded for the overlay, and what it held.
    scene: Option<(String, Result<Scene, String>)>,
}

impl App {
    fn new(cc: &eframe::CreationContext) -> Self {
        let settings = cc
            .storage
            .and_then(|s| eframe::get_value(s, SETTINGS_KEY))
            .unwrap_or_default();
        Self {
            settings,
            run: None,
            log: Vec::new(),
            progress: false,
            labels: HashMap::new(),
            scan: None,
            scanned: None,
            scan_status: String::new(),
            thumb_grab: None,
            thumbed: None,
            thumb: None,
            scene: None,
        }
    }

    /// Start grabbing a thumbnail frame when the video changed since the last grab (and exists);
    /// take in a grab that finished. Reload the scene when its path changed.
    fn poll_thumbnail(&mut self, ctx: &egui::Context) {
        let video = self.settings.video.trim().to_owned();
        if self.thumbed.as_ref() != Some(&video) {
            self.thumbed = Some(video.clone());
            self.thumb = None;
            // A newer grab replaces one still running; its result is dropped.
            self.thumb_grab = None;
            if Path::new(&video).is_file() {
                let (tx, rx) = channel();
                let ctx = ctx.clone();
                std::thread::spawn(move || {
                    let _ = tx.send(grab_thumbnail(Path::new(&video)));
                    ctx.request_repaint();
                });
                self.thumb_grab = Some(rx);
            }
        }
        if let Some(thumb) = self.thumb_grab.as_ref().and_then(|rx| rx.try_recv().ok()) {
            self.thumb_grab = None;
            self.thumb = Some(thumb.map(|(frame, img)| {
                let size = [img.width() as usize, img.height() as usize];
                let image = egui::ColorImage::from_rgb(size, img.as_raw());
                (ctx.load_texture("thumbnail", image, Default::default()), frame)
            }));
        }

        let scene = self.settings.scene.trim();
        if self.scene.as_ref().is_none_or(|(p, _)| p != scene) {
            let loaded = Scene::load(scene).map_err(|e| format!("scene: {e}"));
            self.scene = Some((scene.to_owned(), loaded));
        }
    }

    /// Start searching the Gamelogs folder when the chat log or folder changed since the last
    /// search (and both exist); take in the result of a search that finished.
    fn poll_scan(&mut self, ctx: &egui::Context) {
        let s = &self.settings;
        let key = (s.chat_log.trim().to_owned(), s.combat_log_dir.trim().to_owned());
        let ready = Path::new(&key.0).is_file() && Path::new(&key.1).is_dir();
        if ready && self.scanned.as_ref() != Some(&key) && self.run.is_none() {
            let (tx, rx) = channel();
            let (chat, dir) = (PathBuf::from(&key.0), PathBuf::from(&key.1));
            let ctx = ctx.clone();
            std::thread::spawn(move || {
                let _ = tx.send(search(&chat, &dir));
                ctx.request_repaint();
            });
            // A newer search replaces one still running; its result is dropped.
            self.scan = Some(rx);
            self.scanned = Some(key);
        }
        let Some(found) = self.scan.as_ref().and_then(|rx| rx.try_recv().ok()) else { return };
        self.scan = None;
        match found {
            Ok((logs, start, end)) => {
                let added = self.add_found(logs);
                self.scan_status = format!(
                    "found {added} gamelog(s) with combat between {} and {}",
                    start.format("%Y.%m.%d %H:%M"),
                    end.format("%H:%M"),
                );
            }
            Err(e) => self.scan_status = e,
        }
    }

    /// Replace the previously found logs with `logs`, skipping copies of a log already in the list
    /// (same character and session start, e.g. picked by hand from another folder); how many
    /// were added.
    fn add_found(&mut self, logs: Vec<String>) -> usize {
        let s = &mut self.settings;
        s.combat_log_files.retain(|p| !s.found_logs.contains(p));
        s.found_logs.clear();
        let mut seen: Vec<_> =
            s.combat_log_files.iter().filter_map(|p| gamelog_header(p).ok()).collect();
        for log in logs {
            if s.combat_log_files.contains(&log) {
                continue;
            }
            let header = gamelog_header(&log).ok();
            if let Some(h) = header.as_ref().filter(|h| h.0.is_some() && h.1.is_some()) {
                if seen.contains(h) {
                    continue;
                }
                seen.push(h.clone());
            }
            s.combat_log_files.push(log.clone());
            s.found_logs.push(log);
        }
        s.found_logs.len()
    }

    fn push(&mut self, out: Output) {
        let (text, progress) = match out {
            Output::Line(t) => (t, false),
            Output::Progress(t) => (t, true),
        };
        // `\r\n` arrives as an empty line after the progress line it ends.
        if self.progress && text.is_empty() && !progress {
            self.progress = false;
            return;
        }
        if self.progress {
            self.log.pop();
        }
        self.log.push(text);
        self.progress = progress;
    }

    /// What's missing before a run can start, if anything.
    fn missing(&self) -> Option<&'static str> {
        let s = &self.settings;
        if s.video.trim().is_empty() {
            Some("Pick a video.")
        } else if s.out_dir.trim().is_empty() {
            Some("Pick an output folder.")
        } else if s.run_name.trim().is_empty() {
            Some("Name the run folder.")
        } else if s.scene.trim().is_empty() {
            Some("Pick a scene file.")
        } else {
            None
        }
    }

    fn start(&mut self, ctx: &egui::Context) {
        let s = &self.settings;
        let exe = scrim_positions();
        let mut cmd = Command::new(&exe);
        cmd.arg("--scene").arg(s.scene.trim()).arg("--out").arg(Path::new(s.out_dir.trim()).join(s.run_name.trim()));
        if !s.chat_log.trim().is_empty() {
            // Every CD -> WF/GF in the video, each into its own `<video>_NN.*` outputs.
            cmd.arg("--chat-log").arg(s.chat_log.trim()).args(["--match", "all"]);
        }
        if !s.extract_audio {
            cmd.arg("--no-audio");
        }
        for log in &s.combat_log_files {
            cmd.arg("--combat-log").arg(log);
        }
        cmd.arg(s.video.trim()).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            cmd.creation_flags(CREATE_NO_WINDOW);
        }

        self.log.clear();
        self.progress = false;
        self.log.push(format!("$ {cmd:?}"));
        match cmd.spawn() {
            Ok(mut child) => {
                let (tx, rx) = channel();
                forward(child.stdout.take().unwrap(), tx.clone(), ctx.clone());
                forward(child.stderr.take().unwrap(), tx, ctx.clone());
                self.run = Some(Run { child, output: rx });
            }
            Err(e) => self.log.push(format!("Cannot start {}: {e}", exe.display())),
        }
    }

    /// Drain the running child's output and notice when it exits.
    fn poll(&mut self) {
        let Some(run) = &mut self.run else { return };
        let pending: Vec<Output> = run.output.try_iter().collect();
        let status = run.child.try_wait();
        for out in pending {
            self.push(out);
        }
        let done = match status {
            Ok(Some(status)) if status.success() => Some("Done.".to_owned()),
            Ok(Some(status)) => Some(format!("Failed ({status}).")),
            Ok(None) => None,
            Err(e) => Some(format!("Lost the process: {e}")),
        };
        if let Some(msg) = done {
            // Output written just before exit may still be in the pipe threads.
            if let Some(run) = self.run.take() {
                for out in run.output.iter() {
                    self.push(out);
                }
            }
            self.push(Output::Line(msg));
        }
    }
}

/// A labelled path field with a "Browse…" button that opens `pick`.
fn path_row(
    ui: &mut egui::Ui,
    label: &str,
    value: &mut String,
    hint: &str,
    pick: impl FnOnce(rfd::FileDialog) -> Option<PathBuf>,
) {
    ui.label(label);
    ui.horizontal(|ui| {
        let browse = ui.button("Browse…");
        let field = egui::TextEdit::singleline(value).hint_text(hint);
        ui.add_sized([ui.available_width(), ui.spacing().interact_size.y], field);
        if browse.clicked() {
            let mut dialog = rfd::FileDialog::new();
            if let Some(dir) = Path::new(value.trim()).parent().filter(|d| d.is_dir()) {
                dialog = dialog.set_directory(dir);
            }
            if Path::new(value.trim()).is_dir() {
                dialog = dialog.set_directory(value.trim());
            }
            if let Some(p) = pick(dialog) {
                *value = path_string(p);
            }
        }
    });
    ui.end_row();
}

/// The combat logs list: one row per gamelog (its character, session start and file name) with a
/// remove button, and buttons to add more or clear them.
fn combat_logs_ui(ui: &mut egui::Ui, app: &mut App) {
    let (s, labels) = (&mut app.settings, &mut app.labels);
    ui.horizontal(|ui| {
        ui.label("Combat logs");
        let can_scan = Path::new(s.chat_log.trim()).is_file() && Path::new(s.combat_log_dir.trim()).is_dir();
        let rescan = ui.add_enabled(can_scan, egui::Button::new("Rescan"));
        if rescan.on_hover_text("Search the Gamelogs folder for logs with combat during the chat log").clicked() {
            app.scanned = None;
        }
        if ui.button("Add logs…").clicked() {
            let mut dialog = rfd::FileDialog::new()
                .set_title("Gamelogs of the pilots in the match")
                .add_filter("Gamelog", &["txt"]);
            if Path::new(&s.combat_log_dir).is_dir() {
                dialog = dialog.set_directory(&s.combat_log_dir);
            }
            for p in dialog.pick_files().unwrap_or_default() {
                let p = path_string(p);
                if !s.combat_log_files.contains(&p) {
                    s.combat_log_files.push(p);
                }
            }
        }
        if ui.add_enabled(!s.combat_log_files.is_empty(), egui::Button::new("Clear")).clicked() {
            s.combat_log_files.clear();
            s.found_logs.clear();
        }
        if app.scan.is_some() {
            ui.spinner();
            ui.weak("searching the Gamelogs folder…");
        } else if !app.scan_status.is_empty() {
            ui.weak(&app.scan_status);
        } else {
            ui.weak("optional: each pilot's gamelog; ones with no combat in the match are skipped");
        }
    });
    let mut remove = None;
    egui::ScrollArea::vertical().id_salt("combat_logs").max_height(120.0).show(ui, |ui| {
        for (i, path) in s.combat_log_files.iter().enumerate() {
            ui.horizontal(|ui| {
                if ui.small_button("🗙").on_hover_text("Remove").clicked() {
                    remove = Some(i);
                }
                let label = labels.entry(path.clone()).or_insert_with(|| gamelog_label(path));
                ui.label(label.as_str()).on_hover_text(path);
            });
        }
    });
    if let Some(i) = remove {
        let p = s.combat_log_files.remove(i);
        s.found_logs.retain(|f| *f != p);
    }
}

/// The video's thumbnail with the scene's rectangles outlined on it; hovering shows it larger.
fn thumbnail_ui(ui: &mut egui::Ui, app: &App) {
    let (tex, frame) = match &app.thumb {
        Some(Ok((tex, frame))) => (tex, *frame),
        Some(Err(e)) => {
            ui.colored_label(ui.visuals().warn_fg_color, format!("No preview: {e}"));
            return;
        }
        None if app.thumb_grab.is_some() => {
            ui.horizontal(|ui| {
                ui.spinner();
                ui.weak("reading a frame…");
            });
            return;
        }
        None => {
            ui.weak("Pick a video to preview it with the scene.");
            return;
        }
    };
    let scene = app.scene.as_ref().filter(|(p, _)| !p.is_empty()).map(|(_, s)| s);
    let draw = |ui: &mut egui::Ui, width: f32| -> (egui::Response, bool) {
        let size = egui::vec2(width, width * frame[1] as f32 / frame[0].max(1) as f32);
        let response = ui.add(egui::Image::new(tex).fit_to_exact_size(size));
        let Some(Ok(scene)) = scene else { return (response, false) };
        let at = response.rect;
        let painter = ui.painter_at(at);
        let mut outside_any = false;
        for (i, (label, rect, outside)) in overlay_rects(scene, frame, at.width() / frame[0] as f32).into_iter().enumerate() {
            let color = if outside { ui.visuals().error_fg_color } else { OVERLAY_COLORS[i % OVERLAY_COLORS.len()] };
            let rect = rect.translate(at.min.to_vec2());
            painter.rect_stroke(rect, 0.0, egui::Stroke::new(1.5, color), egui::StrokeKind::Inside);
            painter.text(rect.min + egui::vec2(3.0, 2.0), egui::Align2::LEFT_TOP, label, egui::FontId::proportional(11.0), color);
            outside_any |= outside;
        }
        (response, outside_any)
    };
    let (response, outside) = draw(ui, ui.available_width());
    response.on_hover_ui(|ui| {
        draw(ui, 960.0);
    });
    ui.weak(format!("{} × {}", frame[0], frame[1]));
    match scene {
        Some(Err(e)) => {
            ui.colored_label(ui.visuals().warn_fg_color, e);
        }
        Some(Ok(_)) if outside => {
            ui.colored_label(ui.visuals().warn_fg_color, "The scene reaches past the frame: is it for this recording?");
        }
        _ => {}
    }
}

/// Outline colours of the scene's rectangles, in order.
const OVERLAY_COLORS: [egui::Color32; 6] = [
    egui::Color32::from_rgb(0x4f, 0xc3, 0xf7),
    egui::Color32::from_rgb(0xff, 0xb7, 0x4d),
    egui::Color32::from_rgb(0x81, 0xc7, 0x84),
    egui::Color32::from_rgb(0xf0, 0x62, 0x92),
    egui::Color32::from_rgb(0xba, 0x68, 0xc8),
    egui::Color32::from_rgb(0xff, 0xf1, 0x76),
];

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.poll();
        self.poll_scan(ctx);
        self.poll_thumbnail(ctx);
        let running = self.run.is_some();

        egui::TopBottomPanel::top("settings").show(ctx, |ui| {
            egui::SidePanel::right("thumbnail").resizable(true).default_width(320.0).show_inside(ui, |ui| {
                ui.add_space(6.0);
                thumbnail_ui(ui, self);
            });
            ui.add_space(6.0);
            ui.add_enabled_ui(!running, |ui| {
                let s = &mut self.settings;
                egui::Grid::new("paths").num_columns(2).spacing([8.0, 6.0]).show(ui, |ui| {
                    path_row(ui, "Video", &mut s.video, "recorded match (.mkv, .mp4, …)", |d| {
                        d.add_filter("Video", &["mkv", "mp4", "mov", "webm", "flv", "avi"])
                            .add_filter("All files", &["*"])
                            .pick_file()
                    });
                    path_row(ui, "Chat log", &mut s.chat_log, "optional: Local chat log, finds the matches (each processed) and EVE times", |d| {
                        d.add_filter("Chat log", &["txt"]).pick_file()
                    });
                    path_row(ui, "Gamelogs folder", &mut s.combat_log_dir, "EVE's Gamelogs folder: searched for logs with combat during the chat log", |d| {
                        d.pick_folder()
                    });
                    path_row(ui, "Output folder", &mut s.out_dir, "parent folder: each run goes in its own subfolder", |d| {
                        d.pick_folder()
                    });
                    ui.label("Run folder");
                    ui.horizontal(|ui| {
                        let field = egui::TextEdit::singleline(&mut s.run_name).hint_text("subfolder for this run's CSV (and audio, logs)");
                        ui.add_sized([160.0, ui.spacing().interact_size.y], field);
                        if !s.out_dir.trim().is_empty() && !s.run_name.trim().is_empty() {
                            let full = Path::new(s.out_dir.trim()).join(s.run_name.trim());
                            ui.weak(full.display().to_string());
                        }
                    });
                    ui.end_row();
                    path_row(ui, "Scene", &mut s.scene, "scene.json: where each overview is in the frame", |d| {
                        d.add_filter("Scene", &["json"]).pick_file()
                    });
                    ui.label("");
                    ui.checkbox(&mut s.extract_audio, "Extract audio (<video>.mp3 next to the CSV)");
                    ui.end_row();
                });
            });
            ui.add_enabled_ui(!running, |ui| {
                ui.add_space(4.0);
                combat_logs_ui(ui, self);
                let s = &self.settings;
                if !s.combat_log_files.is_empty() && s.chat_log.trim().is_empty() {
                    ui.colored_label(
                        ui.visuals().warn_fg_color,
                        "Combat logs need EVE times, which come from the chat log.",
                    );
                }
            });
            ui.add_space(4.0);
            ui.horizontal(|ui| {
                if running {
                    ui.spinner();
                    if ui.button("Cancel").clicked() {
                        if let Some(run) = &mut self.run {
                            let _ = run.child.kill();
                        }
                    }
                } else {
                    let missing = self.missing();
                    let run = ui.add_enabled(missing.is_none(), egui::Button::new("Run"));
                    if let Some(why) = missing {
                        ui.label(why);
                    }
                    if run.clicked() {
                        self.start(ctx);
                    }
                }
            });
            ui.add_space(6.0);
        });

        egui::CentralPanel::default().show(ctx, |ui| {
            egui::ScrollArea::both().stick_to_bottom(true).auto_shrink(false).show(ui, |ui| {
                for line in &self.log {
                    ui.label(egui::RichText::new(line).monospace());
                }
            });
        });
    }

    fn save(&mut self, storage: &mut dyn eframe::Storage) {
        eframe::set_value(storage, SETTINGS_KEY, &self.settings);
    }
}

impl Drop for App {
    /// Closing the window stops a run in progress.
    fn drop(&mut self) {
        if let Some(run) = &mut self.run {
            let _ = run.child.kill();
        }
    }
}

fn main() -> eframe::Result {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Scrim Positions")
            .with_inner_size([1140.0, 620.0]),
        ..Default::default()
    };
    eframe::run_native(
        "scrim-positions-gui",
        options,
        Box::new(|cc| Ok(Box::new(App::new(cc)))),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(s: &str) -> NaiveDateTime {
        NaiveDateTime::parse_from_str(s, "%Y.%m.%d %H:%M:%S").unwrap()
    }

    fn gamelog(listener: &str, lines: &[&str]) -> String {
        let mut out = format!(
            "------\r\n  Gamelog\r\n  Listener: {listener}\r\n  Session Started: 2026.09.26 12:00:00\r\n------\r\n"
        );
        for l in lines {
            out += l;
            out += "\r\n";
        }
        out
    }

    #[test]
    fn chat_span_of_utf16_log() {
        let text = "\u{feff}\r\n  Channel Name:    Local\r\n  Session started: 2026.09.26 12:59:55\r\n\
            \u{feff}[ 2026.09.26 13:00:01 ] A > hi\r\n\u{feff}[ 2026.09.26 15:13:01 ] B > o7\r\n";
        let mut bytes = vec![0xFF, 0xFE];
        bytes.extend(text.trim_start_matches('\u{feff}').encode_utf16().flat_map(u16::to_le_bytes));
        let span = chat_span(&decode_chat_log(&bytes)).unwrap();
        assert_eq!(span, (t("2026.09.26 12:59:55"), t("2026.09.26 15:13:01")));
        assert!(chat_span("not a chat log").is_err());
    }

    #[test]
    fn overlay_scales_scene_rects() {
        let scene: Scene = serde_json::from_str(
            r#"{ "panels": [ { "name": "A", "rect": { "x": 0, "y": 0, "w": 100, "h": 50 } } ],
                 "chat": { "x": 100, "y": 0, "w": 100, "h": 100 },
                 "targets": [ { "x": 150, "y": 50, "w": 60, "h": 50 } ] }"#,
        )
        .unwrap();
        let rects = overlay_rects(&scene, [200, 100], 0.5);
        let labels: Vec<_> = rects.iter().map(|r| r.0.as_str()).collect();
        assert_eq!(labels, ["A", "chat", "targets 1"]);
        assert_eq!(rects[1].1, egui::Rect::from_min_size(egui::pos2(50.0, 0.0), egui::vec2(50.0, 50.0)));
        assert_eq!(rects.iter().map(|r| r.2).collect::<Vec<_>>(), [false, false, true]);
    }

    #[test]
    fn grabs_thumbnail_of_short_clip() {
        let clip = Path::new(env!("CARGO_MANIFEST_DIR")).join("../overview/tests/fixtures/overview-sample.mkv");
        let (frame, img) = grab_thumbnail(&clip).unwrap();
        assert_eq!(img.width(), THUMB_WIDTH);
        assert_eq!(img.height(), THUMB_WIDTH * frame[1] / frame[0]);
        assert!(grab_thumbnail(Path::new("no-such-video.mkv")).is_err());
    }

    #[test]
    fn finds_logs_with_combat_in_span() {
        let dir = std::env::temp_dir().join(format!("positions-gui-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let combat = |time: &str| format!("[ {time} ] (combat) 100 to B[X](Loki) - Gun - Hits");
        let files = [
            ("20260926_120000_1.txt", gamelog("A", &[&combat("2026.09.26 13:30:00")])),
            ("20260926_120000_2.txt", gamelog("B", &[&combat("2026.09.26 11:30:00")])),
            ("20260926_120000_3.txt", gamelog("C", &["[ 2026.09.26 13:30:00 ] (notify) Docking"])),
            ("20260926_120000_4.txt", combat("2026.09.26 13:30:00")),
            ("20260926_150000_5.txt", gamelog("E", &[&combat("2026.09.26 15:30:00")])),
            ("notes.md", gamelog("F", &[&combat("2026.09.26 13:30:00")])),
        ];
        for (name, text) in &files {
            std::fs::write(dir.join(name), text).unwrap();
        }
        let found = find_gamelogs(&dir, t("2026.09.26 13:00:00"), t("2026.09.26 14:00:00")).unwrap();
        assert_eq!(found, [path_string(dir.join("20260926_120000_1.txt"))]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
