class_name CombatStats
extends RefCounted
## What a match's synced `CombatLog`s say about each pilot, for the roster: rolling damage, rep and
## capacitor rates, and the electronic warfare on it at any match time. The same event is often in
## several logs (A's outgoing hit is B's incoming one; everyone near sees a scram), so they are
## merged first.

## Rates are averaged over this much match time up to the moment shown.
const RATE_WINDOW_S := 10.0
## Columns filled from rates: amount per second the pilot took (`_in`) or gave (`_out`).
const RATE_IDS := ["dmg_in", "dmg_out", "rep_in", "rep_out", "cap_in", "cap_out"]
const EWAR_IDS := ["ewar_in", "ewar_out"]
## Electronic warfare kinds, in display order: name, short label, cycle time (s) when the logs
## don't show one. Only scram/disrupt, neuts, nos and ECM are in EVE gamelogs today; the rest are
## recognised by module name should they appear.
const EWAR_TYPES := {
	"scram": {"title": "Warp scramble", "short": "Scram", "cycle_s": 5.0},
	"disrupt": {"title": "Warp disruption", "short": "Disr", "cycle_s": 5.0},
	"web": {"title": "Stasis webifier", "short": "Web", "cycle_s": 5.0},
	"neut": {"title": "Energy neutralizer", "short": "Neut", "cycle_s": 12.0},
	"nos": {"title": "Energy nosferatu", "short": "Nos", "cycle_s": 6.0},
	"ecm": {"title": "ECM jam", "short": "ECM", "cycle_s": 20.0},
	"td": {"title": "Tracking disruptor", "short": "TD", "cycle_s": 5.0},
	"gd": {"title": "Guidance disruptor", "short": "GD", "cycle_s": 5.0},
	"damp": {"title": "Sensor dampener", "short": "Damp", "cycle_s": 5.0},
	"tp": {"title": "Target painter", "short": "TP", "cycle_s": 5.0},
	"rsb": {"title": "Remote sensor booster", "short": "RSB", "cycle_s": 5.0},
	"rtc": {"title": "Remote tracking computer", "short": "RTC", "cycle_s": 5.0},
}
## Neut / nos cycle times (s) by module size: Small, Medium, Heavy.
const SIZE_CYCLES := {"neut": [6.0, 12.0, 24.0], "nos": [3.0, 6.0, 12.0]}
## [substring of the lowercase module name, ewar type] for kinds the parser has no rule for.
const EWAR_KEYWORDS := [
	["tracking disrupt", "td"], ["guidance disrupt", "gd"], ["dampen", "damp"],
	["painter", "tp"], ["sensor boost", "rsb"], ["tracking comp", "rtc"],
	["webif", "web"], ["stasis", "web"],
]
## Kinds of source -> target line drawn in space, in display order.
const LINK_KINDS := ["shooting", "tackle", "neut", "ewar"]
## A hit (or miss) keeps its shooting line up this long; closer hits make one span.
const SHOT_HOLD_S := 4.0
## Gaps between repeats of the same module on the same target count as its cycle only within this
## fraction of the expected one: overheating shortens it, shorter gaps are several modules.
const CYCLE_MIN_FRACTION := 0.6
const CYCLE_MAX_FRACTION := 1.1

## pilot -> rate id -> { t: PackedFloat64Array (sorted), sum: PackedFloat64Array (prefix sums,
## one longer) }.
var _series := {}
## pilot -> "in" / "out" -> Array of { type, other, t0, t1 } sorted by `t0`.
var _ewar := {}
## Column id -> true when any pilot has data for it.
var _has := {}
## Target pilot -> source pilot -> damage { t, sum } (as in `_series`).
var _dmg_by_source := {}
## `LINK_KINDS` kind -> Array of { source, target, t0, t1 }: spans when the source was doing that
## to the target.
var _links := {}


## Merges `logs` (synced `CombatLog`s) into per-pilot series. Entries by or on a pilot in `cutoff`
## (pilot -> match time, e.g. when it was podded) after its time are left out.
static func from_logs(logs: Array, cutoff := {}) -> CombatStats:
	var stats := CombatStats.new()
	var rates := {}  # pilot -> rate id -> [[t, amount], …]
	var hits := {}  # target -> source -> [[t, amount], …]
	var casts := {}  # [source, target, type, weapon] key -> { source, target, type, weapon, times }
	var shots := {}  # "source|target" -> [source, target, times]
	var spans := {}  # "kind|source|target" -> [kind, source, target, [[t0, t1], …]]
	for e in merge(logs):
		if e.t > cutoff.get(e.source_pilot, INF) or e.t > cutoff.get(e.target_pilot, INF):
			continue
		_add_rates(rates, e)
		if e.kind == CombatLog.Kind.DAMAGE or e.kind == CombatLog.Kind.MISS:
			var pair := "%s|%s" % [e.source_pilot, e.target_pilot]
			if not shots.has(pair):
				shots[pair] = [e.source_pilot, e.target_pilot, []]
			shots[pair][2].append(e.t)
		if e.kind == CombatLog.Kind.DAMAGE and not is_nan(e.amount):
			if not hits.has(e.target_pilot):
				hits[e.target_pilot] = {}
			if not hits[e.target_pilot].has(e.source_pilot):
				hits[e.target_pilot][e.source_pilot] = []
			hits[e.target_pilot][e.source_pilot].append([e.t, e.amount])
		var type := ewar_type(e)
		if type != "":
			var key := "%s|%s|%s|%s" % [e.source_pilot, e.target_pilot, type, e.weapon]
			if not casts.has(key):
				casts[key] = {"source": e.source_pilot, "target": e.target_pilot, "type": type,
					"weapon": e.weapon, "times": []}
			casts[key].times.append(e.t)
	for pilot in rates:
		stats._series[pilot] = {}
		for id in rates[pilot]:
			stats._series[pilot][id] = _prefix(rates[pilot][id])
			stats._has[id] = true
	for target in hits:
		stats._dmg_by_source[target] = {}
		for source in hits[target]:
			stats._dmg_by_source[target][source] = _prefix(hits[target][source])
	for c in casts.values():
		var times: Array = c.times
		times.sort()
		var cycle := estimate_cycle(c.type, c.weapon, times)
		var kind := link_kind(c.type)
		for t in times:
			stats._add_ewar(c.source, "out", {"type": c.type, "other": c.target, "t0": t, "t1": t + cycle})
			stats._add_ewar(c.target, "in", {"type": c.type, "other": c.source, "t0": t, "t1": t + cycle})
			_add_span(spans, kind, c.source, c.target, t, t + cycle)
	for s in shots.values():
		for t in s[2]:
			_add_span(spans, "shooting", s[0], s[1], t, t + SHOT_HOLD_S)
	for s in spans.values():
		if not stats._links.has(s[0]):
			stats._links[s[0]] = []
		for span in _fold(s[3]):
			stats._links[s[0]].append({"source": s[1], "target": s[2], "t0": span[0], "t1": span[1]})
	for pilot in stats._ewar:
		for dir in stats._ewar[pilot]:
			stats._ewar[pilot][dir].sort_custom(func(a, b): return a.t0 < b.t0)
	return stats


static func _add_span(spans: Dictionary, kind: String, source: String, target: String, t0: float, t1: float) -> void:
	var key := "%s|%s|%s" % [kind, source, target]
	if not spans.has(key):
		spans[key] = [kind, source, target, []]
	spans[key][3].append([t0, t1])


## `spans` ([[t0, t1], …]) sorted and with overlapping ones merged.
static func _fold(spans: Array) -> Array:
	spans.sort_custom(func(a, b): return a[0] < b[0])
	var out := []
	for s in spans:
		if not out.is_empty() and s[0] <= out[-1][1]:
			out[-1][1] = maxf(out[-1][1], s[1])
		else:
			out.append([s[0], s[1]])
	return out


## Entries of every log in `logs`, once each, with both pilots known and a match time. An event in
## several logs counts as many times as the log that has it most often (two guns hitting the same
## target for the same amount in the same second are two events).
static func merge(logs: Array) -> Array:
	var best := {}  # key -> [count, entries of the log with the most]
	for gamelog in logs:
		var mine := {}
		for e in gamelog.entries:
			if e.source_pilot == "" or e.target_pilot == "" or e.source_pilot == e.target_pilot or is_nan(e.t):
				continue
			var key := "%d|%d|%s|%s|%s|%s" % [int(e.eve_unix), e.kind, e.source_pilot, e.target_pilot,
				str(e.amount), e.weapon]
			if not mine.has(key):
				mine[key] = []
			mine[key].append(e)
		for key in mine:
			if not best.has(key) or mine[key].size() > best[key].size():
				best[key] = mine[key]
	var out := []
	for list in best.values():
		out.append_array(list)
	out.sort_custom(func(a, b): return a.t < b.t)
	return out


## `points` ([[t, amount], …]) sorted by time, as { t, sum } (prefix sums, one longer).
static func _prefix(points: Array) -> Dictionary:
	points.sort_custom(func(a, b): return a[0] < b[0])
	var t := PackedFloat64Array()
	var sum := PackedFloat64Array([0.0])
	for p in points:
		t.append(p[0])
		sum.append(sum[-1] + p[1])
	return {"t": t, "sum": sum}


static func _add_rates(rates: Dictionary, e: Dictionary) -> void:
	var what := ""
	match e.kind:
		CombatLog.Kind.DAMAGE:
			what = "dmg"
		CombatLog.Kind.REMOTE_REP:
			what = "rep"
		CombatLog.Kind.NEUT, CombatLog.Kind.NOS:
			what = "cap"
	if what == "" or is_nan(e.amount):
		return
	for side in [[e.source_pilot, "_out"], [e.target_pilot, "_in"]]:
		var pilot: String = side[0]
		if not rates.has(pilot):
			rates[pilot] = {}
		var id: String = what + side[1]
		if not rates[pilot].has(id):
			rates[pilot][id] = []
		rates[pilot][id].append([e.t, e.amount])


func _add_ewar(pilot: String, dir: String, app: Dictionary) -> void:
	if not _ewar.has(pilot):
		_ewar[pilot] = {"in": [], "out": []}
	_ewar[pilot][dir].append(app)
	_has["ewar_" + dir] = true


## The `EWAR_TYPES` key of entry `e`, or "" if it isn't electronic warfare.
static func ewar_type(e: Dictionary) -> String:
	match e.kind:
		CombatLog.Kind.SCRAM:
			return "disrupt" if e.weapon.to_lower().contains("disrupt") else "scram"
		CombatLog.Kind.NEUT:
			return "neut"
		CombatLog.Kind.NOS:
			return "nos"
		CombatLog.Kind.JAM:
			return "ecm"
		CombatLog.Kind.DAMAGE, CombatLog.Kind.MISS, CombatLog.Kind.REMOTE_REP:
			return ""
	var lower: String = e.weapon.to_lower()
	for k in EWAR_KEYWORDS:
		if lower.contains(k[0]):
			return k[1]
	return ""


## The `LINK_KINDS` line an ewar `type` (an `EWAR_TYPES` key) is drawn as.
static func link_kind(type: String) -> String:
	match type:
		"scram", "disrupt", "web":
			return "tackle"
		"neut", "nos":
			return "neut"
	return "ewar"


## Expected cycle time (s) of a `type` module named `weapon`: its usual one, or the median gap
## between `times` (sorted match times of its repeats on one target) that look like one cycle.
static func estimate_cycle(type: String, weapon: String, times: Array) -> float:
	var expected := default_cycle(type, weapon)
	var gaps := []
	for i in range(1, times.size()):
		var gap: float = times[i] - times[i - 1]
		if gap >= expected * CYCLE_MIN_FRACTION and gap <= expected * CYCLE_MAX_FRACTION:
			gaps.append(gap)
	if gaps.is_empty():
		return expected
	gaps.sort()
	var mid := gaps.size() / 2
	return gaps[mid] if gaps.size() % 2 == 1 else (gaps[mid - 1] + gaps[mid]) / 2.0


## Usual cycle time (s) of a `type` module named `weapon`.
static func default_cycle(type: String, weapon: String) -> float:
	if SIZE_CYCLES.has(type):
		var lower := weapon.to_lower()
		for i in ["small", "medium", "heavy"].size():
			if lower.contains(["small", "medium", "heavy"][i]):
				return SIZE_CYCLES[type][i]
	return EWAR_TYPES[type].cycle_s if EWAR_TYPES.has(type) else 5.0


## Whether any pilot has data for roster column `id`.
func has(id: String) -> bool:
	return _has.has(id)


## `pilot`'s rate `id` (one of `RATE_IDS`) per second over the `RATE_WINDOW_S` up to match time
## `t`; NAN when the logs say nothing of it.
func rate(pilot: String, id: String, t: float) -> float:
	var s: Dictionary = _series.get(pilot, {}).get(id, {})
	if s.is_empty():
		return NAN
	return _window_rate(s, t)


## Damage per second on `pilot` from each attacker over the `RATE_WINDOW_S` up to match time `t`:
## Array of { pilot (the attacker), dps }, highest first; attackers under 0.5 are left out.
func damage_in_by_source(pilot: String, t: float) -> Array:
	var out := []
	var sources: Dictionary = _dmg_by_source.get(pilot, {})
	for source in sources:
		var dps := _window_rate(sources[source], t)
		if dps >= 0.5:
			out.append({"pilot": source, "dps": dps})
	out.sort_custom(func(a, b): return a.dps > b.dps)
	return out


## Amount per second in series `s` ({ t, sum }) over the `RATE_WINDOW_S` up to `t`.
static func _window_rate(s: Dictionary, t: float) -> float:
	var times: PackedFloat64Array = s.t
	var hi := times.bsearch(t, false)
	var lo := times.bsearch(t - RATE_WINDOW_S, false)
	return (s.sum[hi] - s.sum[lo]) / RATE_WINDOW_S


## Electronic warfare on `pilot` (`outgoing`: by it) active at match time `t`: type -> Array of
## { pilot (the other side), cycles (of that type between the two up to `t`) }, by first applied.
func ewar_at(pilot: String, outgoing: bool, t: float) -> Dictionary:
	var out := {}
	var counts := {}  # "type|other" -> cycles so far
	var active := {}  # "type|other" -> true
	for app in _ewar.get(pilot, {}).get("out" if outgoing else "in", []):
		if app.t0 > t:
			break
		var key := "%s|%s" % [app.type, app.other]
		counts[key] = counts.get(key, 0) + 1
		if t < app.t1 and not active.has(key):
			active[key] = true
			if not out.has(app.type):
				out[app.type] = []
			out[app.type].append({"pilot": app.other, "cycles": 0})
	for type in out:
		for row in out[type]:
			row.cycles = counts["%s|%s" % [type, row.pilot]]
	return out


## Source -> target lines active at match time `t`: Array of { kind (one of `LINK_KINDS`), source,
## target }, one per kind and pair.
func links_at(t: float) -> Array:
	var out := []
	for kind in LINK_KINDS:
		for span in _links.get(kind, []):
			if span.t0 <= t and t < span.t1:
				out.append({"kind": kind, "source": span.source, "target": span.target})
	return out
