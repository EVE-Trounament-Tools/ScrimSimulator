//! Overview layout detection, row parsing, and per-pilot tracking (DESIGN.md S4.4).
//!
//! ```no_run
//! use overview::layout::{self, Rect};
//! use overview::{row, track};
//! use glyph::Font;
//!
//! # fn main() -> anyhow::Result<()> {
//! let font = Font::builtin()?;
//! let mut decoder = videoin::Decoder::open("recording.mkv")?;
//! let first = decoder.next_frame()?.expect("at least one frame");
//! let panel = Rect { x: 0, y: 0, w: first.image.width(), h: first.image.height() };
//! let layout = layout::detect(&first.image, panel, &font)?;
//!
//! let mut tracker = track::Tracker::new();
//! tracker.observe(first.t, &row::read_rows(&first.image, &layout, &font));
//! for frame in decoder {
//!     let frame = frame?;
//!     tracker.observe(frame.t, &row::read_rows(&frame.image, &layout, &font));
//! }
//! for t in tracker.finish() {
//!     println!("{}: {:?}, {} samples", t.name, t.ship_type, t.samples.len());
//! }
//! # Ok(()) }
//! ```

pub mod gamelog;
pub mod layout;
pub mod panel;
pub mod plane_exit;
pub mod row;
pub mod ship_types;
pub mod solve;
pub mod targets;
pub mod track;
pub mod util;
pub mod value;
