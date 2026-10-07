//! Convert an RGB image region into a background/foreground-independent "ink coverage" map.
//!
//! The overview renders anti-aliased text over a handful of flat backgrounds (dark, gray, red,
//! blue, purple — see DESIGN.md S3.2/S4.3). Anti-aliasing is a linear blend between a background
//! colour `bg` and a foreground (glyph) colour `fg`, so for any pixel `p = bg + a*(fg - bg)` we
//! can recover the blend fraction `a` — the "coverage" — by projecting `p - bg` onto `fg - bg`.
//! Coverage is 0 for background, 1 for solid ink, and matches how the training samples are
//! encoded regardless of what colour the cell's background or text actually are.

use image::{Rgb, RgbImage};

/// A `[0, 1]` ink-coverage map for one image region, one value per pixel, row-major.
#[derive(Clone, Debug)]
pub struct CoverageMap {
    pub width: usize,
    pub height: usize,
    pub data: Vec<f32>,
    /// Background colour estimated for this region.
    pub bg: [u8; 3],
    /// Foreground (ink) colour estimated for this region.
    pub fg: [u8; 3],
}

impl CoverageMap {
    pub fn get(&self, x: usize, y: usize) -> f32 {
        self.data[y * self.width + x]
    }

    pub fn row(&self, y: usize) -> &[f32] {
        &self.data[y * self.width..(y + 1) * self.width]
    }

    /// Column-wise max coverage, used for ink-projection segmentation (DESIGN.md S4.3).
    pub fn column_ink(&self) -> Vec<f32> {
        let mut cols = vec![0.0f32; self.width];
        for y in 0..self.height {
            for (x, c) in cols.iter_mut().enumerate() {
                let v = self.get(x, y);
                if v > *c {
                    *c = v;
                }
            }
        }
        cols
    }

    /// Extract the sub-columns `[x0, x1)` as a standalone coverage map (same height).
    pub fn slice_cols(&self, x0: usize, x1: usize) -> CoverageMap {
        let w = x1 - x0;
        let mut data = vec![0.0f32; w * self.height];
        for y in 0..self.height {
            data[y * w..(y + 1) * w].copy_from_slice(&self.row(y)[x0..x1]);
        }
        CoverageMap {
            width: w,
            height: self.height,
            data,
            bg: self.bg,
            fg: self.fg,
        }
    }
}

/// Estimate a region's background colour as the modal pixel colour, tolerating a small amount of
/// compression/encoder noise (e.g. the blue overview background in the fixtures varies by a
/// couple of levels per pixel).
fn modal_bg(img: &RgbImage, x0: u32, y0: u32, w: u32, h: u32) -> [u8; 3] {
    // `BTreeMap`, not `HashMap`: a region with a genuine count tie between two candidate
    // background shades is common (large flat areas), and `HashMap`'s iteration order is
    // randomised per process, so resolving ties by iteration order — as both the bucket-count
    // `max_by_key` below and picking each bucket's representative colour do — would make the
    // detected background (and everything downstream: coverage, segmentation, the read text
    // itself) nondeterministic across runs of the very same binary on the very same image.
    // `BTreeMap` iterates in a fixed key order, making both tie-breaks reproducible.
    use std::collections::BTreeMap;
    let mut counts: BTreeMap<[u8; 3], u32> = BTreeMap::new();
    // Flat backgrounds make long runs of one colour; count a run locally and touch the map once
    // per run rather than once per pixel.
    let mut run: Option<([u8; 3], u32)> = None;
    for y in y0..y0 + h {
        for x in x0..x0 + w {
            let Rgb(p) = *img.get_pixel(x, y);
            match &mut run {
                Some((c, n)) if *c == p => *n += 1,
                _ => {
                    if let Some((c, n)) = run.replace((p, 1)) {
                        *counts.entry(c).or_insert(0) += n;
                    }
                }
            }
        }
    }
    if let Some((c, n)) = run {
        *counts.entry(c).or_insert(0) += n;
    }
    // Quantise to buckets of 4 to merge near-identical background shades before taking the mode.
    let mut bucket_counts: BTreeMap<[u8; 3], u32> = BTreeMap::new();
    let mut bucket_examples: BTreeMap<[u8; 3], [u8; 3]> = BTreeMap::new();
    for (colour, n) in &counts {
        let bucket = [colour[0] / 4, colour[1] / 4, colour[2] / 4];
        *bucket_counts.entry(bucket).or_insert(0) += n;
        bucket_examples.entry(bucket).or_insert(*colour);
    }
    let best_bucket = bucket_counts
        .iter()
        .max_by_key(|(_, &n)| n)
        .map(|(b, _)| *b)
        .unwrap_or([0, 0, 0]);
    bucket_examples
        .get(&best_bucket)
        .copied()
        .unwrap_or([0, 0, 0])
}

/// Estimate the foreground colour as the pixel colour farthest (by Manhattan distance) from `bg`
/// within the region — i.e. the most fully-saturated ink pixel.
fn farthest_fg(img: &RgbImage, x0: u32, y0: u32, w: u32, h: u32, bg: [u8; 3]) -> [u8; 3] {
    let mut best = bg;
    let mut best_dist = 0i32;
    for y in y0..y0 + h {
        for x in x0..x0 + w {
            let Rgb(p) = *img.get_pixel(x, y);
            let dist = (p[0] as i32 - bg[0] as i32).abs()
                + (p[1] as i32 - bg[1] as i32).abs()
                + (p[2] as i32 - bg[2] as i32).abs();
            if dist > best_dist {
                best_dist = dist;
                best = p;
            }
        }
    }
    best
}

/// Compute the coverage map for a region, auto-detecting bg/fg.
pub fn coverage_region(img: &RgbImage, x0: u32, y0: u32, w: u32, h: u32) -> CoverageMap {
    let bg = modal_bg(img, x0, y0, w, h);
    let fg = farthest_fg(img, x0, y0, w, h, bg);
    coverage_region_with_colours(img, x0, y0, w, h, bg, fg)
}

/// Compute the coverage map for a region given known bg/fg colours (used by training, where the
/// sample's colours are fixed and known in advance).
pub fn coverage_region_with_colours(
    img: &RgbImage,
    x0: u32,
    y0: u32,
    w: u32,
    h: u32,
    bg: [u8; 3],
    fg: [u8; 3],
) -> CoverageMap {
    let d = [
        fg[0] as f32 - bg[0] as f32,
        fg[1] as f32 - bg[1] as f32,
        fg[2] as f32 - bg[2] as f32,
    ];
    let denom = (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).max(1e-6);
    let mut data = vec![0.0f32; (w * h) as usize];
    for y in 0..h {
        for x in 0..w {
            let Rgb(p) = *img.get_pixel(x0 + x, y0 + y);
            let v = [
                p[0] as f32 - bg[0] as f32,
                p[1] as f32 - bg[1] as f32,
                p[2] as f32 - bg[2] as f32,
            ];
            let dot = v[0] * d[0] + v[1] * d[1] + v[2] * d[2];
            let a = (dot / denom).clamp(0.0, 1.0);
            data[(y * w + x) as usize] = a;
        }
    }
    CoverageMap {
        width: w as usize,
        height: h as usize,
        data,
        bg,
        fg,
    }
}
