class_name MatchLibrary
extends RefCounted
## Matches added through the main menu: copies of their CSVs in `user://matches/`, so they keep
## working if the original file moves. Each may have a JSON sidecar (`meta_path`) holding edits
## made while viewing it (team swaps, team names), an audio file (`audio_path`) that starts
## with the CSV's first sample, and EVE gamelogs (`logs_dir`) of pilots in the match (see
## `CombatLog`). Matches can be sorted into folders: real subdirectories of `dir`, nested to any
## depth, named by their path relative to `dir` ("" is the library itself, "Season 3/vs X" a
## folder in a folder). A match's logs dir (`*.logs`) is never a folder.

## Overridable so tests never touch the real library.
static var dir := "user://matches"
## Where the release bundle keeps the demo library (`demo/` next to the executable, see
## `demo_source`). Overridable so tests never touch the real one.
static var demo_dir := ""
## Audio formats Godot can load at runtime.
const AUDIO_EXTENSIONS := ["ogg", "mp3", "wav"]


## `[{ path, name, modified, audio, folder }]` for every CSV in the library: the library's own
## first, then each of `folders()` in turn, in natural name order within each (`_2` before `_10`); `name` drops the
## `.positions.csv` / `.csv` extension, `modified` is a Unix time, `audio` whether the match has
## an audio file and `folder` the folder it is in.
static func list() -> Array:
	var out := []
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for folder in [""] + folders():
		var here := []
		var d := folder_abs(folder)
		for file in DirAccess.get_files_at(d):
			if file.get_extension().to_lower() != "csv":
				continue
			var path := d.path_join(file)
			here.append({
				"path": path, "name": display_name(file), "modified": FileAccess.get_modified_time(path),
				"audio": audio_path(path) != "", "folder": folder,
			})
		here.sort_custom(func(a, b): return a.name.naturalnocasecmp_to(b.name) < 0)
		out.append_array(here)
	return out


## Every folder inside folder `parent` (all of them for ""), at any depth, as paths relative to
## `dir`: sorted by name, each followed by its own subfolders.
static func folders(parent := "") -> Array:
	var out := []
	var d := folder_abs(parent)
	if not DirAccess.dir_exists_absolute(d):
		return out
	var names := Array(DirAccess.get_directories_at(d)).filter(func(n): return not _is_logs_dir(n))
	names.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	for n in names:
		out.append(parent.path_join(n))
		out.append_array(folders(parent.path_join(n)))
	return out


## Folder `rel`'s directory: "" -> `dir`, "a/b" -> "<dir>/a/b".
static func folder_abs(rel: String) -> String:
	return dir if rel == "" else dir.path_join(rel)


## The folder library match `path` is in ("" for the library itself).
static func folder_of(path: String) -> String:
	var base := path.get_base_dir().simplify_path()
	var root := dir.simplify_path()
	return "" if base == root else base.substr(root.length() + 1)


## Paths of the matches in folder `rel` and all its subfolders.
static func matches_in(rel: String) -> Array:
	return list().filter(func(e): return e.folder == rel or e.folder.begins_with(rel + "/")).map(
		func(e): return e.path)


## Whether directory name `name` is a match's logs dir (and so not a folder).
static func _is_logs_dir(name: String) -> bool:
	return name.to_lower().ends_with(".logs")


## `name` cleaned up for use as a folder name, or "" if it can't be one (empty, "." / "..", or
## ending in ".logs").
static func folder_name(name: String) -> String:
	name = name.strip_edges().validate_filename()
	if name.is_empty() or name == "." or name == ".." or _is_logs_dir(name):
		return ""
	return name


## Whether folder `parent` already has a subfolder named `name`, ignoring case (`except` aside).
static func _folder_taken(parent: String, name: String, except := "") -> bool:
	for rel in folders(parent):
		if rel.get_base_dir() == parent and rel != except and rel.get_file().to_lower() == name.to_lower():
			return true
	return false


## Creates folder `name` inside folder `parent` and returns its path, or "" if the name can't be
## used (see `folder_name`) or is taken.
static func create_folder(parent: String, name: String) -> String:
	name = folder_name(name)
	if name.is_empty() or _folder_taken(parent, name):
		return ""
	var rel := parent.path_join(name)
	var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder_abs(rel)))
	if err != OK:
		push_error("Cannot create %s: %s" % [folder_abs(rel), error_string(err)])
		return ""
	return rel


## Renames folder `rel` to `new_name` and returns its new path, or "" if the name can't be used
## or another folder next to it has it.
static func rename_folder(rel: String, new_name: String) -> String:
	new_name = folder_name(new_name)
	if rel == "" or new_name.is_empty() or _folder_taken(rel.get_base_dir(), new_name, rel):
		return ""
	var dest := rel.get_base_dir().path_join(new_name)
	if dest == rel:
		return rel
	return dest if _rename_dir(folder_abs(rel), folder_abs(dest)) else ""


## Moves folder `rel` (with everything in it) into folder `parent` and returns its new path; a
## folder there with the same name gets it a " (2)", " (3)", … suffix. "" if `parent` is `rel`
## itself or inside it.
static func move_folder(rel: String, parent: String) -> String:
	if rel == "" or parent == rel or parent.begins_with(rel + "/"):
		return ""
	if rel.get_base_dir() == parent:
		return rel
	if not DirAccess.dir_exists_absolute(folder_abs(parent)):
		push_error("Cannot move %s: no folder %s" % [rel, parent])
		return ""
	var name := rel.get_file()
	var n := 1
	while _folder_taken(parent, name if n == 1 else "%s (%d)" % [name, n]):
		n += 1
	var dest := parent.path_join(name if n == 1 else "%s (%d)" % [name, n])
	return dest if _rename_dir(folder_abs(rel), folder_abs(dest)) else ""


static func _rename_dir(from: String, to: String) -> bool:
	var err := DirAccess.rename_absolute(ProjectSettings.globalize_path(from), ProjectSettings.globalize_path(to))
	if err != OK:
		push_error("Cannot move %s to %s: %s" % [from, to, error_string(err)])
	return err == OK


## Deletes folder `rel` and everything in it: its matches (with their sidecars, audio and logs)
## and subfolders.
static func remove_folder(rel: String) -> void:
	if rel == "":
		return
	_remove_tree(folder_abs(rel))


static func _remove_tree(d: String) -> void:
	for sub in DirAccess.get_directories_at(d):
		_remove_tree(d.path_join(sub))
	for file in DirAccess.get_files_at(d):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(d.path_join(file)))
	var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(d))
	if err != OK:
		push_error("Cannot remove %s: %s" % [d, error_string(err)])


## "match_03.positions.csv" -> "match_03".
static func display_name(file: String) -> String:
	for ext in [".positions.csv", ".csv"]:
		if file.to_lower().ends_with(ext):
			return file.left(file.length() - ext.length())
	return file


## The demo library shipped with the release (`demo_dir`, else `demo/` next to the
## executable): a copy of a library, its matches in the same layout as in `dir` (folders,
## sidecars, audio, logs). "" if there is none or it holds no CSV. Never found when run from
## source.
static func demo_source() -> String:
	var d := demo_dir
	if d == "":
		if OS.has_feature("editor"):
			return ""
		d = OS.get_executable_path().get_base_dir().path_join("demo")
	if not DirAccess.dir_exists_absolute(d):
		return ""
	for folder in [""] + _subdirs(d):
		for file in DirAccess.get_files_at(d.path_join(folder)):
			if file.get_extension().to_lower() == "csv":
				return d
	return ""


## Every directory inside `d`, at any depth, as paths relative to it.
static func _subdirs(d: String) -> Array:
	var out := []
	for n in DirAccess.get_directories_at(d):
		out.append(n)
		for sub in _subdirs(d.path_join(n)):
			out.append(n.path_join(sub))
	return out


## Copies the demo library (`demo_source`) into the library the first time it is found, keeping
## any file already there; once added, it is never added again, so removing it sticks.
static func add_demo() -> void:
	if Settings.get_value("library/demo_added"):
		return
	var src := demo_source()
	if src == "" or not _copy_tree(src, dir):
		return
	Settings.set_value("library/demo_added", true)


## Copies everything in directory `src` into `dest` (made if missing), skipping files `dest`
## already has. False if anything couldn't be copied.
static func _copy_tree(src: String, dest: String) -> bool:
	var ok := true
	for folder in [""] + _subdirs(src):
		var to_dir := dest.path_join(folder)
		var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(to_dir))
		if err != OK:
			push_error("Cannot create %s: %s" % [to_dir, error_string(err)])
			ok = false
			continue
		for file in DirAccess.get_files_at(src.path_join(folder)):
			var to := to_dir.path_join(file)
			if FileAccess.file_exists(to):
				continue
			err = DirAccess.copy_absolute(src.path_join(folder).path_join(file), ProjectSettings.globalize_path(to))
			if err != OK:
				push_error("Cannot copy %s to %s: %s" % [file, to_dir, error_string(err)])
				ok = false
	return ok


## Copies `src` into library folder `folder` (made if missing) and returns the copy's path (""
## on failure). A file already there with the same name and contents is reused; a different file
## with the same name gets a " (2)", " (3)", … suffix. Gamelogs in the CSV's own `logs_dir` come
## along.
static func add(src: String, folder := "") -> String:
	if not FileAccess.file_exists(src):
		push_error("Cannot add %s: no such file" % src)
		return ""
	var to_dir := folder_abs(folder)
	var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(to_dir))
	if err != OK:
		push_error("Cannot create %s: %s" % [to_dir, error_string(err)])
		return ""
	var file := src.get_file()
	var stem := display_name(file)
	var dest := _copy_unique(src, to_dir, stem, file.substr(stem.length()))
	var gamelogs := log_paths(src)
	if dest != "" and not gamelogs.is_empty():
		var data := MatchData.load_csv(dest, {}, 0.0, true)
		for gamelog in gamelogs:
			add_log(dest, gamelog, data)
	return dest


## Copies `src` into `to_dir` as `<stem><ext>`, reusing an identical file there and otherwise
## adding a " (2)", " (3)", … suffix; the copy's path, or "" on failure.
static func _copy_unique(src: String, to_dir: String, stem: String, ext: String) -> String:
	var src_hash := FileAccess.get_sha256(src)
	var n := 1
	while true:
		var dest := _numbered(to_dir, stem, ext, n)
		if not FileAccess.file_exists(dest):
			var err := DirAccess.copy_absolute(ProjectSettings.globalize_path(src), ProjectSettings.globalize_path(dest))
			if err != OK:
				push_error("Cannot copy %s to %s: %s" % [src, dest, error_string(err)])
				return ""
			return dest
		if FileAccess.get_sha256(dest) == src_hash:
			return dest
		n += 1
	return ""


## "<to_dir>/<stem><ext>" for `n` 1, else "<to_dir>/<stem> (<n>)<ext>".
static func _numbered(to_dir: String, stem: String, ext: String, n: int) -> String:
	return to_dir.path_join(stem + ext if n == 1 else "%s (%d)%s" % [stem, n, ext])


## Copies every match in directory `src_dir` (a scrim's `*.csv`s, with their `logs_dir`s) into
## library folder `parent`/<`src_dir`'s name>, which is made if missing (and otherwise added to,
## so importing a folder again changes nothing). The directory's audio files become the audio
## of the matches they pair with (`pair_audio`), and each loose gamelog (`*.txt`) is added to
## every match it has combat during (`add_log`). Returns `{ folder, matches, failed,
## unpaired_audio }`: the folder, the added matches' paths, and the file names of CSVs that
## couldn't be added and audio that paired with none; `folder` is "" if nothing was added.
static func add_folder(src_dir: String, parent := "") -> Dictionary:
	var out := {"folder": "", "matches": [], "failed": [], "unpaired_audio": []}
	if not DirAccess.dir_exists_absolute(src_dir):
		push_error("Cannot add %s: no such folder" % src_dir)
		return out
	var csvs := []
	var audio := []
	var gamelogs := []
	for file in DirAccess.get_files_at(src_dir):
		var ext := file.get_extension().to_lower()
		if ext == "csv":
			csvs.append(src_dir.path_join(file))
		elif AUDIO_EXTENSIONS.has(ext):
			audio.append(src_dir.path_join(file))
		elif ext == "txt":
			gamelogs.append(src_dir.path_join(file))
	if csvs.is_empty():
		push_error("Cannot add %s: no match CSVs in it" % src_dir)
		return out
	var name := folder_name(src_dir.simplify_path().get_file())
	var folder := parent.path_join(name if name != "" else "Scrim")
	var added := {}
	for csv in csvs:
		var dest := add(csv, folder)
		if dest == "":
			out.failed.append(csv.get_file())
		else:
			added[csv] = dest
			out.matches.append(dest)
	if added.is_empty():
		return out
	out.folder = folder
	var pairs := pair_audio(added.keys(), audio)
	for csv in pairs:
		set_audio(added[csv], pairs[csv])
	out.unpaired_audio = audio.filter(func(a): return not pairs.values().has(a)).map(func(a): return a.get_file())
	for path in out.matches:
		var data := MatchData.load_csv(path, {}, 0.0, true) if not gamelogs.is_empty() else null
		if data == null or not data.has_eve_time():
			continue
		for gamelog in gamelogs:
			add_log(path, gamelog, data)
	return out


## Pairs match CSVs `csvs` with audio files `audio` by name: `{ csv -> audio }`. A CSV pairs with
## the audio file of the same name (ignoring case and extensions: "match_03.positions.csv" with
## "Match_03.mp3"); a CSV left over then pairs with the leftover audio whose name ends in the same
## number ("clip_001" with "match_1"), if that number picks out just one of each.
static func pair_audio(csvs: Array, audio: Array) -> Dictionary:
	var pairs := {}
	var left := audio.duplicate()
	for csv in csvs:
		var name := display_name(csv.get_file()).to_lower()
		for a in left:
			if a.get_file().get_basename().to_lower() == name:
				pairs[csv] = a
				left.erase(a)
				break
	var csv_by_n := {}
	for csv in csvs:
		if not pairs.has(csv):
			csv_by_n.get_or_add(_trailing_number(display_name(csv.get_file())), []).append(csv)
	var audio_by_n := {}
	for a in left:
		audio_by_n.get_or_add(_trailing_number(a.get_file().get_basename()), []).append(a)
	for n in csv_by_n:
		if n >= 0 and csv_by_n[n].size() == 1 and audio_by_n.get(n, []).size() == 1:
			pairs[csv_by_n[n][0]] = audio_by_n[n][0]
	return pairs


## The number `name` ends in ("match_003" -> 3), or -1.
static func _trailing_number(name: String) -> int:
	var m := RegEx.create_from_string("(\\d+)$").search(name)
	return m.get_string(1).to_int() if m else -1


## Moves library match `path` (with its sidecar, audio and logs) into folder `folder` and returns
## its new path; a match there with the same file name gets it a " (2)", " (3)", … suffix. ""
## on failure.
static func move(path: String, folder: String) -> String:
	var to_dir := folder_abs(folder)
	if not DirAccess.dir_exists_absolute(to_dir):
		push_error("Cannot move %s: no folder %s" % [path, folder])
		return ""
	if to_dir.simplify_path() == path.get_base_dir().simplify_path():
		return path
	var file := path.get_file()
	var stem := display_name(file)
	var n := 1
	while FileAccess.file_exists(_numbered(to_dir, stem, file.substr(stem.length()), n)):
		n += 1
	var dest := _numbered(to_dir, stem, file.substr(stem.length()), n)
	return dest if _move_match(path, dest) else ""


## Moves match `path`'s CSV to `dest`, and its sidecar, audio and logs along with it.
static func _move_match(path: String, dest: String) -> bool:
	var companions := _companions(path)
	var err := DirAccess.rename_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(dest))
	if err != OK:
		push_error("Cannot move %s to %s: %s" % [path, dest, error_string(err)])
		return false
	for companion: String in companions:
		var to: String = dest.get_basename() + "." + companion.get_extension()
		err = DirAccess.rename_absolute(ProjectSettings.globalize_path(companion), ProjectSettings.globalize_path(to))
		if err != OK:
			push_error("Cannot move %s: %s" % [companion, error_string(err)])
	return true


## Renames library match `path` to display name `new_name` (its extension is kept) and returns
## the new path, or "" if the name is empty or another match in its folder already shows it.
## The sidecar, audio and logs move with it.
static func rename(path: String, new_name: String) -> String:
	new_name = new_name.strip_edges().validate_filename()
	if new_name.is_empty():
		return ""
	var file := path.get_file()
	var dest := path.get_base_dir().path_join(new_name + file.substr(display_name(file).length()))
	if dest == path:
		return path
	# Case-only renames are allowed (on case-insensitive file systems the target "exists").
	var folder := folder_of(path)
	for e in list():
		if e.path != path and e.folder == folder and e.name.to_lower() == new_name.to_lower():
			return ""
	if FileAccess.file_exists(dest) and dest.to_lower() != path.to_lower():
		return ""
	return dest if _move_match(path, dest) else ""


## Deletes a library match, its sidecar, its audio and its logs.
static func remove(path: String) -> void:
	var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if err != OK:
		push_error("Cannot remove %s: %s" % [path, error_string(err)])
	remove_logs(path)
	for companion: String in _companions(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(companion))


## The existing files that belong to library match `path`: its sidecar, audio and logs dir.
static func _companions(path: String) -> Array:
	var out := []
	if FileAccess.file_exists(meta_path(path)):
		out.append(meta_path(path))
	if audio_path(path) != "":
		out.append(audio_path(path))
	if DirAccess.dir_exists_absolute(logs_dir(path)):
		out.append(logs_dir(path))
	return out


## Whether `path` is a match in the library or one of its folders (only those keep a sidecar).
static func contains(path: String) -> bool:
	if path == "":
		return false
	var base := path.get_base_dir().simplify_path()
	var root := dir.simplify_path()
	return base == root or (base.begins_with(root + "/") and not _is_logs_dir(base.get_file()))


## "…/match_03.positions.csv" -> "…/match_03.positions.json".
static func meta_path(path: String) -> String:
	return path.get_basename() + ".json"


## Match `path`'s audio file ("…/match_03.positions.ogg"), or "" if it has none.
static func audio_path(path: String) -> String:
	for ext in AUDIO_EXTENSIONS:
		var file: String = path.get_basename() + "." + ext
		if FileAccess.file_exists(file):
			return file
	return ""


## Copies audio file `src` into the library as match `path`'s audio, replacing any it had, and
## returns the copy's path ("" if `src` isn't a supported format or can't be copied).
static func set_audio(path: String, src: String) -> String:
	var ext := src.get_extension().to_lower()
	if not AUDIO_EXTENSIONS.has(ext):
		push_error("Cannot add %s: not one of %s" % [src, ", ".join(AUDIO_EXTENSIONS)])
		return ""
	if not FileAccess.file_exists(src):
		push_error("Cannot add %s: no such file" % src)
		return ""
	var dest := path.get_basename() + "." + ext
	if ProjectSettings.globalize_path(src).simplify_path() == ProjectSettings.globalize_path(dest).simplify_path():
		return dest
	remove_audio(path)
	var err := DirAccess.copy_absolute(ProjectSettings.globalize_path(src), ProjectSettings.globalize_path(dest))
	if err != OK:
		push_error("Cannot copy %s to %s: %s" % [src, dest, error_string(err)])
		return ""
	return dest


## Directory holding match `path`'s gamelogs: "…/match_03.positions.csv" ->
## "…/match_03.positions.logs". Also read next to CSVs outside the library.
static func logs_dir(path: String) -> String:
	return path.get_basename() + ".logs"


## Match `path`'s gamelogs (`*.txt` in `logs_dir`), sorted by file name.
static func log_paths(path: String) -> Array:
	var out := []
	var d := logs_dir(path)
	if not DirAccess.dir_exists_absolute(d):
		return out
	for file in DirAccess.get_files_at(d):
		if file.get_extension().to_lower() == "txt":
			out.append(d.path_join(file))
	out.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	return out


## Saves the part of gamelog `src` logged during match `path` (`CombatLog.trim` to
## `MatchData.eve_window`) in its `logs_dir`, and returns the saved file's path. "" (and nothing
## saved) if `src` isn't a gamelog, the match has no EVE times or the log has no combat during
## it. An identical log already there is reused; a different one with the same name gets a
## " (2)", … suffix. `data` is the match loaded from `path`, if the caller has it.
static func add_log(path: String, src: String, data: MatchData = null) -> String:
	if not FileAccess.file_exists(src):
		push_error("Cannot add %s: no such file" % src)
		return ""
	if data == null:
		data = MatchData.load_csv(path, {}, 0.0, true)
	if data == null or not data.has_eve_time():
		push_error("Cannot add %s: %s has no EVE times to line it up with" % [src, path])
		return ""
	var window := data.eve_window()
	var text := CombatLog.trim(FileAccess.get_file_as_string(src), window[0], window[1])
	if text.is_empty():
		push_error("Cannot add %s: not an EVE gamelog" % src)
		return ""
	if CombatLog.parse(text).entries.is_empty():
		push_error("Cannot add %s: no combat during %s" % [src, path.get_file()])
		return ""
	var d := logs_dir(path)
	var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(d))
	if err != OK:
		push_error("Cannot create %s: %s" % [d, error_string(err)])
		return ""
	var file := src.get_file()
	var stem := file.get_basename()
	var n := 1
	while true:
		var dest := d.path_join("%s%s.%s" % [stem, "" if n == 1 else " (%d)" % n, file.get_extension()])
		if not FileAccess.file_exists(dest):
			var f := FileAccess.open(dest, FileAccess.WRITE)
			if f == null:
				push_error("Cannot save %s: %s" % [dest, error_string(FileAccess.get_open_error())])
				return ""
			f.store_string(text)
			return dest
		if FileAccess.get_file_as_string(dest) == text:
			return dest
		n += 1
	return ""


## Deletes gamelog `gamelog` (a path from `log_paths`) of match `path`.
static func remove_log(path: String, gamelog: String) -> void:
	if gamelog.get_base_dir().simplify_path() != logs_dir(path).simplify_path():
		push_error("%s is not a log of %s" % [gamelog, path])
		return
	var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(gamelog))
	if err != OK:
		push_error("Cannot remove %s: %s" % [gamelog, error_string(err)])


## Deletes all of match `path`'s gamelogs and, if then empty, their directory.
static func remove_logs(path: String) -> void:
	for gamelog in log_paths(path):
		remove_log(path, gamelog)
	var d := logs_dir(path)
	if DirAccess.dir_exists_absolute(d) and DirAccess.get_files_at(d).is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(d))


## Deletes match `path`'s audio file, if any.
static func remove_audio(path: String) -> void:
	var file := audio_path(path)
	if file != "":
		var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(file))
		if err != OK:
			push_error("Cannot remove %s: %s" % [file, error_string(err)])


## Match `path`'s audio, ready to play, or null if it has none (or it can't be decoded).
static func load_audio(path: String) -> AudioStream:
	var file := audio_path(path)
	var stream: AudioStream = null
	match file.get_extension():
		"ogg":
			stream = AudioStreamOggVorbis.load_from_file(file)
		"mp3":
			stream = AudioStreamMP3.load_from_file(file)
		"wav":
			stream = AudioStreamWAV.load_from_file(file)
	if stream == null and file != "":
		push_error("Cannot decode %s" % file)
	return stream


## The match's saved edits: `{ teams: { pilot -> Team }, team_names: { Team -> String },
## log_pilots: { gamelog file name -> pilot } }` (the last overrides who a gamelog is attributed
## to), each present only if saved. {} when there is no (readable) sidecar.
static func load_meta(path: String) -> Dictionary:
	var file := meta_path(path)
	if not FileAccess.file_exists(file):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(file))
	if not parsed is Dictionary:
		push_error("Ignoring unreadable %s" % file)
		return {}
	# JSON has string keys and float numbers: turn teams back into ints.
	var out := {}
	if parsed.get("teams") is Dictionary:
		out.teams = {}
		for pilot in parsed.teams:
			out.teams[pilot] = int(parsed.teams[pilot])
	if parsed.get("team_names") is Dictionary:
		out.team_names = {}
		for team in parsed.team_names:
			out.team_names[int(team)] = str(parsed.team_names[team])
	if parsed.get("log_pilots") is Dictionary:
		out.log_pilots = {}
		for log_file in parsed.log_pilots:
			out.log_pilots[log_file] = str(parsed.log_pilots[log_file])
	return out


## Writes the sidecar of library match `path` (see `load_meta`).
static func save_meta(path: String, meta: Dictionary) -> void:
	var file := meta_path(path)
	var f := FileAccess.open(file, FileAccess.WRITE)
	if f == null:
		push_error("Cannot save %s: %s" % [file, error_string(FileAccess.get_open_error())])
		return
	f.store_string(JSON.stringify(meta, "\t"))
