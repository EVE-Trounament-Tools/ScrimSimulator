class_name WebFilePicker
extends RefCounted
## Web build only: the menu's file dialogs browse the computer through the browser's own file
## picker instead. When one of them would open, the picked files are copied into the page's
## virtual file system (/tmp) and the dialog's own signal is emitted with their paths, so the menu
## handles them exactly as on the desktop.

## Adds `window.scrimPick(opts_json, done)`: opens the browser's file picker; `done(json)` gets the
## paths the picked files were copied to (`[]` if cancelled).
const PICK_JS := """
window.scrimPick = function (opts, done) {
	opts = JSON.parse(opts);
	const input = document.createElement('input');
	input.type = 'file';
	input.accept = opts.accept || '';
	input.multiple = !!opts.multiple;
	input.webkitdirectory = !!opts.directory;
	input.style.display = 'none';
	document.body.appendChild(input);
	let finished = false;
	const finish = (paths) => {
		if (finished) return;
		finished = true;
		input.remove();
		done(JSON.stringify(paths));
	};
	input.addEventListener('change', async () => {
		const paths = [];
		for (const f of input.files) {
			const rel = opts.directory && f.webkitRelativePath ? f.webkitRelativePath : f.name;
			const dest = opts.dest + '/' + rel;
			engine.copyToFS(dest, await f.arrayBuffer());
			paths.push(dest);
		}
		finish(paths);
	});
	input.addEventListener('cancel', () => finish([]));
	input.click();
};
"""

static var _callback: JavaScriptObject
static var _picks := 0


static func attach(menu: MainMenu) -> void:
	JavaScriptBridge.eval(PICK_JS, true)
	for dialog: FileDialog in [menu.add_dialog, menu.audio_dialog, menu.logs_dialog, menu.folder_dialog]:
		dialog.use_native_dialog = false
		dialog.about_to_popup.connect(_on_popup.bind(menu, dialog))


static func _on_popup(menu: MainMenu, dialog: FileDialog) -> void:
	dialog.hide.call_deferred()
	_picks += 1
	var dest := "/tmp/scrim-upload-%d" % _picks
	var opts := {
		"accept": _accept(dialog.filters),
		"multiple": dialog.file_mode == FileDialog.FILE_MODE_OPEN_FILES,
		"directory": dialog.file_mode == FileDialog.FILE_MODE_OPEN_DIR,
		"dest": dest,
	}
	var paths := await _pick(opts)
	if paths.is_empty():
		return
	match dialog.file_mode:
		FileDialog.FILE_MODE_OPEN_FILE:
			dialog.file_selected.emit(paths[0])
		FileDialog.FILE_MODE_OPEN_FILES:
			# Gamelogs are matched against the matches' CSVs, which may not be downloaded yet.
			for path: String in menu.log_targets():
				if not await WebLibrary.fetch_match(path, false):
					return
			dialog.files_selected.emit(PackedStringArray(paths))
		FileDialog.FILE_MODE_OPEN_DIR:
			# Every path is "<dest>/<picked folder>/…".
			dialog.dir_selected.emit(dest.path_join(paths[0].substr(dest.length() + 1).get_slice("/", 0)))


## Opens the browser's file picker; the paths the picked files were copied to.
static func _pick(opts: Dictionary) -> Array:
	var result := []
	_callback = JavaScriptBridge.create_callback(func(args: Array):
		var parsed: Variant = JSON.parse_string(str(args[0]))
		result.append(parsed if parsed is Array else []))
	var window := JavaScriptBridge.get_interface("window")
	window.scrimPick(JSON.stringify(opts), _callback)
	var tree := Engine.get_main_loop() as SceneTree
	while result.is_empty():
		await tree.process_frame
	return result[0]


## FileDialog filters ("*.ogg, *.mp3 ; Audio files") as an `accept` attribute (".ogg,.mp3").
static func _accept(filters: PackedStringArray) -> String:
	var exts := []
	for f in filters:
		for pattern in f.get_slice(";", 0).split(",", false):
			pattern = pattern.strip_edges()
			if pattern.begins_with("*."):
				exts.append(pattern.substr(1))
	return ",".join(exts)
