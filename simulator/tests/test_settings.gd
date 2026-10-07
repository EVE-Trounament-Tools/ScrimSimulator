extends "res://tests/test_case.gd"
## Settings: defaults and persistence, against a temp file instead of user://settings.cfg.

var _saved_path: String


func before_each() -> void:
	_saved_path = Settings.path
	Settings.path = temp_dir().path_join("settings.cfg")
	Settings._cfg = null


func after_each() -> void:
	Settings.path = _saved_path
	Settings._cfg = null


func test_default_when_unset() -> void:
	assert_eq(Settings.get_value("sde/auto_update"), true)


func test_unknown_key_is_null() -> void:
	assert_null(Settings.get_value("nope/missing"))


func test_set_value_persists() -> void:
	Settings.set_value("sde/auto_update", false)
	assert_true(FileAccess.file_exists(Settings.path))
	Settings._cfg = null  # Force a reload from disk.
	assert_eq(Settings.get_value("sde/auto_update"), false)


func test_ship_models_default_on() -> void:
	assert_eq(Settings.get_value("display/ship_models"), true)


func test_season_teams_default_on() -> void:
	assert_eq(Settings.get_value("teams/season_db"), true)


func test_smooth_motion_default_on() -> void:
	assert_eq(Settings.get_value("display/smooth_motion"), true)


func test_ui_scale_default_one() -> void:
	assert_eq(Settings.get_value("display/ui_scale"), 1.0)


func test_roster_columns_default_empty() -> void:
	assert_eq(Settings.get_value("roster/columns"), [])


func test_overlay_defaults() -> void:
	assert_eq(Settings.get_value("overlay/name"), true)
	assert_eq(Settings.get_value("overlay/type"), true)
	assert_eq(Settings.get_value("overlay/distance"), false)
	assert_eq(Settings.get_value("overlay/speed"), false)
	assert_eq(Settings.get_value("overlay/icon"), true)
