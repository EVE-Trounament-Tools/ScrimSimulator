class_name Settings
extends RefCounted
## Persistent user settings in `user://settings.cfg`.

## Overridable so tests never touch the real settings file.
static var path := "user://settings.cfg"
const DEFAULTS := {
	"sde/auto_update": true,
	"display/ship_models": true,
	"display/smooth_motion": true,
	# Interface scale (window content scale factor); resizing the window never scales the UI.
	"display/ui_scale": 1.0,
	# Show the broadcast-style ship data panel instead of the roster table.
	"display/broadcast_roster": true,
	# Highlight roster rows of ships taking damage (HP dropping).
	"display/damage_highlight": false,
	# Draw micro jump drive spool-ups in space (ring, projected landing and arrow).
	"display/mjd_spoolup": true,
	# Match start detection: ignore position changes up to this many metres (overview jitter).
	"match/ignore_jitter": false,
	"match/jitter_threshold_m": 500.0,
	# Roster column layout (see `RosterTable`); empty = default columns.
	"roster/columns": [],
	# Whether the bundled demo match has been added to the library (see `MatchLibrary.add_demo`).
	"library/demo_added": false,
	# Keep pilots on their season's team (`TeamDb`) in every match; off = each match's own
	# teams from start positions.
	"teams/season_db": true,
	# CSV pilot name -> display name, applied in every match.
	"names/pilots": {},
	# What is drawn above each ship in space (Settings → Ship overlay).
	"overlay/name": true,
	"overlay/type": true,
	"overlay/distance": false,
	"overlay/speed": false,
	"overlay/icon": true,
	# Source -> target lines in space (debug menu), per `CombatStats.LINK_KINDS` kind.
	"links/shooting": true,
	"links/shooting_color": Color(1.0, 0.3, 0.25),
	"links/tackle": true,
	"links/tackle_color": Color(1.0, 0.85, 0.2),
	"links/neut": true,
	"links/neut_color": Color(0.75, 0.4, 1.0),
	"links/ewar": true,
	"links/ewar_color": Color(0.3, 0.85, 1.0),
}

static var _cfg: ConfigFile


static func get_value(key: String) -> Variant:
	_load()
	var parts := key.split("/", true, 1)
	return _cfg.get_value(parts[0], parts[1], DEFAULTS.get(key))


static func set_value(key: String, value: Variant) -> void:
	_load()
	var parts := key.split("/", true, 1)
	_cfg.set_value(parts[0], parts[1], value)
	var err := _cfg.save(path)
	if err != OK:
		push_error("Cannot save %s: %s" % [path, error_string(err)])
	if OS.has_feature("web"):
		WebSettings.changed(_cfg)


static func _load() -> void:
	if _cfg != null:
		return
	_cfg = ConfigFile.new()
	if OS.has_feature("web"):
		WebSettings.load_into(_cfg)
		return
	_cfg.load(path)  # Missing file is fine: defaults apply.
