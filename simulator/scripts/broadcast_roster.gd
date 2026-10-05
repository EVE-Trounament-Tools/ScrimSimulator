class_name BroadcastRoster
extends PanelContainer
## Tournament-broadcast style ship data: one team down each side, mirrored about a centre column
## with the match clock. Each row shows points, pilot, speed, shield/armor/hull bars, ship type
## and the electronic warfare on the ship (nearest the centre, at most `MAX_EWAR_ICONS`).
## Points and the hit point bars are placeholders for now.

## A row was clicked.
signal row_pressed(pilot: String)

enum Side { LEFT, RIGHT }

## id -> header title, alignment and width (px), in left-side order (the right side is mirrored).
## `bar` columns hold a placeholder hit point bar.
const COLUMNS := {
	"pts": {"title": "PTS", "align": HORIZONTAL_ALIGNMENT_LEFT, "width": 36},
	"name": {"title": "NAME", "align": HORIZONTAL_ALIGNMENT_LEFT, "width": 140},
	"speed": {"title": "SPEED", "align": HORIZONTAL_ALIGNMENT_LEFT, "width": 72},
	"hull": {"title": "HULL", "align": HORIZONTAL_ALIGNMENT_CENTER, "width": 44, "bar": true},
	"armor": {"title": "ARM", "align": HORIZONTAL_ALIGNMENT_CENTER, "width": 44, "bar": true},
	"shield": {"title": "SHLD", "align": HORIZONTAL_ALIGNMENT_CENTER, "width": 44, "bar": true},
	"ship": {"title": "SHIP", "align": HORIZONTAL_ALIGNMENT_LEFT, "width": 110},
	"ewar": {"title": "", "align": HORIZONTAL_ALIGNMENT_LEFT, "width": 0},
}
const MAX_EWAR_ICONS := 5
const EWAR_SEPARATION := 2
const EWAR_W := MAX_EWAR_ICONS * RosterTable.ICON_PX + (MAX_EWAR_ICONS - 1) * EWAR_SEPARATION
const CELL_GAP := 6
const BAR_H := 8.0
const BAR_COLOR := Color(0.75, 0.75, 0.75, 0.8)
const CENTRE_W := 170.0
const CLOCK_COLOR := Color(1.0, 0.9, 0.3)
const BACKGROUND := Color(0.04, 0.05, 0.07, 0.92)

## Side -> { team: Label, points: Label, rows: VBoxContainer }.
var sides := {}
var clock: Label
## pilot -> { side, button, cells (HBoxContainer), labels: { column id -> Label or bar },
## ewar (HBoxContainer) }.
var rows := {}


func _init() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = BACKGROUND
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	add_theme_stylebox_override("panel", style)
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	add_child(box)
	box.add_child(_side(Side.LEFT))
	var centre := VBoxContainer.new()
	centre.custom_minimum_size.x = CENTRE_W
	box.add_child(centre)
	clock = Label.new()
	clock.text = "00:00"
	clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	clock.add_theme_color_override("font_color", CLOCK_COLOR)
	clock.add_theme_font_size_override("font_size", 22)
	centre.add_child(clock)
	var feed := Label.new()
	feed.text = "BATTLEFEED"
	feed.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	feed.modulate = Color(1, 1, 1, 0.7)
	centre.add_child(feed)
	box.add_child(_side(Side.RIGHT))


## Column ids in display order on `side`: the left side's run outward-in, the right's mirrored.
static func column_ids(side: int) -> Array:
	var ids := COLUMNS.keys()
	if side == Side.RIGHT:
		ids.reverse()
	return ids


## One team's half: a coloured title bar (name and points), the column header and the rows.
func _side(side: int) -> VBoxContainer:
	var half := VBoxContainer.new()
	half.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	half.add_theme_constant_override("separation", 2)
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", StyleBoxFlat.new())
	half.add_child(bar)
	var title := HBoxContainer.new()
	title.add_theme_constant_override("separation", 16)
	title.alignment = BoxContainer.ALIGNMENT_END if side == Side.LEFT else BoxContainer.ALIGNMENT_BEGIN
	bar.add_child(title)
	var team := Label.new()
	team.add_theme_font_size_override("font_size", 20)
	var points := Label.new()
	points.text = "0"
	points.add_theme_font_size_override("font_size", 20)
	for label in ([team, points] if side == Side.LEFT else [points, team]):
		title.add_child(label)
	var head := _cells(side)
	head.size_flags_horizontal = _toward_centre(side)
	head.modulate = Color(1, 1, 1, 0.7)
	for id in column_ids(side):
		var label := _cell(id, side)
		label.text = COLUMNS[id].title
		head.add_child(label)
	half.add_child(head)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 0)
	half.add_child(body)
	sides[side] = {"bar": bar, "team": team, "points": points, "rows": body}
	return half


## Rows and headers hug the centre column.
static func _toward_centre(side: int) -> int:
	return Control.SIZE_SHRINK_END if side == Side.LEFT else Control.SIZE_SHRINK_BEGIN


static func _cells(side: int) -> HBoxContainer:
	var cells := HBoxContainer.new()
	cells.add_theme_constant_override("separation", CELL_GAP)
	cells.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return cells


## A text cell of column `id`, its alignment mirrored on the right side.
static func _cell(id: String, side: int) -> Label:
	var label := Label.new()
	var align: HorizontalAlignment = COLUMNS[id].align
	if side == Side.RIGHT and align == HORIZONTAL_ALIGNMENT_LEFT:
		align = HORIZONTAL_ALIGNMENT_RIGHT
	label.horizontal_alignment = align
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.custom_minimum_size.x = EWAR_W if id == "ewar" else COLUMNS[id].width
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


## Names and colours each side's team.
func set_teams(left_name: String, left_color: Color, right_name: String, right_color: Color) -> void:
	for side in sides:
		var color := left_color if side == Side.LEFT else right_color
		sides[side].team.text = (left_name if side == Side.LEFT else right_name).to_upper()
		var style: StyleBoxFlat = sides[side].bar.get_theme_stylebox("panel")
		style.bg_color = color.darkened(0.45)
		style.content_margin_left = 8
		style.content_margin_right = 8


func team_text(side: int) -> String:
	return sides[side].team.text


func points_text(side: int) -> String:
	return sides[side].points.text


func clear() -> void:
	for side in sides:
		var body: VBoxContainer = sides[side].rows
		for c in body.get_children():
			body.remove_child(c)
			c.queue_free()
	rows.clear()


## A pilot row on `side`, drawn in `color`; clicking it emits `row_pressed`.
func add_row(side: int, pilot: String, color: Color) -> Button:
	var button := Button.new()
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	button.size_flags_horizontal = _toward_centre(side)
	button.pressed.connect(func(): row_pressed.emit(pilot))
	sides[side].rows.add_child(button)
	var cells := _cells(side)
	cells.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	button.add_child(cells)
	var labels := {}
	var ewar: HBoxContainer
	for id in column_ids(side):
		var cell: Control
		if COLUMNS[id].get("bar", false):
			cell = _bar(COLUMNS[id].width)
		elif id == "ewar":
			ewar = HBoxContainer.new()
			ewar.add_theme_constant_override("separation", EWAR_SEPARATION)
			ewar.alignment = BoxContainer.ALIGNMENT_BEGIN if side == Side.LEFT else BoxContainer.ALIGNMENT_END
			ewar.custom_minimum_size.x = EWAR_W
			ewar.mouse_filter = Control.MOUSE_FILTER_IGNORE
			cell = ewar
		else:
			cell = _cell(id, side)
			cell.add_theme_color_override("font_color", color)
		cells.add_child(cell)
		labels[id] = cell
	labels.pts.text = "0"
	var size := cells.get_combined_minimum_size()
	button.custom_minimum_size = Vector2(size.x, maxf(size.y, RosterTable.ICON_PX) + 2.0)
	rows[pilot] = {"side": side, "button": button, "cells": cells, "labels": labels, "ewar": ewar}
	return button


## A placeholder hit point bar, full.
static func _bar(width: float) -> Control:
	var holder := CenterContainer.new()
	holder.custom_minimum_size.x = width
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rect := ColorRect.new()
	rect.color = BAR_COLOR
	rect.custom_minimum_size = Vector2(width, BAR_H)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(rect)
	return holder


func set_cell(pilot: String, id: String, text: String) -> void:
	rows[pilot].labels[id].text = text


func cell_text(pilot: String, id: String) -> String:
	return rows[pilot].labels[id].text


## Shows `items` (as `RosterTable.set_cell_icons`) next to `pilot`'s ship type: the first
## `MAX_EWAR_ICONS`, the rest dropped.
func set_ewar(pilot: String, items: Array) -> void:
	var row: Dictionary = rows[pilot]
	var color: Color = row.labels.ship.get_theme_color("font_color")
	RosterTable.fill_icons(row.ewar, items.slice(0, MAX_EWAR_ICONS), color)


func set_dimmed(pilot: String, on: bool) -> void:
	rows[pilot].button.modulate.a = 0.5 if on else 1.0


func set_clock(text: String) -> void:
	clock.text = text
