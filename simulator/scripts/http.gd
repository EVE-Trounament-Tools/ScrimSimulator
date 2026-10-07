class_name Http
extends RefCounted
## One-shot HTTP GETs for the downloaders (`ShipSizes`, `ShipAssets`).

const HEADERS := ["User-Agent: scrimSimulator (EVE scrim replay tool)"]


## GETs `url` through a temporary HTTPRequest under `parent`. With `to_file` the body is
## streamed there instead of returned; `progress(got_bytes, total_bytes)` is called each frame
## while the request runs (total is -1 when unknown).
## Returns { ok (HTTP 200), code (HTTP status, 0 if the request failed), result, etag, body }.
static func fetch(parent: Node, url: String, headers: Array = [], to_file := "",
		progress := Callable(), timeout := 30.0) -> Dictionary:
	var req := HTTPRequest.new()
	if OS.has_feature("web"):
		url = WebBackend.rewrite_url(url)
		req.accept_gzip = false  # The browser has already decompressed the body.
	req.timeout = timeout if to_file == "" else 0.0
	if to_file != "":
		req.download_file = to_file
		req.download_chunk_size = 1 << 16
	parent.add_child(req)
	var out := {"ok": false, "code": 0, "result": HTTPRequest.RESULT_CANT_CONNECT, "etag": "",
		"body": PackedByteArray()}
	var done := []
	req.request_completed.connect(func(result, code, hdrs, body): done.append([result, code, hdrs, body]))
	if req.request(url, HEADERS + headers) == OK:
		while done.is_empty():
			if progress.is_valid():
				progress.call(req.get_downloaded_bytes(), req.get_body_size())
			await parent.get_tree().process_frame
		var r: Array = done[0]
		out.result = r[0]
		out.code = r[1]
		out.etag = header(r[2], "etag")
		out.body = r[3]
		out.ok = r[0] == HTTPRequest.RESULT_SUCCESS and r[1] == 200
	req.queue_free()
	return out


## Value of header `name` (case-insensitive) in Godot's "Name: value" list, or "".
static func header(headers: PackedStringArray, name: String) -> String:
	var prefix := name.to_lower() + ":"
	for h in headers:
		if h.to_lower().begins_with(prefix):
			return h.substr(prefix.length()).strip_edges()
	return ""
