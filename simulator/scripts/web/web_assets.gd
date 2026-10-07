class_name WebAssets
extends RefCounted
## Web build only: ship sizes and models come from the site's mirror, made once on the server by
## tools/web_assets.gd, instead of from CCP and GitHub. Ship sizes are fetched ready-made (the
## ~100 MB SDE never reaches the browser). Models and icons still go through `ShipAssets`, whose
## download URLs `WebBackend.rewrite_url` points at the mirror, which holds the models already
## Draco-decoded, so each hull is fetched only when a match needs it and nothing has to run
## `glb-undraco`. Both are cached in the browser (user://sde) and revalidated by ETag.

const SIZES_PATH := "/assets/ship_sizes.json"


## Replaces `ShipSizes.start` / `full_download` / `check_update`: (re)loads the mirror's
## ship_sizes.json into `sizes`' cache.
static func start_sizes(sizes: ShipSizes) -> void:
	if sizes.busy:
		return
	sizes.busy = true
	sizes._set_status("Loading ship sizes…")
	DirAccess.make_dir_recursive_absolute(sizes._dir)
	var etag_path := sizes._cache_path() + ".etag"
	var etag := FileAccess.get_file_as_string(etag_path) if sizes.is_loaded() else ""
	var headers := ["If-None-Match: %s" % etag] if etag != "" else []
	var r := await WebBackend.request(sizes, HTTPClient.METHOD_GET, SIZES_PATH, null, headers)
	sizes.busy = false
	if r.code == 304:
		sizes._set_status(sizes._summary())
		return
	if not r.ok:
		sizes._fail("Ship sizes unavailable from the site (HTTP %d)" % r.code)
		return
	var f := FileAccess.open(sizes._cache_path(), FileAccess.WRITE)
	if f == null:
		sizes._fail("Cannot write %s" % sizes._cache_path())
		return
	f.store_buffer(r.body)
	f.close()
	f = FileAccess.open(etag_path, FileAccess.WRITE)
	if f:
		f.store_string(r.etag)
	sizes._load_cache()
	sizes.sizes_changed.emit()


## Replaces `ShipAssets.start`: the mirror is same-origin and small, so icons and the model index
## are fetched without asking, and checked for updates every start.
static func start_assets(assets: ShipAssets, enabled: bool) -> void:
	if not enabled:
		assets._set_status(assets._summary())
	elif not assets.is_loaded():
		assets.full_download()
	else:
		assets.check_update()
