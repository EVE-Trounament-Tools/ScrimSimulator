extends "res://tests/test_case.gd"
## The web build's helpers that don't need a browser: library diffing and placeholders
## (WebLibrary), mirror URLs (WebBackend) and picker filters (WebFilePicker). Synthetic data only.

const SHA_A := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const SHA_B := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

var _saved_dir: String


func before_each() -> void:
	_saved_dir = MatchLibrary.dir
	MatchLibrary.dir = temp_dir().path_join("matches")
	WebLibrary._hashes = {}


func after_each() -> void:
	MatchLibrary.dir = _saved_dir
	WebBackend._origin = ""


func _write(rel: String, body: String) -> String:
	var path := MatchLibrary.dir.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(body)
	f.close()
	return path


func test_diff_reports_added_changed_and_removed() -> void:
	var base := {"a": "1", "b": "2", "c": "3"}
	var now := {"a": "1", "b": "9", "d": "4"}
	assert_eq(WebLibrary._diff(base, now), {"b": "9", "d": "4", "c": null})
	assert_eq(WebLibrary._diff(now, now), {})


func test_match_key_matches_the_site() -> void:
	# Same cases as web/worker/test/worker.test.ts.
	assert_eq(WebLibrary.match_key("a/m.positions.csv"), "a/m.positions")
	assert_eq(WebLibrary.match_key("a/m.positions.json"), "a/m.positions")
	assert_eq(WebLibrary.match_key("a/m.positions.logs/x.txt"), "a/m.positions")
	assert_eq(WebLibrary.match_key("a/M.Positions.LOGS/x.txt"), "a/M.Positions")
	assert_eq(WebLibrary.match_key("m.ogg"), "m")


func test_units_join_a_rename_and_keep_other_matches_apart() -> void:
	var ops := [
		{"op": "delete", "path": "S/old.positions.csv", "prev": SHA_A},
		{"op": "delete", "path": "S/old.positions.json", "prev": SHA_B},
		{"op": "put", "path": "S/new.positions.csv", "sha": SHA_A, "size": 1, "prev": null},
		{"op": "put", "path": "S/other.positions.csv", "sha": SHA_B.replace("b", "c"), "size": 1, "prev": null},
		{"op": "put", "path": "T/", "sha": "", "size": 0, "prev": null},
	]
	var units := WebLibrary._units(ops)
	assert_eq(units.size(), 3)
	var sizes := units.map(func(u): return u.size())
	sizes.sort()
	assert_eq(sizes, [1, 1, 3])


func test_placeholders_stand_for_their_sha_and_move_with_renames() -> void:
	WebLibrary._apply("S/", "", 0)
	WebLibrary._apply("S/m.positions.csv", SHA_A, 1234)
	var path := MatchLibrary.dir.path_join("S/m.positions.csv")
	assert_true(WebLibrary._is_marker(path))
	assert_eq(WebLibrary._read_marker(path), {"sha": SHA_A, "size": 1234})
	assert_eq(MatchLibrary.list().map(func(e): return e.name), ["m"])
	var renamed := MatchLibrary.rename(path, "n")
	assert_eq(WebLibrary.scan_local(), {"S/": "", "S/n.positions.csv": SHA_A})
	assert_eq(WebLibrary._local_size("S/n.positions.csv"), 1234)
	assert_true(WebLibrary._is_marker(renamed))


func test_scan_hashes_real_files_and_skips_logs_dirs_and_partial_downloads() -> void:
	_write("m.positions.csv", "t,pilot\n")
	_write("m.positions.logs/a.txt", "log")
	_write("x.ogg.part", "half")
	var scan := WebLibrary.scan_local()
	assert_eq(scan.keys().size(), 2)
	assert_eq(scan["m.positions.csv"], "t,pilot\n".sha256_text())
	assert_eq(scan["m.positions.logs/a.txt"], "log".sha256_text())


func test_apply_removes_files_and_empty_logs_dirs_but_keeps_real_identical_content() -> void:
	var csv := _write("m.positions.csv", "real")
	WebLibrary._apply("m.positions.csv", "real".sha256_text(), 4)
	assert_eq(FileAccess.get_file_as_string(csv), "real")
	_write("m.positions.logs/a.txt", "log")
	WebLibrary._apply("m.positions.logs/a.txt", null, 0)
	assert_false(DirAccess.dir_exists_absolute(MatchLibrary.dir.path_join("m.positions.logs")))
	WebLibrary._apply("m.positions.csv", null, 0)
	assert_false(FileAccess.file_exists(csv))


func test_rewrite_points_upstream_downloads_at_the_mirror() -> void:
	WebBackend._origin = "https://sim.example"
	assert_eq(WebBackend.rewrite_url(ShipAssets.INDEX_URL),
		"https://sim.example/assets/gallery/statics/resources_index_en.json")
	assert_eq(WebBackend.rewrite_url(ShipAssets.GALLERY + "models/1.glb"), "https://sim.example/assets/gallery/models/1.glb")
	assert_eq(WebBackend.rewrite_url(ShipAssets.ICONS_URL), "https://sim.example/assets/icons.zip")
	assert_eq(WebBackend.rewrite_url(ShipAssets.IMAGE_SERVER % 447), "https://sim.example/assets/types/447.png")
	assert_eq(WebBackend.rewrite_url("https://esi.evetech.net/x"), "https://esi.evetech.net/x")


func test_picker_accept_from_dialog_filters() -> void:
	assert_eq(WebFilePicker._accept(PackedStringArray(["*.ogg, *.mp3, *.wav ; Audio files"])), ".ogg,.mp3,.wav")
	assert_eq(WebFilePicker._accept(PackedStringArray(["*.csv ; CSV files"])), ".csv")
	assert_eq(WebFilePicker._accept(PackedStringArray()), "")
