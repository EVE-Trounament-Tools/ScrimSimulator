//! Per-pilot identity and time series (DESIGN.md S4.4 "associate rows across ... time by (pilot
//! name, ship type)"), plus the ship-type transition rule this project layers on top of it: a
//! pilot's ship type may only ever change *to* `Capsule` (they got podded); any other change is
//! an OCR mistake, not a real event, and must be flagged rather than accepted. Before that rule
//! ever sees a reading, [`Tracker::observe`] first snaps it to a known ship via
//! [`crate::ship_types::ShipTypes`] (DESIGN.md S4.3's candidate-set fuzzy match), so a truncated
//! or near-miss OCR string (`Tomado`, `Griffin Navy Is`) doesn't masquerade as a type change.

use crate::row::RowReading;
use crate::ship_types::ShipTypes;
use crate::util::levenshtein;
use std::collections::HashMap;

/// A single tick's distance/speed reading for a track (`None` where the cell was unreadable or
/// legitimately blank).
#[derive(Clone, Copy, Debug)]
pub struct Sample {
    pub t: f64,
    pub distance_m: Option<f64>,
    pub speed_mps: Option<f64>,
}

/// A ship-type change other than one into `Capsule` — per the ground rule above, always a
/// misread, never a real observation.
#[derive(Clone, Debug)]
pub struct TypeConflict {
    pub t: f64,
    pub from: String,
    pub read_as: String,
}

pub const CAPSULE: &str = "Capsule";

/// How many of a track's earliest ship-type readings are pooled (majority vote) before the type
/// is considered locked. Guards against a single unlucky first-frame misread being taken as
/// ground truth; DESIGN.md's `Font::read` already scores each glyph highly on this font/scale
/// (see `crates/glyph`), so a small window is enough.
const TYPE_BOOTSTRAP_SAMPLES: usize = 3;

/// One pilot's track: canonical identity plus its distance/speed time series.
#[derive(Clone, Debug)]
pub struct Track {
    /// This track's creation order within its [`Tracker`], unchanged by [`Tracker::finish`]'s
    /// sort, so the ids [`Tracker::observe`] returns still find the track afterwards.
    pub id: usize,
    /// The most-voted-for spelling seen for this pilot's name (OCR noise on a look-alike glyph,
    /// e.g. `l`/`I`, produces minority variants that are folded into this track by
    /// [`Tracker::observe`] but never win the vote outright).
    pub name: String,
    name_votes: HashMap<String, u32>,

    pub ship_type: Option<String>,
    type_bootstrap: Vec<String>,
    type_votes: HashMap<String, u32>,

    pub capsule_events: Vec<f64>,
    /// The ship type locked before the pilot was podded (`ship_type` is `Capsule` from then on),
    /// so callers can still say what the pilot was flying before `capsule_events[0]`.
    pub lost_ship: Option<String>,
    pub type_conflicts: Vec<TypeConflict>,

    pub samples: Vec<Sample>,
}

impl Track {
    /// A track with no samples yet; `id` must be unique among its tracker's (or observer's) tracks.
    pub fn new(id: usize, name: &str) -> Track {
        Track {
            id,
            name: name.to_string(),
            name_votes: HashMap::new(),
            ship_type: None,
            type_bootstrap: Vec::new(),
            type_votes: HashMap::new(),
            capsule_events: Vec::new(),
            lost_ship: None,
            type_conflicts: Vec::new(),
            samples: Vec::new(),
        }
    }

    fn vote_name(&mut self, observed: &str) {
        *self.name_votes.entry(observed.to_string()).or_insert(0) += 1;
        if let Some((best, _)) = self.name_votes.iter().max_by_key(|(_, &n)| n) {
            self.name = best.clone();
        }
    }

    fn observe_type(&mut self, t: f64, observed: &str) {
        if self.ship_type.is_none() {
            self.type_bootstrap.push(observed.to_string());
            if self.type_bootstrap.len() >= TYPE_BOOTSTRAP_SAMPLES {
                self.lock_bootstrap_type();
            }
            return;
        }
        let current = self.ship_type.as_deref().unwrap();
        if observed == current {
            return;
        }
        if observed == CAPSULE {
            self.capsule_events.push(t);
            self.lost_ship = Some(current.to_string());
            self.ship_type = Some(CAPSULE.to_string());
        } else {
            self.type_conflicts.push(TypeConflict {
                t,
                from: current.to_string(),
                read_as: observed.to_string(),
            });
        }
    }

    fn lock_bootstrap_type(&mut self) {
        for ty in self.type_bootstrap.drain(..) {
            *self.type_votes.entry(ty).or_insert(0) += 1;
        }
        let winner = self
            .type_votes
            .iter()
            .max_by_key(|(_, &n)| n)
            .map(|(ty, _)| ty.clone())
            .expect("bootstrap only locks once at least one type was observed");
        self.ship_type = Some(winner);
    }

    /// Lock in whatever ship type has been observed so far, even if fewer than
    /// `TYPE_BOOTSTRAP_SAMPLES` readings arrived (a track that ends early — e.g. the pilot leaves
    /// grid — must not sit forever unlocked). Idempotent once already locked.
    pub fn finalize(&mut self) {
        if self.ship_type.is_none() && !self.type_bootstrap.is_empty() {
            self.lock_bootstrap_type();
        }
    }
}

/// Clusters per-frame [`RowReading`]s into per-pilot [`Track`]s across a video.
pub struct Tracker {
    tracks: Vec<Track>,
    ship_types: ShipTypes,
}

/// Max case-sensitive edit distance between an incoming name reading and a track's current
/// canonical name for it to still count as the same pilot. `1` absorbs a single misread glyph
/// (the `l`/`I` confusion documented in `crates/glyph`'s golden tests) without risking merging two
/// genuinely different short names.
const FUZZY_NAME_DISTANCE: usize = 1;

impl Tracker {
    pub fn new() -> Tracker {
        Tracker::with_ship_types(ShipTypes::builtin())
    }

    /// Like [`Tracker::new`], but against an arbitrary ship-type candidate set (tests, or a
    /// future non-bundled source) instead of the one bundled into this crate.
    pub fn with_ship_types(ship_types: ShipTypes) -> Tracker {
        Tracker { tracks: Vec::new(), ship_types }
    }

    /// Feed one frame's row readings in at time `t` (seconds). Returns the id of the track each
    /// row went to, aligned with `rows` (`None` for a row with a blank Name cell).
    pub fn observe(&mut self, t: f64, rows: &[RowReading]) -> Vec<Option<usize>> {
        let mut ids = Vec::with_capacity(rows.len());
        for row in rows {
            let name = row.name.text.trim();
            if name.is_empty() {
                ids.push(None);
                continue;
            }
            // Resolved before indexing into `self.tracks` so the two `self` fields don't need to
            // be borrowed at the same time.
            let ship_type = row.ship_type.text.trim();
            let canonical_type =
                (!ship_type.is_empty()).then(|| self.ship_types.canonicalize(ship_type).to_string());

            let idx = self.find_or_create(name);
            let track = &mut self.tracks[idx];
            track.vote_name(name);
            if let Some(canonical_type) = canonical_type {
                track.observe_type(t, &canonical_type);
            }
            track.samples.push(Sample {
                t,
                distance_m: row.distance.ok(),
                speed_mps: row.velocity.ok(),
            });
            ids.push(Some(track.id));
        }
        ids
    }

    fn find_or_create(&mut self, name: &str) -> usize {
        if let Some(i) = self.tracks.iter().position(|tr| tr.name == name) {
            return i;
        }
        let mut best: Option<(usize, usize)> = None;
        for (i, tr) in self.tracks.iter().enumerate() {
            let d = levenshtein(&tr.name, name);
            if d <= FUZZY_NAME_DISTANCE && best.map(|(_, bd)| d < bd).unwrap_or(true) {
                best = Some((i, d));
            }
        }
        if let Some((i, _)) = best {
            return i;
        }
        self.tracks.push(Track::new(self.tracks.len(), name));
        self.tracks.len() - 1
    }

    /// Finish tracking: lock any still-bootstrapping ship types and return the finished tracks,
    /// sorted by name for stable output.
    pub fn finish(mut self) -> Vec<Track> {
        for t in &mut self.tracks {
            t.finalize();
        }
        self.tracks.sort_by(|a, b| a.name.cmp(&b.name));
        self.tracks
    }
}

impl Default for Tracker {
    fn default() -> Self {
        Tracker::new()
    }
}

/// Flag samples whose value is a spike relative to its neighbours: DESIGN.md S4.3 "OCR misreads
/// are isolated spikes in an otherwise smooth signal, so a Hampel/median filter removes them".
/// Returns one bool per input value (aligned 1:1, `None` inputs are never flagged).
///
/// `window` is the number of neighbours considered on each side; `n_sigmas` scales the MAD-based
/// threshold (mirroring a standard-deviation multiple for a robust estimator).
pub fn hampel_flags(values: &[Option<f64>], window: usize, n_sigmas: f64) -> Vec<bool> {
    let mut flags = vec![false; values.len()];
    for i in 0..values.len() {
        let Some(v) = values[i] else { continue };
        let lo = i.saturating_sub(window);
        let hi = (i + window + 1).min(values.len());
        let mut neighbourhood: Vec<f64> = (lo..hi).filter_map(|j| values[j]).collect();
        if neighbourhood.len() < 3 {
            continue; // not enough context to judge
        }
        neighbourhood.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let median = neighbourhood[neighbourhood.len() / 2];
        let mut abs_dev: Vec<f64> = neighbourhood.iter().map(|x| (x - median).abs()).collect();
        abs_dev.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let mad = abs_dev[abs_dev.len() / 2];
        let sigma = 1.4826 * mad;
        if sigma > 0.0 && (v - median).abs() > n_sigmas * sigma {
            flags[i] = true;
        }
    }
    flags
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::value::CellValue;
    use glyph::{CharReading, Reading};

    fn reading(text: &str) -> Reading {
        Reading {
            text: text.to_string(),
            chars: vec![CharReading {
                ch: 'x',
                score: 1.0,
                margin: 1.0,
            }],
            confidence: 1.0,
        }
    }

    fn row(name: &str, ty: &str, distance_m: f64, speed: f64) -> RowReading {
        RowReading {
            row_index: 0,
            distance: CellValue::Value(distance_m),
            name: reading(name),
            ship_type: reading(ty),
            velocity: CellValue::Value(speed),
        }
    }

    fn locked_track(ty: &str) -> Track {
        let mut tr = Track::new(0, "Pilot");
        for t in 0..TYPE_BOOTSTRAP_SAMPLES {
            tr.observe_type(t as f64, ty);
        }
        tr
    }

    #[test]
    fn tornado_to_capsule_is_accepted_as_a_loss() {
        let mut tr = locked_track("Tornado");
        tr.observe_type(10.0, CAPSULE);
        assert_eq!(tr.ship_type.as_deref(), Some(CAPSULE));
        assert_eq!(tr.capsule_events, vec![10.0]);
        assert_eq!(tr.lost_ship.as_deref(), Some("Tornado"));
        assert!(tr.type_conflicts.is_empty());
    }

    #[test]
    fn tornado_to_tomado_is_a_conflict_not_a_change() {
        let mut tr = locked_track("Tornado");
        tr.observe_type(5.0, "Tomado"); // e.g. an rn/m misread
        assert_eq!(tr.ship_type.as_deref(), Some("Tornado"));
        assert_eq!(tr.type_conflicts.len(), 1);
    }

    #[test]
    fn tornado_to_badger_is_a_conflict_not_a_change() {
        let mut tr = locked_track("Tornado");
        tr.observe_type(5.0, "Badger");
        assert_eq!(tr.ship_type.as_deref(), Some("Tornado"));
        assert_eq!(tr.type_conflicts.len(), 1);
    }

    #[test]
    fn capsule_to_tornado_is_a_conflict_the_pilot_stays_podded() {
        let mut tr = locked_track(CAPSULE);
        tr.observe_type(5.0, "Tornado");
        assert_eq!(tr.ship_type.as_deref(), Some(CAPSULE));
        assert_eq!(tr.type_conflicts.len(), 1);
    }

    #[test]
    fn look_alike_name_variants_merge_into_one_track() {
        let mut tracker = Tracker::new();
        tracker.observe(0.0, &[row("Kyle Katarn", "Catalyst", 100.0, 0.0)]);
        tracker.observe(1.0, &[row("KyIe Katarn", "Catalyst", 100.0, 0.0)]); // l -> I misread
        tracker.observe(2.0, &[row("Kyle Katarn", "Catalyst", 100.0, 0.0)]);
        let tracks = tracker.finish();
        assert_eq!(tracks.len(), 1, "expected the l/I variant to merge, not open a new track");
        assert_eq!(tracks[0].name, "Kyle Katarn", "majority spelling should win");
        assert_eq!(tracks[0].samples.len(), 3);
    }

    #[test]
    fn near_miss_type_readings_lock_the_real_ship_with_no_conflict() {
        let mut tracker = Tracker::new();
        // "Tornaco" is a single-glyph (c/d) misread of "Tornado"; canonicalizing before
        // `observe_type` means the bootstrap votes for one real ship instead of splitting between
        // a real spelling and a fake one.
        tracker.observe(0.0, &[row("Pilot", "Tornaco", 100.0, 0.0)]);
        tracker.observe(1.0, &[row("Pilot", "Tornado", 100.0, 0.0)]);
        tracker.observe(2.0, &[row("Pilot", "Tornaco", 100.0, 0.0)]);
        let tracks = tracker.finish();
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].ship_type.as_deref(), Some("Tornado"));
        assert!(tracks[0].type_conflicts.is_empty());
    }

    #[test]
    fn truncated_type_reading_canonicalizes_to_the_full_name() {
        let mut tracker = Tracker::new();
        tracker.observe(0.0, &[row("Pilot", "Griffin Navy Is", 100.0, 0.0)]);
        let track = &tracker.finish()[0];
        assert_eq!(track.ship_type.as_deref(), Some("Griffin Navy Issue"));
    }

    #[test]
    fn distinct_names_do_not_merge() {
        let mut tracker = Tracker::new();
        tracker.observe(0.0, &[row("Jax Sunder", "Hawk", 1000.0, 0.0)]);
        tracker.observe(0.0, &[row("Kenneth McArt", "Corax", 2000.0, 0.0)]);
        // Two names further apart than the single-glyph-misread tolerance must land in two
        // distinct tracks, not merge into one.
        let tracks = tracker.finish();
        assert_eq!(tracks.len(), 2);
    }

    #[test]
    fn hampel_flags_an_isolated_spike() {
        let values: Vec<Option<f64>> = vec![100.0, 101.0, 99.0, 5000.0, 100.0, 102.0, 98.0]
            .into_iter()
            .map(Some)
            .collect();
        let flags = hampel_flags(&values, 3, 3.0);
        assert_eq!(flags, vec![false, false, false, true, false, false, false]);
    }
}
