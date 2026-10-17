class_name DataCheck
extends RefCounted
## What each library match is missing (`MatchData.data_issues`) and which of its pilots are on no
## team when it is opened (`unassigned`), for the `MainMenu`'s warning badges. Loading every CSV
## each time the menu refreshes would be slow, so results are cached in `cache_path` (next to the
## library, not in it, so the web build never syncs it), keyed by match path: issues are kept
## while the CSV's modified time and size are unchanged, unassigned pilots also while its sidecar
## and season db (`teams_key`) are.

## Cache entries: path -> { modified, size, issues, teams_key, unassigned }. Loaded from
## `cache_path` on first use.
static var _cache: Variant = null
## `MatchLibrary.dir` the cache was loaded for (tests swap libraries).
static var _cache_dir := ""


## The cache file: beside `MatchLibrary.dir`.
static func cache_path() -> String:
	return MatchLibrary.dir.get_base_dir().path_join("data-check-cache.json")


## What library match `path` is missing (see `MatchData.data_issues`), [] when nothing is or its
## CSV can't be loaded (such as a web placeholder whose CSV isn't fetched yet; not cached).
static func issues(path: String) -> Array:
	return _entry(path).get("issues", [])


## The pilots of library match `path` (sorted) left on no team (`MatchData.Team.UNKNOWN`) once
## opening it has put them on their sides (`TeamDb.settle`), [] when there are none or its CSV
## can't be loaded.
static func unassigned(path: String) -> Array:
	return _entry(path).get("unassigned", [])


## Drops the entries of matches no longer in the library (`paths`), saving if any went.
static func prune(paths: Array) -> void:
	_load_cache()
	var keep := {}
	for p in paths:
		keep[p] = true
	var gone: Array = _cache.keys().filter(func(p): return not keep.has(p))
	if gone.is_empty():
		return
	for p in gone:
		_cache.erase(p)
	_save_cache()


## What decides `path`'s teams besides its CSV: its sidecar and the season db it is opened with.
static func teams_key(path: String) -> String:
	var db := _md5(TeamDb.db_path(TeamDb.season_of(path))) if TeamDb.uses_db(path) else "off"
	return "%s %s" % [_md5(MatchLibrary.meta_path(path)), db]


## `path`'s cache entry, brought up to date; {} if its CSV can't be loaded.
static func _entry(path: String) -> Dictionary:
	_load_cache()
	var modified := FileAccess.get_modified_time(path)
	var size := _size(path)
	var key := teams_key(path)
	var entry: Variant = _cache.get(path)
	var fresh: bool = entry is Dictionary and int(entry.get("modified", -1)) == modified \
		and int(entry.get("size", -1)) == size and entry.has("issues")
	if fresh and entry.get("teams_key") == key and entry.has("unassigned"):
		return entry
	var data := MatchData.load_csv(path, {}, 0.0, true)
	if data == null:
		return {}
	if not fresh:
		entry = {"modified": modified, "size": size, "issues": data.data_issues()}
	TeamDb.settle(data, TeamDb.db_for(path), MatchLibrary.load_meta(path).get("teams", {}))
	var pilots: Array = data.teams.keys().filter(func(p): return data.teams[p] == MatchData.Team.UNKNOWN)
	pilots.sort()
	entry.teams_key = key
	entry.unassigned = pilots
	_cache[path] = entry
	_save_cache()
	return entry


static func _load_cache() -> void:
	if _cache != null and _cache_dir == MatchLibrary.dir:
		return
	_cache_dir = MatchLibrary.dir
	_cache = {}
	var file := cache_path()
	if not FileAccess.file_exists(file):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(file))
	if parsed is Dictionary:
		_cache = parsed


static func _save_cache() -> void:
	var f := FileAccess.open(cache_path(), FileAccess.WRITE)
	if f == null:
		push_error("Cannot save %s: %s" % [cache_path(), error_string(FileAccess.get_open_error())])
		return
	f.store_string(JSON.stringify(_cache))


## MD5 of file `path`, "" when there is none.
static func _md5(path: String) -> String:
	return FileAccess.get_md5(path) if FileAccess.file_exists(path) else ""


static func _size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f else -1
