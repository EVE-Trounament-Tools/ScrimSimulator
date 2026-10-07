//! Glyph templates and normalised cross-correlation (NCC) matching.
//!
//! Each template is cropped to its own line's slab during training (`train.rs`), so heights vary
//! a little line to line. Matching against a cell searches a small window of vertical and
//! horizontal offsets rather than assuming baseline-exact alignment, since a cell's row band (the
//! overview highlight/background stripe) is generally taller than the glyphs it contains and its
//! top does not line up pixel-for-pixel with the training crop.

use crate::coverage::CoverageMap;

#[derive(Clone, Debug)]
pub struct Template {
    pub ch: char,
    pub width: usize,
    pub height: usize,
    /// Row-major coverage values, `[0, 1]`.
    pub data: Vec<f32>,
    /// `data`'s mean, and the sum of squares of `data` minus that mean — the template half of
    /// [`ncc`], computed once here instead of on every offset of every match
    /// ([`PaddedCell::best_match`]).
    mean: f32,
    zero_mean_sq: f32,
}

impl Template {
    pub fn from_coverage(ch: char, cov: &CoverageMap) -> Template {
        let data = cov.data.clone();
        let mean = data.iter().sum::<f32>() / data.len() as f32;
        let zero_mean_sq = data.iter().map(|&v| (v - mean) * (v - mean)).sum();
        Template {
            ch,
            width: cov.width,
            height: cov.height,
            data,
            mean,
            zero_mean_sq,
        }
    }
}

/// Normalised cross-correlation between two equal-sized coverage patches, flattened row-major.
/// Returns a value in roughly `[-1, 1]`; `1` is a perfect match. Patches with (near-)zero
/// variance (e.g. all-background) score `0` rather than `NaN`/`inf`.
pub fn ncc(a: &[f32], b: &[f32]) -> f32 {
    debug_assert_eq!(a.len(), b.len());
    let n = a.len() as f32;
    let mean_a = a.iter().sum::<f32>() / n;
    let mean_b = b.iter().sum::<f32>() / n;
    let mut num = 0.0f32;
    let mut da = 0.0f32;
    let mut db = 0.0f32;
    for i in 0..a.len() {
        let x = a[i] - mean_a;
        let y = b[i] - mean_b;
        num += x * y;
        da += x * x;
        db += y * y;
    }
    let denom = (da * db).sqrt();
    if denom < 1e-6 {
        0.0
    } else {
        num / denom
    }
}

/// Best NCC score (and the offset it occurred at) for `template` against a `cell` region that may
/// be larger than the template in both dimensions. `dx_pad`/`dy_pad` bound how far, beyond the
/// natural size difference, the template is allowed to slide — this absorbs the vertical mismatch
/// between a training crop and a live cell's row band, plus a few pixels of horizontal jitter from
/// segmentation, without letting a small glyph match anywhere in a large cell.
pub fn best_match(
    template: &Template,
    cell: &CoverageMap,
    dx_pad: usize,
    dy_pad: usize,
) -> (f32, i32, i32) {
    let th = template.height as i32;
    let tw = template.width as i32;
    let ch = cell.height as i32;
    let cw = cell.width as i32;

    let y_lo = -(dy_pad as i32);
    let y_hi = ch - th + dy_pad as i32;
    let x_lo = -(dx_pad as i32);
    let x_hi = cw - tw + dx_pad as i32;

    let mut best = f32::NEG_INFINITY;
    let mut best_dx = 0;
    let mut best_dy = 0;

    let mut patch = vec![0.0f32; template.data.len()];
    for dy in y_lo..=y_hi {
        for dx in x_lo..=x_hi {
            for ty in 0..template.height {
                let cy = dy + ty as i32;
                for tx in 0..template.width {
                    let cx = dx + tx as i32;
                    let v = if cy >= 0 && cy < ch && cx >= 0 && cx < cw {
                        cell.get(cx as usize, cy as usize)
                    } else {
                        0.0
                    };
                    patch[ty * template.width + tx] = v;
                }
            }
            let score = ncc(&template.data, &patch);
            if score > best {
                best = score;
                best_dx = dx;
                best_dy = dy;
            }
        }
    }
    (best, best_dx, best_dy)
}

/// A cell prepared once for matching against many templates: zero-padded by the slide window on
/// every side (so out-of-cell pixels read as `0`, exactly as [`best_match`] treats them, with no
/// bounds checks) plus summed-area tables of the values and their squares (so each window's
/// mean/variance is O(1) instead of a pass over the patch).
///
/// NCC's numerator `Σ (t - t̄)(c - c̄)` equals `Σ t·c - t̄ Σc`, and `Σc` is a table lookup, so the
/// only per-pixel work left is `Σ t·c` — over the template's *ink* pixels only, since background
/// pixels (`t = 0`, most of a glyph's slab) contribute nothing to it.
pub struct PaddedCell {
    width: usize,
    height: usize,
    dx_pad: usize,
    dy_pad: usize,
    /// Padded width/height, and the padded values stored *column-major*: the slide window is
    /// much taller (`2 * dy_pad` plus slack) than it is wide, so accumulating down columns gives
    /// the inner loop in [`Self::best_match`] a long contiguous run to vectorise.
    pw: usize,
    ph: usize,
    cols: Vec<f32>,
    /// `(pw + 1) x (ph + 1)` summed-area tables of `data` and `data²`. `f64` so differencing two
    /// large prefix sums leaves no residue on an all-background window.
    sum: Vec<f64>,
    sum_sq: Vec<f64>,
}

impl PaddedCell {
    pub fn new(cell: &CoverageMap, dx_pad: usize, dy_pad: usize) -> PaddedCell {
        let pw = cell.width + 2 * dx_pad;
        let ph = cell.height + 2 * dy_pad;
        let mut data = vec![0.0f32; pw * ph];
        for y in 0..cell.height {
            let at = (y + dy_pad) * pw + dx_pad;
            data[at..at + cell.width].copy_from_slice(cell.row(y));
        }
        let sw = pw + 1;
        let mut sum = vec![0.0f64; sw * (ph + 1)];
        let mut sum_sq = vec![0.0f64; sw * (ph + 1)];
        for y in 0..ph {
            let (mut row, mut row_sq) = (0.0f64, 0.0f64);
            for x in 0..pw {
                let v = data[y * pw + x] as f64;
                row += v;
                row_sq += v * v;
                sum[(y + 1) * sw + x + 1] = sum[y * sw + x + 1] + row;
                sum_sq[(y + 1) * sw + x + 1] = sum_sq[y * sw + x + 1] + row_sq;
            }
        }
        let mut cols = vec![0.0f32; pw * ph];
        for y in 0..ph {
            for x in 0..pw {
                cols[x * ph + y] = data[y * pw + x];
            }
        }
        PaddedCell { width: cell.width, height: cell.height, dx_pad, dy_pad, pw, ph, cols, sum, sum_sq }
    }

    fn window(table: &[f64], sw: usize, x: usize, y: usize, w: usize, h: usize) -> f64 {
        table[(y + h) * sw + x + w] - table[y * sw + x + w] - table[(y + h) * sw + x]
            + table[y * sw + x]
    }

    /// Same result as [`best_match`]`(template, cell, dx_pad, dy_pad)` for the cell and pads this
    /// was built with (up to float rounding), including its tie-break (first best offset in
    /// row-major order) and `NEG_INFINITY` when the template can't be placed at all.
    pub fn best_match(&self, template: &Template) -> (f32, i32, i32) {
        let (tw, th) = (template.width, template.height);
        let span_x = self.width as i32 - tw as i32 + 2 * self.dx_pad as i32 + 1;
        let span_y = self.height as i32 - th as i32 + 2 * self.dy_pad as i32 + 1;
        if span_x <= 0 || span_y <= 0 {
            return (f32::NEG_INFINITY, 0, 0);
        }
        let (nx, ny) = (span_x as usize, span_y as usize);
        debug_assert!(nx + tw - 1 <= self.pw && ny + th - 1 <= self.ph);

        let mut acc = vec![0.0f32; acc_len(self.ph, nx, ny)];
        #[cfg(target_arch = "x86_64")]
        if std::is_x86_feature_detected!("avx2") {
            // SAFETY: the CPU supports AVX2, checked just above.
            unsafe { numerators_avx2(&mut acc, self, template) };
        } else {
            numerators(&mut acc, self, template);
        }
        #[cfg(not(target_arch = "x86_64"))]
        numerators(&mut acc, self, template);

        let n = (tw * th) as f64;
        let sw = self.pw + 1;
        let mut best = f32::NEG_INFINITY;
        let (mut best_dx, mut best_dy) = (0, 0);
        for oy in 0..ny {
            for ox in 0..nx {
                let s = Self::window(&self.sum, sw, ox, oy, tw, th);
                let s2 = Self::window(&self.sum_sq, sw, ox, oy, tw, th);
                let db = (s2 - s * s / n).max(0.0) as f32;
                let denom = (template.zero_mean_sq * db).sqrt();
                let num = acc[ox * self.ph + oy] - template.mean * s as f32;
                let score = if denom < 1e-6 { 0.0 } else { num / denom };
                if score > best {
                    best = score;
                    best_dx = ox as i32 - self.dx_pad as i32;
                    best_dy = oy as i32 - self.dy_pad as i32;
                }
            }
        }
        (best, best_dx, best_dy)
    }
}

/// NCC numerators for every offset at once, laid out like the padded cell's columns
/// (`acc[ox * ph + oy]`, see [`acc_len`]). With that stride, one template pixel's contribution to
/// *every* offset is a single contiguous run of the column-major cell, so the inner loop is one
/// long multiply-add over hundreds of elements rather than many short ones — at the price of also
/// computing `th - 1` unused rows per column, which is far cheaper than the per-run overhead.
#[inline(always)]
fn numerators(acc: &mut [f32], cell: &PaddedCell, template: &Template) {
    let tw = template.width;
    let len = acc.len();
    for ty in 0..template.height {
        for tx in 0..tw {
            let w = template.data[ty * tw + tx];
            if w == 0.0 {
                continue;
            }
            let src = &cell.cols[tx * cell.ph + ty..][..len];
            for (d, &s) in acc.iter_mut().zip(src) {
                *d += w * s;
            }
        }
    }
}

/// Length of [`numerators`]' accumulator: offsets `(ox, oy)` live at `ox * ph + oy`.
fn acc_len(ph: usize, nx: usize, ny: usize) -> usize {
    (nx - 1) * ph + ny
}

/// [`numerators`] compiled for AVX2 (8-wide instead of the baseline's 4-wide SSE2), selected at
/// runtime so release binaries still run on any x86-64. FMA is deliberately not enabled: Rust
/// never contracts `w * s + d` into one, so results stay bit-identical to the baseline path.
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
unsafe fn numerators_avx2(acc: &mut [f32], cell: &PaddedCell, template: &Template) {
    numerators(acc, cell, template)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(width: usize, height: usize, f: impl Fn(usize, usize) -> f32) -> CoverageMap {
        let data = (0..height).flat_map(|y| (0..width).map(move |x| (x, y))).map(|(x, y)| f(x, y));
        CoverageMap { width, height, data: data.collect(), bg: [0; 3], fg: [255; 3] }
    }

    #[test]
    fn padded_cell_matches_reference_best_match() {
        let font = crate::Font::builtin().unwrap();
        // Pseudo-random ink, plus an all-background cell and cells narrower/shorter than glyphs.
        let noise = |seed: usize| {
            move |x: usize, y: usize| {
                let h = (x * 7919 + y * 104_729 + seed * 1_299_709) % 1000;
                if h < 400 { 0.0 } else { h as f32 / 1000.0 }
            }
        };
        let cells = [
            map(14, 37, noise(1)),
            map(30, 37, noise(2)),
            map(5, 20, noise(3)),
            map(12, 37, |_, _| 0.0),
        ];
        for cell in &cells {
            let padded = PaddedCell::new(cell, 2, 10);
            for t in font.templates() {
                let (s0, _, _) = best_match(t, cell, 2, 10);
                let (s1, _, _) = padded.best_match(t);
                if s0 == f32::NEG_INFINITY {
                    assert_eq!(s1, f32::NEG_INFINITY, "{:?}", t.ch);
                    continue;
                }
                assert!((s0 - s1).abs() < 1e-4, "{:?}: {s0} vs {s1}", t.ch);
            }
        }
    }
}
