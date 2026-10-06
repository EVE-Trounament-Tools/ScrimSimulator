extends "res://tests/test_case.gd"
## BroadcastRoster: mirrored sides, placeholder points, HP bars, damage highlight and the capped
## EWAR icons.

const L := BroadcastRoster.Side.LEFT
const R := BroadcastRoster.Side.RIGHT


func _panel() -> BroadcastRoster:
	var b := BroadcastRoster.new()
	add_node(b)
	b.set_teams("Paper Numbers", Color.RED, "Dracarys.", Color.BLUE)
	return b


## The column ids of `pilot`'s row, in display order.
func _row_ids(b: BroadcastRoster, pilot: String) -> Array:
	var row: Dictionary = b.rows[pilot]
	return row.cells.get_children().map(func(c): return row.labels.find_key(c))


func _items(n: int) -> Array:
	var out := []
	for i in n:
		out.append({"key": "k%d" % i, "texture": null, "text": "E%d" % i, "tooltip": "t%d" % i})
	return out


func test_teams_and_points() -> void:
	var b := _panel()
	assert_eq(b.team_text(L), "PAPER NUMBERS")
	assert_eq(b.team_text(R), "DRACARYS.")
	assert_eq(b.points_text(L), "0")
	assert_eq(b.points_text(R), "0")


func test_sides_are_mirrored() -> void:
	var b := _panel()
	b.add_row(L, "a", Color.RED)
	b.add_row(R, "b", Color.BLUE)
	assert_eq(_row_ids(b, "a"), ["pts", "name", "speed", "hull", "armor", "shield", "ship", "ewar"])
	assert_eq(_row_ids(b, "b"), ["ewar", "ship", "shield", "armor", "hull", "speed", "name", "pts"])
	assert_eq(b.rows["a"].button.get_parent(), b.sides[L].rows)
	assert_eq(b.rows["b"].button.get_parent(), b.sides[R].rows)
	assert_eq(b.cell_text("a", "pts"), "0")
	b.set_cell("a", "speed", "12 m/s")
	assert_eq(b.cell_text("a", "speed"), "12 m/s")


func test_ewar_capped() -> void:
	var b := _panel()
	b.add_row(L, "a", Color.RED)
	b.set_ewar("a", _items(7))
	var box: HBoxContainer = b.rows["a"].ewar
	assert_eq(box.get_child_count(), BroadcastRoster.MAX_EWAR_ICONS)
	assert_eq(box.get_children().map(func(c): return c.get_meta("key")), ["k0", "k1", "k2", "k3", "k4"])
	var first := box.get_child(0)
	b.set_ewar("a", _items(7))
	assert_eq(box.get_child(0), first, "same items: not rebuilt")
	b.set_ewar("a", [])
	assert_eq(box.get_child_count(), 0)


func test_clear_and_click() -> void:
	var b := _panel()
	var button := b.add_row(R, "b", Color.BLUE)
	var got := []
	b.row_pressed.connect(func(p): got.append(p))
	button.pressed.emit()
	assert_eq(got, ["b"])
	b.clear()
	assert_true(b.rows.is_empty())
	assert_eq(b.sides[R].rows.get_child_count(), 0)


func test_hp_bars() -> void:
	var b := _panel()
	b.add_row(L, "a", Color.RED)
	var labels: Dictionary = b.rows["a"].labels
	for id in ["shield", "armor", "hull"]:
		assert_true(is_nan(HpBar.get_fraction(labels[id])), "unknown until set")
	b.set_hp("a", Vector3(0.5, 1.0, 0.0))
	assert_eq(HpBar.get_fraction(labels.shield), 0.5)
	assert_eq(HpBar.get_fraction(labels.armor), 1.0)
	assert_eq(HpBar.get_fraction(labels.hull), 0.0)
	assert_eq(labels.shield.tooltip_text, "Shield: 50%")
	assert_almost(labels.shield.get_child(0).anchor_right, 0.5)
	b.set_hp("a", MatchData.NAN_HP)
	assert_eq(labels.hull.color, HpBar.UNKNOWN)
	assert_false(labels.hull.get_child(0).visible)


func test_damage_highlight() -> void:
	var b := _panel()
	b.add_row(R, "b", Color.BLUE)
	assert_false(b.is_damaged("b"))
	b.set_damaged("b", true)
	assert_true(b.is_damaged("b"))


func test_dead_row_greyed_out() -> void:
	var b := _panel()
	b.add_row(L, "a", Color.RED)
	var name: Label = b.rows["a"].labels.name
	assert_false(b.is_dead("a"))
	b.set_dead("a", true)
	assert_true(b.is_dead("a"))
	assert_eq(name.get_theme_color("font_color"), BroadcastRoster.DEAD_COLOR)
	assert_eq(b.rows["a"].labels.ship.get_theme_color("font_color"), BroadcastRoster.DEAD_COLOR)
	assert_almost(b.rows["a"].button.modulate.a, BroadcastRoster.DEAD_ALPHA)
	b.set_dead("a", false)
	assert_eq(name.get_theme_color("font_color"), Color.RED)
	assert_eq(b.rows["a"].button.modulate.a, 1.0)
