class_name DebugMenu
extends OpaquePopup
## Debug overlay controls: a movement vector and range spheres for one ship (plus renaming its
## pilot), or (`all_ships`)
## the same for every ship at once, plus the vector projection time, the beacons' jump
## range and which source -> target activity lines are drawn, in what colour. Emits what the user picked; `main.gd` owns the state and calls `show_state` to redraw.

signal vector_toggled(on: bool)
signal sphere_added(radius_km: float, color: Color)
signal sphere_removed(index: int)
signal spheres_cleared
signal vector_seconds_changed(seconds: float)
signal beacon_range_toggled(centre: bool, on: bool)
## An activity line kind (`CombatStats.LINK_KINDS`) shown or hidden (all-ships menu only).
signal link_toggled(kind: String, on: bool)
## An activity line kind recoloured (all-ships menu only).
signal link_color_changed(kind: String, color: Color)
## "Rename pilot…" pressed (per-ship menu only).
signal rename_requested
## "Get Damage Breakdown" pressed (per-ship menu only).
signal damage_breakdown_requested

const DEFAULT_RADIUS_KM := 10.0
const DEFAULT_COLOR := Color(0.3, 1.0, 0.75)
const LINK_TITLES := {
	"shooting": "Shooting",
	"tackle": "Tackle (scram / point / web)",
	"neut": "Neuts / nos",
	"ewar": "EWAR",
}

var all_ships: bool
var title_label: Label
## Per-ship menu only.
var rename_button: Button
## Per-ship menu only.
var damage_button: Button
var vector_check: CheckBox
## One row per sphere (per-ship menu only): swatch, range, remove button.
var sphere_list: VBoxContainer
var radius_spin: SpinBox
var color_button: ColorPickerButton
var add_button: Button
var clear_button: Button
var seconds_spin: SpinBox
var corner_check: CheckBox
var centre_check: CheckBox
## Activity line kind -> its CheckBox / ColorPickerButton (all-ships menu only).
var link_checks := {}
var link_colors := {}


func _init(all := false) -> void:
	super()
	all_ships = all
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)

	var title_row := HBoxContainer.new()
	box.add_child(title_row)
	title_label = Label.new()
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_label)
	if not all:
		rename_button = Button.new()
		rename_button.text = "Rename pilot…"
		rename_button.pressed.connect(func():
			hide()
			rename_requested.emit())
		title_row.add_child(rename_button)
		damage_button = Button.new()
		damage_button.text = "Get Damage Breakdown"
		damage_button.pressed.connect(func():
			hide()
			damage_breakdown_requested.emit())
		box.add_child(damage_button)

	vector_check = CheckBox.new()
	vector_check.text = "Movement vectors on all ships" if all else "Movement vector"
	vector_check.toggled.connect(func(on): vector_toggled.emit(on))
	box.add_child(vector_check)

	if all:
		var seconds := HBoxContainer.new()
		box.add_child(seconds)
		var label := Label.new()
		label.text = "Vector shows where ships will be in"
		seconds.add_child(label)
		seconds_spin = SpinBox.new()
		seconds_spin.min_value = 0.5
		seconds_spin.max_value = 60.0
		seconds_spin.step = 0.5
		seconds_spin.suffix = "s"
		seconds_spin.value_changed.connect(func(v): vector_seconds_changed.emit(v))
		seconds.add_child(seconds_spin)

	box.add_child(HSeparator.new())
	var spheres_title := Label.new()
	spheres_title.text = "Range spheres (every ship)" if all else "Range spheres"
	box.add_child(spheres_title)
	sphere_list = VBoxContainer.new()
	box.add_child(sphere_list)

	var add_row := HBoxContainer.new()
	box.add_child(add_row)
	radius_spin = SpinBox.new()
	radius_spin.min_value = 0.1
	radius_spin.max_value = 300.0
	radius_spin.step = 0.1
	radius_spin.value = DEFAULT_RADIUS_KM
	radius_spin.suffix = "km"
	add_row.add_child(radius_spin)
	color_button = ColorPickerButton.new()
	color_button.color = DEFAULT_COLOR
	color_button.custom_minimum_size = Vector2(40, 0)
	add_row.add_child(color_button)
	add_button = Button.new()
	add_button.text = "Add to every ship" if all else "Add sphere"
	add_button.pressed.connect(func(): sphere_added.emit(radius_spin.value, color_button.color))
	add_row.add_child(add_button)

	if all:
		clear_button = Button.new()
		clear_button.text = "Clear all spheres"
		clear_button.pressed.connect(func(): spheres_cleared.emit())
		box.add_child(clear_button)

		box.add_child(HSeparator.new())
		corner_check = CheckBox.new()
		corner_check.text = "Corner beacons: 5 km jump range"
		corner_check.toggled.connect(func(on): beacon_range_toggled.emit(false, on))
		box.add_child(corner_check)
		centre_check = CheckBox.new()
		centre_check.text = "Centre beacon: 5 km jump range"
		centre_check.toggled.connect(func(on): beacon_range_toggled.emit(true, on))
		box.add_child(centre_check)

		box.add_child(HSeparator.new())
		var links_title := Label.new()
		links_title.text = "Activity lines (from combat logs)"
		box.add_child(links_title)
		for kind in CombatStats.LINK_KINDS:
			var row := HBoxContainer.new()
			box.add_child(row)
			var check := CheckBox.new()
			check.text = LINK_TITLES[kind]
			check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			check.toggled.connect(func(on): link_toggled.emit(kind, on))
			row.add_child(check)
			var picker := ColorPickerButton.new()
			picker.custom_minimum_size = Vector2(40, 0)
			picker.color_changed.connect(func(c): link_color_changed.emit(kind, c))
			row.add_child(picker)
			link_checks[kind] = check
			link_colors[kind] = picker


## Fills the menu: `title`, the vector checkbox, and (per-ship menu) a row per sphere in
## `spheres` ({ radius_km, color }) and whether the damage breakdown has data (`has_damage`).
func show_state(title: String, vector_on: bool, spheres: Array, has_damage := false) -> void:
	title_label.text = title
	if damage_button:
		damage_button.disabled = not has_damage
		damage_button.tooltip_text = "" if has_damage else "Add combat logs to the match first"
	vector_check.set_pressed_no_signal(vector_on)
	for c in sphere_list.get_children():
		sphere_list.remove_child(c)
		c.queue_free()
	if all_ships:
		return
	for i in spheres.size():
		var row := HBoxContainer.new()
		sphere_list.add_child(row)
		var swatch := ColorRect.new()
		swatch.color = spheres[i].color
		swatch.custom_minimum_size = Vector2(16, 16)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(swatch)
		var label := Label.new()
		label.text = "%.1f km" % spheres[i].radius_km
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var remove := Button.new()
		remove.text = "✕"
		remove.tooltip_text = "Remove this sphere"
		remove.pressed.connect(func(): sphere_removed.emit(i))
		row.add_child(remove)


## Sets the activity line rows from `state` (kind -> { on, color }) without emitting.
func show_links(state: Dictionary) -> void:
	for kind in state:
		if link_checks.has(kind):
			link_checks[kind].set_pressed_no_signal(state[kind].on)
			link_colors[kind].color = state[kind].color


## Pops up with its top-left corner at `pos` (embedder coordinates).
func open_at(pos: Vector2) -> void:
	popup(Rect2i(Vector2i(pos), Vector2i.ZERO))
