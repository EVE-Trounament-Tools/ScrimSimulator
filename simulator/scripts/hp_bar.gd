class_name HpBar
extends RefCounted
## A horizontal hit point bar for one layer (shield, armor or hull), shared by the roster views:
## light where HP remains and red where it's lost, like the locked-target rings in EVE, or grey
## when unknown (no observer had the ship locked).

const REMAINING := Color(0.85, 0.85, 0.85)
const LOST := Color(0.55, 0.12, 0.12)
const UNKNOWN := Color(0.35, 0.35, 0.35, 0.6)


## A bar `width` x `height` px (`width` 0: as wide as its container lets it), unknown. Its tooltip
## names `layer`, if given.
static func make(width: float, height: float, layer := "") -> Control:
	var bar := ColorRect.new()
	bar.color = UNKNOWN
	bar.custom_minimum_size = Vector2(width, height)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_PASS
	if not layer.is_empty():
		bar.set_meta("layer", layer)
	bar.tooltip_text = _prefix(bar) + "Not locked"
	var fill := ColorRect.new()
	fill.color = REMAINING
	fill.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	fill.anchor_right = 0.0
	fill.visible = false
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(fill)
	bar.set_meta("fraction", NAN)
	return bar


## Shows `fraction` (0-1) of the layer remaining, or unknown when NAN. Does nothing when
## unchanged, so it is cheap to call every frame.
static func set_fraction(bar: Control, fraction: float) -> void:
	var old: float = bar.get_meta("fraction")
	if fraction == old or (is_nan(fraction) and is_nan(old)):
		return
	bar.set_meta("fraction", fraction)
	var fill: ColorRect = bar.get_child(0)
	var prefix := _prefix(bar)
	fill.visible = not is_nan(fraction)
	if is_nan(fraction):
		bar.color = UNKNOWN
		bar.tooltip_text = prefix + "Not locked"
		return
	bar.color = LOST
	fill.anchor_right = clampf(fraction, 0.0, 1.0)
	fill.offset_right = 0.0
	bar.tooltip_text = prefix + "%d%%" % roundi(fraction * 100.0)


static func get_fraction(bar: Control) -> float:
	return bar.get_meta("fraction")


static func _prefix(bar: Control) -> String:
	return "%s: " % bar.get_meta("layer") if bar.has_meta("layer") else ""
