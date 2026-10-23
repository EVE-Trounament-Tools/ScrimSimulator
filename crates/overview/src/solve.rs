//! Position from distances (DESIGN.md S2.1) for the three-observer cube setup: every pilot starts
//! inside a [`CUBE_M`]-sided cube, and the observers sit on three distinct centre->corner
//! diagonals of it, all the same distance `R` from the centre ([`observers_at`]). Which three
//! diagonals, and `R`, are not known up front; `R` = [`CORNER_R_M`] puts them on the corners.
//!
//! Three spheres meet in two points mirrored through the observers' plane. The cube resolves that
//! twice. First, [`infer_observers`] tries every ordered corner triple over a range of `R` and
//! keeps the one whose trilaterated starting positions are consistent (the spheres actually meet)
//! and lie inside the cube, and whose tracks move at the speed the overview shows. Second, [`solve_track`] starts a
//! pilot at the root inside the cube and from there follows a filtered, smoothed track, which
//! keeps it on its side of the observers' plane and irons out the distances' 1 km rounding.

pub type V3 = [f64; 3];

/// Cube side length: every pilot starts inside it, and the observers are on its centre->corner
/// diagonals.
pub const CUBE_M: f64 = 100_000.0;
/// Distance from the cube's centre to its corners: observers this far out sit on the corners.
pub const CORNER_R_M: f64 = CUBE_M / 2.0 * 1.732_050_807_568_877_2;
/// The range of observer distances from the centre [`infer_observers`] searches.
pub const MIN_OBSERVER_R_M: f64 = 20_000.0;
pub const MAX_OBSERVER_R_M: f64 = 600_000.0;

pub(crate) fn sub(a: V3, b: V3) -> V3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

pub(crate) fn add(a: V3, b: V3) -> V3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

pub(crate) fn scale(a: V3, k: f64) -> V3 {
    [a[0] * k, a[1] * k, a[2] * k]
}

pub(crate) fn dot(a: V3, b: V3) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

pub(crate) fn cross(a: V3, b: V3) -> V3 {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

pub fn norm(a: V3) -> f64 {
    dot(a, a).sqrt()
}

pub(crate) fn dist(a: V3, b: V3) -> f64 {
    norm(sub(a, b))
}

/// The cube's eight corners, in metres.
pub fn corners() -> [V3; 8] {
    std::array::from_fn(|i| {
        [
            (i & 1) as f64 * CUBE_M,
            ((i >> 1) & 1) as f64 * CUBE_M,
            ((i >> 2) & 1) as f64 * CUBE_M,
        ]
    })
}

/// The observers on the diagonals toward corners `triple` (indices into [`corners`]), `r_m` from
/// the cube's centre.
pub fn observers_at(triple: [usize; 3], r_m: f64) -> [V3; 3] {
    let c = corners();
    let centre = [CUBE_M / 2.0; 3];
    triple.map(|i| add(centre, scale(sub(c[i], centre), r_m / CORNER_R_M)))
}

/// How far `p` lies outside the cube (0 inside or on it).
pub fn outside_cube_m(p: V3) -> f64 {
    norm(std::array::from_fn(|k| (-p[k]).max(p[k] - CUBE_M).max(0.0)))
}

/// Both candidate positions for one set of three distances.
#[derive(Clone, Copy, Debug)]
pub struct Trilat {
    /// The two mirror-image solutions. They coincide (on the observers' plane) when the spheres
    /// only touch, or when noise means they don't meet at all.
    pub roots: [V3; 2],
    /// RMS of `|‖p − oᵢ‖ − dᵢ|` at the roots. 0 when the spheres meet, otherwise a measure of how
    /// inconsistent the three readings are.
    pub residual_m: f64,
}

/// Closed-form trilateration in the observers' own frame (`ex` toward observer 1, `ey` in their
/// plane, `ez` normal to it). Cube corners are never collinear, so the frame always exists.
pub fn trilaterate(obs: [V3; 3], d: [f64; 3]) -> Trilat {
    let [p1, p2, p3] = obs;
    let d12 = dist(p2, p1);
    let ex = scale(sub(p2, p1), 1.0 / d12);
    let i = dot(ex, sub(p3, p1));
    let ey_raw = sub(sub(p3, p1), scale(ex, i));
    let ey = scale(ey_raw, 1.0 / norm(ey_raw));
    let ez = cross(ex, ey);
    let j = dot(ey, sub(p3, p1));

    let x = (d[0] * d[0] - d[1] * d[1] + d12 * d12) / (2.0 * d12);
    let y = (d[0] * d[0] - d[2] * d[2] + i * i + j * j) / (2.0 * j) - (i / j) * x;
    let z = (d[0] * d[0] - x * x - y * y).max(0.0).sqrt();

    let base = add(p1, add(scale(ex, x), scale(ey, y)));
    let roots = [add(base, scale(ez, z)), sub(base, scale(ez, z))];
    let sq: f64 = (0..3).map(|k| (dist(roots[0], obs[k]) - d[k]).powi(2)).sum();
    Trilat { roots, residual_m: (sq / 3.0).sqrt() }
}

/// One reading for corner inference: time, distances to observers A/B/C, and the overview's
/// speed for that tick when it was read. A distance is NaN when that observer didn't read one
/// (the pilot was off its overview); only [`solve_track`] takes such partial readings.
#[derive(Clone, Copy, Debug)]
pub struct Reading {
    pub t: f64,
    pub d: [f64; 3],
    pub speed_mps: Option<f64>,
}

impl Reading {
    /// All three observers read a distance.
    pub fn is_complete(&self) -> bool {
        self.d.iter().all(|d| !d.is_nan())
    }
}

/// The observer layout [`infer_observers`] settled on.
#[derive(Clone, Copy, Debug)]
pub struct ObserverFit {
    /// Positions of observers A, B, C (in the order of the distance triples).
    pub corners: [V3; 3],
    /// The corners (indices into [`corners`]) whose diagonals they sit on...
    pub triple: [usize; 3],
    /// ...and how far from the centre ([`CORNER_R_M`] on the corners).
    pub r_m: f64,
    /// Cost of the chosen triple: [`CornerCost::total`].
    pub score: f64,
    pub cost: CornerCost,
    /// The best cost among triples with a *different* shape (side lengths in A/B/C order), so
    /// a caller can tell a clear winner from a near-tie. `INFINITY` if there is no other shape.
    pub runner_up: f64,
    /// That runner-up triple, if any.
    pub runner_up_corners: Option<[V3; 3]>,
}

/// How close (relative) the best other-shaped observer layout may score before the choice is
/// ambiguous...
const AMBIGUITY_RATIO: f64 = 1.5;
/// ...or how close in absolute terms (metres of cost), which also catches a tie at 0.
const AMBIGUITY_MARGIN_M: f64 = 500.0;

impl ObserverFit {
    /// Whether another observer layout fits almost as well as the chosen one.
    pub fn is_ambiguous(&self) -> bool {
        self.runner_up < self.score * AMBIGUITY_RATIO || self.runner_up - self.score < AMBIGUITY_MARGIN_M
    }
}

/// What a corner triple costs, by signal.
#[derive(Clone, Copy, Debug, Default)]
pub struct CornerCost {
    /// Mean per-reading trilateration residual plus distance outside the cube over each pilot's
    /// first [`START_TICKS`] readings, in metres.
    pub start_m: f64,
    /// Median relative mismatch between the solved tracks' speed and the overview's Velocity
    /// (see [`speed_error`]); `None` when no pilot moved fast enough for long enough.
    pub speed_err: Option<f64>,
}

impl CornerCost {
    /// Both signals in metres: the speed mismatch is weighted by [`SPEED_ERR_WEIGHT_M`].
    pub fn total(&self) -> f64 {
        self.start_m + self.speed_err.map_or(0.0, |e| e * SPEED_ERR_WEIGHT_M)
    }
}

/// How many of each pilot's earliest readings feed the start cost. Pilots start inside the cube,
/// but later in a match they may not be.
pub const START_TICKS: usize = 10;

/// Metres of start cost that one unit of relative speed mismatch is worth. The right shape's
/// mismatch is ~0.05-0.10 (1 km distance rounding), a wrong one's ~0.1-0.4; at this weight the
/// speed term decides whenever start costs are within a few hundred metres of each other, which
/// is when the start alone can't tell (every pilot far from every observer).
pub const SPEED_ERR_WEIGHT_M: f64 = 10_000.0;

/// Steps of the coarse log-spaced grid of observer distances [`infer_observers`] searches...
const R_GRID: usize = 48;
/// ...and golden-section steps refining the best of them.
const R_REFINE_STEPS: usize = 16;

/// Mean per-reading start cost (see [`CornerCost::start_m`]) of observers at `obs`.
fn start_cost(obs: [V3; 3], pilots: &[Vec<Reading>]) -> f64 {
    let n = pilots.iter().map(|p| p.len().min(START_TICKS)).sum::<usize>().max(1) as f64;
    pilots
        .iter()
        .flat_map(|p| p.iter().take(START_TICKS))
        .map(|r| {
            let tri = trilaterate(obs, r.d);
            let out = tri.roots.map(outside_cube_m);
            tri.residual_m + out[0].min(out[1])
        })
        .sum::<f64>()
        / n
}

/// One ordered triple of distinct corners per shape (side lengths in A/B/C order), the first in
/// index order. Every triple of a shape is a cube symmetry of it, so all score the same and give
/// the same answer up to a rotation or reflection of the output frame, at any `R`; always taking
/// the first keeps the frame the same from run to run.
fn shapes() -> Vec<[usize; 3]> {
    let c = corners();
    let mut seen: Vec<[u64; 3]> = Vec::new();
    let mut out = Vec::new();
    for a in 0..8 {
        for b in (0..8).filter(|&b| b != a) {
            for cc in (0..8).filter(|&x| x != a && x != b) {
                let shape = [dist(c[a], c[b]), dist(c[a], c[cc]), dist(c[b], c[cc])].map(|s| s.round() as u64);
                if !seen.contains(&shape) {
                    seen.push(shape);
                    out.push([a, b, cc]);
                }
            }
        }
    }
    out
}

/// What observers on the diagonals toward `triple`, `r_m` from the centre, cost.
fn cost_at(triple: [usize; 3], r_m: f64, pilots: &[Vec<Reading>]) -> CornerCost {
    let obs = observers_at(triple, r_m);
    CornerCost { start_m: start_cost(obs, pilots), speed_err: speed_error(obs, pilots) }
}

/// Pick the observers' diagonals and their distance from the centre from the pilots' readings
/// (each pilot's time-ordered). With `fixed_r` the distance is known and only the diagonals are
/// picked.
///
/// Each shape of corner triple ([`shapes`]) gets a start cost: each early reading costs its
/// trilateration residual plus how far its nearer-to-the-cube root sits outside the cube. A wrong
/// `R` stretches or squeezes every distance, so the spheres stop meeting and the
/// starts leave the cube: each shape's `R` is the best of a log-spaced grid over
/// [`MIN_OBSERVER_R_M`]..[`MAX_OBSERVER_R_M`], refined by golden-section search.
///
/// The start alone is ambiguous when every pilot starts far from every observer (near the
/// centre): then every shape fits. So each candidate's whole match is also solved and its speed
/// compared with the overview's Velocity (see [`speed_error`]): a wrong layout distorts distances,
/// so its tracks move at the wrong speed. Only complete readings count.
pub fn infer_observers(pilots: &[Vec<Reading>], fixed_r: Option<f64>) -> ObserverFit {
    use rayon::prelude::*;
    let pilots: Vec<Vec<Reading>> = pilots.iter().map(|p| p.iter().filter(|r| r.is_complete()).copied().collect()).collect();
    let pilots = &pilots[..];
    let total = |c: &CornerCost| c.total();
    let mut scored: Vec<([usize; 3], f64, CornerCost)> = shapes()
        .par_iter()
        .map(|&triple| {
            let at = |r: f64| (triple, r, cost_at(triple, r, pilots));
            if let Some(r) = fixed_r {
                return at(r);
            }
            let ratio = MAX_OBSERVER_R_M / MIN_OBSERVER_R_M;
            let mut grid: Vec<f64> =
                (0..R_GRID).map(|i| MIN_OBSERVER_R_M * ratio.powf(i as f64 / (R_GRID - 1) as f64)).collect();
            grid.push(CORNER_R_M);
            grid.sort_by(f64::total_cmp);
            let costs: Vec<_> = grid.iter().map(|&r| at(r)).collect();
            let k = (0..grid.len()).min_by(|&a, &b| total(&costs[a].2).total_cmp(&total(&costs[b].2))).unwrap();
            let (mut lo, mut hi) = (grid[k.saturating_sub(1)], grid[(k + 1).min(grid.len() - 1)]);
            let mut best = costs[k];
            // Golden-section search between the grid neighbours of the best grid value.
            let g = (5f64.sqrt() - 1.0) / 2.0;
            let (mut x1, mut x2) = (hi - g * (hi - lo), lo + g * (hi - lo));
            let (mut f1, mut f2) = (at(x1), at(x2));
            for _ in 0..R_REFINE_STEPS {
                if total(&f1.2) < total(&f2.2) {
                    hi = x2;
                    (x2, f2) = (x1, f1);
                    x1 = hi - g * (hi - lo);
                    f1 = at(x1);
                } else {
                    lo = x1;
                    (x1, f1) = (x2, f2);
                    x2 = lo + g * (hi - lo);
                    f2 = at(x2);
                }
            }
            for cand in [f1, f2] {
                if total(&cand.2) < total(&best.2) {
                    best = cand;
                }
            }
            best
        })
        .collect();
    scored.sort_by(|x, y| x.2.total().total_cmp(&y.2.total()));
    let (triple, r_m, cost) = scored[0];
    ObserverFit {
        corners: observers_at(triple, r_m),
        triple,
        r_m,
        score: cost.total(),
        cost,
        runner_up: scored.get(1).map_or(f64::INFINITY, |e| e.2.total()),
        runner_up_corners: scored.get(1).map(|e| observers_at(e.0, e.1)),
    }
}

/// Two observers whose distances agree on at least this share of the ticks both read...
const SAME_OBSERVER_SHARE: f64 = 0.9;
/// ...out of at least this many such ticks, are one overview captured twice.
const SAME_OBSERVER_MIN_TICKS: usize = 30;

/// The first pair of observers (indices into [`Reading::d`]) whose distances are the same on
/// nearly every tick both read, with that share: one overview captured in two panels, which
/// leaves two observers to trilaterate from. Distinct observers agree only when the 1 km rounding
/// happens to line up (~1% of ticks).
pub fn duplicate_observers(pilots: &[Vec<Reading>]) -> Option<(usize, usize, f64)> {
    [(0, 1), (0, 2), (1, 2)].into_iter().find_map(|(i, j)| {
        let both: Vec<&Reading> =
            pilots.iter().flatten().filter(|r| !r.d[i].is_nan() && !r.d[j].is_nan()).collect();
        let same = both.iter().filter(|r| r.d[i] == r.d[j]).count();
        let share = same as f64 / both.len().max(1) as f64;
        (both.len() >= SAME_OBSERVER_MIN_TICKS && share >= SAME_OBSERVER_SHARE).then_some((i, j, share))
    })
}

/// Speed windows span at least this long, so the 1 km rounding of distances stays small next to
/// the distance flown...
const SPEED_WINDOW_S: f64 = 10.0;
/// ...and at most this long (a window across a gap in the readings is skipped).
const SPEED_WINDOW_MAX_S: f64 = 14.0;
/// Windows slower than this (mean overview speed) are skipped: rounding would dominate.
const SPEED_MIN_MPS: f64 = 300.0;
/// A window needs this many overview speed readings.
const SPEED_MIN_READINGS: usize = 5;

/// How badly solving with observers at `obs` disagrees with the overview's Velocity: over every
/// window of [`SPEED_WINDOW_S`]..[`SPEED_WINDOW_MAX_S`] of each pilot's track, the solved
/// straight-line speed against the mean overview speed, as a relative error; the median over all
/// windows. A turning ship flies further than its chord, which costs every shape alike. `None`
/// with no usable window.
pub fn speed_error(obs: [V3; 3], pilots: &[Vec<Reading>]) -> Option<f64> {
    let mut errs: Vec<f64> = Vec::new();
    for p in pilots {
        let fixes = solve_track(obs, p);
        let mut k = 0;
        for i in 0..fixes.len() {
            while k < fixes.len() && fixes[k].t - fixes[i].t < SPEED_WINDOW_S {
                k += 1;
            }
            if k == fixes.len() {
                break;
            }
            let span = fixes[k].t - fixes[i].t;
            if span > SPEED_WINDOW_MAX_S {
                continue;
            }
            let speeds: Vec<f64> = p[i..=k].iter().filter_map(|r| r.speed_mps).collect();
            if speeds.len() < SPEED_MIN_READINGS {
                continue;
            }
            let overview = speeds.iter().sum::<f64>() / speeds.len() as f64;
            if overview < SPEED_MIN_MPS {
                continue;
            }
            let solved = dist(fixes[k].p, fixes[i].p) / span;
            errs.push((solved - overview).abs() / overview);
        }
    }
    if errs.is_empty() {
        return None;
    }
    errs.sort_by(f64::total_cmp);
    Some(errs[errs.len() / 2])
}

/// One solved position.
#[derive(Clone, Copy, Debug)]
pub struct Fix {
    pub t: f64,
    pub p: V3,
    pub residual_m: f64,
}

/// How hard ships can accelerate: the standard deviation of the white acceleration noise in the
/// tracking filter's constant-velocity model, in m/s². Frigates reach several km/s in seconds.
const ACCEL_NOISE_MPS2: f64 = 300.0;
/// Noise of one displayed distance: rounding to whole km is uniform over ±500 m, σ = 1 km/√12.
const DISTANCE_SIGMA_M: f64 = 288.675;
/// Noise of the overview's Velocity reading.
const SPEED_SIGMA_MPS: f64 = 50.0;
/// Below this filtered speed the direction of `v` is meaningless, so speed readings are skipped.
const SPEED_UPDATE_MIN_MPS: f64 = 1.0;
/// A speed reading further than this many standard deviations from the filtered speed is skipped.
/// A speed only sizes `v` along its filtered heading, and a ship that turns and burns jumps its
/// speed before the distances show which way: folded in, the jump pushes the track along the old
/// heading, kilometres a tick, until it fails [`RESET_GATE_M`] and is taken for a teleport (whose
/// restart once picked the mirror root, hundreds of km away). The distances steer it until the
/// filter has caught up with the new heading and speed.
const SPEED_GATE_SIGMAS: f64 = 2.0;
/// An overview speed of at most this (parked ships read 0 or 1 m/s) holds the whole velocity at 0.
/// Without it, a ship sitting through the countdown has no velocity reading at all, and smoothing
/// slides it km along whatever direction its rounded distances can't see, toward where it later
/// flies. Any faster reading, however slow, is a real speed and updates `|v|` as usual.
const STILL_SPEED_MPS: f64 = 1.0;
/// Noise of such a reading: a 0 or 1 is exact to the m/s, unlike a moving ship's speed, which
/// [`SPEED_SIGMA_MPS`] allows to be read a little before or after its distances. As loose as
/// that, a parked ship could keep 20 m/s under a reading of 0 and slide hundreds of metres.
const STILL_SIGMA_MPS: f64 = 1.0;
/// Acceleration noise between two still readings, in place of [`ACCEL_NOISE_MPS2`]: a ship that
/// reads 0–1 m/s at both ends of a tick hasn't burned in between. Holding the velocity alone isn't
/// enough, as the full noise still lets position wander ~90 m a tick on its own, which smoothing
/// spends leaning a parked ship toward where it's about to fly.
const STILL_ACCEL_MPS2: f64 = 1.0;
/// A reading this far (any one distance) from the filter's prediction is a teleport: a micro
/// jump, a warp, a pod. The track restarts there instead of being dragged across.
const RESET_GATE_M: f64 = 8_000.0;
/// Uncertainty a (re)started track begins with.
const START_POS_SIGMA_M: f64 = 3_000.0;
const START_VEL_SIGMA_MPS: f64 = 1_000.0;

use nalgebra::{DMatrix, DVector};

type Vec6 = nalgebra::Vector6<f64>;
type Mat6 = nalgebra::Matrix6<f64>;

/// One filtered tick, kept for the backward (smoothing) pass.
struct Step {
    t: f64,
    d: [f64; 3],
    /// Filtered state `[p, v]` and covariance.
    x: Vec6,
    p: Mat6,
    /// The prediction this tick was filtered from, and the transition that made it (identity on a
    /// track's first tick).
    x_pred: Vec6,
    p_pred: Mat6,
    f: Mat6,
    /// This tick's overview speed said the ship was still ([`is_still`]).
    still: bool,
}

/// The overview shows the ship standing still ([`STILL_SPEED_MPS`]).
fn is_still(speed_mps: Option<f64>) -> bool {
    speed_mps.is_some_and(|v| v <= STILL_SPEED_MPS)
}

impl Step {
    /// A track (re)starting at `p0` with velocity `v0`.
    fn start(t: f64, d: [f64; 3], p0: V3, v0: V3, still: bool) -> Step {
        let x = Vec6::new(p0[0], p0[1], p0[2], v0[0], v0[1], v0[2]);
        let mut p = Mat6::zeros();
        for k in 0..3 {
            p[(k, k)] = START_POS_SIGMA_M.powi(2);
            p[(k + 3, k + 3)] = START_VEL_SIGMA_MPS.powi(2);
        }
        Step { t, d, x, p, x_pred: x, p_pred: p, f: Mat6::identity(), still }
    }

    /// Predict from `self` to `r` and fold `r` in, with the squared, noise-normalised mismatch
    /// between prediction and readings. `None` when `r` is a teleport ([`RESET_GATE_M`]).
    fn next(&self, r: &Reading, obs: [V3; 3]) -> Option<(Step, f64)> {
        let still = is_still(r.speed_mps);
        let (x_pred, p_pred, f) = predict(self, r.t, self.still && still);
        let at = pos(&x_pred);
        let miss: Vec<f64> = obs.iter().zip(r.d).filter(|(_, d)| !d.is_nan()).map(|(o, d)| d - dist(at, *o)).collect();
        if miss.iter().any(|m| m.abs() > RESET_GATE_M) {
            return None;
        }
        let mut cost: f64 = miss.iter().map(|m| (m / DISTANCE_SIGMA_M).powi(2)).sum();
        if let Some(v) = r.speed_mps {
            cost += ((v - norm([x_pred[3], x_pred[4], x_pred[5]])) / SPEED_SIGMA_MPS).powi(2);
        }
        let mut step = Step { t: r.t, d: r.d, x: x_pred, p: p_pred, x_pred, p_pred, f, still };
        step.update(obs, r.speed_mps);
        Some((step, cost))
    }

    /// Fold in this tick's distances and (when read) speed, all linearised at the prediction.
    fn update(&mut self, obs: [V3; 3], speed_mps: Option<f64>) {
        let at = pos(&self.x);
        let v = [self.x[3], self.x[4], self.x[5]];
        let s = norm(v);
        let mut rows: Vec<(Vec6, f64, f64)> = obs
            .iter()
            .zip(self.d)
            .filter(|(_, d)| !d.is_nan())
            .map(|(o, d)| {
                let r = sub(at, *o);
                let n = norm(r).max(1.0);
                (Vec6::new(r[0] / n, r[1] / n, r[2] / n, 0.0, 0.0, 0.0), d - n, DISTANCE_SIGMA_M.powi(2))
            })
            .collect();
        match speed_mps {
            // Standing still: pin each component of `v` to 0, the only way a speed says anything
            // about a velocity that has no direction yet.
            _ if is_still(speed_mps) => {
                for k in 0..3 {
                    let mut row = Vec6::zeros();
                    row[k + 3] = 1.0;
                    rows.push((row, -v[k], STILL_SIGMA_MPS.powi(2)));
                }
            }
            Some(measured) if s > SPEED_UPDATE_MIN_MPS => {
                let h = Vec6::new(0.0, 0.0, 0.0, v[0] / s, v[1] / s, v[2] / s);
                let sd = ((h.transpose() * self.p * h)[(0, 0)] + SPEED_SIGMA_MPS.powi(2)).sqrt();
                if (measured - s).abs() <= SPEED_GATE_SIGMAS * sd {
                    rows.push((h, measured - s, SPEED_SIGMA_MPS.powi(2)));
                }
            }
            _ => {}
        }
        let m = rows.len();
        let h = DMatrix::from_fn(m, 6, |i, j| rows[i].0[j]);
        let y = DVector::from_fn(m, |i, _| rows[i].1);
        let r = DMatrix::from_fn(m, m, |i, j| if i == j { rows[i].2 } else { 0.0 });
        let p = DMatrix::from_column_slice(6, 6, self.p.as_slice());
        let s_inv = match (&h * &p * h.transpose() + r).try_inverse() {
            Some(inv) => inv,
            None => return,
        };
        let k = &p * h.transpose() * s_inv;
        let dx = &k * y;
        let p_new = (DMatrix::identity(6, 6) - &k * &h) * &p;
        self.x += Vec6::from_column_slice(dx.as_slice());
        self.p = Mat6::from_column_slice(p_new.as_slice());
        self.p = (self.p + self.p.transpose()) * 0.5;
    }
}

fn pos(x: &Vec6) -> V3 {
    [x[0], x[1], x[2]]
}

/// Constant-velocity transition over `dt`, and its white-acceleration process noise ([`STILL_ACCEL_MPS2`]
/// when the ship reads still at both ends).
fn predict(prev: &Step, t: f64, still: bool) -> (Vec6, Mat6, Mat6) {
    let dt = t - prev.t;
    let mut f = Mat6::identity();
    let mut q = Mat6::zeros();
    let a2 = if still { STILL_ACCEL_MPS2 } else { ACCEL_NOISE_MPS2 }.powi(2);
    for k in 0..3 {
        f[(k, k + 3)] = dt;
        q[(k, k)] = a2 * dt.powi(3) / 3.0;
        q[(k, k + 3)] = a2 * dt.powi(2) / 2.0;
        q[(k + 3, k)] = a2 * dt.powi(2) / 2.0;
        q[(k + 3, k + 3)] = a2 * dt;
    }
    (f * prev.x, f * prev.p * f.transpose() + q, f)
}

/// Rauch–Tung–Striebel backward pass over one uninterrupted stretch of track, appending its fixes.
fn smooth_into(fixes: &mut Vec<Fix>, seg: &[Step], obs: [V3; 3]) {
    let Some(last) = seg.last() else { return };
    let mut xs = vec![last.x; seg.len()];
    for k in (0..seg.len() - 1).rev() {
        let next = &seg[k + 1];
        xs[k] = match next.p_pred.try_inverse() {
            Some(inv) => seg[k].x + seg[k].p * next.f.transpose() * inv * (xs[k + 1] - next.x_pred),
            None => seg[k].x,
        };
    }
    for (s, x) in seg.iter().zip(xs) {
        let p = pos(&x);
        let miss: Vec<f64> = (0..3).filter(|&k| !s.d[k].is_nan()).map(|k| dist(p, obs[k]) - s.d[k]).collect();
        let sq: f64 = miss.iter().map(|m| m * m).sum();
        fixes.push(Fix { t: s.t, p, residual_m: (sq / miss.len() as f64).sqrt() });
    }
}

/// Solve one pilot's track from its time-ordered readings.
///
/// Trilaterating each tick alone is hopeless near the observers' plane: the out-of-plane
/// coordinate, `sqrt(d² − x² − y²)`, swings by many km when one displayed distance ticks over by
/// 1 km. So the track is an extended Kalman filter over position and velocity (constant velocity
/// plus [`ACCEL_NOISE_MPS2`] of acceleration noise), fed each tick's three distances and the
/// overview's speed, then smoothed backwards (Rauch–Tung–Striebel) since the whole match is known.
/// Continuity also keeps the track on its side of the observers' plane, mirror roots and all.
///
/// The track starts at the closed-form root inside the cube (pilots start there; ties go to the
/// one nearer the centre). A reading more than [`RESET_GATE_M`] from the prediction is a teleport
/// (micro jump, warp): the track restarts there, at whichever root the following readings fit
/// better with the velocity carried over ([`lookahead_cost`]), and each stretch is smoothed
/// separately so the hop stays a single tick.
///
/// A partial reading (an observer missed the pilot, see [`Reading`]) only carries an existing
/// track on: its distances can't place a start or a restart, so it is dropped when there is no
/// track yet or it fails the gate, and a run of them is dropped unless the next complete reading
/// confirms it ([`drop_unconfirmed`]). Every other reading gets one fix.
pub fn solve_track(obs: [V3; 3], readings: &[Reading]) -> Vec<Fix> {
    let centre = [CUBE_M / 2.0; 3];
    let mut fixes: Vec<Fix> = Vec::with_capacity(readings.len());
    let mut seg: Vec<Step> = Vec::new();
    for (i, r) in readings.iter().enumerate() {
        let next = seg.last().map(|prev| prev.next(r, obs));
        if !r.is_complete() {
            if let Some(Some((step, _))) = next {
                seg.push(step);
            }
            continue;
        }
        let roots = trilaterate(obs, r.d).roots;
        let step = match next {
            None => {
                let cost = |p: V3| (outside_cube_m(p), dist(p, centre));
                let (c0, c1) = (cost(roots[0]), cost(roots[1]));
                let first = c1.0 < c0.0 || (c1.0 == c0.0 && c1.1 < c0.1);
                started(r, obs, roots[usize::from(first)], [0.0; 3])
            }
            Some(next) => match next {
                Some((step, _)) => step,
                None => {
                    // Teleport: restart on whichever side of the observers' plane carries on
                    // best, keeping the velocity (a micro jump does). A partial stretch this
                    // reading didn't confirm goes, so restart from before it.
                    drop_unconfirmed(&mut seg);
                    let Some(prev) = seg.last() else { unreachable!("a segment starts complete") };
                    let v = [prev.x[3], prev.x[4], prev.x[5]];
                    let from = pos(&prev.x);
                    smooth_into(&mut fixes, &seg, obs);
                    seg.clear();
                    let fit = |root: V3| lookahead_cost(started(r, obs, root, v), &readings[i + 1..], obs);
                    let (d0, d1) = (dist(roots[0], from), dist(roots[1], from));
                    let mirror = if (d0 - d1).abs() > RESTART_TIE_M { d1 < d0 } else { fit(roots[1]) < fit(roots[0]) };
                    started(r, obs, roots[usize::from(mirror)], v)
                }
            },
        };
        seg.push(step);
    }
    drop_unconfirmed(&mut seg);
    smooth_into(&mut fixes, &seg, obs);
    fixes
}

/// Drops a segment's trailing partial steps. While an observer is missing, the direction only it
/// measured drifts, and the filter doesn't know it (the speed reading pins that velocity
/// component's size but not its sign), so a partial stretch is kept only once a complete reading
/// after it passes the gate.
fn drop_unconfirmed(seg: &mut Vec<Step>) {
    while seg.last().is_some_and(|s| s.d.iter().any(|d| d.is_nan())) {
        seg.pop();
    }
}

/// A restart takes the root nearer the track's last position when the two are further apart
/// than this from it. Mirror roots move identically, so [`lookahead_cost`] can only tell them
/// apart by the velocity carried over, which is stale after a gap in the readings; far from the
/// observers' plane the mirror root is hundreds of km away, which no hop explains.
const RESTART_TIE_M: f64 = 20_000.0;

/// How many readings after a restart [`lookahead_cost`] runs the filter over to pick a side.
const LOOKAHEAD_TICKS: usize = 10;

/// A track started on reading `r` at `p0` with velocity `v0`, `r` folded in.
fn started(r: &Reading, obs: [V3; 3], p0: V3, v0: V3) -> Step {
    let mut step = Step::start(r.t, r.d, p0, v0, is_still(r.speed_mps));
    step.update(obs, r.speed_mps);
    step
}

/// Mean mismatch of the filter run from `step` over the next [`LOOKAHEAD_TICKS`] readings (up to
/// the next teleport), so a restart can tell its two mirror-image roots apart by which one moves
/// on consistently.
fn lookahead_cost(mut step: Step, readings: &[Reading], obs: [V3; 3]) -> f64 {
    let (mut total, mut n) = (0.0, 0);
    for r in readings.iter().take(LOOKAHEAD_TICKS) {
        let Some((next, cost)) = step.next(r, obs) else { break };
        total += cost;
        n += 1;
        step = next;
    }
    if n == 0 { 0.0 } else { total / n as f64 }
}

/// A fitted displacement over the window shorter than this is within the 1 km display rounding
/// of the distances, so the ship counts as stationary and has no direction.
const MIN_DISPLACEMENT_M: f64 = 1_000.0;

/// Direction of travel at `fixes[i]`: a unit vector along the least-squares slope of x/y/z against
/// t over fixes within `half_window_s` of it. `None` with fewer than 3 points, or when the fitted
/// displacement across the window is below [`MIN_DISPLACEMENT_M`].
pub fn direction(fixes: &[Fix], i: usize, half_window_s: f64) -> Option<V3> {
    let t0 = fixes[i].t;
    let win: Vec<&Fix> = fixes.iter().filter(|f| (f.t - t0).abs() <= half_window_s).collect();
    if win.len() < 3 {
        return None;
    }
    let n = win.len() as f64;
    let mt = win.iter().map(|f| f.t).sum::<f64>() / n;
    let stt: f64 = win.iter().map(|f| (f.t - mt).powi(2)).sum();
    if stt <= 0.0 {
        return None;
    }
    let slope: V3 = std::array::from_fn(|k| {
        let mp = win.iter().map(|f| f.p[k]).sum::<f64>() / n;
        win.iter().map(|f| (f.t - mt) * (f.p[k] - mp)).sum::<f64>() / stt
    });
    let span = win.last().unwrap().t - win[0].t;
    let speed = norm(slope);
    (speed * span >= MIN_DISPLACEMENT_M).then(|| scale(slope, 1.0 / speed))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Deterministic pseudo-random points in the cube (no `rand` dependency).
    fn points(n: usize) -> Vec<V3> {
        let mut s: u64 = 0x9E37_79B9_7F4A_7C15;
        let mut next = || {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            (s >> 11) as f64 / (1u64 << 53) as f64
        };
        (0..n).map(|_| [next() * CUBE_M, next() * CUBE_M, next() * CUBE_M]).collect()
    }

    fn ranges(obs: [V3; 3], p: V3) -> [f64; 3] {
        obs.map(|o| dist(o, p))
    }

    fn shape(obs: [V3; 3]) -> [u64; 3] {
        [dist(obs[0], obs[1]), dist(obs[0], obs[2]), dist(obs[1], obs[2])].map(|s| s.round() as u64)
    }

    #[test]
    fn trilaterate_round_trips_for_every_corner_shape() {
        let c = corners();
        let configs = [[c[0], c[1], c[2]], [c[0], c[1], c[6]], [c[0], c[3], c[5]]];
        for obs in configs {
            for p in points(50) {
                let tri = trilaterate(obs, ranges(obs, p));
                let err = tri.roots.map(|r| dist(r, p));
                assert!(err[0].min(err[1]) < 1.0, "{obs:?} {p:?}: {err:?}");
                assert!(tri.residual_m < 1.0);
            }
        }
    }

    /// The overview shows distances in whole km.
    fn rounded(obs: [V3; 3], p: V3) -> [f64; 3] {
        ranges(obs, p).map(|d| (d / 1000.0).round() * 1000.0)
    }

    /// One reading per pilot: each starts somewhere, standing still.
    fn standing(obs: [V3; 3], starts: &[V3]) -> Vec<Vec<Reading>> {
        starts.iter().map(|&p| vec![Reading { t: 0.0, d: rounded(obs, p), speed_mps: None }]).collect()
    }

    /// The shape of a fit's diagonals (side lengths of their corners, whatever its `R`).
    fn fit_shape(fit: &ObserverFit) -> [u64; 3] {
        shape(observers_at(fit.triple, CORNER_R_M))
    }

    #[test]
    fn observers_at_the_corner_distance_are_the_corners() {
        let c = corners();
        let obs = observers_at([0, 3, 6], CORNER_R_M);
        for (o, i) in obs.iter().zip([0, 3, 6]) {
            assert!(dist(*o, c[i]) < 1e-6, "{o:?}");
        }
        let far = observers_at([0, 1, 2], 2.0 * CORNER_R_M);
        assert!(dist(far[0], [-50_000.0; 3]) < 1e-6, "{far:?}");
    }

    #[test]
    fn infer_observers_recovers_the_shape_from_rounded_distances() {
        let c = corners();
        for truth in [[c[0], c[1], c[2]], [c[0], c[1], c[6]], [c[0], c[3], c[5]], [c[7], c[2], c[4]]] {
            let readings = standing(truth, &points(20));
            let fit = infer_observers(&readings, None);
            assert_eq!(fit_shape(&fit), shape(truth), "{fit:?}");
            assert!(fit.runner_up > fit.score);
            // Same solution up to a cube symmetry: every reading has a root inside the cube.
            for r in readings.iter().flatten() {
                let tri = trilaterate(fit.corners, r.d);
                assert!(tri.roots.iter().any(|&r| outside_cube_m(r) < 2_000.0));
            }
        }
    }

    /// A start where every pilot is far from every observer: one team bunched at the centre, the
    /// other strung along a corner->centre line. Rounded to whole km, every shape explains it.
    fn central_start() -> Vec<V3> {
        let mut starts: Vec<V3> = (0..10)
            .map(|i| {
                let k = i as f64;
                [50_000.0 + 1_500.0 * (k * 1.3).sin(), 50_000.0 + 1_500.0 * (k * 2.1).cos(), 49_000.0 + 300.0 * k]
            })
            .collect();
        starts.extend((0..10).map(|i| {
            let s = 30_000.0 + 2_000.0 * i as f64; // along the corner (100,0,100) -> centre line
            [50_000.0 + s / 3f64.sqrt(), 50_000.0 - s / 3f64.sqrt(), 50_000.0 + s / 3f64.sqrt()]
        }));
        starts
    }

    #[test]
    fn a_central_start_alone_is_reported_ambiguous() {
        let c = corners();
        let truth = [c[5], c[0], c[7]];
        let fit = infer_observers(&standing(truth, &central_start()), None);
        assert!(fit.is_ambiguous(), "{fit:?}");
    }

    #[test]
    fn overview_speed_breaks_a_central_start_tie() {
        let c = corners();
        // Face diagonal, edge, space diagonal: the layout the start alone can't pick out.
        for truth in [[c[5], c[0], c[7]], [c[0], c[1], c[2]], [c[0], c[3], c[5]]] {
            let mut dirs = points(20).into_iter().map(|p| {
                let v = sub(p, [CUBE_M / 2.0; 3]);
                scale(v, 1.0 / norm(v))
            });
            let pilots: Vec<Vec<Reading>> = central_start()
                .into_iter()
                .map(|p0| {
                    // Straight at 800 m/s for 40 s, read once a second.
                    let v = scale(dirs.next().unwrap(), 800.0);
                    (0..40)
                        .map(|t| {
                            let p = add(p0, scale(v, t as f64));
                            Reading { t: t as f64, d: rounded(truth, p), speed_mps: Some(800.0) }
                        })
                        .collect()
                })
                .collect();
            let fit = infer_observers(&pilots, None);
            assert_eq!(fit_shape(&fit), shape(truth), "{fit:?}");
            assert!(!fit.is_ambiguous(), "{fit:?}");
        }
    }

    /// Ships starting all over the cube and flying straight at 800 m/s for 40 s, as observers at
    /// `obs` read them.
    fn flying(obs: [V3; 3]) -> Vec<Vec<Reading>> {
        let dirs = points(20).into_iter().map(|p| {
            let v = sub(p, [CUBE_M / 2.0; 3]);
            scale(v, 800.0 / norm(v))
        });
        points(20)
            .into_iter()
            .zip(dirs)
            .map(|(p0, v)| {
                (0..40)
                    .map(|t| Reading { t: t as f64, d: rounded(obs, add(p0, scale(v, t as f64))), speed_mps: Some(800.0) })
                    .collect()
            })
            .collect()
    }

    #[test]
    fn one_overview_in_two_panels_is_caught() {
        let obs = observers_at([0, 1, 2], 450_000.0);
        assert_eq!(duplicate_observers(&flying(obs)), None, "distinct observers");
        let twice: Vec<Vec<Reading>> = flying(obs)
            .into_iter()
            .map(|p| p.into_iter().map(|r| Reading { d: [r.d[0], r.d[1], r.d[1]], ..r }).collect())
            .collect();
        assert_eq!(duplicate_observers(&twice), Some((1, 2, 1.0)));
        assert_eq!(duplicate_observers(&twice[..1]), Some((1, 2, 1.0)), "40 ticks");
        let few: Vec<Vec<Reading>> = vec![twice[0][..20].to_vec()];
        assert_eq!(duplicate_observers(&few), None, "too few ticks to tell");
    }

    #[test]
    fn infer_observers_recovers_their_distance_along_the_diagonals() {
        for r in [CORNER_R_M, 150_000.0, 235_000.0] {
            for triple in [[0, 1, 2], [0, 1, 6]] {
                let truth = observers_at(triple, r);
                let fit = infer_observers(&flying(truth), None);
                assert_eq!(fit_shape(&fit), shape(observers_at(triple, CORNER_R_M)), "R={r}: {fit:?}");
                assert!((fit.r_m - r).abs() < 2_000.0, "R={r}: fitted {:.0}", fit.r_m);
            }
        }
    }

    #[test]
    fn a_known_observer_distance_is_kept() {
        let truth = observers_at([0, 1, 2], 235_000.0);
        let fit = infer_observers(&flying(truth), Some(235_000.0));
        assert_eq!(fit.r_m, 235_000.0);
        assert_eq!(fit_shape(&fit), shape(observers_at([0, 1, 2], CORNER_R_M)));
    }

    /// What the overview shows for a ship flying `path` (one point per second): distances rounded
    /// to whole km, and its speed.
    fn observe(obs: [V3; 3], path: &[V3]) -> Vec<Reading> {
        path.iter()
            .enumerate()
            .map(|(t, &p)| {
                let speed = match (t.checked_sub(1).map(|i| path[i]), path.get(t + 1)) {
                    (_, Some(&next)) => dist(next, p),
                    (Some(prev), None) => dist(p, prev),
                    (None, None) => 0.0,
                };
                Reading { t: t as f64, d: rounded(obs, p), speed_mps: Some(speed) }
            })
            .collect()
    }

    fn max_error(fixes: &[Fix], path: &[V3]) -> f64 {
        fixes.iter().zip(path).map(|(f, p)| dist(f.p, *p)).fold(0.0, f64::max)
    }

    fn max_step(fixes: &[Fix]) -> f64 {
        fixes.windows(2).map(|w| dist(w[1].p, w[0].p)).fold(0.0, f64::max)
    }

    #[test]
    fn track_stays_on_its_branch_across_the_observers_plane() {
        let c = corners();
        let obs = [c[0], c[1], c[2]]; // the z = 0 face
        // Starts inside the cube, flies down through z = 0 and out the other side.
        let path: Vec<V3> = (0..40)
            .map(|t| [30_000.0 + 500.0 * t as f64, 40_000.0, 20_000.0 - 1_000.0 * t as f64])
            .collect();
        let fixes = solve_track(obs, &observe(obs, &path));
        // Once out of the plane by more than the rounding can blur, it's on the right side.
        for (f, p) in fixes.iter().zip(&path).filter(|(_, p)| p[2].abs() > 5_000.0) {
            assert!(f.p[2].signum() == p[2].signum(), "t={}: {:?} vs {:?}", f.t, f.p, p);
        }
        assert!(max_error(&fixes, &path) < 2_500.0, "{}", max_error(&fixes, &path));
    }

    #[test]
    fn rounding_near_the_observers_plane_does_not_throw_the_track_around() {
        let c = corners();
        let obs = [c[0], c[3], c[7]]; // their plane, x = y, runs through the centre
        // Drifting at 100 m/s, about 5 km off the plane, ~80 km from the observers.
        let path: Vec<V3> = (0..120)
            .map(|t| {
                let s = t as f64 * 100.0 / 2f64.sqrt();
                [55_000.0 + s, 50_000.0 + s, 45_000.0]
            })
            .collect();
        let readings = observe(obs, &path);
        let per_tick: Vec<(f64, [f64; 3])> = readings.iter().map(|r| (r.t, r.d)).collect();
        // Per-tick trilateration really is that bad here, as the filter's reason to exist.
        let jumpy = per_tick.iter().map(|&(_, d)| trilaterate(obs, d).roots).collect::<Vec<_>>();
        let worst = jumpy.windows(2).map(|w| dist(w[1][0], w[0][0]).min(dist(w[1][0], w[0][1]))).fold(0.0, f64::max);
        assert!(worst > 3_000.0, "{worst}");

        let fixes = solve_track(obs, &readings);
        assert!(max_step(&fixes) < 1_000.0, "{}", max_step(&fixes));
        let rms = (fixes.iter().zip(&path).map(|(f, p)| dist(f.p, *p).powi(2)).sum::<f64>()
            / path.len() as f64)
            .sqrt();
        assert!(rms < 2_000.0, "{rms}");
    }

    /// A ship parked through a 13 s countdown (the overview reading 0 or 1 m/s), then burning
    /// off along `dir` at up to 2 km/s.
    fn countdown_then_burn(obs: [V3; 3], start: V3, dir: V3) -> Vec<Reading> {
        let path: Vec<V3> = (0..60)
            .map(|t| {
                let s = (t as f64 - 13.0).max(0.0);
                let along = 0.5 * 300.0 * s.min(7.0).powi(2) + 2_100.0 * (s - 7.0).max(0.0);
                add(start, scale(dir, along))
            })
            .collect();
        let mut readings = observe(obs, &path);
        for (i, r) in readings[..13].iter_mut().enumerate() {
            r.speed_mps = Some((i % 2) as f64); // `observe` sees the burn a tick early
        }
        readings
    }

    #[test]
    fn a_ship_holding_still_through_the_countdown_does_not_move() {
        // The observers of a real scrim, whose plane (x = z) the starts sit close to: with no
        // speed to hold them, smoothing slid parked ships up to 22 km toward where they later flew.
        let obs = [[100_000.0, 0.0, 100_000.0], [0.0; 3], [100_000.0; 3]];
        let starts = [[71_000.0, 32_000.0, 65_000.0], [73_000.0, 71_000.0, 73_000.0], [66_000.0; 3], [79_000.0, 76_000.0, 78_000.0]];
        let dirs = [[1.0, 0.0, 0.0], [0.0, 0.0, -1.0], [-0.6, 0.0, 0.8], [0.0, 1.0, 0.0]];
        for start in starts {
            for dir in dirs {
                let fixes = solve_track(obs, &countdown_then_burn(obs, start, dir));
                let drift = fixes[..13].iter().map(|f| dist(f.p, fixes[0].p)).fold(0.0, f64::max);
                assert!(drift < 10.0, "{start:?} {dir:?}: drifted {drift} m before moving");
            }
        }
    }

    #[test]
    fn a_slow_ship_is_not_held_still() {
        let c = corners();
        let obs = [c[0], c[3], c[7]]; // their plane runs through the centre
        // Crawls at 25 m/s for 100 s, where only the speed shows which way along the plane.
        let path: Vec<V3> = (0..100).map(|t| [40_000.0 + 25.0 * t as f64, 30_000.0, 60_000.0]).collect();
        let fixes = solve_track(obs, &observe(obs, &path));
        let rms = (fixes.iter().zip(&path).map(|(f, p)| dist(f.p, *p).powi(2)).sum::<f64>()
            / path.len() as f64)
            .sqrt();
        assert!(rms < 4_000.0, "{rms}");
    }

    #[test]
    fn a_micro_jump_stays_a_single_hop() {
        let c = corners();
        let obs = [c[5], c[0], c[7]];
        // Starts inside the cube, flies 1 km/s along x, jumps 100 km along y in one tick at
        // t = 30, then flies on.
        let path: Vec<V3> = (0..60)
            .map(|t| {
                let hop = if t >= 30 { 100_000.0 } else { 0.0 };
                [20_000.0 + 1_000.0 * t as f64, 5_000.0 + hop, 40_000.0]
            })
            .collect();
        let mut readings = observe(obs, &path);
        readings[29].speed_mps = Some(1_000.0); // the jump isn't flown
        let fixes = solve_track(obs, &readings);
        let hop = dist(fixes[30].p, fixes[29].p);
        assert!((hop - 100_000.0).abs() < 5_000.0, "{hop}");
        let others = fixes.windows(2).enumerate().filter(|(i, _)| *i != 29).map(|(_, w)| dist(w[1].p, w[0].p));
        assert!(others.fold(0.0, f64::max) < 2_500.0);
        assert!(max_error(&fixes, &path) < 3_000.0, "{}", max_error(&fixes, &path));
    }

    #[test]
    fn a_turn_and_hard_burn_is_followed() {
        let obs = observers_at([0, 3, 1], 301_000.0); // plane far below the cube
        // Coasts down at 300 m/s, then turns and burns along y at 900 m/s² to 3.9 km/s. The speed
        // jumps a tick before the distances show the turn; folded in along the old heading, it
        // threw the track kilometres down.
        let path: Vec<V3> = (0..45)
            .map(|t| {
                let t = t as f64;
                let coast = 300.0 * t.min(15.0) + 900.0 * (1.0 - (-(t - 15.0).max(0.0) / 3.0).exp());
                let s = (t - 15.0).max(0.0);
                let ta = 3_900.0 / 900.0;
                let along = if s <= ta { 450.0 * s * s } else { 450.0 * ta * ta + 3_900.0 * (s - ta) };
                [0.0, 2_000.0 + along, 90_000.0 - 0.3 * coast]
            })
            .collect();
        let fixes = solve_track(obs, &observe(obs, &path));
        assert!(max_error(&fixes, &path) < 3_000.0, "{}", max_error(&fixes, &path));
    }

    #[test]
    fn a_gap_in_the_readings_does_not_flip_the_track_to_its_mirror() {
        let obs = observers_at([0, 1, 2], 295_000.0); // plane far below the cube
        // Climbs 400 m/s in z, then unread for 22 s while it turns and burns 2 km/s down and back
        // along x, then flies on. The velocity carried over the gap matches the mirror's motion.
        let path: Vec<V3> = (0..80).map(turning).collect();
        let mut readings = observe(obs, &path);
        readings.drain(31..53);
        let kept: Vec<V3> = path.iter().enumerate().filter(|(t, _)| !(31..53).contains(t)).map(|(_, p)| *p).collect();
        let fixes = solve_track(obs, &readings);
        assert!(max_error(&fixes, &kept) < 5_000.0, "{}", max_error(&fixes, &kept));
    }

    /// The flight of the gap test above: climbing, then a hard turn and burn at t = 30.
    fn turning(t: usize) -> V3 {
        let t = t as f64;
        if t <= 30.0 {
            [50_000.0, 60_000.0, 50_000.0 + 400.0 * t]
        } else {
            [50_000.0 - 1_200.0 * (t - 30.0), 60_000.0, 62_000.0 - 1_500.0 * (t - 30.0)]
        }
    }

    /// `path`'s readings with observer A missing from t = 31 to 52.
    fn a_lost(obs: [V3; 3], path: &[V3]) -> Vec<Reading> {
        let mut readings = observe(obs, path);
        for r in &mut readings[31..53] {
            r.d[0] = f64::NAN;
        }
        readings
    }

    #[test]
    fn a_track_carries_on_through_one_observer_losing_the_pilot() {
        let obs = observers_at([0, 1, 2], 295_000.0);
        // Steady flight: two observers and the speed hold it until A sees it again.
        let path: Vec<V3> = (0..80).map(|t| [30_000.0 + 600.0 * t as f64, 60_000.0, 40_000.0 + 300.0 * t as f64]).collect();
        let fixes = solve_track(obs, &a_lost(obs, &path));
        assert_eq!(fixes.len(), path.len());
        assert!(max_error(&fixes, &path) < 3_000.0, "{}", max_error(&fixes, &path));
    }

    #[test]
    fn a_partial_stretch_the_next_full_reading_rejects_is_dropped() {
        let obs = observers_at([0, 1, 2], 295_000.0);
        // Turning while A is gone: the stretch drifts, so it goes and the track restarts.
        let path: Vec<V3> = (0..80).map(turning).collect();
        let fixes = solve_track(obs, &a_lost(obs, &path));
        let kept: Vec<V3> = fixes.iter().map(|f| path[f.t as usize]).collect();
        assert!(fixes.len() < path.len());
        assert!(max_error(&fixes, &kept) < 5_000.0, "{}", max_error(&fixes, &kept));
    }

    #[test]
    fn partial_readings_alone_start_no_track() {
        let obs = observers_at([0, 1, 2], 295_000.0);
        let mut readings = observe(obs, &[[50_000.0; 3]; 5]);
        for r in &mut readings[..2] {
            r.d[1] = f64::NAN;
        }
        let fixes = solve_track(obs, &readings);
        assert_eq!(fixes.iter().map(|f| f.t).collect::<Vec<_>>(), [2.0, 3.0, 4.0]);
    }

    #[test]
    fn direction_of_a_straight_line_and_of_a_stationary_ship() {
        let moving: Vec<Fix> = (0..10)
            .map(|t| Fix { t: t as f64, p: [300.0 * t as f64, 400.0 * t as f64, 0.0], residual_m: 0.0 })
            .collect();
        let d = direction(&moving, 5, 3.0).unwrap();
        assert!((d[0] - 0.6).abs() < 1e-9 && (d[1] - 0.8).abs() < 1e-9 && d[2].abs() < 1e-9);

        let still: Vec<Fix> = (0..10)
            .map(|t| Fix { t: t as f64, p: [50_000.0 + (t % 2) as f64 * 400.0, 0.0, 0.0], residual_m: 0.0 })
            .collect();
        assert!(direction(&still, 5, 3.0).is_none());
    }
}
