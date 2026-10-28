extends "res://tests/test_case.gd"
## main.gd integration: load a match into the real viewer node and drive playback by hand.
## Methods are called directly (no frames awaited after loading) so `_process` never advances
## time behind the test's back.

const Main := preload("res://scripts/main.gd")
const C := MatchData.CENTRE_M
const X := Vector3.RIGHT

var _saved_path: String
var _saved_library: String


func before_each() -> void:
	# Keep the real settings untouched and skip the SDE update check (network).
	_saved_path = Settings.path
	Settings.path = temp_dir().path_join("settings.cfg")
	_saved_library = MatchLibrary.dir
	MatchLibrary.dir = temp_dir().path_join("matches")
	Settings._cfg = null
	Settings.set_value("sde/auto_update", false)
	Settings.set_value("display/ship_models", false)
	stub_sde()


func after_each() -> void:
	tree.root.content_scale_factor = 1.0
	Settings.path = _saved_path
	Settings._cfg = null
	MatchLibrary.dir = _saved_library
	ShipSizes.dir = ""
	var bus := AudioServer.get_bus_index(Main.AUDIO_BUS)
	if bus >= 0:
		AudioServer.set_bus_mute(bus, false)


func _main() -> Main:
	var m: Main = Main.new()
	add_node(m)
	m.assets.fetch_ewar_icons = false
	return m


## blue (corner 0), red (corner 7, one 20 s gap), late (centre, from 5 s), and runner, who
## leaves the arena at 2 s. Ship types are made up so real SDE sizes don't apply.
func _match_csv() -> String:
	var rows := [
		row(0, "blue", "Test Hull", on_line(0, 0.5)),
		row(4, "blue", "Test Hull", on_line(0, 0.4)),
		row(0, "red", "Test Hull", on_line(7, 0.5)),
		row(20, "red", "Test Hull", on_line(7, 0.5)),
		row(0, "runner", "Test Hull", C + X * 100000.0),
		row(4, "runner", "Test Hull", C + X * 150000.0),
	]
	for t in [5, 10, 15, 20]:
		rows.append(row(t, "late", "Test Hull", C))
	for t in [8, 12, 16, 20]:
		rows.append(row(t, "blue", "Test Hull", on_line(0, 0.4)))
		rows.append(row(t, "runner", "Test Hull", C + X * 150000.0))
	return write_csv(rows)


func test_fmt_time() -> void:
	assert_eq(Main._fmt_time(0.0), "00:00")
	assert_eq(Main._fmt_time(59.9), "00:59")
	assert_eq(Main._fmt_time(61.0), "01:01")
	assert_eq(Main._fmt_time(3600.0), "60:00")


func test_fmt_speed() -> void:
	assert_eq(Main._fmt_speed(0.0), "0 m/s")
	assert_eq(Main._fmt_speed(999.0), "999 m/s")
	assert_eq(Main._fmt_speed(999.4), "999 m/s")
	assert_eq(Main._fmt_speed(999.5), "1.0 km/s")
	assert_eq(Main._fmt_speed(1000.0), "1.0 km/s")
	assert_eq(Main._fmt_speed(2450.0), "2.5 km/s")


func test_link_offsets() -> void:
	var ab := {"kind": "shooting", "source": "A", "target": "B"}
	assert_eq(Main._link_offsets([ab]), [0.0], "a lone line runs through the icon centres")
	assert_eq(Main._link_offsets([ab, {"kind": "tackle", "source": "A", "target": "B"}]), [-0.5, 0.5])
	assert_eq(Main._link_offsets([ab, {"kind": "shooting", "source": "B", "target": "A"}]), [-0.5, 0.5],
		"lines both ways share the pair's slots")
	assert_eq(Main._link_offsets([ab, {"kind": "shooting", "source": "A", "target": "C"}]), [0.0, 0.0],
		"other pairs don't shift it")


func test_material() -> void:
	var m := Main._material(Color(1, 0, 0, 0.5), false)
	assert_eq(m.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA)
	assert_eq(m.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED)
	m = Main._material(Color(1, 0, 0), true)
	assert_eq(m.transparency, BaseMaterial3D.TRANSPARENCY_DISABLED)
	assert_eq(m.shading_mode, BaseMaterial3D.SHADING_MODE_PER_PIXEL)


func test_starts_empty() -> void:
	var m := _main()
	assert_null(m.data)
	assert_true(m.file_label.text.begins_with("No match loaded"))


func test_starts_on_menu() -> void:
	var m := _main()
	assert_true(m.menu.visible)
	assert_true(m.menu.empty_label.visible)
	assert_false(m.menu.resume_button.visible, "nothing to go back to")


func test_menu_lists_library_and_opens_match() -> void:
	var path := MatchLibrary.add(_match_csv())
	var m := _main()
	assert_eq(m.menu.list.match_items().size(), 1)
	assert_false(m.menu.empty_label.visible)
	m.menu.open_button.pressed.emit()
	assert_false(m.menu.visible)
	assert_eq(m.match_path, path)
	assert_eq(m.ships.size(), 4)


func test_menu_add_copies_and_opens() -> void:
	var m := _main()
	var src := _match_csv()
	m.menu.add_dialog.file_selected.emit(src)
	assert_false(m.menu.visible)
	assert_eq(m.match_path, MatchLibrary.dir.path_join("match.positions.csv"))
	assert_eq(MatchLibrary.list().size(), 1)


func test_menu_bad_match_shows_error() -> void:
	var m := _main()
	m.menu.add_dialog.file_selected.emit(write_csv([], "not,a,positions,file"))
	assert_true(m.menu.visible)
	assert_null(m.data)
	assert_true(m.menu.error_label.visible)
	assert_true(m.menu.error_label.text.begins_with("Failed to load"))


func test_menu_button_pauses_and_resumes() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._toggle_play()
	m._show_menu()
	assert_true(m.menu.visible)
	assert_false(m.playing)
	assert_true(m.menu.resume_button.visible)
	m.menu.resume_button.pressed.emit()
	assert_false(m.menu.visible)
	assert_not_null(m.data)


func test_menu_blocks_playback_keys() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._show_menu()
	var ev := InputEventKey.new()
	ev.keycode = KEY_SPACE
	ev.pressed = true
	m._input(ev)
	assert_false(m.playing)
	ev.keycode = KEY_RIGHT
	m._input(ev)
	assert_eq(m.time, 0.0)


func test_drop_adds_to_library_and_opens() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._on_files_dropped(PackedStringArray(["/tmp/notes.txt", _match_csv()]))
	assert_false(m.menu.visible)
	assert_eq(m.match_path.get_base_dir(), MatchLibrary.dir)
	assert_eq(MatchLibrary.list().size(), 1)


func test_menu_remove_deletes_from_library() -> void:
	MatchLibrary.add(_match_csv())
	var m := _main()
	m.menu.remove_dialog.confirmed.emit()
	assert_eq(m.menu.list.match_items().size(), 0)
	assert_eq(MatchLibrary.list(), [])


func test_menu_folders_move_and_follow_open_match() -> void:
	var path := MatchLibrary.add(_match_csv())
	var m := _main()
	m.menu.create_folder("", "Season 3")
	assert_eq(m.menu.target_folder(), "Season 3", "new folder selected")
	assert_eq(m.menu.selected_path(), "", "a folder isn't a match")
	assert_true(m.menu.open_button.disabled)
	m.menu.create_folder("Season 3", "vs X")
	m.load_match(path)
	m._show_menu()
	m.menu.move_item({"kind": "match", "path": path, "folder": ""}, "Season 3/vs X")
	var moved := MatchLibrary.folder_abs("Season 3/vs X").path_join(path.get_file())
	assert_eq(m.match_path, moved, "open match follows its move")
	assert_eq(m.menu.list.folder_item("Season 3/vs X").get_child(0).get_metadata(0).path, moved)
	m.menu._select({"kind": "folder", "rel": "Season 3"})
	m.menu.rename_selected("Season 4")
	assert_eq(m.match_path, MatchLibrary.folder_abs("Season 4/vs X").path_join(path.get_file()), "and its folder's rename")
	assert_true(MatchLibrary.contains(m.match_path))
	m.menu.open_context_menu(Vector2(10, 10))
	assert_eq(m.menu.move_menu.item_count, 3, "Library, Season 4, vs X")
	assert_true(m.menu.move_menu.is_item_disabled(0), "already in the library")
	assert_true(m.menu.move_menu.is_item_disabled(2), "not into itself")
	m.menu.remove_dialog.confirmed.emit()
	assert_eq(MatchLibrary.list(), [])
	assert_eq(MatchLibrary.folders(), [])


func test_drop_folder_adds_scrim() -> void:
	var src := temp_dir().path_join("Scrim 1")
	DirAccess.make_dir_recursive_absolute(src)
	DirAccess.copy_absolute(_match_csv(), src.path_join("clip_001.positions.csv"))
	DirAccess.copy_absolute(write_wav(), src.path_join("match_1.wav"))
	var m := _main()
	m._on_files_dropped(PackedStringArray([src]))
	assert_true(m.menu.visible)
	assert_eq(MatchLibrary.folders(), ["Scrim 1"])
	assert_eq(m.menu.selected_path(), MatchLibrary.folder_abs("Scrim 1").path_join("clip_001.positions.csv"))
	assert_ne(MatchLibrary.audio_path(m.menu.selected_path()), "", "audio paired by number")
	assert_false(m.menu.error_label.visible)
	var db := TeamDb.read("Scrim 1")
	assert_eq(db.pilots.size(), 2, "its pilots join the season's teams")
	assert_eq(db.teams.size(), 2)


## A library match whose first ship moves at 2 s (after a countdown from 0 s).
func _countdown_match() -> String:
	return MatchLibrary.add(write_csv([
		row(0, "a", "Rifter", C),
		row(2, "a", "Rifter", C),
		row(4, "a", "Rifter", C + X * 2000),
		row(6, "a", "Rifter", C + X * 4000),
	]))


func test_audio_keeps_countdown() -> void:
	var path := _countdown_match()
	var m := _main()
	m.load_match(path)
	assert_eq(m.data.start_time, 2.0, "no audio: countdown skipped")
	assert_null(m.audio_player.stream)
	MatchLibrary.set_audio(path, write_wav(10.0))
	m.load_match(path)
	assert_eq(m.data.start_time, 0.0, "audio starts with the data")
	assert_eq(m.data.duration, 6.0)
	assert_true(m.audio_player.stream is AudioStreamWAV)


func test_broadcast_clock_counts_down_to_first_move() -> void:
	var path := _countdown_match()
	MatchLibrary.set_audio(path, write_wav(10.0))
	var m := _main()
	m.load_match(path)
	assert_eq(m.data.lead_in, 2.0)
	for c in [[0.0, "-00:02"], [1.5, "-00:01"], [2.0, "00:00"], [5.0, "00:03"]]:
		m._seek(c[0])
		m._process(0.0)
		assert_eq(m.broadcast_panel.clock.text, c[1], "at %s" % c[0])


func test_mute() -> void:
	var m := _main()
	m.load_match(_match_csv())
	assert_true(m.mute_button.disabled, "no audio, nothing to mute")
	var path := _countdown_match()
	MatchLibrary.set_audio(path, write_wav(10.0))
	m.load_match(path)
	assert_false(m.mute_button.disabled)
	var bus := AudioServer.get_bus_index(Main.AUDIO_BUS)
	assert_false(AudioServer.is_bus_mute(bus))
	m._toggle_play()
	m.mute_button.button_pressed = true
	assert_true(AudioServer.is_bus_mute(bus))
	assert_true(Settings.get_value("audio/muted"))
	assert_true(m.audio_player.playing, "keeps playing muted, so unmuting stays in sync")
	m._set_muted(false)
	assert_false(AudioServer.is_bus_mute(bus))
	assert_false(m.mute_button.button_pressed)
	Settings.set_value("audio/muted", true)
	var m2 := _main()
	assert_true(m2.mute_button.button_pressed, "remembered")
	assert_true(AudioServer.is_bus_mute(bus))


func test_audio_follows_playback() -> void:
	var path := _countdown_match()
	MatchLibrary.set_audio(path, write_wav(10.0))
	var m := _main()
	m.load_match(path)
	assert_false(m.audio_player.playing)
	m._seek(3.0)
	m._toggle_play()
	assert_true(m.audio_player.playing)
	m._set_speed(2.0)
	assert_eq(m.audio_player.pitch_scale, 2.0)
	assert_eq(m.audio_pitch.pitch_scale, 0.5, "pitch kept")
	assert_eq(m.audio_player.playback_type, AudioServer.PLAYBACK_TYPE_STREAM, "bus effect runs on web")
	m._toggle_play()
	assert_false(m.audio_player.playing)
	m._set_speed(1.0)


## A library match named `name` with `ships` pilots sampled 0-20 s with full HP, half on each
## start line but the last `stray` of them, who start at the centre (on no team).
func _hp_match(name: String, ships: int, stray := 0) -> String:
	var rows := []
	for i in ships:
		var at := C if i >= ships - stray else on_line(0 if i % 2 == 0 else 7, 0.5)
		for t in 21:
			rows.append(row(t, "P%02d" % i, "Test Hull", at) + [1, 1, 1])
	var src := write_csv(rows, DEFAULT_HEADER + ",shield,armor,hull")
	var named := src.get_base_dir().path_join(name + ".positions.csv")
	DirAccess.rename_absolute(src, named)
	return MatchLibrary.add(named)


func test_menu_flags_matches_missing_data() -> void:
	var full := _hp_match("full", MatchData.MIN_SHIPS)
	var short := _hp_match("short", 12)
	var m := _main()
	var items := {}
	for it in m.menu.list.match_items():
		items[it.get_metadata(0).path] = it
	assert_eq(items[full].get_button_count(0), 0, "complete match: no badge")
	assert_eq(items[short].get_button_count(0), 1, "badge")
	assert_eq(items[short].get_button(0, 0), m.menu.warning_icon)
	assert_true(items[short].get_button_tooltip_text(0, 0).contains("Only 12 of 20 ships"))
	assert_true(items[short].get_tooltip_text(0).begins_with("Missing data:"))


func test_menu_flags_pilots_on_no_team() -> void:
	var stray := _hp_match("stray", MatchData.MIN_SHIPS - 2, 2)
	var m := _main()
	var item: TreeItem = m.menu.list.match_items()[0]
	assert_eq(item.get_button_count(0), 2, "missing data and no team")
	var i := item.get_button_by_id(0, MainMenu.Badge.NO_TEAM)
	assert_eq(item.get_button(0, i), m.menu.no_team_icon)
	assert_eq(item.get_button_tooltip_text(0, i), "Not on a team:\n  P16\n  P17")
	assert_eq(DataCheck.unassigned(stray), ["P16", "P17"])
	# Putting them on a team (saved in the sidecar) clears the badge.
	MatchLibrary.save_meta(stray, {"teams": {"P16": MatchData.Team.BLUE, "P17": MatchData.Team.RED}})
	m.menu.refresh()
	item = m.menu.list.match_items()[0]
	assert_eq(item.get_button_by_id(0, MainMenu.Badge.NO_TEAM), -1, "assigned: no badge")
	assert_eq(DataCheck.unassigned(stray), [])


func test_missing_text_caps_lines() -> void:
	assert_eq(MainMenu.flag_text("Missing data:", []), "")
	var many := range(MainMenu.MAX_ISSUES_SHOWN + 3).map(func(i): return "issue %d" % i)
	var text := MainMenu.flag_text("Missing data:", many)
	assert_eq(text.split("\n").size(), MainMenu.MAX_ISSUES_SHOWN + 2)
	assert_true(text.ends_with("…and 3 more"))


func test_data_check_caches_until_csv_changes() -> void:
	var path := _hp_match("cached", 12)
	assert_eq(DataCheck.issues(path), ["Only 12 of 20 ships"])
	assert_true(FileAccess.file_exists(DataCheck.cache_path()))
	DataCheck._cache[path].issues = ["stale"]
	assert_eq(DataCheck.issues(path), ["stale"], "unchanged CSV: cached")
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	f.seek_end()
	f.store_line(",".join(row(21, "P00", "Test Hull", on_line(0, 0.5)).map(func(v): return str(v))) + ",1,1,1")
	f.close()
	assert_eq(DataCheck.issues(path), ["Only 12 of 20 ships"], "changed CSV: rechecked")
	DataCheck.prune([])
	assert_false(DataCheck._cache.has(path), "pruned")


func test_menu_audio_badge_and_context_menu() -> void:
	var path := _countdown_match()
	var m := _main()
	assert_eq(m.menu.list.match_items()[0].get_icon(0), m.menu.blank_icon)
	m.menu.add_audio(write_wav())
	assert_eq(m.menu.list.match_items()[0].get_icon(0), m.menu.audio_icon, "badge")
	assert_ne(MatchLibrary.audio_path(path), "")
	m.menu.open_context_menu(Vector2(10, 10))
	var menu: PopupMenu = m.menu.context_menu
	assert_eq(menu.get_item_text(menu.get_item_index(MainMenu.MenuItem.ADD_AUDIO)), "Replace audio…")
	assert_false(menu.is_item_disabled(menu.get_item_index(MainMenu.MenuItem.REMOVE_AUDIO)))
	menu.id_pressed.emit(MainMenu.MenuItem.REMOVE_AUDIO)
	assert_eq(MatchLibrary.audio_path(path), "")
	assert_eq(m.menu.list.match_items()[0].get_icon(0), m.menu.blank_icon)
	assert_eq(m.menu.list.match_items().size(), 1, "match stays")
	m.menu.open_context_menu(Vector2(10, 10))
	assert_true(menu.is_item_disabled(menu.get_item_index(MainMenu.MenuItem.REMOVE_AUDIO)))
	menu.id_pressed.emit(MainMenu.MenuItem.REMOVE)
	assert_true(m.menu.remove_dialog.visible)
	m.menu.remove_dialog.confirmed.emit()
	assert_eq(MatchLibrary.list(), [])


func test_audio_change_reloads_open_match() -> void:
	var path := _countdown_match()
	var m := _main()
	m.load_match(path)
	m._show_menu()
	m.menu.add_audio(write_wav())
	assert_eq(m.data.start_time, 0.0)
	assert_true(m.menu.visible, "stays on the menu")
	m.menu.remove_audio_selected()
	assert_eq(m.data.start_time, 2.0)
	assert_null(m.audio_player.stream)


func test_drop_audio_onto_open_match() -> void:
	var path := _countdown_match()
	var m := _main()
	m.load_match(path)
	m._on_files_dropped(PackedStringArray([write_wav()]))
	assert_ne(MatchLibrary.audio_path(path), "")
	assert_eq(m.data.start_time, 0.0)


## A library match with EVE times (14:03:14 on), and a gamelog of its pilot "Halvard Ostberg".
func _logged_match() -> Array:
	var rows := []
	for t in [0, 2, 4, 6]:
		rows.append(row(t, "Halvard Ostberg", "Skiff", C + X * 1000.0 * t) + ["2026-10-03T14:03:%02d.000Z" % (14 + t)])
	var path := MatchLibrary.add(write_csv(rows, DEFAULT_HEADER + ",eve_time"))
	var gamelog := temp_dir().path_join("20261003_124532_1.txt")
	var f := FileAccess.open(gamelog, FileAccess.WRITE)
	f.store_string("  Listener: Halvard Ostbergte\n[ 2026.10.03 14:03:16 ] (combat) 204 to Someone[X](Endurance) - Test Railgun - Hits\n")
	f.close()
	return [path, gamelog]


func test_menu_adds_combat_logs() -> void:
	var made := _logged_match()
	var m := _main()
	m.load_match(made[0])
	assert_eq(m.data.combat_logs, [])
	for id in CombatStats.RATE_IDS + CombatStats.EWAR_IDS:
		assert_true(m.roster_table.unavailable.has(id), "no logs: %s hidden" % id)
	m._show_menu()
	var not_a_log := temp_dir().path_join("notes.txt")
	FileAccess.open(not_a_log, FileAccess.WRITE).store_string("hello")
	m.menu.add_logs(PackedStringArray([made[1], not_a_log]))
	assert_true(m.menu.error_label.visible, "notes.txt refused")
	assert_eq(MatchLibrary.log_paths(made[0]).size(), 1)
	assert_eq(m.data.combat_logs.size(), 1, "open match picks it up")
	assert_eq(m.data.combat_logs[0].pilot, "Halvard Ostberg")
	assert_eq(m.data.combat_logs[0].entries[0].t, 2.0)
	m.menu.open_context_menu(Vector2(10, 10))
	var menu: PopupMenu = m.menu.context_menu
	assert_false(menu.is_item_disabled(menu.get_item_index(MainMenu.MenuItem.REMOVE_LOGS)))
	menu.id_pressed.emit(MainMenu.MenuItem.REMOVE_LOGS)
	assert_eq(MatchLibrary.log_paths(made[0]), [])
	assert_eq(m.data.combat_logs, [])


## A library match in `folder` with EVE times from 14:`minute`:00 to 14:`minute`:06.
func _timed_match(minute: int, folder := "") -> String:
	var rows := []
	for t in [0, 2, 4, 6]:
		rows.append(row(t, "Halvard Ostberg", "Skiff", C + X * 1000.0 * t) + ["2026-10-03T14:%02d:%02d.000Z" % [minute, t]])
	return MatchLibrary.add(write_csv(rows, DEFAULT_HEADER + ",eve_time"), folder)


## A gamelog with one hit at 14:`minute`:02 for each of `minutes`.
func _day_log(minutes: Array) -> String:
	var gamelog := temp_dir().path_join("20261003_120000.txt")
	var f := FileAccess.open(gamelog, FileAccess.WRITE)
	f.store_string("  Listener: Halvard Ostberg\n")
	for minute in minutes:
		f.store_string("[ 2026.10.03 14:%02d:02 ] (combat) 204 to Someone[X](Endurance) - Test Railgun - Hits\n" % minute)
	f.close()
	return gamelog


func test_logs_added_to_one_match_reach_its_folder() -> void:
	var a := _timed_match(3, "Scrim")
	var b := _timed_match(10, "Scrim")
	var other := _timed_match(20, "Elsewhere")
	var idle := _timed_match(30, "Scrim")
	var m := _main()
	m._show_menu()
	m.menu.refresh()
	m.menu._select({"kind": "match", "path": a})
	m.menu.add_logs(PackedStringArray([_day_log([3, 10, 20])]))
	assert_false(m.menu.error_label.visible)
	assert_eq(MatchLibrary.log_paths(a).size(), 1)
	assert_eq(MatchLibrary.log_paths(b).size(), 1, "same day, same folder")
	assert_eq(MatchLibrary.log_paths(idle), [], "no combat during it")
	assert_eq(MatchLibrary.log_paths(other), [], "other folder untouched")
	assert_eq(CombatLog.load_file(MatchLibrary.log_paths(b)[0]).entries.size(), 1, "trimmed to its window")


func test_folder_menu_adds_logs() -> void:
	var a := _timed_match(3, "Scrim/Day 1")
	var b := _timed_match(10, "Scrim")
	var m := _main()
	m._show_menu()
	m.menu.refresh()
	m.menu._select({"kind": "folder", "rel": "Scrim"})
	m.menu.open_context_menu(Vector2(10, 10))
	var menu: PopupMenu = m.menu.context_menu
	assert_false(menu.is_item_disabled(menu.get_item_index(MainMenu.MenuItem.ADD_LOGS)))
	m.menu.add_logs(PackedStringArray([_day_log([3, 10, 40])]))
	assert_eq(MatchLibrary.log_paths(a).size(), 1, "subfolder included")
	assert_eq(MatchLibrary.log_paths(b).size(), 1)
	var not_a_log := temp_dir().path_join("notes.txt")
	FileAccess.open(not_a_log, FileAccess.WRITE).store_string("hello")
	m.menu.add_logs(PackedStringArray([not_a_log]))
	assert_true(m.menu.error_label.visible, "notes.txt refused")


func test_log_pilot_override_survives_meta_save() -> void:
	var made := _logged_match()
	MatchLibrary.add_log(made[0], made[1])
	MatchLibrary.save_meta(made[0], {"log_pilots": {made[1].get_file(): "nobody"}})
	var m := _main()
	m.load_match(made[0])
	assert_eq(m.log_pilots, {made[1].get_file(): "nobody"})
	m._save_meta()
	assert_eq(MatchLibrary.load_meta(made[0]).log_pilots, {made[1].get_file(): "nobody"})


func test_load_bad_file() -> void:
	var m := _main()
	m.load_match(temp_dir().path_join("missing.positions.csv"))
	assert_null(m.data)
	assert_eq(m.file_label.text, "Failed to load missing.positions.csv")


func test_load_match() -> void:
	var m := _main()
	m.load_match(_match_csv())
	assert_not_null(m.data)
	assert_eq(m.ships.size(), 4)
	assert_eq(m.ships_root.get_child_count(), 5, "4 ships + 1 death marker")
	assert_eq(m.timeline.max_value, 20.0)
	assert_eq(m.file_label.text,
		"match.positions.csv — 4 pilots (blue 1 / red 1 / unknown 2), 1 out of bounds")
	assert_false(m.playing, "starts paused")
	assert_true(m.start_button.visible)
	assert_eq(m.time, 0.0)


func test_start_button_starts_once() -> void:
	var m := _main()
	assert_false(m.start_button.visible, "hidden with no match")
	m.load_match(_match_csv())
	m.start_button.pressed.emit()
	assert_true(m.playing)
	assert_false(m.start_button.visible)
	m._toggle_play()
	assert_false(m.playing)
	assert_false(m.start_button.visible, "stays gone once started")
	m.load_match(m.match_path)
	assert_false(m.start_button.visible, "reloading the same match keeps it gone")
	assert_true(m.playing)
	m.load_match(write_csv([row(0, "solo", "Test Hull", C), row(1, "solo", "Test Hull", C)]))
	assert_true(m.start_button.visible, "a new match shows it again")
	assert_false(m.playing)


func test_play_hides_start_button() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._toggle_play()
	assert_true(m.playing)
	assert_false(m.start_button.visible)


func test_ui_scale_setting() -> void:
	var m := _main()
	assert_eq(m.ui_scale_option.selected, Main.UI_SCALES.find(1.0))
	m.ui_scale_option.item_selected.emit(Main.UI_SCALES.find(1.5))
	assert_eq(m.get_window().content_scale_factor, 1.5)
	Settings._cfg = null  # Force a reload from disk.
	assert_eq(Settings.get_value("display/ui_scale"), 1.5)
	assert_almost(m.camera.fov,
		m.camera.fov_for_height(m.get_viewport().get_visible_rect().size.y), 1e-3, "camera refits")


func test_overlays_rescale_with_units_per_px() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._select("blue")
	var ship: Dictionary = m.ships["blue"]
	var label: float = ship.label.pixel_size
	var select: float = ship.select_icon.pixel_size
	assert_almost(label, m._units_per_px(1.0) * Main.LABEL_PX, 1e-7)
	m._overlay_unit *= 2.0  # As if the FOV had stopped growing while the viewport did.
	m._rescale_overlays()
	assert_almost(ship.label.pixel_size, label / 2.0, 1e-7)
	assert_almost(ship.select_icon.pixel_size, select / 2.0, 1e-7, "keeps the selection boost")
	m._rescale_overlays()
	assert_almost(ship.label.pixel_size, label / 2.0, 1e-7, "no change without a new ratio")


func test_reload_replaces_ships() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m.load_match(write_csv([row(0, "solo", "Test Hull", C), row(1, "solo", "Test Hull", C)]))
	assert_eq(m.ships.keys(), ["solo"])


func test_seek_clamps() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._seek(-5.0)
	assert_eq(m.time, 0.0)
	m._seek(100.0)
	assert_eq(m.time, 20.0)
	m._seek(7.5)
	assert_eq(m.time, 7.5)
	assert_eq(m.timeline.value, 7.5)


func test_shift_arrows_skip_ten_seconds() -> void:
	var m := _main()
	m.load_match(_match_csv())
	var key := func(code):
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.shift_pressed = true
		ev.pressed = true
		m._input(ev)
	m._seek(2.5)
	m._set_playing(true)
	key.call(KEY_RIGHT)
	assert_almost(m.time, 12.5)
	assert_true(m.playing, "skipping keeps playback going")
	key.call(KEY_RIGHT)
	assert_eq(m.time, 20.0, "clamped to the end")
	key.call(KEY_LEFT)
	assert_almost(m.time, 10.0)
	key.call(KEY_LEFT)
	key.call(KEY_LEFT)
	assert_eq(m.time, 0.0, "clamped to the start")


func test_step_tick_pauses_and_snaps_to_whole_ticks() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._seek(7.5)
	m._set_playing(true)
	m._step_tick(1)
	assert_eq(m.time, 8.0)
	assert_false(m.playing)
	m._step_tick(1)
	assert_eq(m.time, 9.0)
	m._seek(7.5)
	m._step_tick(-1)
	assert_eq(m.time, 7.0)
	m._step_tick(-1)
	assert_eq(m.time, 6.0)
	m._seek(0.0)
	m._step_tick(-1)
	assert_eq(m.time, 0.0, "clamped at the start")


func test_playback_stops_at_end_and_restarts() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._set_playing(true)
	m._seek(18.0)
	m._process(1.0)
	assert_almost(m.time, 19.0)
	assert_true(m.playing)
	m.speed = 10.0
	m._process(1.0)
	assert_eq(m.time, 20.0)
	assert_false(m.playing)
	assert_eq(m.play_button.text, "Play")
	m._toggle_play()
	assert_eq(m.time, 0.0, "play at the end restarts")
	assert_true(m.playing)
	assert_eq(m.play_button.text, "Pause")


func test_ship_visibility_and_position() -> void:
	var m := _main()
	m._set_smooth_on(false)  # Linear, so mid-segment positions are easy to state.
	m.load_match(_match_csv())
	m._seek(0.0)
	m._update_ships()
	assert_true(m.ships["blue"].node.visible)
	assert_almost(m.ships["blue"].node.position, on_line(0, 0.5) * Main.M_TO_UNITS)
	assert_true(m.ships["red"].node.visible)
	assert_false(m.ships["late"].node.visible, "before first sample")

	m._seek(2.0)
	m._update_ships()
	assert_true(m.ships["blue"].node.visible)
	assert_almost(m.ships["blue"].node.position, on_line(0, 0.45) * Main.M_TO_UNITS)
	assert_false(m.ships["red"].node.visible, "20 s gap hides the ship")

	m._seek(5.0)
	m._update_ships()
	assert_true(m.ships["late"].node.visible)
	assert_almost(m.ships["late"].node.position, C * Main.M_TO_UNITS)


func test_death_marks_ship() -> void:
	var m := _main()
	m.load_match(_match_csv())
	var runner: Dictionary = m.ships["runner"]
	assert_almost(runner.death_t, 2.0)
	m._seek(1.0)
	m._update_ships()
	assert_false(runner.death_marker.visible)
	assert_false(runner.dead)
	assert_false("DEAD" in runner.label.text)

	m._seek(3.0)
	m._update_ships()
	assert_true(runner.death_marker.visible)
	assert_true(runner.dead)
	assert_true("DEAD" in runner.label.text)
	assert_almost(runner.death_marker.position, (C + X * MatchData.BOUNDARY_RADIUS_M) * Main.M_TO_UNITS, 1e-2)


# --- roster ----------------------------------------------------------------------

## Team header labels and the pilots of the buttons in roster order, e.g. ["Blue (1)", "blue", ...].
func _roster(m: Main) -> Array:
	var out := []
	for c in m.roster_table.body.get_children():
		if c is Label:
			out.append(c.text)
		else:
			out.append(m.roster_buttons.find_key(c.get_child(0)))
	return out


## "hopper" micro jumps at 3 s and gets podded at 6 s.
func _events_csv() -> String:
	var rows := [
		row(0, "hopper", "Test Hull", C),
		row(1, "hopper", "Test Hull", C + X * 1000),
		row(2, "hopper", "Test Hull", C + X * 2000),
		row(3, "hopper", "Test Hull", C + X * 102000),
		row(4, "hopper", "Test Hull", C + X * 103000),
		row(5, "hopper", "Test Hull", C + X * 104000),
		row(6, "hopper", "Capsule", C + X * 105000),
		row(10, "hopper", "Capsule", C + X * 105000),
	]
	return write_csv(rows)


func test_events_on_timeline() -> void:
	var m := _main()
	m.load_match(_events_csv())
	var marks: Array = m.event_strip.marks
	assert_eq(marks.size(), 2)
	assert_eq(marks[0].t, 3.0)
	assert_eq(marks[0].color, Main.EVENT_COLORS[MatchData.Event.MJD])
	assert_eq(marks[0].text, "00:03 hopper — MJD 100 km (Test Hull)")
	assert_eq(marks[1].text, "00:06 hopper — Died (Test Hull)")
	m.load_match(_match_csv())
	assert_eq(m.event_strip.marks.size(), 1, "reload replaces marks (runner leaves the arena)")


func test_click_event_mark_seeks_before_it() -> void:
	var m := _main()
	m.load_match(_events_csv())
	m.event_strip.size = Vector2(1000, 12)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = Vector2(m.event_strip.x_of(6.0), 6)
	m.event_strip._gui_input(ev)
	assert_almost(m.time, 6.0 - Main.EVENT_LEAD_S)
	assert_eq(m.event_strip.mark_at(m.event_strip.x_of(4.5)), -1, "nothing between ticks")


func test_playback_keys() -> void:
	var m := _main()
	m.load_match(_events_csv())
	var key := func(code):
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.pressed = true
		m._input(ev)
	key.call(KEY_BRACKETRIGHT)
	assert_almost(m.time, 1.0)
	key.call(KEY_BRACKETRIGHT)
	assert_almost(m.time, 4.0)
	key.call(KEY_BRACKETRIGHT)
	assert_almost(m.time, 4.0, 1e-3, "no event after the last")
	key.call(KEY_BRACKETLEFT)
	assert_almost(m.time, 1.0)
	var was_playing: bool = m.playing
	key.call(KEY_SPACE)
	assert_eq(m.playing, not was_playing)
	key.call(KEY_SPACE)
	assert_eq(m.playing, was_playing)
	key.call(KEY_RIGHT)
	assert_almost(m.time, 2.0)
	key.call(KEY_LEFT)
	key.call(KEY_LEFT)
	assert_almost(m.time, 0.0)


func test_mjd_trail_shows_briefly_after_jump() -> void:
	var m := _main()
	m.load_match(_events_csv())
	assert_eq(m.mjd_trails.size(), 1)
	var trail: Node3D = m.mjd_trails[0].node
	for case in [[2.5, false], [3.0, true], [7.0, true], [8.5, false]]:
		m._seek(case[0])
		m._process(0.0)
		assert_eq(trail.visible, case[1], "at %s s" % case[0])


func test_info_shows_podding() -> void:
	var m := _main()
	m.load_match(_events_csv())
	m._select("hopper")
	m._seek(7.0)
	m._update_info()
	assert_true("Died at 00:06 (lost Test Hull)" in m.info_label.text)


func test_short_name() -> void:
	assert_eq(Main._short_name("Halvard"), "Halvard")
	assert_eq(Main._short_name("Amarr Citizen 0220922"), "Amarr C. 0.")
	assert_eq(Main._short_name("  Two  Spaces "), "Two S.")


func test_roster_lists_teams() -> void:
	var m := _main()
	m._set_broadcast_on(false)
	assert_false(m.roster_panel.visible, "hidden until a match loads")
	m.load_match(_match_csv())
	assert_true(m.roster_panel.visible)
	assert_eq(_roster(m), ["Blue (1)", "blue", "Red (1)", "red", "Unknown (2)", "late", "runner"])
	assert_eq(m.roster_table.cell_text("blue", "ship"), "Test Hull")
	assert_eq(m.roster_table.cell_text("blue", "pilot"), "blue")


func test_broadcast_toggle() -> void:
	var m := _main()
	m.load_match(_match_csv())
	assert_true(m.broadcast_panel.visible, "on by default")
	assert_false(m.roster_panel.visible)
	assert_true(m.broadcast_button.button_pressed)
	m._set_broadcast_on(false)
	assert_false(Settings.get_value("display/broadcast_roster"))
	m._set_broadcast_on(true)
	assert_true(m.broadcast_panel.visible)
	assert_true(Settings.get_value("display/broadcast_roster"))
	assert_eq(m.broadcast_panel.rows.keys(), ["blue", "red"], "unknown pilots left out")
	assert_eq(m.broadcast_panel.rows["red"].side, BroadcastRoster.Side.LEFT)
	assert_eq(m.broadcast_panel.rows["blue"].side, BroadcastRoster.Side.RIGHT)
	assert_eq(m.broadcast_panel.team_text(BroadcastRoster.Side.LEFT), "RED")
	assert_eq(m.broadcast_panel.cell_text("blue", "ship"), "Test Hull")
	m._seek(2.0)
	m._process(0.0)
	assert_eq(m.broadcast_panel.cell_text("blue", "speed"), "0 m/s")
	assert_eq(m.broadcast_panel.clock.text, "00:02")
	m._set_broadcast_on(false)
	assert_false(m.broadcast_panel.visible)
	assert_true(m.roster_panel.visible)


func test_broadcast_setting_survives_reload() -> void:
	Settings.set_value("display/broadcast_roster", false)
	var m := _main()
	assert_false(m.broadcast_button.button_pressed)
	m.load_match(_match_csv())
	assert_false(m.broadcast_panel.visible)
	assert_true(m.roster_panel.visible)


## Two Abaddons each (40 points apiece) for blue (corner 0) and red (corner 7); blue's "b2" is
## podded at 4 s, red's "r2" leaves the arena at 3 s.
func _points_csv() -> String:
	var rows := []
	for t in 7:
		rows.append(row(t, "b1", "Abaddon", on_line(0, 0.5)))
		rows.append(row(t, "b2", "Abaddon" if t < 4 else "Capsule", on_line(0, 0.6)))
		rows.append(row(t, "r1", "Abaddon", on_line(7, 0.5)))
		rows.append(row(t, "r2", "Abaddon", on_line(7, 0.6) if t < 3 else C + X * 130000))
	return write_csv(rows)


func test_broadcast_points() -> void:
	var m := _main()
	m.load_match(MatchLibrary.add(_points_csv()))
	assert_eq(m.ruleset_id, Ruleset.latest_id())
	var L := BroadcastRoster.Side.LEFT  # red
	var R := BroadcastRoster.Side.RIGHT  # blue
	assert_eq(m.broadcast_panel.cell_text("b1", "pts"), "44", "two Abaddons inflate each other")
	m._seek(0.0)
	m._process(0.0)
	# Each 88-point fleet hands the other 112 of the 200-point cap.
	var start := m.score.score(MatchData.Team.RED, 0.0)
	assert_eq(m.broadcast_panel.points_text(L), "%d" % start)
	assert_eq(m.broadcast_panel.points_text(R), "%d" % m.score.score(MatchData.Team.BLUE, 0.0))
	m._seek(6.0)
	m._process(0.0)
	assert_eq(m.broadcast_panel.points_text(L), "%d" % (start + 44), "red scores the podded b2")
	assert_eq(m.broadcast_panel.points_text(R), "%d" % (start + 44), "blue scores r2 leaving the arena")


func test_ruleset_saved_with_match() -> void:
	var path := MatchLibrary.add(_points_csv())
	MatchLibrary.save_meta(path, {"ruleset": "nope"})
	var m := _main()
	m.load_match(path)
	assert_eq(m.ruleset_id, Ruleset.latest_id(), "unknown ruleset falls back to the newest")
	assert_eq(m.ruleset_option.get_item_metadata(m.ruleset_option.selected), m.ruleset_id)
	m._set_ruleset("ATXXII")
	assert_eq(MatchLibrary.load_meta(path).ruleset, "ATXXII")


## Stationary blue (corner 0) and red (corner 7) with HP: red takes a hit at 3 s; blue's HP is
## blank from 2 s.
func _hp_csv() -> String:
	var rows := []
	for t in 7:
		var red := Vector3(1, 1, 1) if t < 3 else Vector3(0.5, 1, 1)
		rows.append(row(t, "red", "Test Hull", on_line(7, 0.5)) + [red.x, red.y, red.z])
		rows.append(row(t, "blue", "Test Hull", on_line(0, 0.5)) + ([1, 1, 1] if t < 2 else ["", "", ""]))
	return write_csv(rows, DEFAULT_HEADER + ",shield,armor,hull")


func test_hp_shown_in_both_rosters() -> void:
	var m := _main()
	m.load_match(_hp_csv())
	assert_true("hp" in m.roster_table.visible_ids())
	m._set_playing(false)
	m._seek(4.0)
	m._process(0.0)
	var bars: HBoxContainer = m.roster_table.rows["red"].labels["hp"]
	assert_eq(bars.get_children().map(HpBar.get_fraction), [0.5, 1.0, 1.0])
	assert_eq(HpBar.get_fraction(m.broadcast_panel.rows["red"].labels.shield), 0.5)
	assert_true(is_nan(HpBar.get_fraction(m.roster_table.rows["blue"].labels["hp"].get_child(0))), "blank: unknown")
	assert_true(is_nan(HpBar.get_fraction(m.broadcast_panel.rows["blue"].labels.hull)))


func test_broadcast_row_greyed_out_once_podded() -> void:
	var rows := []
	for t in 7:
		rows.append(row(t, "red", "Test Hull" if t < 3 else "Capsule", on_line(7, 0.5)) + [1, 1, 1])
		rows.append(row(t, "blue", "Test Hull", on_line(0, 0.5)) + [1, 1, 1])
	var m := _main()
	m.load_match(write_csv(rows, DEFAULT_HEADER + ",shield,armor,hull"))
	m._set_playing(false)
	m._seek(2.0)
	m._process(0.0)
	assert_false(m.broadcast_panel.is_dead("red"))
	m._seek(4.0)
	m._process(0.0)
	assert_true(m.broadcast_panel.is_dead("red"))
	assert_eq(m.broadcast_panel.cell_text("red", "ship"), "Test Hull", "keeps the hull it lost")
	assert_eq(m.broadcast_panel.cell_text("red", "speed"), "—")
	assert_true(is_nan(HpBar.get_fraction(m.broadcast_panel.rows["red"].labels.hull)))
	assert_eq(m.roster_table.cell_text("red", "ship"), "Capsule", "roster table unchanged")
	assert_false(m.broadcast_panel.is_dead("blue"))
	m._seek(1.0)
	m._process(0.0)
	assert_false(m.broadcast_panel.is_dead("red"), "alive again when scrubbed back")


func test_hp_column_hidden_without_hp() -> void:
	var m := _main()
	m.load_match(_match_csv())
	assert_false("hp" in m.roster_table.visible_ids())
	assert_true(m.damage_button.disabled)
	m.load_match(_hp_csv())
	assert_false(m.damage_button.disabled)


func test_damage_highlight_toggle() -> void:
	var m := _main()
	m.load_match(_hp_csv())
	m._set_playing(false)
	m._seek(3.5)
	m._process(0.0)
	assert_false(m.roster_table.is_row_damaged("red"), "off by default")
	m._set_damage_on(true)
	assert_true(Settings.get_value("display/damage_highlight"))
	assert_true(m.damage_button.button_pressed)
	assert_true(m.damage_setting.button_pressed)
	assert_true(m.roster_table.is_row_damaged("red"))
	assert_true(m.broadcast_panel.is_damaged("red"))
	assert_false(m.roster_table.is_row_damaged("blue"))
	m._seek(6.5)
	m._process(0.0)
	assert_false(m.roster_table.is_row_damaged("red"), "steady again")
	m._seek(3.5)
	m._process(0.0)
	m._set_damage_on(false)
	assert_false(m.roster_table.is_row_damaged("red"))
	assert_false(m.broadcast_panel.is_damaged("red"))


func test_damage_setting_survives_reload() -> void:
	Settings.set_value("display/damage_highlight", true)
	var m := _main()
	assert_true(m.damage_on)
	assert_true(m.damage_button.button_pressed)
	assert_true(m.damage_setting.button_pressed)


func test_roster_sorts_by_ship_type_and_abbreviates() -> void:
	var m := _main()
	m.load_match(write_csv([
		row(0, "Zed Pilot", "Atron", C), row(1, "Zed Pilot", "Atron", C),
		row(0, "Amy Pilot", "Rifter", C), row(1, "Amy Pilot", "Rifter", C),
		row(0, "Bob Pilot", "Atron", C), row(1, "Bob Pilot", "Atron", C),
	]))
	assert_eq(_roster(m), ["Blue (0)", "Red (0)", "Unknown (3)", "Bob Pilot", "Zed Pilot", "Amy Pilot"])
	assert_eq(m.roster_table.cell_text("Bob Pilot", "ship"), "Atron")
	assert_eq(m.roster_table.cell_text("Bob Pilot", "pilot"), "Bob P.")
	assert_eq(m.roster_buttons["Bob Pilot"].tooltip_text, "Centre the camera on Bob Pilot (right-click to rename or debug)")


## Blue (corner 0): an Abaddon, a Punisher (5) and an Atron (4); red (corner 7): two Atrons and a
## Rifter (4 points each).
func test_roster_sorts_by_points() -> void:
	var m := _main()
	var rows := []
	for t in 2:
		rows.append(row(t, "atron", "Atron", on_line(0, 0.5)))
		rows.append(row(t, "punisher", "Punisher", on_line(0, 0.6)))
		rows.append(row(t, "abaddon", "Abaddon", on_line(0, 0.7)))
		rows.append(row(t, "rifter", "Rifter", on_line(7, 0.5)))
		rows.append(row(t, "y atron", "Atron", on_line(7, 0.6)))
		rows.append(row(t, "x atron", "Atron", on_line(7, 0.7)))
	m.load_match(write_csv(rows))
	var order := ["abaddon", "punisher", "atron", "x atron", "y atron", "rifter"]
	assert_eq(_roster(m), ["Blue (3)"] + order.slice(0, 3) + ["Red (3)"] + order.slice(3),
			"most points first, ties by ship type then pilot")
	var buttons := {}  # row button -> pilot
	for pilot in m.broadcast_panel.rows:
		buttons[m.broadcast_panel.rows[pilot].button] = pilot
	var shown := func(side: int) -> Array:
		return m.broadcast_panel.sides[side].rows.get_children().map(func(b): return buttons[b])
	assert_eq(shown.call(BroadcastRoster.Side.LEFT), order.slice(3), "red down the left")
	assert_eq(shown.call(BroadcastRoster.Side.RIGHT), order.slice(0, 3), "blue down the right")


func test_roster_hides_empty_unknown_group() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._swap_team("late")
	m._swap_team("runner")
	assert_eq(_roster(m), ["Blue (3)", "blue", "late", "runner", "Red (1)", "red"])


func test_roster_shows_speed_and_distance() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._seek(2.0)
	m._process(0.0)
	var motion := m._motion("blue")
	assert_eq(m.roster_table.cell_text("blue", "speed"), "0 m/s", "the CSV's speed, though blue moves")
	assert_eq(m.roster_table.cell_text("blue", "distance"), "%.1f km" % motion.dist_km)
	assert_eq(m.roster_table.cell_text("late", "speed"), "—", "late isn't on grid yet")
	assert_eq(m.roster_table.cell_text("late", "distance"), "—")
	m._seek(10.0)
	m._process(0.0)
	assert_eq(m.roster_table.cell_text("late", "speed"), "0 m/s")
	assert_eq(m.roster_table.cell_text("late", "distance"), "0.0 km")
	assert_almost(m.roster_buttons["runner"].modulate.a, 0.5, 1e-3, "out-of-bounds pilot dimmed")
	assert_eq(m.roster_table.cell_text("runner", "speed"), "—", "dead pilot")
	assert_eq(m.roster_table.cell_text("runner", "distance"), "—")
	assert_almost(m.roster_buttons["blue"].modulate.a, 1.0)


func test_roster_panel_fits_columns() -> void:
	var m := _main()
	m.load_match(_match_csv())
	var before := -m.roster_panel.offset_left
	m.roster_table.set_column_visible("speed", false)
	assert_almost(-m.roster_panel.offset_left, before - RosterTable.COLUMNS.speed.width - RosterTable.HANDLE_W)


func test_track_centres_camera() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._seek(2.0)
	m._set_tracked("blue")
	assert_eq(m.tracked, "blue")
	assert_true(m.roster_buttons["blue"].button_pressed)
	m._process(1.0)
	assert_almost(m.camera.target, m.ships["blue"].node.position)
	m._process(1.0)
	assert_almost(m.camera.target, m.ships["blue"].node.position, 1e-4, "keeps following")

	m._set_tracked("blue")
	assert_eq(m.tracked, "", "picking it again frees the camera")
	assert_false(m.roster_buttons["blue"].button_pressed)


func test_track_holds_target_while_hidden() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._seek(0.0)
	m._set_tracked("red")
	m._process(0.0)
	var target: Vector3 = m.camera.target
	m._seek(10.0)  # In red's 20 s gap.
	m._process(0.0)
	assert_false(m.ships["red"].node.visible)
	assert_eq(m.camera.target, target)


func test_pan_stops_tracking() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._set_tracked("blue")
	var ev := InputEventMouseMotion.new()
	ev.relative = Vector2(50, 0)
	ev.button_mask = MOUSE_BUTTON_MASK_RIGHT
	m.camera._unhandled_input(ev)
	assert_eq(m.tracked, "")


func test_new_match_drops_missing_tracked_pilot() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._set_tracked("blue")
	m.load_match(write_csv([row(0, "solo", "Test Hull", C), row(1, "solo", "Test Hull", C)]))
	assert_eq(m.tracked, "")


func test_swap_team() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._swap_team("blue")
	assert_eq(m.data.teams["blue"], MatchData.Team.RED)
	assert_eq(m.ships["blue"].color, Main.TEAM_COLORS[MatchData.Team.RED])
	assert_eq(_roster(m), ["Blue (0)", "Red (2)", "blue", "red", "Unknown (2)", "late", "runner"])
	assert_true(m.file_label.text.contains("blue 0 / red 2 / unknown 2"))
	m._seek(0.0)
	m._update_ships()
	assert_eq(m.ships["blue"].tint, Main.TEAM_COLORS[MatchData.Team.RED])
	assert_eq(m.ships["blue"].label.modulate, Main.TEAM_COLORS[MatchData.Team.RED])
	m._swap_team("blue")
	assert_eq(m.data.teams["blue"], MatchData.Team.BLUE)


func test_swap_recolours_death_marker() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._swap_team("runner")
	var label: Label3D = m.ships["runner"].death_marker.get_child(2)
	assert_eq(label.modulate, Main.TEAM_COLORS[MatchData.Team.BLUE])


func test_swap_survives_reload_of_same_match() -> void:
	var m := _main()
	var path := _match_csv()
	m.load_match(path)
	m._swap_team("blue")
	m._on_sizes_changed()
	assert_eq(m.data.teams["blue"], MatchData.Team.RED)
	m.load_match(write_csv([row(0, "blue", "Test Hull", on_line(0, 0.5))]))
	assert_true(m.team_overrides.is_empty(), "a different match starts fresh")


func test_swap_persists_for_library_match() -> void:
	Settings.set_value("teams/season_db", false)  # teams of this match only
	var path := MatchLibrary.add(_match_csv())
	var m := _main()
	m.load_match(path)
	m._swap_team("blue")
	var m2 := _main()
	m2.load_match(path)
	assert_eq(m2.data.teams["blue"], MatchData.Team.RED)
	assert_eq(_roster(m2), ["Blue (0)", "Red (2)", "blue", "red", "Unknown (2)", "late", "runner"])


func test_move_to_unknown() -> void:
	Settings.set_value("teams/season_db", false)  # teams of this match only
	var path := MatchLibrary.add(_match_csv())
	var m := _main()
	m.load_match(path)
	m._move_team("blue", MatchData.Team.UNKNOWN)
	assert_eq(m.data.teams["blue"], MatchData.Team.UNKNOWN)
	assert_eq(m.ships["blue"].color, Main.TEAM_COLORS[MatchData.Team.UNKNOWN])
	assert_eq(_roster(m), ["Blue (0)", "Red (1)", "red", "Unknown (3)", "blue", "late", "runner"])
	var m2 := _main()
	m2.load_match(path)
	assert_eq(m2.data.teams["blue"], MatchData.Team.UNKNOWN)


func test_team_menu_moves_pilot() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._open_team_menu("blue")
	var items := []
	for i in range(1, m.team_menu.item_count):
		items.append(m.team_menu.get_item_text(i))
	assert_eq(items, ["Move to Red", "Move to Unknown"])
	m.team_menu.index_pressed.emit(2)
	assert_eq(m.data.teams["blue"], MatchData.Team.UNKNOWN)
	m.team_menu.hide()


func test_move_to_unknown_leaves_season_db() -> void:
	var path := _season_match(0, 7)
	var m := _main()
	m.load_match(path)
	m._move_team("blue", MatchData.Team.UNKNOWN)
	assert_eq(m.data.teams["blue"], MatchData.Team.UNKNOWN)
	assert_false(TeamDb.read("Season 1").manual.has("blue"), "Unknown is this match's only")


func test_rename_team_shows_and_persists() -> void:
	Settings.set_value("teams/season_db", false)  # teams of this match only
	var path := MatchLibrary.add(_match_csv())
	var m := _main()
	m.load_match(path)
	m._rename_team(MatchData.Team.RED, " Them ")
	assert_eq(_roster(m)[2], "Them (1)")
	assert_true(m.file_label.text.contains("blue 1 / Them 1 / unknown 2"))
	assert_eq(m.roster_table.rows["blue"].button.get_parent().get_child(1).tooltip_text,
			"Move to Them (right-click for more)")
	var m2 := _main()
	m2.load_match(path)
	assert_eq(_roster(m2)[2], "Them (1)")
	m2._rename_team(MatchData.Team.RED, "")
	assert_eq(_roster(m2)[2], "Red (1)", "empty restores the default")
	m2.load_match(MatchLibrary.add(write_csv([row(0, "blue", "Test Hull", on_line(0, 0.5))])))
	assert_true(m2.team_names.is_empty(), "another match has its own names")


## Library match (added like the menu does, so its season `TeamDb` knows it) with "blue" and
## "red" starting at corners `blue_corner` and `red_corner`, and "late" at the centre.
func _season_match(blue_corner: int, red_corner: int, folder := "Season 1") -> String:
	var path := MatchLibrary.add(write_csv([
		row(0, "blue", "Test Hull", on_line(blue_corner, 0.5)),
		row(0, "red", "Test Hull", on_line(red_corner, 0.5)),
		row(0, "late", "Test Hull", C),
		row(10, "blue", "Test Hull", on_line(blue_corner, 0.4)),
	]), folder)
	TeamDb.ingest_paths([path])
	return path


func test_season_teams_follow_pilots_across_matches() -> void:
	var first := _season_match(0, 7)
	var flipped := _season_match(7, 0)
	var m := _main()
	m.load_match(first)
	assert_eq(_roster(m), ["Team 1 (1)", "blue", "Team 2 (1)", "red", "Unknown (1)", "late"])
	m.load_match(flipped)
	assert_eq(m.data.teams["blue"], MatchData.Team.RED, "starts at the red corner here")
	assert_eq(_roster(m), ["Team 2 (1)", "red", "Team 1 (1)", "blue", "Unknown (1)", "late"])
	assert_true(m.file_label.text.contains("Team 2 1 / Team 1 1 / unknown 1"))


func test_season_team_keeps_its_colour_in_a_folder() -> void:
	_season_match(0, 7)
	var flipped := _season_match(7, 0)
	var m := _main()
	m.load_match(flipped)
	var blue: Color = Main.TEAM_COLORS[MatchData.Team.BLUE]
	assert_eq(m.ships["blue"].color, blue, "Team 1 is blue in the folder, though on red here")
	assert_eq(m.ships["red"].color, Main.TEAM_COLORS[MatchData.Team.RED])
	m._swap_team("late")  # unknown -> blue side, Team 2
	assert_eq(m.ships["late"].color, Main.TEAM_COLORS[MatchData.Team.RED])


func test_season_team_colours_are_per_folder() -> void:
	_season_match(0, 7, "Season 1/vs A")
	var other := _season_match(7, 0, "Season 1/vs B")
	var m := _main()
	m.load_match(other)
	assert_eq(m.ships["red"].color, Main.TEAM_COLORS[MatchData.Team.BLUE], "first match of its folder")


func test_season_team_rename_shows_in_every_match() -> void:
	var first := _season_match(0, 7)
	var flipped := _season_match(7, 0)
	var m := _main()
	m.load_match(flipped)
	m._rename_team(MatchData.Team.BLUE, " Them ")
	assert_eq(_roster(m)[0], "Them (1)")
	assert_true(m.team_names.is_empty(), "named in the season, not the match")
	m.load_match(first)
	assert_eq(_roster(m)[2], "Them (1)")
	m._rename_team(MatchData.Team.RED, "")
	assert_eq(_roster(m)[2], "Team 2 (1)", "empty gives back the temporary name")


func test_season_team_swap_teaches_other_matches() -> void:
	var first := _season_match(0, 7)
	var flipped := _season_match(7, 0)
	var m := _main()
	m.load_match(first)
	m._swap_team("late")  # unknown -> blue, Team 1
	m.load_match(flipped)
	assert_eq(m.data.teams["late"], MatchData.Team.RED, "with Team 1, on red here")


func test_season_teams_off_keeps_match_teams() -> void:
	_season_match(0, 7)
	var flipped := _season_match(7, 0)
	Settings.set_value("teams/season_db", false)
	var m := _main()
	m.load_match(flipped)
	assert_eq(_roster(m), ["Blue (1)", "red", "Red (1)", "blue", "Unknown (1)", "late"])
	assert_true(m.team_sides.is_empty())


func test_internal_match_keeps_match_teams() -> void:
	_season_match(0, 7)
	var flipped := _season_match(7, 0)
	MatchLibrary.set_internal(flipped, true)
	var m := _main()
	m.load_match(flipped)
	assert_eq(_roster(m), ["Blue (1)", "red", "Red (1)", "blue", "Unknown (1)", "late"])
	assert_true(m.team_sides.is_empty())
	m._swap_team("late")
	assert_true(MatchLibrary.is_internal(flipped), "saving a swap keeps the flag")
	assert_false(TeamDb.read("Season 1").manual.has("late"), "a swap doesn't touch the season")


func test_ship_overlay_default_name_and_type() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._seek(1.0)
	m._update_ships()
	assert_eq(m.ships["runner"].label.text, "runner\nTest Hull")


func test_ship_overlay_distance_and_speed() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._set_smooth_on(false)  # Straight-line motion, so the distances are exact.
	m._set_overlay("name", false)
	m._set_overlay("type", false)
	m._set_overlay("distance", true)
	m._set_overlay("speed", true)
	m._seek(1.0)
	m._update_ships()
	var label: Label3D = m.ships["runner"].label
	assert_eq(label.text, "112.5 km\n0 m/s")
	m._seek(1.5)
	m._update_ships()
	assert_eq(label.text, "118.8 km\n0 m/s", "distance follows the ship every frame")
	assert_true(Settings.get_value("overlay/speed"))
	assert_false(Settings.get_value("overlay/name"))


func test_ship_overlay_all_off_hides_label_but_not_death() -> void:
	var m := _main()
	m.load_match(_match_csv())
	for field in Main.OVERLAY_FIELDS:
		m._set_overlay(field, false)
	m._seek(1.0)
	m._update_ships()
	var runner: Dictionary = m.ships["runner"]
	assert_false(runner.label.visible)
	m._seek(3.0)
	m._update_ships()
	assert_true(runner.label.visible)
	assert_eq(runner.label.text, "DEAD (out of bounds)")


func test_double_click_team_asks_rename() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m.roster_table.group_activated.emit(MatchData.Team.BLUE)
	assert_eq(m.rename_dialog.line_edit.text, "Blue")
	m.rename_dialog.line_edit.text = "Us"
	m.rename_dialog.confirmed.emit()
	assert_eq(_roster(m)[0], "Us (1)")


func test_rename_pilot_everywhere_and_persists() -> void:
	var m := _main()
	m.load_match(_events_csv())
	m._select("hopper")
	m._seek(7.0)
	m._rename_pilot("hopper", "Hoppy")
	assert_eq(m.roster_table.cell_text("hopper", "pilot"), "Hoppy")
	assert_true(m.ships["hopper"].label.text.begins_with("Hoppy\n"))
	assert_true(m.event_strip.marks[0].text.contains(" Hoppy — "))
	assert_true(m.info_label.text.begins_with("Hoppy — "))
	var m2 := _main()
	m2.load_match(write_csv([row(0, "hopper", "Test Hull", C), row(1, "hopper", "Test Hull", C)]))
	assert_eq(m2.roster_table.cell_text("hopper", "pilot"), "Hoppy", "alias applies to every match")
	m2._rename_pilot("hopper", "  ")
	assert_eq(m2.roster_table.cell_text("hopper", "pilot"), "hopper")
	assert_eq(Settings.get_value("names/pilots"), {})


func test_ship_menu_rename_pilot() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._open_ship_debug_menu("blue", Vector2(10, 10))
	m.ship_debug_menu.rename_button.pressed.emit()
	assert_eq(m.rename_dialog.line_edit.text, "blue")
	m.rename_dialog.line_edit.text = "Blue Leader"
	m.rename_dialog.confirmed.emit()
	assert_eq(m.roster_table.cell_text("blue", "pilot"), "Blue Leader")
	assert_eq(m.ship_debug_menu.title_label.text, "Blue Leader")


func test_ship_menu_flips_plane_exit_and_saves_it() -> void:
	# "blue" sits in the plane y = z until 2 s, then exit 1 takes it toward y > z (clockwise).
	var plane := "0.000000 -0.707107 0.707107 0"
	var path := write_csv([
		"0,blue,Test Hull,50000,50000,50000,0,1,0,0,0,,,",
		"2,blue,Test Hull,50000,50000,50000,0,1,0,0,0,,,",
		"4,blue,Test Hull,50000,60000,40000,0,0,0.7071,-0.7071,0,cw,1," + plane,
		"6,blue,Test Hull,50000,70000,30000,0,0,0.7071,-0.7071,0,cw,1," + plane,
	], DEFAULT_HEADER + ",plane_exit,plane_exit_id,plane")
	var m := _main()
	m.load_match(path)
	var at := func(csv_t: float) -> float: return csv_t - m.data.start_time
	m._seek(at.call(2.0))
	m._open_ship_debug_menu("blue", Vector2(10, 10))
	assert_false(m.ship_debug_menu.flip_button.visible, "not in an exit yet")
	m._seek(at.call(6.0))
	m._open_ship_debug_menu("blue", Vector2(10, 10))
	assert_true(m.ship_debug_menu.flip_button.visible)
	assert_eq(m.ship_debug_menu.flip_button.text, "Flip plane exit (clockwise → counterclockwise)")
	m.ship_debug_menu.flip_button.pressed.emit()
	assert_eq(m.time, at.call(6.0), "playback state kept")
	assert_eq(m.data.sample("blue", at.call(6.0)).pos, Vector3(50000, 30000, 70000))
	assert_eq(m.data.plane_exit_at("blue", at.call(6.0)).turn, "ccw")
	assert_true(FileAccess.get_file_as_string(path).contains("50000,30000,70000"), "saved to the CSV")
	m._select("blue")
	assert_true(m.info_label.text.contains("Plane exit 1: counterclockwise"), m.info_label.text)


func test_ship_menu_damage_breakdown_windows() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._open_ship_debug_menu("blue", Vector2(10, 10))
	assert_true(m.ship_debug_menu.damage_button.disabled, "no combat logs")
	var gamelog := CombatLog.new()
	for hit in [["red", 1.0, 300.0], ["late", 2.0, 100.0], ["blue", 3.0, 50.0]]:
		gamelog.entries.append({"eve_unix": 1000.0 + hit[1], "t": hit[1], "kind": CombatLog.Kind.DAMAGE,
			"text": "", "source": hit[0], "target": "blue", "source_ship": "", "target_ship": "",
			"source_pilot": hit[0], "target_pilot": "blue", "amount": hit[2], "weapon": "Gun", "quality": ""})
	m.data.combat_logs = [gamelog]
	m._apply_combat_stats()
	m._seek(4.0)
	m._open_ship_debug_menu("blue", Vector2(10, 10))
	assert_false(m.ship_debug_menu.damage_button.disabled)
	m.ship_debug_menu.damage_button.pressed.emit()
	m._open_ship_debug_menu("red", Vector2(10, 10))
	m.ship_debug_menu.damage_button.pressed.emit()
	assert_eq(m.breakdown_windows.size(), 2, "one window per press")
	var w: DamageBreakdown = m.breakdown_windows[0]
	assert_eq(w.title, "Incoming DPS — blue")
	assert_eq(w.total_label.text, "Total: 40 DPS")
	assert_eq(w._cells.map(func(c): return c.text), ["red", "Test Hull", "30", "late", "Test Hull", "10"],
		"highest first; self-damage dropped")
	assert_true(m.breakdown_windows[1].empty_label.visible, "nothing on red")
	w.close_requested.emit()
	await tree.process_frame
	assert_eq(m.breakdown_windows.size(), 1, "closed window forgotten")
	m.load_match(_events_csv())
	await tree.process_frame
	assert_eq(m.breakdown_windows.size(), 0, "another match closes them")


func test_menu_rename_open_match_keeps_its_edits() -> void:
	var path := MatchLibrary.add(_match_csv())
	var m := _main()
	m.load_match(path)
	m._swap_team("blue")
	m._show_menu()
	m.menu.rename_selected("Grand final")
	var renamed := MatchLibrary.dir.path_join("Grand final.positions.csv")
	assert_eq(m.match_path, renamed)
	assert_eq(m.menu.selected_path(), renamed)
	assert_true(m.file_label.text.begins_with("Grand final.positions.csv"))
	m._on_sizes_changed()
	assert_eq(m.data.teams["blue"], MatchData.Team.RED, "swap survives the rename")


func test_menu_rename_to_taken_name_shows_error() -> void:
	MatchLibrary.add(write_csv([row(0, "a", "Test Hull", C)]))
	var src := _match_csv()
	var other := temp_dir().path_join("other.csv")
	DirAccess.copy_absolute(src, other)
	MatchLibrary.add(other)
	var m := _main()
	m.menu._select({"kind": "match", "path": MatchLibrary.dir.path_join("other.csv")})
	m.menu.rename_selected("match")
	assert_true(m.menu.error_label.visible)
	assert_eq(MatchLibrary.list().size(), 2)


# --- selection -------------------------------------------------------------------

## A viewer at 2 s with ships placed: blue and runner on grid, red (in its gap) and late not.
func _select_main() -> Main:
	var m := _main()
	m.load_match(_match_csv())
	m._seek(2.0)
	m._process(0.0)
	return m


func _screen(m: Main, pilot: String) -> Vector2:
	return m.camera.unproject_position(m.ships[pilot].node.global_position)


func _mouse(m: Main, pos: Vector2, pressed: bool, double := false) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.position = pos
	ev.pressed = pressed
	ev.double_click = double
	m._unhandled_input(ev)


func _click(m: Main, pos: Vector2, double := false) -> void:
	_mouse(m, pos, true, double)
	_mouse(m, pos, false)


## Somewhere on screen far from every ship.
func _empty_spot(m: Main) -> Vector2:
	for p in [Vector2(5, 5), Vector2(1000, 5), Vector2(5, 600)]:
		if m._pick_ship(p) == "":
			return p
	fail("no empty spot")
	return Vector2.ZERO


func test_pick_ship_hits_nearest_and_misses_empty_space() -> void:
	var m := _select_main()
	for pilot in ["blue", "runner"]:
		assert_eq(m._pick_ship(_screen(m, pilot)), pilot)
		assert_eq(m._pick_ship(_screen(m, pilot) + Vector2(Main.PICK_PX - 2, 0)), pilot, "near miss still hits")
	assert_eq(m._pick_ship(_empty_spot(m)), "")


func test_pick_ignores_hidden_and_behind_camera() -> void:
	var m := _select_main()
	assert_false(m.ships["late"].node.visible)
	assert_ne(m._pick_ship(_screen(m, "late")), "late", "not on grid yet")
	# Stand just in front of blue, looking straight away from it.
	var blue: Vector3 = m.ships["blue"].node.global_position
	m.camera.look_at_from_position(blue + Vector3(0, 0, 1), blue + Vector3(0, 0, 10))
	assert_true(m.camera.is_position_behind(blue))
	assert_ne(m._pick_ship(_screen(m, "blue")), "blue", "behind the camera")
	assert_ne(m._pick_ship(m.get_viewport().get_visible_rect().size / 2.0), "blue")


func test_hotkeys_button_toggles_list() -> void:
	var m := _select_main()
	assert_false(m.hotkeys_panel.visible)
	m.hotkeys_button.button_pressed = true
	assert_true(m.hotkeys_panel.visible)
	assert_eq(m.hotkeys_panel.grid.get_child_count(), HotkeysPanel.HOTKEYS.size() * 2)
	_click(m, _screen(m, "blue"))
	assert_true(m.info_panel.visible, "ship details still shown")
	assert_eq(m.info_panel.get_parent(), m.hotkeys_panel.get_parent())
	assert_true(m.info_panel.get_index() > m.hotkeys_panel.get_index(), "details stack below the list")
	m.hotkeys_button.button_pressed = false
	assert_false(m.hotkeys_panel.visible)


func test_menu_hotkeys_button_toggles_list() -> void:
	var m := _main()
	assert_false(m.menu.hotkeys_panel.visible)
	m.menu.hotkeys_button.button_pressed = true
	assert_true(m.menu.hotkeys_panel.visible)
	assert_eq(m.menu.hotkeys_panel.grid.get_child_count(), HotkeysPanel.HOTKEYS.size() * 2)
	m.menu.hotkeys_button.button_pressed = false
	assert_false(m.menu.hotkeys_panel.visible)


func test_click_selects_and_shows_info() -> void:
	var m := _select_main()
	assert_false(m.info_panel.visible)
	_click(m, _screen(m, "blue"))
	assert_eq(m.selected, "blue")
	assert_true(m.info_panel.visible)
	assert_true(m.info_label.text.contains("blue"))
	assert_true(m.info_label.text.contains("Test Hull"))
	assert_true(m.info_label.text.contains("Speed"))
	assert_true(m.ships["blue"].select_icon.visible)
	assert_false(m.ships["red"].select_icon.visible)
	assert_false(m.roster_buttons["blue"].flat, "roster row highlighted")
	assert_true(m.roster_buttons["red"].flat)
	assert_eq(m.tracked, "", "a single click doesn't follow")

	_click(m, _screen(m, "runner"))
	assert_eq(m.selected, "runner")
	assert_false(m.ships["blue"].select_icon.visible)
	assert_true(m.roster_buttons["blue"].flat)


func test_click_empty_space_deselects() -> void:
	var m := _select_main()
	_click(m, _screen(m, "blue"))
	_click(m, _empty_spot(m))
	assert_eq(m.selected, "")
	assert_false(m.info_panel.visible)
	assert_false(m.ships["blue"].select_icon.visible)


func test_escape_deselects() -> void:
	var m := _select_main()
	_click(m, _screen(m, "blue"))
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	m._unhandled_input(ev)
	assert_eq(m.selected, "")


func test_drag_does_not_select() -> void:
	var m := _select_main()
	var pos := _screen(m, "blue")
	_mouse(m, pos + Vector2(80, 0), true)
	_mouse(m, pos, false)
	assert_eq(m.selected, "", "drag ending on a ship")
	_click(m, pos)
	_mouse(m, _empty_spot(m), true)
	_mouse(m, _empty_spot(m) + Vector2(50, 50), false)
	assert_eq(m.selected, "blue", "drag from empty space keeps the selection")


func test_double_click_follows() -> void:
	var m := _select_main()
	_click(m, _screen(m, "blue"))
	_click(m, _screen(m, "blue"), true)
	assert_eq(m.selected, "blue")
	assert_eq(m.tracked, "blue")
	assert_true(m.roster_buttons["blue"].button_pressed)
	m._process(1.0)
	assert_almost(m.camera.target, m.ships["blue"].node.position)
	assert_true(m.info_label.text.contains("Following"))

	_click(m, _screen(m, "blue"), true)
	assert_eq(m.tracked, "blue", "double-clicking the followed ship keeps following")
	_click(m, _empty_spot(m), true)
	assert_eq(m.tracked, "blue", "double-clicking empty space doesn't drop the follow")


func _move(m: Main, pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	m._unhandled_input(ev)


func test_drag_from_ship_measures() -> void:
	var m := _select_main()
	var pos := _screen(m, "blue")
	_mouse(m, pos, true)
	assert_true(m.camera.rotate_locked, "press on a ship locks camera rotation")
	_move(m, pos + Vector2(2, 0))
	assert_false(m.measure_root.visible, "within the click slop")
	_move(m, pos + Vector2(80, 0))
	assert_true(m.measure_root.visible)
	assert_true(m.measure_label.visible)
	assert_true(m.measure_label.text.begins_with("r "))
	var r: float = m.measure_root.scale.x
	assert_true(r > 0.0)
	assert_almost(m.measure_root.position, m.ships["blue"].node.position)
	_move(m, pos + Vector2(160, 0))
	assert_true(m.measure_root.scale.x > r, "grows as the drag goes further")
	_mouse(m, pos, false)
	assert_eq(m.selected, "", "a measuring drag selects nothing")
	assert_false(m.measure_root.visible, "gone on release")
	assert_false(m.measure_label.visible)
	assert_false(m.camera.rotate_locked)


func test_measure_snaps_to_ship_and_brackets_it() -> void:
	var m := _select_main()
	_mouse(m, _screen(m, "blue"), true)
	_move(m, _screen(m, "blue") + Vector2(40, 40))
	assert_false(m.ships["runner"].measure_icon.visible)
	_move(m, _screen(m, "runner"))
	var o: Vector3 = m.ships["blue"].node.position
	var d := o.distance_to(m.ships["runner"].node.position)
	var rb: float = m.ships["blue"].radius
	var rr: float = m.ships["runner"].radius
	assert_almost(m.measure_root.scale.x, d - rr)
	assert_true(m.measure_label.text.begins_with(Main._fmt_km_m(d - rb - rr)))
	assert_true(m.ships["runner"].measure_icon.visible, "snapped ship is inside")
	assert_false(m.ships["blue"].measure_icon.visible, "origin isn't bracketed")
	_mouse(m, _screen(m, "runner"), false)
	assert_false(m.ships["runner"].measure_icon.visible)


func test_press_on_empty_space_does_not_measure() -> void:
	var m := _select_main()
	var pos := _empty_spot(m)
	_mouse(m, pos, true)
	assert_false(m.camera.rotate_locked)
	_move(m, pos + Vector2(80, 80))
	assert_false(m.measure_root.visible)
	_mouse(m, pos + Vector2(80, 80), false)


func test_in_sphere_and_fmt_km_m() -> void:
	assert_true(Main._in_sphere(10.0, 0.0, 10.0), "touching counts")
	assert_true(Main._in_sphere(10.5, 0.5, 10.0), "hull reaches in")
	assert_false(Main._in_sphere(10.5, 0.4, 10.0))
	assert_eq(Main._fmt_km_m(0.85), "850 m")
	assert_eq(Main._fmt_km_m(12.3451), "12.345 km")
	assert_eq(Main._fmt_km_m(1.0), "1.000 km")
	assert_eq(Main._fmt_km_m(0.9996), "1.000 km")


func test_info_shows_death() -> void:
	var m := _select_main()
	_click(m, _screen(m, "runner"))
	m._seek(10.0)
	m._process(0.0)
	assert_true(m.info_label.text.contains("DEAD"))


func test_reload_drops_missing_selection() -> void:
	var m := _select_main()
	_click(m, _screen(m, "blue"))
	m.load_match(_match_csv())
	assert_eq(m.selected, "blue", "same pilots: kept")
	assert_true(m.ships["blue"].select_icon.visible)
	m.load_match(write_csv([row(0, "red", "Test Hull", on_line(7, 0.5))]))
	assert_eq(m.selected, "")
	assert_false(m.info_panel.visible)


func test_boundary_toggle() -> void:
	var m := _main()
	assert_true(m.boundary.visible)
	m.boundary_setting.button_pressed = false
	assert_false(m.boundary.visible)


func test_popups_opaque() -> void:
	var m := _main()
	for popup in [m.settings_popup, m.overlay_popup, m.all_debug_menu, m.ship_debug_menu]:
		assert_eq(popup.get_theme_stylebox("panel").bg_color.a, 1.0)


# --- ship models -----------------------------------------------------------------

## A viewer whose asset cache is a temp dir holding the MJU model (standing in for "Test Hull",
## a 50 m frigate) and a couple of brackets, so model mode never touches the network.
func _model_main(cache_model := true) -> Main:
	var m := _main()
	m.sizes.ships = {"test hull": {"name": "Test Hull", "type_id": 33591, "group_id": 25, "radius_m": 50.0}}
	var dir := temp_dir()
	DirAccess.make_dir_recursive_absolute(dir.path_join("models"))
	DirAccess.make_dir_recursive_absolute(dir.path_join("brackets"))
	DirAccess.copy_absolute(ProjectSettings.globalize_path("res://tests/fixtures/mobile-micro-jump-unit.glb"),
		dir.path_join("models/33591.glb"))
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.save_png(dir.path_join("brackets/frigate_32.png"))
	img.save_png(dir.path_join("brackets/mobilemicrojumpunit.png"))
	var a := m.assets
	a._dir = dir
	a.has_brackets = true
	# Without the model, an empty index keeps `ensure_models` from downloading it.
	a.index = {33591: "extra_models/33591_lite.glb"} if cache_model else {}
	a.models = {33591: ""} if cache_model else {}
	a._scenes.clear()
	a._textures.clear()
	m.load_match(_match_csv())
	return m


func test_models_off_draws_spheres() -> void:
	var m := _model_main()
	assert_false(m.models_on)
	m._seek(0.0)
	m._update_ships()
	var blue: Dictionary = m.ships["blue"]
	assert_eq(blue.model_id, 0)
	assert_eq(blue.visual.mesh, m.sphere_mesh)
	assert_false(blue.icon.visible)
	assert_true(m.markers_box.visible)
	assert_false(m.markers_model.visible)


func test_models_on_draws_model_and_icon() -> void:
	var m := _model_main()
	m._set_models_on(true)
	assert_true(Settings.get_value("display/ship_models"))
	assert_true(m.models_setting.button_pressed)
	m._seek(0.0)
	m._update_ships()
	var blue: Dictionary = m.ships["blue"]
	assert_eq(blue.model_id, 33591)
	assert_false(blue.visual is MeshInstance3D, "model, not the sphere")
	assert_almost(blue.visual.scale, Vector3.ONE * 0.05, 1e-4, "true 50 m radius, no min-size clamp")
	assert_true(blue.icon.visible)
	assert_true(blue.icon.fixed_size)
	assert_not_null(blue.icon.texture)
	assert_false(m.markers_box.visible)
	assert_true(m.markers_model.visible)
	assert_eq(m.markers_model.get_child_count(), 9)

	m._set_models_on(false)
	m._update_ships()
	assert_eq(blue.model_id, 0)
	assert_eq(blue.visual.mesh, m.sphere_mesh)
	assert_false(blue.icon.visible)
	assert_false(Settings.get_value("display/ship_models"))


func test_ship_overlay_icon_toggle() -> void:
	var m := _model_main()
	m._set_models_on(true)
	m._seek(0.0)
	m._update_ships()
	var blue: Dictionary = m.ships["blue"]
	assert_true(blue.icon.visible)
	m._set_overlay("icon", false)
	m._update_ships()
	assert_false(blue.icon.visible)
	assert_false(Settings.get_value("overlay/icon"))
	m._set_overlay("icon", true)
	m._update_ships()
	assert_true(blue.icon.visible)


func test_uncached_model_falls_back_to_sphere_with_icon() -> void:
	var m := _model_main(false)
	m._set_models_on(true)
	m._seek(0.0)
	m._update_ships()
	var blue: Dictionary = m.ships["blue"]
	assert_eq(blue.model_id, 0)
	assert_eq(blue.visual.mesh, m.sphere_mesh)
	assert_true(blue.icon.visible)


func test_model_key_toggles() -> void:
	var m := _model_main()
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_M
	m._unhandled_input(key)
	assert_true(m.models_on)
	m._unhandled_input(key)
	assert_false(m.models_on)


func test_smooth_motion_setting() -> void:
	var m := _main()
	assert_true(m.smooth_on, "on by default")
	m.load_match(_match_csv())
	assert_true(m.data.smooth)
	m._set_smooth_on(false)
	assert_false(m.data.smooth)
	assert_eq(Settings.get_value("display/smooth_motion"), false)
	m.load_match(_match_csv())
	assert_false(m.data.smooth, "new match picks up the setting")


## "p" flies +X at 1 km/s for 10 s, then turns to +Y. Its ship is flagged as a model so
## `_face_heading` rotates it (tests run with models off).
func _turning_ship(m: Main) -> Dictionary:
	var rows := []
	for t in 21:
		var p := C + (X * t if t <= 10 else X * 10.0 + Vector3.UP * (t - 10)) * 1000.0
		rows.append(row(t, "p", "Test Hull", p))
	m.load_match(write_csv(rows))
	var ship: Dictionary = m.ships["p"]
	ship.model_id = 1
	return ship


func _nose(ship: Dictionary) -> Vector3:
	return ship.visual.basis.z.normalized()


func test_jitter_setting_moves_match_start() -> void:
	var m := _main()
	m.load_match(write_csv([
		row(0, "a", "Rifter", C),
		row(2, "a", "Rifter", C + X * 100),
		row(4, "a", "Rifter", C + X * 2000),
		row(6, "a", "Rifter", C + X * 4000),
	]))
	assert_false(m.jitter_setting.button_pressed, "off by default")
	assert_false(m.jitter_spin.editable)
	assert_eq(m.data.start_time, 0.0, "any movement starts the match")
	m.jitter_setting.button_pressed = true
	assert_true(Settings.get_value("match/ignore_jitter"))
	assert_true(m.jitter_spin.editable)
	assert_eq(m.data.start_time, 2.0, "reloaded: 100 m drift is jitter")
	assert_eq(m.timeline.max_value, 4.0)
	m.jitter_spin.value = 3000.0
	assert_eq(Settings.get_value("match/jitter_threshold_m"), 3000.0)
	assert_eq(m.data.start_time, 4.0)


func test_smooth_heading_turns_gradually() -> void:
	var m := _main()
	var ship := _turning_ship(m)
	m.time = 5.0
	m._face_heading(ship, "p")
	assert_almost(_nose(ship), X, 1e-3, "first update snaps to the heading")
	var last := _nose(ship)
	var max_step := 0.0
	for i in 100:
		m.time = 5.0 + (i + 1) * 0.1
		m._face_heading(ship, "p")
		max_step = maxf(max_step, last.angle_to(_nose(ship)))
		last = _nose(ship)
	assert_true(max_step < 0.1, "no sudden turn (max %.3f rad per 0.1 s)" % max_step)
	assert_true(_nose(ship).angle_to(Vector3.UP) < 0.1, "ends up facing the new course")


func test_smooth_heading_snaps_on_seek() -> void:
	var m := _main()
	var ship := _turning_ship(m)
	m.time = 5.0
	m._face_heading(ship, "p")
	m.time = 15.0
	m._face_heading(ship, "p")
	assert_almost(_nose(ship), Vector3.UP, 1e-3)


func test_heading_without_smoothing_snaps() -> void:
	var m := _main()
	m._set_smooth_on(false)
	var ship := _turning_ship(m)
	m.time = 9.0
	m._face_heading(ship, "p")
	assert_almost(_nose(ship), X, 1e-3)
	m.time = 10.6
	m._face_heading(ship, "p")
	assert_almost(_nose(ship), Vector3.UP, 1e-3, "faces the new course right away")


# --- debug overlays --------------------------------------------------------------

func _right(m: Main, pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.position = pos
	ev.pressed = pressed
	m._unhandled_input(ev)


func test_right_click_ship_opens_its_debug_menu() -> void:
	var m := _select_main()
	_right(m, _screen(m, "blue"), true)
	_right(m, _screen(m, "blue"), false)
	assert_eq(m.debug_pilot, "blue")
	assert_true(m.ship_debug_menu.visible)
	assert_eq(m.ship_debug_menu.title_label.text, "blue")


func test_right_drag_or_empty_space_opens_nothing() -> void:
	var m := _select_main()
	var pos := _screen(m, "blue")
	_right(m, pos + Vector2(80, 0), true)
	_right(m, pos, false)
	assert_false(m.ship_debug_menu.visible, "pan ending on a ship")
	_right(m, _empty_spot(m), true)
	_right(m, _empty_spot(m), false)
	assert_false(m.ship_debug_menu.visible, "empty space")


func test_roster_right_click_opens_debug_menu() -> void:
	var m := _select_main()
	m.roster_table.row_context_pressed.emit("red")
	assert_eq(m.debug_pilot, "red")
	assert_true(m.ship_debug_menu.visible)


## "jumper" (corner 0) flies +Y at 100 m/s, then micro jumps 100 km along +X at 21 s; "other"
## (corner 7) sits still.
func _mjd_main() -> Main:
	var m := _main()
	var rows := []
	for t in 21:
		rows.append(row(t, "jumper", "Test Hull", on_line(0, 0.5) + Vector3.UP * 100 * t))
		rows.append(row(t, "other", "Test Hull", on_line(7, 0.5)))
	rows.append(row(21, "jumper", "Test Hull", on_line(0, 0.5) + Vector3.UP * 2000 + X * 100000))
	m.load_match(write_csv(rows))
	return m


func test_mjd_spool_up_graphics() -> void:
	var m := _mjd_main()
	var ship: Dictionary = m.ships["jumper"]
	m._seek(5.0)
	m._process(0.0)
	assert_false(ship.mjd_ring.visible, "not spooling yet")
	assert_false(ship.mjd_projection.visible)
	assert_eq(m.broadcast_panel.rows["jumper"].mjd.get_child_count(), 0)

	m._seek(15.0)
	m._process(0.0)
	assert_true(ship.mjd_ring.visible)
	assert_true(ship.mjd_projection.visible)
	assert_eq(ship.mjd_label.text, "jumper MJD 6 s")
	# Where it actually lands (+X), not 100 km along its current heading (+Y).
	assert_almost(ship.mjd_land, (on_line(0, 0.5) + Vector3.UP * 2000 + X * 100000) * Main.M_TO_UNITS)
	var icons: HBoxContainer = m.broadcast_panel.rows["jumper"].mjd
	assert_eq(icons.get_child_count(), 1)
	assert_eq(icons.get_child(0).tooltip_text, "Micro jump drive spooling: jumps in 6 s")
	assert_eq(m.broadcast_panel.rows["other"].mjd.get_child_count(), 0)

	m.mjd_button.button_pressed = false
	assert_false(Settings.get_value("display/mjd_spoolup"))
	assert_false(m.mjd_setting.button_pressed, "settings checkbox follows")
	m._process(0.0)
	assert_false(ship.mjd_ring.visible, "space graphics are behind the toggle")
	assert_false(ship.mjd_projection.visible)
	assert_eq(icons.get_child_count(), 1, "broadcast icon shows regardless")

	m.mjd_setting.button_pressed = true
	m._seek(21.0)
	m._process(0.0)
	assert_false(ship.mjd_ring.visible, "landed")
	assert_eq(icons.get_child_count(), 0)


func test_mjd_projection_shows_landing_when_stopped() -> void:
	var m := _main()
	var rows := []
	for t in 21:
		var y := 100 * mini(t, 5)  # stops at 5 s
		rows.append(row(t, "jumper", "Test Hull", on_line(0, 0.5) + Vector3.UP * y))
		rows.append(row(t, "other", "Test Hull", on_line(7, 0.5)))
	rows.append(row(21, "jumper", "Test Hull", on_line(0, 0.5) + Vector3.UP * 500 + X * 100000))
	m.load_match(write_csv(rows))
	var ship: Dictionary = m.ships["jumper"]
	m._seek(15.0)
	m._process(0.0)
	assert_true(ship.mjd_projection.visible)
	assert_almost(ship.mjd_land, (on_line(0, 0.5) + Vector3.UP * 500 + X * 100000) * Main.M_TO_UNITS)


func test_movement_vector_projects_velocity() -> void:
	var m := _main()
	var rows := []
	for t in 21:
		rows.append(row(t, "blue", "Test Hull", C + X * 100 * t))
	m.load_match(write_csv(rows))
	m._seek(2.0)
	m._process(0.0)
	var ship: Dictionary = m.ships["blue"]
	assert_false(ship.vector.visible)
	m._open_ship_debug_menu("blue", Vector2.ZERO)
	m.ship_debug_menu.vector_check.button_pressed = true
	assert_true(ship.vector.visible)
	m._process(0.0)
	var v := X * 100
	assert_almost(ship.vector_tip, v * Main.VECTOR_SECONDS * Main.M_TO_UNITS)
	m.all_debug_menu.seconds_spin.value = 10.0
	m._process(0.0)
	assert_almost(ship.vector_tip, v * 10.0 * Main.M_TO_UNITS)
	m.ship_debug_menu.vector_check.button_pressed = false
	assert_false(ship.vector.visible)


func test_all_ships_vectors() -> void:
	var m := _select_main()
	m._open_all_debug_menu()
	m.all_debug_menu.vector_check.button_pressed = true
	for pilot in m.ships:
		assert_true(m.ships[pilot].vector.visible, pilot)
	m._open_all_debug_menu()
	assert_true(m.all_debug_menu.vector_check.button_pressed, "shown as all on")
	m.all_debug_menu.vector_check.button_pressed = false
	for pilot in m.ships:
		assert_false(m.ships[pilot].vector.visible, pilot)


## Radii (km) of `pilot`'s range spheres.
func _sphere_radii(m: Main, pilot: String) -> Array:
	return m.ships[pilot].spheres.get_children().filter(func(c): return not c.is_queued_for_deletion()) \
		.map(func(c): return c.get_child(1).mesh.radius)


func test_ship_spheres_add_and_remove() -> void:
	var m := _select_main()
	m._open_ship_debug_menu("blue", Vector2.ZERO)
	var menu: DebugMenu = m.ship_debug_menu
	menu.radius_spin.value = 5.0
	menu.add_button.pressed.emit()
	menu.radius_spin.value = 20.0
	menu.color_button.color = Color.RED
	menu.add_button.pressed.emit()
	assert_eq(_sphere_radii(m, "blue"), [5.0, 20.0])
	assert_eq(_sphere_radii(m, "red"), [])
	assert_eq(menu.sphere_list.get_child_count(), 2, "listed in the menu")
	menu.sphere_removed.emit(0)
	assert_eq(_sphere_radii(m, "blue"), [20.0])
	assert_eq(m.debug["blue"].spheres[0].color, Color.RED)


func test_all_ships_spheres_add_and_clear() -> void:
	var m := _select_main()
	m._add_sphere("blue", 3.0, Color.WHITE)
	m.all_debug_menu.radius_spin.value = 8.0
	m.all_debug_menu.add_button.pressed.emit()
	for pilot in m.ships:
		assert_true(_sphere_radii(m, pilot).has(8.0), pilot)
	assert_eq(_sphere_radii(m, "blue"), [3.0, 8.0])
	m.all_debug_menu.clear_button.pressed.emit()
	for pilot in m.ships:
		assert_eq(_sphere_radii(m, pilot), [], pilot)


func test_debug_state_survives_same_match_reload_only() -> void:
	var m := _select_main()
	m._add_sphere("blue", 3.0, Color.WHITE)
	m._set_vector("blue", true)
	m.load_match(m.match_path)
	assert_eq(_sphere_radii(m, "blue"), [3.0])
	assert_true(m.ships["blue"].vector.visible)
	m.load_match(_match_csv())
	assert_eq(_sphere_radii(m, "blue"), [], "different match")
	assert_false(m.ships["blue"].vector.visible)


func test_beacon_jump_ranges() -> void:
	var m := _main()
	assert_false(m.beacon_ranges_corner.visible)
	assert_false(m.beacon_ranges_centre.visible)
	m.all_debug_menu.corner_check.button_pressed = true
	assert_true(m.beacon_ranges_corner.visible)
	assert_false(m.beacon_ranges_centre.visible)
	m.all_debug_menu.centre_check.button_pressed = true
	assert_true(m.beacon_ranges_centre.visible)
	assert_eq(m.beacon_ranges_corner.get_child_count(), 8)
	assert_eq(m.beacon_ranges_centre.get_child_count(), 1)
	var centre: Node3D = m.beacon_ranges_centre.get_child(0)
	assert_almost(centre.position, Vector3.ONE * Main.CUBE / 2.0)
	assert_almost(centre.get_child(1).mesh.radius, Main.BEACON_JUMP_KM)


func test_activity_lines() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._set_playing(false)
	var gamelog := CombatLog.new()
	gamelog.entries = [{
		"eve_unix": 1005.0, "t": 5.0, "kind": CombatLog.Kind.DAMAGE, "text": "",
		"source": "blue", "target": "late", "source_ship": "", "target_ship": "",
		"source_pilot": "blue", "target_pilot": "late", "amount": 100.0, "weapon": "Gun", "quality": "",
	}]
	m.combat_stats = CombatStats.from_logs([gamelog])
	var lines: ImmediateMesh = m.links_mesh.mesh
	m._seek(6.0)
	m._process(0.0)
	assert_eq(lines.get_surface_count(), 1, "blue shooting late")
	m._seek(12.0)
	m._process(0.0)
	assert_eq(lines.get_surface_count(), 0, "the shot has long passed")
	m._seek(6.0)
	m._refresh_all_debug_menu()
	assert_true(m.all_debug_menu.link_checks.shooting.button_pressed, "on by default")
	m.all_debug_menu.link_checks.shooting.button_pressed = false
	assert_false(Settings.get_value("links/shooting"))
	m._process(0.0)
	assert_eq(lines.get_surface_count(), 0, "shooting hidden")
	m.all_debug_menu.link_color_changed.emit("tackle", Color.GREEN)
	assert_eq(Settings.get_value("links/tackle_color"), Color.GREEN)
	var again := _main()
	assert_false(again.links.shooting.on, "kept across restarts")
	assert_eq(again.links.tackle.color, Color.GREEN)
