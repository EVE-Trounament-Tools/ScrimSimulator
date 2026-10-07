//! Read a segmented cell against a trained [`crate::Font`] (DESIGN.md S4.3).
//!
//! Each ink run in the cell is classified against the active alphabet by best-offset NCC
//! (`template::PaddedCell::best_match`). A run whose single best match is unconvincing is also tried as two
//! (or more) touching glyphs — real overview video is compressed with 4:2:0 chroma, which
//! regularly blurs adjacent glyphs into one ink run (`km` -> one run, `rn` fusing into something
//! that scores tolerably as `m`) — so recognition-driven splitting (`classify_span`, below) is
//! not optional polish here, it is what makes those columns readable at all. What's still true is
//! that this stays within one run: it does not merge separate runs, and the result always carries
//! a real confidence rather than a silently wrong high-confidence answer.

use crate::coverage::CoverageMap;
use crate::segment::{self, gaps, split_at_ink_minimum, Span};
use crate::template::{PaddedCell, Template};

/// Which characters are legal in a cell, used to prune the search (DESIGN.md S4.3: "numeric
/// columns use a digit/separator/unit alphabet only — a tiny, closed, high-confidence set").
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Alphabet {
    /// Distance/velocity/angular-velocity columns: digits, thousands separator, decimal point,
    /// minus sign, and the unit letters the overview actually appends (km, m, m/s, AU, rad/s...).
    Numeric,
    /// Name/type/corp/alliance columns: the full trained character set.
    Full,
    /// Pilot-name columns: letters, digits, space, and the punctuation EVE character names
    /// actually use (`-`, `'`, `.`). Narrower than `Full` so look-alike symbol glyphs that never
    /// occur in a name (e.g. `|`, `~`, `#`) can't win a close call against `l`/`I`/`t`.
    Name,
    /// Ship-type (and corp/alliance) columns: same charset as `Name` — this crate has no separate
    /// closed list of ship-type strings to prune against (that's DESIGN.md's SDE fuzzy-match
    /// pass, M2), so the two alphabets are identical for now, kept distinct so a caller's column
    /// mapping reads naturally and the two can diverge later without changing call sites.
    ShipType,
}

impl Alphabet {
    fn allows(self, ch: char) -> bool {
        match self {
            Alphabet::Full => true,
            Alphabet::Numeric => "0123456789,.-kmAUs/".contains(ch),
            Alphabet::Name | Alphabet::ShipType => {
                ch.is_ascii_alphanumeric() || " -'.".contains(ch)
            }
        }
    }
}

/// One classified character, with the winning NCC score and the margin over the runner-up. A
/// small margin means the glyph was genuinely ambiguous (e.g. `l` vs `I`, or a run that actually
/// contained two touching characters).
#[derive(Clone, Debug)]
pub struct CharReading {
    pub ch: char,
    pub score: f32,
    pub margin: f32,
}

/// The result of reading one cell.
#[derive(Clone, Debug)]
pub struct Reading {
    pub text: String,
    pub chars: Vec<CharReading>,
    /// The smallest per-character margin in the reading — a cheap proxy for "how much do I trust
    /// this whole cell". DESIGN.md S4.3: "every cell carries a confidence; low-confidence cells
    /// are dropped, not guessed" is left to the caller, thresholding on this.
    pub confidence: f32,
}

/// How far a template is allowed to slide inside a cell, beyond the natural size difference.
const DX_PAD: usize = 2;
const DY_PAD: usize = 10;

/// Width tolerance (px) for the initial candidate filter — skips obviously-wrong-width templates
/// to keep matching fast. Widened automatically if it would leave zero candidates (a wider- or
/// narrower-than-any-single-glyph run, e.g. touching characters), so a reading is always produced.
const WIDTH_TOLERANCE: i32 = 4;

fn best_two<'a>(templates: &'a [Template], cell: &CoverageMap, alphabet: Alphabet) -> Vec<(f32, &'a Template)> {
    let candidates: Vec<&Template> = templates
        .iter()
        .filter(|t| alphabet.allows(t.ch))
        .collect();

    let narrow: Vec<&Template> = candidates
        .iter()
        .copied()
        .filter(|t| (t.width as i32 - cell.width as i32).abs() <= WIDTH_TOLERANCE)
        .collect();
    let pool = if narrow.is_empty() { candidates } else { narrow };

    let padded = PaddedCell::new(cell, DX_PAD, DY_PAD);
    let mut scored: Vec<(f32, &Template)> = pool
        .into_iter()
        .map(|t| {
            let (score, _dx, _dy) = padded.best_match(t);
            (score, t)
        })
        .collect();
    scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap());
    scored
}

/// A single-glyph match already scoring at least this well is trusted outright — splitting isn't
/// even attempted, so a legitimately wide glyph (`m`, `w`, `@`) is never chopped in two.
///
/// This does mean a touching pair whose best single-glyph interpretation happens to score highly
/// (`best_match` slides the template to whatever offset scores best, so a narrow glyph like `k`
/// can plant itself on just its own slice of a wider `km` run and score deceptively well while
/// leaving the rest of the run's ink unexplained) is trusted too, same as a real single glyph
/// scoring that well — width isn't used to override this, because the reverse mistake is worse:
/// it costs correctly-read single glyphs (`m`, `w`) far more often than it saves misread pairs. A
/// caller reading a value with a closed set of valid trailing units (`crates/overview`'s distance
/// parser, e.g. `"m"`/`"km"`/`"AU"`) is the right place to recover a truncated unit like this
/// `k`-for-`km` case; that context is unavailable here.
const CONFIDENT_SINGLE_SCORE: f32 = 0.90;

/// How much wider (px) than its best single-glyph template a run may be and still have that
/// match trusted outright under [`CONFIDENT_SINGLE_SCORE`]. A run with this much unexplained ink
/// is a fused pair, not one glyph: real video produced `km` read confidently as just `m` (the `m`
/// template sliding onto the right half of a 29px run, scoring 0.96 while ignoring the `k`), a
/// 1000x distance error. Such a run is always tried as a split, and its single-glyph score is
/// discounted by how little of the run the template covers (`classify_span`).
///
/// Numeric cells only: their alphabet has exactly one wide glyph (`m`) and no fused pair that
/// could plausibly be one glyph. On name text the same rule over-splits (`J` -> `I.`, measured
/// against `crates/overview`'s video fixture), so name/type columns keep the old behaviour.
const WIDE_RUN_SLACK: usize = 6;

/// Splitting only wins over the single-glyph reading when it beats it by more than this much,
/// per resulting glyph — otherwise a run that's genuinely one (slightly odd) glyph would flip to
/// a spurious two-glyph reading on noise alone.
const SPLIT_PENALTY: f32 = 0.05;

/// Below this width (px) a piece can't be its own glyph — splitting stops rather than producing
/// slivers no template could plausibly match.
const MIN_GLYPH_WIDTH: usize = 3;

/// How many times a single run may be split (i.e. `2^MAX_SPLITS` glyphs at most from one run).
/// Touching pairs (`km`, `rn`, `tt`, `ff`) only ever need one split; the extra headroom is cheap
/// and guards against a rarer three-glyph fusion without letting the recursion run away.
const MAX_SPLITS: u32 = 2;

/// Classify one run, recognition-driven-splitting it into more than one glyph when that scores
/// better than treating it as a single (possibly touching-glyph-fused) character. See the module
/// doc comment: this is what recovers columns like `28 km` or `Tornado` from a 4:2:0-blurred
/// video frame where compression has visually fused two adjacent glyphs into one ink run.
fn classify_span(
    templates: &[Template],
    cell: &CoverageMap,
    span: Span,
    alphabet: Alphabet,
    splits_left: u32,
) -> Vec<CharReading> {
    let (x0, x1) = span;
    let glyph_cell = cell.slice_cols(x0, x1);
    let scored = best_two(templates, &glyph_cell, alphabet);
    let (top_score, top_ch) = scored.first().map(|&(s, t)| (s, t.ch)).unwrap_or((0.0, '?'));
    let top_width = scored.first().map(|&(_, t)| t.width).unwrap_or(0);
    let second_score = scored.get(1).map(|&(s, _)| s).unwrap_or(-1.0);
    let single = CharReading {
        ch: top_ch,
        score: top_score,
        margin: top_score - second_score,
    };

    let too_wide = alphabet == Alphabet::Numeric && x1 - x0 > top_width + WIDE_RUN_SLACK;
    let confident = top_score >= CONFIDENT_SINGLE_SCORE && !too_wide;
    if splits_left == 0 || confident || x1 - x0 < 2 * MIN_GLYPH_WIDTH {
        return vec![single];
    }

    let mid = split_at_ink_minimum(cell, span);
    if mid <= x0 + MIN_GLYPH_WIDTH || mid + MIN_GLYPH_WIDTH >= x1 {
        return vec![single]; // no interior point splits both pieces to a plausible glyph width
    }

    let left = classify_span(templates, cell, (x0, mid), alphabet, splits_left - 1);
    let right = classify_span(templates, cell, (mid, x1), alphabet, splits_left - 1);
    let n = (left.len() + right.len()) as f32;
    let split_score =
        (left.iter().chain(right.iter()).map(|c| c.score).sum::<f32>()) / n - SPLIT_PENALTY;

    // An over-wide run's single-glyph score only measures the template's own slice of it; scale
    // it by the share of the run the template covers so the unexplained ink counts against it.
    let single_score = if too_wide {
        top_score * top_width as f32 / (x1 - x0) as f32
    } else {
        top_score
    };
    if split_score > single_score {
        let mut combined = left;
        combined.extend(right);
        combined
    } else {
        vec![single]
    }
}

/// Read a full cell: segment it into ink runs, classify each (splitting touching glyphs where
/// that scores better — `classify_span`), and insert spaces at wide gaps.
///
/// `space_gap_px` is the minimum gap (in pixels) between two runs that counts as a word break
/// rather than ordinary inter-glyph spacing.
pub fn read(templates: &[Template], cell: &CoverageMap, alphabet: Alphabet, space_gap_px: usize) -> Reading {
    let runs = segment::blobs(cell, segment::DEFAULT_BLOB_THRESHOLD);
    let run_gaps = gaps(&runs);

    let mut text = String::new();
    let mut chars = Vec::new();
    let mut confidence = f32::INFINITY;

    for (i, &span) in runs.iter().enumerate() {
        if i > 0 && run_gaps[i - 1] >= space_gap_px {
            text.push(' ');
        }
        for reading in classify_span(templates, cell, span, alphabet, MAX_SPLITS) {
            confidence = confidence.min(reading.margin);
            text.push(reading.ch);
            chars.push(reading);
        }
    }

    if runs.is_empty() {
        confidence = 0.0;
    }

    Reading {
        text,
        chars,
        confidence,
    }
}
