extends SceneTree
## Builds the website's asset mirror (served from /assets/, see web/README.md) with the desktop
## app's own downloaders, so the SDE and the ship models are downloaded and decoded once on the
## server instead of in every browser:
##
##   godot --headless --path simulator -s tools/web_assets.gd -- <out dir> [--limit N] [--ships A,B]
##
## Fills or updates simulator/sde/ exactly as the app does (SDE -> ship sizes, overview icons,
## the model index and every ship hull, Draco-decoded by glb-undraco, which must be built), then
## writes into <out dir>:
##   ship_sizes.json                            what WebAssets.start_sizes loads
##   icons.zip                                  the bracket icons, laid out as CCP's icon zip
##   gallery/statics/resources_index_en.json    model index of the mirrored hulls only
##   gallery/models/<type id>.glb               decoded hull models
##   types/<type id>.png                        electronic warfare module icons
## `--limit N` mirrors only N hulls and `--ships` only the named ones (for trying it out). Exits 1
## on failure.

var sizes: ShipSizes
var assets: ShipAssets


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or args[0].begins_with("--"):
		_quit("usage: -- <out dir> [--limit N]")
		return
	var out: String = args[0]
	var limit := -1
	var i := args.find("--limit")
	if i >= 0 and i + 1 < args.size():
		limit = int(args[i + 1])
	var only := []
	i = args.find("--ships")
	if i >= 0 and i + 1 < args.size():
		only = Array(args[i + 1].split(",", false)).map(func(n): return n.strip_edges().to_lower())

	sizes = ShipSizes.new()
	root.add_child(sizes)
	sizes.status_changed.connect(func(t): print("sde: ", t))
	sizes.needs_download.connect(func(_why): sizes.full_download())
	if sizes.is_loaded():
		sizes.check_update()
	else:
		sizes.full_download()
	await _idle(sizes)
	if not sizes.is_loaded():
		_quit("no ship sizes")
		return

	assets = ShipAssets.new()
	root.add_child(assets)
	assets.status_changed.connect(func(t): print("models: ", t))
	if assets.is_loaded():
		assets.check_update()
	else:
		assets.full_download()
	await _idle(assets)
	if not assets.is_loaded():
		_quit("no model index or icons")
		return
	if ShipAssets.undraco_path() == "":
		_quit("glb-undraco not built: cargo build --release -p glb-undraco")
		return

	var ids := [ShipAssets.MJU_TYPE_ID]
	for key in sizes.ships:
		if only.is_empty() or only.has(key):
			ids.append(sizes.ships[key].type_id)
	ids = ids.filter(func(id): return assets.index.has(id))
	ids.sort()
	if limit >= 0:
		ids = ids.slice(0, limit)
	print("models: %d hulls to mirror" % ids.size())
	await assets.ensure_models(ids)
	for key in ShipAssets.EWAR_TYPE_IDS:
		if not FileAccess.file_exists(assets._ewar_path(key)):
			await assets._fetch_ewar_icon(key)

	var err := _write(out, ids)
	if err != "":
		_quit(err)
		return
	print("mirror written to %s" % out)
	quit(0)


func _idle(node: Node) -> void:
	await process_frame
	while node.busy:
		await process_frame


func _write(out: String, ids: Array) -> String:
	var data := ShipSizes.data_dir()
	var models_dir := data.path_join("assets/models")
	for d in ["gallery/statics", "gallery/models", "types"]:
		DirAccess.make_dir_recursive_absolute(out.path_join(d))
	if DirAccess.copy_absolute(data.path_join("ship_sizes.json"), out.path_join("ship_sizes.json")) != OK:
		return "cannot copy ship_sizes.json"

	var zip := ZIPPacker.new()
	if zip.open(out.path_join("icons.zip")) != OK:
		return "cannot write icons.zip"
	var brackets := data.path_join("assets/brackets")
	for file in DirAccess.get_files_at(brackets):
		zip.start_file(ShipAssets.BRACKETS_PREFIX + file)
		zip.write_file(FileAccess.get_file_as_bytes(brackets.path_join(file)))
		zip.close_file()
	zip.close()

	var types := []
	for id in ids:
		if not assets.has_model(id):
			continue
		var src := models_dir.path_join("%d.glb" % id)
		if DirAccess.copy_absolute(src, out.path_join("gallery/models/%d.glb" % id)) != OK:
			return "cannot copy %s" % src
		types.append({"id": id, "model_path": "models/%d.glb" % id})
	var f := FileAccess.open(out.path_join("gallery/statics/resources_index_en.json"), FileAccess.WRITE)
	if f == null:
		return "cannot write the model index"
	f.store_string(JSON.stringify([{"groups": [{"types": types}]}]))
	f.close()
	print("models: %d of %d mirrored" % [types.size(), ids.size()])

	for key in ShipAssets.EWAR_TYPE_IDS:
		var src: String = assets._ewar_path(key)
		if FileAccess.file_exists(src):
			DirAccess.copy_absolute(src, out.path_join("types/%d.png" % ShipAssets.EWAR_TYPE_IDS[key]))
	return ""


func _quit(error: String) -> void:
	push_error(error)
	quit(1)
