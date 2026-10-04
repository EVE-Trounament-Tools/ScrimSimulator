extends "res://tests/test_case.gd"
## ShipAssets: index parsing, bracket mapping, model normalisation and the cache. Instances are
## kept out of the scene tree so `_ready` never loads the real `sde/assets/` cache; network paths
## aren't covered.

## Mobile Micro Jump Unit from EVE_Model_Gallery, already run through `glb-undraco`.
const MJU_GLB := "res://tests/fixtures/mobile-micro-jump-unit.glb"


func _assets(dir := "") -> ShipAssets:
	var a: ShipAssets = own(ShipAssets.new())
	a._dir = dir if dir else temp_dir()
	return a


## A cache dir holding the MJU model as type 33591 and a frigate bracket.
func _populated_dir() -> String:
	var dir := temp_dir()
	DirAccess.make_dir_recursive_absolute(dir.path_join("models"))
	DirAccess.copy_absolute(ProjectSettings.globalize_path(MJU_GLB), dir.path_join("models/33591.glb"))
	DirAccess.make_dir_recursive_absolute(dir.path_join("brackets"))
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	img.save_png(dir.path_join("brackets/frigate_32.png"))
	img.save_png(dir.path_join("brackets/mobilemicrojumpunit.png"))
	return dir


# --- index / brackets --------------------------------------------------------

func test_parse_index() -> void:
	var idx := ShipAssets.parse_index([
		{"id": 6, "groups": [
			{"id": 25, "types": [
				{"id": 587, "model_path": "./models/587_lite.glb"},
				{"id": 999, "model_path": ""},
				{"id": 998},
			]},
		]},
		{"id": 22, "groups": [{"id": 1276, "types": [{"id": 33591, "model_path": "./extra_models/33591_lite.glb"}]}]},
		"junk",
	])
	assert_eq(idx, {587: "models/587_lite.glb", 33591: "extra_models/33591_lite.glb"})


func test_bracket_name() -> void:
	assert_eq(ShipAssets.bracket_name(25), "frigate")
	assert_eq(ShipAssets.bracket_name(419), "battlecruiser")
	assert_eq(ShipAssets.bracket_name(29), "capsule")
	assert_eq(ShipAssets.bracket_name(1, "Precursor Battlecruiser"), "battlecruiser", "keyword fallback")
	assert_eq(ShipAssets.bracket_name(1, "Logistics Destroyer"), "destroyer")
	assert_eq(ShipAssets.bracket_name(1, "Something New"), ShipAssets.DEFAULT_BRACKET)


func test_bracket_texture() -> void:
	var a := _assets(_populated_dir())
	var tex := a.bracket(25)
	assert_not_null(tex)
	assert_eq(tex.get_height(), 32)
	assert_not_null(a.bracket_texture(ShipAssets.MJU_BRACKET), "unsuffixed deployable icon")
	assert_null(a.bracket(27), "battleship icon not on disk")


func test_ewar_texture() -> void:
	var dir := temp_dir()
	DirAccess.make_dir_recursive_absolute(dir.path_join("ewar"))
	Image.create(64, 64, false, Image.FORMAT_RGBA8).save_png(dir.path_join("ewar/neut.png"))
	var a := _assets(dir)
	assert_eq(a.ewar_texture("neut").get_height(), 64)
	assert_null(a.ewar_texture("scram"), "not on disk")
	for type in CombatStats.EWAR_TYPES:
		assert_true(ShipAssets.EWAR_TYPE_IDS.has(type), "icon type ID for %s" % type)


func test_extract_brackets() -> void:
	var zip_path := temp_dir().path_join("icons.zip")
	var zip := ZIPPacker.new()
	assert_eq(zip.open(zip_path), OK)
	for name in ["Icons/items/Brackets/Frigate_32.png", "Icons/items/Brackets/readme.txt",
			"Icons/items/Modules/gun.png"]:
		zip.start_file(name)
		zip.write_file("x".to_utf8_buffer())
		zip.close_file()
	zip.close()
	var out := temp_dir()
	assert_eq(ShipAssets.extract_brackets(zip_path, out), "")
	assert_eq(Array(DirAccess.get_files_at(out)), ["frigate_32.png"])
	assert_true(ShipAssets.extract_brackets(temp_dir().path_join("missing.zip"), out).begins_with("Cannot open"))


# --- models --------------------------------------------------------------------

func test_normalize_centres_and_scales_to_unit_radius() -> void:
	var box := BoxMesh.new()
	box.size = Vector3(10, 2, 4)
	var mesh := MeshInstance3D.new()
	mesh.mesh = box
	mesh.position = Vector3(100, 0, 0)
	var root := Node3D.new()
	root.add_child(mesh)
	var pivot := ShipAssets.normalize(root)
	var b := ShipAssets._mesh_bounds(pivot, Transform3D.IDENTITY)
	assert_almost(b.get_center(), Vector3.ZERO)
	assert_almost(b.size, Vector3(2, 0.4, 0.8))
	assert_eq(mesh.owner, pivot)
	pivot.free()


func test_load_model_scene() -> void:
	var scene := ShipAssets.load_model_scene(ProjectSettings.globalize_path(MJU_GLB))
	assert_not_null(scene)
	var model := scene.instantiate()
	var b := ShipAssets._mesh_bounds(model, Transform3D.IDENTITY)
	assert_almost(0.5 * b.get_longest_axis_size(), 1.0)
	assert_almost(b.get_center(), Vector3.ZERO)
	assert_true(model.find_children("*", "MeshInstance3D", true, false).size() > 0)
	model.free()


func test_instance_model_needs_cached_file() -> void:
	var a := _assets(_populated_dir())
	assert_null(a.instance_model(33591), "not in the cache index")
	a.models[33591] = "etag"
	var m := a.instance_model(33591)
	assert_not_null(m)
	m.free()


func test_undraco_path_is_absolute_or_empty() -> void:
	var p := ShipAssets.undraco_path()
	assert_true(p == "" or p.is_absolute_path(), p)


# --- cache / status ------------------------------------------------------------

func test_cache_round_trip_drops_missing_models() -> void:
	var dir := _populated_dir()
	var a := _assets(dir)
	a.has_brackets = true
	a.index = {33591: "extra_models/33591_lite.glb", 587: "models/587_lite.glb"}
	a.index_etag = "\"abc\""
	a.models = {33591: "\"m1\"", 587: "\"m2\""}  # 587 has no file on disk.
	a._save_cache()

	var b := _assets(dir)
	b._load_cache()
	assert_true(b.is_loaded())
	assert_eq(b.index, {33591: "extra_models/33591_lite.glb", 587: "models/587_lite.glb"})
	assert_eq(b.index_etag, "\"abc\"")
	assert_eq(b.models, {33591: "\"m1\""})
	assert_true(b.has_model(33591))
	assert_false(b.has_model(587))
	assert_eq(b.status, "1 ship models cached")


func test_start() -> void:
	var a := _assets()
	var reasons := []
	a.needs_download.connect(func(reason): reasons.append(reason))
	a.start(false, true)
	assert_eq(reasons, [], "models off: no prompt")
	a.start(true, false)
	assert_eq(reasons.size(), 1)


func test_ensure_models_waits_for_index() -> void:
	var a := _assets()
	a.ensure_models([587, 587, 33591])
	assert_eq(a._wanted.keys(), [587, 33591])
	assert_eq(a._fetching, {})
