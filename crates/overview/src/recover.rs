//! Name rows whose Name cell couldn't be read, from where they sit in a name-sorted overview.
//!
//! Something drawn over an observer's overview (a hover tooltip parked on the Name column) hides
//! a few pilots' names while their Distance, Type and Velocity cells stay readable. Those rows
//! read as junk names that join no roster pilot, so that observer never contributes the pilot's
//! distance and the pilot gets no position at all. Every observer's overview is sorted by Name
//! (`docs/eve/README.md`), so within one frame the readable rows are anchors in alphabetical
//! order, and a run of unreadable rows between two anchors can only be the roster pilots whose
//! names sort between them. When exactly as many such pilots are missing from the frame as there
//! are unreadable rows, they're assigned in order.
//!
//! Nothing is guessed: a frame whose anchors aren't in name order (the overview isn't sorted by
//! name, or a misread joined the wrong pilot) is skipped whole, and a run whose candidate count
//! doesn't match, or whose readable ship type contradicts its candidate, is skipped.

use crate::track::{Sample, CAPSULE};

/// One overview row in one frame of one observer, in on-screen order.
#[derive(Clone, Debug)]
pub struct SlotRow {
    /// The roster pilot this row's track already belongs to, if that pilot is one more than this
    /// observer saw (a track only this observer founded is likely the junk a hidden name reads
    /// as, so it isn't an anchor).
    pub pilot: Option<usize>,
    /// The row's ship type when it read as a known ship (`ShipTypes::resolve`), else `None`.
    pub ship_type: Option<String>,
    pub sample: Sample,
}

/// One roster pilot as recovery sees it.
#[derive(Clone, Debug)]
pub struct Candidate {
    /// The pilot's name; sorted case-insensitively, as the client sorts the overview.
    pub name: String,
    /// Ship types the pilot was seen flying (a Capsule row always agrees).
    pub ship_types: Vec<String>,
}

/// What recovery did for one observer.
#[derive(Debug, Default)]
pub struct Recovery {
    /// Recovered samples per roster pilot (indexed like the `candidates` passed in).
    pub samples: Vec<Vec<Sample>>,
    /// `(frame, row)` of every row recovered, with the pilot it was given.
    pub assigned: Vec<(usize, usize, usize)>,
    /// Frames skipped because their anchors weren't in name order.
    pub frames_out_of_order: usize,
    /// Runs of unreadable rows left unnamed although some pilot was missing there (candidate
    /// count or ship type didn't fit).
    pub runs_skipped: usize,
}

fn sort_key(name: &str) -> String {
    name.to_lowercase()
}

/// Recover one observer's hidden rows. `frames` holds each frame's rows in on-screen order.
pub fn recover(frames: &[Vec<SlotRow>], candidates: &[Candidate]) -> Recovery {
    let keys: Vec<String> = candidates.iter().map(|c| sort_key(&c.name)).collect();
    let mut out = Recovery { samples: vec![Vec::new(); candidates.len()], ..Recovery::default() };
    for (f, rows) in frames.iter().enumerate() {
        let anchors: Vec<(usize, usize)> =
            rows.iter().enumerate().filter_map(|(r, row)| row.pilot.map(|p| (r, p))).collect();
        if anchors.windows(2).any(|w| keys[w[0].1] >= keys[w[1].1]) {
            out.frames_out_of_order += 1;
            continue;
        }
        let seen: Vec<usize> = anchors.iter().map(|&(_, p)| p).collect();

        // Runs of unanchored rows, each with the anchors either side of it (`None` = list edge).
        let mut r = 0;
        while r < rows.len() {
            if rows[r].pilot.is_some() {
                r += 1;
                continue;
            }
            let start = r;
            while r < rows.len() && rows[r].pilot.is_none() {
                r += 1;
            }
            let before = start.checked_sub(1).and_then(|i| rows[i].pilot).map(|p| keys[p].as_str());
            let after = rows.get(r).and_then(|row| row.pilot).map(|p| keys[p].as_str());
            let mut between: Vec<usize> = (0..candidates.len())
                .filter(|p| !seen.contains(p))
                .filter(|&p| before.map_or(true, |b| keys[p].as_str() > b))
                .filter(|&p| after.map_or(true, |a| keys[p].as_str() < a))
                .collect();
            between.sort_by(|&a, &b| keys[a].cmp(&keys[b]));

            let run = &rows[start..r];
            if between.is_empty() {
                continue; // no pilot missing here: stray ink, e.g. below the list's last row
            }
            let fits = between.len() == run.len()
                && run.iter().zip(&between).all(|(row, &p)| agrees(row, &candidates[p]));
            if !fits {
                out.runs_skipped += 1;
                continue;
            }
            for (i, (row, &p)) in run.iter().zip(&between).enumerate() {
                out.samples[p].push(row.sample);
                out.assigned.push((f, start + i, p));
            }
        }
    }
    out
}

/// Whether a row's ship type is consistent with `pilot`: unreadable says nothing, a Capsule is
/// anyone after they're podded, otherwise it must be a ship they were seen in.
fn agrees(row: &SlotRow, pilot: &Candidate) -> bool {
    match row.ship_type.as_deref() {
        None | Some(CAPSULE) => true,
        Some(ty) => pilot.ship_types.is_empty() || pilot.ship_types.iter().any(|s| s == ty),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cand(name: &str, ty: &str) -> Candidate {
        Candidate { name: name.to_string(), ship_types: vec![ty.to_string()] }
    }

    fn row(pilot: Option<usize>, ty: Option<&str>, d: f64) -> SlotRow {
        SlotRow {
            pilot,
            ship_type: ty.map(str::to_string),
            sample: Sample { t: 0.0, distance_m: Some(d), speed_mps: Some(0.0) },
        }
    }

    /// A roster's top, in the client's (case-insensitive) name order.
    fn roster() -> Vec<Candidate> {
        vec![
            cand("1pilot", "Rifter"),
            cand("Alpha One", "Punisher"),
            cand("Alpha Two", "Thrasher"),
            cand("Bravo One", "Ferox"),
            cand("charlie3", "Myrmidon"),
            cand("Delta One", "Hurricane"),
        ]
    }

    #[test]
    fn a_tooltip_run_is_named_in_sort_order() {
        let frame = vec![
            row(Some(0), Some("Rifter"), 1.0),
            row(None, Some("Punisher"), 2.0),
            row(None, Some("Thrasher"), 3.0),
            row(None, None, 4.0),
            row(Some(4), Some("Myrmidon"), 5.0),
            row(Some(5), None, 6.0),
        ];
        let rec = recover(&[frame], &roster());
        assert_eq!(rec.assigned, vec![(0, 1, 1), (0, 2, 2), (0, 3, 3)]);
        assert_eq!(rec.samples[3][0].distance_m, Some(4.0));
        assert_eq!(rec.runs_skipped, 0);
    }

    #[test]
    fn a_run_at_the_list_edge_uses_the_edge_as_its_bound() {
        let frame = vec![row(None, None, 1.0), row(Some(1), None, 2.0)];
        let rec = recover(&[frame], &roster()[..2]);
        assert_eq!(rec.assigned, vec![(0, 0, 0)]);
    }

    #[test]
    fn a_run_with_more_candidates_than_rows_is_left_alone() {
        // Two unreadable rows, three pilots between 1pilot and charlie3: which two is a guess.
        let frame = vec![row(Some(0), None, 1.0), row(None, None, 2.0), row(None, None, 3.0), row(Some(4), None, 4.0)];
        let rec = recover(&[frame], &roster()[..5]);
        assert!(rec.assigned.is_empty());
        assert_eq!(rec.runs_skipped, 1);
    }

    #[test]
    fn a_contradicting_ship_type_rejects_the_run() {
        let frame = vec![row(Some(0), None, 1.0), row(None, Some("Myrmidon"), 2.0), row(Some(2), None, 3.0)];
        let rec = recover(&[frame], &roster()[..3]);
        assert!(rec.assigned.is_empty());
        assert_eq!(rec.runs_skipped, 1);
    }

    #[test]
    fn a_capsule_agrees_with_anyone() {
        let frame = vec![row(Some(0), None, 1.0), row(None, Some(CAPSULE), 2.0), row(Some(2), None, 3.0)];
        let rec = recover(&[frame], &roster()[..3]);
        assert_eq!(rec.assigned, vec![(0, 1, 1)]);
    }

    #[test]
    fn junk_with_no_missing_pilot_is_not_a_skipped_run() {
        let frame = vec![row(Some(0), None, 1.0), row(Some(1), None, 2.0), row(None, None, 3.0)];
        let rec = recover(&[frame], &roster()[..2]);
        assert!(rec.assigned.is_empty());
        assert_eq!(rec.runs_skipped, 0);
    }

    #[test]
    fn a_frame_out_of_name_order_is_skipped() {
        // Sorted by something else (distance): charlie3 above 1pilot.
        let frame = vec![row(Some(4), None, 1.0), row(None, None, 2.0), row(Some(0), None, 3.0)];
        let rec = recover(&[frame], &roster());
        assert!(rec.assigned.is_empty());
        assert_eq!(rec.frames_out_of_order, 1);
    }

    #[test]
    fn sorting_ignores_case() {
        // `nadia` < `Nate Two` < `noble3`, as the client sorts them.
        let roster = vec![cand("nadia one", "Tristan"), cand("Nate Two", "Tristan"), cand("noble3", "Ferox")];
        let frame = vec![row(Some(0), None, 1.0), row(None, None, 2.0), row(Some(2), None, 3.0)];
        let rec = recover(&[frame], &roster);
        assert_eq!(rec.assigned, vec![(0, 1, 1)]);
        assert_eq!(rec.frames_out_of_order, 0);
    }
}
