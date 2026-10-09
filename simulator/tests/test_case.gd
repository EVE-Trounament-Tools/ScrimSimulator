extends RefCounted
## Base class for simulator tests, run by `run_tests.gd`. Every method named `test_*` is a test
## (it may `await`); optional `before_each` / `after_each` run around each one. Assertions record
## a failure and carry on — GDScript has no exceptions to abort a test with.

const DEFAULT_HEADER := "t,pilot,ship_type,x_m,y_m,z_m,speed_mps,dir_x,dir_y,dir_z,residual_m"

## Set by the runner.
var tree: SceneTree
## Failure messages of the current test; reset by the runner.
var failures: PackedStringArray = []

## Shared by every test so temp dirs never collide.
static var _temp_count := 0

var _nodes: Array[Node] = []


## Root of every file a test writes; removed by the runner when the suite finishes.
static func temp_root() -> String:
	return OS.get_temp_dir().path_join("scrim-sim-tests-%d" % OS.get_process_id())


## A fresh, empty directory under `temp_root()`.
func temp_dir() -> String:
	_temp_count += 1
	var dir := temp_root().path_join("%d" % _temp_count)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


## Writes `rows` (each an Array of fields, or a raw String line) under `header` to a temp
## CSV and returns its path. CSVs are generated here rather than checked in because Godot
## imports any `*.csv` inside the project as a translation table.
func write_csv(rows: Array, header := DEFAULT_HEADER) -> String:
	var path := temp_dir().path_join("match.positions.csv")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_line(header)
	for row in rows:
		f.store_line(row if row is String else ",".join(row.map(func(v): return str(v))))
	f.close()
	return path


## Writes `seconds` of silent 8 kHz 8-bit mono WAV to a temp file named `name` and returns its path.
func write_wav(seconds := 1.0, name := "comms.wav") -> String:
	var samples := int(8000 * seconds)
	var b := StreamPeerBuffer.new()
	b.put_data("RIFF".to_ascii_buffer())
	b.put_u32(36 + samples)
	b.put_data("WAVEfmt ".to_ascii_buffer())
	b.put_u32(16)
	b.put_u16(1)  # PCM
	b.put_u16(1)  # mono
	b.put_u32(8000)  # sample rate
	b.put_u32(8000)  # byte rate
	b.put_u16(1)  # block align
	b.put_u16(8)  # bits per sample
	b.put_data("data".to_ascii_buffer())
	b.put_u32(samples)
	var silence := PackedByteArray()
	silence.resize(samples)
	silence.fill(128)
	b.put_data(silence)
	var path := temp_dir().path_join(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(b.data_array)
	f.close()
	return path


## A `scrim-positions` row with only the columns the simulator reads filled in.
static func row(t: float, pilot: String, ship_type: String, pos: Vector3) -> Array:
	return [t, pilot, ship_type, pos.x, pos.y, pos.z, 0, 0, 0, 0, 0]


## Point `frac` of the way from the cube centre (0) to cube corner `corner` (1).
static func on_line(corner: int, frac: float) -> Vector3:
	var c := Vector3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1) * MatchData.CUBE_M
	return MatchData.CENTRE_M.lerp(c, frac)


## Adds `node` to the scene tree; it is freed after the current test.
func add_node(node: Node) -> Node:
	_nodes.append(node)
	tree.root.add_child(node)
	return node


## Points `ShipSizes` at a temp dir holding an empty build-1 cache, so a `main.gd` added to the
## tree neither prompts to download the SDE nor picks up the developer's real one. Leaving that
## prompt open in every test makes Godot crash intermittently. Undo with `ShipSizes.dir = ""`.
func stub_sde() -> void:
	ShipSizes.dir = temp_dir()
	var f := FileAccess.open(ShipSizes.dir.path_join("ship_sizes.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"build": 1, "ships": {}}))
	f.close()


## Frees `node` after the current test without adding it to the tree (no `_ready`).
func own(node: Node) -> Node:
	_nodes.append(node)
	return node


func _free_nodes() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()


# --- assertions --------------------------------------------------------------

func fail(msg: String) -> void:
	# Frame 0 is fail() itself, 1 the assert helper; report the first frame in the test file.
	var where := ""
	for frame in get_stack():
		if frame.source == get_script().resource_path:
			where = "line %d: " % frame.line
			break
	failures.append(where + msg)


func assert_true(cond: bool, msg := "") -> void:
	if not cond:
		fail(msg if msg else "expected true")


func assert_false(cond: bool, msg := "") -> void:
	if cond:
		fail(msg if msg else "expected false")


func assert_eq(got: Variant, want: Variant, msg := "") -> void:
	if typeof(got) != typeof(want) or got != want:
		fail("%sgot %s, want %s" % [_prefix(msg), var_to_str(got), var_to_str(want)])


func assert_ne(got: Variant, unwanted: Variant, msg := "") -> void:
	if typeof(got) == typeof(unwanted) and got == unwanted:
		fail("%sgot %s, expected something else" % [_prefix(msg), var_to_str(got)])


func assert_null(v: Variant, msg := "") -> void:
	if v != null:
		fail("%sexpected null, got %s" % [_prefix(msg), var_to_str(v)])


func assert_not_null(v: Variant, msg := "") -> void:
	if v == null:
		fail("%sexpected non-null" % _prefix(msg))


## Floats or Vector3s within `eps` (Euclidean distance for vectors).
func assert_almost(got: Variant, want: Variant, eps := 1e-3, msg := "") -> void:
	var ok := false
	if got is Vector3 and want is Vector3:
		ok = got.distance_to(want) <= eps
	elif (got is float or got is int) and (want is float or want is int):
		ok = absf(got - want) <= eps
	if not ok:
		fail("%sgot %s, want %s (±%s)" % [_prefix(msg), var_to_str(got), var_to_str(want), eps])


static func _prefix(msg: String) -> String:
	return msg + ": " if msg else ""
