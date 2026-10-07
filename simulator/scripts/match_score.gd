class_name MatchScore
extends RefCounted
## Team points through a match under a `Ruleset`: a team scores the points of every enemy ship
## lost (podded or out of bounds), and starts with whatever the enemy fleet leaves of the points
## cap. Pilots of unknown team are left out.

## Pilot -> the hull it fielded (its first non-capsule ship type; "" if it only flew a capsule).
var fielded := {}
## Pilot -> its ship's points in its team's fleet (with inflation).
var values := {}
## Team -> its fleet's total points.
var fleet_totals := {}
## Pilot -> match time its ship was lost (first podding or boundary crossing in a ship).
var loss_t := {}
var ruleset: Ruleset

var _teams := {}


func _init(data: MatchData, rules: Ruleset) -> void:
	ruleset = rules
	var fleets := {MatchData.Team.BLUE: [], MatchData.Team.RED: []}
	for pilot in data.tracks:
		var team: int = data.teams.get(pilot, MatchData.Team.UNKNOWN)
		if not fleets.has(team):
			continue
		_teams[pilot] = team
		var hull := ""
		for s in data.tracks[pilot]:
			if s.ship_type != MatchData.CAPSULE:
				hull = s.ship_type
				break
		fielded[pilot] = hull
		fleets[team].append(pilot)
	for team in fleets:
		var pts := ruleset.fleet_points(fleets[team].map(func(p): return fielded[p]))
		var total := 0
		for i in pts.size():
			values[fleets[team][i]] = pts[i]
			total += pts[i]
		fleet_totals[team] = total
	for e in data.events:
		if not _teams.has(e.pilot) or loss_t.has(e.pilot) or fielded[e.pilot] == "":
			continue
		var lost: bool = e.kind == MatchData.Event.DEATH \
				or (e.kind == MatchData.Event.BOUNDARY and e.ship_type != MatchData.CAPSULE)
		if lost:
			loss_t[e.pilot] = e.t  # events are sorted, so this is the first


static func opponent(team: int) -> int:
	return MatchData.Team.RED if team == MatchData.Team.BLUE else MatchData.Team.BLUE


## Points `team` starts with: what the enemy fleet leaves of the cap.
func head_start(team: int) -> int:
	return ruleset.head_start(fleet_totals.get(opponent(team), 0))


## `team`'s points at match time `t`: its head start plus every enemy ship lost by then.
func score(team: int, t: float) -> int:
	var total := head_start(team)
	var enemy := opponent(team)
	for pilot in loss_t:
		if _teams[pilot] == enemy and loss_t[pilot] <= t:
			total += values[pilot]
	return total
