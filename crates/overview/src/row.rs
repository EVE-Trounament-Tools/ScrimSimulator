//! Read one frame's overview rows against a detected [`crate::layout::Layout`] (DESIGN.md S4.4).

use crate::layout::{Column, Layout};
use crate::value::{parse_distance, parse_scalar, CellValue};
use glyph::{Alphabet, Font, Reading};
use image::RgbImage;

/// One row's four required cells, read and (for the numeric ones) parsed.
#[derive(Clone, Debug)]
pub struct RowReading {
    pub row_index: u32,
    pub distance: CellValue,
    pub name: Reading,
    pub ship_type: Reading,
    pub velocity: CellValue,
}

/// Read every row `layout` has room for in `img`, stopping at the first empty Name cell (the end
/// of the visible list — DESIGN.md S7: "only rows actually rendered can be read"). Faded rows
/// ([`is_faded`]) are skipped: they hold a ship the observer can no longer see.
pub fn read_rows(img: &RgbImage, layout: &Layout, font: &Font) -> Vec<RowReading> {
    read_rows_opts(img, layout, font, false)
}

/// [`read_rows`], but with `keep_blank_names` a blank Name cell only ends the list when the
/// row's Distance cell is unreadable too: a name hidden under something drawn over the overview
/// (a hover tooltip) still has a row under it, which `overview::recover` can name from its slot.
pub fn read_rows_opts(img: &RgbImage, layout: &Layout, font: &Font, keep_blank_names: bool) -> Vec<RowReading> {
    let mut rows = Vec::new();
    let mut i = 0u32;
    while let Some((y, h)) = layout.row_rect(i) {
        // Checked before the Name is read: a faded row's dim name can read blank, which would
        // otherwise end the list there and lose every live row below it.
        let span = layout.column(Column::Name);
        if name_ink(img, span.x, y, span.w, h) == Ink::Faded {
            i += 1;
            continue;
        }
        let name = read_cell(img, layout, Column::Name, y, h, font, Alphabet::Name);
        let distance_r = read_cell(img, layout, Column::Distance, y, h, font, Alphabet::Numeric);
        if name.text.trim().is_empty() && !(keep_blank_names && parse_distance(&distance_r.text).ok().is_some()) {
            break;
        }
        let ship_type = read_cell(img, layout, Column::Type, y, h, font, Alphabet::ShipType);
        let velocity_r = read_cell(img, layout, Column::Velocity, y, h, font, Alphabet::Numeric);

        rows.push(RowReading {
            row_index: i,
            distance: parse_distance(&distance_r.text),
            name,
            ship_type,
            velocity: parse_scalar(&velocity_r.text),
        });
        i += 1;
    }
    rows
}

/// A Name cell whose brightest ink stands out from its background by less than this (max
/// channel, 0-255) is faded. Live rows' text sits 150+ above even a selected row's gray; a
/// faded row's sits ~60 above its dark background.
const FADED_CONTRAST: u8 = 100;

/// Below this contrast the Name cell holds no text at all (past the end of the list, or a name
/// hidden under something drawn over the overview), rather than faded text.
const EMPTY_CONTRAST: u8 = 20;

/// What a Name cell's text looks like.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Ink {
    /// No text: left to the OCR'd Name and Distance to decide whether the list ends here.
    None,
    /// Drawn faded: the client keeps a ship that cloaked, warped off or died in the list for a
    /// while, dimmed and frozen at its last Distance and Velocity. A reappearing ship gets a
    /// fresh, live row of its own, so reading the faded one would pin the pilot to where they
    /// vanished.
    Faded,
    Live,
}

/// Classify the Name cell at `x, y, w, h` by how far its brightest ink stands out from its
/// background.
fn name_ink(img: &RgbImage, x: u32, y: u32, w: u32, h: u32) -> Ink {
    let (x1, y1) = ((x + w).min(img.width()), (y + h).min(img.height()));
    let mut px: Vec<u8> = (y..y1)
        .flat_map(|py| (x..x1).map(move |px| img.get_pixel(px, py).0.into_iter().max().unwrap_or(0)))
        .collect();
    if px.is_empty() {
        return Ink::None;
    }
    px.sort_unstable();
    let bg = px[px.len() / 2];
    // Near the top rather than the very top, so one noisy pixel can't count as ink, yet a short
    // name's few glyphs still do.
    let ink = px[px.len() - 1 - px.len() / 500];
    match ink.saturating_sub(bg) {
        c if c < EMPTY_CONTRAST => Ink::None,
        c if c < FADED_CONTRAST => Ink::Faded,
        _ => Ink::Live,
    }
}

fn read_cell(
    img: &RgbImage,
    layout: &Layout,
    col: Column,
    y: u32,
    h: u32,
    font: &Font,
    alphabet: Alphabet,
) -> Reading {
    let span = layout.column(col);
    font.read_region(img, span.x, y, span.w, h, alphabet)
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgb;

    /// A 160x30 Name cell on `bg`, with a short name's worth of `ink` (two 3x20 strokes).
    fn cell(bg: [u8; 3], ink: [u8; 3]) -> RgbImage {
        let mut img = RgbImage::from_pixel(160, 30, Rgb(bg));
        for x in [10, 14] {
            for dx in 0..3 {
                for y in 5..25 {
                    img.put_pixel(x + dx, y, Rgb(ink));
                }
            }
        }
        img
    }

    #[test]
    fn a_live_row_is_live() {
        assert_eq!(name_ink(&cell([24, 24, 60], [235, 235, 235]), 0, 0, 160, 30), Ink::Live);
    }

    #[test]
    fn a_selected_row_is_live() {
        assert_eq!(name_ink(&cell([94, 94, 94], [244, 244, 244]), 0, 0, 160, 30), Ink::Live);
    }

    #[test]
    fn a_dimmed_row_is_faded() {
        assert_eq!(name_ink(&cell([12, 12, 20], [69, 69, 69]), 0, 0, 160, 30), Ink::Faded);
    }

    #[test]
    fn a_dimmed_selected_row_is_faded() {
        assert_eq!(name_ink(&cell([40, 40, 40], [110, 110, 110]), 0, 0, 160, 30), Ink::Faded);
    }

    #[test]
    fn a_blank_cell_has_no_ink() {
        let img = RgbImage::from_pixel(160, 30, Rgb([12, 12, 20]));
        assert_eq!(name_ink(&img, 0, 0, 160, 30), Ink::None);
    }
}
