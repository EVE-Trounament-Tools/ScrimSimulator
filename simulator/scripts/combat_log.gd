class_name CombatLog
extends RefCounted
## One EVE gamelog (`Documents/EVE/logs/Gamelogs/*.txt`): the combat seen by its listener, one
## pilot of a match. Only `(combat)` lines are kept. `sync` lines it up with a `MatchData` by EVE
## time and attributes it (and the other names in it) to the match's pilots, whose overview-OCR
## names may be truncated or mis-cased versions of the real ones.

enum Kind { DAMAGE, MISS, SCRAM, NEUT, NOS, REMOTE_REP, OTHER, JAM }

## Fuzzy name matches (`String.similarity`) below this don't count.
const MIN_SIMILARITY := 0.8
## Shortest name that may match another as a prefix (OCR truncation).
const MIN_PREFIX := 3
## Colour of an energy-neutralized line the listener caused; the incoming one is 0xffe57f7f.
const NEUT_OUT_COLOR := "ff7fffff"

## Character whose log this is, from the header.
var listener := ""
## Header "Session Started" time, unix seconds (NAN if missing).
var session_start := NAN
## Pilot (track name) of the synced match this log belongs to; "" if none matched.
var pilot := ""
## Path the log was read from.
var path := ""
## Sorted by time: Array of {
##   eve_unix: float (EVE time, unix s), t: float (match time; NAN until `sync`),
##   kind: Kind, text: String (the line without markup),
##   source, target: String (names as written; "" is the listener),
##   source_ship, target_ship: String ("" when not given),
##   source_pilot, target_pilot: String (match pilots after `sync`; "" when unknown),
##   amount: float (hit points, GJ, …; NAN when none), weapon: String, quality: String
##   ("Hits", "Smashes", … for damage) }.
## For SCRAM `weapon` is "Warp scramble" / "Warp disruption"; neither side may be the listener.
## For JAM `weapon` is the ECM module (or drone) that jammed.
var entries: Array = []

static var _tag_re := RegEx.create_from_string("<[^>]*>")
static var _line_re := RegEx.create_from_string(
	"^\\[ (\\d{4}\\.\\d\\d\\.\\d\\d \\d\\d:\\d\\d:\\d\\d) \\] \\(combat\\) (.*)$")
## Start of any log line: `[ 2026.10.03 14:03:30 ] `.
static var _time_re := RegEx.create_from_string("^\\[ (\\d{4}\\.\\d\\d\\.\\d\\d \\d\\d:\\d\\d:\\d\\d) \\] ")
static var _color_re := RegEx.create_from_string("^<color=0x([0-9a-fA-F]{8})>")
## `123 to Name[TICK](Ship) - Weapon - Quality`; ticker / ship / quality are optional.
static var _damage_re := RegEx.create_from_string(
	"^(\\d+) (to|from) (.+?)(?:\\[([^\\]]*)\\])?(?:\\(([^)]*)\\))? - (.+?)(?: - ([^-]+))?$")
static var _miss_out_re := RegEx.create_from_string("^Your (?:group of )?(.+?) misses (.+) completely - (.+)$")
static var _miss_in_re := RegEx.create_from_string("^(.+?) misses you completely - (.+)$")
static var _scram_re := RegEx.create_from_string("^(Warp (?:scramble|disruption)) attempt from (.+?) to (.+)$")
static var _neut_re := RegEx.create_from_string("^(\\d+) GJ energy neutralized (.+) - (.+)$")
static var _nos_re := RegEx.create_from_string("^([-+]\\d+) GJ energy drained (to|from) (.+) - (.+)$")
static var _rep_re := RegEx.create_from_string(
	"^(\\d+) remote (?:armor|shield|hull|structure) (?:repaired|boosted) (to|by) (.+) - (.+)$")
## `You're jammed by Ship [Name] - Module` / `Ship [Name] - jammed - Module` (the pilot may be missing).
static var _jam_in_re := RegEx.create_from_string("^You're jammed by (.+?) - (.+)$")
static var _jam_out_re := RegEx.create_from_string("^(.+?)\\s+jammed - (.+)$")
## `Ship [TICK] [ALLY] [Name] -`: the last bracket is the pilot.
static var _ship_name_re := RegEx.create_from_string("^(.*?)\\s*((?:\\[[^\\]]*\\]\\s*)*)-?\\s*$")


## Reads gamelog `file`; null (with an error) if it can't be read or has no `Listener:` header.
static func load_file(file: String) -> CombatLog:
	var f := FileAccess.open(file, FileAccess.READ)
	if f == null:
		push_error("Cannot open %s: %s" % [file, error_string(FileAccess.get_open_error())])
		return null
	var out := parse(f.get_as_text())
	if out == null:
		push_error("%s: not an EVE gamelog (no Listener header)" % file)
		return null
	out.path = file
	return out


## Parses gamelog text; null if it has no `Listener:` header.
static func parse(text: String) -> CombatLog:
	var out := CombatLog.new()
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("["):
			var m := _line_re.search(line)
			if m != null:
				var e := parse_line(m.get_string(2))
				e.eve_unix = parse_eve_time(m.get_string(1))
				out.entries.append(e)
		elif line.begins_with("Listener:"):
			out.listener = line.trim_prefix("Listener:").strip_edges()
		elif line.begins_with("Session Started:"):
			out.session_start = parse_eve_time(line.trim_prefix("Session Started:").strip_edges())
	if out.listener.is_empty():
		return null
	out.entries.sort_custom(func(a, b): return a.eve_unix < b.eve_unix)
	return out


## Gamelog `text` cut down to its header and the lines (of any kind) logged between EVE times
## `first` and `last` (unix s); the extra lines of a multi-line message go with it. Line endings
## are kept. "" if `text` isn't a gamelog (no `Listener:` header).
static func trim(text: String, first: float, last: float) -> String:
	var out := PackedStringArray()
	var header := true
	var listener := false
	var keep := false
	for line in text.split("\n"):
		var m := _time_re.search(line)
		header = header and m == null
		if header:
			listener = listener or line.strip_edges().begins_with("Listener:")
			out.append(line)
			continue
		if m != null:
			var t := parse_eve_time(m.get_string(1))
			keep = t >= first and t <= last
		if keep:
			out.append(line)
	if not listener:
		return ""
	var trimmed := "\n".join(out)
	return trimmed if trimmed.ends_with("\n") or not text.ends_with("\n") else trimmed + "\n"


## One `(combat)` message (markup included, timestamp and kind stripped) -> entry (see `entries`;
## `eve_unix` is left 0).
static func parse_line(html: String) -> Dictionary:
	var cm := _color_re.search(html)
	var color := cm.get_string(1).to_lower() if cm != null else ""
	var text := strip_markup(html)
	var e := {
		"eve_unix": 0.0, "t": NAN, "kind": Kind.OTHER, "text": text,
		"source": "", "target": "", "source_ship": "", "target_ship": "",
		"source_pilot": "", "target_pilot": "", "amount": NAN, "weapon": "", "quality": "",
	}
	var m := _damage_re.search(text)
	if m != null:
		e.kind = Kind.DAMAGE
		e.amount = float(m.get_string(1))
		_set_other(e, m.get_string(2) == "to", m.get_string(3).strip_edges(), m.get_string(5))
		e.weapon = m.get_string(6).strip_edges()
		e.quality = m.get_string(7).strip_edges()
		return e
	m = _miss_out_re.search(text)
	if m != null:
		e.kind = Kind.MISS
		e.target = m.get_string(2)
		e.weapon = m.get_string(3).strip_edges()
		return e
	m = _miss_in_re.search(text)
	if m != null:
		e.kind = Kind.MISS
		# Drones: "Test Drone A belonging to Some Pilot misses you completely".
		var parts := m.get_string(1).split(" belonging to ", true, 1)
		e.source = parts[-1]
		e.weapon = m.get_string(2).strip_edges()
		return e
	m = _scram_re.search(text)
	if m != null:
		e.kind = Kind.SCRAM
		e.weapon = m.get_string(1)
		var from := _ship_and_name(m.get_string(2))
		var to := _ship_and_name(m.get_string(3))
		e.source = from[1]
		e.source_ship = from[0]
		e.target = to[1]
		e.target_ship = to[0]
		return e
	m = _neut_re.search(text)
	if m != null:
		e.kind = Kind.NEUT
		e.amount = float(m.get_string(1))
		var other := _ship_and_name(m.get_string(2))
		_set_other(e, color == NEUT_OUT_COLOR, other[1], other[0])
		e.weapon = m.get_string(3).strip_edges()
		return e
	m = _nos_re.search(text)
	if m != null:
		e.kind = Kind.NOS
		e.amount = absf(float(m.get_string(1)))
		var other := _ship_and_name(m.get_string(3))
		# "+N drained from X": the listener's nosferatu; "-N drained to X": X's.
		_set_other(e, m.get_string(2) == "from", other[1], other[0])
		e.weapon = m.get_string(4).strip_edges()
		return e
	m = _rep_re.search(text)
	if m != null:
		e.kind = Kind.REMOTE_REP
		e.amount = float(m.get_string(1))
		var other := _ship_and_name(m.get_string(3))
		_set_other(e, m.get_string(2) == "to", other[1], other[0])
		e.weapon = m.get_string(4).strip_edges()
		return e
	m = _jam_in_re.search(text)
	if m == null:
		m = _jam_out_re.search(text)
	if m != null:
		e.kind = Kind.JAM
		var other := _ship_and_name(m.get_string(1))
		_set_other(e, not text.begins_with("You're"), other[1], other[0])
		e.weapon = m.get_string(2).strip_edges()
		return e
	return e


## Fills the side of `e` that isn't the listener.
static func _set_other(e: Dictionary, outgoing: bool, name: String, ship: String) -> void:
	if outgoing:
		e.target = name
		e.target_ship = ship
	else:
		e.source = name
		e.source_ship = ship


## "Hulk [ALPHA] [Kelto Ruvan] -" -> ["Hulk", "Kelto Ruvan"]; "you" / "you!" -> ["", ""];
## a bare "Venture" (no pilot shown) -> ["Venture", "Venture"].
static func _ship_and_name(s: String) -> Array:
	s = s.strip_edges()
	if s == "you" or s == "you!":
		return ["", ""]
	var m := _ship_name_re.search(s)
	var ship := m.get_string(1).strip_edges() if m != null else s
	var brackets := m.get_string(2).strip_edges() if m != null else ""
	if brackets.is_empty():
		return [ship, ship]
	var last := brackets.rfind("[")
	return [ship, brackets.substr(last + 1, brackets.length() - last - 2).strip_edges()]


## Text of a log message without its `<color>`/`<font>`/`<b>` markup, whitespace collapsed.
static func strip_markup(html: String) -> String:
	var text := _tag_re.sub(html, " ", true)
	while text.contains("  "):
		text = text.replace("  ", " ")
	return text.strip_edges()


## Unix seconds of an EVE (UTC) time: "2026.10.03 14:03:30" (gamelogs) or
## "2026-10-03T14:03:14.000Z" (`eve_time` in position CSVs). NAN if unparseable.
static func parse_eve_time(s: String) -> float:
	s = s.strip_edges()
	if s.length() < 19:
		return NAN
	var date := s.substr(0, 10).replace(".", "-").split("-")
	var clock := s.substr(11, 8).split(":")
	if date.size() != 3 or clock.size() != 3:
		return NAN
	for part in Array(date) + Array(clock):
		if not part.is_valid_int():
			return NAN
	var unix := float(Time.get_unix_time_from_datetime_dict({
		"year": int(date[0]), "month": int(date[1]), "day": int(date[2]),
		"hour": int(clock[0]), "minute": int(clock[1]), "second": int(clock[2]),
	}))
	if s.length() > 20 and s[19] == ".":
		var frac := s.substr(19).rstrip("Z")
		if frac.is_valid_float():
			unix += float(frac)
	return unix


## Lines this log up with `data`: attributes it to `pilot_override` if that is one of the match's
## pilots, else to the pilot whose name matches the listener (`resolve_pilot`); resolves the
## other names; sets each entry's match time `t`; and keeps only entries within
## `data.eve_window()`. Without EVE times in `data`, nothing is kept.
func sync(data: MatchData, pilot_override := "") -> void:
	var pilots := data.tracks.keys()
	pilot = pilot_override if data.tracks.has(pilot_override) else resolve_pilot(listener, pilots)
	if not data.has_eve_time():
		entries = []
		return
	var window := data.eve_window()
	var first := data.match_time_of(window[0])
	var last := data.match_time_of(window[1])
	var cache := {}
	var kept := []
	for e in entries:
		e.t = data.match_time_of(e.eve_unix)
		if e.t < first or e.t > last:
			continue
		e.source_pilot = pilot if e.source == "" else _resolve_cached(e.source, pilots, cache)
		e.target_pilot = pilot if e.target == "" else _resolve_cached(e.target, pilots, cache)
		kept.append(e)
	entries = kept


static func _resolve_cached(name: String, pilots: Array, cache: Dictionary) -> String:
	if not cache.has(name):
		cache[name] = resolve_pilot(name, pilots)
	return cache[name]


## The pilot in `pilots` (overview-OCR names) that is `name` (a real character name): an exact
## case-insensitive match, else the only one that is a prefix of it or it of them (OCR cuts long
## names short), else the most similar one at `MIN_SIMILARITY` or above. "" if none.
static func resolve_pilot(name: String, pilots: Array) -> String:
	var lower := name.strip_edges().to_lower()
	if lower.is_empty():
		return ""
	for p in pilots:
		if p.to_lower() == lower:
			return p
	var prefixed := []
	for p in pilots:
		var pl: String = p.to_lower()
		if mini(pl.length(), lower.length()) >= MIN_PREFIX and (lower.begins_with(pl) or pl.begins_with(lower)):
			prefixed.append(p)
	if prefixed.size() == 1:
		return prefixed[0]
	var best := ""
	var best_score := MIN_SIMILARITY
	for p in pilots:
		var score: float = lower.similarity(p.to_lower())
		if score >= best_score:
			best = p
			best_score = score
	return best
