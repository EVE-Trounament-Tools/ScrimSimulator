extends "res://tests/test_case.gd"
## MatchScore: head start from the points cap, enemy losses scored once at the time they happen.

const BLUE := MatchData.Team.BLUE
const RED := MatchData.Team.RED
const C := MatchData.CENTRE_M


func _rules() -> Ruleset:
	return Ruleset.load_id("ATXXII")


## A match whose `fleet` maps pilot -> [team, ship types flown in order] with `events`
## ([t, pilot, kind, ship_type]).
func _match(fleet: Dictionary, events := []) -> MatchData:
	var d := MatchData.new()
	for pilot in fleet:
		d.teams[pilot] = fleet[pilot][0]
		d.tracks[pilot] = []
		for i in fleet[pilot][1].size():
			d.tracks[pilot].append({"t": float(i), "pos": C, "ship_type": fleet[pilot][1][i]})
	for e in events:
		d.events.append({"t": e[0], "pilot": e[1], "kind": e[2], "pos": C, "ship_type": e[3]})
	return d


func test_values_and_head_start() -> void:
	var s := MatchScore.new(_match({
		"b1": [BLUE, ["Dominix"]], "b2": [BLUE, ["Dominix"]],  # 88
		"r1": [RED, ["Abaddon"]],  # 40
		"u": [MatchData.Team.UNKNOWN, ["Raven"]],
	}), _rules())
	assert_eq(s.values, {"b1": 44, "b2": 44, "r1": 40})
	assert_eq(s.fleet_totals, {BLUE: 88, RED: 40})
	assert_eq(s.head_start(BLUE), 160)
	assert_eq(s.head_start(RED), 112)
	assert_eq(s.score(BLUE, 0.0), 160)
	assert_eq(s.score(RED, 0.0), 112)


func test_fielded_ship_skips_leading_capsule() -> void:
	var s := MatchScore.new(_match({"b": [BLUE, ["Capsule", "Abaddon"]], "r": [RED, ["Capsule"]]}), _rules())
	assert_eq(s.fielded, {"b": "Abaddon", "r": ""})
	assert_eq(s.values, {"b": 40, "r": 0})


func test_kill_scores_at_loss_time() -> void:
	var s := MatchScore.new(_match(
		{"b": [BLUE, ["Abaddon", "Capsule"]], "r": [RED, ["Abaddon"]]},
		[[30.0, "b", MatchData.Event.DEATH, "Abaddon"]],
	), _rules())
	assert_eq(s.score(RED, 29.9), 160)
	assert_eq(s.score(RED, 30.0), 200)
	assert_eq(s.score(BLUE, 100.0), 160)


func test_out_of_bounds_counts_as_kill() -> void:
	var s := MatchScore.new(_match(
		{"b": [BLUE, ["Abaddon"]], "r": [RED, ["Abaddon"]]},
		[[12.0, "r", MatchData.Event.BOUNDARY, "Abaddon"]],
	), _rules())
	assert_eq(s.loss_t, {"r": 12.0})
	assert_eq(s.score(BLUE, 12.0), 200)


func test_pod_then_boundary_scores_once() -> void:
	var s := MatchScore.new(_match(
		{"b": [BLUE, ["Abaddon", "Capsule"]], "r": [RED, ["Abaddon"]]},
		[[10.0, "b", MatchData.Event.DEATH, "Abaddon"], [20.0, "b", MatchData.Event.BOUNDARY, "Capsule"]],
	), _rules())
	assert_eq(s.loss_t, {"b": 10.0})
	assert_eq(s.score(RED, 30.0), 200)


func test_capsule_leaving_bounds_is_not_a_kill() -> void:
	var s := MatchScore.new(_match(
		{"b": [BLUE, ["Abaddon"]], "r": [RED, ["Capsule"]]},
		[[5.0, "r", MatchData.Event.BOUNDARY, "Capsule"]],
	), _rules())
	assert_true(s.loss_t.is_empty())


func test_mjd_is_not_a_loss() -> void:
	var s := MatchScore.new(_match(
		{"b": [BLUE, ["Abaddon"]], "r": [RED, ["Abaddon"]]},
		[[5.0, "r", MatchData.Event.MJD, "Abaddon"]],
	), _rules())
	assert_true(s.loss_t.is_empty())


func test_pod_detected_from_csv() -> void:
	var path := write_csv([
		row(0, "b", "Abaddon", on_line(0, 0.5)),
		row(5, "b", "Capsule", on_line(0, 0.5)),
		row(0, "r", "Abaddon", on_line(7, 0.5)),
		row(5, "r", "Abaddon", on_line(7, 0.5)),
	])
	var s := MatchScore.new(MatchData.load_csv(path, {}, 0.0, true), _rules())
	assert_eq(s.loss_t.keys(), ["b"])
	assert_eq(s.score(RED, 5.0), 200)
