class_name Ruleset
extends RefCounted
## A tournament's ship points rules, from `res://rulesets/<id>.json` (generated from that year's
## comp calculator sheet by `scripts/ruleset_from_sheet.py`): each ship's points and hull type,
## the per-hull inflation added to every copy of a ship fielded more than once, and the points
## cap a team is measured against.

const DIR := "res://rulesets"

## Id -> loaded `Ruleset`.
static var _cache := {}

var id := ""
var name := ""
## Sort key: the highest is the newest (default) ruleset.
var order := 0
var source := ""
var point_cap := 0
## Hull type -> points added per extra copy of the same ship; other hulls add `default_inflation`.
var inflation := {}
var default_inflation := 0
## Lowercase ship name -> { name, points, hull }.
var ships := {}


## Ids of every bundled ruleset, oldest first.
static func available() -> Array:
	var all := []
	for f in DirAccess.get_files_at(DIR):
		if f.get_extension() == "json":
			var r := load_file(DIR.path_join(f))
			if r != null:
				all.append(r)
	all.sort_custom(func(a, b): return a.order < b.order)
	return all.map(func(r): return r.id)


## The newest ruleset's id, or "" if there are none.
static func latest_id() -> String:
	var ids := available()
	return ids[-1] if not ids.is_empty() else ""


## The ruleset `id`, or null if there's no such ruleset.
static func load_id(id: String) -> Ruleset:
	if not _cache.has(id):
		for f in DirAccess.get_files_at(DIR):
			if f.get_extension() == "json":
				load_file(DIR.path_join(f))
	return _cache.get(id)


## Parses (and caches) a ruleset file; null if it can't be read.
static func load_file(path: String) -> Ruleset:
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not j is Dictionary or not j.has("id") or not j.has("ships"):
		push_error("%s: not a ruleset" % path)
		return null
	if _cache.has(j.id):
		return _cache[j.id]
	var r := Ruleset.new()
	r.id = j.id
	r.name = j.get("name", j.id)
	r.order = int(j.get("order", 0))
	r.source = j.get("source", "")
	r.point_cap = int(j.get("point_cap", 0))
	for hull in j.get("inflation", {}):
		r.inflation[hull] = int(j.inflation[hull])
	r.default_inflation = int(j.get("default_inflation", 0))
	for ship in j.ships:
		var s: Dictionary = j.ships[ship]
		r.ships[ship.to_lower()] = {"name": ship, "points": int(s.points), "hull": s.get("hull", "")}
	_cache[r.id] = r
	return r


func knows(ship_type: String) -> bool:
	return ships.has(ship_type.to_lower())


## Points of one `ship_type` before inflation; 0 for capsules and ships not in the ruleset.
func base_points(ship_type: String) -> int:
	return ships.get(ship_type.to_lower(), {}).get("points", 0)


## Points added to each copy of `ship_type` per further copy in the same fleet.
func inflation_of(ship_type: String) -> int:
	var s: Dictionary = ships.get(ship_type.to_lower(), {})
	if s.is_empty():
		return 0
	return inflation.get(s.hull, default_inflation)


## Each of `ship_types`' points in one fleet: its base points plus its hull's inflation for every
## other copy of the same ship.
func fleet_points(ship_types: Array) -> Array:
	var copies := {}
	for t in ship_types:
		copies[t.to_lower()] = copies.get(t.to_lower(), 0) + 1
	return ship_types.map(func(t): return base_points(t) + (copies[t.to_lower()] - 1) * inflation_of(t))


## Points the opponent of a fleet worth `fleet_total` starts with: whatever it leaves of the cap.
func head_start(fleet_total: int) -> int:
	return maxi(point_cap - fleet_total, 0)
