class_name WebSettings
extends RefCounted
## Web build only: `Settings` belong to the logged-in character. They start from the copy the site
## put in the page (`WebBackend.boot`) and every change is sent back to it, a moment later so a
## dragged slider is one request.

const SAVE_DELAY := 1.0

static var _text := ""
static var _pending := false


## Fills `cfg` with the character's saved settings (nothing for a character without any yet).
static func load_into(cfg: ConfigFile) -> void:
	var text: Variant = WebBackend.boot().get("settings")
	if text is String and text != "":
		var err := cfg.parse(text)
		if err != OK:
			push_warning("Ignoring unreadable saved settings: %s" % error_string(err))


## `cfg` changed: save it to the site soon.
static func changed(cfg: ConfigFile) -> void:
	_text = cfg.encode_to_text()
	if _pending:
		return
	_pending = true
	var tree := Engine.get_main_loop() as SceneTree
	tree.create_timer(SAVE_DELAY).timeout.connect(_save)


static func _save() -> void:
	_pending = false
	var tree := Engine.get_main_loop() as SceneTree
	var r := await WebBackend.request(tree.root, HTTPClient.METHOD_PUT, "/api/settings", _text,
		["Content-Type: text/plain; charset=utf-8"])
	if not r.ok:
		push_warning("Saving settings failed (HTTP %d)" % r.code)
