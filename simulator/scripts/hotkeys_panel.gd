class_name HotkeysPanel
extends PanelContainer
## Read-only list of the viewer's keyboard and mouse controls, shown top left by the **Hotkeys…**
## buttons of the viewer's bar and the main menu. Clicks pass through it.

## [input, action] rows; keep in sync with the README's Controls table.
const HOTKEYS := [
	["Space / Play", "Play or pause"],
	["← / →", "Pause and step one tick (1 s)"],
	["Shift + ← / →", "Seek back / forward 10 s"],
	["[ / ]", "Jump to the previous / next event on the timeline"],
	["Left drag (empty space)", "Orbit the camera"],
	["Mouse wheel", "Zoom"],
	["Right drag", "Pan"],
	["Click a ship", "Select it and show its details"],
	["Double-click a ship", "Follow it with the camera"],
	["Esc / click empty space", "Clear the selection"],
	["Left drag from a ship", "Measure distances from it"],
	["Right-click a ship", "Its debug menu (also from the roster)"],
	["D", "Debug menu for every ship"],
	["M", "Toggle hull models and icons vs. plain spheres"],
	["B", "Toggle the 125 km arena boundary"],
]

## The grid of every [input, action] row (input labels in even children, actions in odd).
var grid: GridContainer


## `extra` is a titled second section: {"title": String, "rows": [[input, action], ...]}.
func _init(extra := {}) -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel := get_theme_stylebox("panel").duplicate() as StyleBoxFlat
	panel.bg_color.a = 1.0
	panel.set_content_margin_all(10)
	add_theme_stylebox_override("panel", panel)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 6)
	add_child(box)

	grid = _section(box, "Hotkeys", HOTKEYS)
	if not extra.is_empty():
		_section(box, extra.title, extra.rows)


func _section(box: VBoxContainer, title: String, rows: Array) -> GridContainer:
	var heading := Label.new()
	heading.text = title
	box.add_child(heading)
	var g := GridContainer.new()
	g.columns = 2
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.add_theme_constant_override("h_separation", 16)
	box.add_child(g)
	for row in rows:
		var key := Label.new()
		key.text = row[0]
		key.modulate = Color(0.75, 0.85, 1.0)
		g.add_child(key)
		var action := Label.new()
		action.text = row[1]
		g.add_child(action)
	return g
