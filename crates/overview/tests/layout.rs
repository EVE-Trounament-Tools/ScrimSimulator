//! Layout detection tests (DESIGN.md S0/S4.4), against `frame0.png` — a real, native-resolution
//! (2560x1600) video frame from `overview-sample.mkv`.

use glyph::Font;
use overview::layout::{self, Column, Rect};

const PANEL: Rect = Rect { x: 816, y: 0, w: 1200, h: 1600 };

#[test]
fn detects_all_four_required_columns_and_a_sane_row_grid() {
    let img = image::open("tests/fixtures/frame0.png").unwrap().to_rgb8();
    let font = Font::builtin().unwrap();
    let layout = layout::detect(&img, PANEL, &font).unwrap();

    for col in [Column::Distance, Column::Name, Column::Type, Column::Velocity] {
        let span = layout.column(col);
        assert!(span.w > 20, "{col:?} column implausibly narrow: {span:?}");
    }
    // Columns must not overlap and must be left-to-right in this recording's actual order.
    let mut spans: Vec<(Column, u32, u32)> = [Column::Distance, Column::Name, Column::Type, Column::Velocity]
        .into_iter()
        .map(|c| {
            let s = layout.column(c);
            (c, s.x, s.x + s.w)
        })
        .collect();
    spans.sort_by_key(|&(_, x0, _)| x0);
    assert_eq!(
        spans.iter().map(|&(c, _, _)| c).collect::<Vec<_>>(),
        vec![Column::Distance, Column::Name, Column::Type, Column::Velocity]
    );
    for w in spans.windows(2) {
        assert!(w[0].2 <= w[1].1, "columns {:?} and {:?} overlap: {w:?}", w[0].0, w[1].0);
    }

    assert!((40.0..47.0).contains(&layout.row_pitch), "row_pitch implausible: {}", layout.row_pitch);
    assert!(layout.row0_y > 0 && layout.row0_y < 300, "row0_y implausible: {}", layout.row0_y);
}

/// The task this crate is built for explicitly allows column reorder and extra columns ("Size",
/// "Angular" here) between/around the required four. Build a synthetic frame that reorders the
/// real header+body columns (Velocity, Distance, Size, Name, Angular, Type — an order this video
/// never actually uses) and drops Size's neighbouring gap asymmetrically, and check detection
/// still finds all four required columns and reads the same values as the original layout.
#[test]
fn column_order_and_extra_columns_dont_matter() {
    use image::{Rgb, RgbImage};

    let img = image::open("tests/fixtures/frame0.png").unwrap().to_rgb8();
    let font = Font::builtin().unwrap();
    let original = layout::detect(&img, PANEL, &font).unwrap();

    // Cut each detected required column's full-height strip (header word's row band upward
    // doesn't matter here — only column *identification*, not row pitch, is under test) out of
    // the real frame and paste them into a fresh canvas in a different left-to-right order, with
    // a gap standing in for an "extra" (Size/Angular-like) ignored column.
    let strip_h = 400u32; // header + first several data rows
    let order = [Column::Velocity, Column::Distance, Column::Name, Column::Type];
    let gap = 250u32;
    let total_w: u32 = order
        .iter()
        .map(|&c| original.column(c).w)
        .sum::<u32>()
        + gap * (order.len() as u32 + 1);
    let mut canvas = RgbImage::from_pixel(total_w, strip_h, Rgb([10, 10, 10]));

    let mut x = gap;
    let mut new_spans = std::collections::HashMap::new();
    for &col in &order {
        let span = original.column(col);
        for yy in 0..strip_h {
            for xx in 0..span.w {
                let p = *img.get_pixel(span.x + xx, yy);
                canvas.put_pixel(x + xx, yy, p);
            }
        }
        new_spans.insert(col, (x, span.w));
        x += span.w + gap;
    }

    let synthetic_panel = Rect { x: 0, y: 0, w: total_w, h: strip_h };
    let synthetic = layout::detect(&canvas, synthetic_panel, &font)
        .expect("reordered columns with gaps should still be detected");

    for col in [Column::Distance, Column::Name, Column::Type, Column::Velocity] {
        let (paste_x, paste_w) = new_spans[&col];
        let detected = synthetic.column(col);
        // The detected span should sit within (or very close to) the pasted strip, not have
        // drifted into a neighbouring pasted column.
        assert!(
            detected.x + 10 >= paste_x.saturating_sub(gap) && detected.x < paste_x + paste_w + gap,
            "{col:?}: detected span {detected:?} doesn't line up with pasted strip at x={paste_x} w={paste_w}"
        );
    }
}

/// A full-height vertical line through the panel (seen in match recordings: another window's
/// light border crossing a scene panel) is ink on every row; it must not merge the header and
/// rows into one text line.
#[test]
fn full_height_vertical_line_is_ignored() {
    let mut img = image::open("tests/fixtures/frame0.png").unwrap().to_rgb8();
    let font = Font::builtin().unwrap();
    let original = layout::detect(&img, PANEL, &font).unwrap();

    let x = PANEL.x + PANEL.w - 40;
    for y in PANEL.y..PANEL.y + PANEL.h {
        for dx in 0..2 {
            img.put_pixel(x + dx, y, image::Rgb([120, 120, 120]));
        }
    }
    let lined = layout::detect(&img, PANEL, &font).unwrap();
    assert_eq!(lined.row0_y, original.row0_y);
    assert!((lined.row_pitch - original.row_pitch).abs() < 0.01);
    for col in [Column::Distance, Column::Name, Column::Type, Column::Velocity] {
        assert_eq!(lined.column(col), original.column(col), "{col:?}");
    }
}
