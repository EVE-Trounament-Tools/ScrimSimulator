//! Locked-target HP rings (DESIGN.md S4.6). Every locked target's bracket draws its shield, armor
//! and hull as three concentric segmented arcs (shield outermost), white where HP remains and red
//! where it's gone, with the pilot's name, corp, ship type and range written underneath. The OBS
//! scene records blocks of these brackets (`Scene::targets`).
//!
//! Reading a ring is pixel geometry, not OCR: each arc is sampled at [`ARC_SAMPLES`] points along
//! its span (one per percent) and the remaining fraction is the share of white samples among the
//! white and red ones. Samples that are neither (a segment gap, combat text drawn over the ring)
//! don't count either way.
//!
//! Where the brackets are isn't fixed: the client lays locked targets out in rows whose height
//! depends on how many lines the labels above take (a long name wraps), and each block may come
//! from a client at another UI scale or be scaled down by OBS. So each block is calibrated once
//! ([`BlockGeometry::calibrate`]: ring scale and column positions), and the rings are found again
//! in every frame by scanning each column ([`detect_rings`]).
//!
//! Labels say whose ring it is. They're set in the client's proportional label font, which the
//! overview glyph templates read poorly, so they go to Tesseract ([`ocr_label`]) — and only when
//! a block's rings change, since that's the only time its labels can ([`LabelCache`]). Each label
//! is then matched to a roster pilot by name, with ship type and range as tie-breakers
//! ([`match_label`]).

use crate::layout::Rect;
use crate::panel::crop_scaled;
use crate::ship_types::ShipTypes;
use crate::util::levenshtein;
use crate::value::parse_distance;
use anyhow::{bail, Context, Result};
use image::RgbImage;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

/// Samples per arc: each one is 1 % of the arc.
pub const ARC_SAMPLES: usize = 100;

/// Remaining HP of one locked target, each `0.0..=1.0`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Hp {
    pub shield: f32,
    pub armor: f32,
    pub hull: f32,
}

/// Arc radii (shield, armor, hull) at ring scale 1: the template's clients at UI scale 1.75.
pub const REF_RADII: [f32; 3] = [62.0, 54.0, 46.0];
/// Half the arcs' radial thickness at scale 1, searched either side of each radius.
const REF_HALF_THICKNESS: f32 = 2.0;
/// Where the arcs start, in screen degrees (0 = right, 90 = down): bottom left, running clockwise
/// over the top to bottom right, leaving a gap at the bottom.
const ARC_START_DEG: f32 = 138.0;
const ARC_SPAN_DEG: f32 = 267.0;
/// Horizontal distance between neighbouring brackets' centers at scale 1.
const REF_PITCH_X: f32 = 180.0;
/// Rows are at least this far apart at scale 1 (a bracket with one-line labels is ~300 tall).
const REF_MIN_ROW_GAP: f32 = 250.0;
/// Where the label starts below the ring's center at scale 1, and how far it can run.
const REF_LABEL_TOP: f32 = 84.0;
const REF_LABEL_MAX: f32 = 200.0;
/// Clearance above the next ring's center that a label can't run into, at scale 1.
const REF_RING_TOP: f32 = 70.0;

/// Ring scales tried by [`BlockGeometry::calibrate`].
const SCALE_SWEEP: (f32, f32, f32) = (0.6, 1.5, 0.02);
/// [`ring_score`] a spot needs to count as a ring.
const MIN_RING_SCORE: f32 = 0.45;
/// Fewer white-or-red samples than this on all three arcs together means there's no ring.
const MIN_READ_SAMPLES: usize = 150;

/// What one pixel of an arc shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Px {
    /// White: HP still there.
    Filled,
    /// Red: HP lost.
    Lost,
    Other,
}

/// Light gray to white is HP left and saturated red, however dark, is HP lost. The ring's
/// brightness varies from frame to frame (white can be as dim as ~95 gray), and the dark gaps
/// between segments stay below that.
fn classify(p: [u8; 3]) -> Px {
    let [r, g, b] = p.map(i32::from);
    let (lo, hi) = (r.min(g).min(b), r.max(g).max(b));
    if lo >= 95 && hi - lo <= 40 {
        Px::Filled
    } else if r >= 60 && r >= 2 * g && r >= 2 * b {
        Px::Lost
    } else {
        Px::Other
    }
}

/// The pixel class at `(x, y)` of `img`, `Other` outside it.
fn class_at(img: &RgbImage, x: f32, y: f32) -> Px {
    let (x, y) = (x.round(), y.round());
    if x < 0.0 || y < 0.0 || x >= img.width() as f32 || y >= img.height() as f32 {
        return Px::Other;
    }
    classify(img.get_pixel(x as u32, y as u32).0)
}

/// What an arc shows at angle `deg`: the majority of white and red pixels across the arc's
/// thickness, `Other` if neither is there.
fn arc_sample(img: &RgbImage, cx: f32, cy: f32, radius: f32, half: f32, deg: f32) -> Px {
    let (s, c) = deg.to_radians().sin_cos();
    let (mut filled, mut lost) = (0, 0);
    let steps = (half.ceil() as i32).max(1);
    for i in -steps..=steps {
        let r = radius + half * i as f32 / steps as f32;
        match class_at(img, cx + r * c, cy + r * s) {
            Px::Filled => filled += 1,
            Px::Lost => lost += 1,
            Px::Other => {}
        }
    }
    match (filled, lost) {
        (0, 0) => Px::Other,
        (f, l) if f >= l => Px::Filled,
        _ => Px::Lost,
    }
}

/// The angle of sample `i` of `n` along an arc, at the middle of its 1/n of the span.
fn arc_angle(i: usize, n: usize) -> f32 {
    ARC_START_DEG + ARC_SPAN_DEG * (i as f32 + 0.5) / n as f32
}

/// Radii at scale 1 between and either side of the arcs, where a ring has no arc pixels: the gaps
/// between arcs, the dark band between the hull arc and the ship portrait, and outside the shield
/// arc short of the selected target's outline.
const REF_GAP_RADII: [f32; 4] = [68.5, 58.0, 50.0, 41.5];

/// How ring-like the spot `(cx, cy)` is for a ring of `scale`, sampling `n` angles: the share of
/// samples on the three arc radii that hit an arc pixel (white or red), minus the share on the
/// radii between and around them that do. Sharp in position and scale, because a ring shifted
/// by half the arc spacing puts its arcs in the gaps.
fn ring_score(img: &RgbImage, cx: f32, cy: f32, scale: f32, n: usize) -> f32 {
    let hits = |radii: &[f32]| {
        let mut hits = 0;
        for radius in radii {
            let r = radius * scale;
            // Either side along the arc too, so a sample in the gap between two segments hits.
            let dt = (1.5 / r).to_degrees();
            for i in 0..n {
                let a = arc_angle(i, n);
                let hit = [a - dt, a, a + dt].into_iter().any(|deg| {
                    let (s, c) = deg.to_radians().sin_cos();
                    class_at(img, cx + r * c, cy + r * s) != Px::Other
                });
                if hit {
                    hits += 1;
                }
            }
        }
        hits as f32 / (radii.len() * n) as f32
    };
    hits(&REF_RADII) - hits(&REF_GAP_RADII)
}

/// Read the ring of `scale` centered at `(cx, cy)` in `img`: [`ARC_SAMPLES`] samples per arc.
/// `None` if too few samples are white or red for it to be a ring.
pub fn read_ring(img: &RgbImage, cx: f32, cy: f32, scale: f32) -> Option<Hp> {
    let half = REF_HALF_THICKNESS * scale;
    let mut fractions = [0.0f32; 3];
    let mut counted = 0;
    for (k, radius) in REF_RADII.iter().enumerate() {
        let (mut filled, mut lost) = (0, 0);
        for i in 0..ARC_SAMPLES {
            match arc_sample(img, cx, cy, radius * scale, half, arc_angle(i, ARC_SAMPLES)) {
                Px::Filled => filled += 1,
                Px::Lost => lost += 1,
                Px::Other => {}
            }
        }
        counted += filled + lost;
        fractions[k] = if filled + lost == 0 { 0.0 } else { filled as f32 / (filled + lost) as f32 };
    }
    (counted >= MIN_READ_SAMPLES).then(|| Hp { shield: fractions[0], armor: fractions[1], hull: fractions[2] })
}

/// Where one block's brackets sit: their ring scale and the x of each column, in block
/// coordinates.
#[derive(Clone, Debug, PartialEq)]
pub struct BlockGeometry {
    pub scale: f32,
    pub columns: Vec<f32>,
}

/// The best ring of `scale` in `img`, searching centers on a `step` grid within `xs` × `ys`.
fn best_ring(
    img: &RgbImage,
    scale: f32,
    xs: (f32, f32),
    ys: (f32, f32),
    step: f32,
    n: usize,
) -> Option<(f32, f32, f32)> {
    let mut best: Option<(f32, f32, f32)> = None;
    let mut y = ys.0;
    while y <= ys.1 {
        let mut x = xs.0;
        while x <= xs.1 {
            let s = ring_score(img, x, y, scale, n);
            if best.is_none_or(|b| s > b.0) {
                best = Some((s, x, y));
            }
            x += step;
        }
        y += step;
    }
    best
}

/// The ring scale at `(cx, cy)`, refined from a rough `scale`: the radial centroid of each arc's
/// pixels, least-squares fitted to [`REF_RADII`]. The scale sweep alone can't tell scales a step
/// apart (an arc is several pixels thick).
fn fit_scale(img: &RgbImage, cx: f32, cy: f32, scale: f32) -> f32 {
    let n = 96;
    let (mut num, mut den) = (0.0f32, 0.0f32);
    for radius in REF_RADII {
        let (mut sum, mut count) = (0.0f32, 0.0f32);
        let mut d = -4.0 * scale;
        while d <= 4.0 * scale {
            let r = radius * scale + d;
            for i in 0..n {
                let (s, c) = arc_angle(i, n).to_radians().sin_cos();
                if class_at(img, cx + r * c, cy + r * s) != Px::Other {
                    sum += r;
                    count += 1.0;
                }
            }
            d += 0.5;
        }
        if count > 0.0 {
            num += sum / count * radius;
            den += radius * radius;
        }
    }
    if den > 0.0 { num / den } else { scale }
}

impl BlockGeometry {
    /// Find the ring scale and columns of `block` (a crop of one target block): the best-scoring
    /// ring over every scale in [`SCALE_SWEEP`] fixes the scale and one column, and the others are
    /// a bracket pitch apart ([`detect_rings`] allows for the pitch being a little off). `None`
    /// when no ring is visible yet (nothing locked).
    pub fn calibrate(block: &RgbImage) -> Option<BlockGeometry> {
        // Cheap reject: a ring has hundreds of white or red pixels.
        let arc_px = block.pixels().filter(|p| classify(p.0) != Px::Other).count();
        if arc_px < 600 {
            return None;
        }
        let (w, h) = (block.width() as f32, block.height() as f32);
        let (lo, hi, step) = SCALE_SWEEP;
        let mut best: Option<(f32, f32, f32, f32)> = None; // score, x, y, scale
        let mut scale = lo;
        while scale <= hi + 1e-6 {
            let r = REF_RADII[0] * scale;
            if let Some((s, x, y)) = best_ring(block, scale, (r * 0.5, w - r * 0.5), (r, h - r), 4.0, 16) {
                if best.is_none_or(|b| s > b.0) {
                    best = Some((s, x, y, scale));
                }
            }
            scale += step;
        }
        let (_, x, y, scale) = best?;
        // Refine around the coarse fit.
        let mut fine: Option<(f32, f32, f32, f32)> = None;
        let mut s = scale - step;
        while s <= scale + step + 1e-6 {
            if let Some((score, fx, fy)) = best_ring(block, s, (x - 4.0, x + 4.0), (y - 4.0, y + 4.0), 1.0, 48) {
                if fine.is_none_or(|b| score > b.0) {
                    fine = Some((score, fx, fy, s));
                }
            }
            s += step / 4.0;
        }
        let (score, x, y, scale) = fine?;
        if score < MIN_RING_SCORE {
            return None;
        }
        let scale = fit_scale(block, x, y, scale);
        let pitch = REF_PITCH_X * scale;
        let first = x - pitch * (x / pitch).floor();
        let columns = std::iter::successors(Some(first), |c| Some(c + pitch))
            .take_while(|&c| c < w)
            .collect();
        Some(BlockGeometry { scale, columns })
    }
}

/// How far either side of a column's x [`detect_rings`] looks, at scale 1: a column a few pitches
/// from the one calibration measured can be off by a few pixels.
const REF_COLUMN_SLACK: f32 = 6.0;

/// The rings visible in `block` with geometry `geom`: each column is scanned top to bottom for
/// ring-shaped peaks, which are then refined to the pixel. Centers in block coordinates, sorted
/// by column, then row.
pub fn detect_rings(block: &RgbImage, geom: &BlockGeometry) -> Vec<(f32, f32)> {
    let s = geom.scale;
    let r = REF_RADII[0] * s;
    let h = block.height() as f32;
    let slack = REF_COLUMN_SLACK * s;
    let mut out = Vec::new();
    for &cx in &geom.columns {
        // Each y's best score across the column's slack.
        let mut scores = Vec::new();
        let mut y = r;
        while y <= h - r * 0.5 {
            let mut best = f32::MIN;
            let mut x = cx - slack;
            while x <= cx + slack {
                best = best.max(ring_score(block, x, y, s, 16));
                x += slack / 2.0;
            }
            scores.push((y, best));
            y += 2.0;
        }
        // Greedy peak picking: highest first, nothing within a row gap of a kept peak.
        let mut order: Vec<usize> = (0..scores.len()).filter(|&i| scores[i].1 >= MIN_RING_SCORE).collect();
        order.sort_by(|&a, &b| scores[b].1.total_cmp(&scores[a].1));
        let mut kept: Vec<f32> = Vec::new();
        for i in order {
            let y = scores[i].0;
            if kept.iter().all(|&k| (k - y).abs() >= REF_MIN_ROW_GAP * s) {
                kept.push(y);
            }
        }
        kept.sort_by(f32::total_cmp);
        for y in kept {
            let xs = (cx - slack - 2.0, cx + slack + 2.0);
            if let Some((score, fx, fy)) = best_ring(block, s, xs, (y - 3.0, y + 3.0), 1.0, 48) {
                if score >= MIN_RING_SCORE {
                    out.push((fx, fy));
                }
            }
        }
    }
    out
}

/// What a bracket's label says. Any part may be empty where it didn't read.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Label {
    /// The pilot's name, without the `[CORP]` ticker.
    pub name: String,
    pub ship_type: String,
    pub range_m: Option<f64>,
}

/// Label text height at scale 1 is ~13 px; Tesseract reads it best at about three times that.
const LABEL_UPSCALE: f32 = 3.0;

/// The label under ring `i` of `rings` (all the rings in `block`, ring scale `scale`), cropped and
/// upscaled for Tesseract. `None` if there's no room for a label.
pub fn label_image(block: &RgbImage, rings: &[(f32, f32)], i: usize, scale: f32) -> Option<RgbImage> {
    let (cx, cy) = rings[i];
    let half_w = REF_PITCH_X * scale / 2.0;
    let x0 = (cx - half_w).max(0.0);
    let x1 = (cx + half_w).min(block.width() as f32);
    let y0 = cy + REF_LABEL_TOP * scale;
    // The label stops above the next ring down the same column.
    let next = rings
        .iter()
        .filter(|&&(x, y)| (x - cx).abs() < half_w && y > cy)
        .map(|&(_, y)| y - REF_RING_TOP * scale)
        .fold(f32::INFINITY, f32::min);
    let y1 = (cy + REF_LABEL_MAX * scale).min(next).min(block.height() as f32);
    if x1 - x0 < 8.0 || y1 - y0 < 8.0 {
        return None;
    }
    let rect = Rect { x: x0 as u32, y: y0 as u32, w: (x1 - x0) as u32, h: (y1 - y0) as u32 };
    Some(crop_scaled(block, rect, LABEL_UPSCALE / scale))
}

/// The distance in an OCR'd range line, ignoring specks Tesseract read around and inside it
/// (`"] 104 km"`, `"— 81 km"`, `"113_km"`).
fn line_range(line: &str) -> Option<f64> {
    let start = line.find(|c: char| c.is_ascii_digit())?;
    let rest = &line[start..];
    let end = rest.find(|c: char| !(c.is_ascii_digit() || c == ',' || c == '.')).unwrap_or(rest.len());
    let number = rest[..end].trim_end_matches(['.', ',']);
    let unit = rest[end..].trim_start_matches(|c: char| !c.is_ascii_alphabetic());
    let unit = if unit.starts_with("km") {
        "km"
    } else if unit.starts_with('m') {
        "m"
    } else {
        return None;
    };
    parse_distance(&format!("{number} {unit}")).ok()
}

/// `s` without the specks Tesseract reads off stars and ring edges at either end.
fn trim_specks(s: &str) -> &str {
    s.trim_matches(|c: char| !c.is_alphanumeric())
}

/// Make sense of a label's OCR text: the last line holding a distance is the range, the line
/// above it the ship type, and the lines above that the name, its `[CORP]` ticker dropped (a long
/// name wraps onto a second line, and the ticker may go with it). Lines with no letters or
/// digits (specks read off stars) are skipped.
pub fn parse_label(text: &str) -> Label {
    let lines: Vec<&str> = text
        .lines()
        .map(str::trim)
        .filter(|l| l.chars().filter(|c| c.is_alphanumeric()).count() >= 2)
        .collect();
    let Some(range_at) = lines.iter().rposition(|l| line_range(l).is_some()) else {
        return Label::default();
    };
    let range_m = line_range(lines[range_at]);
    // The ticker may sit on its own line between the name and the type.
    let above: Vec<&str> = lines[..range_at]
        .iter()
        .copied()
        .filter(|l| !l.trim_start_matches(|c: char| !c.is_alphanumeric() && c != '[').starts_with('['))
        .collect();
    let Some((ship_type, name)) = above.split_last() else {
        return Label { range_m, ..Label::default() };
    };
    Label { name: trim_specks(&strip_ticker(&name.join(" "))).to_string(), ship_type: trim_specks(ship_type).to_string(), range_m }
}

/// A label's name line(s) without the `[CORP]` ticker.
fn strip_ticker(text: &str) -> String {
    text.split('[').next().unwrap_or_default().trim().to_string()
}

/// `img` as black text on white: the label text is light and colourless, and dropping
/// everything else (a nebula, coloured combat text) sometimes rescues a label Tesseract misreads
/// on the plain image.
fn binarize(img: &RgbImage) -> image::GrayImage {
    image::GrayImage::from_fn(img.width(), img.height(), |x, y| {
        let p = img.get_pixel(x, y).0;
        let (lo, hi) = (p.iter().min().copied().unwrap_or(0), p.iter().max().copied().unwrap_or(0));
        image::Luma([if lo > 110 && hi - lo < 60 { 0 } else { 255 }])
    })
}

/// Run `tesseract` on `img` (one block of text) and return what it read.
fn tesseract_text(img: &image::GrayImage, tesseract: &Path) -> Result<String> {
    let mut png = Vec::new();
    img.write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)?;
    let mut child = Command::new(tesseract)
        .args(["stdin", "stdout", "--psm", "6"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("running {}", tesseract.display()))?;
    child.stdin.take().expect("piped").write_all(&png)?;
    let out = child.wait_with_output()?;
    if !out.status.success() {
        bail!("{} failed ({})", tesseract.display(), out.status);
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// OCR a [`label_image`] with the `tesseract` executable: as is, and binarized if that doesn't
/// give a name and range.
pub fn ocr_label(img: &RgbImage, tesseract: &Path) -> Result<Label> {
    let complete = |l: &Label| !l.name.is_empty() && l.range_m.is_some();
    let plain = parse_label(&tesseract_text(&image::DynamicImage::ImageRgb8(img.clone()).to_luma8(), tesseract)?);
    if complete(&plain) {
        return Ok(plain);
    }
    let bin = parse_label(&tesseract_text(&binarize(img), tesseract)?);
    Ok(if complete(&bin) || plain.name.is_empty() { bin } else { plain })
}

/// One ring found in one frame: its block, its center in block coordinates, its HP.
#[derive(Clone, Debug)]
pub struct Ring {
    pub center: (f32, f32),
    pub hp: Hp,
}

/// Find and read every ring in `block`.
pub fn read_rings(block: &RgbImage, geom: &BlockGeometry) -> Vec<Ring> {
    detect_rings(block, geom)
        .into_iter()
        .filter_map(|(cx, cy)| Some(Ring { center: (cx, cy), hp: read_ring(block, cx, cy, geom.scale)? }))
        .collect()
}

/// Labels are read again this often even when a block's rings haven't moved, in case one target
/// was swapped for another in the same spot between two samples.
pub const LABEL_REFRESH_S: f64 = 10.0;

/// Max distance (px) a ring may move between frames and still be the same bracket.
const SAME_RING_PX: f32 = 8.0;

fn same_rings(a: &[(f32, f32)], b: &[(f32, f32)]) -> bool {
    a.len() == b.len()
        && a.iter().zip(b).all(|(p, q)| (p.0 - q.0).abs() <= SAME_RING_PX && (p.1 - q.1).abs() <= SAME_RING_PX)
}

/// One block's labels as last read, and its last planned read.
#[derive(Clone, Debug, Default)]
struct BlockLabels {
    centers: Vec<(f32, f32)>,
    labels: Vec<Label>,
    /// The rings and time of the last read planned: what later frames are compared against to
    /// decide whether they need a read of their own.
    planned: Vec<(f32, f32)>,
    planned_at: f64,
    /// A label didn't read, so read again at the next chance.
    retry: bool,
}

/// Which blocks need their labels OCR'd, and the labels of those that don't: labels only change
/// when targets are locked, unlocked or swapped, which moves, adds or removes rings, so a block
/// is only read again when its rings change (or every [`LABEL_REFRESH_S`]).
///
/// Reads are planned for a run of frames first ([`LabelCache::needs_read`], [`LabelCache::plan`]),
/// done together, then stored in frame order ([`LabelCache::store`]); a frame's labels are those
/// of the last read stored at or before it ([`LabelCache::labels`]).
#[derive(Clone, Debug)]
pub struct LabelCache {
    blocks: Vec<BlockLabels>,
}

impl LabelCache {
    pub fn new(blocks: usize) -> LabelCache {
        LabelCache { blocks: vec![BlockLabels { planned_at: f64::NEG_INFINITY, ..BlockLabels::default() }; blocks] }
    }

    /// Whether block `b`, showing rings at `centers` at time `t`, needs reading.
    pub fn needs_read(&self, b: usize, t: f64, centers: &[(f32, f32)]) -> bool {
        let s = &self.blocks[b];
        !centers.is_empty() && (s.retry || t - s.planned_at >= LABEL_REFRESH_S || !same_rings(&s.planned, centers))
    }

    /// Note that block `b` will be read at `t` (so later frames showing the same rings don't read
    /// it again), before its labels are known.
    pub fn plan(&mut self, b: usize, t: f64, centers: &[(f32, f32)]) {
        let s = &mut self.blocks[b];
        s.planned = centers.to_vec();
        s.planned_at = t;
        s.retry = false;
    }

    /// Store block `b`'s labels, read for rings at `centers`. A label that didn't read keeps the
    /// one read before for the same ring, if the rings haven't changed since: something drawn
    /// over a label for a moment (combat text) doesn't make its ring anonymous.
    pub fn store(&mut self, b: usize, centers: &[(f32, f32)], mut labels: Vec<Label>) {
        let s = &mut self.blocks[b];
        if s.labels.len() == labels.len() && same_rings(&s.centers, centers) {
            for (new, old) in labels.iter_mut().zip(&s.labels) {
                if new.name.is_empty() {
                    *new = old.clone();
                }
            }
        }
        s.retry |= labels.iter().any(|l| l.name.is_empty());
        s.centers = centers.to_vec();
        s.labels = labels;
    }

    /// Block `b`'s labels, if they were read for rings at `centers`.
    pub fn labels(&self, b: usize, centers: &[(f32, f32)]) -> Option<&[Label]> {
        let s = &self.blocks[b];
        (s.labels.len() == centers.len() && same_rings(&s.centers, centers)).then_some(&s.labels[..])
    }
}

/// A roster pilot a label might belong to, as of the label's frame.
#[derive(Clone, Debug)]
pub struct Candidate<'a> {
    pub name: &'a str,
    pub ship_type: &'a str,
    /// The pilot's distance from each observer that read one this tick, metres.
    pub ranges_m: Vec<f64>,
}

/// Edit distance between a label's name and a roster name, either of which may be cut short
/// (the overview's Name column truncates long names), and the label may carry misread specks
/// either side of the name: the roster name is matched against the best-fitting stretch of the
/// label too.
fn name_distance(label: &str, roster: &str) -> usize {
    let (a, b) = (label.to_lowercase(), roster.to_lowercase());
    let (short, long) = if a.chars().count() <= b.chars().count() { (&a, &b) } else { (&b, &a) };
    let prefix: String = long.chars().take(short.chars().count()).collect();
    levenshtein(&a, &b).min(levenshtein(short, &prefix)).min(infix_distance(&b, &a))
}

/// Edit distance between `needle` and the stretch of `hay` it best fits (free to skip any of
/// `hay` before and after).
fn infix_distance(needle: &str, hay: &str) -> usize {
    let (n, h): (Vec<char>, Vec<char>) = (needle.chars().collect(), hay.chars().collect());
    let mut prev = vec![0usize; h.len() + 1]; // an empty needle fits anywhere for free
    for (i, &nc) in n.iter().enumerate() {
        let mut cur = vec![i + 1; h.len() + 1];
        for (j, &hc) in h.iter().enumerate() {
            cur[j + 1] = (prev[j] + usize::from(nc != hc)).min(prev[j + 1] + 1).min(cur[j] + 1);
        }
        prev = cur;
    }
    prev.into_iter().min().unwrap_or(0)
}

/// Whether two ship-type readings agree: the same ship once snapped to a known one, or one a
/// prefix of the other (both the label and the overview cut long names short).
fn same_type(a: &str, b: &str, ship_types: &ShipTypes) -> bool {
    let (a, b) = (ship_types.canonicalize(a.trim()).to_lowercase(), ship_types.canonicalize(b.trim()).to_lowercase());
    !a.is_empty() && !b.is_empty() && (a.starts_with(&b) || b.starts_with(&a))
}

/// Whether a label's range agrees with any observer's distance to the pilot: the label shows
/// whole km, and Tesseract can misread a digit.
fn range_agrees(label_m: f64, ranges_m: &[f64]) -> bool {
    ranges_m.iter().any(|&r| (label_m - r).abs() <= (0.1 * r).max(3_000.0))
}

/// Which of `candidates` a label belongs to. The name decides when it's within a misread or two of
/// exactly one pilot (ship type and range break ties); a badly read name still matches when only
/// one pilot within half its length also has the label's ship type and range. `None` if no pilot
/// or more than one fits.
pub fn match_label(label: &Label, candidates: &[Candidate], ship_types: &ShipTypes) -> Option<usize> {
    let len = label.name.chars().count();
    if len < 3 {
        return None;
    }
    let tol = (len / 5).max(1);
    let fits = |c: &Candidate| {
        let type_ok = same_type(&label.ship_type, c.ship_type, ship_types);
        let range_ok = match label.range_m {
            Some(m) if !c.ranges_m.is_empty() => Some(range_agrees(m, &c.ranges_m)),
            _ => None,
        };
        (type_ok, range_ok)
    };
    let mut scored: Vec<(usize, usize)> = candidates
        .iter()
        .enumerate()
        .filter_map(|(i, c)| {
            let d = name_distance(&label.name, c.name);
            (d <= tol).then(|| {
                let (type_ok, range_ok) = fits(c);
                (d + 2 * usize::from(!type_ok) + usize::from(range_ok == Some(false)), i)
            })
        })
        .collect();
    scored.sort();
    match scored[..] {
        [(_, i)] => return Some(i),
        [(best, i), (next, _), ..] if best < next => return Some(i),
        [_, _, ..] => return None,
        [] => {}
    }
    let mut loose = candidates.iter().enumerate().filter(|(_, c)| {
        name_distance(&label.name, c.name) <= len / 2 && fits(c) == (true, Some(true))
    });
    match (loose.next(), loose.next()) {
        (Some((i, _)), None) => Some(i),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgb;

    const WHITE: Rgb<u8> = Rgb([220, 220, 220]);
    const RED: Rgb<u8> = Rgb([200, 30, 30]);
    const SPACE: Rgb<u8> = Rgb([12, 12, 14]);

    /// Draw a segmented ring of `scale` at `(cx, cy)`: each arc white for its first `hp` share
    /// (from the start of the span) and red after, with a dark gap between segments.
    fn draw_ring(img: &mut RgbImage, cx: f32, cy: f32, scale: f32, hp: [f32; 3]) {
        let segments = 40;
        for (k, radius) in REF_RADII.iter().enumerate() {
            let r = radius * scale;
            let steps = (ARC_SPAN_DEG.to_radians() * r * 2.0) as usize;
            for i in 0..steps {
                let u = i as f32 / steps as f32;
                // Segment gap: the last 20 % of each segment's angle.
                if (u * segments as f32).fract() > 0.8 {
                    continue;
                }
                let colour = if u < hp[k] { WHITE } else { RED };
                let deg = ARC_START_DEG + ARC_SPAN_DEG * u;
                let (s, c) = deg.to_radians().sin_cos();
                let mut d = -2.0 * scale;
                while d <= 2.0 * scale {
                    let (x, y) = ((cx + (r + d) * c).round(), (cy + (r + d) * s).round());
                    if x >= 0.0 && y >= 0.0 && (x as u32) < img.width() && (y as u32) < img.height() {
                        img.put_pixel(x as u32, y as u32, colour);
                    }
                    d += 0.5;
                }
            }
        }
    }

    fn space(w: u32, h: u32) -> RgbImage {
        RgbImage::from_pixel(w, h, SPACE)
    }

    fn close(a: f32, b: f32) -> bool {
        (a - b).abs() <= 0.03
    }

    #[test]
    fn full_ring_reads_full() {
        let mut img = space(200, 200);
        draw_ring(&mut img, 100.0, 100.0, 1.0, [1.0, 1.0, 1.0]);
        let hp = read_ring(&img, 100.0, 100.0, 1.0).unwrap();
        assert!(close(hp.shield, 1.0) && close(hp.armor, 1.0) && close(hp.hull, 1.0), "{hp:?}");
    }

    #[test]
    fn partial_arcs_read_their_share() {
        let mut img = space(200, 200);
        draw_ring(&mut img, 100.0, 100.0, 1.0, [0.37, 0.0, 0.8]);
        let hp = read_ring(&img, 100.0, 100.0, 1.0).unwrap();
        assert!(close(hp.shield, 0.37), "{hp:?}");
        assert!(close(hp.armor, 0.0), "{hp:?}");
        assert!(close(hp.hull, 0.8), "{hp:?}");
    }

    #[test]
    fn empty_space_is_no_ring() {
        assert_eq!(read_ring(&space(200, 200), 100.0, 100.0, 1.0), None);
    }

    #[test]
    fn text_over_the_ring_is_ignored() {
        let mut img = space(200, 200);
        draw_ring(&mut img, 100.0, 100.0, 1.0, [0.5, 1.0, 1.0]);
        // A dim combat-text stripe across the top of the ring.
        for y in 40..50 {
            for x in 0..200 {
                img.put_pixel(x, y, Rgb([120, 110, 60]));
            }
        }
        let hp = read_ring(&img, 100.0, 100.0, 1.0).unwrap();
        assert!(close(hp.shield, 0.5) && close(hp.armor, 1.0), "{hp:?}");
    }

    #[test]
    fn calibration_finds_scale_and_columns() {
        let scale = 1.2;
        let mut img = space(660, 700);
        let pitch = REF_PITCH_X * scale;
        draw_ring(&mut img, 110.0 + pitch, 90.0, scale, [1.0, 0.6, 1.0]);
        let geom = BlockGeometry::calibrate(&img).unwrap();
        assert!((geom.scale - scale).abs() < 0.02, "{geom:?}");
        assert_eq!(geom.columns.len(), 3, "{geom:?}");
        assert!((geom.columns[0] - 110.0).abs() <= 2.0, "{geom:?}");
    }

    #[test]
    fn nothing_locked_does_not_calibrate() {
        assert_eq!(BlockGeometry::calibrate(&space(576, 928)), None);
    }

    #[test]
    fn detects_rows_of_any_height() {
        let mut img = space(576, 928);
        // Column 0: rows at 79 and 411 (a wrapped label above); column 1: one ring at 79.
        for (x, y) in [(88.0, 79.0), (88.0, 411.0), (268.0, 79.0)] {
            draw_ring(&mut img, x, y, 1.0, [1.0, 1.0, 1.0]);
        }
        let geom = BlockGeometry { scale: 1.0, columns: vec![88.0, 268.0, 448.0] };
        let rings = detect_rings(&img, &geom);
        assert_eq!(rings.len(), 3, "{rings:?}");
        for (got, want) in rings.iter().zip([(88.0, 79.0), (88.0, 411.0), (268.0, 79.0)]) {
            assert!((got.0 - want.0).abs() <= 1.0 && (got.1 - want.1).abs() <= 1.0, "{rings:?}");
        }
    }

    #[test]
    fn labels_parse_with_wrapped_names_and_specks() {
        let l = parse_label("Test Pilot [ABC]\nRifter\n104 km\n");
        assert_eq!((l.name.as_str(), l.ship_type.as_str(), l.range_m), ("Test Pilot", "Rifter", Some(104_000.0)));
        let l = parse_label("Another Long\nPilotname [ABC]\nProphecy Navy Is\n\n. ,\n1,204 m\n");
        assert_eq!(l.name, "Another Long Pilotname");
        assert_eq!(l.ship_type, "Prophecy Navy Is");
        assert_eq!(l.range_m, Some(1_204.0));
        let l = parse_label("Someone Else\n_ [A.B]\nPunisher\n85 km");
        assert_eq!((l.name.as_str(), l.ship_type.as_str()), ("Someone Else", "Punisher"));
        assert_eq!(parse_label("noise\n"), Label::default());
        let l = parse_label(". Test Pilot\n[ABC]\n_ Rifter\n— 81 km\n");
        assert_eq!((l.name.as_str(), l.ship_type.as_str(), l.range_m), ("Test Pilot", "Rifter", Some(81_000.0)));
        assert_eq!(parse_label("Test Pilot [ABC]\nRifter\n] 104 km").range_m, Some(104_000.0));
        assert_eq!(parse_label("Test Pilot [ABC]\nRifter\n113_km").range_m, Some(113_000.0));
        assert_eq!(parse_label("Test Pilot [ABC]\nRifter\n1,204.m").range_m, Some(1_204.0));
    }

    fn cand<'a>(name: &'a str, ship_type: &'a str, km: &[f64]) -> Candidate<'a> {
        Candidate { name, ship_type, ranges_m: km.iter().map(|k| k * 1000.0).collect() }
    }

    fn label(name: &str, ship_type: &str, km: f64) -> Label {
        Label { name: name.into(), ship_type: ship_type.into(), range_m: Some(km * 1000.0) }
    }

    #[test]
    fn labels_match_by_name() {
        let types = ShipTypes::builtin();
        let roster = [cand("Test Pilot", "Rifter", &[50.0]), cand("Other Person", "Punisher", &[60.0])];
        assert_eq!(match_label(&label("Test Pi1ot", "Rifter", 50.0), &roster, &types), Some(0));
        // The overview cut the roster name short.
        let roster = [cand("Someone Lon", "Rifter", &[50.0]), cand("Other Person", "Punisher", &[60.0])];
        assert_eq!(match_label(&label("Someone Longname", "Rifter", 50.0), &roster, &types), Some(0));
        assert_eq!(match_label(&label("Nobody Here", "Rifter", 50.0), &roster, &types), None);
        // Specks read either side of the name.
        assert_eq!(match_label(&label("= vther Person ei", "Punisher", 60.0), &roster, &types), Some(1));
    }

    #[test]
    fn type_and_range_break_name_ties() {
        let types = ShipTypes::builtin();
        let roster = [cand("Pilot Ann", "Rifter", &[50.0]), cand("Pilot Anna", "Punisher", &[90.0])];
        assert_eq!(match_label(&label("Pilot Ann", "Punisher", 90.0), &roster, &types), Some(1));
        let roster = [cand("Pilot Ann", "Rifter", &[50.0]), cand("Pilot Anna", "Rifter", &[90.0])];
        assert_eq!(match_label(&label("Pilot Ann", "Rifter", 90.0), &roster, &types), Some(1));
        assert_eq!(match_label(&label("Pilot Ann", "Rifter", 70.0), &roster, &types), None);
    }

    #[test]
    fn a_misread_name_matches_on_type_and_range() {
        let types = ShipTypes::builtin();
        let roster = [cand("Test Pilot", "Rifter", &[50.0]), cand("Other Person", "Punisher", &[60.0])];
        assert_eq!(match_label(&label("Tst P1lct", "Rifter", 51.0), &roster, &types), Some(0));
        assert_eq!(match_label(&label("Tst P1lct", "Rifter", 90.0), &roster, &types), None);
    }

    #[test]
    fn label_cache_reads_on_change_and_refresh() {
        let mut cache = LabelCache::new(1);
        let a = [(88.0, 79.0)];
        let ab = [(88.0, 79.0), (268.0, 80.0)];
        assert!(!cache.needs_read(0, 0.0, &[]));
        assert!(cache.needs_read(0, 0.0, &a));
        cache.plan(0, 0.0, &a);
        cache.store(0, &a, vec![label("Test Pilot", "Rifter", 50.0)]);
        assert!(!cache.needs_read(0, 1.0, &[(89.0, 80.0)]));
        assert!(cache.labels(0, &[(89.0, 80.0)]).is_some());
        assert!(cache.needs_read(0, 1.0, &ab));
        assert!(cache.labels(0, &ab).is_none());
        assert!(cache.needs_read(0, LABEL_REFRESH_S, &a));
        cache.plan(0, 2.0, &ab);
        cache.store(0, &ab, vec![label("Test Pilot", "Rifter", 50.0), Label::default()]);
        assert!(cache.needs_read(0, 3.0, &ab), "an unread label is retried");
    }

    #[test]
    fn a_label_that_does_not_read_keeps_the_last_one() {
        let mut cache = LabelCache::new(1);
        let a = [(88.0, 79.0)];
        cache.plan(0, 0.0, &a);
        cache.store(0, &a, vec![label("Test Pilot", "Rifter", 50.0)]);
        cache.plan(0, 10.0, &a);
        cache.store(0, &a, vec![Label::default()]);
        assert_eq!(cache.labels(0, &a).unwrap()[0].name, "Test Pilot");
        assert!(!cache.needs_read(0, 11.0, &a), "nothing left to retry");
    }

    #[test]
    fn planning_ahead_keeps_earlier_frames_labels() {
        // Frames 0 and 1 show ring set A, frame 2 set AB: frame 2's read is planned before frame
        // 1's labels are looked up.
        let mut cache = LabelCache::new(1);
        let a = [(88.0, 79.0)];
        let ab = [(88.0, 79.0), (268.0, 80.0)];
        cache.plan(0, 0.0, &a);
        assert!(!cache.needs_read(0, 1.0, &a));
        assert!(cache.needs_read(0, 2.0, &ab));
        cache.plan(0, 2.0, &ab);
        cache.store(0, &a, vec![label("Test Pilot", "Rifter", 50.0)]);
        assert_eq!(cache.labels(0, &a).map(<[Label]>::len), Some(1), "frame 1");
        cache.store(0, &ab, vec![label("Test Pilot", "Rifter", 50.0), label("Other Person", "Punisher", 60.0)]);
        assert_eq!(cache.labels(0, &ab).map(<[Label]>::len), Some(2), "frame 2");
    }

    #[test]
    fn ticker_is_stripped() {
        assert_eq!(strip_ticker("Test Pilot [ABC]"), "Test Pilot");
        assert_eq!(strip_ticker("Another Pilot"), "Another Pilot");
    }
}
