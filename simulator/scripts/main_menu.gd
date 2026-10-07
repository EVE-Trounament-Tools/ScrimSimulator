class_name MainMenu
extends PanelContainer
## Full-screen start menu: pick a match from the `MatchLibrary`, add a new CSV or a whole scrim
## folder to it, rename or remove one, attach audio to one, add combat logs (EVE gamelogs) to the
## matches of a folder, sort matches into folders (right-click for all of these, or drag to
## move). Covers the viewer until a match is chosen.

## The library path of the match to open.
signal match_chosen(path: String)
## "Back to match" pressed: return to the match that is already open.
signal resumed
## A library match was renamed (its file moved from `old_path` to `new_path`).
signal match_renamed(old_path: String, new_path: String)
## Library match `path` got, lost or replaced its audio file.
signal audio_changed(path: String)
## Library match `path` got or lost combat logs.
signal logs_changed(path: String)

enum MenuItem { ADD_AUDIO, REMOVE_AUDIO, ADD_LOGS, REMOVE_LOGS, RENAME, REMOVE, NEW_FOLDER, ADD_FOLDER, ADD_MATCH }

## Badge on matches with audio: a speaker.
const AUDIO_ICON_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
<path d="M2 6h3l4-3.5v11L5 10H2z" fill="#8fc3ff"/>
<path d="M11 5.5a3.5 3.5 0 0 1 0 5M12.8 3.5a6 6 0 0 1 0 9" stroke="#8fc3ff" stroke-width="1.4" fill="none" stroke-linecap="round"/>
</svg>"""
## Icon of folders.
const FOLDER_ICON_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
<path d="M1.5 3.5h5l1.5 1.5h6.5v8h-13z" fill="#d9b25f"/>
</svg>"""

var list: LibraryTree
var open_button: Button
var rename_button: Button
var remove_button: Button
var audio_button: Button
var resume_button: Button
var error_label: Label
var empty_label: Label
var add_dialog: FileDialog
var remove_dialog: ConfirmationDialog
var rename_dialog: RenameDialog
var audio_dialog: FileDialog
var logs_dialog: FileDialog
var folder_dialog: FileDialog
## Asks for the name of a new folder.
var new_folder_dialog: RenameDialog
## Right-click menu of a match, folder or empty space (`MenuItem` ids).
var context_menu: PopupMenu
## `context_menu`'s "Move to" submenu: ids index `move_targets`.
var move_menu: PopupMenu
## Folders listed in `move_menu` ("" for the library itself).
var move_targets: Array = []
var audio_icon: Texture2D
var folder_icon: Texture2D
## Same size as `audio_icon`, for matches without audio so names stay aligned.
var blank_icon: Texture2D
## Library entries (see `MatchLibrary.list`).
var entries: Array = []
## Folders whose items are collapsed in `list`.
var collapsed := {}
## Folder that a new folder goes into (set when `new_folder_dialog` is asked).
var _new_folder_parent := ""


func _init() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := get_theme_stylebox("panel").duplicate() as StyleBoxFlat
	panel.bg_color = Color(0.06, 0.07, 0.1)
	add_theme_stylebox_override("panel", panel)

	var center := CenterContainer.new()
	add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(680, 0)
	box.add_theme_constant_override("separation", 10)
	center.add_child(box)

	var title := Label.new()
	title.text = "Scrim Simulator"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	box.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Matches"
	subtitle.modulate = Color(1, 1, 1, 0.7)
	box.add_child(subtitle)

	list = LibraryTree.new()
	list.custom_minimum_size = Vector2(0, 360)
	list.item_activated.connect(_on_item_activated)
	list.item_selected.connect(_update_buttons)
	list.item_mouse_selected.connect(_on_item_mouse_selected)
	list.empty_clicked.connect(_on_empty_clicked)
	list.item_collapsed.connect(func(item: TreeItem):
		var meta: Dictionary = item.get_metadata(0)
		if meta.kind == "folder":
			if item.collapsed:
				collapsed[meta.rel] = true
			else:
				collapsed.erase(meta.rel))
	list.dropped.connect(move_item)
	box.add_child(list)

	empty_label = Label.new()
	empty_label.text = "No matches yet — Add match… / Add folder…, or drop a *.positions.csv or a scrim folder here"
	empty_label.modulate = Color(1, 1, 1, 0.6)
	box.add_child(empty_label)

	error_label = Label.new()
	error_label.modulate = Color(1.0, 0.45, 0.4)
	error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	error_label.visible = false
	box.add_child(error_label)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	box.add_child(buttons)

	open_button = Button.new()
	open_button.text = "Open"
	open_button.pressed.connect(_open_selected)
	buttons.add_child(open_button)

	var add_button := Button.new()
	add_button.text = "Add match…"
	add_button.pressed.connect(func(): add_dialog.popup_centered_ratio(0.6))
	buttons.add_child(add_button)

	var add_folder_button := Button.new()
	add_folder_button.text = "Add folder…"
	add_folder_button.tooltip_text = "Add a scrim's folder: its match CSVs, with audio and gamelogs paired by name"
	add_folder_button.pressed.connect(func(): folder_dialog.popup_centered_ratio(0.6))
	buttons.add_child(add_folder_button)

	var new_folder_button := Button.new()
	new_folder_button.text = "New folder…"
	new_folder_button.pressed.connect(func(): ask_new_folder(target_folder()))
	buttons.add_child(new_folder_button)

	rename_button = Button.new()
	rename_button.text = "Rename…"
	rename_button.pressed.connect(_ask_rename)
	buttons.add_child(rename_button)

	remove_button = Button.new()
	remove_button.text = "Remove"
	remove_button.pressed.connect(_confirm_remove)
	buttons.add_child(remove_button)

	audio_button = Button.new()
	audio_button.text = "Add audio…"
	audio_button.tooltip_text = "Attach an audio file (ogg, mp3, wav) that starts with the match data"
	audio_button.pressed.connect(_ask_audio)
	buttons.add_child(audio_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(spacer)

	resume_button = Button.new()
	resume_button.text = "Back to match"
	resume_button.visible = false
	resume_button.pressed.connect(func(): resumed.emit())
	buttons.add_child(resume_button)

	add_dialog = FileDialog.new()
	add_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	add_dialog.access = FileDialog.ACCESS_FILESYSTEM
	add_dialog.filters = PackedStringArray(["*.csv ; CSV files"])
	add_dialog.use_native_dialog = true
	add_dialog.file_selected.connect(add_file)
	add_child(add_dialog)

	remove_dialog = ConfirmationDialog.new()
	remove_dialog.title = "Remove match"
	remove_dialog.ok_button_text = "Remove"
	remove_dialog.confirmed.connect(_remove_selected)
	add_child(remove_dialog)

	rename_dialog = RenameDialog.new()
	rename_dialog.submitted.connect(rename_selected)
	add_child(rename_dialog)

	audio_dialog = FileDialog.new()
	audio_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	audio_dialog.access = FileDialog.ACCESS_FILESYSTEM
	audio_dialog.filters = PackedStringArray(["*.ogg, *.mp3, *.wav ; Audio files"])
	audio_dialog.use_native_dialog = true
	audio_dialog.file_selected.connect(add_audio)
	add_child(audio_dialog)

	logs_dialog = FileDialog.new()
	logs_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	logs_dialog.access = FileDialog.ACCESS_FILESYSTEM
	logs_dialog.filters = PackedStringArray(["*.txt ; EVE gamelogs"])
	logs_dialog.use_native_dialog = true
	logs_dialog.files_selected.connect(add_logs)
	add_child(logs_dialog)

	folder_dialog = FileDialog.new()
	folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
	folder_dialog.use_native_dialog = true
	folder_dialog.dir_selected.connect(add_folder)
	add_child(folder_dialog)

	new_folder_dialog = RenameDialog.new()
	new_folder_dialog.ok_button_text = "Create"
	new_folder_dialog.submitted.connect(func(text): create_folder(_new_folder_parent, text))
	add_child(new_folder_dialog)

	context_menu = PopupMenu.new()
	context_menu.id_pressed.connect(_on_context_item)
	add_child(context_menu)
	move_menu = PopupMenu.new()
	move_menu.id_pressed.connect(func(id): move_item(_selected_meta(), move_targets[id]))
	context_menu.add_child(move_menu)

	var img := Image.new()
	img.load_svg_from_string(FOLDER_ICON_SVG)
	folder_icon = ImageTexture.create_from_image(img)
	img = Image.new()
	img.load_svg_from_string(AUDIO_ICON_SVG)
	audio_icon = ImageTexture.create_from_image(img)
	var blank := Image.create_empty(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
	blank_icon = ImageTexture.create_from_image(blank)

	if OS.has_feature("web"):
		WebLibrary.attach(self)
	refresh()


## Reloads the list from the library, keeping the selected match or folder selected (else the
## first match).
func refresh() -> void:
	var was := _selected_meta()
	list.clear()
	var root := list.create_item()
	var parents := {"": root}
	var folders := MatchLibrary.folders()
	for rel in folders:
		var item := list.create_item(parents[rel.get_base_dir()])
		item.set_text(0, rel.get_file())
		item.set_icon(0, folder_icon)
		item.set_metadata(0, {"kind": "folder", "rel": rel})
		item.collapsed = collapsed.has(rel)
		parents[rel] = item
	entries = MatchLibrary.list()
	for e in entries:
		var item := list.create_item(parents[e.folder])
		item.set_text(0, "%s — %s" % [e.name, _fmt_date(e.modified)])
		item.set_icon(0, audio_icon if e.audio else blank_icon)
		item.set_metadata(0, {"kind": "match", "path": e.path, "folder": e.folder})
		var notes := []
		if e.audio:
			notes.append("Has audio")
		var logs := MatchLibrary.log_paths(e.path).size()
		if logs > 0:
			notes.append("%d combat log%s" % [logs, "" if logs == 1 else "s"])
		item.set_tooltip_text(0, "\n".join(notes))
	if not _select(was):
		var matches := list.match_items()
		if not matches.is_empty():
			_select(matches[0].get_metadata(0))
	empty_label.visible = entries.is_empty() and folders.is_empty()
	_update_buttons()
	if OS.has_feature("web"):
		WebLibrary.local_changed()


## Selects the item whose metadata is `meta` (by its path or folder), revealing it; false if
## there is none.
func _select(meta: Dictionary) -> bool:
	if meta.is_empty():
		return false
	var it := list.get_root().get_next_in_tree()
	while it:
		var m: Dictionary = it.get_metadata(0)
		if m.kind == meta.kind and (m.path == meta.path if m.kind == "match" else m.rel == meta.rel):
			var p := it.get_parent()
			while p:
				p.collapsed = false
				p = p.get_parent()
			it.select(0)
			list.scroll_to_item(it)
			return true
		it = it.get_next_in_tree()
	return false


## Shows `text` as an error under the list ("" hides it).
func show_error(text: String) -> void:
	error_label.text = text
	error_label.visible = text != ""


## Copies `src` into the library (the `target_folder`), selects it, and asks for it to be opened.
func add_file(src: String) -> void:
	var path := MatchLibrary.add(src, target_folder())
	if path == "":
		show_error("Failed to add %s" % src.get_file())
		return
	await TeamDb.ingest_paths([path])  # doesn't wait outside the web build
	show_error("")
	refresh()
	_select({"kind": "match", "path": path})
	match_chosen.emit(path)


## Adds scrim folder `src_dir` to the library, in the `target_folder` (`MatchLibrary.add_folder`),
## and selects its first match; what couldn't be added or paired is named in the error line.
func add_folder(src_dir: String) -> void:
	var added := MatchLibrary.add_folder(src_dir, target_folder())
	if added.matches.is_empty():
		show_error("No matches added from %s — it needs scrim-positions CSVs" % src_dir.simplify_path().get_file())
		return
	var notes := []
	if not added.failed.is_empty():
		notes.append("Not added: %s" % ", ".join(added.failed))
	if not added.unpaired_audio.is_empty():
		notes.append("No match for audio: %s" % ", ".join(added.unpaired_audio))
	await TeamDb.ingest_paths(added.matches)  # doesn't wait outside the web build
	show_error(". ".join(notes))
	collapsed.erase(added.folder)
	refresh()
	_select({"kind": "match", "path": added.matches[0]})


## Asks for the name of a new folder inside folder `parent`.
func ask_new_folder(parent: String) -> void:
	_new_folder_parent = parent
	new_folder_dialog.ask("New folder" if parent == "" else "New folder in %s" % parent, "", "Folder name")


## Makes folder `name` inside folder `parent` and selects it.
func create_folder(parent: String, name: String) -> void:
	var rel := MatchLibrary.create_folder(parent, name)
	if rel == "":
		show_error("Cannot make folder \"%s\": the name is empty, taken or ends in .logs" % name.strip_edges())
		return
	show_error("")
	refresh()
	_select({"kind": "folder", "rel": rel})


## Moves `what` (a `list` item's metadata: a match or folder) into folder `folder`, keeping it
## selected. The open match follows through `match_renamed`.
func move_item(what: Dictionary, folder: String) -> void:
	if what.is_empty():
		return
	if what.kind == "match":
		var path := MatchLibrary.move(what.path, folder)
		if path == "":
			show_error("Cannot move %s" % MatchLibrary.display_name(what.path.get_file()))
			return
		show_error("")
		refresh()
		_select({"kind": "match", "path": path})
		if path != what.path:
			match_renamed.emit(what.path, path)
		return
	var old := MatchLibrary.matches_in(what.rel)
	var rel := MatchLibrary.move_folder(what.rel, folder)
	if rel == "":
		show_error("Cannot move folder %s into %s" % [what.rel, folder if folder != "" else "the library"])
		return
	show_error("")
	_folder_moved(what.rel, rel, old)
	_select({"kind": "folder", "rel": rel})


## Folder `old_rel`, which held matches `old_paths`, is now `new_rel`: shows it and follows
## its matches.
func _folder_moved(old_rel: String, new_rel: String, old_paths: Array) -> void:
	if collapsed.has(old_rel):
		collapsed.erase(old_rel)
		collapsed[new_rel] = true
	refresh()
	if new_rel == old_rel:
		return
	var from := MatchLibrary.folder_abs(old_rel)
	var to := MatchLibrary.folder_abs(new_rel)
	for path in old_paths:
		match_renamed.emit(path, to + path.substr(from.length()))


## Copies audio file `src` into the library as the selected match's audio.
func add_audio(src: String) -> void:
	var path := selected_path()
	if path == "":
		return
	if MatchLibrary.set_audio(path, src) == "":
		show_error("Failed to add audio %s — use an ogg, mp3 or wav file" % src.get_file())
		return
	show_error("")
	refresh()
	audio_changed.emit(path)


## Saves the parts of EVE gamelogs `srcs` logged during each match of the `log_targets` as its
## combat logs (`MatchLibrary.add_log`), so one day-long gamelog reaches every match it covers.
## Matches without EVE times are skipped; gamelogs with combat during none of the matches are
## named in the error line.
func add_logs(srcs: PackedStringArray) -> void:
	var targets := log_targets()
	if targets.is_empty():
		return
	var added := {}
	var timed := false
	for path: String in targets:
		var data := MatchData.load_csv(path, {}, 0.0, true)
		if data == null or not data.has_eve_time():
			continue
		timed = true
		var changed := false
		for src in srcs:
			if MatchLibrary.add_log(path, src, data) != "":
				added[src] = true
				changed = true
		if changed:
			logs_changed.emit(path)
	if not timed:
		show_error("Can't add combat logs: no match here has EVE times (make its CSV with --chat-log or --t0)")
		return
	var failed := Array(srcs).filter(func(src): return not added.has(src)).map(func(src): return src.get_file())
	show_error("" if failed.is_empty() else "Not added (not a gamelog, or no combat during any match here): %s" % ", ".join(failed))
	refresh()


## The matches added gamelogs are checked against: every match in the selected folder (its
## subfolders included), or in the selected match's folder (just the library's top-level matches
## for a match outside any folder). Empty if nothing is selected.
func log_targets() -> Array:
	var meta := _selected_meta()
	match meta.get("kind"):
		"match":
			return MatchLibrary.matches_in(meta.folder)
		"folder":
			return MatchLibrary.matches_in(meta.rel)
	return []


## Deletes the selected match's combat logs.
func remove_logs_selected() -> void:
	var path := selected_path()
	if path == "" or MatchLibrary.log_paths(path).is_empty():
		return
	MatchLibrary.remove_logs(path)
	refresh()
	logs_changed.emit(path)


## Deletes the selected match's audio file.
func remove_audio_selected() -> void:
	var path := selected_path()
	if path == "" or MatchLibrary.audio_path(path) == "":
		return
	MatchLibrary.remove_audio(path)
	refresh()
	audio_changed.emit(path)


## The selected match's library path, or "" (also when a folder is selected).
func selected_path() -> String:
	var meta := _selected_meta()
	return meta.path if meta.get("kind") == "match" else ""


## The folder new things go into: the selected folder, the selected match's folder, or "" (the
## library itself).
func target_folder() -> String:
	var meta := _selected_meta()
	return meta.get("rel", meta.get("folder", ""))


## The selected item's metadata (see `LibraryTree`), or {}.
func _selected_meta() -> Dictionary:
	if list == null or list.get_root() == null:
		return {}
	var item := list.get_selected()
	return item.get_metadata(0) if item else {}


func _on_item_activated() -> void:
	var item := list.get_selected()
	if item and item.get_metadata(0).kind == "folder":
		item.collapsed = not item.collapsed
	else:
		_open_selected()


func _open_selected() -> void:
	var path := selected_path()
	if path != "":
		show_error("")
		match_chosen.emit(path)


func _ask_audio() -> void:
	if selected_path() != "":
		audio_dialog.popup_centered_ratio(0.6)


## Right-click: (the item is already selected) show its menu at the mouse.
func _on_item_mouse_selected(at: Vector2, button: int) -> void:
	if button == MOUSE_BUTTON_RIGHT:
		_update_buttons()
		open_context_menu(list.get_screen_position() + at)


## A click on empty space clears the selection (so new things go in the library itself); a
## right-click shows the library's menu.
func _on_empty_clicked(at: Vector2, button: int) -> void:
	list.deselect_all()
	_update_buttons()
	if button == MOUSE_BUTTON_RIGHT:
		open_context_menu(list.get_screen_position() + at)


## Shows the right-click menu of the selected match or folder (of the library itself if
## nothing is selected) at screen position `at`.
func open_context_menu(at: Vector2) -> void:
	var meta := _selected_meta()
	context_menu.clear()
	match meta.get("kind"):
		"match":
			var has_audio := MatchLibrary.audio_path(meta.path) != ""
			context_menu.add_item("Replace audio…" if has_audio else "Add audio…", MenuItem.ADD_AUDIO)
			context_menu.add_item("Remove audio", MenuItem.REMOVE_AUDIO)
			context_menu.set_item_disabled(context_menu.get_item_index(MenuItem.REMOVE_AUDIO), not has_audio)
			context_menu.add_item("Add combat logs…", MenuItem.ADD_LOGS)
			context_menu.add_item("Remove combat logs", MenuItem.REMOVE_LOGS)
			context_menu.set_item_disabled(context_menu.get_item_index(MenuItem.REMOVE_LOGS),
				MatchLibrary.log_paths(meta.path).is_empty())
			context_menu.add_separator()
			_add_move_submenu(meta)
			context_menu.add_item("Rename…", MenuItem.RENAME)
			context_menu.add_item("Remove match…", MenuItem.REMOVE)
		"folder":
			context_menu.add_item("New folder…", MenuItem.NEW_FOLDER)
			context_menu.add_item("Add match…", MenuItem.ADD_MATCH)
			context_menu.add_item("Add folder…", MenuItem.ADD_FOLDER)
			context_menu.add_item("Add combat logs…", MenuItem.ADD_LOGS)
			context_menu.set_item_disabled(context_menu.get_item_index(MenuItem.ADD_LOGS),
				MatchLibrary.matches_in(meta.rel).is_empty())
			context_menu.add_separator()
			_add_move_submenu(meta)
			context_menu.add_item("Rename…", MenuItem.RENAME)
			context_menu.add_item("Remove folder…", MenuItem.REMOVE)
		_:
			context_menu.add_item("New folder…", MenuItem.NEW_FOLDER)
			context_menu.add_item("Add match…", MenuItem.ADD_MATCH)
			context_menu.add_item("Add folder…", MenuItem.ADD_FOLDER)
	context_menu.reset_size()
	context_menu.popup(Rect2i(Vector2i(at), Vector2i.ZERO))


## Adds "Move to" to `context_menu`: the library and every folder, those `what` (a match or
## folder) can't move to disabled.
func _add_move_submenu(what: Dictionary) -> void:
	move_menu.clear()
	move_targets = [""] + MatchLibrary.folders()
	for i in move_targets.size():
		var rel: String = move_targets[i]
		move_menu.add_item("Library" if rel == "" else "    ".repeat(rel.count("/") + 1) + rel.get_file(), i)
		var here: bool = rel == what.folder if what.kind == "match" else (
			rel == what.rel or rel.begins_with(what.rel + "/") or rel == what.rel.get_base_dir())
		move_menu.set_item_disabled(i, here)
	context_menu.add_submenu_node_item("Move to", move_menu)


func _on_context_item(id: int) -> void:
	match id:
		MenuItem.ADD_AUDIO:
			_ask_audio()
		MenuItem.REMOVE_AUDIO:
			remove_audio_selected()
		MenuItem.ADD_LOGS:
			if not log_targets().is_empty():
				logs_dialog.popup_centered_ratio(0.6)
		MenuItem.REMOVE_LOGS:
			remove_logs_selected()
		MenuItem.RENAME:
			_ask_rename()
		MenuItem.REMOVE:
			_confirm_remove()
		MenuItem.NEW_FOLDER:
			ask_new_folder(target_folder())
		MenuItem.ADD_MATCH:
			add_dialog.popup_centered_ratio(0.6)
		MenuItem.ADD_FOLDER:
			folder_dialog.popup_centered_ratio(0.6)


func _confirm_remove() -> void:
	var meta := _selected_meta()
	match meta.get("kind"):
		"match":
			remove_dialog.title = "Remove match"
			remove_dialog.dialog_text = "Remove %s from the match list?\nThe copied CSV (and its audio and combat logs) is deleted; the original files are not touched." % MatchLibrary.display_name(meta.path.get_file())
		"folder":
			var n := MatchLibrary.matches_in(meta.rel).size()
			remove_dialog.title = "Remove folder"
			remove_dialog.dialog_text = "Remove folder %s and the %d match%s in it?\nThe copied CSVs (and their audio and combat logs) are deleted; the original files are not touched." % [meta.rel, n, "" if n == 1 else "es"]
		_:
			return
	remove_dialog.popup_centered()


func _remove_selected() -> void:
	var meta := _selected_meta()
	match meta.get("kind"):
		"match":
			MatchLibrary.remove(meta.path)
		"folder":
			MatchLibrary.remove_folder(meta.rel)
			collapsed.erase(meta.rel)
		_:
			return
	list.deselect_all()
	refresh()


func _ask_rename() -> void:
	var meta := _selected_meta()
	match meta.get("kind"):
		"match":
			rename_dialog.ask("Rename match", MatchLibrary.display_name(meta.path.get_file()))
		"folder":
			rename_dialog.ask("Rename folder", meta.rel.get_file())


## Renames the selected match or folder to `new_name`, keeping it selected.
func rename_selected(new_name: String) -> void:
	var meta := _selected_meta()
	if meta.get("kind") == "folder":
		var old_paths := MatchLibrary.matches_in(meta.rel)
		var rel := MatchLibrary.rename_folder(meta.rel, new_name)
		if rel == "":
			show_error("Cannot rename to \"%s\": the name is empty, taken or ends in .logs" % new_name.strip_edges())
			return
		show_error("")
		_folder_moved(meta.rel, rel, old_paths)
		_select({"kind": "folder", "rel": rel})
		return
	var old := selected_path()
	if old == "":
		return
	var path := MatchLibrary.rename(old, new_name)
	if path == "":
		show_error("Cannot rename to \"%s\": the name is empty or already taken" % new_name.strip_edges())
		return
	show_error("")
	refresh()
	_select({"kind": "match", "path": path})
	_update_buttons()
	if path != old:
		match_renamed.emit(old, path)


func _update_buttons() -> void:
	var any := not _selected_meta().is_empty()
	var is_match := selected_path() != ""
	open_button.disabled = not is_match
	rename_button.disabled = not any
	remove_button.disabled = not any
	audio_button.disabled = not is_match
	audio_button.text = "Replace audio…" if is_match and MatchLibrary.audio_path(selected_path()) != "" else "Add audio…"


## Unix time -> local "yyyy-mm-dd hh:mm".
static func _fmt_date(unix: int) -> String:
	var bias: int = Time.get_time_zone_from_system().get("bias", 0)
	return Time.get_datetime_string_from_unix_time(unix + bias * 60, true).left(16)
