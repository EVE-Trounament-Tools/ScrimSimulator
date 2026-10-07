class_name WebBackend
extends RefCounted
## Web build only (`OS.has_feature("web")`): talks to the site the page was served from
## (web/worker). The page is only served to a logged-in, whitelisted character, and every
## request here is same-origin, so the session cookie goes along by itself.
##
## The desktop app never calls into this; its scripts only reach the web classes behind an
## `OS.has_feature("web")` check.

## Upstream download URL prefixes -> the site's mirror of them (made by tools/web_assets.gd and
## served from /assets/). The browser never talks to CCP or GitHub itself.
const MIRRORS := [
	["https://raw.githubusercontent.com/EstamelGG/EVE_Model_Gallery/main/docs/", "/assets/gallery/"],
	["https://web.ccpgamescdn.com/aws/developers/Uprising_V21.03_Icons.zip", "/assets/icons.zip"],
]
const IMAGE_SERVER_RE := "^https://images\\.evetech\\.net/types/(\\d+)/icon"

static var _boot: Variant = null
static var _origin := ""


## What the site put in the page for this session (`window.scrimBoot`): `{ build, character:
## { id, name }, admin, settings (settings.cfg text or null), library: { version, files } }`.
## {} outside the web build.
static func boot() -> Dictionary:
	if _boot == null:
		_boot = {}
		if OS.has_feature("web"):
			var text: Variant = JavaScriptBridge.eval("JSON.stringify(window.scrimBoot || {})", true)
			var parsed: Variant = JSON.parse_string(str(text)) if text != null else null
			if parsed is Dictionary:
				_boot = parsed
	return _boot


## "https://host" the page was served from.
static func origin() -> String:
	if _origin == "" and OS.has_feature("web"):
		_origin = str(JavaScriptBridge.eval("location.origin", true))
	return _origin


## `url` pointed at the site's mirror if it is one of the upstream downloads (see `MIRRORS`),
## else unchanged.
static func rewrite_url(url: String) -> String:
	for m in MIRRORS:
		if url.begins_with(m[0]):
			return origin() + m[1] + url.substr(m[0].length())
	var hit := RegEx.create_from_string(IMAGE_SERVER_RE).search(url)
	if hit:
		return origin() + "/assets/types/%s.png" % hit.get_string(1)
	return url


## Sends `method` to site path `path` ("/api/…") with `body` (String, PackedByteArray or null)
## through a temporary HTTPRequest under `parent`. Returns { ok (2xx), code, etag, body, json
## (the body parsed, or null) }.
static func request(parent: Node, method: int, path: String, body: Variant = null,
		headers: Array = [], timeout := 60.0) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = timeout
	req.accept_gzip = false  # The browser has already decompressed the body.
	parent.add_child(req)
	var out := {"ok": false, "code": 0, "etag": "", "body": PackedByteArray(), "json": null}
	var done := []
	req.request_completed.connect(func(result, code, hdrs, data): done.append([result, code, hdrs, data]))
	var bytes: PackedByteArray = body.to_utf8_buffer() if body is String else (body if body is PackedByteArray else PackedByteArray())
	if req.request_raw(origin() + path, headers, method, bytes) == OK:
		while done.is_empty():
			await parent.get_tree().process_frame
		var r: Array = done[0]
		out.code = r[1]
		out.etag = Http.header(r[2], "etag")
		out.body = r[3]
		out.ok = r[0] == HTTPRequest.RESULT_SUCCESS and r[1] >= 200 and r[1] < 300
		out.json = JSON.parse_string(out.body.get_string_from_utf8()) if out.body.size() > 0 else null
	req.queue_free()
	return out
