class_name TeamDb
extends RefCounted
## Season pilot/team database: which team each pilot flies for in a season, so a pilot stays on
## their team (and with its other pilots) in every match of the season.
##
## A season is a top-level library folder ("Season 3/vs X/m1.csv" is in season "Season 3";
## matches in the library itself are season ""). Each season's db is `FILE` in its folder, so it
## moves with the folder and, on the web, is synced (and editable by anyone) like a sidecar:
##
##   { version, build, teams: { id -> { name, temp } }, pilots: { pilot -> id },
##     manual: { pilot -> id } (put there by hand, see `assign`),
##     matches: { path relative to the season folder -> sha256 } }
##
## Matches are added (`ingest`) as they join the library: each side's pilots join the db team
## most of its known pilots are on, or a new team with a temporary name ("Team 3"); a known
## pilot is never moved by that. Opening a match puts known pilots on their team's side
## (`apply`). The db is rebuilt from every match of the season the first time a new build runs
## (`ensure_current`).

const FILE := "pilot-teams.db.json"
## Bump when what `ingest` makes from a match changes, so every db is rebuilt.
const VERSION := 1
const SIDES := [MatchData.Team.BLUE, MatchData.Team.RED]


## The season library match `path` is in.
static func season_of(path: String) -> String:
	var folder := MatchLibrary.folder_of(path)
	return folder.get_slice("/", 0) if folder != "" else ""


## The db file of `season`.
static func db_path(season: String) -> String:
	return MatchLibrary.folder_abs(season).path_join(FILE)


## Every season of the library: "" (if it holds matches) and each top-level folder.
static func seasons() -> Array:
	var out := []
	for folder in MatchLibrary.folders():
		if not folder.contains("/"):
			out.append(folder)
	if MatchLibrary.list().any(func(e): return e.folder == ""):
		out.push_front("")
	return out


## An empty db.
static func empty(build := "") -> Dictionary:
	return {"version": VERSION, "build": build, "teams": {}, "pilots": {}, "manual": {}, "matches": {}}


## `season`'s db (`empty()` if it has none or it can't be read).
static func read(season: String) -> Dictionary:
	var file := db_path(season)
	if not FileAccess.file_exists(file):
		return empty()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(file))
	if not parsed is Dictionary:
		push_error("Ignoring unreadable %s" % file)
		return empty()
	var db := empty(str(parsed.get("build", "")))
	db.version = int(parsed.get("version", 0))
	for key in ["teams", "pilots", "manual", "matches"]:
		if parsed.get(key) is Dictionary:
			db[key] = parsed[key]
	for id in db.teams:
		var t: Dictionary = db.teams[id] if db.teams[id] is Dictionary else {}
		db.teams[id] = {"name": str(t.get("name", temp_name(id))), "temp": bool(t.get("temp", true))}
	return db


## Writes `season`'s db (keys sorted, so the same db always has the same contents).
static func save(season: String, db: Dictionary) -> void:
	var d := MatchLibrary.folder_abs(season)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(d))
	var file := db_path(season)
	var f := FileAccess.open(file, FileAccess.WRITE)
	if f == null:
		push_error("Cannot save %s: %s" % [file, error_string(FileAccess.get_open_error())])
		return
	f.store_string(JSON.stringify(db, "\t", true))


## "Team <n>" for team id "t<n>".
static func temp_name(id: String) -> String:
	return "Team %s" % id.trim_prefix("t")


## Adds a team with a temporary name to `db` and returns its id.
static func new_team(db: Dictionary) -> String:
	var n := 1
	for id: String in db.teams:
		n = maxi(n, int(id.trim_prefix("t")) + 1)
	var id := "t%d" % n
	db.teams[id] = {"name": temp_name(id), "temp": true}
	return id


## `id`'s name ("" if `db` has no such team).
static func team_name(db: Dictionary, id: String) -> String:
	return db.teams[id].name if db.teams.has(id) else ""


## Names team `id`; an empty name gives it back its temporary name.
static func rename(db: Dictionary, id: String, name: String) -> void:
	if not db.teams.has(id):
		return
	name = name.strip_edges()
	db.teams[id] = {"name": temp_name(id), "temp": true} if name == "" else {"name": name, "temp": false}


## Puts `pilot` on team `id` by hand: it stays there through `rebuild`.
static func assign(db: Dictionary, pilot: String, id: String) -> void:
	db.pilots[pilot] = id
	db.manual[pilot] = id


## Which db team each side of a match with `teams` ({ pilot -> Team }) is: `{ BLUE: id, RED: id }`
## ("" for none), the team most of the side's known pilots are on (ties to the lower id). When
## both sides pick the same team, the side with fewer of its pilots takes its next best.
static func sides_of(db: Dictionary, teams: Dictionary) -> Dictionary:
	var ranked := {}  # side -> [[id, count], …], best first
	for side in SIDES:
		var counts := {}
		for pilot in teams:
			if teams[pilot] == side and db.pilots.has(pilot):
				counts[db.pilots[pilot]] = counts.get(db.pilots[pilot], 0) + 1
		var r := counts.keys().map(func(id): return [id, counts[id]])
		r.sort_custom(func(a, b): return a[1] > b[1] or (a[1] == b[1] and _id_less(a[0], b[0])))
		ranked[side] = r
	var out := {}
	for side in SIDES:
		out[side] = ranked[side][0][0] if not ranked[side].is_empty() else ""
	var blue: String = out[MatchData.Team.BLUE]
	if blue != "" and blue == out[MatchData.Team.RED]:
		var blue_n: int = ranked[MatchData.Team.BLUE][0][1]
		var red_n: int = ranked[MatchData.Team.RED][0][1]
		var loser: int = MatchData.Team.RED if blue_n >= red_n else MatchData.Team.BLUE
		out[loser] = ranked[loser][1][0] if ranked[loser].size() > 1 else ""
	return out


static func _id_less(a: String, b: String) -> bool:
	return int(a.trim_prefix("t")) < int(b.trim_prefix("t"))


## Adds the pilots of match `teams` ({ pilot -> Team }) to `db`: each side's new pilots join
## that side's team (`sides_of`), or a new one; pilots already in `db` stay on their team.
static func add_teams(db: Dictionary, teams: Dictionary) -> void:
	var sides := sides_of(db, teams)
	for side in SIDES:
		var members := teams.keys().filter(func(p): return teams[p] == side and not db.pilots.has(p))
		if members.is_empty():
			continue
		if sides[side] == "":
			sides[side] = new_team(db)
		for pilot in members:
			db.pilots[pilot] = sides[side]


## Adds library match `path` to `db` (its season's): its geometric teams with the match's own
## swaps (`MatchLibrary.load_meta`) applied (`data` is the match loaded from `path`, if the caller
## has it). False if it couldn't be read; a match already added with the same contents is skipped.
static func ingest(db: Dictionary, path: String, data: MatchData = null) -> bool:
	var key := _key(path)
	var sha := FileAccess.get_sha256(path)
	if db.matches.get(key) == sha:
		return true
	if data == null:
		data = MatchData.load_csv(path, {}, 0.0, true)
	if data == null:
		return false
	add_teams(db, _match_teams(path, data))
	db.matches[key] = sha
	return true


## Match `data`'s (loaded from library match `path`) teams with its own swaps applied.
static func _match_teams(path: String, data: MatchData) -> Dictionary:
	var teams := data.teams.duplicate()
	var overrides: Dictionary = MatchLibrary.load_meta(path).get("teams", {})
	for pilot in overrides:
		if teams.has(pilot):
			teams[pilot] = overrides[pilot]
	return teams


## `ingest`s library matches `paths` into their seasons' dbs and saves them. On the web, a db
## the browser hasn't downloaded yet is fetched first (a season whose db can't be is skipped,
## so it isn't overwritten).
static func ingest_paths(paths: Array) -> void:
	var by_season := {}
	for path in paths:
		var season := season_of(path)
		if not by_season.has(season):
			by_season[season] = []
		by_season[season].append(path)
	for season in by_season:
		if OS.has_feature("web") and not await WebLibrary.fetch_file(db_path(season)):
			continue
		var db := read(season)
		if not FileAccess.file_exists(db_path(season)):
			db.build = build_id()  # a new db is made by this build: no rebuild needed
		for path in by_season[season]:
			ingest(db, path)
		save(season, db)


## `path` relative to its season's folder.
static func _key(path: String) -> String:
	var season := season_of(path)
	var root := MatchLibrary.folder_abs(season).simplify_path()
	return path.simplify_path().substr(root.length() + 1)


## Puts the known pilots of match `data` on their db team's side (`sides_of` its teams), and
## returns that `{ side -> id }`.
static func apply(db: Dictionary, data: MatchData) -> Dictionary:
	var sides := sides_of(db, data.teams)
	for pilot in data.teams:
		var id: String = db.pilots.get(pilot, "")
		for side in SIDES:
			if id != "" and sides[side] == id:
				data.teams[pilot] = side
	return sides


## `season`'s db made again from all its matches, oldest first, for build `build`. What was
## set by hand in the old db is kept: each old team is matched with the new team most of its
## pilots are on, which takes its name if it was named, and pilots `assign`ed by hand go back
## to their team.
static func rebuild(season: String, build: String) -> Dictionary:
	var old := read(season)
	var db := empty(build)
	var dated := []  # [when, path, sha, teams]
	for entry in MatchLibrary.list():
		if season_of(entry.path) != season:
			continue
		var data := MatchData.load_csv(entry.path, {}, 0.0, true)
		if data == null:
			continue
		var when: float = data.eve_unix_start if data.has_eve_time() else float(entry.modified)
		dated.append([when, entry.path, FileAccess.get_sha256(entry.path), _match_teams(entry.path, data)])
	dated.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1].naturalnocasecmp_to(b[1]) < 0))
	for d in dated:
		add_teams(db, d[3])
		db.matches[_key(d[1])] = d[2]

	# Old team -> new team, biggest overlaps first, each new team matched at most once.
	var overlaps := []  # [count, old id, new id]
	for was in old.teams:
		var counts := {}
		for pilot in old.pilots:
			if old.pilots[pilot] == was and db.pilots.has(pilot) and not old.manual.has(pilot):
				counts[db.pilots[pilot]] = counts.get(db.pilots[pilot], 0) + 1
		for id in counts:
			overlaps.append([counts[id], was, id])
	overlaps.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and _id_less(a[1], b[1])))
	var mapped := {}
	var taken := {}
	for o in overlaps:
		if mapped.has(o[1]) or taken.has(o[2]):
			continue
		mapped[o[1]] = o[2]
		taken[o[2]] = true
	for was in old.teams:
		if not old.teams[was].temp and mapped.has(was):
			rename(db, mapped[was], old.teams[was].name)
	for pilot in old.manual:
		var was: String = old.manual[pilot]
		if not old.teams.has(was):
			continue
		if not mapped.has(was):
			mapped[was] = new_team(db)
			if not old.teams[was].temp:
				rename(db, mapped[was], old.teams[was].name)
		assign(db, pilot, mapped[was])
	return db


## Rebuilds (and saves) every season's db made for another build or `VERSION`. On the web, a
## season's matches are downloaded first (a season that can't be is left as it is).
static func ensure_current(build: String) -> void:
	for season in seasons():
		if OS.has_feature("web") and not await WebLibrary.fetch_file(db_path(season)):
			continue
		var db := read(season)
		if FileAccess.file_exists(db_path(season)) and db.version == VERSION and db.build == build:
			continue
		if OS.has_feature("web"):
			var ok := true
			for entry in MatchLibrary.list():
				if season_of(entry.path) == season and not await WebLibrary.fetch_match(entry.path, false):
					ok = false
					break
			if not ok:
				continue
		save(season, rebuild(season, build))


## The build the db is made by: the site's build on the web (so the first visit after a deploy
## rebuilds), else just `VERSION`.
static func build_id() -> String:
	var site: String = str(WebBackend.boot().get("build", "")) if OS.has_feature("web") else ""
	return "%s:%d" % [site, VERSION] if site != "" else str(VERSION)
