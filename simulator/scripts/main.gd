extends Node3D
## Replays a `scrim-positions` CSV: one hull model (or sphere) per pilot moving through the
## observers' 100 km cube.
## Starts on the `MainMenu` (matches in the `MatchLibrary`); `godot --path simulator -- --csv <file>`
## opens a CSV directly instead. Dropping a CSV on the window adds it to the library and opens it.

## 1 scene unit = 1 km.
const M_TO_UNITS := 0.001
const CUBE := 100.0
const SPEEDS := [0.5, 1.0, 2.0, 5.0, 10.0, 30.0]
## The server tick: samples are 1 s apart, so ←/→ step one sample.
const TICK_S := 1.0
## Shift+←/→ seeks this far without pausing.
const SKIP_S := 10.0
## Ships are drawn at their real hull radius, but never smaller than this angle (radians) as
## seen from the camera, so frigates stay visible from across the arena.
const MIN_VISIBLE_ANGLE := 0.005
## Ship models are drawn at their true size; their overview bracket icon keeps them visible.
const ICON_PX := 20.0
## Corner and centre MJUs are drawn this big (the SDE radius of deployables is meaningless).
const MJU_RADIUS_KM := 1.0
## Below this speed (m/s) a model keeps its last heading.
const MIN_HEADING_SPEED := 5.0
## With smooth motion, models turn toward their heading with this time constant (match s).
const TURN_TIME_S := 0.6
## A playback step longer than this (a seek) snaps models to their heading instead of turning.
const MAX_TURN_STEP_S := 2.0
## Hull models point their nose along +Z; `Basis.looking_at` aims -Z, so turn them around.
const MODEL_FORWARD := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1))
const CORNER_COLOR := Color(0.3, 0.7, 1.0)
const CENTRE_COLOR := Color(1.0, 0.8, 0.2)
const BOUNDARY_KM := MatchData.BOUNDARY_RADIUS_M * M_TO_UNITS
const BOUNDARY_COLOR := Color(1.0, 0.45, 0.15)
const TEAM_COLORS := {
	MatchData.Team.BLUE: Color(0.25, 0.5, 1.0),
	MatchData.Team.RED: Color(1.0, 0.25, 0.2),
	MatchData.Team.UNKNOWN: Color(0.6, 0.6, 0.6),
}
const TEAM_NAMES := {
	MatchData.Team.BLUE: "Blue",
	MatchData.Team.RED: "Red",
	MatchData.Team.UNKNOWN: "Unknown",
}
## A click lands on a ship within this many pixels of its centre (or anywhere on its hull).
const PICK_PX := 14.0
## A left press released within this many pixels is a click; further is a camera drag.
const CLICK_SLOP_PX := 4.0
## The selection bracket is this many times the size of the overview icon.
const SELECT_SCALE := 1.8
const SELECT_COLOR := Color(1, 1, 1, 0.9)
## Left drag from a ship: a range sphere around it; ships it reaches get a bracket this many
## times the overview icon (outside the selection bracket).
const MEASURE_COLOR := Color(0.4, 1.0, 0.6)
const MEASURE_SCALE := 2.4
## Ship/death label `pixel_size` per screen pixel spanned at 1 unit from the camera (0.0008 at the
## default 75° FOV and 648 px viewport), so labels keep their on-screen size.
const LABEL_PX := 0.338
## What can be shown above a ship (settings `overlay/<field>`), in label order; `icon` is the
## overview bracket.
const OVERLAY_FIELDS := ["name", "type", "distance", "speed", "icon"]
## Interface scale presets offered in Settings.
const UI_SCALES := [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
const MJD_COLOR := Color(0.3, 0.9, 0.9)
## Timeline tick colour and legend name per `MatchData.Event`.
const EVENT_COLORS := {
	MatchData.Event.DEATH: Color(1.0, 0.3, 0.55),
	MatchData.Event.BOUNDARY: BOUNDARY_COLOR,
	MatchData.Event.MJD: MJD_COLOR,
}
const EVENT_NAMES := {
	MatchData.Event.DEATH: "Died",
	MatchData.Event.BOUNDARY: "Out of bounds",
	MatchData.Event.MJD: "MJD",
}
## Audio further than this (s) from match time is re-seeked.
const AUDIO_DRIFT_S := 0.15
const AUDIO_BUS := "Match audio"
## Jumping to an event lands this many seconds before it, to see the lead-up.
const EVENT_LEAD_S := 2.0
## A micro jump's take-off -> landing line stays up this long (match s) after the jump.
const MJD_TRAIL_S := 5.0
## Radius (screen px) of the spool ring drawn around a ship spooling its micro jump drive, and of
## the marker where it lands.
const MJD_RING_PX := 24.0
const MJD_RING_SEGMENTS := 48
## Jump range drawn around the corner and centre beacons (debug menu).
const BEACON_JUMP_KM := 5.0
const VECTOR_SECONDS := 3.0
## A movement vector's arrowhead is this fraction of its length.
const ARROW_FRACTION := 0.08
## Activity lines (shooting, tackle, …), in screen pixels: space between the lines of different
## kinds joining the same two ships, dash and gap length, how fast the dashes flow from source to
## target (px/s, wall clock so they move while paused), and the arrowhead at the target.
const LINK_SPACING_PX := 4.0
const LINK_DASH_PX := 14.0
const LINK_GAP_PX := 8.0
const LINK_FLOW_PX_S := 40.0
const LINK_HEAD_PX := 9.0
## Alpha at a dash's tail; its head is opaque, so direction shows in a still frame too.
const LINK_TAIL_ALPHA := 0.3

var data: MatchData
var match_path := ""
var time := 0.0
var playing := false
var speed := 1.0
## Pilot the camera stays centred on ("" = free camera).
var tracked := ""
## Pilot picked by clicking it in space ("" = none); shown in the info panel.
var selected := ""
## pilot -> Team picked with the roster's swap button; kept when the same match reloads, and
## saved with library matches (`MatchLibrary.save_meta`).
var team_overrides := {}
## Team -> name given to it in this match (Blue/Red only; default `TEAM_NAMES`), saved like
## `team_overrides`.
var team_names := {}
## The open library match's season `TeamDb` and which of its teams each side is (`{ Team -> id }`,
## "" for none); `team_sides` is empty when season teams are off or the match isn't in the library.
var team_db := {}
var team_sides := {}
## Team -> the `TEAM_COLORS` key it is drawn in: its season team's colour in the match's folder
## (`TeamDb.side_colors`), so a team looks the same in every match of a folder; empty = its own.
var side_colors := {}
## Whether the open library match is internal (`MatchLibrary.is_internal`): its sides come only
## from start positions, never from `team_db`.
var match_internal := false
## Gamelog file name -> pilot it belongs to, where the listener's name doesn't pick the right one
## (see `CombatLog.sync`); saved like `team_overrides`.
var log_pilots := {}
## Id of the `Ruleset` the match's points follow (default the newest); saved like `team_overrides`.
var ruleset_id := ""
## Team points under `ruleset_id` (null without a match or ruleset).
var score: MatchScore
## What the open match's gamelogs say about each pilot (roster combat columns).
var combat_stats := CombatStats.new()
## CSV pilot name -> display name, for every match (setting `names/pilots`).
var pilot_names: Dictionary = Settings.get_value("names/pilots").duplicate()
## pilot -> { vector: bool, spheres: [{ radius_km, color }] } from the debug menus; kept when the
## same match reloads.
var debug := {}
## `CombatStats.LINK_KINDS` kind -> { on, color }: which activity lines are drawn (from Settings).
var links := {}
## Every activity line, in world space.
var links_mesh: MeshInstance3D
## Movement vectors end where the ship will be this many seconds from now.
var vector_seconds := VECTOR_SECONDS

## pilot -> { node, visual, model_id, icon, select_icon, label, ship_type, radius, dead, color, tint, death_t,
## death_marker, heading, heading_t, vector, vector_tip, spheres, mjd_ring, mjd_projection,
## mjd_lines, mjd_label, mjd_land }; `heading` is the model's
## rotation as of match time `heading_t`; `radius` is the true hull radius in scene units (0 if
## unknown), `visual` the sphere or model under `node`, `model_id` the type ID it shows
## (0 = sphere), `tint` the colour the ship is currently drawn in; `vector` the debug movement
## line (ending at `vector_tip`, relative to the ship) and `spheres` the node holding its debug
## range spheres; `mjd_ring` and `mjd_projection` (lines `mjd_lines` and label `mjd_label`, in
## world space) draw its micro jump drive spool-up, aimed at its landing `mjd_land`.
var ships := {}
var ships_root: Node3D
var boundary: Node3D
var camera: Camera3D
var sphere_mesh := SphereMesh.new()
var sizes: ShipSizes
var assets: ShipAssets
## Draw hull models + bracket icons instead of spheres (setting `display/ship_models`).
var models_on := true
## Smooth ship paths between samples (setting `display/smooth_motion`).
var smooth_on := true
## field -> shown, for each of `OVERLAY_FIELDS` (settings `overlay/<field>`).
var ship_overlay := {}
## Corner/centre markers: plain boxes, or MJU models + icons.
var markers_box: Node3D
var markers_model: Node3D
## 5 km jump range spheres around the corner beacons and the centre one (debug menu).
var beacon_ranges_corner: Node3D
var beacon_ranges_centre: Node3D
var vector_material: StandardMaterial3D

var menu: MainMenu
## Plays the match's audio (`MatchLibrary.load_audio`) in step with `time`, on `AUDIO_BUS`, whose
## pitch shift undoes the pitch change of playing faster or slower.
var audio_player: AudioStreamPlayer
var audio_pitch: AudioEffectPitchShift
## Mutes `AUDIO_BUS` (setting `audio/muted`); the player keeps running so unmuting stays in sync.
var muted := false
var mute_button: Button
var play_button: Button
## Big centred button shown over a freshly opened (paused) match; gone once playback first starts.
var start_button: Button
var timeline: HSlider
var event_strip: EventStrip
## Draw micro jump drive spool-ups in space (setting `display/mjd_spoolup`); the broadcast panel's
## MJD icon shows regardless.
var mjd_on := true
var mjd_button: Button
var mjd_setting: CheckBox
## { t: float, node: Node3D } per micro jump: a line from take-off to landing.
var mjd_trails: Array = []
var time_label: Label
var boundary_setting: CheckBox
var models_setting: CheckBox
## Match-start jitter settings: on/off and threshold (metres).
var jitter_setting: CheckBox
var jitter_spin: SpinBox
var ui_scale_option: OptionButton
var file_label: Label
var sde_label: Label
var settings_popup: OpaquePopup
var overlay_popup: OpaquePopup
var download_dialog: ConfirmationDialog
var assets_dialog: ConfirmationDialog
var bottom_panel: PanelContainer
var roster_panel: PanelContainer
var roster_table: RosterTable
## Right-click menu of a roster row's ⇄ button: the teams its pilot can move to (`_move_team`).
var team_menu: PopupMenu
## Broadcast-style alternative to the roster (setting `display/broadcast_roster`).
var broadcast_panel: BroadcastRoster
var broadcast_button: Button
var broadcast_on := false
## Highlight roster rows of ships taking damage (setting `display/damage_highlight`).
var damage_button: Button
## Picks `ruleset_id`; item metadata is the ruleset id.
var ruleset_option: OptionButton
var damage_setting: CheckBox
var damage_on := false
var info_panel: PanelContainer
var info_label: Label
## Toggles `hotkeys_panel`, shown top left above `info_panel`.
var hotkeys_button: Button
var hotkeys_panel: HotkeysPanel
var select_texture: Texture2D
## Debug menus: one ship's (for `debug_pilot`) and every ship's.
var ship_debug_menu: DebugMenu
var all_debug_menu: DebugMenu
var debug_pilot := ""
## Open "Get Damage Breakdown" windows, refreshed every frame.
var breakdown_windows: Array[DamageBreakdown] = []
## Pilot and team renaming; `_rename_target` applies the submitted name.
var rename_dialog: RenameDialog
var _rename_target := func(_text: String): pass
## pilot -> its toggle Button in the roster.
var roster_buttons := {}
var _scrubbing := false
var _press_pos := Vector2.INF
var _right_press_pos := Vector2.INF
## Pilot a left press landed on (its drag measures from it; "" = none), whether the drag has gone
## past `CLICK_SLOP_PX`, and where the cursor is.
var _measure_from := ""
var _measuring := false
var _measure_mouse := Vector2.ZERO
## Measuring sphere (unit radius, scaled), line to the cursor or snapped ship, and its label.
var measure_root: Node3D
var measure_line: MeshInstance3D
var measure_label: Label3D
## `_units_per_px(1.0)` that the fixed-size icons and labels are currently sized for.
var _overlay_unit := 0.0


func _ready() -> void:
	sphere_mesh.radius = 1.0
	sphere_mesh.height = 2.0
	vector_material = _material(Color.WHITE, false)
	vector_material.vertex_color_use_as_albedo = true
	vector_material.no_depth_test = true
	sizes = ShipSizes.new()
	add_child(sizes)
	assets = ShipAssets.new()
	add_child(assets)
	models_on = Settings.get_value("display/ship_models")
	smooth_on = Settings.get_value("display/smooth_motion")
	broadcast_on = Settings.get_value("display/broadcast_roster")
	damage_on = Settings.get_value("display/damage_highlight")
	mjd_on = Settings.get_value("display/mjd_spoolup")
	muted = Settings.get_value("audio/muted")
	for field in OVERLAY_FIELDS:
		ship_overlay[field] = Settings.get_value("overlay/" + field)
	for kind in CombatStats.LINK_KINDS:
		links[kind] = {"on": Settings.get_value("links/" + kind), "color": Settings.get_value("links/%s_color" % kind)}
	get_window().content_scale_factor = Settings.get_value("display/ui_scale")
	_build_environment()
	_overlay_unit = _units_per_px(1.0)
	get_viewport().size_changed.connect(_on_viewport_resized)
	_build_markers()
	_build_boundary()
	ships_root = Node3D.new()
	add_child(ships_root)
	links_mesh = _lines_mesh()
	links_mesh.visible = true
	add_child(links_mesh)
	_build_measure()
	_build_audio()
	_build_ui()
	get_window().files_dropped.connect(_on_files_dropped)

	sde_label.text = sizes.status
	sizes.status_changed.connect(func(text): sde_label.text = text)
	sizes.needs_download.connect(_prompt_download)
	sizes.sizes_changed.connect(_on_sizes_changed)
	sizes.start(Settings.get_value("sde/auto_update"))
	assets.status_changed.connect(func(text): sde_label.text = text)
	assets.needs_download.connect(_prompt_assets)
	assets.assets_changed.connect(_on_assets_changed)
	assets.ewar_icons_changed.connect(_update_roster_cells)
	assets.start(models_on, Settings.get_value("sde/auto_update"))
	_apply_visual_mode()

	MatchLibrary.add_demo()
	_check_for_update()  # not awaited: runs in the background
	if not OS.has_feature("web"):  # the web build checks once its library is synced (`WebLibrary`)
		TeamDb.ensure_current(TeamDb.build_id())
	var args := OS.get_cmdline_user_args()
	var i := args.find("--csv")
	if i >= 0 and i + 1 < args.size():
		load_match(_resolve_cli_path(args[i + 1]))
	else:
		_show_menu()


## `--path` makes Godot chdir into the project, so a relative CLI path is resolved against the
## launching shell's directory (PWD is left untouched by that chdir).
static func _resolve_cli_path(path: String) -> String:
	if path.is_absolute_path():
		return path
	var pwd := OS.get_environment("PWD")
	if pwd.is_empty():
		return path
	return pwd.path_join(path).simplify_path()


## Opens `path`, hiding the menu; false (and nothing changes) if it can't be read.
func load_match(path: String) -> bool:
	var has_audio := MatchLibrary.contains(path) and MatchLibrary.audio_path(path) != ""
	var d := MatchData.load_csv(path, sizes.radii(), _move_threshold_m(), has_audio)
	if d == null:
		file_label.text = "Failed to load %s" % path.get_file()
		return false
	menu.visible = false
	data = d
	data.smooth = smooth_on
	if path != match_path:
		var meta := MatchLibrary.load_meta(path) if MatchLibrary.contains(path) else {}
		team_overrides = meta.get("teams", {})
		team_names = meta.get("team_names", {})
		log_pilots = meta.get("log_pilots", {})
		ruleset_id = meta.get("ruleset", "")
		if Ruleset.load_id(ruleset_id) == null:
			ruleset_id = Ruleset.latest_id()
		_select_ruleset_option()
		debug.clear()
		for w in breakdown_windows.duplicate():
			w.queue_free()
		breakdown_windows.clear()
		start_button.visible = true
	match_internal = MatchLibrary.contains(path) and MatchLibrary.is_internal(path)
	team_db = TeamDb.db_for(path)
	team_sides = TeamDb.settle(data, team_db, team_overrides)
	side_colors = {} if team_db.is_empty() else TeamDb.side_colors(team_db, TeamDb.folder_key(path), team_sides)
	match_path = path
	audio_player.stop()
	audio_player.stream = MatchLibrary.load_audio(path) if has_audio else null
	_update_mute_button()
	_end_measure()
	for c in ships_root.get_children():
		c.queue_free()
	ships.clear()
	for pilot in data.tracks:
		_add_ship(pilot)
	_fetch_models()
	timeline.max_value = data.duration
	_build_events()
	if not ships.has(tracked):
		tracked = ""
	if not ships.has(selected):
		selected = ""
	_update_file_label()
	roster_table.set_column_available("hp", data.has_hp)
	_update_damage_controls()
	_refresh_roster()
	_select(selected)
	print("Loaded %s: %d pilots, %.0f s" % [path, ships.size(), data.duration])
	for pilot in data.teams:
		print("  %s: %s" % [pilot, MatchData.Team.find_key(data.teams[pilot])])
	for pilot in data.deaths:
		print("  %s: out of bounds at %s" % [pilot, _fmt_time(data.deaths[pilot].t)])
	_load_combat_logs()
	_seek(0.0)
	_set_playing(not start_button.visible)
	return true


## Pauses and covers the viewer with the main menu.
func _show_menu() -> void:
	_set_playing(false)
	menu.show_error("")
	menu.refresh()
	menu.resume_button.visible = data != null
	menu.visible = true


func _on_menu_match_chosen(path: String) -> void:
	if OS.has_feature("web") and not await WebLibrary.fetch_match(path):
		return
	if not load_match(path):
		menu.show_error("Failed to load %s — is it a scrim-positions CSV?" % path.get_file())
	elif OS.has_feature("web"):
		WebLibrary.report_watched(path)


## The open match was renamed in the library: follow its file.
func _on_menu_match_renamed(old_path: String, new_path: String) -> void:
	if old_path == match_path:
		match_path = new_path
		_update_file_label()


## A library match's audio changed: the open one reloads, as its start (time 0) moves with it.
## Also when a match is marked internal or not: the open one reloads its teams.
func _on_menu_audio_changed(path: String) -> void:
	if path != match_path or data == null:
		return
	var in_menu: bool = menu.visible
	load_match(path)
	menu.visible = in_menu


## A library match's combat logs changed: the open one reloads them.
func _on_menu_logs_changed(path: String) -> void:
	if path == match_path and data != null:
		_load_combat_logs()


## Reads the open match's gamelogs (`MatchLibrary.log_paths`, also next to a CSV outside the
## library) into `data.combat_logs`, synced to it and attributed to its pilots (or as
## `log_pilots` says), and shows the roster's combat columns that have data.
func _load_combat_logs() -> void:
	data.combat_logs = []
	_apply_combat_stats()
	var paths := MatchLibrary.log_paths(match_path)
	if not paths.is_empty() and not data.has_eve_time():
		print("  %d combat log(s) ignored: the CSV has no eve_time column" % paths.size())
		return
	for file: String in paths:
		var gamelog := CombatLog.load_file(file)
		if gamelog == null:
			continue
		gamelog.sync(data, log_pilots.get(file.get_file(), ""))
		data.combat_logs.append(gamelog)
		print("  log %s: %s -> %s, %d entries" % [file.get_file(), gamelog.listener,
			gamelog.pilot if gamelog.pilot != "" else "(unattributed)", gamelog.entries.size()])
	_apply_combat_stats()


## Rebuilds `combat_stats` from `data.combat_logs`; roster columns without data are hidden.
func _apply_combat_stats() -> void:
	combat_stats = CombatStats.from_logs(data.combat_logs, data.podded)
	for id in CombatStats.RATE_IDS + CombatStats.EWAR_IDS:
		roster_table.set_column_available(id, combat_stats.has(id))
	_update_roster_cells()
	_update_damage_breakdowns()


## Saves this match's team swaps and names (and gamelog attributions), if it is in the library.
func _save_meta() -> void:
	if MatchLibrary.contains(match_path):
		var meta := {"teams": team_overrides, "team_names": team_names, "ruleset": ruleset_id}
		if not log_pilots.is_empty():
			meta.log_pilots = log_pilots
		if match_internal:
			meta.internal = true
		MatchLibrary.save_meta(match_path, meta)


## `pilot`'s display name: its alias (see `pilot_names`) or its CSV name.
func _pilot_name(pilot: String) -> String:
	return pilot_names.get(pilot, pilot)


## `team`'s display name in this match: its name here, else its season team's (`TeamDb`), else
## the default.
func _team_name(team: int) -> String:
	if team_names.has(team):
		return team_names[team]
	var id: String = team_sides.get(team, "")
	return TeamDb.team_name(team_db, id) if id != "" else TEAM_NAMES[side_colors.get(team, team)]


## `team`'s colour in this match (see `side_colors`).
func _team_color(team: int) -> Color:
	return TEAM_COLORS[side_colors.get(team, team)]


## `_team_name`, lowercase while it is the default ("blue").
func _team_label(team: int) -> String:
	var name := _team_name(team)
	return name.to_lower() if name == TEAM_NAMES[side_colors.get(team, team)] else name


func _update_file_label() -> void:
	if data == null:
		return
	var counts := {MatchData.Team.BLUE: 0, MatchData.Team.RED: 0, MatchData.Team.UNKNOWN: 0}
	for pilot in data.teams:
		counts[data.teams[pilot]] += 1
	file_label.text = "%s — %d pilots (%s %d / %s %d / unknown %d), %d out of bounds" % [
		match_path.get_file(), ships.size(),
		_team_label(MatchData.Team.BLUE), counts[MatchData.Team.BLUE],
		_team_label(MatchData.Team.RED), counts[MatchData.Team.RED], counts[MatchData.Team.UNKNOWN],
		data.deaths.size(),
	]


## New SDE data: reload the match so sizes and boundary deaths use it, keeping playback state.
func _on_sizes_changed() -> void:
	_reload_match()


## Reloads the open match from its CSV, keeping playback state.
func _reload_match() -> void:
	if data == null:
		return
	var t := time
	var was_playing := playing
	var in_menu: bool = menu.visible
	load_match(match_path)
	menu.visible = in_menu
	_seek(t)
	_set_playing(was_playing)


func _prompt_download(reason: String) -> void:
	download_dialog.dialog_text = "%s\n\nDownload it now (~100 MB) so ships are sized by their real hull radius?" % reason
	if assets_dialog.visible:
		await assets_dialog.visibility_changed
	download_dialog.popup_centered()


func _prompt_assets(reason: String) -> void:
	assets_dialog.dialog_text = "%s\n\nDownload the overview icons now (~18 MB)? Hull models (~1–2 MB each) are then fetched as matches need them." % reason
	if download_dialog.visible:
		await download_dialog.visibility_changed
	assets_dialog.popup_centered()


## Offers the release page if GitHub has a newer release than this build; silent otherwise.
func _check_for_update() -> void:
	var release := await UpdateCheck.check(self)
	if release.is_empty():
		return
	var dialog := ConfirmationDialog.new()
	dialog.title = "Update available"
	dialog.dialog_text = "Scrim Simulator %s is available (you have %s)." % [release.tag, release.local]
	dialog.ok_button_text = "Open release page"
	dialog.cancel_button_text = "Not now"
	dialog.confirmed.connect(OS.shell_open.bind(release.url))
	dialog.visibility_changed.connect(func(): if not dialog.visible: dialog.queue_free())
	download_dialog.get_parent().add_child(dialog)
	for other in [download_dialog, assets_dialog]:
		if other.visible:
			await other.visibility_changed
	dialog.popup_centered()


## New models or icons on disk: redraw ships and markers with them.
func _on_assets_changed() -> void:
	for pilot in ships:
		ships[pilot].ship_type = ""  # Forces `_update_ships` to rebuild the visual.
	_fetch_models()
	_build_mju_markers()


## Queues downloads of the hulls in the loaded match, plus the MJU for the markers.
func _fetch_models() -> void:
	if not models_on:
		return
	var ids := [ShipAssets.MJU_TYPE_ID]
	if data != null:
		for pilot in data.tracks:
			for s in data.tracks[pilot]:
				var id: int = sizes.ship(s.ship_type).get("type_id", 0)
				if id > 0 and not ids.has(id):
					ids.append(id)
	assets.ensure_models(ids)


func _set_models_on(on: bool) -> void:
	if on == models_on:
		return
	models_on = on
	Settings.set_value("display/ship_models", on)
	models_setting.set_pressed_no_signal(on)
	if on:
		assets.start(true, false)
	_apply_visual_mode()


func _set_smooth_on(on: bool) -> void:
	smooth_on = on
	Settings.set_value("display/smooth_motion", on)
	if data != null:
		data.smooth = on


## Movement needed to start the match (`MatchData.load_csv`): the jitter threshold when that
## setting is on, else any change of position.
static func _move_threshold_m() -> float:
	if not Settings.get_value("match/ignore_jitter"):
		return 0.0
	return Settings.get_value("match/jitter_threshold_m")


## Saves a match-start setting and reloads the open match, whose start (time 0) may move.
func _set_match_setting(key: String, value: Variant) -> void:
	Settings.set_value(key, value)
	if data != null:
		load_match(match_path)


## Shows or hides `field` (one of `OVERLAY_FIELDS`) above every ship, and saves it.
func _set_overlay(field: String, on: bool) -> void:
	ship_overlay[field] = on
	Settings.set_value("overlay/" + field, on)
	for pilot in ships:
		ships[pilot].ship_type = ""  # Forces `_update_ships` to redo the icon.


## Switches ships and markers between models + icons and spheres + boxes.
func _apply_visual_mode() -> void:
	markers_box.visible = not models_on
	markers_model.visible = models_on
	if models_on:
		_fetch_models()
		_build_mju_markers()
	for pilot in ships:
		ships[pilot].ship_type = ""


func _process(delta: float) -> void:
	if data == null:
		return
	if playing and not _scrubbing:
		time += delta * speed
		if time >= data.duration:
			time = data.duration
			_set_playing(false)
		elif audio_player.playing:
			var heard := audio_player.get_playback_position() + AudioServer.get_time_since_last_mix() * speed
			if absf(heard - time) > AUDIO_DRIFT_S * maxf(speed, 1.0):
				audio_player.seek(time)
	_update_ships()
	_update_vectors()
	_update_links()
	_update_mjd_trails()
	_update_mjd_spool()
	if tracked != "" and ships[tracked].node.visible:
		camera.set_target(ships[tracked].node.position)
	_update_measure()
	if not _scrubbing:
		timeline.set_value_no_signal(time)
	_update_info()
	_update_roster_cells()
	_update_damage_breakdowns()
	time_label.text = "%s / %s" % [_fmt_time(time), _fmt_time(data.duration)]


func _unhandled_input(event: InputEvent) -> void:
	if menu.visible:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_on_left_click(event)
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_on_right_click(event)
		return
	if event is InputEventMouseMotion:
		_on_mouse_motion(event)
		return
	if not (event is InputEventKey and event.pressed):
		return
	if event.keycode == KEY_ESCAPE:
		_select("")
		return
	if event.keycode == KEY_B:
		boundary_setting.button_pressed = not boundary_setting.button_pressed
		return
	if event.keycode == KEY_M:
		_set_models_on(not models_on)
		return
	if event.keycode == KEY_D:
		_open_all_debug_menu()
		return


## Playback keys are taken here, before the GUI, so a focused button or slider can't swallow
## Space or the arrows; only a focused text field keeps them.
func _input(event: InputEvent) -> void:
	if data == null or menu.visible or not (event is InputEventKey and event.pressed):
		return
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return
	match event.keycode:
		KEY_SPACE:
			if not event.echo:
				_toggle_play()
		KEY_LEFT:
			if event.shift_pressed:
				_seek(time - SKIP_S)
			else:
				_step_tick(-1)
		KEY_RIGHT:
			if event.shift_pressed:
				_seek(time + SKIP_S)
			else:
				_step_tick(1)
		KEY_BRACKETLEFT:
			_jump_event(-1)
		KEY_BRACKETRIGHT:
			_jump_event(1)
		_:
			return
	get_viewport().set_input_as_handled()


# --- ships -------------------------------------------------------------------

func _add_ship(pilot: String) -> void:
	var node := Node3D.new()
	node.name = pilot.validate_node_name()
	var color: Color = _team_color(data.teams.get(pilot, MatchData.Team.UNKNOWN))

	var visual := _sphere()
	node.add_child(visual)

	var icon := _icon()
	node.add_child(icon)

	var select_icon := _icon()
	node.add_child(select_icon)

	var measure_icon := _icon()
	node.add_child(measure_icon)

	var label := _label(color)
	node.add_child(label)

	var vector := _lines_mesh()
	node.add_child(vector)

	var spheres := Node3D.new()
	node.add_child(spheres)

	var mjd_ring := _lines_mesh()
	node.add_child(mjd_ring)
	var mjd_projection := Node3D.new()
	mjd_projection.top_level = true  # drawn in world space
	mjd_projection.visible = false
	var mjd_lines := _lines_mesh()
	mjd_lines.visible = true
	mjd_projection.add_child(mjd_lines)
	var mjd_label := _label(MJD_COLOR)
	mjd_projection.add_child(mjd_label)
	node.add_child(mjd_projection)

	node.visible = false
	ships_root.add_child(node)
	ships[pilot] = {
		"node": node, "visual": visual, "model_id": 0, "icon": icon, "select_icon": select_icon,
		"measure_icon": measure_icon, "label": label,
		"ship_type": "", "radius": 0.0, "dead": false, "color": color, "tint": color,
		"death_t": INF, "death_marker": null, "heading": Quaternion.IDENTITY, "heading_t": -INF,
		"vector": vector, "vector_tip": Vector3.ZERO, "spheres": spheres,
		"mjd_ring": mjd_ring, "mjd_projection": mjd_projection, "mjd_lines": mjd_lines,
		"mjd_label": mjd_label, "mjd_land": Vector3.ZERO,
	}
	_apply_debug(pilot)
	if data.deaths.has(pilot):
		var death: Dictionary = data.deaths[pilot]
		ships[pilot].death_t = death.t
		ships[pilot].death_marker = _death_marker(pilot, death, color)


## An empty, hidden line mesh drawn in its vertex colours over everything.
func _lines_mesh() -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.mesh = ImmediateMesh.new()
	mesh.material_override = vector_material
	mesh.visible = false
	return mesh


func _sphere() -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.mesh = sphere_mesh
	return mesh


## Overview bracket overlay: constant on-screen size, drawn over everything.
static func _icon() -> Sprite3D:
	var icon := Sprite3D.new()
	icon.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	icon.fixed_size = true
	icon.no_depth_test = true
	icon.shaded = false
	icon.render_priority = 1
	icon.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	icon.visible = false
	return icon


## Points the icon at `tex`, sized to `ICON_PX` on screen, or hides it.
func _set_icon(icon: Sprite3D, tex: Texture2D, color: Color) -> void:
	icon.texture = tex
	icon.visible = tex != null
	if tex:
		# A fixed_size sprite is drawn as if it were 1 unit from the camera.
		icon.pixel_size = _units_per_px(1.0) * ICON_PX / tex.get_height()
		icon.modulate = color


## Scene units spanned by one screen pixel at distance `d` from the camera.
func _units_per_px(d: float) -> float:
	return d * 2.0 * tan(deg_to_rad(camera.fov) / 2.0) / get_viewport().get_visible_rect().size.y


func _on_viewport_resized() -> void:
	camera.fit_viewport()
	_rescale_overlays()


## Keeps fixed-size icons and labels at the same UI-pixel size after the FOV or viewport changes
## (the camera's FOV stops growing at `MAX_FOV`, so their units per pixel drift).
func _rescale_overlays() -> void:
	var unit := _units_per_px(1.0)
	if is_equal_approx(unit, _overlay_unit) or _overlay_unit <= 0.0:
		_overlay_unit = unit
		return
	var ratio := unit / _overlay_unit
	_overlay_unit = unit
	for node in find_children("*", "Sprite3D", true, false) + find_children("*", "Label3D", true, false):
		if node.fixed_size:
			node.pixel_size *= ratio


## Sets the interface scale (window content scale), remembering it for next time.
func _set_ui_scale(factor: float) -> void:
	Settings.set_value("display/ui_scale", factor)
	get_window().content_scale_factor = factor
	_on_viewport_resized()
	_fit_roster()


## An X where `pilot` crossed the boundary, labelled with the time.
func _death_marker(pilot: String, death: Dictionary, color: Color) -> Node3D:
	var marker := Node3D.new()
	marker.position = death.pos * M_TO_UNITS
	var bar := BoxMesh.new()
	bar.size = Vector3(4.0, 0.4, 0.4)
	var mat := _material(color, false)
	for angle in [45.0, -45.0]:
		var m := MeshInstance3D.new()
		m.mesh = bar
		m.material_override = mat
		m.rotation_degrees.z = angle
		marker.add_child(m)
	var label := _label(color)
	label.text = "%s ✕ %s" % [pilot, _fmt_time(death.t)]
	marker.add_child(label)
	marker.visible = false
	ships_root.add_child(marker)
	return marker


# --- events ------------------------------------------------------------------

## Fills the timeline strip with the match's events and draws a line for each micro jump.
func _build_events() -> void:
	var marks := []
	for e in data.events:
		marks.append({"t": e.t, "color": EVENT_COLORS[e.kind], "text": _event_text(e, _pilot_name(e.pilot))})
	event_strip.set_marks(marks, data.duration)
	mjd_trails.clear()
	for e in data.events:
		if e.kind == MatchData.Event.MJD:
			mjd_trails.append({"t": e.t, "node": _mjd_trail(e)})


## "03:42 Pilot — Died (Venture)", with the pilot shown as `pilot_name`.
static func _event_text(e: Dictionary, pilot_name: String) -> String:
	var what: String = EVENT_NAMES[e.kind]
	if e.kind == MatchData.Event.MJD:
		what += " %.0f km" % (e.pos.distance_to(e.to_pos) * M_TO_UNITS)
	return "%s %s — %s (%s)" % [_fmt_time(e.t), pilot_name, what, e.ship_type]


## A line from where a micro jump took off to where it landed; hidden until shown by time.
func _mjd_trail(e: Dictionary) -> Node3D:
	var lines := ImmediateMesh.new()
	lines.surface_begin(Mesh.PRIMITIVE_LINES)
	lines.surface_add_vertex(e.pos * M_TO_UNITS)
	lines.surface_add_vertex(e.to_pos * M_TO_UNITS)
	lines.surface_end()
	var mesh := MeshInstance3D.new()
	mesh.mesh = lines
	mesh.material_override = _material(Color(MJD_COLOR, 0.8), false)
	mesh.visible = false
	ships_root.add_child(mesh)
	return mesh


func _update_mjd_trails() -> void:
	for trail in mjd_trails:
		trail.node.visible = time >= trail.t and time - trail.t <= MJD_TRAIL_S


## Draws each micro jump drive spool-up (`mjd_on`): a ring around the ship filling over the
## `MatchData.MJD_SPOOL_S`, and an arrow to where it actually lands (`MatchData.mjd_landing`),
## labelled with the seconds left.
func _update_mjd_spool() -> void:
	for pilot in ships:
		var ship: Dictionary = ships[pilot]
		var spool := -1.0
		if mjd_on and ship.node.visible and time < ship.death_t:
			spool = data.mjd_spool(pilot, time)
		var on := spool >= 0.0
		ship.mjd_ring.visible = on
		if not on:
			ship.mjd_projection.visible = false
			continue
		var pos: Vector3 = ship.node.position
		var r := maxf(ship.radius * 1.5, _units_per_px(camera.global_position.distance_to(pos)) * MJD_RING_PX)
		var ring: ImmediateMesh = ship.mjd_ring.mesh
		ring.clear_surfaces()
		ring.surface_begin(Mesh.PRIMITIVE_LINES)
		_add_ring(ring, Vector3.ZERO, r, 1.0, Color(MJD_COLOR, 0.3))
		for k in [1.0, 1.08, 1.16]:
			_add_ring(ring, Vector3.ZERO, r * k, spool, MJD_COLOR)
		ring.surface_end()

		var land := data.mjd_landing(pilot, time) * M_TO_UNITS
		var dir := pos.direction_to(land)
		ship.mjd_projection.visible = dir != Vector3.ZERO
		if dir == Vector3.ZERO:
			continue
		ship.mjd_land = land
		var land_r := _units_per_px(camera.global_position.distance_to(land)) * MJD_RING_PX
		var lines: ImmediateMesh = ship.mjd_lines.mesh
		lines.clear_surfaces()
		lines.surface_begin(Mesh.PRIMITIVE_LINES)
		lines.surface_set_color(Color(MJD_COLOR, 0.8))
		for p in _arrow_points(pos + dir * r, land - dir * land_r):
			lines.surface_add_vertex(p)
		_add_ring(lines, land, land_r, 1.0, MJD_COLOR)
		_add_ring(lines, land, land_r * 0.3, 1.0, MJD_COLOR)
		lines.surface_end()
		ship.mjd_label.text = "%s MJD %d s" % [_pilot_name(pilot), _mjd_seconds_left(spool)]
		ship.mjd_label.position = land + camera.global_basis.y * land_r * 1.6


## Adds the first `fraction` (clockwise from the top) of a camera-facing circle of `radius` around
## `centre` to `lines` (an open `PRIMITIVE_LINES` surface), in `color`.
func _add_ring(lines: ImmediateMesh, centre: Vector3, radius: float, fraction: float, color: Color) -> void:
	var x := camera.global_basis.x * radius
	var y := camera.global_basis.y * radius
	var n := ceili(MJD_RING_SEGMENTS * fraction)
	lines.surface_set_color(color)
	for j in n:
		for k in [j, j + 1]:
			var a: float = TAU * fraction * k / n
			lines.surface_add_vertex(centre + x * sin(a) + y * cos(a))


## Seeks to the lead-up of the next (`dir` 1) or previous (-1) event from now.
func _jump_event(dir: int) -> void:
	var targets := data.events.map(func(e): return maxf(e.t - EVENT_LEAD_S, 0.0))
	if dir < 0:
		targets.reverse()
	for t in targets:
		if (t > time + 0.05) if dir > 0 else (t < time - 0.05):
			_seek(t)
			return


func _label(color: Color) -> Label3D:
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = true
	label.pixel_size = _units_per_px(1.0) * LABEL_PX
	label.font_size = 24
	label.outline_size = 6
	label.no_depth_test = true
	label.modulate = color
	label.position = Vector3(0, 2.5, 0)
	return label


func _update_ships() -> void:
	for pilot in ships:
		var ship: Dictionary = ships[pilot]
		var dead: bool = time >= ship.death_t
		if ship.death_marker:
			ship.death_marker.visible = dead
		var s := data.sample(pilot, time)
		var node: Node3D = ship.node
		if s.is_empty():
			node.visible = false
			continue
		node.visible = true
		var pos: Vector3 = s.pos * M_TO_UNITS
		node.position = pos
		if s.ship_type != ship.ship_type or dead != ship.dead:
			ship.ship_type = s.ship_type
			ship.radius = data.radius_m(s.ship_type) * M_TO_UNITS
			ship.dead = dead
			var pod: bool = s.ship_type == "Capsule"
			var color: Color = ship.color.darkened(0.5) if pod else ship.color
			if dead:
				color = color.lerp(Color(0.5, 0.5, 0.5), 0.6)
				color.a = 0.4
			ship.tint = color
			_refresh_visual(ship)
			ship.label.modulate = color if not dead else Color(color, 0.7)
		ship.label.text = _ship_label_text(pilot, s, dead)
		ship.label.visible = ship.label.text != ""
		_face_heading(ship, pilot)
		var r: float = ship.radius
		if ship.model_id == 0 or r <= 0.0:
			r = maxf(r, camera.global_position.distance_to(node.position) * MIN_VISIBLE_ANGLE)
		ship.visual.scale = Vector3.ONE * r
		ship.label.position.y = r * 1.6 if not ship.icon.visible else maxf(r * 1.6, _icon_clearance(node))


## The text above `pilot`'s ship for its sample `s`: the `ship_overlay` fields that are on, one
## per line, then DEAD when it has left the arena.
func _ship_label_text(pilot: String, s: Dictionary, dead: bool) -> String:
	var lines := PackedStringArray()
	if ship_overlay.name:
		lines.append(_pilot_name(pilot))
	if ship_overlay.type:
		lines.append(s.ship_type)
	if ship_overlay.distance:
		lines.append("%.1f km" % (s.pos.distance_to(MatchData.CENTRE_M) * M_TO_UNITS))
	if ship_overlay.speed and not is_nan(s.speed):
		lines.append(_fmt_speed(s.speed))
	if dead:
		lines.append("DEAD (out of bounds)")
	return "\n".join(lines)


## Swaps `ship.visual` to the hull model (models on and cached) or the sphere, and tints it.
func _refresh_visual(ship: Dictionary) -> void:
	var info := sizes.ship(ship.ship_type)
	var type_id: int = info.get("type_id", 0) if models_on else 0
	var want := type_id if assets.has_model(type_id) else 0
	if want != ship.model_id or ship.visual == null:
		var visual: Node3D = assets.instance_model(want) if want else null
		if visual == null:
			want = 0
			visual = _sphere()
		if ship.visual:
			ship.visual.queue_free()
		ship.node.add_child(visual)
		ship.visual = visual
		ship.model_id = want
	var color: Color = ship.tint
	if ship.model_id == 0:
		ship.visual.material_override = _material(color, true)
	else:
		for m in ship.visual.find_children("*", "GeometryInstance3D", true, false):
			m.transparency = 0.6 if ship.dead else 0.0
	var tex: Texture2D = null
	if models_on and ship_overlay.icon and info:
		tex = assets.bracket(info.group_id, sizes.ship_groups.get(info.group_id, ""))
	_set_icon(ship.icon, tex, Color(color, maxf(color.a, 0.7)))


## Turns model ships to face along their movement (`_velocity`). Smooth motion eases the turn;
## otherwise it snaps.
func _face_heading(ship: Dictionary, pilot: String) -> void:
	if ship.model_id == 0:
		return
	var target: Quaternion = ship.heading
	var v := _velocity(pilot)
	if v.length() >= MIN_HEADING_SPEED:
		var up := Vector3.UP if absf(v.normalized().y) < 0.99 else Vector3.RIGHT
		target = (Basis.looking_at(v, up) * MODEL_FORWARD).get_rotation_quaternion()
	var dt: float = time - ship.heading_t
	ship.heading_t = time
	if smooth_on and dt > 0.0 and dt <= MAX_TURN_STEP_S:
		ship.heading = ship.heading.slerp(target, 1.0 - exp(-dt / TURN_TIME_S))
	elif smooth_on and dt == 0.0:
		pass  # Paused: hold the current turn.
	else:
		ship.heading = target
	ship.visual.basis = Basis(ship.heading)


## `pilot`'s velocity (m/s) now, from its track. With smooth motion, a straight line fitted either
## side of now (`MatchData.velocity`), as fast as the overview speed when the match has real
## speeds; otherwise over the last half second. ZERO when it can't be told.
func _velocity(pilot: String) -> Vector3:
	if smooth_on:
		var v := data.velocity(pilot, time, true)
		var speed: float = data.sample(pilot, time).get("speed", NAN)
		if data.has_speed and not is_nan(speed) and v != Vector3.ZERO:
			return v.normalized() * speed
		return v
	var prev := data.sample(pilot, time - 0.5)
	var now := data.sample(pilot, time)
	if prev.is_empty() or now.is_empty() or now.t <= prev.t:
		return Vector3.ZERO
	return (now.pos - prev.pos) / (now.t - prev.t)


## Scene units from the node's centre to just above an `ICON_PX` icon at the camera's distance.
func _icon_clearance(node: Node3D) -> float:
	return _units_per_px(camera.global_position.distance_to(node.global_position)) * ICON_PX * 0.75


# --- selection ---------------------------------------------------------------

## Left click selects the ship under the cursor (empty space clears it); a double click also
## follows it. A press on a ship that turns into a drag measures from it (see `_update_measure`);
## one on empty space drags the camera. Neither selects anything.
func _on_left_click(event: InputEventMouseButton) -> void:
	if event.pressed:
		_end_measure()
		_press_pos = event.position
		if event.double_click:
			# The camera jumps to the ship, so the release would miss it: ignore that release.
			_press_pos = Vector2.INF
			var pilot := _pick_ship(event.position)
			if pilot != "":
				_select(pilot)
				_follow(pilot)
			return
		_measure_from = _pick_ship(event.position)
		_measure_mouse = event.position
		camera.rotate_locked = _measure_from != ""
		return
	if not _measuring and event.position.distance_to(_press_pos) <= CLICK_SLOP_PX:
		_select(_pick_ship(event.position))
	_press_pos = Vector2.INF
	_end_measure()


## A left drag that started on a ship measures once it passes `CLICK_SLOP_PX`.
func _on_mouse_motion(event: InputEventMouseMotion) -> void:
	if _measure_from == "":
		return
	_measure_mouse = event.position
	if not _measuring and event.position.distance_to(_press_pos) > CLICK_SLOP_PX:
		_measuring = true
	if _measuring:
		_update_measure()


## The visible ship drawn nearest `screen_pos` within `PICK_PX` (or its on-screen hull), or "";
## never `exclude`.
func _pick_ship(screen_pos: Vector2, exclude := "") -> String:
	var best := ""
	var best_d := INF
	for pilot in ships:
		var node: Node3D = ships[pilot].node
		if pilot == exclude or not node.visible or camera.is_position_behind(node.global_position):
			continue
		var d := camera.unproject_position(node.global_position).distance_to(screen_pos)
		var dist := camera.global_position.distance_to(node.global_position)
		var hull_px: float = ships[pilot].visual.scale.x / _units_per_px(dist)
		if d <= maxf(PICK_PX, hull_px) and d < best_d:
			best = pilot
			best_d = d
	return best


## Right click (not drag: that pans) on a ship opens its debug menu.
func _on_right_click(event: InputEventMouseButton) -> void:
	if event.pressed:
		_right_press_pos = event.position
		return
	if event.position.distance_to(_right_press_pos) <= CLICK_SLOP_PX:
		var pilot := _pick_ship(event.position)
		if pilot != "":
			_open_ship_debug_menu(pilot, event.position)
	_right_press_pos = Vector2.INF


## Selects `pilot` ("" clears): brackets it in space, highlights its roster row and fills the
## info panel.
func _select(pilot: String) -> void:
	selected = pilot
	for p in ships:
		var ship: Dictionary = ships[p]
		var on: bool = p == selected
		_set_icon(ship.select_icon, _select_texture() if on else null, SELECT_COLOR)
		if on:
			ship.select_icon.pixel_size *= SELECT_SCALE
		ship.label.font_size = 30 if on else 24
	for p in roster_buttons:
		_style_roster_button(p)
	if selected != "" and roster_buttons.has(selected):
		roster_table.scroll.ensure_control_visible(roster_buttons[selected])
	_update_info()


## White corner brackets drawn around the selected ship's icon.
func _select_texture() -> Texture2D:
	if select_texture:
		return select_texture
	const N := 64
	const ARM := 18
	const W := 4
	var img := Image.create(N, N, false, Image.FORMAT_RGBA8)
	for corner in [Vector2i(0, 0), Vector2i(N - ARM, 0), Vector2i(0, N - W), Vector2i(N - ARM, N - W)]:
		img.fill_rect(Rect2i(corner, Vector2i(ARM, W)), Color.WHITE)
	for corner in [Vector2i(0, 0), Vector2i(N - W, 0), Vector2i(0, N - ARM), Vector2i(N - W, N - ARM)]:
		img.fill_rect(Rect2i(corner, Vector2i(W, ARM)), Color.WHITE)
	select_texture = ImageTexture.create_from_image(img)
	return select_texture


## Gives the selected pilot's roster row a tinted background.
func _style_roster_button(pilot: String) -> void:
	var button: Button = roster_buttons[pilot]
	if pilot != selected:
		button.flat = true
		button.remove_theme_stylebox_override("normal")
		button.remove_theme_stylebox_override("hover")
		return
	var box := StyleBoxFlat.new()
	box.bg_color = Color(ships[pilot].color, 0.25)
	box.set_corner_radius_all(3)
	button.flat = false
	button.add_theme_stylebox_override("normal", box)
	button.add_theme_stylebox_override("hover", box)


## Shows the selected pilot's ship, team, speed and position in the info panel.
func _update_info() -> void:
	info_panel.visible = selected != "" and data != null
	if not info_panel.visible:
		return
	var team: int = data.teams.get(selected, MatchData.Team.UNKNOWN)
	var lines := PackedStringArray()
	lines.append("%s — %s" % [_pilot_name(selected), _team_name(team)])
	var now := data.sample(selected, time)
	if now.is_empty():
		lines.append("Not on grid")
	else:
		lines.append(now.ship_type)
		var motion := _motion(selected)
		if not is_nan(motion.speed):
			lines.append("Speed: %s" % _fmt_speed(motion.speed))
		var d: float = motion.dist_km
		lines.append("From centre: %.1f km (boundary %.1f km)" % [d, BOUNDARY_KM - d])
		var exit := data.plane_exit_at(selected, time)
		if not exit.is_empty():
			lines.append("Plane exit %d: %s" % [exit.id, DebugMenu.turn_name(exit.turn)])
	var ship: Dictionary = ships[selected]
	for e in data.events:
		if e.pilot == selected and e.kind == MatchData.Event.DEATH and time >= e.t:
			lines.append("Died at %s (lost %s)" % [_fmt_time(e.t), e.ship_type])
	if time >= ship.death_t:
		lines.append("DEAD (out of bounds at %s)" % _fmt_time(ship.death_t))
	lines.append("Following" if tracked == selected else "Double-click to follow")
	info_label.text = "\n".join(lines)
	info_label.modulate = _team_color(team).lerp(Color.WHITE, 0.5)


## `pilot`'s ship type, speed (m/s from the CSV's latest sample; NAN if unknown) and distance
## from the centre (km) at the current time, or {} when it isn't on grid.
func _motion(pilot: String) -> Dictionary:
	var now := data.sample(pilot, time)
	if now.is_empty():
		return {}
	return {
		"ship_type": now.ship_type,
		"speed": now.speed,
		"dist_km": now.pos.distance_to(MatchData.CENTRE_M) * M_TO_UNITS,
	}


# --- measuring ---------------------------------------------------------------

func _build_measure() -> void:
	measure_root = Node3D.new()
	measure_root.visible = false
	add_child(measure_root)
	measure_root.add_child(_range_sphere(1.0, MEASURE_COLOR, 0.35, 48, 6, 3))
	measure_line = MeshInstance3D.new()
	measure_line.mesh = ImmediateMesh.new()
	measure_line.material_override = vector_material
	measure_line.visible = false
	add_child(measure_line)
	measure_label = _label(MEASURE_COLOR)
	measure_label.visible = false
	add_child(measure_label)


## Stops measuring: hides the sphere, line, label and brackets and gives the camera back its drag.
func _end_measure() -> void:
	_measure_from = ""
	_measuring = false
	if camera:
		camera.rotate_locked = false
	if measure_root == null:
		return
	measure_root.visible = false
	measure_line.visible = false
	measure_label.visible = false
	for pilot in ships:
		ships[pilot].measure_icon.visible = false


## Redraws the measuring sphere around `_measure_from`. Its radius reaches the cursor (on the
## plane through the ship facing the camera), or, with the cursor on another ship, that ship's
## near hull, labelled with the hull-to-hull gap. Ships whose hulls it reaches are bracketed.
func _update_measure() -> void:
	if not _measuring:
		return
	if not ships.has(_measure_from) or not ships[_measure_from].node.visible:
		_end_measure()
		return
	var from: Dictionary = ships[_measure_from]
	var o: Vector3 = from.node.position
	var radius: float = measure_root.scale.x if measure_root.visible else 0.0
	var a := o
	var b := o
	var text := ""
	var snap := _pick_ship(_measure_mouse, _measure_from)
	if snap != "":
		var to: Dictionary = ships[snap]
		var t: Vector3 = to.node.position
		var d := o.distance_to(t)
		var dir := (t - o).normalized()
		radius = maxf(d - to.radius, 0.0)
		a = o + dir * minf(from.radius, d)
		b = o + dir * radius
		text = "%s\nr %s" % [_fmt_km_m(maxf(d - from.radius - to.radius, 0.0)), _fmt_km_m(radius)]
	else:
		var hit: Variant = Plane(camera.global_basis.z, o).intersects_ray(
			camera.project_ray_origin(_measure_mouse), camera.project_ray_normal(_measure_mouse))
		if hit != null:
			radius = o.distance_to(hit)
		b = o + ((hit - o).normalized() if hit != null and radius > 0.0 else Vector3.ZERO) * radius
		text = "r %s" % _fmt_km_m(radius)
	measure_root.position = o
	measure_root.scale = Vector3.ONE * maxf(radius, 1e-4)
	measure_root.visible = true
	var lines: ImmediateMesh = measure_line.mesh
	lines.clear_surfaces()
	if a != b:
		lines.surface_begin(Mesh.PRIMITIVE_LINES)
		lines.surface_set_color(MEASURE_COLOR)
		lines.surface_add_vertex(a)
		lines.surface_add_vertex(b)
		lines.surface_end()
	measure_line.visible = true
	measure_label.text = text
	measure_label.position = (a + b) / 2.0 if snap != "" else b
	measure_label.visible = true
	for pilot in ships:
		var ship: Dictionary = ships[pilot]
		var inside: bool = pilot != _measure_from and ship.node.visible \
			and _in_sphere(o.distance_to(ship.node.position), ship.radius, radius)
		if inside != ship.measure_icon.visible:
			_set_icon(ship.measure_icon, _select_texture() if inside else null, MEASURE_COLOR)
			if inside:
				ship.measure_icon.pixel_size *= MEASURE_SCALE


## Whether a hull of radius `ship_r` whose centre is `dist` from a sphere's centre reaches into a
## sphere of `radius` (touching counts).
static func _in_sphere(dist: float, ship_r: float, radius: float) -> bool:
	return dist - ship_r <= radius + 1e-6


## A distance in scene units (km) to the metre: "12.345 km", or "850 m" under 1 km.
static func _fmt_km_m(km: float) -> String:
	var m := roundi(km * 1000.0)
	if m < 1000:
		return "%d m" % m
	return "%d.%03d km" % [m / 1000, m % 1000]


# --- debug overlays ----------------------------------------------------------

## `pilot`'s debug state, created empty on first use.
func _debug(pilot: String) -> Dictionary:
	if not debug.has(pilot):
		debug[pilot] = {"vector": false, "spheres": []}
	return debug[pilot]


## Rebuilds `pilot`'s range spheres and shows or hides its movement vector from `debug`.
func _apply_debug(pilot: String) -> void:
	var ship: Dictionary = ships[pilot]
	var state: Dictionary = debug.get(pilot, {"vector": false, "spheres": []})
	for c in ship.spheres.get_children():
		ship.spheres.remove_child(c)
		c.queue_free()
	for sphere in state.spheres:
		ship.spheres.add_child(_range_sphere(sphere.radius_km, sphere.color, 0.35, 48, 6, 3))
	ship.vector.visible = state.vector


## Redraws each shown movement vector: a line from the ship to where it will be in
## `vector_seconds` at its current velocity, with an arrowhead; nothing when (nearly) stopped.
func _update_vectors() -> void:
	for pilot in ships:
		var ship: Dictionary = ships[pilot]
		if not ship.vector.visible or not ship.node.visible:
			continue
		var lines: ImmediateMesh = ship.vector.mesh
		lines.clear_surfaces()
		var v := _velocity(pilot)
		if v.length() < MIN_HEADING_SPEED:
			ship.vector_tip = Vector3.ZERO
			continue
		var tip := v * vector_seconds * M_TO_UNITS
		ship.vector_tip = tip
		lines.surface_begin(Mesh.PRIMITIVE_LINES)
		lines.surface_set_color(Color(ship.tint, 1.0))
		for p in _arrow_points(Vector3.ZERO, tip):
			lines.surface_add_vertex(p)
		lines.surface_end()


## Line vertex pairs of an arrow from `from` to `to`: the shaft, then an arrowhead
## `ARROW_FRACTION` of its length.
static func _arrow_points(from: Vector3, to: Vector3) -> Array:
	var dir := (to - from).normalized()
	var side := dir.cross(Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT).normalized()
	var head := from.distance_to(to) * ARROW_FRACTION
	return [from, to, to, to - (dir - side * 0.5) * head, to, to - (dir + side * 0.5) * head]


## Redraws the activity lines active now (`CombatStats.links_at`) between visible ships: dashes
## flowing from source to target in the kind's colour, each fading in from its tail, with an
## arrowhead short of the target. Kinds joining the same two ships are drawn side by side.
func _update_links() -> void:
	var lines: ImmediateMesh = links_mesh.mesh
	lines.clear_surfaces()
	var active := combat_stats.links_at(time)
	if active.is_empty():
		return
	var flow := Time.get_ticks_msec() / 1000.0 * LINK_FLOW_PX_S
	var began := false
	for l in active:
		var state: Dictionary = links.get(l.kind, {})
		if not state.get("on", false) or not ships.has(l.source) or not ships.has(l.target):
			continue
		var a: Node3D = ships[l.source].node
		var b: Node3D = ships[l.target].node
		if not a.visible or not b.visible:
			continue
		var mid := (a.position + b.position) / 2.0
		var px := _units_per_px(camera.global_position.distance_to(mid))
		var along := b.position - a.position
		var length := along.length()
		if length < px:
			continue
		var dir := along / length
		var side := dir.cross(camera.global_position - mid).normalized()
		var offset := side * (CombatStats.LINK_KINDS.find(l.kind) - (CombatStats.LINK_KINDS.size() - 1) / 2.0) * LINK_SPACING_PX * px
		var from := a.position + offset + dir * _icon_clearance(a) * 0.6
		var to := b.position + offset - dir * _icon_clearance(b)
		var span := (to - from).dot(dir)
		if span <= 0.0:
			continue
		if not began:
			lines.surface_begin(Mesh.PRIMITIVE_LINES)
			began = true
		var color: Color = state.color
		var tail := Color(color, LINK_TAIL_ALPHA)
		var period := (LINK_DASH_PX + LINK_GAP_PX) * px
		var d := fmod(flow * px, period) - period
		while d < span:
			var d0 := maxf(d, 0.0)
			var d1 := minf(d + LINK_DASH_PX * px, span)
			if d1 > d0:
				lines.surface_set_color(tail.lerp(color, (d0 - d) / (LINK_DASH_PX * px)))
				lines.surface_add_vertex(from + dir * d0)
				lines.surface_set_color(tail.lerp(color, (d1 - d) / (LINK_DASH_PX * px)))
				lines.surface_add_vertex(from + dir * d1)
			d += period
		var head := LINK_HEAD_PX * px
		var wing := side * head * 0.5
		lines.surface_set_color(color)
		for p in [to, to - dir * head + wing, to, to - dir * head - wing]:
			lines.surface_add_vertex(p)
	if began:
		lines.surface_end()


func _set_link(kind: String, on: bool) -> void:
	links[kind].on = on
	Settings.set_value("links/" + kind, on)


func _set_link_color(kind: String, color: Color) -> void:
	links[kind].color = color
	Settings.set_value("links/%s_color" % kind, color)


func _set_vector(pilot: String, on: bool) -> void:
	_debug(pilot).vector = on
	_apply_debug(pilot)


func _add_sphere(pilot: String, radius_km: float, color: Color) -> void:
	_debug(pilot).spheres.append({"radius_km": radius_km, "color": color})
	_apply_debug(pilot)


func _remove_sphere(pilot: String, index: int) -> void:
	_debug(pilot).spheres.remove_at(index)
	_apply_debug(pilot)


func _clear_spheres() -> void:
	for pilot in ships:
		_debug(pilot).spheres.clear()
		_apply_debug(pilot)


func _set_beacon_range(centre: bool, on: bool) -> void:
	(beacon_ranges_centre if centre else beacon_ranges_corner).visible = on


func _open_ship_debug_menu(pilot: String, at: Vector2) -> void:
	debug_pilot = pilot
	_refresh_ship_debug_menu()
	ship_debug_menu.open_at(at)


func _refresh_ship_debug_menu() -> void:
	var state := _debug(debug_pilot)
	ship_debug_menu.show_state(_pilot_name(debug_pilot), state.vector, state.spheres,
			combat_stats.has("dmg_in"), data.plane_exit_at(debug_pilot, time))


func _open_all_debug_menu() -> void:
	_refresh_all_debug_menu()
	all_debug_menu.open_at(get_viewport().get_visible_rect().size / 2.0 - Vector2(150, 150))


func _refresh_all_debug_menu() -> void:
	var all_on := not ships.is_empty() and ships.keys().all(func(p): return _debug(p).vector)
	all_debug_menu.show_state("Debug — all ships", all_on, [])
	all_debug_menu.show_links(links)


## The two debug menus; their signals change `debug` and redraw the overlays.
func _build_debug_menus(layer: CanvasLayer) -> void:
	ship_debug_menu = DebugMenu.new()
	layer.add_child(ship_debug_menu)
	var for_ship := func(f: Callable):
		if ships.has(debug_pilot):
			f.call()
			_refresh_ship_debug_menu()
	ship_debug_menu.vector_toggled.connect(func(on): for_ship.call(func(): _set_vector(debug_pilot, on)))
	ship_debug_menu.sphere_added.connect(func(r, c): for_ship.call(func(): _add_sphere(debug_pilot, r, c)))
	ship_debug_menu.sphere_removed.connect(func(i): for_ship.call(func(): _remove_sphere(debug_pilot, i)))
	ship_debug_menu.rename_requested.connect(func(): _ask_rename_pilot(debug_pilot))
	ship_debug_menu.damage_breakdown_requested.connect(func():
		_open_damage_breakdown(layer, debug_pilot, ship_debug_menu.position))
	ship_debug_menu.plane_exit_flip_requested.connect(func(id): _flip_plane_exit(debug_pilot, id))

	all_debug_menu = DebugMenu.new(true)
	all_debug_menu.seconds_spin.set_value_no_signal(vector_seconds)
	layer.add_child(all_debug_menu)
	all_debug_menu.vector_toggled.connect(func(on):
		for pilot in ships:
			_set_vector(pilot, on))
	all_debug_menu.sphere_added.connect(func(r, c):
		for pilot in ships:
			_add_sphere(pilot, r, c))
	all_debug_menu.spheres_cleared.connect(_clear_spheres)
	all_debug_menu.vector_seconds_changed.connect(func(sec): vector_seconds = sec)
	all_debug_menu.beacon_range_toggled.connect(_set_beacon_range)
	all_debug_menu.link_toggled.connect(_set_link)
	all_debug_menu.link_color_changed.connect(_set_link_color)


## Mirrors `pilot`'s plane exit `id` to the other side of the observers' plane in the open
## match's CSV (the library copy, or the file opened with `--csv`) and reloads it.
func _flip_plane_exit(pilot: String, id: int) -> void:
	if not MatchData.flip_plane_exit(match_path, pilot, id):
		file_label.text = "Couldn't flip the plane exit in %s" % match_path.get_file()
		return
	_reload_match()
	if OS.has_feature("web"):
		WebLibrary.local_changed()


## Opens a new damage breakdown window for `pilot` with its top-left corner near `at` (kept on
## screen) under `layer`.
func _open_damage_breakdown(layer: CanvasLayer, pilot: String, at: Vector2) -> void:
	var w := DamageBreakdown.new(pilot)
	var view := Vector2i(get_viewport().get_visible_rect().size)
	var pos := Vector2i(at) + Vector2i(24, 24) * (breakdown_windows.size() % 8)
	w.position = pos.clamp(Vector2i(0, 32), (view - w.size).max(Vector2i(0, 32)))
	layer.add_child(w)
	breakdown_windows.append(w)
	w.tree_exiting.connect(func(): breakdown_windows.erase(w))
	_update_damage_breakdowns()
	w.show()


## Refreshes every open damage breakdown window: incoming DPS on its pilot now, per attacker.
## Hidden while the main menu covers the viewer.
func _update_damage_breakdowns() -> void:
	for w in breakdown_windows:
		w.visible = not menu.visible
		if data == null or not w.visible:
			continue
		var rows := []
		var total := 0.0
		for r in combat_stats.damage_in_by_source(w.pilot, time):
			var motion := _motion(r.pilot) if data.tracks.has(r.pilot) else {}
			var ship: String = motion.get("ship_type", data.tracks[r.pilot][0].ship_type if data.tracks.has(r.pilot) else "")
			var team: int = data.teams.get(r.pilot, MatchData.Team.UNKNOWN)
			rows.append({"name": _pilot_name(r.pilot), "ship": ship, "color": _team_color(team), "dps": r.dps})
			total += r.dps
		w.show_rows("Incoming DPS — %s" % _pilot_name(w.pilot), total, rows)


# --- playback ----------------------------------------------------------------

func _seek(t: float) -> void:
	if data == null:
		return
	time = clampf(t, 0.0, data.duration)
	timeline.set_value_no_signal(time)
	_sync_audio()


## Pauses and moves to the next (`dir` 1) or previous (-1) whole tick.
func _step_tick(dir: int) -> void:
	_set_playing(false)
	var tick := floorf(time / TICK_S + 0.001) + 1.0 if dir > 0 else ceilf(time / TICK_S - 0.001) - 1.0
	_seek(tick * TICK_S)


func _toggle_play() -> void:
	if data == null:
		return
	if not playing and time >= data.duration:
		time = 0.0
	_set_playing(not playing)


func _set_playing(p: bool) -> void:
	playing = p
	if p:
		start_button.visible = false
	play_button.text = "Pause" if p else "Play"
	_sync_audio()


## Starts the match audio at `time` while playing (and not scrubbing), else stops it.
func _sync_audio() -> void:
	if audio_player == null or audio_player.stream == null:
		return
	if playing and not _scrubbing and time < audio_player.stream.get_length():
		audio_player.play(time)
	else:
		audio_player.stop()


## Plays the match audio `speed` times faster without changing its pitch.
func _set_speed(s: float) -> void:
	speed = s
	audio_player.pitch_scale = s
	audio_pitch.pitch_scale = 1.0 / s


static func _fmt_time(t: float) -> String:
	var s := int(t)
	return "%02d:%02d" % [s / 60, s % 60]


## Broadcast clock: like `_fmt_time`, but counts down to the match start (`t` < 0) as "-mm:ss",
## rounding up so it reaches "00:00" as the first ship moves.
static func _fmt_clock(t: float) -> String:
	return "-" + _fmt_time(ceilf(-t)) if t < 0.0 else _fmt_time(t)


## Speed (m/s) for display: whole m/s below 1 km/s, else km/s to 1 decimal. Rounds first so
## 999.5 shows as 1.0 km/s, never 1000 m/s.
static func _fmt_speed(mps: float) -> String:
	if roundf(mps) >= 1000.0:
		return "%.1f km/s" % (mps / 1000.0)
	return "%.0f m/s" % mps


# --- scene -------------------------------------------------------------------

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.03, 0.035, 0.05)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.5, 0.55)
	env.ambient_light_energy = 0.6
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)

	camera = Camera3D.new()
	camera.set_script(preload("res://scripts/orbit_camera.gd"))
	camera.target = Vector3.ONE * CUBE / 2.0
	add_child(camera)
	camera.panned.connect(func(): _set_tracked(""))


## Positions of the 8 corner markers, then the centre one.
static func _marker_positions() -> Array:
	var out := []
	for i in 8:
		out.append(Vector3(i & 1, (i >> 1) & 1, (i >> 2) & 1) * CUBE)
	out.append(Vector3.ONE * CUBE / 2.0)
	return out


func _build_markers() -> void:
	markers_box = Node3D.new()
	add_child(markers_box)
	markers_model = Node3D.new()
	add_child(markers_model)
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 2.0
	var corner_mat := _material(CORNER_COLOR, false)
	var centre_mat := _material(CENTRE_COLOR, false)
	var positions := _marker_positions()
	for i in positions.size():
		var m := MeshInstance3D.new()
		m.mesh = box
		m.material_override = corner_mat if i < 8 else centre_mat
		m.position = positions[i]
		markers_box.add_child(m)

	beacon_ranges_corner = Node3D.new()
	beacon_ranges_corner.visible = false
	add_child(beacon_ranges_corner)
	beacon_ranges_centre = Node3D.new()
	beacon_ranges_centre.visible = false
	add_child(beacon_ranges_centre)
	for i in positions.size():
		var color := CORNER_COLOR if i < 8 else CENTRE_COLOR
		var sphere := _range_sphere(BEACON_JUMP_KM, color, 0.35, 48, 6, 3)
		sphere.position = positions[i]
		(beacon_ranges_corner if i < 8 else beacon_ranges_centre).add_child(sphere)

	# Cube edges, for orientation.
	var lines := ImmediateMesh.new()
	lines.surface_begin(Mesh.PRIMITIVE_LINES)
	for a in 8:
		for axis in 3:
			var b := a | (1 << axis)
			if b != a:
				lines.surface_add_vertex(Vector3(a & 1, (a >> 1) & 1, (a >> 2) & 1) * CUBE)
				lines.surface_add_vertex(Vector3(b & 1, (b >> 1) & 1, (b >> 2) & 1) * CUBE)
	lines.surface_end()
	var edges := MeshInstance3D.new()
	edges.mesh = lines
	var line_mat := StandardMaterial3D.new()
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.albedo_color = Color(0.3, 0.5, 0.7, 0.5)
	line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	edges.material_override = line_mat
	add_child(edges)


## (Re)builds the MJU marker set from whatever model and icon are cached; boxes stand in for a
## missing model.
func _build_mju_markers() -> void:
	if not models_on:
		return
	for c in markers_model.get_children():
		c.queue_free()
	var tex := assets.bracket_texture(ShipAssets.MJU_BRACKET)
	var positions := _marker_positions()
	for i in positions.size():
		var color := CORNER_COLOR if i < 8 else CENTRE_COLOR
		var marker := Node3D.new()
		marker.position = positions[i]
		var model: Node3D = assets.instance_model(ShipAssets.MJU_TYPE_ID)
		if model:
			model.scale = Vector3.ONE * MJU_RADIUS_KM
		else:
			model = markers_box.get_child(i).duplicate()
		marker.add_child(model)
		var icon := _icon()
		marker.add_child(icon)
		_set_icon(icon, tex, color)
		markers_model.add_child(marker)


## Arena boundary, centred on the cube.
func _build_boundary() -> void:
	boundary = _range_sphere(BOUNDARY_KM, BOUNDARY_COLOR, 0.25, 96, 8, 5)
	boundary.position = Vector3.ONE * CUBE / 2.0
	add_child(boundary)


## A sphere of `radius` (scene units) drawn as `meridians` + `parallels` wire circles of
## `segments` lines each (at `wire_alpha`), plus a faint shell.
static func _range_sphere(radius: float, color: Color, wire_alpha: float, segments: int,
		meridians: int, parallels: int) -> Node3D:
	var root := Node3D.new()
	var lines := ImmediateMesh.new()
	lines.surface_begin(Mesh.PRIMITIVE_LINES)
	for k in meridians:
		var lon := PI * k / meridians
		for j in segments:
			for a in [TAU * j / segments, TAU * (j + 1) / segments]:
				lines.surface_add_vertex(Vector3(cos(a) * cos(lon), sin(a), cos(a) * sin(lon)) * radius)
	for k in parallels:
		var lat := PI * (k + 1) / (parallels + 1) - PI / 2.0
		for j in segments:
			for a in [TAU * j / segments, TAU * (j + 1) / segments]:
				lines.surface_add_vertex(Vector3(cos(a) * cos(lat), sin(lat), sin(a) * cos(lat)) * radius)
	lines.surface_end()
	var wire := MeshInstance3D.new()
	wire.mesh = lines
	wire.material_override = _material(Color(color, wire_alpha), false)
	root.add_child(wire)

	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = segments * 2 / 3
	sphere.rings = segments / 3
	var shell_mat := _material(Color(color, 0.04), false)
	shell_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var shell := MeshInstance3D.new()
	shell.mesh = sphere
	shell.material_override = shell_mat
	root.add_child(shell)
	return root


static func _material(color: Color, shaded: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if color.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if not shaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


# --- UI ----------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	bottom_panel = PanelContainer.new()
	bottom_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bottom_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	layer.add_child(bottom_panel)

	var box := VBoxContainer.new()
	bottom_panel.add_child(box)

	var row := HBoxContainer.new()
	box.add_child(row)

	var menu_button := Button.new()
	menu_button.text = "Menu"
	menu_button.tooltip_text = "Back to the match list"
	menu_button.pressed.connect(_show_menu)
	row.add_child(menu_button)

	play_button = Button.new()
	play_button.text = "Play"
	play_button.custom_minimum_size.x = 70
	play_button.pressed.connect(_toggle_play)
	row.add_child(play_button)

	var speed_option := OptionButton.new()
	for s in SPEEDS:
		speed_option.add_item("%sx" % s)
	speed_option.select(SPEEDS.find(1.0))
	speed_option.item_selected.connect(func(idx): _set_speed(SPEEDS[idx]))
	row.add_child(speed_option)

	mute_button = Button.new()
	mute_button.text = "Mute"
	mute_button.toggle_mode = true
	mute_button.button_pressed = muted
	mute_button.toggled.connect(_set_muted)
	row.add_child(mute_button)
	_update_mute_button()

	time_label = Label.new()
	time_label.text = "--:-- / --:--"
	row.add_child(time_label)

	for kind in EVENT_COLORS:
		var key := Label.new()
		key.text = "▮ %s" % EVENT_NAMES[kind]
		key.modulate = EVENT_COLORS[kind]
		key.tooltip_text = "Timeline marker colour ([ / ] jump between events)"
		key.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_child(key)

	var settings_button := Button.new()
	settings_button.text = "Settings…"
	settings_button.pressed.connect(func(): settings_popup.popup_centered())
	row.add_child(settings_button)

	var debug_button := Button.new()
	debug_button.text = "Debug…"
	debug_button.tooltip_text = "Movement vectors and range spheres for every ship, beacon jump range (D).\nRight-click a ship or roster row for its own."
	debug_button.pressed.connect(_open_all_debug_menu)
	row.add_child(debug_button)

	hotkeys_button = Button.new()
	hotkeys_button.text = "Hotkeys…"
	hotkeys_button.toggle_mode = true
	hotkeys_button.tooltip_text = "Show every hotkey and mouse control (top left)"
	hotkeys_button.toggled.connect(func(on): hotkeys_panel.visible = on)
	row.add_child(hotkeys_button)

	broadcast_button = Button.new()
	broadcast_button.text = "Broadcast"
	broadcast_button.toggle_mode = true
	broadcast_button.button_pressed = broadcast_on
	broadcast_button.tooltip_text = "Broadcast-style ship data panel instead of the roster table"
	broadcast_button.toggled.connect(_set_broadcast_on)
	row.add_child(broadcast_button)

	damage_button = Button.new()
	damage_button.text = "Damage"
	damage_button.toggle_mode = true
	damage_button.button_pressed = damage_on
	damage_button.toggled.connect(_set_damage_on)
	row.add_child(damage_button)
	_update_damage_controls()

	mjd_button = Button.new()
	mjd_button.text = "MJD"
	mjd_button.toggle_mode = true
	mjd_button.button_pressed = mjd_on
	mjd_button.tooltip_text = "Show micro jump drive spool-ups in space: a ring around the ship and where it lands"
	mjd_button.toggled.connect(_set_mjd_on)
	row.add_child(mjd_button)

	ruleset_option = OptionButton.new()
	ruleset_option.tooltip_text = "Ruleset the broadcast panel's points follow"
	for id in Ruleset.available():
		ruleset_option.add_item(Ruleset.load_id(id).name)
		ruleset_option.set_item_metadata(ruleset_option.item_count - 1, id)
	ruleset_option.item_selected.connect(func(i): _set_ruleset(ruleset_option.get_item_metadata(i)))
	row.add_child(ruleset_option)

	sde_label = Label.new()
	sde_label.modulate = Color(1, 1, 1, 0.6)
	row.add_child(sde_label)

	file_label = Label.new()
	file_label.text = "No match loaded — pick one from the Menu or drop a *.positions.csv"
	file_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	file_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(file_label)

	event_strip = EventStrip.new()
	event_strip.mark_pressed.connect(func(i): _seek(event_strip.marks[i].t - EVENT_LEAD_S))
	box.add_child(event_strip)

	timeline = HSlider.new()
	timeline.step = 0.0
	timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline.value_changed.connect(_seek)
	timeline.drag_started.connect(func():
		_scrubbing = true
		_sync_audio())
	timeline.drag_ended.connect(func(_changed):
		_scrubbing = false
		_sync_audio())
	box.add_child(timeline)
	event_strip.slider = timeline

	start_button = Button.new()
	start_button.text = "Start"
	start_button.custom_minimum_size = Vector2(200, 70)
	start_button.add_theme_font_size_override("font_size", 32)
	start_button.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	start_button.grow_horizontal = Control.GROW_DIRECTION_BOTH
	start_button.grow_vertical = Control.GROW_DIRECTION_BOTH
	start_button.visible = false
	start_button.pressed.connect(_set_playing.bind(true))
	layer.add_child(start_button)

	download_dialog = ConfirmationDialog.new()
	download_dialog.title = "EVE Static Data Export"
	download_dialog.ok_button_text = "Download"
	download_dialog.cancel_button_text = "Not now"
	download_dialog.confirmed.connect(sizes.full_download)
	layer.add_child(download_dialog)

	assets_dialog = ConfirmationDialog.new()
	assets_dialog.title = "EVE ship models"
	assets_dialog.ok_button_text = "Download"
	assets_dialog.cancel_button_text = "Not now"
	assets_dialog.confirmed.connect(assets.full_download)
	layer.add_child(assets_dialog)

	# Hotkeys list and the selected ship's details, stacked top left.
	var top_left := VBoxContainer.new()
	top_left.position = Vector2(12, 12)
	top_left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_left.add_theme_constant_override("separation", 8)
	layer.add_child(top_left)
	hotkeys_panel = HotkeysPanel.new()
	top_left.add_child(hotkeys_panel)
	info_panel = PanelContainer.new()
	info_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_panel.visible = false
	top_left.add_child(info_panel)
	info_label = Label.new()
	info_panel.add_child(info_label)

	_build_settings(layer)
	_build_overlay_menu(layer)
	_build_roster(layer)
	_build_debug_menus(layer)

	rename_dialog = RenameDialog.new()
	rename_dialog.submitted.connect(func(text): _rename_target.call(text))
	layer.add_child(rename_dialog)

	# Above every other control, so the menu hides the bar, roster and start button.
	var menu_layer := CanvasLayer.new()
	menu_layer.layer = 10
	add_child(menu_layer)
	menu = MainMenu.new()
	menu.visible = false
	menu.match_chosen.connect(_on_menu_match_chosen)
	menu.resumed.connect(func(): menu.visible = false)
	menu.match_renamed.connect(_on_menu_match_renamed)
	menu.audio_changed.connect(_on_menu_audio_changed)
	menu.internal_changed.connect(_on_menu_audio_changed)
	menu.logs_changed.connect(_on_menu_logs_changed)
	menu_layer.add_child(menu)


func _build_audio() -> void:
	var bus := AudioServer.get_bus_index(AUDIO_BUS)
	if bus < 0:
		AudioServer.add_bus()
		bus = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus, AUDIO_BUS)
		AudioServer.add_bus_effect(bus, AudioEffectPitchShift.new())
	audio_pitch = AudioServer.get_bus_effect(bus, 0)
	audio_pitch.pitch_scale = 1.0
	AudioServer.set_bus_mute(bus, muted)
	audio_player = AudioStreamPlayer.new()
	audio_player.bus = AUDIO_BUS
	# Web defaults to sample playback, which skips bus effects (and so the pitch fix).
	audio_player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	add_child(audio_player)


func _build_settings(layer: CanvasLayer) -> void:
	settings_popup = OpaquePopup.new()
	layer.add_child(settings_popup)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	settings_popup.add_child(box)

	var title := Label.new()
	title.text = "Settings"
	box.add_child(title)

	var auto_update := CheckBox.new()
	auto_update.text = "Check for EVE static data (SDE) and ship model updates on startup"
	auto_update.button_pressed = Settings.get_value("sde/auto_update")
	auto_update.toggled.connect(func(on): Settings.set_value("sde/auto_update", on))
	box.add_child(auto_update)

	models_setting = CheckBox.new()
	models_setting.text = "Draw ships as hull models with overview icons (instead of spheres) (M)"
	models_setting.button_pressed = models_on
	models_setting.toggled.connect(_set_models_on)
	box.add_child(models_setting)

	boundary_setting = CheckBox.new()
	boundary_setting.text = "Show the 125 km arena boundary (B)"
	boundary_setting.button_pressed = boundary.visible
	boundary_setting.toggled.connect(func(on): boundary.visible = on)
	box.add_child(boundary_setting)

	var overlay_button := Button.new()
	overlay_button.text = "Ship overlay…"
	overlay_button.tooltip_text = "Choose what is shown above each ship: name, type, distance, speed, icon."
	overlay_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	overlay_button.pressed.connect(func(): overlay_popup.popup_centered())
	box.add_child(overlay_button)

	damage_setting = CheckBox.new()
	damage_setting.text = "Highlight ships taking damage in the roster (HP dropping)"
	damage_setting.button_pressed = damage_on
	damage_setting.toggled.connect(_set_damage_on)
	box.add_child(damage_setting)

	mjd_setting = CheckBox.new()
	mjd_setting.text = "Show micro jump drive spool-ups in space (ring, landing)"
	mjd_setting.button_pressed = mjd_on
	mjd_setting.toggled.connect(_set_mjd_on)
	box.add_child(mjd_setting)

	var smooth_setting := CheckBox.new()
	smooth_setting.text = "Smooth ship movement between position samples (instead of straight lines)"
	smooth_setting.button_pressed = smooth_on
	smooth_setting.toggled.connect(_set_smooth_on)
	box.add_child(smooth_setting)

	var ui_scale := HBoxContainer.new()
	box.add_child(ui_scale)
	var ui_scale_label := Label.new()
	ui_scale_label.text = "Interface scale"
	ui_scale.add_child(ui_scale_label)
	ui_scale_option = OptionButton.new()
	var saved: float = Settings.get_value("display/ui_scale")
	var closest := 0
	for i in UI_SCALES.size():
		ui_scale_option.add_item("%d%%" % roundi(UI_SCALES[i] * 100.0))
		if absf(UI_SCALES[i] - saved) < absf(UI_SCALES[closest] - saved):
			closest = i
	ui_scale_option.select(closest)
	ui_scale_option.item_selected.connect(func(idx): _set_ui_scale(UI_SCALES[idx]))
	ui_scale.add_child(ui_scale_option)

	var jitter := HBoxContainer.new()
	box.add_child(jitter)
	jitter_setting = CheckBox.new()
	jitter_setting.text = "Ignore position jitter when finding the match start: movement under"
	jitter_setting.button_pressed = Settings.get_value("match/ignore_jitter")
	jitter_setting.tooltip_text = "Only for CSVs without overview speeds; with them, the first ship over %d m/s starts the match." % MatchData.MOVE_SPEED_MPS
	jitter.add_child(jitter_setting)
	jitter_spin = SpinBox.new()
	jitter_spin.min_value = 0.0
	jitter_spin.max_value = 50000.0
	jitter_spin.step = 50.0
	jitter_spin.suffix = "m"
	jitter_spin.value = Settings.get_value("match/jitter_threshold_m")
	jitter_spin.editable = jitter_setting.button_pressed
	jitter.add_child(jitter_spin)
	jitter_setting.toggled.connect(func(on):
		jitter_spin.editable = on
		_set_match_setting("match/ignore_jitter", on))
	jitter_spin.value_changed.connect(func(v): _set_match_setting("match/jitter_threshold_m", v))

	var season_teams := CheckBox.new()
	season_teams.text = "Keep pilots on their season's team in every match (top-level library folder = season)"
	season_teams.button_pressed = Settings.get_value("teams/season_db")
	season_teams.toggled.connect(func(on): _set_match_setting("teams/season_db", on))
	box.add_child(season_teams)

	var status := Label.new()
	status.text = sizes.status
	sizes.status_changed.connect(func(text): status.text = text)
	box.add_child(status)

	var assets_status := Label.new()
	assets_status.text = assets.status
	assets.status_changed.connect(func(text): assets_status.text = text)
	box.add_child(assets_status)

	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	var check := Button.new()
	check.text = "Check for updates now"
	check.pressed.connect(func():
		sizes.check_update()
		assets.check_update())
	buttons.add_child(check)
	var redownload := Button.new()
	redownload.text = "Re-download SDE"
	redownload.pressed.connect(sizes.full_download)
	buttons.add_child(redownload)
	var models_download := Button.new()
	models_download.text = "Download ship icons"
	models_download.pressed.connect(assets.full_download)
	buttons.add_child(models_download)


## Settings → Ship overlay: a checkbox per `OVERLAY_FIELDS` entry.
func _build_overlay_menu(layer: CanvasLayer) -> void:
	overlay_popup = OpaquePopup.new()
	layer.add_child(overlay_popup)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	overlay_popup.add_child(box)

	var title := Label.new()
	title.text = "Shown above ships"
	box.add_child(title)

	var names := {
		"name": "Pilot name",
		"type": "Ship type",
		"distance": "Distance from centre",
		"speed": "Speed",
		"icon": "Ship icon (with hull models)",
	}
	for field in OVERLAY_FIELDS:
		var check := CheckBox.new()
		check.text = names[field]
		check.button_pressed = ship_overlay[field]
		check.toggled.connect(func(on): _set_overlay(field, on))
		box.add_child(check)


## Right-hand table of each team's pilots (ship, pilot, speed, distance from centre): click one to
## follow it, ⇄ to change its team (right-click ⇄ to pick any team, Unknown included).
func _build_roster(layer: CanvasLayer) -> void:
	roster_panel = PanelContainer.new()
	roster_panel.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	roster_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	roster_panel.visible = false
	layer.add_child(roster_panel)
	broadcast_panel = BroadcastRoster.new()
	broadcast_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	broadcast_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	broadcast_panel.visible = false
	broadcast_panel.row_pressed.connect(_set_tracked)
	layer.add_child(broadcast_panel)
	var keep_above_bar := func():
		roster_panel.offset_bottom = -bottom_panel.size.y
		broadcast_panel.offset_top = -bottom_panel.size.y
		broadcast_panel.offset_bottom = -bottom_panel.size.y
	bottom_panel.resized.connect(keep_above_bar)
	keep_above_bar.call()

	roster_table = RosterTable.new()
	roster_table.row_pressed.connect(_set_tracked)
	roster_table.swap_pressed.connect(_swap_team)
	team_menu = PopupMenu.new()
	team_menu.index_pressed.connect(func(i): _move_team(team_menu.get_item_metadata(0), team_menu.get_item_metadata(i)))
	add_child(team_menu)
	roster_table.swap_context_pressed.connect(_open_team_menu)
	roster_table.row_context_pressed.connect(func(pilot):
		_open_ship_debug_menu(pilot, get_viewport().get_mouse_position()))
	roster_table.group_activated.connect(_ask_rename_team)
	roster_table.layout_changed.connect(_fit_roster)
	roster_panel.add_child(roster_table)
	_fit_roster()


## Sizes the roster panel to its columns, plus room for the scroll bar.
func _fit_roster() -> void:
	var bar := roster_table.scroll.get_v_scroll_bar().get_combined_minimum_size().x
	var panel := roster_panel.get_theme_stylebox("panel")
	var width := roster_table.header.get_combined_minimum_size().x + bar + panel.get_minimum_size().x
	roster_panel.offset_left = -width
	roster_panel.offset_right = 0.0


## Shows the roster table or the broadcast panel (`broadcast_on`) while a match is open.
func _apply_roster_visibility() -> void:
	roster_panel.visible = data != null and not broadcast_on
	broadcast_panel.visible = data != null and broadcast_on


func _set_broadcast_on(on: bool) -> void:
	broadcast_on = on
	Settings.set_value("display/broadcast_roster", on)
	broadcast_button.set_pressed_no_signal(on)
	_apply_roster_visibility()


func _set_damage_on(on: bool) -> void:
	damage_on = on
	Settings.set_value("display/damage_highlight", on)
	damage_button.set_pressed_no_signal(on)
	damage_setting.set_pressed_no_signal(on)
	_update_roster_cells()


func _set_muted(on: bool) -> void:
	muted = on
	Settings.set_value("audio/muted", on)
	AudioServer.set_bus_mute(AudioServer.get_bus_index(AUDIO_BUS), on)
	mute_button.set_pressed_no_signal(on)


## Mute only matters for a match with comms audio: its button is disabled otherwise.
func _update_mute_button() -> void:
	var has_audio := audio_player.stream != null
	mute_button.disabled = not has_audio
	mute_button.tooltip_text = "Mute the match's comms audio" if has_audio else "This match has no comms audio"


func _set_mjd_on(on: bool) -> void:
	mjd_on = on
	Settings.set_value("display/mjd_spoolup", on)
	mjd_button.set_pressed_no_signal(on)
	mjd_setting.set_pressed_no_signal(on)


## The damage highlight needs HP: its button is disabled for a match without any.
func _update_damage_controls() -> void:
	var has_hp := data != null and data.has_hp
	damage_button.disabled = not has_hp
	damage_button.tooltip_text = ("Highlight ships taking damage (HP dropping) in the roster" if has_hp
			else "This match has no HP data")


## Rebuilds the roster and the broadcast panel from the loaded match's teams.
func _refresh_roster() -> void:
	roster_table.clear()
	roster_buttons.clear()
	broadcast_panel.clear()
	_apply_roster_visibility()
	if data == null:
		return
	_compute_score()
	var pilots := ships.keys()
	# By points (most first; pilots without any last), then ship type, then pilot.
	var pts := func(p: String) -> int: return score.values.get(p, -1) if score != null else -1
	var key := func(p: String) -> String: return "%s\n%s" % [data.tracks[p][0].ship_type, _pilot_name(p)]
	pilots.sort_custom(func(a, b):
		if pts.call(a) != pts.call(b):
			return pts.call(a) > pts.call(b)
		return key.call(a).naturalnocasecmp_to(key.call(b)) < 0)
	for team in [MatchData.Team.BLUE, MatchData.Team.RED, MatchData.Team.UNKNOWN]:
		var members := pilots.filter(func(p): return data.teams.get(p, MatchData.Team.UNKNOWN) == team)
		if team == MatchData.Team.UNKNOWN and members.is_empty():
			continue
		var color: Color = _team_color(team)
		var renamable: bool = team != MatchData.Team.UNKNOWN
		roster_table.add_group("%s (%d)" % [_team_name(team), members.size()], color,
				team if renamable else -1, "Double-click to rename" if renamable else "")
		var other: int = MatchData.Team.BLUE if team != MatchData.Team.BLUE else MatchData.Team.RED
		for pilot in members:
			var button := roster_table.add_row(pilot, color, "Move to %s (right-click for more)" % _team_name(other))
			button.tooltip_text = "Centre the camera on %s (right-click to rename or debug)" % _pilot_name(pilot)
			button.set_pressed_no_signal(pilot == tracked)
			roster_buttons[pilot] = button
			_style_roster_button(pilot)
			roster_table.set_cell(pilot, "ship", data.tracks[pilot][0].ship_type)
			roster_table.set_cell(pilot, "pilot", pilot_names.get(pilot, _short_name(pilot)))
	# Broadcast panel: red down the left, blue down the right; unknown pilots are left out.
	broadcast_panel.set_teams(_team_name(MatchData.Team.RED), _team_color(MatchData.Team.RED),
			_team_name(MatchData.Team.BLUE), _team_color(MatchData.Team.BLUE))
	for pilot in pilots:
		var team: int = data.teams.get(pilot, MatchData.Team.UNKNOWN)
		if team == MatchData.Team.UNKNOWN:
			continue
		var side := BroadcastRoster.Side.LEFT if team == MatchData.Team.RED else BroadcastRoster.Side.RIGHT
		var button := broadcast_panel.add_row(side, pilot, _team_color(team))
		button.tooltip_text = "Centre the camera on %s" % _pilot_name(pilot)
		broadcast_panel.set_cell(pilot, "ship", data.tracks[pilot][0].ship_type)
		broadcast_panel.set_cell(pilot, "name", pilot_names.get(pilot, _short_name(pilot)))
	_refresh_score()
	_update_roster_cells()


## Recomputes `score` for the current teams and `ruleset_id`.
func _compute_score() -> void:
	var rules := Ruleset.load_id(ruleset_id)
	score = MatchScore.new(data, rules) if data != null and rules != null else null


## Shows each ship's points from `score`.
func _refresh_score() -> void:
	var rules: Ruleset = score.ruleset if score != null else null
	for pilot in broadcast_panel.rows:
		if score == null or not score.values.has(pilot):
			broadcast_panel.set_cell(pilot, "pts", "—")
			continue
		var ship: String = score.fielded[pilot]
		broadcast_panel.set_cell(pilot, "pts", "%d" % score.values[pilot])
		var label: Label = broadcast_panel.rows[pilot].labels.pts
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		if not rules.knows(ship):
			label.tooltip_text = "%s isn't in %s: 0 points" % [ship, rules.name]
		else:
			var extra: int = score.values[pilot] - rules.base_points(ship)
			label.tooltip_text = "%s: %d points%s (%s)" % [ship, rules.base_points(ship),
					" + %d inflation" % extra if extra > 0 else "", rules.name]


func _set_ruleset(id: String) -> void:
	ruleset_id = id
	_select_ruleset_option()
	_save_meta()
	_refresh_roster()  # Points may change, and the rows are sorted by them.


func _select_ruleset_option() -> void:
	if ruleset_option == null:
		return
	for i in ruleset_option.item_count:
		if ruleset_option.get_item_metadata(i) == ruleset_id:
			ruleset_option.select(i)


## Refreshes each roster row's live columns: current hull, speed, distance from centre, HP, and the
## combat-log rates and electronic warfare, and highlights ships taking damage (`damage_on`).
## Pilots off grid show dashes and unknown HP; dead ones are dimmed.
func _update_roster_cells() -> void:
	if data == null:
		return
	var rate_ids := CombatStats.RATE_IDS.filter(combat_stats.has)
	for pilot in roster_buttons:
		for id in rate_ids:
			var r := combat_stats.rate(pilot, id, time)
			roster_table.set_cell(pilot, id, "%d" % roundi(r) if r >= 0.5 else "—")
		for id in CombatStats.EWAR_IDS:
			if combat_stats.has(id):
				roster_table.set_cell_icons(pilot, id, _ewar_icons(pilot, id == "ewar_out"))
		var motion := _motion(pilot)
		var dead: bool = time >= ships[pilot].death_t
		if not motion.is_empty():
			roster_table.set_cell(pilot, "ship", motion.ship_type)
		if motion.is_empty() or dead:
			roster_table.set_cell(pilot, "speed", "—")
			roster_table.set_cell(pilot, "distance", "—")
		else:
			roster_table.set_cell(pilot, "speed", "—" if is_nan(motion.speed) else _fmt_speed(motion.speed))
			roster_table.set_cell(pilot, "distance", "%.1f km" % motion.dist_km)
		roster_buttons[pilot].modulate.a = 0.5 if dead else 1.0
		var hp := MatchData.NAN_HP if dead else data.hp_at(pilot, time)
		var hit := damage_on and not dead and data.taking_damage(pilot, time)
		roster_table.set_cell_hp(pilot, "hp", hp)
		roster_table.set_row_damaged(pilot, hit)
		if broadcast_panel.rows.has(pilot):
			_update_broadcast_row(pilot, dead, hp, hit)
	broadcast_panel.set_clock(_fmt_clock(time - data.lead_in))
	for side in [BroadcastRoster.Side.LEFT, BroadcastRoster.Side.RIGHT]:
		var team := MatchData.Team.RED if side == BroadcastRoster.Side.LEFT else MatchData.Team.BLUE
		broadcast_panel.set_points(side, "%d" % score.score(team, time) if score != null else "0")


## Copies `pilot`'s roster row (ship, speed, `hp`, taking damage: `hit`) into the broadcast panel,
## with the electronic warfare on it and a micro jump drive icon while it spools. Ships that died (out of bounds: `dead`, or podded) grey out
## their row and keep the hull they lost.
func _update_broadcast_row(pilot: String, dead: bool, hp: Vector3, hit: bool) -> void:
	var lost := data.lost_hull(pilot, time)
	dead = dead or not lost.is_empty()
	broadcast_panel.set_cell(pilot, "ship", lost if not lost.is_empty() else roster_table.cell_text(pilot, "ship"))
	broadcast_panel.set_cell(pilot, "speed", "—" if dead else roster_table.cell_text(pilot, "speed"))
	broadcast_panel.set_dead(pilot, dead)
	broadcast_panel.set_hp(pilot, MatchData.NAN_HP if dead else hp)
	broadcast_panel.set_damaged(pilot, hit and not dead)
	var ewar := combat_stats.has("ewar_in") and not dead
	broadcast_panel.set_ewar(pilot, _ewar_icons(pilot, false) if ewar else [])
	broadcast_panel.set_mjd(pilot, [] if dead else _mjd_icons(data.mjd_spool(pilot, time)))


## The broadcast panel's micro jump drive icon for a drive `spool` of the way spooled up (see
## `MatchData.mjd_spool`), or none when it isn't spooling.
func _mjd_icons(spool: float) -> Array:
	if spool < 0.0:
		return []
	return [{"key": "mjd", "texture": assets.ewar_texture("mjd"), "text": "MJD",
		"tooltip": "Micro jump drive spooling: jumps in %d s" % _mjd_seconds_left(spool)}]


## Whole seconds (rounded up) until a micro jump drive `spool` of the way spooled up jumps.
static func _mjd_seconds_left(spool: float) -> int:
	return ceili((1.0 - spool) * MatchData.MJD_SPOOL_S - 0.001)


## Roster icons for the electronic warfare on `pilot` (`outgoing`: by it) now: one per type, its
## tooltip listing the pilots on the other side and the cycles so far.
func _ewar_icons(pilot: String, outgoing: bool) -> Array:
	var active := combat_stats.ewar_at(pilot, outgoing, time)
	var items := []
	for type in CombatStats.EWAR_TYPES:
		if not active.has(type):
			continue
		var info: Dictionary = CombatStats.EWAR_TYPES[type]
		var lines := ["%s %s:" % [info.title, "to" if outgoing else "from"]]
		for row in active[type]:
			lines.append("  %s (%d cycle%s)" % [_pilot_name(row.pilot), row.cycles, "" if row.cycles == 1 else "s"])
		items.append({"key": type, "texture": assets.ewar_texture(type), "text": info.short,
			"tooltip": "\n".join(lines)})
	return items


## Roster abbreviation of a pilot name: the first word, then initials ("Halvard Some Name" ->
## "Halvard S. N.").
static func _short_name(pilot: String) -> String:
	var words := pilot.split(" ", false)
	if words.is_empty():
		return pilot
	var out := words[0]
	for i in range(1, words.size()):
		out += " %s." % words[i].left(1)
	return out


## Follows `pilot` with the camera; picking the followed pilot again (or "") frees it.
func _set_tracked(pilot: String) -> void:
	_follow("" if pilot == tracked else pilot)


## Follows `pilot` with the camera ("" frees it).
func _follow(pilot: String) -> void:
	tracked = pilot
	for p in roster_buttons:
		roster_buttons[p].set_pressed_no_signal(p == tracked)
	if tracked != "" and ships[tracked].node.visible:
		camera.set_target(ships[tracked].node.position)


## Moves `pilot` to the other team (unknown pilots go to blue).
func _swap_team(pilot: String) -> void:
	_move_team(pilot, MatchData.Team.RED if data.teams.get(pilot) == MatchData.Team.BLUE else MatchData.Team.BLUE)


## Opens `team_menu` at the mouse for `pilot`: "Move to" each team it isn't on.
func _open_team_menu(pilot: String) -> void:
	team_menu.clear()
	team_menu.add_separator(_pilot_name(pilot))
	team_menu.set_item_metadata(0, pilot)
	for team in [MatchData.Team.BLUE, MatchData.Team.RED, MatchData.Team.UNKNOWN]:
		if data.teams.get(pilot) != team:
			team_menu.add_item("Move to %s" % _team_name(team))
			team_menu.set_item_metadata(team_menu.item_count - 1, team)
	team_menu.popup(Rect2i(Vector2i(get_viewport().get_mouse_position()), Vector2i.ZERO))


## Moves `pilot` to `team` and recolours it; a team it fills takes in the unknown pilots
## (`MatchData.fill_unknown`), except those put on Unknown by hand. Unknown is this match's
## only: the season db keeps the pilot's team.
func _move_team(pilot: String, team: int) -> void:
	if data.teams.get(pilot) == team:
		return
	data.teams[pilot] = team
	team_overrides[pilot] = team
	if not team_sides.is_empty() and team != MatchData.Team.UNKNOWN:
		_edit_team_db(func(db):
			if team_sides[team] == "":
				team_sides[team] = TeamDb.new_team(db)
			TeamDb.assign(db, pilot, team_sides[team]))
	_recolor_ship(pilot)
	for p in data.fill_unknown(TeamDb.pinned_unknown(team_overrides)):
		_recolor_ship(p)
	_save_meta()
	_update_file_label()
	_refresh_roster()


## Gives `pilot`'s ship (and death marker) its team's colour.
func _recolor_ship(pilot: String) -> void:
	var ship: Dictionary = ships[pilot]
	ship.color = _team_color(data.teams[pilot])
	ship.ship_type = ""  # Forces `_update_ships` to re-tint the visual, icon and label.
	if ship.death_marker:
		var was_visible: bool = ship.death_marker.visible
		ship.death_marker.queue_free()
		ship.death_marker = _death_marker(pilot, data.deaths[pilot], ship.color)
		ship.death_marker.visible = was_visible


func _ask_rename_pilot(pilot: String) -> void:
	rename_dialog.ask("Rename pilot", _pilot_name(pilot), pilot)
	_rename_target = func(text): _rename_pilot(pilot, text)


func _ask_rename_team(team: int) -> void:
	rename_dialog.ask("Rename team", _team_name(team), TEAM_NAMES[side_colors.get(team, team)])
	_rename_target = func(text): _rename_team(team, text)


## Shows `pilot` as `new_name` in every match; empty (or its CSV name) restores the CSV name.
func _rename_pilot(pilot: String, new_name: String) -> void:
	new_name = new_name.strip_edges()
	if new_name == "" or new_name == pilot:
		pilot_names.erase(pilot)
	else:
		pilot_names[pilot] = new_name
	Settings.set_value("names/pilots", pilot_names.duplicate())
	if data == null:
		return
	if ships.has(pilot):
		ships[pilot].ship_type = ""  # Forces `_update_ships` to redo the label.
		_update_ships()
	_build_events()
	_refresh_roster()
	_update_info()
	if debug_pilot == pilot:
		_refresh_ship_debug_menu()


## Names `team` (Blue or Red): its season team (`TeamDb`, where empty gives back its temporary
## name) with season teams on, else just in this match (where empty restores the default).
func _rename_team(team: int, new_name: String) -> void:
	new_name = new_name.strip_edges()
	if team_sides.get(team, "") != "":
		team_names.erase(team)
		_edit_team_db(func(db): TeamDb.rename(db, team_sides[team], new_name))
	elif new_name == "" or new_name == TEAM_NAMES[side_colors.get(team, team)]:
		team_names.erase(team)
	else:
		team_names[team] = new_name
	_save_meta()
	_update_file_label()
	_refresh_roster()
	_update_info()


## Changes the open match's season `TeamDb` with `edit` (called with the db, read afresh) and
## saves it.
func _edit_team_db(edit: Callable) -> void:
	var season := TeamDb.season_of(match_path)
	team_db = TeamDb.read(season)
	edit.call(team_db)
	TeamDb.save(season, team_db)


## A dropped CSV joins the library and opens (from the menu or mid-match); a dropped folder
## joins it as a scrim folder (`MainMenu.add_folder`); a dropped audio file becomes the audio of
## the selected match (menu) or the open library match.
func _on_files_dropped(files: PackedStringArray) -> void:
	if not WebBackend.member():
		var why := "Only whitelisted pilots can add matches, audio or combat logs"
		if menu.visible:
			menu.show_error(why)
		else:
			file_label.text = why
		return
	for f in files:
		if DirAccess.dir_exists_absolute(f):
			_show_menu()
			menu.add_folder(f)
			return
		var ext := f.get_extension().to_lower()
		if ext == "csv":
			_show_menu()
			menu.add_file(f)
			return
		if MatchLibrary.AUDIO_EXTENSIONS.has(ext):
			if menu.visible:
				menu.add_audio(f)
			elif MatchLibrary.contains(match_path):
				if MatchLibrary.set_audio(match_path, f) != "":
					load_match(match_path)
			return
