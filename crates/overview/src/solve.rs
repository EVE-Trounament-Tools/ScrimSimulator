//! Position from distances (DESIGN.md S2.1) for the three-observer cube setup: the observers sit
//! on three distinct corners of a [`CUBE_M`]-sided cube, which three is not known up front, and
//! every pilot starts inside the cube.
//!
//! Three spheres meet in two points mirrored through the observers' plane. The cube resolves that
//! twice. First, [`infer_corners`] tries every ordered corner triple and keeps the one whose
//! trilaterated starting positions are consistent (the spheres actually meet) and lie inside the
//! cube, and whose tracks move at the speed the overview shows. Second, [`solve_track`] picks a
//! pilot's first root by the same inside-the-cube rule and follows later roots by continuity.

pub type V3 = [f64; 3];

/// Cube side length: the observers are on its corners.
pub const CUBE_M: f64 = 100_000.0;

fn sub(a: V3, b: V3) -> V3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn add(a: V3, b: V3) -> V3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

fn scale(a: V3, k: f64) -> V3 {
    [a[0] * k, a[1] * k, a[2] * k]
}

fn dot(a: V3, b: V3) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

fn cross(a: V3, b: V3) -> V3 {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

pub fn norm(a: V3) -> f64 {
    dot(a, a).sqrt()
}

fn dist(a: V3, b: V3) -> f64 {
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
/// speed for that tick when it was read.
#[derive(Clone, Copy, Debug)]
pub struct Reading {
    pub t: f64,
    pub d: [f64; 3],
    pub speed_mps: Option<f64>,
}

/// The corner triple [`infer_corners`] settled on.
#[derive(Clone, Copy, Debug)]
pub struct CornerFit {
    /// Positions of observers A, B, C (in the order of the distance triples).
    pub corners: [V3; 3],
    /// Cost of the chosen triple: [`CornerCost::total`].
    pub score: f64,
    pub cost: CornerCost,
    /// The best cost among triples with a *different* shape (side lengths in A/B/C order), so
    /// a caller can tell a clear winner from a near-tie. `INFINITY` if there is no other shape.
    pub runner_up: f64,
    /// That runner-up triple, if any.
    pub runner_up_corners: Option<[V3; 3]>,
}

/// How close (relative) the best other-shaped corner triple may score before the choice is
/// ambiguous...
const AMBIGUITY_RATIO: f64 = 1.5;
/// ...or how close in absolute terms (metres of cost), which also catches a tie at 0.
const AMBIGUITY_MARGIN_M: f64 = 500.0;

impl CornerFit {
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

/// Pick the observers' corners from the pilots' readings (each pilot's time-ordered).
///
/// Every ordered triple of distinct corners (8·7·6 = 336) gets a start cost: each early reading
/// costs its trilateration residual plus how far its nearer-to-the-cube root sits outside the
/// cube. Triples related by a cube symmetry score identically and give the same answer up to a
/// rotation or reflection of the output frame, so only the best triple per shape goes on.
///
/// The start alone is ambiguous when every pilot starts far from every observer (near the
/// centre): then every shape fits. So each shape's whole match is also solved and its speed
/// compared with the overview's Velocity (see [`speed_error`]): a wrong shape distorts distances,
/// so its tracks move at the wrong speed.
pub fn infer_corners(pilots: &[Vec<Reading>]) -> CornerFit {
    let c = corners();
    let mut best: Vec<([u64; 3], [V3; 3], f64)> = Vec::new(); // best start cost per shape
    let n_start = pilots.iter().map(|p| p.len().min(START_TICKS)).sum::<usize>().max(1) as f64;
    for a in 0..8 {
        for b in (0..8).filter(|&b| b != a) {
            for cc in (0..8).filter(|&x| x != a && x != b) {
                let obs = [c[a], c[b], c[cc]];
                let cost: f64 = pilots
                    .iter()
                    .flat_map(|p| p.iter().take(START_TICKS))
                    .map(|r| {
                        let tri = trilaterate(obs, r.d);
                        let out = tri.roots.map(outside_cube_m);
                        tri.residual_m + out[0].min(out[1])
                    })
                    .sum::<f64>()
                    / n_start;
                let shape = [dist(obs[0], obs[1]), dist(obs[0], obs[2]), dist(obs[1], obs[2])]
                    .map(|s| s.round() as u64);
                match best.iter_mut().find(|e| e.0 == shape) {
                    Some(e) if cost < e.2 => *e = (shape, obs, cost),
                    Some(_) => {}
                    None => best.push((shape, obs, cost)),
                }
            }
        }
    }
    let mut scored: Vec<([V3; 3], CornerCost)> = best
        .into_iter()
        .map(|(_, obs, start_m)| (obs, CornerCost { start_m, speed_err: speed_error(obs, pilots) }))
        .collect();
    scored.sort_by(|x, y| x.1.total().total_cmp(&y.1.total()));
    CornerFit {
        corners: scored[0].0,
        score: scored[0].1.total(),
        cost: scored[0].1,
        runner_up: scored.get(1).map_or(f64::INFINITY, |e| e.1.total()),
        runner_up_corners: scored.get(1).map(|e| e.0),
    }
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
        let triples: Vec<(f64, [f64; 3])> = p.iter().map(|r| (r.t, r.d)).collect();
        let fixes = solve_track(obs, &triples);
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

/// Gap (s) beyond which the last two fixes are too old to extrapolate from; the root nearest the
/// last fix is used instead.
const PREDICT_MAX_GAP_S: f64 = 5.0;

/// Solve one pilot's track from its time-ordered `(t, [d_A, d_B, d_C])` readings. The first
/// fix takes the root inside the cube (pilots start there). Later fixes take the root nearest a
/// constant-velocity extrapolation of the previous two fixes. Plain nearest-to-last would bounce
/// a ship that crosses the observers' plane back to the side it came from.
pub fn solve_track(obs: [V3; 3], readings: &[(f64, [f64; 3])]) -> Vec<Fix> {
    let centre = [CUBE_M / 2.0; 3];
    let mut fixes: Vec<Fix> = Vec::with_capacity(readings.len());
    for &(t, d) in readings {
        let tri = trilaterate(obs, d);
        let target = match fixes.as_slice() {
            [] => None,
            [.., a, b] if t - b.t <= PREDICT_MAX_GAP_S && b.t - a.t > 0.0 => {
                let v = scale(sub(b.p, a.p), 1.0 / (b.t - a.t));
                Some(add(b.p, scale(v, t - b.t)))
            }
            [.., b] => Some(b.p),
        };
        let cost = |p: V3| match target {
            Some(q) => (dist(p, q), 0.0),
            None => (outside_cube_m(p), dist(p, centre)),
        };
        let (c0, c1) = (cost(tri.roots[0]), cost(tri.roots[1]));
        let p = if c1.0 < c0.0 || (c1.0 == c0.0 && c1.1 < c0.1) { tri.roots[1] } else { tri.roots[0] };
        fixes.push(Fix { t, p, residual_m: tri.residual_m });
    }
    fixes
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

    #[test]
    fn infer_corners_recovers_the_shape_from_rounded_distances() {
        let c = corners();
        for truth in [[c[0], c[1], c[2]], [c[0], c[1], c[6]], [c[0], c[3], c[5]], [c[7], c[2], c[4]]] {
            let readings = standing(truth, &points(20));
            let fit = infer_corners(&readings);
            assert_eq!(shape(fit.corners), shape(truth));
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
        let fit = infer_corners(&standing(truth, &central_start()));
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
            let fit = infer_corners(&pilots);
            assert_eq!(shape(fit.corners), shape(truth), "{fit:?}");
            assert!(!fit.is_ambiguous(), "{fit:?}");
        }
    }

    #[test]
    fn track_stays_on_its_branch_across_the_observers_plane() {
        let c = corners();
        let obs = [c[0], c[1], c[2]]; // the z = 0 face
        // Starts inside the cube, flies down through z = 0 and out the other side.
        let path: Vec<(f64, V3)> = (0..40)
            .map(|t| (t as f64, [30_000.0 + 500.0 * t as f64, 40_000.0, 20_000.0 - 1_000.0 * t as f64]))
            .collect();
        let readings: Vec<(f64, [f64; 3])> = path.iter().map(|&(t, p)| (t, ranges(obs, p))).collect();
        let fixes = solve_track(obs, &readings);
        for (f, (_, p)) in fixes.iter().zip(&path) {
            assert!(dist(f.p, *p) < 1.0, "t={}: {:?} vs {:?}", f.t, f.p, p);
        }
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
