class_name MatchData
extends RefCounted
## Per-pilot position tracks loaded from a `scrim-positions` CSV:
## `t,pilot,ship_type,x_m,y_m,z_m,speed_mps,dir_x,dir_y,dir_z,residual_m`, optionally
## `shield,armor,hull` (remaining HP 0-1, blank while no observer had the pilot locked), plus `eve_time` (each tick's EVE time, ISO 8601 UTC) when it was made with
## `--chat-log` or `--t0`.
## Positions are metres in the observers' cube frame (0..100 km per axis).

## Samples further apart than this are treated as a gap: the ship is hidden in between.
const MAX_GAP_S := 5.0

## Teams start strung along lines from two cube corners to the centre.
enum Team { UNKNOWN = -1, BLUE = 0, RED = 1 }
const CUBE_M := 100000.0
const CENTRE_M := Vector3.ONE * CUBE_M / 2.0
## Arena boundary: pilots whose hull reaches further than this from the centre are out of
## bounds (dead).
const BOUNDARY_RADIUS_M := 125000.0
## Pilots starting this close to the centre can't be attributed to a corner line.
const CENTRE_RADIUS_M := 10000.0
## Max distance of a pilot's first position from a corner->centre line to count as on it.
const LINE_TOLERANCE_M := 10000.0
## A micro jump drive teleports its ship this far ahead; a hop between consecutive samples within
## `MJD_TOLERANCE_M` of it (and no longer than a gap apart) is taken as an MJD. Capsules can't fit
## one, which keeps pod warps out.
const MJD_DISTANCE_M := 100000.0
const MJD_TOLERANCE_M := 15000.0
const CAPSULE := "Capsule"
## Shield, armor and hull of a pilot whose HP isn't known.
const NAN_HP := Vector3(NAN, NAN, NAN)
## A pilot is taking damage when a layer reads lower than its previous reading and more than
## `DAMAGE_MIN_DROP` below its highest reading in the previous `DAMAGE_WINDOW_S` (ring reads
## jitter by about 0.02), and stays so for `DAMAGE_HOLD_S` after.
const DAMAGE_MIN_DROP := 0.03
## Smallest fall from the previous reading that counts as lower (not a repeat of the same value).
const DAMAGE_STEP := 0.005
const DAMAGE_WINDOW_S := 3.0
const DAMAGE_HOLD_S := 2.0

enum Event { DEATH, BOUNDARY, MJD }

## pilot name -> Array of { t: float, pos: Vector3 (metres), ship_type: String, speed: float
## (m/s as read from the overview; NAN if the CSV has none), hp: Vector3 (remaining shield, armor,
## hull 0-1; `NAN_HP` when blank) }, sorted by t.
## A sample its ship micro jumped to also has `mjd: true`; with an `eve_time` column, every sample
## has `eve_time: String`.
var tracks: Dictionary = {}
## pilot name -> Team, from each pilot's first position.
var teams: Dictionary = {}
## pilot name -> { t: float (match time, s since start), pos: Vector3 (metres) } where the
## pilot first crossed the arena boundary. Pilots who never left are absent.
var deaths: Dictionary = {}
## Notable moments, sorted by t: Array of { t: float (match time), pilot: String, kind: Event,
## pos: Vector3 (metres), ship_type: String (hull lost / flown) }; MJDs add `to_pos`, where the
## ship landed (`pos` is where it jumped from).
var events: Array = []
## Whether any sample has HP.
var has_hp := false
## pilot name -> match times (sorted) at which an HP reading showed a hit (see `DAMAGE_MIN_DROP`).
var damage_times: Dictionary = {}
## Lowercase ship type -> published hull radius in metres (from `ShipSizes`); unknown types
## count as points.
var radii: Dictionary = {}
## CSV time of match time 0: just before the first ship moves (or the first sample if none do,
## or if the lead-in is kept).
var start_time := 0.0
## Match time of the last sample.
var duration := 0.0
## EVE time (ISO 8601 UTC) of the CSV's first and last sample, for lining the match up with other
## EVE logs; "" when the CSV has no `eve_time` column.
var eve_start := ""
var eve_end := ""
## `eve_start` / `eve_end` as unix seconds (NAN without `eve_time`).
var eve_unix_start := NAN
var eve_unix_end := NAN
## CSV time of the first sample (whose EVE time is `eve_start`).
var first_t := 0.0
## `CombatLog`s of this match, synced to it; filled in by whoever loads the match.
var combat_logs: Array = []
## Follow a Catmull-Rom spline through the samples instead of straight lines between them.
var smooth := false


## A ship further than `move_threshold_m` from its first sample has started moving; the match
## (time 0) begins at the sample before the earliest such move, skipping the pre-match countdown.
## 0 counts any change of position. `keep_lead_in` starts the match at the first sample instead
## (a match with audio, which starts there too).
static func load_csv(path: String, ship_radii := {}, move_threshold_m := 0.0, keep_lead_in := false) -> MatchData:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Cannot open %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return null
	var header := f.get_csv_line()
	var col := {}
	for i in header.size():
		col[header[i].strip_edges()] = i
	for name in ["t", "pilot", "ship_type", "x_m", "y_m", "z_m"]:
		if not col.has(name):
			push_error("%s: missing column '%s' (expected a scrim-positions CSV)" % [path, name])
			return null

	var data := MatchData.new()
	data.radii = ship_radii
	var t_min := INF
	var t_max := -INF
	var speed_col: int = col.get("speed_mps", -1)
	var eve_col: int = col.get("eve_time", -1)
	var hp_cols: Array = ["shield", "armor", "hull"].map(func(c): return col.get(c, -1))
	while not f.eof_reached():
		var row := f.get_csv_line()
		if row.size() < header.size():
			continue
		var x: String = row[col["x_m"]]
		if x.is_empty():
			continue
		var t := float(row[col["t"]])
		var pilot: String = row[col["pilot"]]
		var s := {
			"t": t,
			"pos": Vector3(float(x), float(row[col["y_m"]]), float(row[col["z_m"]])),
			"ship_type": row[col["ship_type"]],
			"speed": _parse_speed(row[speed_col]) if speed_col >= 0 else NAN,
			"hp": _parse_hp(row, hp_cols),
		}
		if not is_nan(s.hp.x):
			data.has_hp = true
		if eve_col >= 0:
			s.eve_time = row[eve_col]
			if t < t_min:
				data.eve_start = s.eve_time
			if t > t_max:
				data.eve_end = s.eve_time
		if not data.tracks.has(pilot):
			data.tracks[pilot] = []
		data.tracks[pilot].append(s)
		t_min = minf(t_min, t)
		t_max = maxf(t_max, t)

	if data.tracks.is_empty():
		push_error("%s: no position rows" % path)
		return null
	for pilot in data.tracks:
		data.tracks[pilot].sort_custom(func(a, b): return a.t < b.t)
	var first_move := INF if keep_lead_in else data._find_start(move_threshold_m)
	data.start_time = first_move if first_move < INF else t_min
	data.first_t = t_min
	if not data.eve_start.is_empty():
		data.eve_unix_start = CombatLog.parse_eve_time(data.eve_start)
		data.eve_unix_end = CombatLog.parse_eve_time(data.eve_end)
	data.duration = t_max - data.start_time
	data._assign_teams()
	data._find_mjds()
	data._find_deaths()
	data._find_events()
	data._find_damage()
	return data


## Whether samples carry EVE times, so other EVE logs can be lined up with the match.
func has_eve_time() -> bool:
	return not is_nan(eve_unix_start)


## EVE time (unix s) at match time `t`; NAN without EVE times.
func eve_unix_at(t: float) -> float:
	return eve_unix_start + (start_time - first_t) + t


## EVE times (unix s) other logs are kept for: the CSV's span, `MAX_GAP_S` either side (their
## times are whole seconds): `[first, last]` (`Vector2` is too coarse for unix times).
func eve_window() -> PackedFloat64Array:
	return PackedFloat64Array([eve_unix_start - MAX_GAP_S, eve_unix_end + MAX_GAP_S])


## Match time at EVE time `eve_unix` (unix s); NAN without EVE times.
func match_time_of(eve_unix: float) -> float:
	return eve_unix - eve_unix_start - (start_time - first_t)


## Overview speed cell -> m/s, or NAN when blank.
static func _parse_speed(cell: String) -> float:
	cell = cell.strip_edges()
	return NAN if cell.is_empty() else float(cell)


## Shield, armor and hull cells of `row` -> Vector3, or `NAN_HP` when any is blank or missing.
static func _parse_hp(row: PackedStringArray, cols: Array) -> Vector3:
	var hp := NAN_HP
	for i in 3:
		if cols[i] < 0:
			return NAN_HP
		var cell := row[cols[i]].strip_edges()
		if cell.is_empty():
			return NAN_HP
		hp[i] = float(cell)
	return hp


## CSV time of the sample before the earliest move of any ship (beyond `threshold_m` from its
## first sample), or INF if no ship ever moves.
func _find_start(threshold_m: float) -> float:
	var start := INF
	for pilot in tracks:
		var track: Array = tracks[pilot]
		for i in range(1, track.size()):
			if track[i - 1].t >= start:
				break
			if track[i].pos.distance_to(track[0].pos) > threshold_m:
				start = track[i - 1].t
				break
	return start


## Puts each pilot on the corner->centre line nearest its first position; the two most
## populated corners become BLUE (lower corner index) and RED, everyone else is UNKNOWN.
func _assign_teams() -> void:
	var centre := CENTRE_M
	var corner_of := {}  # pilot -> corner index, or -1
	var counts := {}  # corner index -> pilot count
	for pilot in tracks:
		var p: Vector3 = tracks[pilot][0].pos
		var best := -1
		if p.distance_to(centre) >= CENTRE_RADIUS_M:
			var best_d := LINE_TOLERANCE_M
			for i in 8:
				var corner := Vector3(i & 1, (i >> 1) & 1, (i >> 2) & 1) * CUBE_M
				var d := p.distance_to(Geometry3D.get_closest_point_to_segment(p, centre, corner))
				if d < best_d:
					best_d = d
					best = i
		corner_of[pilot] = best
		if best >= 0:
			counts[best] = counts.get(best, 0) + 1

	var corners := counts.keys()
	corners.sort_custom(func(a, b): return counts[a] > counts[b])
	var team_corners := corners.slice(0, 2)
	team_corners.sort()
	for pilot in tracks:
		var idx := team_corners.find(corner_of[pilot])
		teams[pilot] = Team.UNKNOWN if idx < 0 else idx  # 0 = BLUE, 1 = RED


## Hull radius of `ship_type` in metres, or 0.0 if unknown.
func radius_m(ship_type: String) -> float:
	return radii.get(ship_type.to_lower(), 0.0)


## Records where each pilot's hull first touched the boundary sphere; later re-entry is ignored.
func _find_deaths() -> void:
	for pilot in tracks:
		var track: Array = tracks[pilot]
		for i in track.size():
			var b: Dictionary = track[i]
			# The ship centre may get this close before the hull reaches the boundary.
			var limit := maxf(BOUNDARY_RADIUS_M - radius_m(b.ship_type), 0.0)
			if b.pos.distance_to(CENTRE_M) <= limit:
				continue
			if i == 0 or b.get("mjd", false):
				# A jump teleports: the ship is outside the moment it lands.
				deaths[pilot] = {"t": maxf(b.t - start_time, 0.0), "pos": b.pos}
			else:
				var a: Dictionary = track[i - 1]
				var w := _boundary_crossing(a.pos, b.pos, limit)
				deaths[pilot] = {
					"t": maxf(lerpf(a.t, b.t, w) - start_time, 0.0), "pos": a.pos.lerp(b.pos, w),
				}
			break


## Flags samples a ship micro jumped to: an MJD-length hop from the previous sample, neither a
## capsule nor across a gap.
func _find_mjds() -> void:
	for pilot in tracks:
		var track: Array = tracks[pilot]
		for i in range(1, track.size()):
			var a: Dictionary = track[i - 1]
			var b: Dictionary = track[i]
			if a.ship_type == CAPSULE or b.ship_type == CAPSULE or b.t - a.t > MAX_GAP_S:
				continue
			if absf(a.pos.distance_to(b.pos) - MJD_DISTANCE_M) <= MJD_TOLERANCE_M:
				b.mjd = true


## Collects podding (first capsule sample after a hull), boundary crossings and MJDs into `events`.
func _find_events() -> void:
	events.clear()
	for pilot in tracks:
		var track: Array = tracks[pilot]
		for i in range(1, track.size()):
			var a: Dictionary = track[i - 1]
			var b: Dictionary = track[i]
			var t: float = b.t - start_time
			if t < 0.0:
				continue  # before the match started
			if b.ship_type == CAPSULE and a.ship_type != CAPSULE:
				events.append({"t": t, "pilot": pilot, "kind": Event.DEATH, "pos": b.pos, "ship_type": a.ship_type})
			if b.get("mjd", false):
				events.append({
					"t": t, "pilot": pilot, "kind": Event.MJD, "pos": a.pos, "to_pos": b.pos,
					"ship_type": a.ship_type,
				})
		if deaths.has(pilot):
			var death: Dictionary = deaths[pilot]
			var s := sample(pilot, death.t)
			events.append({
				"t": death.t, "pilot": pilot, "kind": Event.BOUNDARY, "pos": death.pos,
				"ship_type": s.get("ship_type", track[0].ship_type),
			})
	events.sort_custom(func(a, b): return a.t < b.t)


## Fills `damage_times`: each known-HP sample with a layer lower than in the previous known reading
## and more than `DAMAGE_MIN_DROP` below that layer's highest known reading in the previous
## `DAMAGE_WINDOW_S`.
func _find_damage() -> void:
	damage_times.clear()
	if not has_hp:
		return
	for pilot in tracks:
		var track: Array = tracks[pilot]
		var hits := PackedFloat64Array()
		for i in track.size():
			var b: Dictionary = track[i]
			if is_nan(b.hp.x):
				continue
			var top := Vector3(-INF, -INF, -INF)
			var prev := NAN_HP
			var j := i - 1
			while j >= 0 and b.t - track[j].t <= DAMAGE_WINDOW_S:
				if not is_nan(track[j].hp.x):
					top = top.max(track[j].hp)
					if is_nan(prev.x):
						prev = track[j].hp
				j -= 1
			for k in 3:
				if b.hp[k] < prev[k] - DAMAGE_STEP and top[k] - b.hp[k] > DAMAGE_MIN_DROP:
					hits.append(b.t - start_time)
					break
		if not hits.is_empty():
			damage_times[pilot] = hits


## Whether `pilot` took a hit (see `damage_times`) in the `DAMAGE_HOLD_S` up to match time `t`.
func taking_damage(pilot: String, t: float) -> bool:
	var hits: PackedFloat64Array = damage_times.get(pilot, PackedFloat64Array())
	if hits.is_empty():
		return false
	var i := hits.bsearch(t, false)  # first hit after t
	return i > 0 and t - hits[i - 1] < DAMAGE_HOLD_S


## `pilot`'s remaining shield, armor and hull (0-1) at match time `t`: those of the latest sample
## at or before `t`, `NAN_HP` when unknown.
func hp_at(pilot: String, t: float) -> Vector3:
	return sample(pilot, t).get("hp", NAN_HP)


## Fraction w in [0, 1] along a->b (a inside, b outside) where the segment hits the sphere of
## radius `r` around the centre.
static func _boundary_crossing(a: Vector3, b: Vector3, r: float) -> float:
	# Solve |a - c + w (b - a)|^2 = R^2 for w.
	var d := b - a
	var f := a - CENTRE_M
	var qa := d.dot(d)
	var qb := 2.0 * f.dot(d)
	var qc := f.dot(f) - r * r
	if qa == 0.0:
		return 1.0
	return clampf((-qb + sqrt(maxf(qb * qb - 4.0 * qa * qc, 0.0))) / (2.0 * qa), 0.0, 1.0)


## Interpolated state of `pilot` at match time `t` (seconds since start), or an empty
## Dictionary when the pilot has no data then (before first / after last sample, or in a gap).
## Ship type, speed and HP aren't interpolated: they're those of the latest sample at or before `t`.
func sample(pilot: String, t: float) -> Dictionary:
	var track: Array = tracks[pilot]
	t += start_time
	if track.is_empty() or t < track[0].t or t > track[-1].t:
		return {}
	var i := track.bsearch_custom(t, func(s, v): return s.t < v)
	# i = first sample with s.t >= t.
	if i < track.size() and is_equal_approx(track[i].t, t):
		return track[i]
	var a: Dictionary = track[i - 1]
	var b: Dictionary = track[i]
	if b.t - a.t > MAX_GAP_S:
		return {}
	if b.get("mjd", false):
		# Micro jumps are instant: hold the take-off point until the landing sample.
		return {"t": t, "pos": a.pos, "ship_type": a.ship_type, "speed": a.speed, "hp": a.hp}
	var w: float = (t - a.t) / (b.t - a.t)
	if not smooth:
		return {"t": t, "pos": a.pos.lerp(b.pos, w), "ship_type": a.ship_type, "speed": a.speed, "hp": a.hp}
	var pre := _neighbour(track, i - 2, a, b, a.get("mjd", false))
	var post := _neighbour(track, i + 1, b, a, i + 1 < track.size() and track[i + 1].get("mjd", false))
	var pos: Vector3 = a.pos.cubic_interpolate_in_time(
			b.pos, pre.pos, post.pos, w, b.t - a.t, pre.t - a.t, post.t - a.t)
	return {"t": t, "pos": pos, "ship_type": a.ship_type, "speed": a.speed, "hp": a.hp}


## Spline control point beyond `end` (away from `other`): `track[j]` if it exists and isn't
## across a gap or a micro jump (`jump`), else `other` mirrored through `end`.
static func _neighbour(track: Array, j: int, end: Dictionary, other: Dictionary, jump := false) -> Dictionary:
	if not jump and j >= 0 and j < track.size() and absf(track[j].t - end.t) <= MAX_GAP_S:
		return track[j]
	return {"t": end.t * 2.0 - other.t, "pos": end.pos * 2.0 - other.pos}
