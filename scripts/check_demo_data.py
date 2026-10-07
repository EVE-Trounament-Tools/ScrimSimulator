#!/usr/bin/env python3
"""Fail if the checked-in demo data looks like a real match.

Match data may be committed only when it has no real character names and no tournament-legal
ships. Every CSV and gamelog under resouces/demo/ must therefore use only the names
scripts/anonymize.py produces ("<Faction> Citizen <7 digits>") and no ship that has points in
any ruleset under simulator/rulesets/.

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
        check(path, LOG_PILOT.findall(text) + LOG_LISTENER.findall(text), LOG_SHIP.findall(text))

    for p in problems:
        print(p, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
