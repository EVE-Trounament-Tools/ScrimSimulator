class_name WebLibrary
extends RefCounted
## Web build only: keeps the browser's copy of the match library in step with the site's shared
## library, so `MatchLibrary` and the menu work unchanged on user://matches (kept in the
## browser's IndexedDB).
##
## The site's library is a manifest of library paths -> sha256 of their contents (folders end in
## "/"). Each sync is a three-way merge against `_base`, the manifest the local copy last
## matched: changes on the site are applied locally, local changes (made through `MatchLibrary`)
## are uploaded and committed. A path changed on both sides keeps the local change.
##
## A file the site has but this browser hasn't needed yet is a small placeholder holding its sha
## (`MARKER`), so listing the library downloads nothing. Sidecars and gamelogs are small and read
## synchronously by the app, so they are downloaded right away; a match's CSV and audio only when
## it is opened (`fetch_match`). Renaming or moving a placeholder just moves it, and the site
## sees a known sha at a new path, so nothing is re-uploaded.
##
## The site only lets a match's uploader (or an admin) replace or remove its files. Changes it
## refuses are undone here, a match (its CSV, sidecar, audio and logs, and where it was moved or
## renamed from) at a time, and the reason is shown in the menu.

const STATE_PATH := "user://web_library.json"
const MARKER := "#scrimsim-remote "
## Seconds between checks for other people's changes.
const SYNC_INTERVAL := 20.0
## Seconds after a local change before it is sent (several quick edits make one commit).
const CHANGE_DELAY := 0.5
## Downloaded as soon as they appear on the site (see the class description).
const EAGER_EXTENSIONS := ["json", "txt"]

static var menu: MainMenu
## Library path -> sha the local copy last matched on the site ("" for folders).
static var _base := {}
## Library path -> [size, modified time, sha] of real (not placeholder) local files, so unchanged
## files aren't hashed again every sync.
static var _hashes := {}
static var _syncing := false
static var _again := false
static var _change_timer: Timer
## Set while the menu is refreshed from here, so that refresh isn't taken for a local change.
static var _quiet := false


## Called once by the menu (before its first `refresh`): brings the local copy up to the library
## the page was served with, and starts syncing.
static func attach(m: MainMenu) -> void:
	menu = m
	_load_state()
	var lib: Variant = WebBackend.boot().get("library")
	if lib is Dictionary and lib.get("files") is Array:
		var remote := _manifest_map(lib.files)
		var local := scan_local()
		var local_changes := _diff(_base, local)
		var remote_changes := _diff(_base, remote.shas)
		for p in remote_changes:
			if not local_changes.has(p):
				_apply(p, remote_changes[p], remote.sizes.get(p, 0))
				_set_base(p, remote_changes[p])
		_save_state()
	WebFilePicker.attach(m)
	var interval := Timer.new()
	interval.wait_time = SYNC_INTERVAL
	interval.autostart = true
	interval.timeout.connect(sync)
	m.add_child(interval)
	_change_timer = Timer.new()
	_change_timer.one_shot = true
	_change_timer.wait_time = CHANGE_DELAY
	_change_timer.timeout.connect(sync)
	m.add_child(_change_timer)
	# First sync right away: uploads anything left from last time, fetches sidecars and logs.
	_change_timer.autostart = true


## The menu was refreshed, usually after a change to the library: sync soon.
static func local_changed() -> void:
	if _quiet or _change_timer == null or not _change_timer.is_inside_tree():
		return
	_change_timer.start()


## Downloads whatever of library match `path` (its CSV, sidecar, audio and logs) is still a
## placeholder, showing progress in the menu. False (with the reason shown) if it couldn't.
static func fetch_match(path: String) -> bool:
	if menu == null or not MatchLibrary.contains(path):
		return true
	var files := [path, MatchLibrary.meta_path(path), MatchLibrary.audio_path(path)]
	files.append_array(MatchLibrary.log_paths(path))
	var name := MatchLibrary.display_name(path.get_file())
	for file: String in files:
		if file == "" or not _is_marker(file):
			continue
		var m := _read_marker(file)
		var ok := await _download(m.sha, file, func(got, total):
			menu.show_error(ShipSizes.progress_text(name, got, total if total > 0 else m.size)))
		if not ok:
			menu.show_error("Couldn't download %s — check your connection and try again" % file.get_file())
			return false
	menu.show_error("")
	return true


# --- sync ------------------------------------------------------------------------------

## One sync with the site; a sync asked for while one runs follows it.
static func sync() -> void:
	if menu == null or not menu.is_inside_tree():
		return
	if _syncing:
		_again = true
		return
	_syncing = true
	for attempt in 3:
		# Another commit got in between reading the library and committing: read it again.
		if await _sync_once() != "conflict":
			break
	_syncing = false
	if _again:
		_again = false
		sync()


## Returns "ok", "offline" or "conflict".
static func _sync_once() -> String:
	var r := await WebBackend.request(menu, HTTPClient.METHOD_GET, "/api/library")
	if not r.ok or not r.json is Dictionary:
		return "offline"
	var remote := _manifest_map(r.json.files)
	var local := scan_local()
	var local_changes := _diff(_base, local)
	var remote_changes := _diff(_base, remote.shas)
	var touched := false

	# Site -> here, where not changed here too.
	for p in remote_changes:
		if local_changes.has(p):
			continue
		_apply(p, remote_changes[p], remote.sizes.get(p, 0))
		_set_base(p, remote_changes[p])
		touched = true

	# Here -> site.
	var ops := []
	for p in local_changes:
		var mine: Variant = local_changes[p]
		var theirs: Variant = remote.shas.get(p)
		if mine == theirs:
			_set_base(p, mine)
			continue
		if mine == null:
			ops.append({"op": "delete", "path": p, "prev": theirs})
		else:
			ops.append({"op": "put", "path": p, "sha": mine, "size": _local_size(p), "prev": theirs})
	var result := "ok"
	var refused := []  # reasons shown in the menu
	while not ops.is_empty():
		var c := await _commit(ops)
		if c.status == "ok":
			for op in ops:
				_set_base(op.path, op.get("sha") if op.op == "put" else null)
			break
		if c.status == "conflict" or c.status == "offline":
			result = c.status
			break
		# Refused (not the uploader, or too large to upload): undo the matches involved, send the rest.
		var bad: Dictionary = c.paths
		var keep := []
		for unit in _units(ops):
			if unit.any(func(op): return bad.has(op.path)):
				for op in unit:
					_apply(op.path, remote.shas.get(op.path), remote.sizes.get(op.path, 0))
					_set_base(op.path, remote.shas.get(op.path))
					if bad.has(op.path):
						refused.append("%s: %s" % [MatchLibrary.display_name(op.path.get_file()), bad[op.path]])
				touched = true
			else:
				keep.append_array(unit)
		if keep.size() == ops.size():
			break
		ops = keep
	_save_state()

	for p in scan_local():
		var abs := _abs(p)
		if p.get_extension().to_lower() in EAGER_EXTENSIONS and _is_marker(abs):
			await _download(_read_marker(abs).sha, abs)
	if touched:
		_quiet = true
		menu.refresh()
		_quiet = false
	if not refused.is_empty():
		menu.show_error("Not changed on the site — " + "; ".join(refused))
	return result


## Uploads what `ops` need and commits them. Returns { status: "ok" | "conflict" | "offline" |
## "refused", paths: { path -> reason } for "refused" }.
static func _commit(ops: Array) -> Dictionary:
	var shas := []
	for op in ops:
		if op.op == "put" and op.sha != "":
			shas.append(op.sha)
	if not shas.is_empty():
		var m := await WebBackend.request(menu, HTTPClient.METHOD_POST, "/api/blobs/missing",
			JSON.stringify({"shas": shas}), ["Content-Type: application/json"])
		if not m.ok or not m.json is Dictionary:
			return {"status": "offline"}
		var refused := {}
		for sha in m.json.missing:
			var op: Dictionary = ops[ops.find_custom(func(o): return o.get("sha") == sha)]
			var abs := _abs(op.path)
			if _is_marker(abs):
				# Content the site has lost track of and we never had: nothing to send.
				refused[op.path] = "its file isn't on the site any more"
				continue
			var up := await _upload(sha, abs)
			if up != "":
				refused[op.path] = up
		if not refused.is_empty():
			return {"status": "refused", "paths": refused}
	var r := await WebBackend.request(menu, HTTPClient.METHOD_POST, "/api/library/commit",
		JSON.stringify({"ops": ops}), ["Content-Type: application/json"])
	if r.ok:
		return {"status": "ok"}
	if r.code == 403 and r.json is Dictionary and r.json.get("reasons") is Dictionary:
		return {"status": "refused", "paths": r.json.reasons}
	if r.code == 409 and r.json is Dictionary and r.json.get("status") == "missing":
		return {"status": "conflict"}  # uploaded blob vanished meanwhile: start over
	if r.code == 409:
		return {"status": "conflict"}
	if r.code == 400:
		var why: String = r.json.get("error", "refused") if r.json is Dictionary else "refused"
		var all := {}
		for op in ops:
			all[op.path] = why
		return {"status": "refused", "paths": all}
	return {"status": "offline"}


## Sends local file `abs` as blob `sha`; "" on success, else why not.
static func _upload(sha: String, abs: String) -> String:
	var bytes := FileAccess.get_file_as_bytes(abs)
	if bytes.is_empty() and FileAccess.get_open_error() != OK:
		return "can't read it"
	menu.show_error("Uploading %s (%d MB)…" % [abs.get_file(), bytes.size() >> 20])
	var r := await WebBackend.request(menu, HTTPClient.METHOD_PUT, "/api/blobs/" + sha, bytes,
		["Content-Type: application/octet-stream"], 0.0)
	menu.show_error("")
	if r.ok:
		return ""
	if r.json is Dictionary and r.json.has("error"):
		return str(r.json.error)
	return "upload failed (HTTP %d)" % r.code


## Downloads blob `sha` into `abs`, replacing what is there. `progress(got, total)` as `Http.fetch`.
static func _download(sha: String, abs: String, progress := Callable()) -> bool:
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	var part := abs + ".part"
	var r := await Http.fetch(menu, WebBackend.origin() + "/api/blobs/" + sha, [], part, progress)
	if not r.ok:
		DirAccess.remove_absolute(part)
		push_warning("Download of %s failed (result %d, HTTP %d)" % [abs, r.result, r.code])
		return false
	DirAccess.remove_absolute(abs)
	if DirAccess.rename_absolute(part, abs) != OK:
		return false
	_remember_hash(abs, sha)
	return true


# --- local copy ------------------------------------------------------------------------

## Library path -> sha of everything in the local copy: folders ("a/b/" -> ""), and files with the
## sha of their contents (a placeholder's: the sha it stands for). Logs dirs aren't folders.
static func scan_local() -> Dictionary:
	var out := {}
	_scan(MatchLibrary.dir, "", out)
	return out


static func _scan(abs: String, rel: String, out: Dictionary) -> void:
	if not DirAccess.dir_exists_absolute(abs):
		return
	for d in DirAccess.get_directories_at(abs):
		if not d.to_lower().ends_with(".logs"):
			out[rel + d + "/"] = ""
		_scan(abs.path_join(d), rel + d + "/", out)
	for f in DirAccess.get_files_at(abs):
		if f.ends_with(".part"):
			continue
		out[rel + f] = _local_sha(abs.path_join(f), rel + f)


static func _local_sha(abs: String, rel: String) -> String:
	if _is_marker(abs):
		return _read_marker(abs).sha
	var size := _file_size(abs)
	var mtime := FileAccess.get_modified_time(abs)
	var h: Variant = _hashes.get(rel)
	if h is Array and h[0] == size and h[1] == mtime:
		return h[2]
	var sha := FileAccess.get_sha256(abs)
	_hashes[rel] = [size, mtime, sha]
	return sha


static func _remember_hash(abs: String, sha: String) -> void:
	_hashes[_rel(abs)] = [_file_size(abs), FileAccess.get_modified_time(abs), sha]


static func _file_size(abs: String) -> int:
	var f := FileAccess.open(abs, FileAccess.READ)
	return f.get_length() if f else 0


static func _local_size(p: String) -> int:
	if p.ends_with("/"):
		return 0
	var abs := _abs(p)
	return _read_marker(abs).size if _is_marker(abs) else _file_size(abs)


## Makes library path `p` locally what the site has: `sha` null removes it, a folder is made, a
## file becomes a placeholder for `sha` (`size` bytes).
static func _apply(p: String, sha: Variant, size: int) -> void:
	var abs := _abs(p)
	if sha == null:
		if p.ends_with("/"):
			DirAccess.remove_absolute(abs)  # Only if empty: files still in it keep it.
		else:
			DirAccess.remove_absolute(abs)
			_hashes.erase(p)
			var parent := abs.get_base_dir()
			if parent.get_file().to_lower().ends_with(".logs") and DirAccess.get_files_at(parent).is_empty():
				DirAccess.remove_absolute(parent)
		return
	if p.ends_with("/"):
		DirAccess.make_dir_recursive_absolute(abs)
		return
	if not _is_marker(abs) and FileAccess.file_exists(abs) and _local_sha(abs, p) == sha:
		return
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	var f := FileAccess.open(abs, FileAccess.WRITE)
	if f == null:
		push_error("Cannot write %s: %s" % [abs, error_string(FileAccess.get_open_error())])
		return
	f.store_string("%s%s %d\n" % [MARKER, sha, size])
	_hashes.erase(p)


static func _is_marker(abs: String) -> bool:
	var f := FileAccess.open(abs, FileAccess.READ)
	if f == null or f.get_length() > 128:
		return false
	return f.get_buffer(MARKER.length()).get_string_from_utf8() == MARKER


## { sha, size } of placeholder `abs`.
static func _read_marker(abs: String) -> Dictionary:
	var parts := FileAccess.get_file_as_string(abs).substr(MARKER.length()).strip_edges().split(" ")
	return {"sha": parts[0], "size": parts[1].to_int() if parts.size() > 1 else 0}


static func _abs(p: String) -> String:
	return MatchLibrary.dir.path_join(p.trim_suffix("/"))


static func _rel(abs: String) -> String:
	return abs.substr(MatchLibrary.dir.length() + 1)


# --- manifests ---------------------------------------------------------------------------

## The site's file rows as { shas: path -> sha, sizes: path -> size }.
static func _manifest_map(rows: Array) -> Dictionary:
	var shas := {}
	var sizes := {}
	for row in rows:
		if row is Dictionary and row.has("path"):
			shas[str(row.path)] = str(row.get("sha", ""))
			sizes[str(row.path)] = int(row.get("size", 0))
	return {"shas": shas, "sizes": sizes}


## Paths whose value differs from `from` to `to`: path -> its value in `to` (null if gone).
static func _diff(from: Dictionary, to: Dictionary) -> Dictionary:
	var out := {}
	for p in to:
		if from.get(p) != to[p]:
			out[p] = to[p]
	for p in from:
		if not to.has(p):
			out[p] = null
	return out


static func _set_base(p: String, sha: Variant) -> void:
	if sha == null:
		_base.erase(p)
	else:
		_base[p] = sha


## The match a library path belongs to (its path without extension, logs files included), as
## the site's `matchKey`.
static func match_key(p: String) -> String:
	var segs := p.split("/")
	for i in segs.size() - 1:
		if segs[i].to_lower().ends_with(".logs"):
			var parts := Array(segs.slice(0, i))
			parts.append(segs[i].left(segs[i].length() - ".logs".length()))
			return "/".join(parts)
	var file := segs[segs.size() - 1]
	var dot := file.rfind(".")
	return p.left(p.length() - (file.length() - dot)) if dot > 0 else p


## `ops` grouped into what has to be done or undone together: each match's files, joined with
## the match they were moved or renamed from (a delete and a put of the same sha). Folders alone.
static func _units(ops: Array) -> Array:
	var key_of := func(op: Dictionary) -> String:
		return op.path if op.path.ends_with("/") else match_key(op.path)
	var parent := {}
	var find := func(k: String) -> String:
		while parent.get(k, k) != k:
			k = parent[k]
		return k
	var deleted := {}  # sha -> key
	for op in ops:
		if op.op == "delete" and op.prev != null and op.prev != "":
			deleted[op.prev] = key_of.call(op)
	for op in ops:
		if op.op == "put" and deleted.has(op.sha):
			var a: String = find.call(key_of.call(op))
			var b: String = find.call(deleted[op.sha])
			if a != b:
				parent[a] = b
	var groups := {}
	for op in ops:
		groups.get_or_add(find.call(key_of.call(op)), []).append(op)
	return groups.values()


# --- state -------------------------------------------------------------------------------

static func _load_state() -> void:
	if not FileAccess.file_exists(STATE_PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(STATE_PATH))
	if parsed is Dictionary:
		_base = parsed.get("base", {})
		_hashes = parsed.get("hashes", {})
		for p in _hashes:
			_hashes[p] = [int(_hashes[p][0]), int(_hashes[p][1]), str(_hashes[p][2])]


static func _save_state() -> void:
	var f := FileAccess.open(STATE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("Cannot save %s: %s" % [STATE_PATH, error_string(FileAccess.get_open_error())])
		return
	f.store_string(JSON.stringify({"base": _base, "hashes": _hashes}))
