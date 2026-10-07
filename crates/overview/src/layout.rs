//! Overview column layout, detected from the header row rather than assumed at fixed pixel
//! coordinates (DESIGN.md S0 "layout calibration" / S4.4). The task this solves: "the columns may
//! not be in the same order and extra columns may or may not be present, but the necessary four
//! [Distance, Name, Type, Velocity] will be there along with the header row" — so layout detection
//! reads the header text and locates each required column by keyword, wherever it happens to sit
//! and however many other columns (Size, Angular, ...) surround it.
//!
//! Detected once per recording (a static OBS scene, per DESIGN.md S0), then reused to read every
//! subsequent frame's rows at fixed x-ranges and a fixed row pitch.

use crate::util::levenshtein_ci;
use anyhow::{bail, Result};
use glyph::{segment, Alphabet, Font};
use image::RgbImage;
use std::collections::HashMap;

/// The four columns this crate tracks. The overview may show others (Size, Angular, Radial/
/// Transversal Velocity, Corp, Alliance, ...); those are located and skipped, never required.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Column {
    Distance,
    Name,
    Type,
    Velocity,
}

impl Column {
    fn keyword(self) -> &'static str {
        match self {
            Column::Distance => "distance",
            Column::Name => "name",
            Column::Type => "type",
            Column::Velocity => "velocity",
        }
    }

    const ALL: [Column; 4] = [Column::Distance, Column::Name, Column::Type, Column::Velocity];
}

/// Header keywords that exist but this crate has no use for — recognising them keeps them from
/// ever being mistaken for one of the required four, but their position isn't recorded.
const IGNORED_HEADER_KEYWORDS: &[&str] = &[
    "size", "angular", "radial", "transversal", "corp", "alliance", "signal",
];

/// A pixel rectangle within a frame, `[x, x+w) x [y, y+h)`.
#[derive(Clone, Copy, Debug, serde::Serialize, serde::Deserialize)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

/// A detected column's cell span: `[x, x+w)`, generous enough to hold any value that column
/// renders (wider than the header word itself for a right-aligned numeric column).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ColSpan {
    pub x: u32,
    pub w: u32,
}

/// A fully detected overview layout: where each required column is horizontally, and where rows
/// start and repeat vertically.
#[derive(Clone, Debug)]
pub struct Layout {
    pub columns: HashMap<Column, ColSpan>,
    /// Row cell height to read (a single `(x, w)` reused for every column at this row).
    pub row_height: u32,
    /// Y of the first data row (row 0).
    pub row0_y: u32,
    /// Vertical spacing between consecutive rows.
    pub row_pitch: f32,
    /// Bottom of the area rows may occupy (the panel's bottom edge) — a row slot at or past this
    /// y is not read.
    pub list_bottom: u32,
}

impl Layout {
    pub fn column(&self, c: Column) -> ColSpan {
        self.columns[&c]
    }

    /// Row `i`'s y (top) and height, or `None` if row `i` doesn't fit above `list_bottom`.
    ///
    /// The returned band is inset [`ROW_INSET_PX`] from the row's nominal top and bottom. A row
    /// cut off by the panel edge is not read at all: its partial glyphs read as confident
    /// garbage (`"alaiaaxa"`) rather than as blank.
    pub fn row_rect(&self, i: u32) -> Option<(u32, u32)> {
        let y = self.row0_y as f32 + i as f32 * self.row_pitch;
        let top = y.round() as u32 + ROW_INSET_PX;
        let bottom = y.round() as u32 + self.row_height - ROW_INSET_PX;
        if bottom > self.list_bottom {
            return None;
        }
        Some((top, bottom - top))
    }
}

/// Pixels trimmed off the top and bottom of every row band before its cells are read. Row text is
/// vertically centred with ~10px of slack on each side, but the fitted row grid can land a pixel
/// off a real background transition (seen on resampled panels, `crate::panel`); a 1px blended
/// line from a differently-coloured neighbouring row (gray above blue) then spans the whole cell
/// width and wrecks its bg/fg estimate. Trimming a few pixels removes that line without touching
/// the glyphs.
const ROW_INSET_PX: u32 = 3;

/// Row pitch (px) of the overview this crate's thresholds (and `glyph`'s bundled font sample) were
/// tuned against: the 2560x1600 video fixture, fitted by `detect` at ~43.4px. A panel rendered at
/// a different UI scale or window size is resampled to this pitch first (`crate::panel`), so
/// every fixed pixel threshold here and in `glyph` keeps meaning the same thing.
pub const REF_ROW_PITCH: f32 = 43.4;

/// Minimum height (px) for a detected line band to count as text rather than a hairline
/// separator (the golden fixtures' row separators, and this crate's own frames, both show these
/// as 1-6px bands well below any real glyph's height).
const MIN_LINE_HEIGHT: u32 = 10;

/// Gap (px) between ink runs that separates two header words rather than two letters of the same
/// word. Matches `glyph`'s own `DEFAULT_SPACE_GAP_PX` (kept in sync by the golden/background
/// tests there); duplicated here because layout detection segments words itself, ahead of
/// deciding which rect to hand `Font::read_region` for the actual text.
const WORD_GAP_PX: usize = 9;

/// Case-insensitive edit distance, at or under which an OCR'd header word counts as a keyword
/// match. `2` tolerates header text reading noisier than row text tends to (observed on real
/// compressed video: `"Distance"` -> `"Oislance"`, two misread glyphs) without risking a
/// collision — the required/ignored keyword set is small and mutually far apart (nearest pair is
/// 3+ edits), so this stays comfortably unambiguous.
const KEYWORD_MAX_DISTANCE: usize = 2;

/// How far (px) a column's cell may extend past its header word on a side with no neighbouring
/// header word to bound it (the panel's outer edge). `Name` gets much more slack: a pilot name
/// routinely runs far wider than the 4-letter header `"Name"` itself, where the numeric columns'
/// values are rarely wider than their own header word (`"50,095"` is narrower than `"Velocity"`).
fn outer_margin(col: Column) -> u32 {
    match col {
        Column::Name => 200,
        // Small: a numeric column at the panel's outer edge has nothing past it but the row-icon
        // gutter (left edge) or empty panel background (right edge) — generous margin here risks
        // pulling in icon-glyph noise rather than catching a wider value (see `detect`'s doc
        // comment: these columns' header word is usually already about as wide as their data).
        _ => 15,
    }
}

/// Detect the overview's column layout within `panel`, a rectangle expected to contain the whole
/// overview panel (header + row list). `panel` does not need to be tight — only wide/tall enough
/// to contain the table; detection finds the header and columns by their text, not by position.
///
/// Line/word existence is judged by *local contrast* (a row's, or a word-column's, deviation from
/// its own neighbourhood's median colour) rather than `glyph::coverage`'s single bg/fg pair for a
/// whole region: the overview's row backgrounds alternate (dark/gray/red/blue/purple) and its
/// header/tab text is visibly dimmer than row text, so no single bg/fg pair fits the whole panel.
/// Once a word's pixel rect is known, `Font::read_region`'s own per-cell bg/fg detection reads it
/// correctly regardless of that rect's actual colours — that part is unchanged.
pub fn detect(img: &RgbImage, panel: Rect, font: &Font) -> Result<Layout> {
    let row_ink = row_ink_signal(img, panel);
    let lines = segment::runs(&row_ink, INK_THRESHOLD);
    let lines: Vec<(usize, usize)> = lines
        .into_iter()
        .filter(|&(y0, y1)| (y1 - y0) as u32 >= MIN_LINE_HEIGHT)
        .collect();

    // (line bottom, every word span in that line, required-column -> word span)
    type HeaderCandidate = (usize, Vec<(usize, usize)>, HashMap<Column, (usize, usize)>);
    let mut best: Option<HeaderCandidate> = None;
    for &(y0, y1) in &lines {
        let words = word_spans(img, panel, y0, y1);
        let mut found: HashMap<Column, (usize, usize)> = HashMap::new();
        for &(wx0, wx1) in &words {
            let text = font
                .read_region(
                    img,
                    panel.x + wx0 as u32,
                    panel.y + y0 as u32,
                    (wx1 - wx0) as u32,
                    (y1 - y0) as u32,
                    Alphabet::Full,
                )
                .text;
            if std::env::var_os("OVERVIEW_DEBUG_LAYOUT").is_some() {
                eprintln!("line y=({y0},{y1}) word=({wx0},{wx1}) text={text:?}");
            }
            if let Some(col) = match_keyword(&text) {
                found.insert(col, (wx0, wx1));
            }
        }
        let all_found = found.len() == Column::ALL.len();
        if found.len() > best.as_ref().map(|(_, _, f)| f.len()).unwrap_or(0) {
            best = Some((y1, words, found));
        }
        if all_found {
            break; // all four required columns found; no need to keep scanning
        }
    }

    let Some((header_bottom, mut all_words, found)) = best else {
        bail!("no header row found: no text line matched any of Distance/Name/Type/Velocity");
    };
    for col in Column::ALL {
        if !found.contains_key(&col) {
            bail!(
                "header row found but missing required column {:?} (found: {:?})",
                col,
                found.keys().collect::<Vec<_>>()
            );
        }
    }

    // Column spans: each column claims from its *own* header word's left edge up to (not
    // including) the *next* header word's left edge — tiling the row contiguously, required or
    // ignored words alike (an ignored column between two required ones, e.g. Size between Type
    // and Velocity, still marks a real boundary; skipping it would let its neighbour's span
    // balloon into its data).
    //
    // This looks like it should only be right for left-aligned columns, but it measures true for
    // every column here, including the right-aligned numeric ones: a header word turns out to
    // mark roughly a column's left edge regardless of how its *data* aligns within that width
    // (e.g. `"Size"`'s own word ends well before its data's right-aligned edge does — data is
    // right-aligned within a column much wider than the 4-letter header, not to the header word's
    // own extent). Measured directly against this crate's video fixture (see the module's design
    // notes); a per-column left/right-alignment model was tried first and needed exactly this
    // shape of correction for right-aligned columns anyway, so this is that model simplified.
    //
    // Very narrow "words" are dropped first: the Name column's sort-direction arrow reads as its
    // own tiny word sitting well inside the Name column's true width, not at a real boundary, and
    // must not be mistaken for one (every genuine header keyword is much wider than this).
    const MIN_NEIGHBOUR_WORD_WIDTH: usize = 20;
    const BOUNDARY_GAP_PX: usize = 4;
    all_words.retain(|&(x0, x1)| x1 - x0 >= MIN_NEIGHBOUR_WORD_WIDTH);
    all_words.sort_by_key(|&(x0, _)| x0);

    let mut columns = HashMap::new();
    for (&col, &(x0, x1)) in &found {
        let idx = all_words
            .iter()
            .position(|&w| w == (x0, x1))
            .expect("a matched column's word span is one of the header's own word spans");
        let left = if idx == 0 {
            x0.saturating_sub(outer_margin(col) as usize)
        } else {
            x0
        };
        let right = if idx + 1 < all_words.len() {
            all_words[idx + 1].0.saturating_sub(BOUNDARY_GAP_PX).max(left)
        } else {
            x1 + outer_margin(col) as usize
        };
        columns.insert(
            col,
            ColSpan {
                x: panel.x + left as u32,
                w: (right - left) as u32,
            },
        );
    }

    // Row pitch/row0: text-line bands strictly below the header. Scanned over the Name column's
    // own x-range only, not the full panel width — every row also carries a small ship-type icon
    // in the leftmost/icon column, and unlike the row text those icons run tall enough, row after
    // row, to leave no ink-free gap between them, which would otherwise merge every row into one
    // giant band.
    let name_span = found[&Column::Name];
    let below_header = Rect {
        x: panel.x + name_span.0 as u32,
        y: panel.y + header_bottom as u32,
        w: (name_span.1 - name_span.0) as u32,
        h: panel.h - header_bottom as u32,
    };
    let row_ink = row_ink_signal(img, below_header);
    let row_bands: Vec<(usize, usize)> = segment::runs(&row_ink, INK_THRESHOLD)
        .into_iter()
        .filter(|&(y0, y1)| (y1 - y0) as u32 >= MIN_LINE_HEIGHT)
        .map(|(y0, y1)| (y0 + header_bottom, y1 + header_bottom))
        .collect();
    if row_bands.len() < 2 {
        bail!(
            "found the header row but only {} data row(s) below it — can't establish row pitch",
            row_bands.len()
        );
    }
    let tops: Vec<f32> = row_bands.iter().map(|&(y0, _)| y0 as f32).collect();
    // Fit row index -> band top by least squares rather than taking the median consecutive
    // difference: band tops are whole pixels, so most gaps measure 43px and some 44px (the true
    // pitch is fractional, ~43.4 here), and the median of those integer diffs collapses to
    // whichever one is more common, discarding the fractional part entirely. That looked harmless
    // per-row but compounds linearly: by row 24 it had drifted enough (~0.4px x 24 rows) to crop
    // a sliver of the row *above* into the cell — fatal specifically when that neighbour is a
    // strongly different colour (this crate's red "hostile" row), which projects the wrong-row
    // sliver to a false mid-range ink value across the whole row width, one solid blob instead of
    // per-letter runs. A least-squares fit keeps the fractional pitch, so row0_y/row_pitch stay
    // accurate arbitrarily far down the list instead of just near the header.
    let n = tops.len() as f32;
    let mean_i = (n - 1.0) / 2.0;
    let mean_top = tops.iter().sum::<f32>() / n;
    let mut num = 0.0f32;
    let mut den = 0.0f32;
    for (i, &top) in tops.iter().enumerate() {
        let di = i as f32 - mean_i;
        num += di * (top - mean_top);
        den += di * di;
    }
    let row_pitch = num / den;
    let row0_fit = mean_top - mean_i * row_pitch; // fitted band top at index 0

    // A text line's own ink band starts well after its row's background band does — text is
    // vertically centred with room for descenders, not flush with the top — so the two can't be
    // conflated. Measured directly against a real background-colour transition in this crate's
    // video fixture (0.12 was an unvalidated guess and put a cell's top ~11px below the row's
    // true top, enough to crop in a sliver of the row above; harmless against a similar
    // neighbour, but that sliver reads as one false, uniformly-elevated ink value across a
    // strongly-different-coloured neighbour, such as this fixture's red "hostile" row highlight,
    // fusing what should be per-letter runs into one unreadable blob).
    let row_top_pad = row_pitch * 0.26;
    let row0_y = panel.y + (row0_fit - row_top_pad).round() as u32;
    let row_height = row_pitch.round() as u32;

    // `list_bottom` is a backstop, not the primary stopping rule: the list is live (rows can
    // appear as ships warp in — DESIGN.md's `Natasha Etern`/`Nicha vnii srrid` case in this
    // crate's video fixture, absent from frame 0 but present from partway through), so `row.rs`'s
    // per-frame "next row's Name cell is blank" check is what actually ends each frame's read, and
    // must be allowed to see rows beyond frame 0's row count. What this backstop prevents is
    // reading indefinitely into the panel's *empty background below the window*, which is not
    // reliably blank — captured near the panel's own bottom edge, the same near-black colour
    // repeated on both sides of a background transition can leave enough stray contrast to read as
    // a garbage "row" (observed directly in this fixture past its real last row). A generous
    // multiple of the row pitch past the last row frame 0 actually shows is headroom for genuine
    // list growth without opening the door to that.
    let list_bottom = panel.y + row_bands.last().unwrap().1 as u32 + (row_pitch * 6.0) as u32;

    Ok(Layout {
        columns,
        row_height,
        row0_y,
        row_pitch,
        list_bottom: list_bottom.min(panel.y + panel.h),
    })
}

/// Contrast threshold (max-channel deviation from the local median, 0-255) that counts a pixel as
/// ink. Tuned against this crate's fixtures — well above compression noise, comfortably below
/// even the dimmer (unselected-tab-style) header/label text's contrast against its background.
const INK_THRESHOLD: f32 = 40.0;

/// Per-row max-channel deviation from that row's own median colour, for every row of `rect`. A
/// row is "local" because each overview row (and the header/tab strip above it) is one flat
/// background colour across its full width, so a single per-row median is a clean background
/// estimate — unlike one bg/fg pair for the whole multi-coloured panel.
///
/// Vertical lines are left out: vertical runs, at least [`MIN_VLINE_LEN`] tall, of *thin* ink
/// (ink that also contrasts with the pixels [`VLINE_PROBE_PX`] to either side) — e.g. the light
/// border another window draws through a scene panel. Counted in, such a line bridges every gap
/// between text lines and the whole panel reads as one line. Glyphs are far shorter than that,
/// and the edge of a wide area (a row background narrower than `rect`) isn't thin, so both still
/// count as they always did.
fn row_ink_signal(img: &RgbImage, rect: Rect) -> Vec<f32> {
    let (w, h) = (rect.w as usize, rect.h as usize);
    let k = VLINE_PROBE_PX;
    let mut thin = vec![false; w * h];
    let mut diffs: Vec<Vec<f32>> = (0..h)
        .map(|dy| {
            let y = rect.y + dy as u32;
            let med = row_median_color(img, rect.x, y, rect.w);
            let px = |x: usize| img.get_pixel(rect.x + x as u32, y);
            let diff: Vec<f32> = (0..w).map(|x| max_channel_diff(px(x), med)).collect();
            for x in k..w.saturating_sub(k) {
                let c = px(x).0.map(f32::from);
                thin[dy * w + x] = diff[x] >= INK_THRESHOLD
                    && max_channel_diff(px(x - k), c) >= INK_THRESHOLD
                    && max_channel_diff(px(x + k), c) >= INK_THRESHOLD;
            }
            diff
        })
        .collect();
    for x in 0..w {
        let mut y = 0;
        while y < h {
            let run = (y..h).take_while(|&yy| thin[yy * w + x]).count();
            if run >= MIN_VLINE_LEN {
                for row in &mut diffs[y..y + run] {
                    row[x] = 0.0;
                }
            }
            y += run.max(1);
        }
    }
    diffs.iter().map(|row| row.iter().copied().fold(0.0, f32::max)).collect()
}

/// Shortest vertical run (px) of thin ink [`row_ink_signal`] treats as a line rather than a glyph
/// stroke: twice the tallest header/row text band (~23px), and taller than the gap it'd bridge.
const MIN_VLINE_LEN: usize = 48;

/// How far (px) to each side [`row_ink_signal`] looks to tell a thin line from the edge of a wide
/// area: wider than a 2px border resampled by up to [`crate::panel`]'s 1.5x, plus Lanczos ringing.
const VLINE_PROBE_PX: usize = 8;

fn row_median_color(img: &RgbImage, x0: u32, y: u32, w: u32) -> [f32; 3] {
    let mut rs = Vec::with_capacity(w as usize);
    let mut gs = Vec::with_capacity(w as usize);
    let mut bs = Vec::with_capacity(w as usize);
    for x in x0..x0 + w {
        let p = img.get_pixel(x, y).0;
        rs.push(p[0]);
        gs.push(p[1]);
        bs.push(p[2]);
    }
    rs.sort_unstable();
    gs.sort_unstable();
    bs.sort_unstable();
    let mid = (w / 2) as usize;
    [rs[mid] as f32, gs[mid] as f32, bs[mid] as f32]
}

fn max_channel_diff(p: &image::Rgb<u8>, med: [f32; 3]) -> f32 {
    (0..3)
        .map(|c| (p.0[c] as f32 - med[c]).abs())
        .fold(0.0, f32::max)
}

/// Group a line band's ink into word-level x-spans (local to `panel`), using the same
/// intra-word/word-gap distinction `glyph::Font` uses when reading a whole cell. `y0`/`y1` are
/// local to `panel` (as returned in `lines`, from `row_ink_signal`).
fn word_spans(img: &RgbImage, panel: Rect, y0: usize, y1: usize) -> Vec<(usize, usize)> {
    let mut col_ink = vec![0.0f32; panel.w as usize];
    for y in y0..y1 {
        let level = row_median_color(img, panel.x, panel.y + y as u32, panel.w);
        for (x, v) in col_ink.iter_mut().enumerate() {
            let p = img.get_pixel(panel.x + x as u32, panel.y + y as u32);
            *v = v.max(max_channel_diff(p, level));
        }
    }
    let runs = segment::runs(&col_ink, INK_THRESHOLD);
    let mut words: Vec<(usize, usize)> = Vec::new();
    for (x0, x1) in runs {
        match words.last_mut() {
            Some(last) if x0.saturating_sub(last.1) < WORD_GAP_PX => last.1 = x1,
            _ => words.push((x0, x1)),
        }
    }
    words
}

fn match_keyword(text: &str) -> Option<Column> {
    Column::ALL
        .into_iter()
        .find(|col| levenshtein_ci(text, col.keyword()) <= KEYWORD_MAX_DISTANCE)
}

/// Whether a word is a known-but-unwanted header (used only to make intent explicit at call
/// sites / in tests — `detect` itself only ever looks for the required four).
pub fn is_ignored_header_word(text: &str) -> bool {
    IGNORED_HEADER_KEYWORDS
        .iter()
        .any(|kw| levenshtein_ci(text, kw) <= KEYWORD_MAX_DISTANCE)
}
