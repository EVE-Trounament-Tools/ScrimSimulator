//! Multi-observer scene test (`overview::panel`): one native-resolution frame of a match
//! recording showing three observers' overviews at three different UI scales. Guards the
//! resample-to-reference-pitch step that lets the single-panel pipeline read all three.
//!
//! The frame shows real pilots, so it is kept local in the git-ignored `resouces/matches/` and
//! the test skips when it is absent (as in CI). Panel rects are in the checked-in scene config.

use overview::layout::REF_ROW_PITCH;
use overview::panel::{calibrate, crop_scaled, Scene};
use overview::row::read_rows;

const SCENE: &str = "tests/fixtures/scene-3panel.json";
const FRAME: &str = "../../resouces/matches/scene-3panel-60s.png";

/// Each panel in the frame lists every pilot on grid; fewer rows means rows were lost.
const MIN_ROWS: usize = 15;

#[test]
fn reads_all_three_observers_at_their_own_scales() {
    let Ok(frame) = image::open(FRAME) else {
        eprintln!("skipped: {FRAME} not present (local-only fixture)");
        return;
    };
    let frame = frame.to_rgb8();
    let scene = Scene::load(SCENE).unwrap();
    let font = glyph::Font::builtin().unwrap();

    for spec in &scene.panels {
        let (scale, layout) = calibrate(&frame, spec, &font).unwrap();
        assert!(
            (layout.row_pitch - REF_ROW_PITCH).abs() < 1.0,
            "panel {}: calibrated pitch {} (scale {scale}) not near reference",
            spec.name,
            layout.row_pitch
        );
        let crop = crop_scaled(&frame, spec.rect, scale);
        let rows = read_rows(&crop, &layout, &font);
        assert!(rows.len() >= MIN_ROWS, "panel {}: only {} rows", spec.name, rows.len());
        for (i, r) in rows.iter().enumerate() {
            assert!(r.distance.ok().is_some(), "panel {} row {i}: distance unread", spec.name);
            assert!(!r.name.text.is_empty(), "panel {} row {i}: name unread", spec.name);
            assert!(!r.ship_type.text.is_empty(), "panel {} row {i}: type unread", spec.name);
        }
    }
}
