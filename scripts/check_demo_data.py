#!/usr/bin/env python3
"""Fail if the checked-in demo data looks like a real match.

Match data may be committed only when it has no real character names, no tournament-legal
ships and no real modules. Every CSV and gamelog under resouces/demo/ must therefore use only the
names scripts/anonymize.py produces ("<Faction> Citizen <7 digits>"), no ship that has points in
any ruleset under simulator/rulesets/, and only its generic module names.

    scripts/check_demo_data.py
"""
import csv
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEMO = ROOT / "resouces" / "demo"
NAME = re.compile(r"(Amarr|Caldari|Gallente|Minmatar) Citizen \d{7}")
# Gamelog: "<b>Ship</b></color></font> <font size=11>[Pilot] -" and the header's listener.
LOG_SHIP = re.compile(r"<b>([^<>]+)</b></color></font>")
LOG_PILOT = re.compile(r"<font size=11>\[([^\]]+)\] -")
LOG_LISTENER = re.compile(r"^\s*Listener: (.+?)\s*$", re.M)
# Drones / NPCs show their own name in both slots; scripts/anonymize.py keeps those.
LOG_SHIP_PILOT = re.compile(r"<b>([^<>]+)</b></color></font> <font size=11>\[([^\]]+)\] -")
# The module at a line's end: damage "- Module - Quality", misses "completely - Module", the rest
# "- Module</font>".
LOG_MODULE = re.compile(r" - ([^<>]+?)(?: - [A-Z][a-z]+(?: [A-Za-z]+)?)?(?:</font>)?$", re.M)
GENERIC_MODULE = re.compile(
    r"Weapon [A-Z]|(?:(?:Small|Medium|Heavy) )?(?:Energy Neutralizer|Energy Nosferatu|ECM|Tracking Disruptor|"
    r"Guidance Disruptor|Sensor Dampener|Target Painter|Remote Sensor Booster|Remote Tracking Computer|"
    r"Stasis Webifier|Warp Scrambler|Warp Disruptor|Remote Repairer)")


def legal_ships() -> set[str]:
    ships = set()
    for path in (ROOT / "simulator" / "rulesets").glob("*.json"):
        ships |= set(json.loads(path.read_text())["ships"])
    return ships


def main() -> int:
    legal = legal_ships()
    problems = []

    def check(path: Path, pilots, ships) -> None:
        rel = path.relative_to(ROOT)
        for p in sorted(set(pilots)):
            if not NAME.fullmatch(p):
                problems.append(f"{rel}: pilot name not anonymized: {p!r}")
        for s in sorted(set(ships) & legal):
            problems.append(f"{rel}: legal ship: {s!r}")

    for path in sorted(DEMO.rglob("*.csv")):
        with path.open(newline="") as f:
            rows = list(csv.DictReader(f))
        check(path, (r["pilot"] for r in rows), (r["ship_type"] for r in rows))
    for path in sorted(DEMO.rglob("*.txt")):
        text = path.read_text(errors="replace")
        npcs = {ship for ship, pilot in LOG_SHIP_PILOT.findall(text) if ship == pilot}
        pilots = [p for p in LOG_PILOT.findall(text) if p not in npcs]
        check(path, pilots + LOG_LISTENER.findall(text), LOG_SHIP.findall(text))
        modules = set(LOG_MODULE.findall(text)) | npcs
        for m in sorted(m for m in modules if not GENERIC_MODULE.fullmatch(m)):
            problems.append(f"{path.relative_to(ROOT)}: module not anonymized: {m!r}")

    for p in problems:
        print(p, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
