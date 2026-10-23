class_name LibraryTree
extends Tree
## The `MainMenu`'s list of library folders and matches. Each item's metadata says what it is:
## `{ kind: "folder", rel }` or `{ kind: "match", path, folder }` (see `MatchLibrary`). Matches
## and folders can be dragged onto a folder (or a match in it), or onto empty space for the
## library itself.

## `what` (an item's metadata) was dropped onto folder `folder`.
signal dropped(what: Dictionary, folder: String)

## Set: nothing can be dragged (a website viewer, who can't change the library).
var read_only := false


func _init() -> void:
	hide_root = true
	allow_rmb_select = true
	drop_mode_flags = DROP_MODE_ON_ITEM


## The match items, in tree order.
func match_items() -> Array:
	return _items().filter(func(it): return it.get_metadata(0).kind == "match")


## Folder `rel`'s item, or null.
func folder_item(rel: String) -> TreeItem:
	for it in _items():
		if it.get_metadata(0).kind == "folder" and it.get_metadata(0).rel == rel:
			return it
	return null


## Every item but the hidden root, in tree order.
func _items() -> Array:
	var out := []
	var it := get_root().get_next_in_tree() if get_root() else null
	while it:
		out.append(it)
		it = it.get_next_in_tree()
	return out


## The folder something dropped at `at` lands in ("" for empty space), or null if `what` can't
## go there (where it already is, or a folder into itself).
func drop_folder(at: Vector2, what: Variant) -> Variant:
	if not (what is Dictionary and what.has("kind")):
		return null
	var item := get_item_at_position(at)
	var folder: String = ""
	if item:
		var meta: Dictionary = item.get_metadata(0)
		folder = meta.rel if meta.kind == "folder" else meta.folder
	if what.kind == "match":
		return null if folder == what.folder else folder
	if folder == what.rel or folder.begins_with(what.rel + "/") or folder == what.rel.get_base_dir():
		return null
	return folder


func _get_drag_data(at: Vector2) -> Variant:
	var item := get_item_at_position(at)
	if item == null or read_only:
		return null
	var preview := Label.new()
	preview.text = item.get_text(0)
	set_drag_preview(preview)
	return item.get_metadata(0)


func _can_drop_data(at: Vector2, data: Variant) -> bool:
	return drop_folder(at, data) != null


func _drop_data(at: Vector2, data: Variant) -> void:
	var folder: Variant = drop_folder(at, data)
	if folder != null:
		dropped.emit(data, folder)
