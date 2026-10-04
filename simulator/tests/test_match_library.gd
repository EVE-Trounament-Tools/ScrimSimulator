extends "res://tests/test_case.gd"
## MatchLibrary: adding, listing and removing matches, in a temp dir instead of user://matches.

var _saved_dir: String
var _saved_settings: String


func before_each() -> void:
	_saved_dir = MatchLibrary.dir
	MatchLibrary.dir = temp_dir().path_join("matches")
	_saved_settings = Settings.path
	Settings.path = temp_dir().path_join("settings.cfg")
	Settings._cfg = null


func after_each() -> void:
	MatchLibrary.dir = _saved_dir
	MatchLibrary.demo_dir = ""
	Settings.path = _saved_settings
	Settings._cfg = null


## A CSV named `name` in its own temp dir, holding `body`.
func _file(name: String, body: String) -> String:
	var path := temp_dir().path_join(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(body)
	f.close()
	return path


func test_missing_dir_lists_nothing() -> void:
	assert_eq(MatchLibrary.list(), [])


func test_add_copies_and_lists() -> void:
	var src := _file("match_03.positions.csv", "a")
	var path := MatchLibrary.add(src)
	assert_eq(path, MatchLibrary.dir.path_join("match_03.positions.csv"))
	assert_eq(FileAccess.get_file_as_string(path), "a")
	var entries := MatchLibrary.list()
	assert_eq(entries.size(), 1)
	assert_eq(entries[0].path, path)
	assert_eq(entries[0].name, "match_03")
	DirAccess.remove_absolute(src)
	assert_true(FileAccess.file_exists(path), "copy outlives the original")


func test_readd_identical_is_not_duplicated() -> void:
	var first := MatchLibrary.add(_file("m.positions.csv", "same"))
	var second := MatchLibrary.add(_file("m.positions.csv", "same"))
	assert_eq(second, first)
	assert_eq(MatchLibrary.list().size(), 1)
	assert_eq(MatchLibrary.add(first), first, "adding a library file returns it")


func test_name_clash_gets_suffix() -> void:
	MatchLibrary.add(_file("m.positions.csv", "one"))
	var second := MatchLibrary.add(_file("m.positions.csv", "two"))
	var third := MatchLibrary.add(_file("m.positions.csv", "three"))
	assert_eq(second.get_file(), "m (2).positions.csv")
	assert_eq(third.get_file(), "m (3).positions.csv")
	assert_eq(FileAccess.get_file_as_string(second), "two")
	assert_eq(MatchLibrary.list().size(), 3)


func test_list_natural_name_order() -> void:
	for n in ["m_10", "m_02", "m_1", "M_3"]:
		MatchLibrary.add(_file(n + ".csv", n))
	assert_eq(MatchLibrary.list().map(func(e): return e.name), ["m_1", "m_02", "M_3", "m_10"])


func test_list_ignores_other_files() -> void:
	MatchLibrary.add(_file("m.csv", "1"))
	var f := FileAccess.open(MatchLibrary.dir.path_join("notes.txt"), FileAccess.WRITE)
	f.close()
	assert_eq(MatchLibrary.list().size(), 1)


func test_remove_deletes() -> void:
	var path := MatchLibrary.add(_file("m.csv", "1"))
	MatchLibrary.remove(path)
	assert_false(FileAccess.file_exists(path))
	assert_eq(MatchLibrary.list(), [])


func test_add_missing_source_fails() -> void:
	assert_eq(MatchLibrary.add(temp_dir().path_join("nope.csv")), "")
	assert_eq(MatchLibrary.list(), [])


func test_display_name() -> void:
	assert_eq(MatchLibrary.display_name("match_03.positions.csv"), "match_03")
	assert_eq(MatchLibrary.display_name("x.CSV"), "x")
	assert_eq(MatchLibrary.display_name("plain"), "plain")


func test_rename_keeps_extension_and_moves_meta() -> void:
	var path := MatchLibrary.add(_file("m.positions.csv", "1"))
	MatchLibrary.save_meta(path, {"teams": {"a": 1}})
	var renamed := MatchLibrary.rename(path, "  Final vs Them ")
	assert_eq(renamed, MatchLibrary.dir.path_join("Final vs Them.positions.csv"))
	assert_false(FileAccess.file_exists(path))
	assert_false(FileAccess.file_exists(MatchLibrary.meta_path(path)))
	assert_eq(MatchLibrary.load_meta(renamed), {"teams": {"a": 1}})
	assert_eq(MatchLibrary.list().map(func(e): return e.name), ["Final vs Them"])
	assert_eq(MatchLibrary.rename(renamed, "Final vs Them"), renamed, "same name is a no-op")


func test_rename_to_taken_or_empty_name_fails() -> void:
	var a := MatchLibrary.add(_file("a.csv", "1"))
	MatchLibrary.add(_file("b.csv", "2"))
	assert_eq(MatchLibrary.rename(a, "b"), "")
	assert_eq(MatchLibrary.rename(a, "   "), "")
	assert_true(FileAccess.file_exists(a))


func test_meta_round_trip() -> void:
	var path := MatchLibrary.add(_file("m.csv", "1"))
	assert_eq(MatchLibrary.load_meta(path), {}, "no sidecar yet")
	MatchLibrary.save_meta(path, {"teams": {"x y": MatchData.Team.RED}, "team_names": {MatchData.Team.BLUE: "Us"}})
	var meta := MatchLibrary.load_meta(path)
	assert_eq(meta.teams, {"x y": MatchData.Team.RED})
	assert_eq(meta.team_names, {MatchData.Team.BLUE: "Us"})
	assert_eq(typeof(meta.teams["x y"]), TYPE_INT)
	assert_eq(MatchLibrary.list().size(), 1, "sidecar isn't listed")


func test_meta_log_pilots_round_trip() -> void:
	var path := MatchLibrary.add(_file("m.csv", "1"))
	MatchLibrary.save_meta(path, {"teams": {}, "log_pilots": {"a.txt": "Some Pilot"}})
	assert_eq(MatchLibrary.load_meta(path).log_pilots, {"a.txt": "Some Pilot"})


## A positions CSV named `name` with EVE times 14:03:14 (t=0) to 14:03:24 (t=10).
func _match_file(name := "m.positions.csv") -> String:
	var body := "t,pilot,ship_type,x_m,y_m,z_m,speed_mps,dir_x,dir_y,dir_z,residual_m,eve_time\n"
	for t in range(0, 12, 2):
		body += "%d,A,Rifter,%d,0,0,0,0,0,0,0,2026-10-03T14:03:%02d.000Z\n" % [t, 1000 * t, 14 + t]
	return _file(name, body)


## A gamelog named `name` of "A", with a hit logged at 14:03:`second` and a notice before the match.
func _gamelog(name: String, second := 20, damage := 10) -> String:
	return _file(name, "------\r\n  Gamelog\r\n  Listener: A\r\n------\r\n"
		+ "[ 2026.10.03 13:00:00 ] (notify) Undocking\r\n"
		+ "[ 2026.10.03 14:03:%02d ] (combat) %d to B[X](Rifter) - Gun - Hits\r\n" % [second, damage])


func test_logs() -> void:
	var path := MatchLibrary.add(_match_file())
	assert_eq(MatchLibrary.logs_dir(path), MatchLibrary.dir.path_join("m.positions.logs"))
	assert_eq(MatchLibrary.log_paths(path), [])
	var a := MatchLibrary.add_log(path, _gamelog("20261003_1.txt"))
	assert_eq(a, MatchLibrary.logs_dir(path).path_join("20261003_1.txt"))
	assert_eq(MatchLibrary.add_log(path, _gamelog("20261003_1.txt")), a, "same log reused")
	var a2 := MatchLibrary.add_log(path, _gamelog("20261003_1.txt", 20, 11))
	assert_eq(a2.get_file(), "20261003_1 (2).txt", "different log, same name")
	assert_eq(MatchLibrary.log_paths(path).size(), 2)
	assert_true(MatchLibrary.log_paths(path).has(a2))
	assert_eq(MatchLibrary.list().size(), 1, "logs aren't matches")
	MatchLibrary.remove_log(path, a)
	assert_eq(MatchLibrary.log_paths(path), [a2])
	MatchLibrary.remove_logs(path)
	assert_eq(MatchLibrary.log_paths(path), [])
	assert_false(DirAccess.dir_exists_absolute(MatchLibrary.logs_dir(path)))


func test_add_log_keeps_only_the_match() -> void:
	var path := MatchLibrary.add(_match_file())
	var saved := MatchLibrary.add_log(path, _gamelog("x.txt"))
	assert_eq(FileAccess.get_file_as_string(saved), "------\r\n  Gamelog\r\n  Listener: A\r\n------\r\n"
		+ "[ 2026.10.03 14:03:20 ] (combat) 10 to B[X](Rifter) - Gun - Hits\r\n")


func test_add_log_refuses_logs_outside_the_match() -> void:
	var path := MatchLibrary.add(_match_file())
	assert_eq(MatchLibrary.add_log(path, _gamelog("late.txt", 59)), "", "no combat during the match")
	assert_eq(MatchLibrary.add_log(path, _file("notes.txt", "hello\n")), "", "not a gamelog")
	var no_times := MatchLibrary.add(_file("n.positions.csv", "t,pilot,ship_type,x_m,y_m,z_m\n0,A,Rifter,0,0,0\n"))
	assert_eq(MatchLibrary.add_log(no_times, _gamelog("x.txt")), "", "no EVE times")
	assert_eq(MatchLibrary.log_paths(path), [])


func test_add_brings_logs_along() -> void:
	var src := _match_file()
	var logs := src.get_basename() + ".logs"
	DirAccess.make_dir_recursive_absolute(logs)
	DirAccess.copy_absolute(_gamelog("x.txt"), logs.path_join("x.txt"))
	var path := MatchLibrary.add(src)
	assert_eq(MatchLibrary.log_paths(path).map(func(p): return p.get_file()), ["x.txt"])
	assert_false(FileAccess.get_file_as_string(MatchLibrary.log_paths(path)[0]).contains("Undocking"), "trimmed")


func test_rename_and_remove_carry_logs() -> void:
	var path := MatchLibrary.add(_match_file())
	MatchLibrary.add_log(path, _gamelog("x.txt"))
	var renamed := MatchLibrary.rename(path, "n")
	assert_false(DirAccess.dir_exists_absolute(MatchLibrary.logs_dir(path)))
	assert_eq(MatchLibrary.log_paths(renamed).map(func(p): return p.get_file()), ["x.txt"])
	MatchLibrary.remove(renamed)
	assert_false(DirAccess.dir_exists_absolute(MatchLibrary.logs_dir(renamed)))


func test_remove_deletes_meta() -> void:
	var path := MatchLibrary.add(_file("m.csv", "1"))
	MatchLibrary.save_meta(path, {"teams": {}})
	MatchLibrary.remove(path)
	assert_false(FileAccess.file_exists(MatchLibrary.meta_path(path)))


func test_contains() -> void:
	var path := MatchLibrary.add(_file("m.csv", "1"))
	assert_true(MatchLibrary.contains(path))
	assert_false(MatchLibrary.contains(temp_dir().path_join("m.csv")))
	assert_false(MatchLibrary.contains(""))


func test_set_audio_copies_next_to_csv() -> void:
	var path := MatchLibrary.add(_file("m.positions.csv", "1"))
	assert_eq(MatchLibrary.audio_path(path), "")
	assert_false(MatchLibrary.list()[0].audio)
	var src := write_wav()
	var audio := MatchLibrary.set_audio(path, src)
	assert_eq(audio, MatchLibrary.dir.path_join("m.positions.wav"))
	assert_eq(MatchLibrary.audio_path(path), audio)
	assert_true(MatchLibrary.list()[0].audio)
	assert_eq(MatchLibrary.list().size(), 1, "audio isn't listed as a match")
	DirAccess.remove_absolute(src)
	assert_true(MatchLibrary.load_audio(path) is AudioStreamWAV, "copy outlives the original")


func test_set_audio_replaces_other_format() -> void:
	var path := MatchLibrary.add(_file("m.positions.csv", "1"))
	MatchLibrary.set_audio(path, write_wav())
	var ogg := MatchLibrary.set_audio(path, _file("comms.OGG", "not really ogg"))
	assert_eq(ogg, MatchLibrary.dir.path_join("m.positions.ogg"))
	assert_false(FileAccess.file_exists(MatchLibrary.dir.path_join("m.positions.wav")))
	assert_eq(MatchLibrary.audio_path(path), ogg)


func test_set_audio_rejects_other_files() -> void:
	var path := MatchLibrary.add(_file("m.positions.csv", "1"))
	assert_eq(MatchLibrary.set_audio(path, _file("notes.txt", "x")), "")
	assert_eq(MatchLibrary.set_audio(path, temp_dir().path_join("missing.wav")), "")
	assert_eq(MatchLibrary.audio_path(path), "")
	assert_null(MatchLibrary.load_audio(path))


func test_remove_audio() -> void:
	var path := MatchLibrary.add(_file("m.positions.csv", "1"))
	MatchLibrary.set_audio(path, write_wav())
	MatchLibrary.remove_audio(path)
	assert_eq(MatchLibrary.audio_path(path), "")
	assert_true(FileAccess.file_exists(path), "match stays")


func test_rename_moves_audio() -> void:
	var path := MatchLibrary.add(_file("m.positions.csv", "1"))
	MatchLibrary.set_audio(path, write_wav())
	var renamed := MatchLibrary.rename(path, "n")
	assert_eq(MatchLibrary.audio_path(renamed), MatchLibrary.dir.path_join("n.positions.wav"))
	assert_eq(MatchLibrary.audio_path(path), "")


func test_remove_deletes_audio() -> void:
	var path := MatchLibrary.add(_file("m.positions.csv", "1"))
	var audio := MatchLibrary.set_audio(path, write_wav())
	MatchLibrary.remove(path)
	assert_false(FileAccess.file_exists(audio))


## A release-style `demo/` dir: the checked-in demo match and its gamelog as "Demo match".
func _demo_dir() -> String:
	var src: String = preload("res://tests/test_demo_match.gd").demo_path()
	var d := temp_dir().path_join("demo")
	DirAccess.make_dir_recursive_absolute(d.path_join("Demo match.positions.logs"))
	DirAccess.copy_absolute(src, d.path_join("Demo match.positions.csv"))
	for gamelog in MatchLibrary.log_paths(src):
		DirAccess.copy_absolute(gamelog, d.path_join("Demo match.positions.logs").path_join(gamelog.get_file()))
	return d


func test_add_demo_adds_match_and_logs() -> void:
	MatchLibrary.demo_dir = _demo_dir()
	MatchLibrary.add_demo()
	var entries := MatchLibrary.list()
	assert_eq(entries.size(), 1)
	assert_eq(entries[0].name, "Demo match")
	assert_eq(MatchLibrary.log_paths(entries[0].path).size(), 1)
	assert_true(Settings.get_value("library/demo_added"))


func test_removed_demo_stays_removed() -> void:
	MatchLibrary.demo_dir = _demo_dir()
	MatchLibrary.add_demo()
	MatchLibrary.remove(MatchLibrary.list()[0].path)
	MatchLibrary.add_demo()
	assert_eq(MatchLibrary.list(), [])


func test_add_demo_copies_folders_and_audio() -> void:
	var d := _demo_dir()
	DirAccess.make_dir_recursive_absolute(d.path_join("Scrim/m.positions.logs"))
	DirAccess.copy_absolute(d.path_join("Demo match.positions.csv"), d.path_join("Scrim/m.positions.csv"))
	DirAccess.copy_absolute(write_wav(), d.path_join("Scrim/m.positions.wav"))
	MatchLibrary.demo_dir = d
	MatchLibrary.add_demo()
	assert_eq(MatchLibrary.list().map(func(e): return [e.folder, e.name, e.audio]),
		[["", "Demo match", false], ["Scrim", "m", true]])


func test_missing_demo_is_noop() -> void:
	MatchLibrary.demo_dir = temp_dir().path_join("nope")
	MatchLibrary.add_demo()
	assert_eq(MatchLibrary.list(), [])
	assert_false(Settings.get_value("library/demo_added"), "a later run can still add it")


func test_folders_list_nested_and_skip_logs() -> void:
	assert_eq(MatchLibrary.create_folder("", "b"), "b")
	assert_eq(MatchLibrary.create_folder("", "A"), "A")
	assert_eq(MatchLibrary.create_folder("A", "x"), "A/x")
	var path := MatchLibrary.add(_match_file(), "A/x")
	MatchLibrary.add_log(path, _gamelog("g.txt"))
	assert_eq(MatchLibrary.folders(), ["A", "A/x", "b"])
	assert_eq(MatchLibrary.list().map(func(e): return e.folder), ["A/x"])
	assert_eq(MatchLibrary.folder_of(path), "A/x")
	assert_eq(MatchLibrary.matches_in("A"), [path])
	assert_eq(MatchLibrary.matches_in("b"), [])


func test_create_folder_rejects_bad_names() -> void:
	MatchLibrary.create_folder("", "a")
	assert_eq(MatchLibrary.create_folder("", "A"), "", "taken, ignoring case")
	assert_eq(MatchLibrary.create_folder("", "  "), "")
	assert_eq(MatchLibrary.create_folder("", "m.logs"), "")
	assert_eq(MatchLibrary.create_folder("", ".."), "")
	assert_eq(MatchLibrary.create_folder("a", "a"), "a/a", "same name elsewhere is fine")


func test_contains_nested() -> void:
	MatchLibrary.create_folder("", "f")
	var path := MatchLibrary.add(_file("m.csv", "1"), "f")
	assert_eq(path, MatchLibrary.dir.path_join("f/m.csv"))
	assert_true(MatchLibrary.contains(path))
	assert_false(MatchLibrary.contains(MatchLibrary.dir.path_join("f/m.logs/x.txt")))


func test_move_carries_companions_and_suffixes() -> void:
	MatchLibrary.create_folder("", "f")
	var path := MatchLibrary.add(_match_file())
	MatchLibrary.save_meta(path, {"teams": {}})
	MatchLibrary.set_audio(path, write_wav())
	MatchLibrary.add_log(path, _gamelog("g.txt"))
	var moved := MatchLibrary.move(path, "f")
	assert_eq(moved, MatchLibrary.dir.path_join("f/m.positions.csv"))
	assert_false(FileAccess.file_exists(path))
	assert_true(FileAccess.file_exists(MatchLibrary.meta_path(moved)))
	assert_ne(MatchLibrary.audio_path(moved), "")
	assert_eq(MatchLibrary.log_paths(moved).size(), 1)
	assert_eq(MatchLibrary.move(moved, "f"), moved, "already there")
	var other := MatchLibrary.add(_file("m.positions.csv", "other"))
	assert_eq(MatchLibrary.move(other, "f").get_file(), "m (2).positions.csv")
	assert_eq(MatchLibrary.move(moved, "nope"), "")


func test_rename_clash_is_per_folder() -> void:
	MatchLibrary.create_folder("", "f")
	MatchLibrary.add(_file("a.csv", "1"))
	var b := MatchLibrary.add(_file("b.csv", "2"), "f")
	assert_eq(MatchLibrary.rename(b, "a"), MatchLibrary.dir.path_join("f/a.csv"))


func test_rename_move_and_remove_folder() -> void:
	MatchLibrary.create_folder("", "a")
	MatchLibrary.create_folder("a", "b")
	MatchLibrary.create_folder("", "c")
	var path := MatchLibrary.add(_file("m.csv", "1"), "a/b")
	assert_eq(MatchLibrary.rename_folder("a", "c"), "", "taken")
	assert_eq(MatchLibrary.rename_folder("a", "z"), "z")
	assert_eq(MatchLibrary.matches_in("z"), [MatchLibrary.dir.path_join("z/b/m.csv")])
	assert_eq(MatchLibrary.move_folder("z", "z/b"), "", "not into itself")
	assert_eq(MatchLibrary.move_folder("z/b", "c"), "c/b")
	MatchLibrary.create_folder("", "b")
	assert_eq(MatchLibrary.move_folder("c/b", ""), "b (2)", "name taken there")
	assert_eq(MatchLibrary.list().size(), 1)
	MatchLibrary.remove_folder("b (2)")
	assert_eq(MatchLibrary.list(), [])
	assert_eq(MatchLibrary.folders(), ["b", "c", "z"])
	assert_false(FileAccess.file_exists(path))


func test_pair_audio() -> void:
	var pairs := MatchLibrary.pair_audio(
		["d/match_03.positions.csv", "d/clip_001.positions.csv", "d/x_2.csv", "d/y_2.csv", "d/lone.csv"],
		["d/Match_03.ogg", "d/match_1.mp3", "d/comms_2.wav", "d/extra.mp3"])
	assert_eq(pairs, {
		"d/match_03.positions.csv": "d/Match_03.ogg",
		"d/clip_001.positions.csv": "d/match_1.mp3",
	}, "exact name, then a unique trailing number; 2 is ambiguous")
	assert_eq(MatchLibrary.pair_audio(["d/a_1.csv"], ["d/a_1.wav", "d/b_1.wav"]), {"d/a_1.csv": "d/a_1.wav"},
		"exact name wins over numbers")


func test_add_folder_pairs_audio_and_logs() -> void:
	var src := temp_dir().path_join("vs X")
	DirAccess.make_dir_recursive_absolute(src)
	DirAccess.copy_absolute(_match_file(), src.path_join("clip_001.positions.csv"))
	DirAccess.copy_absolute(write_wav(), src.path_join("match_001.wav"))
	DirAccess.copy_absolute(write_wav(), src.path_join("stray.wav"))
	DirAccess.copy_absolute(_gamelog("g.txt"), src.path_join("g.txt"))
	DirAccess.copy_absolute(_gamelog("late.txt", 59), src.path_join("late.txt"))
	MatchLibrary.create_folder("", "Season")
	var added := MatchLibrary.add_folder(src, "Season")
	assert_eq(added.folder, "Season/vs X")
	var path := MatchLibrary.dir.path_join("Season/vs X/clip_001.positions.csv")
	assert_eq(added.matches, [path])
	assert_eq(added.unpaired_audio, ["stray.wav"])
	assert_ne(MatchLibrary.audio_path(path), "")
	assert_eq(MatchLibrary.log_paths(path).map(func(p): return p.get_file()), ["g.txt"], "only logs with combat in the match")
	assert_eq(MatchLibrary.add_folder(src, "Season").matches, [path], "importing again changes nothing")
	assert_eq(MatchLibrary.list().size(), 1)


func test_add_folder_without_csvs() -> void:
	var added := MatchLibrary.add_folder(temp_dir())
	assert_eq(added.matches, [])
	assert_eq(MatchLibrary.folders(), [])
