class_name RosterTable
extends VBoxContainer
## Spreadsheet-style roster: a fixed header over scrolling pilot rows, grouped under team labels.
## Drag the grip left of the first column to resize the whole table, drag a grip between columns
## to trade width between them, double-click a column's right grip to fit it to its contents,
## drag a header to move it, and right-click the header to choose which columns are shown. The
## layout persists in setting `roster/columns`. Columns can also be made unavailable (no data for
## them): they are hidden without touching the saved layout. Rows can be highlighted while their
## ship takes damage.

signal row_pressed(pilot: String)
signal swap_pressed(pilot: String)
## A pilot row was right-clicked.
signal row_context_pressed(pilot: String)
## A team label added with a `key` was double-clicked.
signal group_activated(key: int)
## Column widths, order or visibility changed.
signal layout_changed

## id -> title, alignment and default width (px), in default display order. `icons` columns hold
## a row of icons (`set_cell_icons`) and `hp` columns shield, armor and hull bars (`set_cell_hp`)
## instead of text. `missing` is the menu tooltip while a column is unavailable.
const COLUMNS := {
	"ship": {"title": "Ship", "align": HORIZONTAL_ALIGNMENT_LEFT, "width": 110},
	"pilot": {"title": "Pilot", "align": HORIZONTAL_ALIGNMENT_LEFT, "width": 110},
	"speed": {"title": "Speed", "align": HORIZONTAL_ALIGNMENT_RIGHT, "width": 70},
	"distance": {"title": "Centre", "align": HORIZONTAL_ALIGNMENT_RIGHT, "width": 70},
	"hp": {"title": "HP", "align": HORIZONTAL_ALIGNMENT_CENTER, "width": 90, "hp": true, "missing": "No HP data in this CSV"},
	"dmg_in": {"title": "Dmg in", "align": HORIZONTAL_ALIGNMENT_RIGHT, "width": 72},
	"dmg_out": {"title": "Dmg out", "align": HORIZONTAL_ALIGNMENT_RIGHT, "width": 72},
	"rep_in": {"title": "Reps in", "align": HORIZONTAL_ALIGNMENT_RIGHT, "width": 72},
	"rep_out": {"title": "Reps out", "align": HORIZONTAL_ALIGNMENT_RIGHT, "width": 72},
	"cap_in": {"title": "Cap in", "align": HORIZONTAL_ALIGNMENT_RIGHT, "width": 72},
	"cap_out": {"title": "Cap out", "align": HORIZONTAL_ALIGNMENT_RIGHT, "width": 72},
	"ewar_in": {"title": "EWAR in", "align": HORIZONTAL_ALIGNMENT_LEFT, "width": 90, "icons": true},
	"ewar_out": {"title": "EWAR out", "align": HORIZONTAL_ALIGNMENT_LEFT, "width": 90, "icons": true},
}
const MIN_WIDTH := 30.0
## Width of the resize grips around header cells (and the matching gaps between row cells).
const HANDLE_W := 6.0
## Extra room auto-size leaves beyond a column's widest text.
const AUTOSIZE_PAD := 8.0
## The table never grows wider than this fraction of the viewport by dragging its edge.
const MAX_VIEWPORT_FRACTION := 0.9
## Width of each row's team swap button, mirrored by a spacer at the end of the header.
const SWAP_W := 28.0
## Size of the icons in `icons` columns.
const ICON_PX := 24.0
## Height of the bars in `hp` columns.
const HP_BAR_H := 8.0
## Row background while its ship takes damage.
const DAMAGE_COLOR := Color(0.9, 0.15, 0.1, 0.35)
const SETTING := "roster/columns"

## Display order of { id, width, visible }.
var columns: Array = []
var header: HBoxContainer
var scroll: ScrollContainer
var body: VBoxContainer
var menu: PopupMenu
## Column id -> its header Label.
var header_cells := {}
## pilot -> { button, cells (HBoxContainer), labels: { column id -> Label, or HBoxContainer for
## `icons` and `hp` columns }, damage (ColorRect behind the cells, shown while taking damage) }.
var rows := {}
## Column id -> true for columns hidden because there is nothing to show in them.
var unavailable := {}
## Grip being dragged ({} = none): { kind: "edge" | "divider", id, x }, plus the column widths
## when the drag started (id -> width).
var _drag := {}
var _drag_widths := {}


func _init() -> void:
	add_theme_constant_override("separation", 2)
	header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 0)
	header.mouse_filter = Control.MOUSE_FILTER_STOP
	header.gui_input.connect(_on_header_input)
	add_child(header)
	scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	body = VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	menu = PopupMenu.new()
	menu.hide_on_checkable_item_selection = false
	for id in COLUMNS:
		menu.add_check_item(COLUMNS[id].title)
	menu.index_pressed.connect(func(i): set_column_visible(COLUMNS.keys()[i], not _column(COLUMNS.keys()[i]).visible))
	add_child(menu)
	columns = _load_columns(Settings.get_value(SETTING))
	_apply_layout()


## Saved layout, repaired: unknown ids dropped, missing ones appended, widths clamped, and at
## least one column visible.
static func _load_columns(saved: Variant) -> Array:
	var out := []
	if saved is Array:
		for c in saved:
			if c is Dictionary and COLUMNS.has(c.get("id")) and not out.any(func(o): return o.id == c.id):
				out.append({
					"id": c.id,
					"width": maxf(float(c.get("width", COLUMNS[c.id].width)), MIN_WIDTH),
					"visible": bool(c.get("visible", true)),
				})
	for id in COLUMNS:
		if not out.any(func(o): return o.id == id):
			out.append({"id": id, "width": float(COLUMNS[id].width), "visible": true})
	if not out.any(func(o): return o.visible):
		out[0].visible = true
	return out


func _column(id: String) -> Dictionary:
	for c in columns:
		if c.id == id:
			return c
	return {}


## Ids of the shown columns, in display order.
func visible_ids() -> Array:
	return columns.filter(_shown).map(func(c): return c.id)


## Whether column `c` is shown: picked by the user and available.
func _shown(c: Dictionary) -> bool:
	return c.visible and not unavailable.has(c.id)


## Makes column `id` available (shown if the user picked it) or not (hidden, its menu item
## disabled). Not saved: the layout keeps the user's choice.
func set_column_available(id: String, on: bool) -> void:
	if on == not unavailable.has(id):
		return
	if on:
		unavailable.erase(id)
	else:
		unavailable[id] = true
	_apply_layout()
	layout_changed.emit()


func set_column_width(id: String, width: float) -> void:
	_column(id).width = maxf(width, MIN_WIDTH)
	_changed()


## Moves column `id` to position `index` in the display order.
func move_column(id: String, index: int) -> void:
	var c := _column(id)
	var from := columns.find(c)
	columns.remove_at(from)
	columns.insert(clampi(index, 0, columns.size()), c)
	_changed()


## Shows or hides column `id`; the last shown column can't be hidden.
func set_column_visible(id: String, on: bool) -> void:
	if not on and visible_ids() == [id]:
		return
	_column(id).visible = on
	_changed()


## Moves the boundary right of column `left_id` by `dx` px: it grows and the next shown column
## shrinks by the same amount (neither below `MIN_WIDTH`), so the total width is unchanged.
func move_divider(left_id: String, dx: float) -> void:
	_move_divider(left_id, dx)
	_changed()


## Scales every shown column so they add up to `total` px (each at least `MIN_WIDTH`).
func set_total_width(total: float) -> void:
	_scale_to(total)
	_changed()


## Sizes column `id` to fit its header and every row's text.
func autosize(id: String) -> void:
	var label: Label = header_cells.get(id, null)
	if label == null:
		return
	var font := label.get_theme_font("font")
	var font_size := label.get_theme_font_size("font_size")
	var texts: Array = [COLUMNS[id].title]
	var width := 0.0
	for pilot in rows:
		var cell: Control = rows[pilot].labels[id]
		if cell is Label:
			texts.append(cell.text)
		elif COLUMNS[id].get("hp", false):
			return  # Bars fill whatever width they're given.
		else:
			width = maxf(width, icon_box(pilot, id).get_combined_minimum_size().x)
	for text in texts:
		width = maxf(width, font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	_column(id).width = maxf(ceilf(width + AUTOSIZE_PAD), MIN_WIDTH)
	_changed()


## Sum of the shown columns' widths.
func total_width() -> float:
	var total := 0.0
	for c in columns:
		if _shown(c):
			total += c.width
	return total


func _move_divider(left_id: String, dx: float) -> void:
	var ids := visible_ids()
	var k := ids.find(left_id)
	if k < 0 or k + 1 >= ids.size():
		return
	var left := _column(left_id)
	var right := _column(ids[k + 1])
	dx = clampf(dx, MIN_WIDTH - left.width, right.width - MIN_WIDTH)
	left.width += dx
	right.width -= dx


func _scale_to(total: float) -> void:
	if is_inside_tree():
		total = minf(total, get_viewport_rect().size.x * MAX_VIEWPORT_FRACTION)
	var old := total_width()
	if old <= 0.0:
		return
	for c in columns:
		if _shown(c):
			c.width = maxf(c.width * total / old, MIN_WIDTH)


func _changed() -> void:
	Settings.set_value(SETTING, columns.duplicate(true))
	_apply_layout()
	layout_changed.emit()


# --- rows --------------------------------------------------------------------

func clear() -> void:
	for c in body.get_children():
		body.remove_child(c)
		c.queue_free()
	rows.clear()


## A full-width, centred team label; with a `key` (>= 0), double-clicking it emits
## `group_activated(key)`.
func add_group(text: String, color: Color, key := -1, tooltip := "") -> Label:
	var label := Label.new()
	label.text = text
	label.modulate = color
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if key >= 0:
		label.mouse_filter = Control.MOUSE_FILTER_STOP
		label.tooltip_text = tooltip
		label.gui_input.connect(func(event: InputEvent):
			if event is InputEventMouseButton and event.double_click and event.button_index == MOUSE_BUTTON_LEFT:
				group_activated.emit(key)
				label.accept_event())
	body.add_child(label)
	return label


## A pilot row: a toggle button spanning the cells (right-click: `row_context_pressed`), then a
## team swap button. Returns the row button.
func add_row(pilot: String, color: Color, swap_tooltip: String) -> Button:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	body.add_child(row)
	var button := Button.new()
	button.toggle_mode = true
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(func(): row_pressed.emit(pilot))
	button.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
			row_context_pressed.emit(pilot)
			button.accept_event())
	row.add_child(button)
	var damage := ColorRect.new()
	damage.color = DAMAGE_COLOR
	damage.visible = false
	damage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	damage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	button.add_child(damage)
	var cells := HBoxContainer.new()
	cells.add_theme_constant_override("separation", int(HANDLE_W))
	cells.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cells.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	button.add_child(cells)
	var labels := {}
	for id in COLUMNS:
		var cell: Control
		if COLUMNS[id].get("icons", false):
			cell = _icon_cell(color)
		elif COLUMNS[id].get("hp", false):
			cell = _hp_cell()
		else:
			cell = _cell(COLUMNS[id].align)
			cell.add_theme_color_override("font_color", color)
		cells.add_child(cell)
		labels[id] = cell
	var swap := Button.new()
	swap.text = "⇄"
	swap.custom_minimum_size.x = SWAP_W
	swap.focus_mode = Control.FOCUS_NONE
	swap.tooltip_text = swap_tooltip
	swap.pressed.connect(func(): swap_pressed.emit(pilot))
	row.add_child(swap)
	rows[pilot] = {"button": button, "cells": cells, "labels": labels, "damage": damage}
	_layout_row(rows[pilot])
	return button


func set_cell(pilot: String, id: String, text: String) -> void:
	rows[pilot].labels[id].text = text


func cell_text(pilot: String, id: String) -> String:
	return rows[pilot].labels[id].text


## Shows `pilot`'s remaining shield, armor and hull (`hp` x, y, z: 0-1, NAN when unknown) in
## `hp` column `id`.
func set_cell_hp(pilot: String, id: String, hp: Vector3) -> void:
	var bars: HBoxContainer = rows[pilot].labels[id]
	for i in 3:
		HpBar.set_fraction(bars.get_child(i), hp[i])


## Highlights `pilot`'s row (taking damage) or not.
func set_row_damaged(pilot: String, on: bool) -> void:
	rows[pilot].damage.visible = on


func is_row_damaged(pilot: String) -> bool:
	return rows[pilot].damage.visible


## Fills `icons` column `id` of `pilot`'s row with `items`, each { key, texture, text, tooltip }:
## the texture, or `text` when it is null, with its own tooltip (clicks still reach the row). Does
## nothing when the items are the same as last time, so it is cheap to call every frame.
func set_cell_icons(pilot: String, id: String, items: Array) -> void:
	var cell := icon_box(pilot, id)
	fill_icons(cell, items, cell.get_meta("color", Color.WHITE))


## Fills `box` with `items` (see `set_cell_icons`); text items are drawn in `color`. Does nothing
## when the items are the same as last time.
static func fill_icons(box: HBoxContainer, items: Array, color: Color) -> void:
	var signature := "\n".join(items.map(func(i): return "%s|%s|%s" % [i.key, i.texture != null, i.tooltip]))
	if box.get_meta("signature", "") == signature:
		return
	box.set_meta("signature", signature)
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	for item in items:
		var child: Control
		if item.texture != null:
			var rect := TextureRect.new()
			rect.texture = item.texture
			rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			rect.custom_minimum_size = Vector2(ICON_PX, ICON_PX)
			rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			child = rect
		else:
			var label := Label.new()
			label.text = item.text
			label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			label.add_theme_color_override("font_color", color)
			child = label
		child.tooltip_text = item.tooltip
		child.mouse_filter = Control.MOUSE_FILTER_PASS
		child.set_meta("key", item.key)
		box.add_child(child)


## An `icons` cell: a clipping Control (so extra icons don't widen the row) around a row of icons.
static func _icon_cell(color: Color) -> Control:
	var cell := Control.new()
	cell.clip_contents = true
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	box.set_meta("color", color)
	cell.add_child(box)
	return cell


## An `hp` cell: shield, armor and hull bars side by side, sharing the column's width.
static func _hp_cell() -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for layer in ["Shield", "Armor", "Hull"]:
		var bar := HpBar.make(0.0, HP_BAR_H, layer)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_child(bar)
	return box


## The icon row of `pilot`'s `icons` column `id`.
func icon_box(pilot: String, id: String) -> HBoxContainer:
	return rows[pilot].labels[id].get_child(0)


static func _cell(align: HorizontalAlignment) -> Label:
	var label := Label.new()
	label.horizontal_alignment = align
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


# --- layout ------------------------------------------------------------------

## Rebuilds the header and re-orders, re-sizes and shows/hides every row's cells.
func _apply_layout() -> void:
	for c in header.get_children():
		header.remove_child(c)
		c.queue_free()
	header_cells.clear()
	var ids := visible_ids()
	header.add_child(_handle("edge", ""))
	for c in columns:
		if not _shown(c):
			continue
		var label := _cell(HORIZONTAL_ALIGNMENT_CENTER)
		label.text = COLUMNS[c.id].title
		label.custom_minimum_size.x = c.width
		label.modulate = Color(1, 1, 1, 0.7)
		label.mouse_filter = Control.MOUSE_FILTER_STOP
		label.tooltip_text = "Drag to move, drag the edge to resize, right-click to show/hide columns"
		label.gui_input.connect(_on_header_input)
		label.set_drag_forwarding(_drag_column.bind(c.id, label), _can_drop_column.bind(label),
				_drop_column.bind(c.id, label))
		header.add_child(label)
		header_cells[c.id] = label
		header.add_child(_handle("last" if c.id == ids[-1] else "divider", c.id))
	var spacer := Control.new()
	spacer.custom_minimum_size.x = SWAP_W
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(spacer)
	for i in menu.item_count:
		var id: String = COLUMNS.keys()[i]
		menu.set_item_checked(i, _column(id).visible)
		menu.set_item_disabled(i, unavailable.has(id) or visible_ids() == [id])
		menu.set_item_tooltip(i, COLUMNS[id].get("missing", "No combat log data") if unavailable.has(id) else "")
	for pilot in rows:
		_layout_row(rows[pilot])


func _layout_row(row: Dictionary) -> void:
	var width := HANDLE_W
	var i := 0
	for c in columns:
		var cell: Control = row.labels[c.id]
		row.cells.move_child(cell, i)
		i += 1
		cell.visible = _shown(c)
		cell.custom_minimum_size.x = c.width
		if cell.visible:
			width += c.width + HANDLE_W
	row.cells.offset_left = HANDLE_W
	var button: Button = row.button
	button.custom_minimum_size = Vector2(width, row.cells.get_combined_minimum_size().y + 4.0)


## A resize grip: `kind` "edge" (left of the first column: resizes the table), "divider"
## (right of column `id`: moves the boundary with the next column) or "last" (right of the last
## column: not draggable). Double-clicking a divider or the last grip auto-sizes column `id`.
func _handle(kind: String, id: String) -> Control:
	var handle := Control.new()
	handle.custom_minimum_size.x = HANDLE_W
	if kind != "last":
		handle.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	match kind:
		"edge":
			handle.tooltip_text = "Drag to resize the table"
		"divider":
			handle.tooltip_text = "Drag to trade width with the next column, double-click to fit %s" % COLUMNS[id].title
		"last":
			handle.tooltip_text = "Double-click to fit %s" % COLUMNS[id].title
	handle.draw.connect(func():
		var x := HANDLE_W / 2.0
		handle.draw_line(Vector2(x, 2), Vector2(x, handle.size.y - 2), Color(1, 1, 1, 0.2)))
	handle.gui_input.connect(_on_handle_input.bind(kind, id))
	return handle


func _on_handle_input(event: InputEvent, kind: String, id: String) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and event.double_click:
			_drag = {}
			if kind != "edge":
				autosize(id)
		elif event.pressed:
			if kind != "last":
				_drag = {"kind": kind, "id": id, "x": event.global_position.x}
				_drag_widths = {}
				for c in columns:
					_drag_widths[c.id] = c.width
		elif not _drag.is_empty():
			_drag = {}
			_changed()  # Saves the final widths.
		accept_event()
	elif event is InputEventMouseMotion and not _drag.is_empty() and _drag.kind == kind and _drag.id == id:
		# Re-apply from the widths at the press, live, without saving on every motion event.
		for c in columns:
			c.width = _drag_widths[c.id]
		var dx: float = event.global_position.x - _drag.x
		if kind == "edge":
			var start := total_width()
			_scale_to(start - dx)  # The grip is on the left: dragging left widens.
		else:
			_move_divider(id, dx)
		for c in columns:
			if header_cells.has(c.id):
				header_cells[c.id].custom_minimum_size.x = c.width
		for pilot in rows:
			_layout_row(rows[pilot])
		layout_changed.emit()
		accept_event()


func _on_header_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		menu.popup(Rect2i(Vector2i(get_screen_position() + get_local_mouse_position()), Vector2i.ZERO))
		accept_event()


func _drag_column(_at: Vector2, id: String, label: Label) -> Variant:
	var preview := Label.new()
	preview.text = COLUMNS[id].title
	label.set_drag_preview(preview)
	return {"roster_column": id}


func _can_drop_column(_at: Vector2, data: Variant, _label: Label) -> bool:
	return data is Dictionary and data.has("roster_column")


## Drops a dragged column before or after `id`, by which half of its header the cursor is in.
func _drop_column(at: Vector2, data: Variant, id: String, label: Label) -> void:
	var moved: String = data.roster_column
	if moved == id:
		return
	var c := _column(moved)
	var rest := columns.filter(func(o): return o != c)
	var index := rest.find(_column(id)) + (1 if at.x > label.size.x / 2.0 else 0)
	move_column(moved, index)
