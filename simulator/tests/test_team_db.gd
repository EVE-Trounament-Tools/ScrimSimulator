extends "res://tests/test_case.gd"
## TeamDb: season pilot/team dbs, in a temp library instead of user://matches.

var _saved_dir: String


func before_each() -> void:
	_saved_dir = MatchLibrary.dir
	MatchLibrary.dir = temp_dir().path_join("matches")


func after_each() -> void:
	MatchLibrary.dir = _saved_dir


## A library match in `folder` with `corners` { pilot -> corner its line starts on }.
func _match(corners: Dictionary, folder := "S1") -> String:
	var rows := []
	for pilot in corners:
		rows.append(row(0, pilot, "Test Hull", on_line(corners[pilot], 0.5)))
	return MatchLibrary.add(write_csv(rows), folder)


func _add(corners: Dictionary, folder := "S1") -> String:
	var path := _match(corners, folder)
	TeamDb.ingest_paths([path])
	return path


func test_season_of_top_level_folder() -> void:
	assert_eq(TeamDb.season_of(MatchLibrary.dir.path_join("m.csv")), "")
	assert_eq(TeamDb.season_of(MatchLibrary.dir.path_join("S1/m.csv")), "S1")
	assert_eq(TeamDb.season_of(MatchLibrary.dir.path_join("S1/vs X/m.csv")), "S1")
	assert_eq(TeamDb.db_path("S1"), MatchLibrary.dir.path_join("S1").path_join(TeamDb.FILE))


func test_ingest_makes_temp_named_teams() -> void:
	_add({"a1": 0, "a2": 0, "b1": 7, "b2": 7})
	var db := TeamDb.read("S1")
	assert_eq(db.pilots, {"a1": "t1", "a2": "t1", "b1": "t2", "b2": "t2"})
	assert_eq(db.teams, {"t1": {"name": "Team 1", "temp": true}, "t2": {"name": "Team 2", "temp": true}})
	assert_eq(db.matches.size(), 1)


func test_flipped_match_keeps_teams() -> void:
	_add({"a1": 0, "a2": 0, "b1": 7, "b2": 7})
	var path := _add({"a1": 7, "a2": 7, "b1": 0, "b2": 0, "b3": 0})
	var db := TeamDb.read("S1")
	assert_eq(db.teams.size(), 2, "no new team")
	assert_eq(db.pilots["b3"], "t2", "a new pilot joins its side's team")
	var data := MatchData.load_csv(path)
	assert_eq(TeamDb.apply(db, data), {MatchData.Team.BLUE: "t2", MatchData.Team.RED: "t1"})
	assert_eq(data.teams["a1"], MatchData.Team.RED)


func test_misplaced_pilot_goes_to_its_team() -> void:
	_add({"a1": 0, "a2": 0, "b1": 7, "b2": 7})
	var path := _add({"a1": 7, "a2": 0, "b1": 7, "b2": 7})
	var db := TeamDb.read("S1")
	assert_eq(db.pilots["a1"], "t1", "a known pilot is never moved by a match")
	var data := MatchData.load_csv(path)
	assert_eq(data.teams["a1"], MatchData.Team.RED, "starts with the other team")
	TeamDb.apply(db, data)
	assert_eq(data.teams["a1"], MatchData.Team.BLUE)


func test_unknown_pilot_goes_to_its_team() -> void:
	_add({"a1": 0, "a2": 0, "b1": 7})
	var path := MatchLibrary.add(write_csv([
		row(0, "a1", "Test Hull", on_line(0, 0.5)),
		row(0, "a2", "Test Hull", MatchData.CENTRE_M),
		row(0, "b1", "Test Hull", on_line(7, 0.5)),
	]), "S1")
	var data := MatchData.load_csv(path)
	assert_eq(data.teams["a2"], MatchData.Team.UNKNOWN)
	TeamDb.apply(TeamDb.read("S1"), data)
	assert_eq(data.teams["a2"], MatchData.Team.BLUE)


func test_match_swaps_count_when_added() -> void:
	var path := _match({"a1": 0, "a2": 0, "b1": 7})
	MatchLibrary.save_meta(path, {"teams": {"a2": MatchData.Team.RED}})
	TeamDb.ingest_paths([path])
	assert_eq(TeamDb.read("S1").pilots["a2"], "t2")


func test_seasons_are_separate() -> void:
	_add({"a1": 0, "b1": 7}, "S1/vs B")
	_add({"a1": 7, "c1": 0}, "S2")
	_add({"x1": 0, "y1": 7}, "")
	assert_eq(TeamDb.read("S1").pilots, {"a1": "t1", "b1": "t2"})
	assert_eq(TeamDb.read("S2").pilots, {"c1": "t1", "a1": "t2"})
	assert_eq(TeamDb.read("").pilots, {"x1": "t1", "y1": "t2"})
	assert_eq(TeamDb.seasons(), ["", "S1", "S2"])


func test_readding_same_match_changes_nothing() -> void:
	var path := _add({"a1": 0, "b1": 7})
	var before := FileAccess.get_file_as_string(TeamDb.db_path("S1"))
	TeamDb.ingest_paths([path])
	assert_eq(FileAccess.get_file_as_string(TeamDb.db_path("S1")), before)


func test_sides_picking_the_same_team() -> void:
	var db := TeamDb.empty()
	db.pilots = {"a1": "t1", "a2": "t1", "a3": "t1", "b1": "t2"}
	var sides := TeamDb.sides_of(db, {"a1": 0, "a2": 0, "a3": 1, "b1": 1})
	assert_eq(sides, {MatchData.Team.BLUE: "t1", MatchData.Team.RED: "t2"}, "fewer of t1 on red: red takes its next best")
	sides = TeamDb.sides_of(db, {"a1": 0, "a2": 0, "a3": 1})
	assert_eq(sides, {MatchData.Team.BLUE: "t1", MatchData.Team.RED: ""})


func test_rename_and_temp_name() -> void:
	var db := TeamDb.empty()
	var id := TeamDb.new_team(db)
	TeamDb.rename(db, id, " Alpha ")
	assert_eq(TeamDb.team_name(db, id), "Alpha")
	TeamDb.rename(db, id, "")
	assert_eq(db.teams[id], {"name": "Team 1", "temp": true})
	assert_eq(TeamDb.new_team(db), "t2")


func test_rebuild_keeps_names_and_hand_assignments() -> void:
	_add({"a1": 0, "a2": 0, "b1": 7, "b2": 7})
	_add({"a1": 7, "a2": 7, "b1": 0, "c1": 0})
	var db := TeamDb.read("S1")
	TeamDb.rename(db, "t2", "Bravo")
	TeamDb.assign(db, "c1", "t1")
	db.pilots["b2"] = "t1"  # wrong, but not by hand: rebuilt away
	TeamDb.save("S1", db)
	db = TeamDb.rebuild("S1", "new")
	assert_eq(db.build, "new")
	assert_eq(TeamDb.team_name(db, db.pilots["b1"]), "Bravo")
	assert_eq(db.pilots["b2"], db.pilots["b1"])
	assert_eq(db.pilots["c1"], db.pilots["a1"], "kept where it was put by hand")
	assert_eq(db.manual, {"c1": db.pilots["a1"]})
	assert_eq(db.matches.size(), 2)


func test_ensure_current_rebuilds_only_other_builds() -> void:
	_add({"a1": 0, "b1": 7})
	var db := TeamDb.read("S1")
	db.build = "b1"
	db.pilots["zz"] = "t1"
	TeamDb.save("S1", db)
	TeamDb.ensure_current("b1")
	assert_true(TeamDb.read("S1").pilots.has("zz"), "same build: left alone")
	TeamDb.ensure_current("b2")
	db = TeamDb.read("S1")
	assert_eq(db.build, "b2")
	assert_false(db.pilots.has("zz"))
	assert_eq(db.pilots.size(), 2)


func test_ensure_current_makes_missing_dbs() -> void:
	_match({"a1": 0, "b1": 7}, "S9")
	TeamDb.ensure_current("b1")
	assert_eq(TeamDb.read("S9").pilots, {"a1": "t1", "b1": "t2"})


func test_match_never_takes_the_db_name() -> void:
	var src := temp_dir().path_join("pilot-teams.db.csv")
	DirAccess.copy_absolute(write_csv([row(0, "a", "Test Hull", on_line(0, 0.5))]), src)
	var path := MatchLibrary.add(src)
	assert_eq(path.get_file(), "pilot-teams.db (2).csv")
