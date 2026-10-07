class_name ShipAssets
extends Node
## Hull models and overview bracket icons, for drawing ships instead of spheres.
##
## Brackets come from CCP's Image Export Collection icon zip (~18 MB, downloaded once with the
## user's consent; only `Icons/items/Brackets/*` is kept). Electronic warfare module icons come
## from CCP's image server, each fetched the first time it is shown. Models come from
## EVE_Model_Gallery (GLBs exported from the game client), indexed by type ID in its
## `resources_index_en.json`.
## The full set is several GB, so each hull is fetched the first time a match needs it. The
## GLBs are Draco-compressed, which Godot can't read, so every download is rewritten by the
## `glb-undraco` helper before it's cached. Everything lives in `sde/assets/` (git-ignored).
## Updates: the index and cached models are re-checked by ETag; the icon zip and ewar icons are
## frozen.

signal status_changed(text: String)
## Brackets or the model index are missing; `reason` is shown to the user.
signal needs_download(reason: String)
## New models or brackets are on disk.
signal assets_changed
## An electronic warfare icon was downloaded; `ewar_texture` now returns it.
signal ewar_icons_changed

const GALLERY := "https://raw.githubusercontent.com/EstamelGG/EVE_Model_Gallery/main/docs/"
const INDEX_URL := GALLERY + "statics/resources_index_en.json"
const ICONS_URL := "https://web.ccpgamescdn.com/aws/developers/Uprising_V21.03_Icons.zip"
const BRACKETS_PREFIX := "Icons/items/Brackets/"
const IMAGE_SERVER := "https://images.evetech.net/types/%d/icon?size=64"
const MJU_TYPE_ID := 33591
const MJU_BRACKET := "mobilemicrojumpunit"
const WORKERS := 4

## Overview bracket per ship group ID; groups not listed are matched on name (`BRACKET_KEYWORDS`).
const GROUP_BRACKETS := {
	25: "frigate", 324: "frigate", 830: "frigate", 831: "frigate", 834: "frigate",
	893: "frigate", 1022: "frigate", 1527: "frigate", 5087: "frigate",
	1283: "miningfrigate", 237: "rookie", 31: "shuttle", 29: "capsule",
	420: "destroyer", 541: "destroyer", 1305: "destroyer", 1534: "destroyer",
	26: "cruiser", 358: "cruiser", 832: "cruiser", 833: "cruiser", 894: "cruiser", 906: "cruiser",
	963: "cruiser", 1972: "cruiser",
	419: "battlecruiser", 540: "battlecruiser", 1201: "battlecruiser",
	27: "battleship", 898: "battleship", 900: "battleship",
	28: "industrial", 380: "industrial", 1202: "industrial",
	463: "miningbarge", 543: "miningbarge",
	941: "industrialcommand", 883: "industrialcommand", 4902: "industrialcommand",
	513: "freighter", 902: "freighter",
	485: "dreadnought", 4594: "dreadnought",
	547: "carrier", 5120: "carrier", 1538: "forceauxiliary", 659: "supercarrier", 30: "titan",
}
## [substring of the lowercase group name, bracket], first match wins.
const BRACKET_KEYWORDS := [
	["capsule", "capsule"], ["shuttle", "shuttle"], ["corvette", "rookie"],
	["battlecruiser", "battlecruiser"], ["battleship", "battleship"], ["dreadnought", "dreadnought"],
	["supercarrier", "supercarrier"], ["titan", "titan"], ["force auxiliary", "forceauxiliary"],
	["carrier", "carrier"], ["freighter", "freighter"], ["industrial command", "industrialcommand"],
	["mining barge", "miningbarge"], ["exhumer", "miningbarge"], ["destroyer", "destroyer"],
	["interdictor", "destroyer"], ["cruiser", "cruiser"], ["recon", "cruiser"],
	["logistics", "cruiser"], ["industrial", "industrial"], ["transport", "industrial"],
	["blockade", "industrial"],
]
const DEFAULT_BRACKET := "frigate"
## T1 module whose image server icon stands for each `CombatStats.EWAR_TYPES` key, plus "mjd" for
## the micro jump drive spool-up icon.
const EWAR_TYPE_IDS := {
	"scram": 447,  # Warp Scrambler I
	"disrupt": 3242,  # Warp Disruptor I
	"neut": 533,  # Small Energy Neutralizer I
	"nos": 530,  # Small Energy Nosferatu I
	"ecm": 1957,  # Multispectral ECM I
	"td": 2108,  # Tracking Disruptor I
	"gd": 37543,  # Guidance Disruptor I
	"damp": 1968,  # Remote Sensor Dampener I
	"tp": 12709,  # Target Painter I
	"rsb": 1963,  # Remote Sensor Booster I
	"rtc": 2103,  # Remote Tracking Computer I
	"mjd": 4383,  # Micro Jump Drive
}

## Type ID -> model path relative to `GALLERY`.
var index := {}
var index_etag := ""
## Type ID -> ETag of the cached, decoded model.
var models := {}
var has_brackets := false
var busy := false
## Whether missing ewar icons are downloaded (tests turn it off to stay offline).
var fetch_ewar_icons := true
var status := ""

var _dir := ""
var _thread: Thread
## Type IDs asked for before the index was available, or while it was being refreshed.
var _wanted := {}
var _fetching := {}  # type id -> true while downloading or decoding
var _failed := {}  # type id -> true; not retried until the next start
var _scenes := {}  # type id -> PackedScene, or null if the model wouldn't load
var _textures := {}  # bracket name -> Texture2D, or null
var _ewar_textures := {}  # EWAR_TYPE_IDS key -> Texture2D, or null
var _ewar_fetching := {}  # EWAR_TYPE_IDS key -> true while downloading, or after it failed


func _ready() -> void:
	_dir = ShipSizes.data_dir().path_join("assets")
	_load_cache()


func _exit_tree() -> void:
	if _thread != null:
		_thread.wait_to_finish()


func is_loaded() -> bool:
	return has_brackets and not index.is_empty()


func has_model(type_id: int) -> bool:
	return models.has(type_id)


## Startup entry point; does nothing unless ship models are switched on.
func start(enabled: bool, auto_update: bool) -> void:
	if not enabled:
		_set_status(_summary())
	elif not is_loaded():
		needs_download.emit("Ship models and overview icons aren't downloaded yet.")
	elif auto_update:
		check_update()
	else:
		_set_status(_summary())


func _summary() -> String:
	if not is_loaded():
		return "No ship models — ships are drawn as spheres"
	return "%d ship models cached" % models.size()


func _set_status(text: String) -> void:
	if text == status:
		return
	status = text
	status_changed.emit(text)


func _fail(text: String) -> void:
	push_warning(text)
	busy = false
	_set_status(text)


# --- lookups -------------------------------------------------------------------

## A unit-radius instance of the hull `type_id`, centred on the origin, or null if it isn't
## cached or can't be loaded.
func instance_model(type_id: int) -> Node3D:
	if not models.has(type_id):
		return null
	if not _scenes.has(type_id):
		_scenes[type_id] = load_model_scene(_model_path(type_id))
	var scene: PackedScene = _scenes[type_id]
	return scene.instantiate() if scene else null


## Bracket texture for ship group `group_id` (named `group_name`), or null if not downloaded.
func bracket(group_id: int, group_name := "") -> Texture2D:
	return bracket_texture(bracket_name(group_id, group_name))


func bracket_texture(name: String) -> Texture2D:
	if not _textures.has(name):
		_textures[name] = null
		for file in ["%s_32.png" % name, "%s.png" % name, "%s_16.png" % name]:
			var path := _dir.path_join("brackets").path_join(file)
			if FileAccess.file_exists(path):
				var img := Image.load_from_file(path)
				if img:
					_textures[name] = ImageTexture.create_from_image(img)
				break
	return _textures[name]


## Module icon for electronic warfare `type` (an `EWAR_TYPE_IDS` key), or null if it isn't on
## disk yet; a missing icon is downloaded in the background (`ewar_icons_changed` when it lands).
func ewar_texture(type: String) -> Texture2D:
	if not _ewar_textures.has(type):
		_ewar_textures[type] = null
		var path := _ewar_path(type)
		if FileAccess.file_exists(path):
			var img := Image.load_from_file(path)
			if img:
				_ewar_textures[type] = ImageTexture.create_from_image(img)
		elif EWAR_TYPE_IDS.has(type) and fetch_ewar_icons and is_inside_tree():
			_fetch_ewar_icon(type)
	return _ewar_textures[type]


func _ewar_path(type: String) -> String:
	return _dir.path_join("ewar").path_join("%s.png" % type)


## Downloads the image server icon for ewar `type`, once; a failure isn't retried until the next
## start.
func _fetch_ewar_icon(type: String) -> void:
	if _ewar_fetching.has(type):
		return
	_ewar_fetching[type] = true
	DirAccess.make_dir_recursive_absolute(_dir.path_join("ewar"))
	# Keep the Godot editor from importing anything in here.
	FileAccess.open(ShipSizes.data_dir().path_join(".gdignore"), FileAccess.WRITE)
	var path := _ewar_path(type)
	var part := path + ".part"
	var r := await Http.fetch(self, IMAGE_SERVER % EWAR_TYPE_IDS[type], [], part)
	if not r.ok or DirAccess.rename_absolute(part, path) != OK:
		DirAccess.remove_absolute(part)
		push_warning("EWAR icon %s failed (result %d, HTTP %d)" % [type, r.result, r.code])
		return
	_ewar_fetching.erase(type)
	_ewar_textures.erase(type)
	ewar_icons_changed.emit()


static func bracket_name(group_id: int, group_name := "") -> String:
	if GROUP_BRACKETS.has(group_id):
		return GROUP_BRACKETS[group_id]
	var lower := group_name.to_lower()
	for k in BRACKET_KEYWORDS:
		if lower.contains(k[0]):
			return k[1]
	return DEFAULT_BRACKET


# --- model loading ------------------------------------------------------------

## Loads a (Draco-free) GLB and wraps it so it is centred on the origin with a bounding radius
## of 1 (half its longest bounding-box side), ready to be scaled to a hull radius.
static func load_model_scene(path: String) -> PackedScene:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		push_warning("Cannot load model %s: %s" % [path, error_string(err)])
		return null
	var root := doc.generate_scene(state)
	if root == null:
		return null
	var pivot := normalize(root)
	var scene := PackedScene.new()
	err = scene.pack(pivot)
	pivot.free()
	return scene if err == OK else null


## Parents `model` under a new pivot node that centres and scales it to unit radius.
static func normalize(model: Node3D) -> Node3D:
	var box := _mesh_bounds(model, Transform3D.IDENTITY)
	var r := 0.5 * box.get_longest_axis_size()
	if r <= 0.0:
		r = 1.0
	var pivot := Node3D.new()
	pivot.name = "Model"
	pivot.add_child(model)
	model.transform = Transform3D(Basis.from_scale(Vector3.ONE / r), -box.get_center() / r) * model.transform
	_set_owner(model, pivot)
	return pivot


## Bounds of every mesh under `node` (inclusive), in the frame `xform` maps `node` into.
static func _mesh_bounds(node: Node, xform: Transform3D) -> AABB:
	var t: Transform3D = xform * node.transform if node is Node3D else xform
	var box := AABB()
	var first := true
	if node is MeshInstance3D and node.mesh:
		box = t * node.mesh.get_aabb()
		first = false
	for c in node.get_children():
		var b := _mesh_bounds(c, t)
		if b.has_volume():
			box = b if first else box.merge(b)
			first = false
	return box


static func _set_owner(node: Node, owner: Node) -> void:
	node.owner = owner
	for c in node.get_children():
		_set_owner(c, owner)


# --- full download (brackets + index) -----------------------------------------

func full_download() -> void:
	if busy:
		return
	busy = true
	DirAccess.make_dir_recursive_absolute(_dir.path_join("models"))
	# Keep the Godot editor from importing anything in here.
	FileAccess.open(ShipSizes.data_dir().path_join(".gdignore"), FileAccess.WRITE)
	var zip := _dir.path_join("icons.zip")
	_set_status("Downloading icons…")
	var r := await Http.fetch(self, ICONS_URL, [], zip,
		func(got, total): _set_status(ShipSizes.progress_text("icons", got, total)))
	if not r.ok:
		DirAccess.remove_absolute(zip)
		_fail("Icon download failed (result %d, HTTP %d)" % [r.result, r.code])
		return
	_set_status("Extracting overview icons…")
	_thread = Thread.new()
	_thread.start(func(): _finish_brackets.call_deferred(
		extract_brackets(zip, _dir.path_join("brackets"))))


## Copies `Icons/items/Brackets/*` out of the IEC icon zip into `out_dir`, lowercasing names.
## Returns an error message, or "" on success.
static func extract_brackets(zip_path: String, out_dir: String) -> String:
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		return "Cannot open %s" % zip_path
	DirAccess.make_dir_recursive_absolute(out_dir)
	var n := 0
	for file in zip.get_files():
		if not file.begins_with(BRACKETS_PREFIX) or file.get_extension().to_lower() != "png":
			continue
		var dest := out_dir.path_join(file.get_file().to_lower())
		n += 1
		var f := FileAccess.open(dest, FileAccess.WRITE)
		if f == null:
			zip.close()
			return "Cannot write to %s" % dest.get_base_dir()
		f.store_buffer(zip.read_file(file))
	zip.close()
	return "" if n > 0 else "Icon zip has no bracket icons"


func _finish_brackets(error: String) -> void:
	_thread.wait_to_finish()
	_thread = null
	DirAccess.remove_absolute(_dir.path_join("icons.zip"))
	if error != "":
		_fail(error)
		return
	has_brackets = true
	_textures.clear()
	_save_cache()
	busy = false
	await _refresh_index()
	assets_changed.emit()


# --- model index + updates -------------------------------------------------------

## Re-reads the model index if it changed, then re-validates cached models.
func check_update() -> void:
	if busy or not is_loaded():
		return
	_set_status("Checking for ship model updates…")
	if not await _refresh_index():
		return
	busy = true
	var stale := []
	for id in models.keys():
		if not index.has(id):
			continue
		var r := await Http.fetch(self, GALLERY + index[id], ["If-None-Match: %s" % models[id]])
		if r.code == 200:
			stale.append(id)
	busy = false
	for id in stale:
		models.erase(id)
		_scenes.erase(id)
	_save_cache()
	_set_status(_summary())
	for id in stale:
		_wanted[id] = true
	_drain_wanted()


## Fetches the model index unless the cached one is current. Returns false on failure.
func _refresh_index() -> bool:
	busy = true
	var headers := ["If-None-Match: %s" % index_etag] if index_etag and not index.is_empty() else []
	var r := await Http.fetch(self, INDEX_URL, headers)
	busy = false
	if r.code == 304:
		_set_status(_summary())
		_drain_wanted()
		return true
	var parsed = JSON.parse_string(r.body.get_string_from_utf8()) if r.ok else null
	var new_index := parse_index(parsed) if parsed is Array else {}
	if new_index.is_empty():
		_fail("Ship model index download failed (result %d, HTTP %d)" % [r.result, r.code])
		return false
	# Models whose file moved are re-downloaded.
	for id in models.keys():
		if new_index.get(id, "") != index.get(id, ""):
			models.erase(id)
			_scenes.erase(id)
	index = new_index
	index_etag = r.etag
	_save_cache()
	_set_status(_summary())
	_drain_wanted()
	return true


## Type ID -> model path from EVE_Model_Gallery's `resources_index_*.json`
## (categories -> groups -> types, each type with an optional `model_path`).
static func parse_index(categories: Array) -> Dictionary:
	var out := {}
	for c in categories:
		if not c is Dictionary:
			continue
		for g in c.get("groups", []):
			for t in g.get("types", []):
				var path := str(t.get("model_path", ""))
				if path.ends_with(".glb"):
					out[int(t.id)] = path.trim_prefix("./")
	return out


func _drain_wanted() -> void:
	if _wanted.is_empty():
		return
	var ids := _wanted.keys()
	_wanted.clear()
	ensure_models(ids)


# --- per-hull downloads ------------------------------------------------------------

## Downloads (in the background) whichever of `type_ids` have a model but aren't cached yet.
func ensure_models(type_ids: Array) -> void:
	if busy or index.is_empty():
		for id in type_ids:
			_wanted[int(id)] = true
		return
	var queue := []
	for id in type_ids:
		id = int(id)
		if index.has(id) and not models.has(id) and not _fetching.has(id) and not _failed.has(id):
			queue.append(id)
			_fetching[id] = true
	if queue.is_empty():
		return
	var exe := undraco_path()
	if exe == "":
		for id in queue:
			_fetching.erase(id)
		_set_status("glb-undraco not found — build it with `cargo build --release -p glb-undraco`")
		return
	var state := {"running": mini(WORKERS, queue.size()), "done": 0, "total": queue.size()}
	_set_status("Downloading ship models… 0/%d" % state.total)
	for i in state.running:
		_model_worker(queue, state, exe)
	while state.running > 0:
		await get_tree().process_frame
	_save_cache()
	_set_status(_summary())
	assets_changed.emit()


func _model_worker(queue: Array, state: Dictionary, exe: String) -> void:
	while not queue.is_empty():
		var id: int = queue.pop_back()
		var raw := _dir.path_join("models/%d.draco.glb" % id)
		var r := await Http.fetch(self, GALLERY + index[id], [], raw, Callable(), 120.0)
		if r.ok and await _decode(exe, raw, _model_path(id)):
			models[id] = r.etag
			_scenes.erase(id)
		else:
			push_warning("Ship model %d failed (result %d, HTTP %d)" % [id, r.result, r.code])
			_failed[id] = true
		DirAccess.remove_absolute(raw)
		_fetching.erase(id)
		state.done += 1
		_set_status("Downloading ship models… %d/%d" % [state.done, state.total])
	state.running -= 1


## Runs `glb-undraco` on a thread so the frame loop keeps going. True on success.
func _decode(exe: String, src: String, dst: String) -> bool:
	var t := Thread.new()
	t.start(func(): return OS.execute(exe, [src, dst], [], true))
	while t.is_alive():
		await get_tree().process_frame
	return t.wait_to_finish() == 0 and FileAccess.file_exists(dst)


## The `glb-undraco` helper: next to the executable when exported, the cargo build output when
## run from source. "" if it can't be found.
static func undraco_path() -> String:
	var exe := "glb-undraco" + (".exe" if OS.get_name() == "Windows" else "")
	var candidates := []
	if OS.has_feature("editor"):
		var target := ProjectSettings.globalize_path("res://").path_join("../target")
		candidates = [target.path_join("release").path_join(exe), target.path_join("debug").path_join(exe)]
	else:
		candidates = [OS.get_executable_path().get_base_dir().path_join(exe)]
	for c in candidates:
		if FileAccess.file_exists(c):
			return c.simplify_path()
	return ""


# --- cache -------------------------------------------------------------------------

func _model_path(type_id: int) -> String:
	return _dir.path_join("models/%d.glb" % type_id)


func _cache_path() -> String:
	return _dir.path_join("assets.json")


func _load_cache() -> void:
	var f := FileAccess.open(_cache_path(), FileAccess.READ)
	if f == null:
		_set_status(_summary())
		return
	var d = JSON.parse_string(f.get_as_text())
	if not d is Dictionary:
		push_warning("Ignoring unreadable %s" % _cache_path())
		return
	has_brackets = bool(d.get("brackets", false))
	index_etag = str(d.get("index_etag", ""))
	index.clear()
	var idx = d.get("index", {})
	for id in idx:
		index[int(id)] = str(idx[id])
	models.clear()
	var m = d.get("models", {})
	for id in m:
		# Only trust entries whose file is still there.
		if FileAccess.file_exists(_model_path(int(id))):
			models[int(id)] = str(m[id])
	_set_status(_summary())


func _save_cache() -> void:
	DirAccess.make_dir_recursive_absolute(_dir)
	var d := {"brackets": has_brackets, "index_etag": index_etag, "index": index, "models": models}
	var f := FileAccess.open(_cache_path(), FileAccess.WRITE)
	if f == null:
		push_error("Cannot write %s: %s" % [_cache_path(), error_string(FileAccess.get_open_error())])
		return
	f.store_string(JSON.stringify(d, "\t", true))
