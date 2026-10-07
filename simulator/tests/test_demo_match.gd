extends "res://tests/test_case.gd"
## End-to-end checks against the anonymized demo match checked in at
## `resouces/demo/match_03.positions.csv` (regenerate with `scripts/anonymize.py`). It lives
## outside the Godot project so it isn't imported as a translation table.

const Main := preload("res://scripts/main.gd")

const PILOTS := 20
## Every hull in the demo, with its SDE radius in metres (build 3569502). Pinned here so the
## tests run offline; `sde/` is git-ignored and absent in CI.
const HULL_RADII := {
	"Capsule": 2.0, "Venture": 41.0, "Prospect": 41.0, "Endurance": 41.0,
	"Procurer": 137.0, "Retriever": 202.0, "Covetor": 254.0, "Skiff": 137.0, "Mackinaw": 202.0,
	"Porpoise": 450.0, "Orca": 550.0,
}
const PILOT_PATTERN := "^(Amarr|Caldari|Gallente|Minmatar) Citizen \\d{7}$"

var _saved_path: String


static func demo_path() -> String:
	return ProjectSettings.globalize_path("res://").path_join(
		"../resouces/demo/match_03.positions.csv").simplify_path()


## `MatchData` radii: lowercase ship type -> metres.
static func radii() -> Dictionary:
	var out := {}
	for hull in HULL_RADII:
		out[hull.to_lower()] = HULL_RADII[hull]
	return out


func _load() -> MatchData:
	return MatchData.load_csv(demo_path(), radii())


## Ship type `pilot` was flying at match time `t`.
static func _ship_at(d: MatchData, pilot: String, t: float) -> String:
	var ship := ""
	for s in d.tracks[pilot]:
		if s.t - d.start_time > t:
			break
		ship = s.ship_type
	return ship


func before_each() -> void:
	# main.gd reads settings on _ready; keep the real ones untouched and stay offline.
	_saved_path = Settings.path
	Settings.path = temp_dir().path_join("settings.cfg")
	Settings._cfg = null
	Settings.set_value("sde/auto_update", false)
	Settings.set_value("display/ship_models", false)


func after_each() -> void:
	Settings.path = _saved_path
	Settings._cfg = null


# --- the file itself ---------------------------------------------------------

func test_file_exists() -> void:
	assert_true(FileAccess.file_exists(demo_path()), demo_path())


func test_pilots_are_anonymized() -> void:
	var d := _load()
	var re := RegEx.create_from_string(PILOT_PATTERN)
	for pilot in d.tracks:
		assert_not_null(re.search(pilot), "pilot name %s" % pilot)


func test_ships_are_mining_hulls() -> void:
	var d := _load()
	for pilot in d.tracks:
		for s in d.tracks[pilot]:
			if not HULL_RADII.has(s.ship_type):
				fail("%s flies %s at t=%s" % [pilot, s.ship_type, s.t])
				return


# --- MatchData ---------------------------------------------------------------

func test_load() -> void:
	var d := _load()
	assert_not_null(d)
	assert_eq(d.tracks.size(), PILOTS)
	assert_eq(d.start_time, 9.0, "countdown skipped: first ship moves at t=10")
	assert_eq(d.duration, 575.0)
	var samples := 0
	for pilot in d.tracks:
		samples += d.tracks[pilot].size()
	assert_eq(samples, 8811, "pods' tracks end where they died")
	assert_eq(d.eve_start, "2026-10-03T14:03:14.000Z", "countdown's first number")
	assert_eq(d.eve_end, "2026-10-03T14:12:58.000Z", "the second before WF")


func test_tracks_sorted() -> void:
	var d := _load()
	for pilot in d.tracks:
		var track: Array = d.tracks[pilot]
		for i in range(1, track.size()):
			if track[i].t < track[i - 1].t:
				fail("%s unsorted at sample %d" % [pilot, i])
				break


func test_teams() -> void:
	var d := _load()
	var counts := {MatchData.Team.BLUE: 0, MatchData.Team.RED: 0, MatchData.Team.UNKNOWN: 0}
	for pilot in d.teams:
		counts[d.teams[pilot]] += 1
	assert_eq(counts[MatchData.Team.BLUE], 10, "blue")
	assert_eq(counts[MatchData.Team.RED], 9, "red")
	assert_eq(counts[MatchData.Team.UNKNOWN], 1, "unknown")
	assert_eq(d.teams["Amarr Citizen 2674287"], MatchData.Team.BLUE)
	assert_eq(d.teams["Caldari Citizen 6206817"], MatchData.Team.RED)
	assert_eq(d.teams["Amarr Citizen 2281178"], MatchData.Team.UNKNOWN, "starts off both lines")


func test_deaths() -> void:
	var d := _load()
	var dead := d.deaths.keys()
	dead.sort()
	assert_eq(dead, ["Amarr Citizen 5054432", "Caldari Citizen 9942864"])
	assert_almost(d.deaths["Amarr Citizen 5054432"].t, 221.832, 1e-2)
	assert_almost(d.deaths["Caldari Citizen 9942864"].t, 196.951, 1e-2)
	assert_true(d.podded.has("Caldari Citizen 8777524"), "its pod flew out, but pods aren't tracked")
	assert_eq(_ship_at(d, "Amarr Citizen 5054432", d.deaths["Amarr Citizen 5054432"].t), "Prospect")
	assert_eq(_ship_at(d, "Caldari Citizen 9942864", d.deaths["Caldari Citizen 9942864"].t), "Venture")


## A death is where the hull sphere touches the boundary, so the ship's centre is one hull
## radius inside it.
func test_deaths_touch_boundary_with_hull() -> void:
	var d := _load()
	for pilot in d.deaths:
		var death: Dictionary = d.deaths[pilot]
		var r: float = HULL_RADII[_ship_at(d, pilot, death.t)]
		assert_almost(death.pos.distance_to(MatchData.CENTRE_M),
			MatchData.BOUNDARY_RADIUS_M - r, 1.0, "%s centre at boundary - %s m" % [pilot, r])


## No surviving pilot's hull ever crosses the boundary.
func test_survivors_stay_inside_with_hull() -> void:
	var d := _load()
	for pilot in d.tracks:
		if d.deaths.has(pilot):
			continue
		for s in d.tracks[pilot]:
			var reach: float = s.pos.distance_to(MatchData.CENTRE_M) + HULL_RADII[s.ship_type]
			if reach > MatchData.BOUNDARY_RADIUS_M:
				fail("%s's %s reaches %.0f m at t=%s" % [pilot, s.ship_type, reach, s.t])
				break


func test_ship_change_to_capsule() -> void:
	var d := _load()
	var track: Array = d.tracks["Amarr Citizen 0220922"]
	assert_eq(track[0].ship_type, "Porpoise")
	assert_eq(track[-1].ship_type, "Capsule")


func test_events() -> void:
	var d := _load()
	var count := {}
	for e in d.events:
		count[e.kind] = count.get(e.kind, 0) + 1
	assert_eq(count.get(MatchData.Event.DEATH, 0), 11, "pilots podded")
	assert_eq(count.get(MatchData.Event.BOUNDARY, 0), d.deaths.size())
	assert_eq(count.get(MatchData.Event.MJD, 0), 0, "pod warps aren't MJDs")


func test_sample() -> void:
	var d := _load()
	var pilot := "Amarr Citizen 0220922"
	var s := d.sample(pilot, 89.0)
	assert_eq(s.ship_type, "Porpoise")
	assert_almost(s.pos, Vector3(41840, 57520, 67416))

	var a := d.sample(pilot, 89.0)
	var b := d.sample(pilot, 90.0)
	var mid := d.sample(pilot, 89.5)
	assert_almost(mid.pos, a.pos.lerp(b.pos, 0.5))

	assert_eq(d.sample(pilot, -d.start_time - 1.0), {}, "before the recording")
	assert_eq(d.sample(pilot, 576.0), {}, "after the match")


# --- main.gd -----------------------------------------------------------------

## The viewer, with SDE sizes for the demo hulls standing in for the (offline) cache.
func _viewer() -> Main:
	var m: Main = Main.new()
	add_node(m)
	m.assets.fetch_ewar_icons = false
	m.sizes.ships.clear()
	for hull in HULL_RADII:
		m.sizes.ships[hull.to_lower()] = {
			"name": hull, "type_id": 0, "group_id": 0, "radius_m": HULL_RADII[hull],
		}
	m.load_match(demo_path())
	m.start_button.pressed.emit()
	return m


func test_viewer_loads_demo() -> void:
	var m := _viewer()
	assert_not_null(m.data)
	assert_eq(m.ships.size(), PILOTS)
	assert_eq(m.timeline.max_value, 575.0)
	assert_eq(m.file_label.text,
		"match_03.positions.csv — 20 pilots (blue 10 / red 9 / unknown 1), 2 out of bounds")


# --- combat log --------------------------------------------------------------------

static func demo_log_path() -> String:
	return MatchLibrary.log_paths(demo_path())[0]


func test_demo_log_is_anonymized() -> void:
	assert_eq(MatchLibrary.log_paths(demo_path()).size(), 1)
	var gamelog := CombatLog.load_file(demo_log_path())
	assert_not_null(gamelog)
	assert_not_null(RegEx.create_from_string(PILOT_PATTERN).search(gamelog.listener), gamelog.listener)
	var name_re := RegEx.create_from_string("^(?:(Amarr|Caldari|Gallente|Minmatar) Citizen \\d{7}|.* (Bot I|SW-300))$")
	for e in gamelog.entries:
		for who in [e.source, e.target]:
			if who != "" and name_re.search(who) == null:
				fail("not anonymized: %s in %s" % [who, e.text])
				return
		for ship in [e.source_ship, e.target_ship]:
			if ship != "" and not HULL_RADII.has(ship) and name_re.search(ship) == null:
				fail("not a mining hull: %s in %s" % [ship, e.text])
				return


func test_demo_log_syncs_to_match() -> void:
	var d := _load()
	var gamelog := CombatLog.load_file(demo_log_path())
	gamelog.sync(d)
	assert_eq(gamelog.pilot, "Caldari Citizen 6206817", "the Skiff")
	assert_eq(_ship_at(d, gamelog.pilot, 0.0), "Skiff")
	assert_eq(gamelog.entries.size(), 832)
	var first: Dictionary = gamelog.entries[0]
	assert_eq(first.t, 7.0, "14:03:30 is 16 s after the CSV starts, 7 s after match time 0")
	assert_eq(first.kind, CombatLog.Kind.DAMAGE)
	assert_eq(first.source_pilot, gamelog.pilot)
	assert_eq(first.target_pilot, "Caldari Citizen 3216932")
	assert_eq(_ship_at(d, first.target_pilot, first.t), first.target_ship)
	var attributed := 0
	for e in gamelog.entries:
		if e.t < -d.start_time - MatchData.MAX_GAP_S or e.t > d.duration + MatchData.MAX_GAP_S:
			fail("entry outside the match: %s at %s" % [e.text, e.t])
			return
		for p in [e.source_pilot, e.target_pilot]:
			if p != "" and not d.tracks.has(p):
				fail("%s is not a pilot" % p)
				return
		if e.source_pilot != "" and e.target_pilot != "":
			attributed += 1
	assert_true(attributed > gamelog.entries.size() * 0.9, "%d of %d entries have both pilots" % [attributed, gamelog.entries.size()])


func test_viewer_loads_demo_combat_log() -> void:
	var m := _viewer()
	assert_eq(m.data.combat_logs.size(), 1)
	assert_eq(m.data.combat_logs[0].pilot, "Caldari Citizen 6206817")


## Moves the paused viewer to match time `t` and draws a frame.
static func _show_at(m: Main, t: float) -> void:
	m._seek(t)
	m._process(0.0)


func test_viewer_shows_demo_combat_columns() -> void:
	var m := _viewer()
	for id in ["dmg_in", "dmg_out", "cap_in", "cap_out", "ewar_in", "ewar_out"]:
		assert_false(m.roster_table.unavailable.has(id), "%s shown" % id)
	# Its only remote reps come from drones, which aren't pilots.
	assert_true(m.roster_table.unavailable.has("rep_in"))
	m._set_playing(false)
	var skiff := "Caldari Citizen 6206817"
	_show_at(m, 10.0)  # Its railguns hit at 7 s and 10 s.
	assert_eq(m.roster_table.cell_text(skiff, "dmg_out"), "%d" % roundi((204.0 + 113.0) / CombatStats.RATE_WINDOW_S))
	_show_at(m, 0.0)
	assert_eq(m.roster_table.cell_text(skiff, "dmg_out"), "—", "before any shots")
	# 14:03:39: Porpoise [Minmatar Citizen 0254120] scrams Venture [Gallente Citizen 1635012].
	_show_at(m, 17.0)
	var box := m.roster_table.icon_box("Gallente Citizen 1635012", "ewar_in")
	var scram := box.get_children().filter(func(c): return c.get_meta("key") == "scram")
	assert_eq(scram.size(), 1)
	assert_true(scram[0].tooltip_text.begins_with("Warp scramble from:"), scram[0].tooltip_text)
	assert_true(scram[0].tooltip_text.contains(m._pilot_name("Minmatar Citizen 0254120")), scram[0].tooltip_text)
	var out := m.roster_table.icon_box("Minmatar Citizen 0254120", "ewar_out").get_children()
	assert_true(out.any(func(c): return c.get_meta("key") == "scram"), "and on the scrammer's outgoing side")


func test_viewer_plays_through() -> void:
	var m := _viewer()
	m.speed = 10.0
	for i in 60:
		m._process(1.0)
	assert_eq(m.time, 575.0)
	assert_false(m.playing)
