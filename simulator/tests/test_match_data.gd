extends "res://tests/test_case.gd"
## MatchData: CSV loading, team assignment, boundary deaths and track sampling.

const C := MatchData.CENTRE_M
const X := Vector3.RIGHT


func _load(rows: Array, radii := {}, move_threshold_m := 0.0) -> MatchData:
	return MatchData.load_csv(write_csv(rows), radii, move_threshold_m)


# --- load_csv ----------------------------------------------------------------

func test_load_missing_file_returns_null() -> void:
	assert_null(MatchData.load_csv(temp_dir().path_join("nope.csv")))


func test_load_missing_column_returns_null() -> void:
	var path := write_csv([[0, "A", "Rifter", 1, 2]], "t,pilot,ship_type,x_m,y_m")
	assert_null(MatchData.load_csv(path))


func test_load_header_only_returns_null() -> void:
	assert_null(_load([]))


func test_load_skips_blank_position_and_short_rows() -> void:
	var d := _load([
		row(0, "A", "Rifter", C),
		"5,A,Rifter,,,,0,0,0,0,0",
		"6,A,Rifter",
		row(7, "A", "Rifter", C + X),
	])
	assert_not_null(d)
	assert_eq(d.tracks["A"].size(), 2)
	assert_eq(d.tracks["A"][1].pos, C + X)


func test_load_sorts_samples_and_sets_time_range() -> void:
	var d := _load([
		row(13, "A", "Rifter", C),
		row(11, "A", "Rifter", C),
		row(12, "B", "Merlin", C),
		row(12, "A", "Rifter", C),
	])
	assert_eq(d.tracks["A"].map(func(s): return s.t), [11.0, 12.0, 13.0])
	assert_eq(d.tracks.keys().size(), 2)
	assert_eq(d.start_time, 11.0)
	assert_eq(d.duration, 2.0)


func test_load_reads_eve_times() -> void:
	var header := DEFAULT_HEADER + ",eve_time"
	var path := write_csv([
		row(1, "A", "Rifter", C) + ["2026-04-05T00:00:00.000Z"],
		row(0, "A", "Rifter", C) + ["2026-04-04T23:59:59.000Z"],
		row(2, "B", "Merlin", C) + ["2026-04-05T00:00:01.000Z"],
	], header)
	var d := MatchData.load_csv(path)
	assert_eq(d.eve_start, "2026-04-04T23:59:59.000Z")
	assert_eq(d.eve_end, "2026-04-05T00:00:01.000Z")
	assert_eq(d.tracks["A"][1].eve_time, "2026-04-05T00:00:00.000Z")


func test_load_without_eve_times() -> void:
	var d := _load([row(0, "A", "Rifter", C)])
	assert_eq(d.eve_start, "")
	assert_eq(d.eve_end, "")
	assert_false(d.tracks["A"][0].has("eve_time"))
	assert_false(d.has_eve_time())
	assert_true(is_nan(d.eve_unix_at(0.0)))


func test_eve_time_of_match_time() -> void:
	var header := DEFAULT_HEADER + ",eve_time"
	var rows := []
	for t in [10, 12, 14, 16]:
		rows.append(row(t, "A", "Rifter", C + X * (0.0 if t < 14 else 1000.0)) + ["2026-04-05T00:00:%02d.000Z" % t])
	var path := write_csv(rows, header)
	var start := CombatLog.parse_eve_time("2026-04-05T00:00:10.000Z")
	var d := MatchData.load_csv(path)
	assert_true(d.has_eve_time())
	assert_eq(d.eve_unix_start, start)
	assert_eq(d.start_time, 12.0, "countdown skipped")
	assert_eq(d.eve_unix_at(0.0), start + 2.0)
	assert_eq(d.match_time_of(start + 5.0), 3.0)
	d = MatchData.load_csv(path, {}, 0.0, true)
	assert_eq(d.eve_unix_at(0.0), start, "lead-in kept")
	assert_eq(d.match_time_of(start + 5.0), 5.0)


func test_load_skips_countdown_before_first_move() -> void:
	var d := _load([
		row(0, "A", "Rifter", C),
		row(5, "A", "Rifter", C),
		row(6, "A", "Rifter", C + X * 1000),
		row(8, "A", "Rifter", C + X * 3000),
	])
	assert_eq(d.start_time, 5.0, "match starts at the sample before the first move")
	assert_eq(d.duration, 3.0)
	assert_eq(d.sample("A", 0.0).pos, C)
	assert_eq(d.sample("A", 1.0).pos, C + X * 1000)


func test_load_keep_lead_in_starts_at_first_sample() -> void:
	var d := MatchData.load_csv(write_csv([
		row(2, "A", "Rifter", C),
		row(5, "A", "Rifter", C),
		row(6, "A", "Rifter", C + X * 1000),
		row(8, "A", "Rifter", C + X * 3000),
	]), {}, 0.0, true)
	assert_eq(d.start_time, 2.0, "countdown kept")
	assert_eq(d.duration, 6.0)
	assert_eq(d.sample("A", 4.0).pos, C + X * 1000)


func test_load_ignores_jitter_under_threshold_when_finding_start() -> void:
	var rows := [
		row(0, "A", "Rifter", C),
		row(1, "A", "Rifter", C + X * 450),
		row(2, "A", "Rifter", C),
		row(3, "A", "Rifter", C + X * 2000),
	]
	assert_eq(_load(rows, {}, 500.0).start_time, 2.0)
	assert_eq(_load(rows).start_time, 0.0, "without a threshold any movement starts the match")


func test_load_starts_at_earliest_mover() -> void:
	var d := _load([
		row(0, "late", "Rifter", C),
		row(7, "late", "Rifter", C),
		row(8, "late", "Rifter", C + X * 1000),
		row(0, "early", "Merlin", C),
		row(3, "early", "Merlin", C),
		row(4, "early", "Merlin", C + X * 1000),
		row(10, "early", "Merlin", C + X * 2000),
	])
	assert_eq(d.start_time, 3.0)
	assert_eq(d.duration, 7.0)


func test_load_reads_sample_fields() -> void:
	var d := _load([row(1.5, "A Pilot", "Rifter", Vector3(1, 2, 3))])
	var s: Dictionary = d.tracks["A Pilot"][0]
	assert_eq(s.t, 1.5)
	assert_eq(s.pos, Vector3(1, 2, 3))
	assert_eq(s.ship_type, "Rifter")


func test_load_reads_csv_speed() -> void:
	var d := _load(["0,A,Rifter,1,2,3,412.5,0,0,0,0", "1,A,Rifter,1,2,3,,0,0,0,0"])
	assert_eq(d.tracks["A"][0].speed, 412.5)
	assert_true(is_nan(d.tracks["A"][1].speed), "blank speed is unknown")


func test_load_without_speed_column_has_unknown_speed() -> void:
	var path := write_csv(["0,A,Rifter,1,2,3"], "t,pilot,ship_type,x_m,y_m,z_m")
	assert_true(is_nan(MatchData.load_csv(path).tracks["A"][0].speed))


func test_sample_speed_steps_instead_of_interpolating() -> void:
	var d := _load(["0,A,Rifter,0,0,0,100,0,0,0,0", "2,A,Rifter,500,0,0,300,0,0,0,0"])
	assert_eq(d.sample("A", 0.0).speed, 100.0)
	assert_eq(d.sample("A", 1.9).speed, 100.0)
	assert_eq(d.sample("A", 2.0).speed, 300.0)
	d.smooth = true
	assert_eq(d.sample("A", 1.0).speed, 100.0)


func test_load_tolerates_reordered_padded_header() -> void:
	var path := write_csv(["Rifter,0,1,2,3,A"], " ship_type , t , x_m , y_m , z_m , pilot ")
	var d := MatchData.load_csv(path)
	assert_not_null(d)
	assert_eq(d.tracks["A"][0].pos, Vector3(1, 2, 3))
	assert_eq(d.tracks["A"][0].ship_type, "Rifter")


func test_radius_m_is_case_insensitive() -> void:
	var d := _load([row(0, "A", "Rifter", C)], {"rifter": 31.0})
	assert_eq(d.radius_m("RIFTER"), 31.0)
	assert_eq(d.radius_m("Rifter"), 31.0)
	assert_eq(d.radius_m("Unknown Hull"), 0.0)


# --- teams -------------------------------------------------------------------

func test_two_corners_become_blue_and_red_by_corner_index() -> void:
	# Corner 7 has more pilots, but the lower corner index is always BLUE.
	var d := _load([
		row(0, "r1", "x", on_line(7, 0.5)),
		row(0, "r2", "x", on_line(7, 0.8)),
		row(0, "r3", "x", on_line(7, 0.3)),
		row(0, "b1", "x", on_line(2, 0.5)),
		row(0, "b2", "x", on_line(2, 0.9)),
	])
	for p in ["b1", "b2"]:
		assert_eq(d.teams[p], MatchData.Team.BLUE, p)
	for p in ["r1", "r2", "r3"]:
		assert_eq(d.teams[p], MatchData.Team.RED, p)


func test_third_corner_is_unknown() -> void:
	var d := _load([
		row(0, "a1", "x", on_line(0, 0.5)),
		row(0, "a2", "x", on_line(0, 0.6)),
		row(0, "b1", "x", on_line(7, 0.5)),
		row(0, "b2", "x", on_line(7, 0.6)),
		row(0, "c1", "x", on_line(3, 0.5)),
	])
	assert_eq(d.teams["a1"], MatchData.Team.BLUE)
	assert_eq(d.teams["b1"], MatchData.Team.RED)
	assert_eq(d.teams["c1"], MatchData.Team.UNKNOWN)


func test_pilot_near_centre_is_unknown() -> void:
	var d := _load([
		row(0, "a", "x", on_line(0, 0.5)),
		row(0, "b", "x", on_line(7, 0.5)),
		row(0, "mid", "x", C + X * (MatchData.CENTRE_RADIUS_M - 1.0)),
	])
	assert_eq(d.teams["mid"], MatchData.Team.UNKNOWN)


func test_pilot_off_every_line_is_unknown() -> void:
	# ~32.7 km from each corner->centre line, well beyond LINE_TOLERANCE_M.
	var d := _load([
		row(0, "a", "x", on_line(0, 0.5)),
		row(0, "b", "x", on_line(7, 0.5)),
		row(0, "off", "x", C + Vector3(0, 0, 40000)),
	])
	assert_eq(d.teams["off"], MatchData.Team.UNKNOWN)


func test_pilot_within_line_tolerance_is_assigned() -> void:
	var p := on_line(0, 0.5) + Vector3(1, -1, 0).normalized() * (MatchData.LINE_TOLERANCE_M - 100.0)
	var d := _load([
		row(0, "near", "x", p),
		row(0, "b", "x", on_line(7, 0.5)),
	])
	assert_eq(d.teams["near"], MatchData.Team.BLUE)


func test_team_comes_from_first_position() -> void:
	var d := _load([
		row(0, "a", "x", on_line(0, 0.5)),
		row(10, "a", "x", on_line(7, 0.5)),
		row(0, "b", "x", on_line(7, 0.5)),
	])
	assert_eq(d.teams["a"], MatchData.Team.BLUE)
	assert_eq(d.teams["b"], MatchData.Team.RED)


func test_single_corner_is_blue() -> void:
	var d := _load([row(0, "a", "x", on_line(5, 0.5)), row(0, "b", "x", on_line(5, 0.7))])
	assert_eq(d.teams["a"], MatchData.Team.BLUE)
	assert_eq(d.teams["b"], MatchData.Team.BLUE)


# --- deaths ------------------------------------------------------------------

func test_pilot_inside_boundary_has_no_death() -> void:
	var d := _load([row(0, "a", "x", C), row(10, "a", "x", C + X * 120000.0)])
	assert_false(d.deaths.has("a"))


func test_boundary_crossing_is_interpolated() -> void:
	var d := _load([
		row(10, "early", "x", C),
		row(11, "early", "x", C + X * 1000.0),
		row(20, "a", "x", C + X * 100000.0),
		row(30, "a", "x", C + X * 150000.0),
	])
	assert_true(d.deaths.has("a"))
	# Halfway between samples; time is relative to the match start (t=10).
	assert_almost(d.deaths["a"].t, 15.0)
	assert_almost(d.deaths["a"].pos, C + X * MatchData.BOUNDARY_RADIUS_M, 1.0)
	assert_false(d.deaths.has("early"))


func test_first_sample_outside_dies_there() -> void:
	var p := C + Vector3(0, 130000, 0)
	var d := _load([row(4, "start", "x", C), row(5, "start", "x", C + X * 1000.0), row(6, "a", "x", p), row(8, "a", "x", C)])
	assert_eq(d.deaths["a"].t, 2.0)
	assert_eq(d.deaths["a"].pos, p)


func test_first_crossing_wins_after_reentry() -> void:
	var d := _load([
		row(0, "a", "x", C + X * 100000.0),
		row(10, "a", "x", C + X * 150000.0),
		row(20, "a", "x", C + X * 100000.0),
		row(30, "a", "x", C + X * 200000.0),
	])
	assert_almost(d.deaths["a"].t, 5.0)


func test_hull_radius_brings_boundary_closer() -> void:
	var rows := [row(0, "a", "Big Hull", C), row(10, "a", "Big Hull", C + X * 110000.0)]
	assert_false(_load(rows).deaths.has("a"), "unknown size is a point")
	var d := _load(rows, {"big hull": 20000.0})
	assert_true(d.deaths.has("a"), "20 km hull reaches 125 km at 105 km")
	assert_almost(d.deaths["a"].t, 10.0 * 105.0 / 110.0)
	assert_almost(d.deaths["a"].pos, C + X * 105000.0, 1.0)


func test_boundary_crossing_fraction() -> void:
	assert_almost(MatchData._boundary_crossing(C, C + X * 200.0, 100.0), 0.5)
	assert_almost(MatchData._boundary_crossing(C + X * 50.0, C + X * 150.0, 100.0), 0.5)
	# Degenerate segment.
	assert_eq(MatchData._boundary_crossing(C + X * 200.0, C + X * 200.0, 100.0), 1.0)
	# Both ends inside: the crossing lies beyond b, so it's clamped.
	assert_eq(MatchData._boundary_crossing(C, C + X * 50.0, 100.0), 1.0)


# --- events ------------------------------------------------------------------

func _kinds(d: MatchData) -> Array:
	return d.events.map(func(e): return e.kind)


func test_capsule_change_is_a_death_event() -> void:
	var d := _load([
		row(10, "a", "Venture", C),
		row(11, "a", "Venture", C + X),
		row(12, "a", "Capsule", C + X * 2.0),
		row(13, "a", "Capsule", C + X * 3.0),
	])
	assert_eq(_kinds(d), [MatchData.Event.DEATH])
	assert_eq(d.events[0].t, 2.0)
	assert_eq(d.events[0].pilot, "a")
	assert_eq(d.events[0].ship_type, "Venture")
	assert_eq(d.events[0].pos, C + X * 2.0)


func test_lost_hull_is_the_hull_before_the_capsule() -> void:
	var d := _load([
		row(10, "a", "Venture", C),
		row(11, "a", "Venture", C + X),
		row(12, "a", "Capsule", C + X * 2.0),
		row(13, "a", "Capsule", C + X * 3.0),
		row(10, "pod", "Capsule", C),
	])
	assert_eq(d.lost_hull("a", 1.5), "")
	assert_eq(d.lost_hull("a", 2.0), "Venture")
	assert_eq(d.lost_hull("a", 2.5), "Venture")
	assert_eq(d.lost_hull("a", 100.0), "Venture", "after the track ends")
	assert_eq(d.lost_hull("a", -5.0), "", "before the track starts")
	assert_eq(d.lost_hull("pod", 1.0), "", "never had a hull")


func test_starting_in_a_capsule_is_not_a_death() -> void:
	var d := _load([row(0, "a", "Capsule", C), row(1, "a", "Capsule", C + X)])
	assert_eq(d.events, [])


func test_pod_stays_where_it_died() -> void:
	var d := _load([
		row(10, "a", "Venture", C),
		row(11, "a", "Venture", C + X),
		row(12, "a", "Capsule", C + X * 2.0),
		row(13, "a", "Capsule", C + X * 200000.0),  # warps off past the boundary
		row(10, "b", "Venture", C - X),
		row(20, "b", "Venture", C - X * 2.0),
	])
	assert_eq(_kinds(d), [MatchData.Event.DEATH], "the pod leaving isn't a boundary crossing")
	assert_eq(d.podded, {"a": 2.0})
	assert_eq(d.tracks["a"].size(), 3, "nothing after the pod is kept")
	for t in [2.0, 3.0, 10.0]:
		var s := d.sample("a", t)
		assert_eq(s.pos, C + X * 2.0, "held at %s" % t)
		assert_eq(s.ship_type, "Capsule")
		assert_true(is_nan(s.speed) and is_nan(s.hp.x), "nothing known of the pod")
	assert_eq(d.sample("a", 10.5), {}, "after the match ends")
	assert_eq(d.lost_hull("a", 10.0), "Venture")


func test_starting_in_a_capsule_is_still_tracked() -> void:
	var d := _load([row(0, "a", "Capsule", C), row(1, "a", "Capsule", C + X), row(2, "a", "Venture", C)])
	assert_eq(d.podded, {})
	assert_eq(d.sample("a", 1.0).pos, C + X)
	assert_eq(d.sample("a", 3.0), {})


func test_boundary_crossing_is_an_event() -> void:
	var d := _load([
		row(10, "early", "x", C),
		row(20, "a", "x", C + X * 100000.0),
		row(30, "a", "x", C + X * 150000.0),
	])
	assert_eq(_kinds(d), [MatchData.Event.BOUNDARY])
	assert_eq(d.events[0].t, d.deaths["a"].t)
	assert_eq(d.events[0].pos, d.deaths["a"].pos)
	assert_eq(d.events[0].ship_type, "x")


func test_100km_hop_is_an_mjd() -> void:
	var d := _load([
		row(0, "a", "Rifter", C),
		row(1, "a", "Rifter", C + X * 1000),
		row(2, "a", "Rifter", C + X * 101300),
		row(3, "a", "Rifter", C + X * 101400),
	])
	assert_eq(_kinds(d), [MatchData.Event.MJD])
	assert_eq(d.events[0].t, 2.0)
	assert_eq(d.events[0].pos, C + X * 1000)
	assert_eq(d.events[0].to_pos, C + X * 101300)
	assert_true(d.tracks["a"][2].get("mjd", false))


func test_mjd_spool_covers_the_12_ticks_before_a_jump() -> void:
	var rows := []
	for t in 21:
		rows.append(row(t, "a", "Rifter", C + X * 100 * t))
	rows.append(row(21, "a", "Rifter", C + X * 102000))
	var d := _load(rows)
	assert_eq(d.mjd_times["a"], PackedFloat64Array([21.0]))
	assert_eq(d.mjd_spool("a", 8.9), -1.0)
	assert_almost(d.mjd_spool("a", 9.0), 0.0)
	assert_almost(d.mjd_spool("a", 15.0), 0.5)
	assert_almost(d.mjd_spool("a", 20.9), 11.9 / 12.0)
	assert_eq(d.mjd_spool("a", 21.0), -1.0, "landed")
	assert_eq(d.mjd_spool("nobody", 15.0), -1.0)


func test_non_mjd_hops_are_ignored() -> void:
	var d := _load([
		row(0, "short", "Rifter", C),
		row(1, "short", "Rifter", C + X * 60000),
		row(0, "slow", "Rifter", C),
		row(30, "slow", "Rifter", C + X * 100000),  # across a gap
		row(0, "pod", "Capsule", C),
		row(1, "pod", "Capsule", C + X * 100000),  # capsules can't MJD
	])
	assert_eq(d.events, [])


func test_events_are_sorted_by_time() -> void:
	var d := _load([
		row(0, "late", "Venture", C),
		row(5, "late", "Capsule", C),
		row(0, "early", "Venture", C),
		row(1, "early", "Venture", C + Vector3.UP * 100000),
	])
	assert_eq(_kinds(d), [MatchData.Event.MJD, MatchData.Event.DEATH])


func test_mjd_out_of_bounds_dies_on_landing() -> void:
	var d := _load([
		row(0, "a", "Rifter", C + X * 50000),
		row(1, "a", "Rifter", C + X * 150000),
	])
	assert_eq(d.deaths["a"].t, 1.0)
	assert_eq(d.deaths["a"].pos, C + X * 150000)


func test_sample_holds_take_off_point_through_mjd() -> void:
	var d := _load([
		row(0, "a", "Rifter", C),
		row(1, "a", "Rifter", C + X * 1000),
		row(2, "a", "Rifter", C + X * 101000),
		row(3, "a", "Rifter", C + X * 102000),
	])
	assert_eq(d.sample("a", 1.5).pos, C + X * 1000)
	assert_eq(d.sample("a", 2.0).pos, C + X * 101000)
	d.smooth = true
	assert_eq(d.sample("a", 1.5).pos, C + X * 1000)
	# The spline after the jump ignores points before it: straight, even track stays linear.
	assert_almost(d.sample("a", 2.5).pos, C + X * 101500, 1.0)
	assert_almost(d.sample("a", 0.5).pos, C + X * 500, 1.0)


# --- sample ------------------------------------------------------------------

func _sample_data() -> MatchData:
	return _load([
		row(100, "p", "Rifter", Vector3(0, 0, 0)),
		row(102, "p", "Rifter", Vector3(20, 0, 0)),
		row(110, "p", "Rifter", Vector3(20, 80, 0)),  # 8 s gap > MAX_GAP_S
		row(114, "p", "Rifter", Vector3(20, 80, 40)),
	])


func test_sample_outside_track_is_empty() -> void:
	var d := _sample_data()
	assert_eq(d.sample("p", -0.5), {})
	assert_eq(d.sample("p", 14.5), {})


func test_sample_on_a_sample_returns_it() -> void:
	var d := _sample_data()
	assert_eq(d.sample("p", 0.0).pos, Vector3(0, 0, 0))
	assert_eq(d.sample("p", 2.0).pos, Vector3(20, 0, 0))
	assert_eq(d.sample("p", 14.0).pos, Vector3(20, 80, 40))


func test_sample_interpolates_relative_to_start() -> void:
	var d := _sample_data()
	var s := d.sample("p", 0.5)
	assert_almost(s.pos, Vector3(5, 0, 0))
	assert_almost(s.t, 100.5)
	assert_eq(s.ship_type, "Rifter", "ship type comes from the earlier sample")
	assert_almost(d.sample("p", 12.0).pos, Vector3(20, 80, 20))


func test_sample_in_gap_is_empty() -> void:
	var d := _sample_data()
	assert_eq(d.sample("p", 6.0), {})


func test_sample_gap_of_exactly_max_is_interpolated() -> void:
	var g := MatchData.MAX_GAP_S
	var d := _load([row(0, "p", "x", Vector3.ZERO), row(g, "p", "x", X * g)])
	assert_almost(d.sample("p", g / 2.0).pos, X * g / 2.0)


# --- smooth sample -------------------------------------------------------------

func test_smooth_sample_passes_through_samples() -> void:
	var d := _sample_data()
	d.smooth = true
	assert_eq(d.sample("p", 0.0).pos, Vector3(0, 0, 0))
	assert_eq(d.sample("p", 2.0).pos, Vector3(20, 0, 0))
	assert_eq(d.sample("p", 14.0).pos, Vector3(20, 80, 40))


func test_smooth_sample_on_straight_even_track_matches_linear() -> void:
	var d := _load([
		row(0, "p", "x", Vector3.ZERO), row(1, "p", "x", X * 10.0),
		row(2, "p", "x", X * 20.0), row(3, "p", "x", X * 30.0),
	])
	d.smooth = true
	for t in [0.25, 1.5, 2.75]:
		assert_almost(d.sample("p", t).pos, X * 10.0 * t)


func test_smooth_sample_curves_and_is_continuous() -> void:
	var d := _load([
		row(0, "p", "x", Vector3.ZERO), row(1, "p", "x", Vector3(10, 0, 0)),
		row(2, "p", "x", Vector3(10, 10, 0)),
	])
	d.smooth = true
	var mid: Vector3 = d.sample("p", 0.5).pos
	assert_true(mid.distance_to(Vector3(5, 0, 0)) > 0.1, "rounds the corner, not linear")
	var before: Vector3 = d.sample("p", 0.999).pos
	var after: Vector3 = d.sample("p", 1.001).pos
	assert_true(before.distance_to(after) < 0.1, "no jump at the sample")
	# Velocity is continuous too: both sides head the same way.
	var v_in: Vector3 = (before - d.sample("p", 0.99).pos).normalized()
	var v_out: Vector3 = (d.sample("p", 1.01).pos - after).normalized()
	assert_true(v_in.dot(v_out) > 0.99, "no kink at the sample")


func test_smooth_sample_respects_gaps() -> void:
	var d := _sample_data()
	d.smooth = true
	assert_eq(d.sample("p", 6.0), {})
	# Segments beside the gap still interpolate (mirrored neighbours, no NaN).
	var s: Vector3 = d.sample("p", 1.0).pos
	assert_true(s.is_finite())
	assert_almost(d.sample("p", 12.0).pos, Vector3(20, 80, 20))


# --- HP ------------------------------------------------------------------------

const HP_HEADER := "t,pilot,ship_type,x_m,y_m,z_m,speed_mps,dir_x,dir_y,dir_z,residual_m,shield,armor,hull"


## A stationary sample of pilot "A" at `t` with HP `hp` ("" for blank cells).
func _hp_row(t: float, hp: Variant) -> Array:
	var cells: Array = ["", "", ""] if hp is String else [hp.x, hp.y, hp.z]
	return row(t, "A", "Rifter", C) + cells


func _load_hp(hps: Array) -> MatchData:
	var rows := []
	for i in hps.size():
		rows.append(_hp_row(i, hps[i]))
	return MatchData.load_csv(write_csv(rows, HP_HEADER), {}, 0.0, true)


func test_hp_parsed() -> void:
	var d := _load_hp([Vector3(1, 1, 1), "", Vector3(0.5, 0.25, 1)])
	assert_true(d.has_hp)
	assert_eq(d.hp_at("A", 0.0), Vector3(1, 1, 1))
	assert_true(is_nan(d.hp_at("A", 1.0).x), "blank: unknown")
	assert_true(is_nan(d.hp_at("A", 1.5).y), "between samples: the earlier one's")
	assert_eq(d.hp_at("A", 2.0), Vector3(0.5, 0.25, 1))
	assert_true(is_nan(d.hp_at("A", 5.0).z), "after the track: unknown")


func test_hp_mid_interval_holds_earlier_sample() -> void:
	var d := _load_hp([Vector3(1, 1, 1), Vector3(0, 0.5, 1)])
	assert_eq(d.hp_at("A", 0.9), Vector3(1, 1, 1))
	d.smooth = true
	assert_eq(d.hp_at("A", 0.9), Vector3(1, 1, 1))


func test_no_hp_columns() -> void:
	var d := _load([row(0, "A", "Rifter", C), row(1, "A", "Rifter", C)])
	assert_false(d.has_hp)
	assert_true(is_nan(d.hp_at("A", 0.0).x))
	assert_false(d.taking_damage("A", 1.0))


func test_all_hp_blank() -> void:
	assert_false(_load_hp(["", ""]).has_hp)


func test_taking_damage_on_drop_and_held() -> void:
	var full := Vector3(1, 1, 1)
	var d := _load_hp([full, full, Vector3(0.95, 1, 1), Vector3(0.95, 1, 1), Vector3(0.95, 1, 1),
		Vector3(0.95, 1, 1), Vector3(0.95, 1, 1)])
	assert_false(d.taking_damage("A", 1.0))
	assert_false(d.taking_damage("A", 1.9))
	assert_true(d.taking_damage("A", 2.0))
	assert_eq(d.damage_times["A"], PackedFloat64Array([2.0]), "one hit, not repeated while HP holds")
	assert_true(d.taking_damage("A", 2.0 + MatchData.DAMAGE_HOLD_S - 0.1), "held after the hit")
	assert_false(d.taking_damage("A", 2.0 + MatchData.DAMAGE_HOLD_S), "steady again")


func test_damage_ignores_jitter() -> void:
	var d := _load_hp([Vector3(0, 0.7, 1), Vector3(0, 0.68, 1), Vector3(0, 0.7, 1), Vector3(0, 0.68, 1)])
	assert_false(d.damage_times.has("A"))


func test_slow_damage_caught_over_window() -> void:
	var d := _load_hp([Vector3(0, 0.9, 1), Vector3(0, 0.89, 1), Vector3(0, 0.88, 1), Vector3(0, 0.86, 1)])
	assert_eq(d.damage_times.get("A", PackedFloat64Array()), PackedFloat64Array([3.0]))


func test_damage_not_compared_across_long_blank() -> void:
	var rows := [_hp_row(0, Vector3(1, 1, 1))]
	for t in range(1, 5):
		rows.append(_hp_row(t, ""))
	rows.append(_hp_row(5, Vector3(0.5, 1, 1)))
	var d := MatchData.load_csv(write_csv(rows, HP_HEADER), {}, 0.0, true)
	assert_false(d.damage_times.has("A"), "older than the window")
