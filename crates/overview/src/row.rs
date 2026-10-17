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
/// of the visible list — DESIGN.md S7: "only rows actually rendered can be read").
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
