#!/usr/bin/env python3
"""Build a simulator points ruleset (simulator/rulesets/<id>.json) from an Alliance Tournament
"Quick Comp Creator" Google Sheet.

    scripts/ruleset_from_sheet.py 1AVYlWlvuMKnA3yuqqDCcAkia8pvhpb9OBcM29WFw5rM \
        --id ATXXII --name "Alliance Tournament XXII" --order 22

The sheet is downloaded as .xlsx (or read from --xlsx PATH) and parsed with the standard library:
  * ships, points and hull types come from the static values tab (ship name, class, points,
    hull type in columns F:I);
  * hull inflation comes from the calculator tab's points formula, whose
    SWITCH(hull, "Corvette", 0, "Frigate", 0, ..., default) adds (copies - 1) * factor to every
    copy of a ship fielded more than once;
  * the points cap is the number the calculator's totals are compared against (conditional
    formatting).
"""
import argparse
import io
import json
import os
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

NS = {
    "m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
}
REL_NS = "{http://schemas.openxmlformats.org/package/2006/relationships}"
EXPORT_URL = "https://docs.google.com/spreadsheets/d/%s/export?format=xlsx"
SHEET_URL = "https://docs.google.com/spreadsheets/d/%s"
STATIC_TAB = re.compile(r"static values", re.I)
CALCULATOR_TAB = re.compile(r"calculator", re.I)
# Placeholder rows of the ship dropdowns, worth nothing.
NOT_SHIPS = {"Empty", "Capsule"}


def col_row(ref):
    m = re.match(r"([A-Z]+)(\d+)$", ref)
    return m.group(1), int(m.group(2))


class Workbook:
    def __init__(self, data):
        self.zip = zipfile.ZipFile(io.BytesIO(data))
        self.strings = []
        if "xl/sharedStrings.xml" in self.zip.namelist():
            root = ET.fromstring(self.zip.read("xl/sharedStrings.xml"))
            for si in root.findall("m:si", NS):
                self.strings.append("".join(t.text or "" for t in si.iter("{%s}t" % NS["m"])))
        rels = ET.fromstring(self.zip.read("xl/_rels/workbook.xml.rels"))
        targets = {r.get("Id"): r.get("Target") for r in rels.iter(REL_NS + "Relationship")}
        self.sheets = {}
        for s in ET.fromstring(self.zip.read("xl/workbook.xml")).iter("{%s}sheet" % NS["m"]):
            target = targets[s.get("{%s}id" % NS["r"])].lstrip("/")
            self.sheets[s.get("name")] = target if target.startswith("xl/") else "xl/" + target

    def sheet(self, pattern):
        for name, path in self.sheets.items():
            if pattern.search(name):
                return ET.fromstring(self.zip.read(path))
        sys.exit("no sheet matching /%s/ (sheets: %s)" % (pattern.pattern, ", ".join(self.sheets)))

    def cells(self, sheet):
        """{ref: (value, formula)}; shared formulas keep only their master's text."""
        out = {}
        for c in sheet.iter("{%s}c" % NS["m"]):
            v = c.find("m:v", NS)
            f = c.find("m:f", NS)
            value = v.text if v is not None else None
            if value is not None and c.get("t") == "s":
                value = self.strings[int(value)]
            out[c.get("r")] = (value, f.text if f is not None else None)
        return out


def ships_from(wb):
    cells = wb.cells(wb.sheet(STATIC_TAB))
    rows = {}
    for ref, (value, _) in cells.items():
        col, row = col_row(ref)
        if col in ("F", "H", "I"):
            rows.setdefault(row, {})[col] = value
    ships = {}
    for row in sorted(rows):
        r = rows[row]
        name = (r.get("F") or "").strip()
        if not name or name in NOT_SHIPS or r.get("H") is None or r.get("I") is None:
            continue
        try:
            points = int(float(r["H"]))
        except ValueError:
            continue  # the header row
        ships[name] = {"points": points, "hull": r["I"].strip()}
    if not ships:
        sys.exit("no ships found in the static values tab")
    return ships


def inflation_from(wb):
    """Hull -> per-copy inflation and the default, from the calculator's SWITCH(...)."""
    for value, formula in wb.cells(wb.sheet(CALCULATOR_TAB)).values():
        if not formula or "SWITCH(" not in formula.upper():
            continue
        args = formula[formula.upper().index("SWITCH(") + len("SWITCH("):]
        args = args[: args.index(")")]
        parts = [p.strip() for p in re.findall(r'"[^"]*"|[^,]+', args)]
        pairs = parts[1:]
        inflation = {}
        for i in range(0, len(pairs) - 1, 2):
            inflation[pairs[i].strip('"')] = int(float(pairs[i + 1]))
        default = int(float(pairs[-1])) if len(pairs) % 2 == 1 else 0
        return inflation, default
    sys.exit("no SWITCH(...) inflation formula found in the calculator tab")


def point_cap_from(wb):
    sheet = wb.sheet(CALCULATOR_TAB)
    for cf in sheet.iter("{%s}conditionalFormatting" % NS["m"]):
        for rule in cf.iter("{%s}cfRule" % NS["m"]):
            f = rule.find("m:formula", NS)
            if f is not None and re.fullmatch(r"\d+", (f.text or "").strip()):
                return int(f.text)
    sys.exit("no points cap found in the calculator tab's conditional formatting")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sheet_id", help="Google Sheet id (from its URL)")
    ap.add_argument("--id", required=True, help="ruleset id, e.g. ATXXII")
    ap.add_argument("--name", required=True, help='display name, e.g. "Alliance Tournament XXII"')
    ap.add_argument("--order", type=int, required=True, help="sort key; the highest is the default ruleset")
    ap.add_argument("--xlsx", help="read this .xlsx export instead of downloading the sheet")
    ap.add_argument("--out", help="output path (default simulator/rulesets/<id lowercase>.json)")
    args = ap.parse_args()

    if args.xlsx:
        with open(args.xlsx, "rb") as f:
            data = f.read()
    else:
        with urllib.request.urlopen(EXPORT_URL % args.sheet_id) as r:
            data = r.read()
    wb = Workbook(data)
    inflation, default = inflation_from(wb)
    ruleset = {
        "id": args.id,
        "name": args.name,
        "order": args.order,
        "source": SHEET_URL % args.sheet_id,
        "point_cap": point_cap_from(wb),
        "inflation": inflation,
        "default_inflation": default,
        "ships": ships_from(wb),
    }
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = args.out or os.path.join(root, "simulator", "rulesets", args.id.lower() + ".json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    # One ship per line keeps year-on-year diffs readable.
    ships = ruleset.pop("ships")
    text = json.dumps(ruleset, indent="\t", ensure_ascii=False)[:-2]
    lines = ["\t\t%s: %s" % (json.dumps(n, ensure_ascii=False), json.dumps(s)) for n, s in ships.items()]
    text += ',\n\t"ships": {\n%s\n\t}\n}\n' % ",\n".join(lines)
    json.loads(text)
    ruleset["ships"] = ships
    with open(out, "w") as f:
        f.write(text)
    print("%s: %d ships, cap %d, inflation %s (else %d)" % (
        out, len(ruleset["ships"]), ruleset["point_cap"], inflation, default))


if __name__ == "__main__":
    main()
