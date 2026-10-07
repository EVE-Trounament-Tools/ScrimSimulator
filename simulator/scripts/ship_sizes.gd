class_name ShipSizes
extends Node
## Ship hull radii from CCP's Static Data Export (SDE).
##
## The full SDE (~100 MB zip) is downloaded once, with the user's consent, and boiled down to
## `sde/ship_sizes.json` (ship name -> radius in metres). Later SDE builds are applied
## incrementally: the per-build change lists name the type IDs that were added or changed, and
## each one is looked up on ESI, so new ships appear without re-downloading the whole export.
## `sde/` is git-ignored.

signal sizes_changed
signal status_changed(text: String)
## The cache is missing or can't be updated incrementally; `reason` is shown to the user.
signal needs_download(reason: String)

const SDE_BASE := "https://developers.eveonline.com/static-data"
const LATEST_URL := SDE_BASE + "/tranquility/latest.jsonl"
const ZIP_URL := SDE_BASE + "/eve-online-static-data-latest-jsonl.zip"
const CHANGES_URL := SDE_BASE + "/tranquility/changes/%d.jsonl"
const ESI_TYPE_URL := "https://esi.evetech.net/latest/universe/types/%d/"
const ESI_GROUP_URL := "https://esi.evetech.net/latest/universe/groups/%d/"

const SHIP_CATEGORY := 6
## Further back than this many builds, re-download the full SDE instead of walking changes.
const MAX_CHANGE_STEPS := 60
const ESI_WORKERS := 8

## SDE build the cache reflects (0 = no cache).
var build := 0
var release_date := ""
var ship_groups := {}  # group id -> group name ("" if unknown)
var ships := {}  # lowercase ship name -> { name, type_id, group_id, radius_m }
var busy := false
var status := ""

var _dir := ""
var _thread: Thread


func _ready() -> void:
	_dir = data_dir()
	_load_cache()


## `sde/` next to the project when run from source, next to the executable when exported.
static func data_dir() -> String:
	if OS.has_feature("web"):
		return "user://sde"
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://sde")
	return OS.get_executable_path().get_base_dir().path_join("sde")


## Status text for a download of `what` that has `got` of `total` bytes (-1 = unknown).
static func progress_text(what: String, got: int, total: int) -> String:
	if total > 0:
		return "Downloading %s… %d / %d MB" % [what, got >> 20, total >> 20]
	return "Downloading %s… %d MB" % [what, got >> 20]


func _exit_tree() -> void:
	if _thread != null:
		_thread.wait_to_finish()


func is_loaded() -> bool:
	return build > 0


## Lowercase ship name -> hull radius in metres.
func radii() -> Dictionary:
	var out := {}
	for key in ships:
		out[key] = ships[key].radius_m
	return out


## Published hull radius of `ship_type` in metres, or 0.0 if unknown.
func radius_m(ship_type: String) -> float:
	var s: Dictionary = ships.get(ship_type.to_lower(), {})
	return s.get("radius_m", 0.0)


## SDE record { name, type_id, group_id, radius_m } of `ship_type`, or {} if unknown.
func ship(ship_type: String) -> Dictionary:
	return ships.get(ship_type.to_lower(), {})


## Startup entry point: load what's cached, then prompt for or check for updates.
func start(auto_update: bool) -> void:
	if OS.has_feature("web"):
		WebAssets.start_sizes(self)
		return
	if not is_loaded():
		needs_download.emit("Ship sizes come from EVE's Static Data Export, which isn't downloaded yet.")
	elif auto_update:
		check_update()
	else:
		_set_status(_summary())


func _summary() -> String:
	if not is_loaded():
		return "No SDE data — ships use a default size"
	return "SDE build %d (%s), %d ships" % [build, release_date.left(10), ships.size()]


func _set_status(text: String) -> void:
	if text == status:
		return
	status = text
	status_changed.emit(text)


# --- full download -------------------------------------------------------------

func full_download() -> void:
	if OS.has_feature("web"):
		WebAssets.start_sizes(self)
		return
	if busy:
		return
	busy = true
	DirAccess.make_dir_recursive_absolute(_dir)
	# Keep the Godot editor from importing anything in here.
	FileAccess.open(_dir.path_join(".gdignore"), FileAccess.WRITE)
	_set_status("Downloading SDE…")
	var r := await Http.fetch(self, ZIP_URL, [], _dir.path_join("sde.zip"),
		func(got, total): _set_status(progress_text("SDE", got, total)))
	if not r.ok:
		_fail("SDE download failed (result %d, HTTP %d)" % [r.result, r.code])
		DirAccess.remove_absolute(_dir.path_join("sde.zip"))
		return
	_set_status("Extracting ship sizes…")
	_thread = Thread.new()
	_thread.start(_parse_zip.bind(_dir.path_join("sde.zip")))


## Runs on `_thread`: pulls ship groups and ship types out of the SDE zip.
func _parse_zip(path: String) -> void:
	_finish_parse.call_deferred(_extract_ships(path))


## Returns { error, groups, ships, build, release_date } read from the SDE zip at `path`.
static func _extract_ships(path: String) -> Dictionary:
	var out := {"error": ""}
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		out.error = "Cannot open %s" % path
		return out

	var meta := _parse_jsonl(zip.read_file("_sde.jsonl").get_string_from_utf8())
	var groups := {}
	for g in _parse_jsonl(zip.read_file("groups.jsonl").get_string_from_utf8()):
		if int(g.get("categoryID", -1)) == SHIP_CATEGORY:
			groups[int(g._key)] = _en(g.get("name", ""))

	# types.jsonl is ~150 MB of mostly non-ships: split on newlines in the raw bytes and only
	# JSON-parse the lines whose groupID is a ship group.
	var bytes := zip.read_file("types.jsonl")
	zip.close()
	var found := {}
	var start := 0
	while start < bytes.size():
		var end := bytes.find(10, start)
		if end < 0:
			end = bytes.size()
		var line := bytes.slice(start, end).get_string_from_utf8()
		start = end + 1
		var i := line.find("\"groupID\":")
		if i < 0:
			continue
		var gid := line.substr(i + 10, 16).get_slice(",", 0).get_slice("}", 0).strip_edges().to_int()
		if not groups.has(gid):
			continue
		var t = JSON.parse_string(line)
		if t is Dictionary and t.get("published", false):
			var name := _en(t.name)
			found[name.to_lower()] = {
				"name": name, "type_id": int(t._key), "group_id": gid, "radius_m": float(t.get("radius", 0.0)),
			}

	out.groups = groups
	out.ships = found
	out.build = 0
	out.release_date = ""
	for m in meta:
		if m.get("_key") == "sde":
			out.build = int(m.buildNumber)
			out.release_date = str(m.get("releaseDate", ""))
	if found.is_empty() or out.build == 0:
		out.error = "SDE zip has no ship types"
	return out


func _finish_parse(out: Dictionary) -> void:
	_thread.wait_to_finish()
	_thread = null
	DirAccess.remove_absolute(_dir.path_join("sde.zip"))
	if out.error != "":
		_fail(out.error)
		return
	build = out.build
	release_date = out.release_date
	ship_groups = out.groups
	ships = out.ships
	_save_cache()
	busy = false
	print("SDE: %s" % _summary())
	_set_status(_summary())
	sizes_changed.emit()


# --- incremental update ------------------------------------------------------

## Brings the cache up to the latest SDE build using the per-build change lists and ESI.
func check_update() -> void:
	if OS.has_feature("web"):
		WebAssets.start_sizes(self)
		return
	if busy or not is_loaded():
		return
	busy = true
	_set_status("Checking for SDE updates…")
	var latest := await _get_jsonl(LATEST_URL)
	var latest_build := 0
	var latest_date := ""
	for rec in latest:
		if rec.get("_key") == "sde":
			latest_build = int(rec.buildNumber)
			latest_date = str(rec.get("releaseDate", ""))
	if latest_build == 0:
		_fail("SDE update check failed — using cached build %d" % build)
		return
	if latest_build <= build:
		busy = false
		_set_status(_summary())
		return

	# Walk the change lists back from the newest build to ours.
	var added_types := {}
	var changed_types := {}
	var added_groups := {}
	var b := latest_build
	var steps := 0
	while b > build:
		if steps >= MAX_CHANGE_STEPS:
			busy = false
			_set_status(_summary())
			needs_download.emit("The cached SDE (build %d) is too far behind to update incrementally." % build)
			return
		_set_status("Reading SDE changes for build %d…" % b)
		var recs := await _get_jsonl(CHANGES_URL % b)
		var prev := 0
		for rec in recs:
			match rec.get("_key"):
				"_meta":
					prev = int(rec.get("lastBuildNumber", 0))
				"types":
					for id in rec.get("added", []):
						added_types[int(id)] = true
					for id in rec.get("changed", []):
						changed_types[int(id)] = true
				"groups":
					for id in rec.get("added", []):
						added_groups[int(id)] = true
		if prev == 0 or prev >= b:
			_fail("SDE change list for build %d unavailable — using cached build %d" % [b, build])
			return
		b = prev
		steps += 1

	var ok := true
	for gid in added_groups:
		var g := await _get_json(ESI_GROUP_URL % gid)
		if g.is_empty():
			ok = false
		elif int(g.get("category_id", -1)) == SHIP_CATEGORY:
			ship_groups[gid] = str(g.get("name", ""))

	# New types might be ships; changed types only matter if they already are.
	var known := {}
	for key in ships:
		known[ships[key].type_id] = key
	var queue: Array = added_types.keys()
	for id in changed_types:
		if known.has(id) and not added_types.has(id):
			queue.append(id)
	var results := {}  # type id -> ESI dict ({} on failure)
	_set_status("Looking up %d changed types on ESI…" % queue.size())
	await _esi_types(queue, results)

	var updated := 0
	for id in results:
		var t: Dictionary = results[id]
		if t.is_empty():
			ok = false
			continue
		if known.has(id):
			ships.erase(known[id])  # Renamed or no longer a ship.
		var gid := int(t.get("group_id", -1))
		if ship_groups.has(gid) and t.get("published", false):
			var name := str(t.name)
			ships[name.to_lower()] = {
				"name": name, "type_id": id, "group_id": gid, "radius_m": float(t.get("radius", 0.0)),
			}
			updated += 1
	# Only advance the build when every lookup succeeded, so failures are retried next start.
	if ok:
		build = latest_build
		release_date = latest_date
	_save_cache()
	busy = false
	print("SDE: %d ship types added/updated; %s" % [updated, _summary()])
	_set_status(_summary() if ok else "Some SDE updates failed — will retry next start")
	if updated > 0:
		sizes_changed.emit()


## Fetches ESI type info for every id in `queue` with a few concurrent requests.
func _esi_types(queue: Array, results: Dictionary) -> void:
	var workers := mini(ESI_WORKERS, queue.size())
	if workers == 0:
		return
	var state := {"running": workers}
	for i in workers:
		_esi_worker(queue, results, state)
	while state.running > 0:
		await get_tree().process_frame


func _esi_worker(queue: Array, results: Dictionary, state: Dictionary) -> void:
	while not queue.is_empty():
		var id: int = queue.pop_back()
		results[id] = await _get_json(ESI_TYPE_URL % id)
	state.running -= 1


func _fail(text: String) -> void:
	push_warning(text)
	busy = false
	_set_status(text)


# --- HTTP / files --------------------------------------------------------------

## GETs `url`; returns the body, or an empty array on any failure.
func _get_bytes(url: String) -> PackedByteArray:
	var r := await Http.fetch(self, url)
	if not r.ok:
		push_warning("GET %s failed (result %d, HTTP %d)" % [url, r.result, r.code])
		return PackedByteArray()
	return r.body


func _get_json(url: String) -> Dictionary:
	var v = JSON.parse_string((await _get_bytes(url)).get_string_from_utf8())
	return v if v is Dictionary else {}


func _get_jsonl(url: String) -> Array:
	return _parse_jsonl((await _get_bytes(url)).get_string_from_utf8())


## English text of an SDE name field (`{"en": ..., "de": ...}` or a plain string).
static func _en(v: Variant) -> String:
	return str(v.get("en", "")) if v is Dictionary else str(v)


static func _parse_jsonl(text: String) -> Array:
	var out := []
	for line in text.split("\n", false):
		var v = JSON.parse_string(line)
		if v is Dictionary:
			out.append(v)
	return out


func _cache_path() -> String:
	return _dir.path_join("ship_sizes.json")


func _load_cache() -> void:
	var f := FileAccess.open(_cache_path(), FileAccess.READ)
	if f == null:
		_set_status(_summary())
		return
	var d = JSON.parse_string(f.get_as_text())
	if not (d is Dictionary and d.has("ships")):
		push_warning("Ignoring unreadable %s" % _cache_path())
		return
	build = int(d.get("build", 0))
	release_date = str(d.get("release_date", ""))
	ship_groups.clear()
	var groups = d.get("ship_groups", {})
	if groups is Array:  # Caches before group names were kept.
		for g in groups:
			ship_groups[int(g)] = ""
	else:
		for g in groups:
			ship_groups[int(g)] = str(groups[g])
	ships.clear()
	for name in d.ships:
		var s: Dictionary = d.ships[name]
		ships[name.to_lower()] = {
			"name": name, "type_id": int(s.type_id), "group_id": int(s.group_id),
			"radius_m": float(s.radius_m),
		}
	_set_status(_summary())


func _save_cache() -> void:
	DirAccess.make_dir_recursive_absolute(_dir)
	var out := {}
	for key in ships:
		var s: Dictionary = ships[key]
		out[s.name] = {"type_id": s.type_id, "group_id": s.group_id, "radius_m": s.radius_m}
	var d := {
		"build": build, "release_date": release_date,
		"ship_groups": ship_groups, "ships": out,
	}
	var f := FileAccess.open(_cache_path(), FileAccess.WRITE)
	if f == null:
		push_error("Cannot write %s: %s" % [_cache_path(), error_string(FileAccess.get_open_error())])
		return
	f.store_string(JSON.stringify(d, "\t", true))
