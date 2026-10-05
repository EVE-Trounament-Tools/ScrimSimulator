//! One observer's overview panel within a multi-observer OBS scene (DESIGN.md S3.3 "composite
//! crops"), normalised to the scale this crate's pixel thresholds and `glyph`'s templates assume.
//!
//! A scene tiles several clients' overviews into one frame, and nothing forces them to share a UI
//! scale or window size — the match recordings this was written for show three overviews at row
//! pitches of roughly 47, 38 and 35px against the 43.4px everything here was tuned on
//! ([`REF_ROW_PITCH`]). Glyph matching is fixed-size NCC, so instead of making every threshold
//! scale-aware, each panel is cropped and resampled to the reference pitch and the existing
//! single-panel pipeline (`layout::detect`, `row::read_rows`) runs on that crop unchanged.

use crate::layout::{self, Layout, Rect, REF_ROW_PITCH};
use anyhow::{bail, Result};
use glyph::Font;
use image::imageops;
use image::RgbImage;

/// One panel in a scene config: where it sits in the frame, and (once calibrated) the resample
/// factor that brings its rows to [`REF_ROW_PITCH`].
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct PanelSpec {
    /// Observer label used in output (`"A"`, `"B"`, ...).
    pub name: String,
    /// Panel rectangle in frame pixels. Must contain the header row and the row list, and must
    /// stop short of any neighbouring panel (a tab strip below it would read as extra rows).
    pub rect: Rect,
    /// Resample factor; `None` to auto-calibrate on the first frame ([`calibrate`]).
    #[serde(default)]
    pub scale: Option<f32>,
}

/// A whole scene: every observer panel in one recording.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct Scene {
    pub panels: Vec<PanelSpec>,
    /// Where one observer's Local chat window sits in the frame, for matching the recording
    /// against a chat log (`scrim-positions --chat-log`). Not OCR'd by this crate.
    #[serde(default)]
    pub chat: Option<Rect>,
    /// Locked-target blocks: each rect holds one contiguous grid of locked-target brackets
    /// (shield/armor/hull rings) recorded at 1:1, for tracking ship HP — the OBS template uses two
    /// 3x3 grids and one column of two. Not read by this crate yet.
    #[serde(default)]
    pub targets: Vec<Rect>,
}

impl Scene {
    pub fn load(path: impl AsRef<std::path::Path>) -> Result<Scene> {
        let text = std::fs::read_to_string(path)?;
        Ok(serde_json::from_str(&text)?)
    }
}

/// Crop `rect` out of `frame` and resample it by `scale`. Lanczos3: measured against the match
/// fixture, CatmullRom/Triangle blur an upsampled `km` into one run the matcher can't split
/// (several distance cells unreadable at x1.23), while Lanczos3 keeps every cell readable.
pub fn crop_scaled(frame: &RgbImage, rect: Rect, scale: f32) -> RgbImage {
    let crop = imageops::crop_imm(frame, rect.x, rect.y, rect.w, rect.h).to_image();
    if (scale - 1.0).abs() < 1e-3 {
        return crop;
    }
    let w = (rect.w as f32 * scale).round().max(1.0) as u32;
    let h = (rect.h as f32 * scale).round().max(1.0) as u32;
    // `fast_image_resize` (SIMD) rather than `imageops::resize`: same Lanczos3 filter, ~7x less
    // CPU, and identical OCR output on the match fixtures.
    use fast_image_resize as fir;
    let src = fir::images::ImageRef::new(crop.width(), crop.height(), crop.as_raw(), fir::PixelType::U8x3)
        .expect("RgbImage buffer is width*height*3");
    let mut dst = fir::images::Image::new(w, h, fir::PixelType::U8x3);
    let opts = fir::ResizeOptions::new().resize_alg(fir::ResizeAlg::Convolution(fir::FilterType::Lanczos3));
    fir::Resizer::new().resize(&src, &mut dst, &opts).expect("same pixel type in and out");
    RgbImage::from_raw(w, h, dst.into_vec()).expect("U8x3 buffer is w*h*3")
}

fn full_rect(img: &RgbImage) -> Rect {
    Rect { x: 0, y: 0, w: img.width(), h: img.height() }
}

/// Coarse scale sweep for an uncalibrated panel: wide enough to cover any UI-scale/window-size
/// combination plausible in a scene, fine enough that one step lands close enough to the true
/// scale for header OCR (and therefore `layout::detect`) to succeed.
const SWEEP: (f32, f32, f32) = (0.7, 1.5, 0.05);

/// Find `spec`'s resample factor and its layout in that resampled crop. With `spec.scale` set this
/// is just `layout::detect` at that scale; otherwise sweep [`SWEEP`] for the first scale whose
/// header reads, then refine once from the measured row pitch (the row-band fit in `detect` is
/// scale-independent, so one correction lands within a fraction of a pixel of the reference).
pub fn calibrate(frame: &RgbImage, spec: &PanelSpec, font: &Font) -> Result<(f32, Layout)> {
    let detect_at = |scale: f32| {
        let crop = crop_scaled(frame, spec.rect, scale);
        layout::detect(&crop, full_rect(&crop), font)
    };
    if let Some(scale) = spec.scale {
        return Ok((scale, detect_at(scale)?));
    }

    let (lo, hi, step) = SWEEP;
    let mut scale = lo;
    while scale <= hi + 1e-6 {
        if let Ok(coarse) = detect_at(scale) {
            let refined = scale * REF_ROW_PITCH / coarse.row_pitch;
            return match detect_at(refined) {
                Ok(layout) => Ok((refined, layout)),
                Err(_) => Ok((scale, coarse)),
            };
        }
        scale += step;
    }
    bail!(
        "panel {:?}: no scale in {lo}..{hi} found a readable header row in {:?}",
        spec.name,
        spec.rect
    )
}
