//! Which way a ship leaves the observers' plane when the distances can't tell.
//!
//! Three distances fix a ship only up to its reflection through the plane the observers sit in
//! ([`crate::solve`]). A ship that crosses the plane briskly is followed by the track's
//! continuity: its mirror would have to bounce off the plane. But a ship that grazes the plane,
//! or flies in it, can leave toward either side, and everything after could be mirrored without
//! changing a single distance or speed. [`resolve`] makes that choice deterministic: each such
//! exit turns **clockwise** unless the match gives evidence against it, and the tail up to the
//! next exit is put on the chosen side.
//!
//! Clockwise and counterclockwise are seen from the ship's right side with the plane's normal
//! `n = (B − A) × (C − A)` (observers A, B, C) as up: clockwise dips the nose below the plane, so
//! the ship leaves toward `−n`; counterclockwise leaves toward `+n`.

use crate::solve::{cross, dist, dot, norm, outside_cube_m, scale, sub, Fix, V3, CUBE_M};

/// Half-width of the band around the plane in which the out-of-plane coordinate is too blurred
/// by the distances' 1 km rounding to say which side a ship is on.
pub const GRAZE_M: f64 = 3_000.0;
/// A stretch in the band whose normal speed is below this is a graze, not a crossing: its mirror
/// needs only a gentle turn, so either side fits.
pub const GRAZE_NORMAL_MPS: f64 = 150.0;
/// Seconds either side of a band stretch its normal speed is fitted over...
const NORMAL_WINDOW_S: f64 = 3.0;
/// ...and before it, the incoming normal speed (the crossing-fit evidence).
const INCOMING_WINDOW_S: f64 = 5.0;

/// Evidence points against a branch: counterclockwise wins only by at least this much.
pub const DECISION_MARGIN: f64 = 1.0;
/// Points for a branch that has a ship outside the cube before the match starts.
const START_POINTS: f64 = 10.0;
/// How far outside the cube that must be (beyond the rounding).
const START_SLACK_M: f64 = 2_000.0;
/// Arena boundary: pilots further than this from the cube centre are out of bounds.
pub const BOUNDARY_RADIUS_M: f64 = 125_000.0;
/// A branch is only counted outside the boundary this far past it (a scrape proves nothing)...
const BOUNDARY_SLACK_M: f64 = 5_000.0;
/// ...for at least this long...
const BOUNDARY_MIN_S: f64 = 5.0;
/// ...and then only if the same (non-capsule) hull comes back inside: a ship can linger outside
/// before it is removed, so going out and never coming back is not evidence.
const BOUNDARY_POINTS: f64 = 10.0;
/// Most points the crossing fit gives (for incoming normal speed of [`GRAZE_NORMAL_MPS`] or more).
const CROSSING_POINTS: f64 = 2.0;
/// Usual warp scrambler and disruptor ranges (overheated faction modules, with some margin).
pub const SCRAM_RANGE_M: f64 = 15_000.0;
pub const DISRUPT_RANGE_M: f64 = 40_000.0;
/// Hulls with bonused points (heavy interdictors, Arazu/Lachesis, Keres) and their ranges.
pub const LONG_POINT_HULLS: &[&str] = &["Onyx", "Broadsword", "Devoter", "Phobos", "Arazu", "Lachesis", "Keres"];
pub const LONG_SCRAM_RANGE_M: f64 = 45_000.0;
pub const LONG_DISRUPT_RANGE_M: f64 = 90_000.0;
/// Separation allowed past a point's range (positions are a few km off near the plane).
const SCRAM_SLACK_M: f64 = 3_000.0;
/// Points per km of separation past that, and the most one event can give.
const SCRAM_POINTS_PER_KM: f64 = 1.0;
const SCRAM_MAX_POINTS: f64 = 5.0;
/// The other pilot's fix must be this close in time to a scram for it to count.
const SCRAM_MAX_DT_S: f64 = 2.0;

/// The observers' plane: `n·p = d`, `n` a unit vector.
#[derive(Clone, Copy, Debug)]
pub struct Plane {
    pub n: V3,
    pub d: f64,
}

impl Plane {
    /// The plane through observers A, B, C, with `n = (B − A) × (C − A)` normalised.
    pub fn from_observers(obs: [V3; 3]) -> Plane {
        let c = cross(sub(obs[1], obs[0]), sub(obs[2], obs[0]));
        let n = scale(c, 1.0 / norm(c));
        Plane { n, d: dot(n, obs[0]) }
    }

    /// Signed distance of `p` from the plane (positive on the `+n` side).
    pub fn offset(&self, p: V3) -> f64 {
        dot(self.n, p) - self.d
    }

    /// `p` mirrored through the plane.
    pub fn reflect(&self, p: V3) -> V3 {
        sub(p, scale(self.n, 2.0 * self.offset(p)))
    }
}

/// Which way a ship turned leaving the plane.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Turn {
    /// Toward `−n`; the default.
    Cw,
    /// Toward `+n`.
    Ccw,
}

impl Turn {
    pub fn as_str(self) -> &'static str {
        match self {
            Turn::Cw => "cw",
            Turn::Ccw => "ccw",
        }
    }

    /// The side of the plane (sign of the offset) this turn leaves toward.
    fn side(self) -> f64 {
        match self {
            Turn::Cw => -1.0,
            Turn::Ccw => 1.0,
        }
    }
}

/// One ambiguous exit and how it was settled.
#[derive(Clone, Debug)]
pub struct Exit {
    /// Index of the fix nearest the plane; the tail starts after it.
    pub idx: usize,
    /// Index one past the tail's last fix (the next exit's `idx + 1`, or the track's end).
    pub end: usize,
    pub t: f64,
    pub turn: Turn,
    /// Evidence against clockwise that made it counterclockwise (empty for a default).
    pub reasons: Vec<String>,
}

/// One pilot's solved track and, per fix, whether the pilot was in a capsule.
pub struct PilotTrack {
    pub fixes: Vec<Fix>,
    pub capsule: Vec<bool>,
}

/// A warp scramble or disruption attempt from one pilot (index into the tracks) on another, at
/// match time `t` (the CSV's `t`). `source_ship` is the attacker's hull as the log shows it.
#[derive(Clone, Debug)]
pub struct Scram {
    pub t: f64,
    pub source: usize,
    pub target: usize,
    pub disruption: bool,
    pub source_ship: String,
}

/// Range of a point fitted to `ship`.
pub fn point_range_m(disruption: bool, ship: &str) -> f64 {
    let long = LONG_POINT_HULLS.iter().any(|h| h.eq_ignore_ascii_case(ship.trim()));
    match (disruption, long) {
        (false, false) => SCRAM_RANGE_M,
        (true, false) => DISRUPT_RANGE_M,
        (false, true) => LONG_SCRAM_RANGE_M,
        (true, true) => LONG_DISRUPT_RANGE_M,
    }
}

/// Least-squares slope of the plane offset against time over `fixes[lo..hi]`; 0 with fewer than
/// two distinct times.
fn offset_slope(plane: &Plane, fixes: &[Fix]) -> f64 {
    let n = fixes.len() as f64;
    if fixes.len() < 2 {
        return 0.0;
    }
    let mt = fixes.iter().map(|f| f.t).sum::<f64>() / n;
    let ms = fixes.iter().map(|f| plane.offset(f.p)).sum::<f64>() / n;
    let stt: f64 = fixes.iter().map(|f| (f.t - mt).powi(2)).sum();
    if stt <= 0.0 {
        return 0.0;
    }
    fixes.iter().map(|f| (f.t - mt) * (plane.offset(f.p) - ms)).sum::<f64>() / stt
}

/// Fixes within `[t0, t1]`, as an index range.
fn span(fixes: &[Fix], t0: f64, t1: f64) -> std::ops::Range<usize> {
    let lo = fixes.partition_point(|f| f.t < t0);
    let hi = fixes.partition_point(|f| f.t <= t1);
    lo..hi.max(lo)
}

/// The ambiguous exits of a track. For each maximal stretch of fixes within [`GRAZE_M`] of the
/// plane that the track leaves again, the exit is its fix that is nearest the plane and slowest
/// across it (normal speed fitted over [`NORMAL_WINDOW_S`] either side). The stretch is ambiguous
/// when that speed is below [`GRAZE_NORMAL_MPS`]: a brisk crossing is not. A stretch the track
/// starts in counts too (which side it leaves for is a coin flip as well); one it ends in doesn't
/// (there's no tail to place).
pub fn find_exits(plane: &Plane, fixes: &[Fix]) -> Vec<usize> {
    let slope_at = |i: usize| offset_slope(plane, &fixes[span(fixes, fixes[i].t - NORMAL_WINDOW_S, fixes[i].t + NORMAL_WINDOW_S)]);
    let mut out = Vec::new();
    let mut i = 0;
    while i < fixes.len() {
        if plane.offset(fixes[i].p).abs() >= GRAZE_M {
            i += 1;
            continue;
        }
        let start = i;
        while i < fixes.len() && plane.offset(fixes[i].p).abs() < GRAZE_M {
            i += 1;
        }
        if i == fixes.len() {
            break;
        }
        let score = |k: usize| plane.offset(fixes[k].p).abs() / GRAZE_M + slope_at(k).abs() / GRAZE_NORMAL_MPS;
        let idx = (start..i).min_by(|&a, &b| score(a).total_cmp(&score(b))).unwrap();
        if slope_at(idx).abs() < GRAZE_NORMAL_MPS {
            out.push(idx);
        }
    }
    out
}

/// The side (±1) a tail is on: the sign of the offset of its first fix out of the band.
fn tail_side(plane: &Plane, tail: &[Fix]) -> f64 {
    tail.iter()
        .map(|f| plane.offset(f.p))
        .find(|s| s.abs() >= GRAZE_M)
        .map_or(1.0, f64::signum)
}

/// Settle every pilot's ambiguous exits (see the module docs) and put each tail on its side.
///
/// `match_start` is the match time the match starts (the first tick any ship moves); before it,
/// every ship is inside the cube. Tails are decided without `scrams` first, then again with them,
/// measuring each scram against the other pilot's positions from the first pass.
pub fn resolve(plane: &Plane, tracks: &mut [PilotTrack], scrams: &[Scram], match_start: f64) -> Vec<Vec<Exit>> {
    let exits: Vec<Vec<usize>> = tracks.iter().map(|t| find_exits(plane, &t.fixes)).collect();
    let mut result = Vec::new();
    for with_scrams in [false, true] {
        let others: Vec<Vec<Fix>> = tracks.iter().map(|t| t.fixes.clone()).collect();
        let scrams = if with_scrams { scrams } else { &[] };
        result = tracks
            .iter_mut()
            .enumerate()
            .map(|(pilot, track)| {
                let idxs = &exits[pilot];
                idxs.iter()
                    .enumerate()
                    .map(|(k, &idx)| {
                        let end = idxs.get(k + 1).map_or(track.fixes.len(), |&next| next + 1);
                        settle(plane, track, pilot, idx, end, scrams, &others, match_start)
                    })
                    .collect()
            })
            .collect();
    }
    result
}

/// Decide one exit's tail (`fixes[idx + 1..end]`) and mirror it onto the chosen side.
#[allow(clippy::too_many_arguments)]
fn settle(
    plane: &Plane,
    track: &mut PilotTrack,
    pilot: usize,
    idx: usize,
    end: usize,
    scrams: &[Scram],
    others: &[Vec<Fix>],
    match_start: f64,
) -> Exit {
    let fixes = &track.fixes;
    let tail = idx + 1..end;
    let current = tail_side(plane, &fixes[tail.clone()]);
    let branch = |turn: Turn| -> Vec<Fix> {
        fixes[tail.clone()]
            .iter()
            .map(|f| if turn.side() == current { *f } else { Fix { p: plane.reflect(f.p), ..*f } })
            .collect()
    };
    let t_idx = fixes[idx].t;
    let before = span(fixes, t_idx - INCOMING_WINDOW_S, t_idx);
    let incoming = if before.start < idx { offset_slope(plane, &fixes[before]) } else { 0.0 };
    let capsule = &track.capsule[tail.clone()];
    let cost = |turn: Turn| {
        evidence(&branch(turn), capsule, turn, incoming, pilot, scrams, others, match_start)
    };
    let (cw, ccw) = (cost(Turn::Cw), cost(Turn::Ccw));
    let cw_total: f64 = cw.iter().map(|e| e.0).sum();
    let ccw_total: f64 = ccw.iter().map(|e| e.0).sum();
    let turn = if cw_total - ccw_total >= DECISION_MARGIN { Turn::Ccw } else { Turn::Cw };
    if turn.side() != current {
        for f in &mut track.fixes[tail] {
            f.p = plane.reflect(f.p);
        }
    }
    let reasons = match turn {
        Turn::Cw => Vec::new(),
        Turn::Ccw => cw.into_iter().map(|(pts, why)| format!("{why} ({pts:.1})")).collect(),
    };
    Exit { idx, end, t: t_idx, turn, reasons }
}

/// Evidence against a branch: `(points, what)` per finding.
#[allow(clippy::too_many_arguments)]
fn evidence(
    tail: &[Fix],
    capsule: &[bool],
    turn: Turn,
    incoming: f64,
    pilot: usize,
    scrams: &[Scram],
    others: &[Vec<Fix>],
    match_start: f64,
) -> Vec<(f64, String)> {
    let mut out = Vec::new();
    if let Some(f) = tail.iter().find(|f| f.t < match_start && outside_cube_m(f.p) > START_SLACK_M) {
        out.push((START_POINTS, format!("outside the cube before the start at t={:.0}", f.t)));
    }
    if let Some(t) = boundary_reentry(tail, capsule) {
        out.push((BOUNDARY_POINTS, format!("out of bounds and back at t={t:.0}")));
    }
    // Crossing fit: the branch that turns back the way the ship came in.
    if incoming * turn.side() < 0.0 {
        let pts = CROSSING_POINTS * (incoming.abs() / GRAZE_NORMAL_MPS).min(1.0);
        if pts > 0.0 {
            out.push((pts, format!("came in at {:.0} m/s toward the other side", incoming.abs())));
        }
    }
    let (t0, t1) = match (tail.first(), tail.last()) {
        (Some(a), Some(b)) => (a.t, b.t),
        _ => return out,
    };
    for s in scrams.iter().filter(|s| s.t >= t0 && s.t <= t1 && s.source != s.target) {
        let other = match (s.source == pilot, s.target == pilot) {
            (true, false) => s.target,
            (false, true) => s.source,
            _ => continue,
        };
        let (Some(me), Some(them)) = (nearest(tail, s.t), nearest(&others[other], s.t)) else { continue };
        let limit = point_range_m(s.disruption, &s.source_ship) + SCRAM_SLACK_M;
        let over = dist(me.p, them.p) - limit;
        if over > 0.0 {
            let pts = (over / 1000.0 * SCRAM_POINTS_PER_KM).min(SCRAM_MAX_POINTS);
            let kind = if s.disruption { "disruption" } else { "scramble" };
            out.push((pts, format!("warp {kind} {:.0} km out of range at t={:.0}", over / 1000.0, s.t)));
        }
    }
    out
}

/// The fix nearest `t`, if within [`SCRAM_MAX_DT_S`].
fn nearest(fixes: &[Fix], t: f64) -> Option<&Fix> {
    fixes.iter().filter(|f| (f.t - t).abs() <= SCRAM_MAX_DT_S).min_by(|a, b| (a.t - t).abs().total_cmp(&(b.t - t).abs()))
}

/// The time a branch brings the ship back inside the boundary after at least [`BOUNDARY_MIN_S`]
/// more than [`BOUNDARY_SLACK_M`] outside it, in the same non-capsule hull; None if it never does.
fn boundary_reentry(tail: &[Fix], capsule: &[bool]) -> Option<f64> {
    let centre = [CUBE_M / 2.0; 3];
    let mut out_since: Option<f64> = None;
    for (f, &pod) in tail.iter().zip(capsule) {
        if pod {
            return None;
        }
        let r = dist(f.p, centre);
        if r > BOUNDARY_RADIUS_M + BOUNDARY_SLACK_M {
            out_since.get_or_insert(f.t);
        } else if r <= BOUNDARY_RADIUS_M {
            if out_since.is_some_and(|t| f.t - t >= BOUNDARY_MIN_S) {
                return Some(f.t);
            }
            out_since = None;
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::solve::{add, corners};

    fn fix(t: f64, p: V3) -> Fix {
        Fix { t, p, residual_m: 0.0 }
    }

    /// A path through `points` (km) at one fix per second, `secs[k]` seconds per leg.
    fn path(points: &[V3], secs: &[usize]) -> Vec<Fix> {
        let mut out = Vec::new();
        let mut t = 0.0;
        for (k, n) in secs.iter().enumerate() {
            let (a, b) = (scale(points[k], 1000.0), scale(points[k + 1], 1000.0));
            for i in 0..*n {
                let w = i as f64 / *n as f64;
                out.push(fix(t, add(a, scale(sub(b, a), w))));
                t += 1.0;
            }
        }
        out.push(fix(t, scale(*points.last().unwrap(), 1000.0)));
        out
    }

    fn track(fixes: Vec<Fix>) -> PilotTrack {
        let n = fixes.len();
        PilotTrack { fixes, capsule: vec![false; n] }
    }

    fn mirrored_after(plane: &Plane, fixes: &[Fix], t: f64) -> Vec<Fix> {
        fixes.iter().map(|f| if f.t > t { Fix { p: plane.reflect(f.p), ..*f } } else { *f }).collect()
    }

    fn max_error(a: &[Fix], b: &[Fix]) -> f64 {
        a.iter().zip(b).map(|(x, y)| dist(x.p, y.p)).fold(0.0, f64::max)
    }

    /// Observers on an edge and the opposite edge: the plane y = z runs through the centre, with
    /// `+n` toward z > y.
    fn central_plane() -> Plane {
        let c = corners();
        Plane::from_observers([c[0], c[1], c[6]])
    }

    #[test]
    fn plane_normal_follows_observer_order() {
        let p = central_plane();
        let r = 0.5f64.sqrt();
        assert!(dist(p.n, [0.0, -r, r]) < 1e-12, "{:?}", p.n);
        assert!(p.d.abs() < 1e-6);
        assert_eq!(p.reflect([1.0, 2.0, 3.0]).map(|v| v.round()), [1.0, 3.0, 2.0]);
    }

    /// In the plane y = z from (10,10,10) to (50,50,50), then off toward z > y (ccw).
    fn in_plane_then_ccw() -> Vec<Fix> {
        path(&[[10.0, 10.0, 10.0], [50.0, 50.0, 50.0], [80.0, 45.0, 70.0]], &[60, 40])
    }

    #[test]
    fn an_exit_without_evidence_turns_clockwise() {
        let plane = central_plane();
        let truth = in_plane_then_ccw();
        let mut tracks = [track(truth.clone())];
        let exits = resolve(&plane, &mut tracks, &[], 0.0);
        assert_eq!(exits[0].len(), 1, "{:?}", exits);
        assert_eq!(exits[0][0].turn, Turn::Cw);
        assert!(tracks[0].fixes.last().map(|f| plane.offset(f.p)).unwrap() < -GRAZE_M);
        // The same distances as the truth, all the way.
        assert!(max_error(&tracks[0].fixes, &mirrored_after(&plane, &truth, exits[0][0].t)) < 1.0);
    }

    #[test]
    fn a_brisk_crossing_is_not_ambiguous() {
        let plane = central_plane();
        // Straight from the y > z side to the z > y side at ~700 m/s normal speed.
        let fixes = path(&[[50.0, 70.0, 30.0], [50.0, 30.0, 70.0]], &[80]);
        assert!(find_exits(&plane, &fixes).is_empty());
        let mut tracks = [track(fixes.clone())];
        resolve(&plane, &mut tracks, &[], 0.0);
        assert!(max_error(&tracks[0].fixes, &fixes) < 1e-9);
    }

    /// Observers on three face diagonals: the plane x + y + z = 100 km misses the centre, so a
    /// mirror image can sit outside the boundary while the ship is inside.
    fn off_centre_plane() -> (Plane, V3, V3) {
        let c = corners();
        let plane = Plane::from_observers([c[1], c[2], c[4]]);
        let foot = scale([1.0, 1.0, 1.0], 100.0 / 3.0); // centre projected onto the plane, km
        let u = scale([1.0, -1.0, 0.0], 0.5f64.sqrt());
        (plane, foot, u)
    }

    fn at(foot: V3, u: V3, n: V3, along: f64, up: f64) -> V3 {
        add(foot, add(scale(u, along), scale(n, up)))
    }

    #[test]
    fn a_clockwise_branch_that_leaves_and_reenters_the_arena_turns_counterclockwise() {
        let (plane, foot, u) = off_centre_plane();
        let n = plane.n;
        // In the plane, out to where +n keeps the ship inside but −n would put it ~9 km out of
        // bounds, then back toward the centre.
        let truth = path(
            &[at(foot, u, n, 0.0, 0.0), at(foot, u, n, 30.0, 0.0), at(foot, u, n, 110.0, 60.0), at(foot, u, n, 40.0, 40.0)],
            &[30, 60, 60],
        );
        let solved = mirrored_after(&plane, &truth, 30.0); // the solver happened to pick −n
        let mut tracks = [track(solved)];
        let exits = resolve(&plane, &mut tracks, &[], 0.0);
        assert_eq!(exits[0].len(), 1, "{:?}", exits);
        assert_eq!(exits[0][0].turn, Turn::Ccw, "{:?}", exits);
        assert!(exits[0][0].reasons.iter().any(|r| r.contains("out of bounds")), "{:?}", exits);
        assert!(max_error(&tracks[0].fixes, &truth) < 1.0);
    }

    #[test]
    fn going_out_of_bounds_and_staying_out_is_not_evidence() {
        let (plane, foot, u) = off_centre_plane();
        let n = plane.n;
        let truth = path(&[at(foot, u, n, 0.0, 0.0), at(foot, u, n, 30.0, 0.0), at(foot, u, n, 110.0, 60.0)], &[30, 60]);
        let mut tracks = [track(truth)];
        let exits = resolve(&plane, &mut tracks, &[], 0.0);
        assert_eq!(exits[0][0].turn, Turn::Cw);
    }

    #[test]
    fn a_scram_out_of_range_on_the_clockwise_branch_turns_counterclockwise() {
        let plane = central_plane();
        let truth = in_plane_then_ccw();
        // A second ship parked 5 km from where the first ends up, on the +n side.
        let end = truth.last().unwrap().p;
        let tackler: Vec<Fix> = truth.iter().map(|f| fix(f.t, add(end, [5_000.0, 0.0, 0.0]))).collect();
        let scram = Scram { t: truth.last().unwrap().t - 2.0, source: 1, target: 0, disruption: false, source_ship: "Stiletto".into() };
        let mut tracks = [track(truth.clone()), track(tackler)];
        let exits = resolve(&plane, &mut tracks, std::slice::from_ref(&scram), 0.0);
        assert_eq!(exits[0][0].turn, Turn::Ccw, "{:?}", exits);
        assert!(max_error(&tracks[0].fixes, &truth) < 1.0);
        // The same scram from a long-point hull is in range either way.
        let long = Scram { source_ship: "Arazu".into(), ..scram };
        let mut tracks = [track(truth.clone()), track(tracks[1].fixes.clone())];
        let exits = resolve(&plane, &mut tracks, &[long], 0.0);
        assert_eq!(exits[0][0].turn, Turn::Cw, "{:?}", exits);
    }

    #[test]
    fn leaving_the_cube_face_before_the_start_turns_inside() {
        // Observers on the z = 0 face: +n points into the cube.
        let c = corners();
        let plane = Plane::from_observers([c[0], c[1], c[2]]);
        assert!(plane.n[2] > 0.99);
        // Sitting on the face, then lifting off into the cube before the match starts.
        let truth = path(&[[40.0, 40.0, 0.0], [45.0, 40.0, 0.0], [50.0, 40.0, 20.0]], &[10, 20]);
        let mut tracks = [track(truth.clone())];
        let exits = resolve(&plane, &mut tracks, &[], 100.0);
        assert_eq!(exits[0][0].turn, Turn::Ccw, "{:?}", exits);
        assert!(max_error(&tracks[0].fixes, &truth) < 1.0);
    }

    #[test]
    fn solved_from_rounded_distances_an_in_plane_flight_settles_clockwise() {
        use crate::solve::{solve_track, Reading};
        let c = corners();
        let obs = [c[0], c[1], c[6]];
        let plane = Plane::from_observers(obs);
        let truth = in_plane_then_ccw();
        let readings: Vec<Reading> = truth
            .iter()
            .enumerate()
            .map(|(i, f)| {
                let next = truth.get(i + 1).unwrap_or(f);
                let prev = if i > 0 { truth[i - 1] } else { *f };
                let speed = dist(next.p, prev.p) / (next.t - prev.t).max(1.0);
                Reading { t: f.t, d: obs.map(|o| (dist(o, f.p) / 1000.0).round() * 1000.0), speed_mps: Some(speed) }
            })
            .collect();
        let mut tracks = [track(solve_track(obs, &readings))];
        let exits = resolve(&plane, &mut tracks, &[], 0.0);
        assert!(!exits[0].is_empty());
        assert!(exits[0].iter().all(|e| e.turn == Turn::Cw), "{:?}", exits);
        // Ends on the clockwise side, where the truth's mirror is.
        let end = tracks[0].fixes.last().unwrap().p;
        let mirror = plane.reflect(truth.last().unwrap().p);
        assert!(dist(end, mirror) < 3_000.0, "{end:?} vs {mirror:?}");
    }

    #[test]
    fn observers_far_enough_out_leave_no_plane_in_the_arena() {
        use crate::solve::observers_at;
        // Three corners of the bottom face, 235 km from the centre: the plane is 135.7 km below it.
        let plane = Plane::from_observers(observers_at([0, 1, 2], 235_000.0));
        let centre = [CUBE_M / 2.0; 3];
        assert!(plane.offset(centre).abs() > BOUNDARY_RADIUS_M + GRAZE_M);
        // A ship skimming the bottom of the arena never comes near it.
        let fixes = path(&[[50.0, 50.0, -70.0], [100.0, 80.0, -70.0], [150.0, 50.0, -60.0]], &[60, 60]);
        assert!(find_exits(&plane, &fixes).is_empty());
    }

    #[test]
    fn each_exit_gets_its_own_tail() {
        let plane = central_plane();
        // Off to z > y, back into the plane, along it, then off to y > z.
        let fixes = path(
            &[[10.0, 10.0, 10.0], [30.0, 30.0, 30.0], [40.0, 30.0, 45.0], [55.0, 50.0, 50.0], [70.0, 65.0, 65.0], [80.0, 80.0, 60.0]],
            &[30, 30, 30, 30, 30],
        );
        let exits = find_exits(&plane, &fixes);
        assert_eq!(exits.len(), 2, "{exits:?}");
        let mut tracks = [track(fixes)];
        let settled = resolve(&plane, &mut tracks, &[], 0.0);
        assert_eq!(settled[0][0].end, settled[0][1].idx + 1);
        // The first tail defaults to −n. The ship then comes back into the plane from −n, so
        // carrying on through it (to +n) fits better than turning back.
        assert_eq!(settled[0][0].turn, Turn::Cw);
        assert_eq!(settled[0][1].turn, Turn::Ccw, "{:?}", settled[0][1]);
        assert!(settled[0][1].reasons.iter().any(|r| r.contains("came in")));
        for e in &settled[0] {
            let side = tail_side(&plane, &tracks[0].fixes[e.idx + 1..e.end]);
            assert_eq!(side, e.turn.side(), "{e:?}");
        }
    }
}
