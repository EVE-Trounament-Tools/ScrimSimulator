#!/usr/bin/env python3
"""Anonymize a scrim-positions CSV (and optionally a pilot's EVE gamelog) for demos and tests.

Ship types become the mining hull for their ruleset hull class (capsules stay capsules) and
each pilot becomes "<Faction> Citizen <7 digits>". The seed keeps output reproducible.

    scripts/anonymize.py resouces/matches/out/match_01.positions.csv resouces/demo/demo.positions.csv

With --gamelog IN OUT, gamelog IN is cut down to its combat lines during the match and written
to OUT with the same pilot names (log names are matched to the CSV's overview-OCR names the way
the simulator's CombatLog.resolve_pilot does; anyone else gets a fresh name), ships mapped as
above and corp tickers replaced:

    scripts/anonymize.py resouces/matches/out/match_01.positions.csv resouces/demo/demo.positions.csv \
        --gamelog resouces/matches/gamelogs/<date>_<time>_<character id>.txt \
        resouces/demo/demo.positions.logs/<date>_<time>.txt
"""
import argparse
import csv
import difflib
import json
import os
import random
import re
import sys
from datetime import datetime, timedelta, timezone

FACTIONS = ["Amarr", "Caldari", "Gallente", "Minmatar"]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RULESETS = os.path.join(ROOT, "simulator", "rulesets")

# Ruleset hull class -> mining hull of roughly the same size. Ship names come from the
# rulesets, so this script never has to list the hulls actually flown in a match.
HULL_MAP = {
    "Corvette": "Venture",
    "Frigate": "Venture",
    "Logistics Frigate": "Prospect",
    "Destroyer": "Endurance",
    "Cruiser": "Procurer",
    "Logistics": "Mackinaw",
    "Industrial": "Noctis",
    "Battlecruiser": "Porpoise",
    "Battleship": "Orca",
}
# Overview OCR misreads within this similarity of a ruleset ship name count as that ship.
MIN_SHIP_SIMILARITY = 0.8

TICKERS = ["ALPHA", "BRAVO", "CHARL", "DELTA", "ECHO", "FOXTR"]
# Gamelog lines kept: combat during the CSV's EVE span, plus this much either side (seconds).
LOG_SLACK_S = 5
# Same rules as CombatLog.resolve_pilot (similarity there is a bigram score, here difflib's).
MIN_SIMILARITY = 0.8
MIN_PREFIX = 3

LOG_LINE = re.compile(r"^\[ (\d{4}\.\d\d\.\d\d \d\d:\d\d:\d\d) \] \((\w+)\) (.*)$")
# Damage: ">Name[TICK](Ship)<".
DAMAGE_TARGET = re.compile(r">([^<>\[]+)\[([^\]<]*)\]\(([^)<]*)\)<")
# Scram / neut / nos / rep: "<b>Ship</b></color></font>", "<font size=11> [TICK]</font>",
# "<font size=11>[Name] -</font>".
SHIP_SLOT = re.compile(r"(<color=0xFFFFFFFF><b>)([^<]+)(</b></color>)")
TICKER_SLOT = re.compile(r"(<font size=11> \[)([^\]<]+)(\]</font>)")
NAME_SLOT = re.compile(r"(<font size=11>\[)([^\]<]+)(\] -</font>)")
MISS_OUT = re.compile(r"^(Your (?:group of )?.+? misses )(.+)( completely - .+)$")
MISS_IN = re.compile(r"^(?:(.+?) belonging to )?(.+?)( misses you completely - .+)$")


def resolve_pilot(name: str, pilots: list[str]) -> str:
    lower = name.strip().lower()
    for p in pilots:
        if p.lower() == lower:
            return p
    prefixed = [p for p in pilots
                if min(len(p), len(lower)) >= MIN_PREFIX and (lower.startswith(p.lower()) or p.lower().startswith(lower))]
    if len(prefixed) == 1:
        return prefixed[0]
    best, best_score = "", MIN_SIMILARITY
    for p in pilots:
        score = difflib.SequenceMatcher(None, lower, p.lower()).ratio()
        if score >= best_score:
            best, best_score = p, score
    return best


def ruleset_hulls() -> dict[str, str]:
    """Every ship with points in any ruleset under simulator/rulesets/, mapped to its hull class."""
    hulls = {}
    for name in sorted(os.listdir(RULESETS)):
        if name.endswith(".json"):
            with open(os.path.join(RULESETS, name)) as f:
                hulls.update({ship: v["hull"] for ship, v in json.load(f)["ships"].items()})
    return hulls


def mining_hull(ship_type: str, hulls: dict[str, str]) -> str | None:
    if ship_type == "Capsule":
        return ship_type
    if ship_type not in hulls:
        close = difflib.get_close_matches(ship_type, list(hulls), n=1, cutoff=MIN_SHIP_SIMILARITY)
        if not close:
            return None
        ship_type = close[0]
    return HULL_MAP.get(hulls[ship_type])


def eve_time(s: str) -> datetime:
    return datetime.strptime(s[:19].replace("-", ".").replace("T", " "), "%Y.%m.%d %H:%M:%S").replace(tzinfo=timezone.utc)


def anonymize_gamelog(src: str, dst: str, rows: list[dict], log_name, ship) -> int:
    """Writes the anonymized combat of gamelog `src` during the match in `rows` to `dst`.
    `log_name(real name)` and `ship(type)` give the replacements."""
    times = [eve_time(r["eve_time"]) for r in rows if r.get("eve_time")]
    if not times:
        print("the CSV has no eve_time column: can't tell which log lines are the match", file=sys.stderr)
        return 1
    first = min(times) - timedelta(seconds=LOG_SLACK_S)
    last = max(times) + timedelta(seconds=LOG_SLACK_S)
    tickers: dict[str, str] = {}

    def ticker(t: str) -> str:
        if t not in tickers:
            tickers[t] = TICKERS[len(tickers)]
        return tickers[t]

    out = []
    header = True
    with open(src, encoding="utf-8-sig") as fin:
        for line in fin:
            line = line.rstrip("\r\n")
            header = header and not line.startswith("[")
            if header:
                if line.strip().startswith("Listener:"):
                    line = f"  Listener: {log_name(line.split(':', 1)[1].strip())}"
                out.append(line)
                continue
            # Lines of multi-line messages don't match and are dropped with their message.
            m = LOG_LINE.match(line)
            if m is None or m.group(2) != "combat" or not first <= eve_time(m.group(1)) <= last:
                continue
            body = m.group(3)
            # Drones / NPCs show their own name where a pilot's ship and name go: keep those.
            npcs = {ship_name for ship_name in (d[2] for d in SHIP_SLOT.finditer(body))
                    if any(n[2] == ship_name for n in NAME_SLOT.finditer(body))}
            body = DAMAGE_TARGET.sub(lambda d: f">{log_name(d[1])}[{ticker(d[2])}]({ship(d[3])})<", body)
            body = SHIP_SLOT.sub(lambda d: d[1] + (d[2] if d[2] in npcs else ship(d[2])) + d[3], body)
            body = TICKER_SLOT.sub(lambda d: d[1] + ticker(d[2]) + d[3], body)
            body = NAME_SLOT.sub(lambda d: d[1] + (d[2] if d[2] in npcs else log_name(d[2])) + d[3], body)
            if (mo := MISS_OUT.match(body)) is not None:
                body = mo[1] + log_name(mo[2]) + mo[3]
            elif (mi := MISS_IN.match(body)) is not None:
                body = (f"{mi[1]} belonging to " if mi[1] else "") + log_name(mi[2]) + mi[3]
            out.append(f"[ {m.group(1)} ] (combat) {body}")
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    with open(dst, "w", encoding="utf-8", newline="\n") as fout:
        fout.write("\n".join(out) + "\n")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--seed", type=int, default=3)
    ap.add_argument("--gamelog", nargs=2, metavar=("IN", "OUT"),
                    help="also anonymize this pilot's gamelog, keeping only combat during the match")
    ap.add_argument("--ship", action="append", default=[], metavar="NAME=HULL",
                    help="hull class (as in the rulesets) for a ship type no ruleset knows; repeatable")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    names: dict[str, str] = {}
    used: set[str] = set()

    def pilot_name(pilot: str) -> str:
        if pilot not in names:
            while True:
                name = f"{rng.choice(FACTIONS)} Citizen {rng.randrange(10**7):07d}"
                if name not in used:
                    break
            used.add(name)
            names[pilot] = name
        return names[pilot]

    with open(args.input, newline="") as fin:
        reader = csv.DictReader(fin)
        rows = list(reader)
        fields = reader.fieldnames

    hulls = ruleset_hulls()
    for override in args.ship:
        name, _, hull = override.partition("=")
        hulls[name] = hull
    ship_map = {t: m for t in {r["ship_type"] for r in rows} if (m := mining_hull(t, hulls))}
    unknown = sorted({r["ship_type"] for r in rows} - ship_map.keys())
    if unknown:
        print(f"no mining equivalent for: {', '.join(unknown)}", file=sys.stderr)
        return 1

    # Assign names in sorted order so the mapping doesn't depend on row order.
    for pilot in sorted({r["pilot"] for r in rows}, key=str.lower):
        pilot_name(pilot)

    unknown_ships: set[str] = set()

    def ship(t: str) -> str:
        if t not in ship_map:
            if (m := mining_hull(t, hulls)) is None:
                unknown_ships.add(t)
                return t
            ship_map[t] = m
        return ship_map[t]

    if args.gamelog:
        pilots = sorted(names)

        def log_name(real: str) -> str:
            if real.lower() in ("you", "you!"):
                return real
            pilot = resolve_pilot(real, pilots)
            return names[pilot] if pilot else pilot_name("\0" + real)

        status = anonymize_gamelog(args.gamelog[0], args.gamelog[1], [dict(r) for r in rows], log_name, ship)
        if status:
            return status
        if unknown_ships:
            print(f"no mining equivalent for: {', '.join(sorted(unknown_ships))}", file=sys.stderr)
            os.remove(args.gamelog[1])
            return 1

    with open(args.output, "w", newline="") as fout:
        writer = csv.DictWriter(fout, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        for r in rows:
            r["pilot"] = names[r["pilot"]]
            if "raw_name" in r:
                r["raw_name"] = r["pilot"]
            r["ship_type"] = ship_map[r["ship_type"]]
            writer.writerow(r)
    return 0


if __name__ == "__main__":
    sys.exit(main())
