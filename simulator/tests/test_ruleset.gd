extends "res://tests/test_case.gd"
## Ruleset: the bundled ATXXII points, per-hull inflation and the points cap.


func _atxxii() -> Ruleset:
	var r := Ruleset.load_id("ATXXII")
	assert_not_null(r)
	return r


func test_atxxii_is_bundled_and_latest() -> void:
	assert_true(Ruleset.available().has("ATXXII"))
	assert_eq(Ruleset.latest_id(), Ruleset.available()[-1])
	assert_eq(_atxxii().point_cap, 200)


func test_unknown_ruleset_is_null() -> void:
	assert_null(Ruleset.load_id("nope"))


func test_base_points_ignore_case() -> void:
	var r := _atxxii()
	assert_eq(r.base_points("Abaddon"), 40)
	assert_eq(r.base_points("abaddon"), 40)
	assert_true(r.knows("ABADDON"))


func test_capsule_and_unknown_ships_are_free() -> void:
	var r := _atxxii()
	assert_eq(r.base_points("Capsule"), 0)
	assert_eq(r.base_points("Not A Ship"), 0)
	assert_false(r.knows("Not A Ship"))
	assert_eq(r.fleet_points(["Not A Ship", "Not A Ship"]), [0, 0])


func test_names_are_trimmed() -> void:
	# The sheet lists some ships with trailing spaces.
	assert_true(_atxxii().knows("Shapash"))


func test_inflation_by_hull() -> void:
	var r := _atxxii()
	# Every copy pays (copies - 1) * the hull's inflation.
	assert_eq(r.fleet_points(["Dominix", "Dominix"]), [44, 44])
	assert_eq(r.fleet_points(["Raven", "Raven", "Abaddon"]), [42, 42, 40])
	assert_eq(r.fleet_points(["Vexor Navy Issue", "Vexor Navy Issue"]), [18, 18])
	assert_eq(r.fleet_points(["Jackdaw", "Jackdaw", "Jackdaw"]), [12, 12, 12])
	assert_eq(r.fleet_points(["Inquisitor", "Inquisitor"]), [4, 4])
	# Frigates and corvettes don't inflate.
	assert_eq(r.fleet_points(["Executioner", "Executioner", "Velator", "Velator"]), [4, 4, 1, 1])


func test_inflation_counts_same_ship_not_same_hull() -> void:
	assert_eq(_atxxii().fleet_points(["Dominix", "Abaddon"]), [40, 40])


func test_head_start() -> void:
	var r := _atxxii()
	assert_eq(r.head_start(182), 18)
	assert_eq(r.head_start(200), 0)
	assert_eq(r.head_start(210), 0)
