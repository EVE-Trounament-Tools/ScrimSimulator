extends "res://tests/test_case.gd"
## CombatLog: parsing EVE gamelog lines, EVE times, and lining a log up with a match.

const K := CombatLog.Kind
const C := MatchData.CENTRE_M
const X := Vector3.RIGHT
const HEADER := "t,pilot,ship_type,x_m,y_m,z_m,speed_mps,dir_x,dir_y,dir_z,residual_m,eve_time"

## Real lines (timestamp and kind stripped), one per message shape.
const DAMAGE_OUT := "<color=0xff00ffff><b>204</b> <color=0x77ffffff><font size=10>to</font> <b><color=0xffffffff>sorrel17[ALPHA](Endurance)</b><font size=10><color=0x77ffffff> - Test Railgun - Glances Off"
const DAMAGE_IN := "<color=0xffcc0000><b>57</b> <color=0x77ffffff><font size=10>from</font> <b><color=0xffffffff>Wenna Torb[ALPHA](Covetor)</b><font size=10><color=0x77ffffff> - Test Drone B - Penetrates"
const SCRAM_THIRD := "<color=0xffffffff><b>Warp scramble attempt</b> <color=0x77ffffff><font size=10>from</font> <color=0xffffffff><b><font size=12><color=0xFFFFFFFF><b>Retriever</b></color></font><font size=11> [BRAVO]</font> <font size=11>[Narrow NineHawks] -</font></b> <color=0x77ffffff><font size=10>to <b><color=0xffffffff></font><font size=12><color=0xFFFFFFFF><b>Hulk</b></color></font><font size=11> [ALPHA]</font> <font size=11>[Kelto Ruvan] -</font>"
const SCRAM_OUT := "<color=0xffffffff><b>Warp scramble attempt</b> <color=0x77ffffff><font size=10>from</font> <color=0xffffffff><b>you</b> <color=0x77ffffff><font size=10>to <b><color=0xffffffff></font><font size=12><color=0xFFFFFFFF><b>Hulk</b></color></font> <font size=11>[Kelto Ruvan] -</font>"
const NEUT_IN := "<color=0xffe57f7f><b>94 GJ</b><color=0x77ffffff><font size=10> energy neutralized </font><b><color=0xffffffff><font size=12><color=0xFFFFFFFF><b>Covetor</b></color></font> <font size=11>[Wenna Torb] -</font></b><color=0x77ffffff><font size=10> - Small Energy Neutralizer II</font>"
const NEUT_OUT := "<color=0xff7fffff><b>94 GJ</b><color=0x77ffffff><font size=10> energy neutralized </font><b><color=0xffffffff><font size=12><color=0xFFFFFFFF><b>Covetor</b></color></font> <font size=11>[Wenna Torb] -</font></b><color=0x77ffffff><font size=10> - Heavy Energy Neutralizer II</font>"
const NOS_IN := "<color=0xffe57f7f><b>-3 GJ</b><color=0x77ffffff><font size=10> energy drained to </font><b><color=0xffffffff><font size=12><color=0xFFFFFFFF><b>Covetor</b></color></font> <font size=11>[Kelto Ruvan] -</font></b><color=0x77ffffff><font size=10> - Medium Energy Nosferatu II</font>"
const NOS_OUT := "<color=0xff7fffff><b>+33 GJ</b><color=0x77ffffff><font size=10> energy drained from </font><b><color=0xffffffff><font size=12><color=0xFFFFFFFF><b>Orca</b></color></font> </b><color=0x77ffffff><font size=10> - Medium Compact Energy Nosferatu</font>"
const REP_IN := "<color=0xffccff66><b>15</b><color=0x77ffffff><font size=10> remote armor repaired by </font><b><color=0xffffffff><font size=12><color=0xFFFFFFFF><b>Light Repair Drone</b></color></font> <font size=11>[Light Repair Drone] -</font></b><color=0x77ffffff><font size=10> - Light Repair Drone</font>"
const JAM_IN := "<color=0x77ffffff><font size=10>You're</font> <color=0xffffffff><b>jammed</b> <color=0x77ffffff><font size=10>by</font> <color=0xffffffff><b><font size=12><color=0xFFFFFFFF><b>Prospect</b></color></font> </b><color=0x77ffffff><font size=10> - Radar ECM</font>"
const JAM_OUT := "<color=0xffffffff><b><font size=12><color=0xFFFFFFFF><b>Mackinaw</b></color></font> <font size=11>[Kelto Ruvan] -</font> jammed</b><color=0x77ffffff><font size=10> - Ladar ECM</font>"
const JAM_OUT_NO_PILOT := "<color=0xffffffff><b><font size=12><color=0xFFFFFFFF><b>Porpoise</b></color></font>  jammed</b><color=0x77ffffff><font size=10> - Gravimetric ECM</font>"
const REP_OUT := "<color=0xffccff66><b>488</b><color=0x77ffffff><font size=10> remote shield boosted to </font><b><color=0xffffffff><font size=12><color=0xFFFFFFFF><b>Procurer</b></color></font> </b><color=0x77ffffff><font size=10> - Medium Remote Shield Booster</font>"


func _log_text(lines: Array, listener := "Halvard Ostbergte") -> String:
	var out := "------------------------------------------------------------\r\n  Gamelog\r\n"
	out += "  Listener: %s\r\n  Session Started: 2026.10.03 12:45:32\r\n" % listener
	out += "------------------------------------------------------------\r\n"
	for l in lines:
		out += l + "\r\n"
	return out


func _write_log(lines: Array, listener := "Halvard Ostbergte") -> String:
	var path := temp_dir().path_join("20261003_124532_1.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(_log_text(lines, listener))
	f.close()
	return path


## Pilots "Halvard Ostberg" and "Wenna Torb", samples every 2 s from CSV t=0 (14:03:14) to t=10;
## Halvard first moves at t=4, so match time 0 is CSV t=2 (14:03:16).
func _match() -> MatchData:
	var rows := []
	for t in range(0, 12, 2):
		var eve := "2026-10-03T14:03:%02d.000Z" % (14 + t)
		var a := row(t, "Halvard Ostberg", "Skiff", C + X * (0.0 if t < 4 else 1000.0 * t))
		var b := row(t, "Wenna Torb", "Covetor", C - X * 5000.0)
		rows.append(a + [eve])
		rows.append(b + [eve])
	return MatchData.load_csv(write_csv(rows, HEADER))


# --- parse_line --------------------------------------------------------------

func test_damage_out() -> void:
	var e := CombatLog.parse_line(DAMAGE_OUT)
	assert_eq(e.kind, K.DAMAGE)
	assert_eq(e.amount, 204.0)
	assert_eq(e.source, "", "the listener")
	assert_eq(e.target, "sorrel17")
	assert_eq(e.target_ship, "Endurance")
	assert_eq(e.weapon, "Test Railgun")
	assert_eq(e.quality, "Glances Off")
	assert_eq(e.text, "204 to sorrel17[ALPHA](Endurance) - Test Railgun - Glances Off")


func test_damage_in() -> void:
	var e := CombatLog.parse_line(DAMAGE_IN)
	assert_eq(e.kind, K.DAMAGE)
	assert_eq(e.source, "Wenna Torb")
	assert_eq(e.source_ship, "Covetor")
	assert_eq(e.target, "")
	assert_eq(e.weapon, "Test Drone B")
	assert_eq(e.quality, "Penetrates")


func test_misses() -> void:
	var e := CombatLog.parse_line("Your group of Test Railgun misses Dim Reef completely - Test Railgun")
	assert_eq(e.kind, K.MISS)
	assert_eq([e.source, e.target, e.weapon], ["", "Dim Reef", "Test Railgun"])
	e = CombatLog.parse_line("Your Test Drone A misses essa brook completely - Test Drone A")
	assert_eq([e.source, e.target, e.weapon], ["", "essa brook", "Test Drone A"])
	e = CombatLog.parse_line("Test Drone A belonging to Narrow NineHawks misses you completely - Test Drone A")
	assert_eq(e.kind, K.MISS)
	assert_eq([e.source, e.target, e.weapon], ["Narrow NineHawks", "", "Test Drone A"])
	e = CombatLog.parse_line("qvarus misses you completely - Test Railgun B")
	assert_eq([e.source, e.target], ["qvarus", ""])


func test_scram() -> void:
	var e := CombatLog.parse_line(SCRAM_THIRD)
	assert_eq(e.kind, K.SCRAM)
	assert_eq(e.weapon, "Warp scramble")
	assert_eq([e.source, e.source_ship], ["Narrow NineHawks", "Retriever"])
	assert_eq([e.target, e.target_ship], ["Kelto Ruvan", "Hulk"])
	e = CombatLog.parse_line(SCRAM_OUT)
	assert_eq([e.source, e.target, e.target_ship], ["", "Kelto Ruvan", "Hulk"])
	e = CombatLog.parse_line("Warp disruption attempt from Keres [X Y Z] [TSTCO] [Lysande Vonnimarchos] - to you!")
	assert_eq(e.weapon, "Warp disruption")
	assert_eq([e.source, e.source_ship, e.target], ["Lysande Vonnimarchos", "Keres", ""])


func test_neut_direction_from_colour() -> void:
	var e := CombatLog.parse_line(NEUT_IN)
	assert_eq(e.kind, K.NEUT)
	assert_eq(e.amount, 94.0)
	assert_eq([e.source, e.source_ship, e.target], ["Wenna Torb", "Covetor", ""])
	assert_eq(e.weapon, "Small Energy Neutralizer II")
	e = CombatLog.parse_line(NEUT_OUT)
	assert_eq([e.source, e.target, e.target_ship], ["", "Wenna Torb", "Covetor"])


func test_nos() -> void:
	var e := CombatLog.parse_line(NOS_IN)
	assert_eq(e.kind, K.NOS)
	assert_eq(e.amount, 3.0)
	assert_eq([e.source, e.target], ["Kelto Ruvan", ""])
	e = CombatLog.parse_line(NOS_OUT)
	assert_eq(e.amount, 33.0)
	assert_eq([e.source, e.target, e.target_ship], ["", "Orca", "Orca"], "no pilot shown: the ship")


func test_remote_reps() -> void:
	var e := CombatLog.parse_line(REP_IN)
	assert_eq(e.kind, K.REMOTE_REP)
	assert_eq(e.amount, 15.0)
	assert_eq([e.source, e.target], ["Light Repair Drone", ""])
	e = CombatLog.parse_line(REP_OUT)
	assert_eq([e.source, e.target, e.weapon], ["", "Procurer", "Medium Remote Shield Booster"])


func test_jams() -> void:
	var e := CombatLog.parse_line(JAM_IN)
	assert_eq(e.kind, K.JAM)
	assert_eq([e.source, e.source_ship, e.target, e.weapon], ["Prospect", "Prospect", "", "Radar ECM"])
	e = CombatLog.parse_line(JAM_OUT)
	assert_eq(e.kind, K.JAM)
	assert_eq([e.source, e.target, e.target_ship, e.weapon],
			["", "Kelto Ruvan", "Mackinaw", "Ladar ECM"])
	e = CombatLog.parse_line(JAM_OUT_NO_PILOT)
	assert_eq(e.kind, K.JAM)
	assert_eq([e.source, e.target, e.weapon], ["", "Porpoise", "Gravimetric ECM"])


func test_unknown_is_other() -> void:
	var e := CombatLog.parse_line("<b>Something new</b> happened")
	assert_eq(e.kind, K.OTHER)
	assert_eq(e.text, "Something new happened")


# --- times and names -----------------------------------------------------------

func test_parse_eve_time() -> void:
	var t := CombatLog.parse_eve_time("2026.10.03 14:03:30")
	assert_eq(t, float(Time.get_unix_time_from_datetime_string("2026-10-03T14:03:30")))
	assert_eq(CombatLog.parse_eve_time("2026-10-03T14:03:30.000Z"), t)
	assert_eq(CombatLog.parse_eve_time("2026-10-03T14:03:30.250Z"), t + 0.25)
	assert_true(is_nan(CombatLog.parse_eve_time("")))
	assert_true(is_nan(CombatLog.parse_eve_time("yesterday at noon!!")))


func test_resolve_pilot() -> void:
	var pilots := ["Halvard Ostberg", "ZQlHARBOR", "Juno Bellamell", "ZIO", "Dim Reef"]
	assert_eq(CombatLog.resolve_pilot("Halvard Ostbergte", pilots), "Halvard Ostberg", "OCR cut it short")
	assert_eq(CombatLog.resolve_pilot("ZQLHARBOR", pilots), "ZQlHARBOR", "case")
	assert_eq(CombatLog.resolve_pilot("Dim Reef", pilots), "Dim Reef")
	assert_eq(CombatLog.resolve_pilot("Juno Bellame11e", pilots), "Juno Bellamell", "similar")
	assert_eq(CombatLog.resolve_pilot("Ostra Hel Brannik", pilots), "")
	assert_eq(CombatLog.resolve_pilot("", pilots), "")
	assert_eq(CombatLog.resolve_pilot("Lo", ["Dim Reef"]), "", "too short to be a prefix")


func test_resolve_pilot_ambiguous_prefix() -> void:
	assert_eq(CombatLog.resolve_pilot("Halvard", ["Halvard One", "Halvard Two"]), "")


# --- loading and sync ----------------------------------------------------------

func test_load_file() -> void:
	var gamelog := CombatLog.load_file(_write_log([
		"[ 2026.10.03 14:03:20 ] (combat) " + DAMAGE_IN,
		"[ 2026.10.03 14:03:18 ] (notify) Loading the Hybrid Charge into the Hybrid Weapon",
		"[ 2026.10.03 14:03:17 ] (combat) " + DAMAGE_OUT,
		"[ 2026.10.03 14:03:19 ] (question) Are you sure you want to join the fleet?",
		"<br><br>",
	]))
	assert_not_null(gamelog)
	assert_eq(gamelog.listener, "Halvard Ostbergte")
	assert_eq(gamelog.session_start, CombatLog.parse_eve_time("2026.10.03 12:45:32"))
	assert_eq(gamelog.entries.size(), 2, "combat only")
	assert_eq(gamelog.entries[0].target, "sorrel17", "sorted by time")
	assert_true(is_nan(gamelog.entries[0].t), "not synced yet")


func test_load_rejects_non_gamelogs() -> void:
	var path := temp_dir().path_join("notes.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("just some text\n")
	f.close()
	assert_null(CombatLog.load_file(path))
	assert_null(CombatLog.load_file(temp_dir().path_join("missing.txt")))


func test_trim() -> void:
	var text := _log_text([
		"[ 2026.10.03 14:03:10 ] (combat) " + DAMAGE_OUT,
		"[ 2026.10.03 14:03:12 ] (question) Are you sure you want to join the fleet?",
		"<br><br>",
		"NOTE: Attacking members of your fleet is not a CONCORD sanctioned activity.",
		"[ 2026.10.03 14:03:20 ] (notify) Loading the Hybrid Charge into the Hybrid Weapon",
		"[ 2026.10.03 14:03:21 ] (combat) " + DAMAGE_IN,
		"[ 2026.10.03 14:03:22 ] (question) Really?",
		"<br>more",
		"[ 2026.10.03 14:03:40 ] (combat) " + DAMAGE_OUT,
	])
	var first := CombatLog.parse_eve_time("2026.10.03 14:03:12")
	var last := CombatLog.parse_eve_time("2026.10.03 14:03:22")
	var trimmed := CombatLog.trim(text, first, last)
	assert_eq(trimmed, _log_text([
		"[ 2026.10.03 14:03:12 ] (question) Are you sure you want to join the fleet?",
		"<br><br>",
		"NOTE: Attacking members of your fleet is not a CONCORD sanctioned activity.",
		"[ 2026.10.03 14:03:20 ] (notify) Loading the Hybrid Charge into the Hybrid Weapon",
		"[ 2026.10.03 14:03:21 ] (combat) " + DAMAGE_IN,
		"[ 2026.10.03 14:03:22 ] (question) Really?",
		"<br>more",
	]), "header, and every line in the window with its continuation lines")
	assert_eq(CombatLog.trim(trimmed, first, last), trimmed, "trimming twice changes nothing")
	assert_eq(CombatLog.parse(trimmed).listener, "Halvard Ostbergte")
	assert_eq(CombatLog.trim("just text\n", first, last), "", "not a gamelog")


func test_sync() -> void:
	var d := _match()
	assert_eq(d.start_time, 2.0)
	var gamelog := CombatLog.load_file(_write_log([
		"[ 2026.10.03 14:03:05 ] (combat) " + DAMAGE_OUT,  # before the CSV - slack
		"[ 2026.10.03 14:03:14 ] (combat) " + DAMAGE_IN,  # first sample: match time -2
		"[ 2026.10.03 14:03:20 ] (combat) " + NEUT_IN,
		"[ 2026.10.03 14:03:24 ] (combat) " + SCRAM_THIRD,  # last sample
		"[ 2026.10.03 14:03:40 ] (combat) " + DAMAGE_OUT,  # after the CSV + slack
	]))
	gamelog.sync(d)
	assert_eq(gamelog.pilot, "Halvard Ostberg")
	assert_eq(gamelog.entries.map(func(e): return e.t), [-2.0, 4.0, 8.0])
	var neut: Dictionary = gamelog.entries[1]
	assert_eq([neut.source_pilot, neut.target_pilot], ["Wenna Torb", "Halvard Ostberg"])
	var scram: Dictionary = gamelog.entries[2]
	assert_eq([scram.source_pilot, scram.target_pilot], ["", ""], "not in this match")
	assert_almost(d.eve_unix_at(4.0), neut.eve_unix)


func test_same_event_in_several_logs_counts_once() -> void:
	# One scram from Halvard to Wenna, as each of the scrammer, the target and a bystander logs it.
	var d := _match()
	var lines := {
		"Halvard Ostbergte": "Warp scramble attempt from you to Covetor [ALPHA] [Wenna Torb] -",
		"Wenna Torb": "Warp scramble attempt from Skiff [ALPHA] [Halvard Ostbergte] - to you!",
		"Someone Else": "Warp scramble attempt from Skiff [ALPHA] [Halvard Ostbergte] - to Covetor [ALPHA] [Wenna Torb] -",
	}
	var logs := []
	for listener in lines:
		var gamelog := CombatLog.load_file(_write_log(["[ 2026.10.03 14:03:20 ] (combat) " + lines[listener]], listener))
		gamelog.sync(d)
		var e: Dictionary = gamelog.entries[0]
		assert_eq([e.source_pilot, e.target_pilot], ["Halvard Ostberg", "Wenna Torb"], listener)
		logs.append(gamelog)
	assert_eq(CombatStats.merge(logs).size(), 1)
	var stats := CombatStats.from_logs(logs)
	assert_eq(stats.ewar_at("Wenna Torb", false, 4.5).scram, [{"pilot": "Halvard Ostberg", "cycles": 1}])


func test_sync_override_and_unknown_listener() -> void:
	var d := _match()
	var gamelog := CombatLog.load_file(_write_log(["[ 2026.10.03 14:03:20 ] (combat) " + DAMAGE_OUT], "Someone Else"))
	gamelog.sync(d)
	assert_eq(gamelog.pilot, "")
	assert_eq(gamelog.entries[0].source_pilot, "")
	gamelog.sync(d, "Wenna Torb")
	assert_eq(gamelog.pilot, "Wenna Torb")
	assert_eq(gamelog.entries[0].source_pilot, "Wenna Torb")
	gamelog.sync(d, "nobody")
	assert_eq(gamelog.pilot, "", "an override that isn't in the match is ignored")


func test_sync_without_eve_time_keeps_nothing() -> void:
	var d := MatchData.load_csv(write_csv([row(0, "Halvard Ostberg", "Skiff", C)]))
	var gamelog := CombatLog.load_file(_write_log(["[ 2026.10.03 14:03:20 ] (combat) " + DAMAGE_OUT]))
	gamelog.sync(d)
	assert_eq(gamelog.pilot, "Halvard Ostberg")
	assert_eq(gamelog.entries, [])
