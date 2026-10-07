extends "res://tests/test_case.gd"
## CombatStats: merging synced gamelogs, rolling rates, and the electronic warfare active on a
## pilot at a match time.

const K := CombatLog.Kind


## A synced entry: `kind` from `source` to `target` (match pilots) at match time `t` (EVE time
## 1000 + t), with `amount` and `weapon`.
static func _e(kind: int, source: String, target: String, t: float, amount := NAN, weapon := "") -> Dictionary:
	return {
		"eve_unix": 1000.0 + t, "t": t, "kind": kind, "text": "",
		"source": source, "target": target, "source_ship": "", "target_ship": "",
		"source_pilot": source, "target_pilot": target, "amount": amount, "weapon": weapon, "quality": "",
	}


static func _log(entries: Array) -> CombatLog:
	var out := CombatLog.new()
	out.entries = entries
	return out


func test_merge_drops_copies_across_logs_but_keeps_repeats_in_one() -> void:
	var hit := _e(K.DAMAGE, "A", "B", 1.0, 100.0, "Gun")
	var a := _log([hit.duplicate(), hit.duplicate()])  # Two guns, same hit, same second.
	var b := _log([hit.duplicate()])  # B's own log sees one of them.
	assert_eq(CombatStats.merge([a, b]).size(), 2)
	assert_eq(CombatStats.merge([b, a]).size(), 2)
	assert_eq(CombatStats.merge([b, b]).size(), 1)


func test_merge_skips_unknown_pilots_and_unsynced() -> void:
	var unknown := _e(K.DAMAGE, "A", "", 1.0, 5.0)
	var unsynced := _e(K.DAMAGE, "A", "B", 1.0, 5.0)
	unsynced.t = NAN
	assert_eq(CombatStats.merge([_log([unknown, unsynced])]), [])


func test_cutoff_drops_entries_by_or_on_a_pilot_after_its_time() -> void:
	var s := CombatStats.from_logs([_log([
		_e(K.DAMAGE, "A", "B", 1.0, 100.0),
		_e(K.DAMAGE, "A", "B", 5.0, 50.0),  # B was podded at 3 s.
		_e(K.DAMAGE, "B", "A", 6.0, 40.0),
	])], {"B": 3.0})
	var w := CombatStats.RATE_WINDOW_S
	assert_almost(s.rate("B", "dmg_in", 6.0), 100.0 / w)
	assert_true(is_nan(s.rate("A", "dmg_in", 6.0)), "the pod's shots are gone")


func test_rates() -> void:
	var s := CombatStats.from_logs([_log([
		_e(K.DAMAGE, "A", "B", 1.0, 100.0),
		_e(K.DAMAGE, "A", "B", 5.0, 50.0),
		_e(K.REMOTE_REP, "C", "B", 2.0, 30.0),
		_e(K.NEUT, "B", "A", 3.0, 200.0, "Heavy Energy Neutralizer II"),
		_e(K.NOS, "A", "B", 4.0, 20.0, "Small Energy Nosferatu II"),
	])])
	var w := CombatStats.RATE_WINDOW_S
	assert_almost(s.rate("A", "dmg_out", 5.0), 150.0 / w)
	assert_almost(s.rate("B", "dmg_in", 5.0), 150.0 / w)
	assert_almost(s.rate("B", "dmg_in", 1.0), 100.0 / w)
	assert_almost(s.rate("B", "dmg_in", 0.5), 0.0, 1e-6, "before the first hit")
	assert_almost(s.rate("B", "dmg_in", 11.0 + 0.5), 50.0 / w, 1e-6, "the first hit left the window")
	assert_almost(s.rate("B", "rep_in", 5.0), 30.0 / w)
	assert_almost(s.rate("C", "rep_out", 5.0), 30.0 / w)
	assert_almost(s.rate("A", "cap_in", 5.0), 200.0 / w, 1e-3, "neutralized by B")
	assert_almost(s.rate("B", "cap_out", 5.0), 200.0 / w)
	assert_almost(s.rate("B", "cap_in", 5.0), 20.0 / w, 1e-3, "drained by A's nos")
	assert_almost(s.rate("A", "cap_out", 5.0), 20.0 / w)
	assert_true(is_nan(s.rate("C", "dmg_in", 5.0)), "no data")
	for id in CombatStats.RATE_IDS + CombatStats.EWAR_IDS:
		assert_true(s.has(id), id)


func test_damage_in_by_source() -> void:
	var s := CombatStats.from_logs([_log([
		_e(K.DAMAGE, "A", "B", 1.0, 100.0),
		_e(K.DAMAGE, "C", "B", 2.0, 300.0),
		_e(K.DAMAGE, "A", "B", 12.0, 50.0),
		_e(K.REMOTE_REP, "D", "B", 3.0, 500.0),
		_e(K.NEUT, "D", "B", 3.0, 500.0, "Heavy Energy Neutralizer II"),
	])])
	var w := CombatStats.RATE_WINDOW_S
	var rows := s.damage_in_by_source("B", 5.0)
	assert_eq(rows.map(func(r): return r.pilot), ["C", "A"], "highest first, damage only")
	assert_almost(rows[0].dps, 300.0 / w)
	assert_almost(rows[1].dps, 100.0 / w)
	rows = s.damage_in_by_source("B", 12.5)
	assert_eq(rows.map(func(r): return r.pilot), ["A"], "C's hit left the window")
	assert_almost(rows[0].dps, 50.0 / w)
	assert_eq(s.damage_in_by_source("A", 5.0), [], "no incoming damage")


func test_has_without_data() -> void:
	var s := CombatStats.from_logs([_log([_e(K.DAMAGE, "A", "B", 1.0, 1.0)])])
	assert_true(s.has("dmg_in"))
	for id in ["rep_in", "rep_out", "cap_in", "cap_out", "ewar_in", "ewar_out"]:
		assert_false(s.has(id), id)
	assert_false(CombatStats.from_logs([]).has("dmg_in"))


func test_ewar_type() -> void:
	assert_eq(CombatStats.ewar_type(_e(K.SCRAM, "A", "B", 0.0, NAN, "Warp scramble")), "scram")
	assert_eq(CombatStats.ewar_type(_e(K.SCRAM, "A", "B", 0.0, NAN, "Warp disruption")), "disrupt")
	assert_eq(CombatStats.ewar_type(_e(K.NEUT, "A", "B", 0.0, 1.0)), "neut")
	assert_eq(CombatStats.ewar_type(_e(K.NOS, "A", "B", 0.0, 1.0)), "nos")
	assert_eq(CombatStats.ewar_type(_e(K.JAM, "A", "B", 0.0, NAN, "Radar ECM")), "ecm")
	var named := {
		"Tracking Disruptor II": "td", "Guidance Disruptor II": "gd",
		"Remote Sensor Dampener II": "damp", "Target Painter II": "tp",
		"Remote Sensor Booster II": "rsb", "Remote Tracking Computer II": "rtc",
		"Stasis Webifier II": "web", "Fleeting Compact Stasis Webifier": "web",
	}
	for weapon in named:
		assert_eq(CombatStats.ewar_type(_e(K.OTHER, "A", "B", 0.0, NAN, weapon)), named[weapon], weapon)
	assert_eq(CombatStats.ewar_type(_e(K.DAMAGE, "A", "B", 0.0, 1.0, "Target Painter")), "")
	assert_eq(CombatStats.ewar_type(_e(K.OTHER, "A", "B", 0.0)), "")


func test_cycle_estimates() -> void:
	assert_eq(CombatStats.default_cycle("neut", "Small Energy Neutralizer II"), 6.0)
	assert_eq(CombatStats.default_cycle("neut", "Medium Energy Neutralizer II"), 12.0)
	assert_eq(CombatStats.default_cycle("neut", "Heavy Energy Neutralizer II"), 24.0)
	assert_eq(CombatStats.default_cycle("nos", "Medium Compact Energy Nosferatu"), 6.0)
	assert_eq(CombatStats.default_cycle("neut", "Corpus X-Type Energy Neutralizer"), 12.0, "no size")
	assert_eq(CombatStats.default_cycle("ecm", "Radar ECM"), 20.0)
	assert_eq(CombatStats.default_cycle("scram", "Warp scramble"), 5.0)
	var heavy := "Heavy Energy Neutralizer II"
	assert_eq(CombatStats.estimate_cycle("neut", heavy, [0.0]), 24.0, "nothing to measure")
	assert_eq(CombatStats.estimate_cycle("neut", heavy, [0.0, 21.0, 42.0, 63.0]), 21.0, "overheated")
	# Two staggered modules: 2 s gaps aren't a cycle; the 22 s one is.
	assert_eq(CombatStats.estimate_cycle("neut", heavy, [0.0, 2.0, 24.0, 26.0]), 22.0)
	assert_eq(CombatStats.estimate_cycle("neut", heavy, [0.0, 2.0, 4.0]), 24.0)


func test_ewar_at() -> void:
	var neut := "Medium Energy Neutralizer II"
	var s := CombatStats.from_logs([_log([
		_e(K.SCRAM, "A", "B", 0.0, NAN, "Warp scramble"),
		_e(K.SCRAM, "A", "B", 5.0, NAN, "Warp scramble"),
		_e(K.SCRAM, "C", "B", 4.0, NAN, "Warp scramble"),
		_e(K.NEUT, "A", "B", 1.0, 100.0, neut),
		_e(K.JAM, "B", "A", 2.0, NAN, "Radar ECM"),
	])])
	var got := s.ewar_at("B", false, 4.5)
	assert_eq(got.keys(), ["scram", "neut"])
	assert_eq(got.scram, [{"pilot": "A", "cycles": 1}, {"pilot": "C", "cycles": 1}])
	assert_eq(got.neut, [{"pilot": "A", "cycles": 1}])
	got = s.ewar_at("B", false, 9.5)
	assert_eq(got.scram, [{"pilot": "A", "cycles": 2}], "C's scram cycle ended at 9 s")
	assert_eq(got.neut, [{"pilot": "A", "cycles": 1}], "a 12 s cycle")
	assert_false(s.ewar_at("B", false, 13.5).has("neut"))
	assert_eq(s.ewar_at("B", false, -1.0), {}, "before anything")
	assert_eq(s.ewar_at("A", true, 4.5).scram, [{"pilot": "B", "cycles": 1}])
	assert_eq(s.ewar_at("A", false, 4.5).ecm, [{"pilot": "B", "cycles": 1}])
	assert_eq(s.ewar_at("B", true, 22.5), {}, "the 20 s jam ended")
	assert_eq(s.ewar_at("D", true, 1.0), {}, "unknown pilot")


func test_link_kind() -> void:
	for type in ["scram", "disrupt", "web"]:
		assert_eq(CombatStats.link_kind(type), "tackle", type)
	for type in ["neut", "nos"]:
		assert_eq(CombatStats.link_kind(type), "neut", type)
	for type in ["ecm", "td", "gd", "damp", "tp", "rsb", "rtc"]:
		assert_eq(CombatStats.link_kind(type), "ewar", type)


func test_links_at() -> void:
	var s := CombatStats.from_logs([_log([
		_e(K.DAMAGE, "A", "B", 1.0, 100.0, "Gun"),
		_e(K.DAMAGE, "A", "B", 3.0, 100.0, "Gun"),
		_e(K.MISS, "B", "A", 2.0, NAN, "Gun"),
		_e(K.SCRAM, "A", "B", 0.0, NAN, "Warp scramble"),
		_e(K.SCRAM, "A", "B", 5.0, NAN, "Warp scramble"),
		_e(K.NOS, "C", "A", 1.0, 10.0, "Small Energy Nosferatu II"),
		_e(K.OTHER, "C", "B", 1.0, NAN, "Target Painter II"),
	])])
	assert_eq(s.links_at(2.5), [
		{"kind": "shooting", "source": "A", "target": "B"},
		{"kind": "shooting", "source": "B", "target": "A"},
		{"kind": "tackle", "source": "A", "target": "B"},
		{"kind": "neut", "source": "C", "target": "A"},
		{"kind": "ewar", "source": "C", "target": "B"},
	])
	assert_eq(s.links_at(6.5), [
		{"kind": "shooting", "source": "A", "target": "B"},
		{"kind": "tackle", "source": "A", "target": "B"},
	], "hits 2 s apart hold until 3 + 4 s; scram cycles chain into one")
	assert_eq(s.links_at(7.5), [{"kind": "tackle", "source": "A", "target": "B"}])
	assert_eq(s.links_at(10.5), [], "last scram cycle ended at 10 s")
	assert_eq(s.links_at(-1.0), [])
