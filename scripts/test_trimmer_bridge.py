"""Tests for scrim_trimmer_bridge.py against ScrimTrimmer's own test recordings.

    python3 -m unittest scripts/test_trimmer_bridge.py

Skipped when the submodule, tesseract or the Python deps are missing.
"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import unittest
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "scrim_trimmer_bridge.py")
RES = os.path.join(HERE, "..", "third_party", "ScrimTrimmer", "src", "tests", "resources")
# The cases' Local chat panel: pixels (0, 312)-(192, 738) of the 1280x800 frame.
CHAT_REGION = ["0", str(312 / 800), str(192 / 1280), str(738 / 800)]

sys.path.insert(0, HERE)
from scrim_trimmer_bridge import pair_cd_wf, spans_overlap, t0_datetime  # noqa: E402

HAVE_DEPS = (
    os.path.isdir(RES)
    and shutil.which("tesseract") is not None
    and shutil.which("ffprobe") is not None
    and all(importlib.util.find_spec(m) for m in ("cv2", "numpy", "pytesseract", "PIL"))
)


def run_bridge(case: int, *extra: str) -> dict:
    out = subprocess.run(
        [sys.executable, BRIDGE, os.path.join(RES, f"case{case}.mkv"),
         "--chat-log", os.path.join(RES, f"case{case}.txt"),
         # The cases' file times are when they were checked out, not recorded.
         "--no-date-check", *extra],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    return json.loads(out.stdout)


class T0Date(unittest.TestCase):
    def utc(self, *a):
        return datetime(*a, tzinfo=timezone.utc)

    def test_same_day(self):
        self.assertEqual(t0_datetime(63835, self.utc(2026, 4, 4, 17, 42, 57)),
                         self.utc(2026, 4, 4, 17, 43, 55))

    def test_log_starts_after_midnight_recording_before(self):
        self.assertEqual(t0_datetime(86390, self.utc(2026, 4, 5, 0, 0, 5)),
                         self.utc(2026, 4, 4, 23, 59, 50))

    def test_log_starts_before_midnight_recording_after(self):
        self.assertEqual(t0_datetime(10, self.utc(2026, 4, 4, 23, 59, 30)),
                         self.utc(2026, 4, 5, 0, 0, 10))


class SpansOverlap(unittest.TestCase):
    def span(self, day, h0, h1):
        return (datetime(2026, 4, day, h0, tzinfo=timezone.utc), datetime(2026, 4, day, h1, tzinfo=timezone.utc))

    def test_overlapping(self):
        self.assertTrue(spans_overlap(self.span(4, 12, 15), self.span(4, 14, 16)))

    def test_inside(self):
        self.assertTrue(spans_overlap(self.span(4, 12, 18), self.span(4, 14, 16)))

    def test_within_slack(self):
        # Recording remuxed half an hour after the log ended.
        log = self.span(4, 12, 14)
        video = (log[1] + timedelta(minutes=30), log[1] + timedelta(hours=2))
        self.assertTrue(spans_overlap(log, video))

    def test_past_slack(self):
        self.assertFalse(spans_overlap(self.span(4, 12, 14), self.span(4, 16, 18)))

    def test_another_day(self):
        self.assertFalse(spans_overlap(self.span(4, 12, 15), self.span(8, 12, 15)))
        self.assertFalse(spans_overlap(self.span(8, 12, 15), self.span(4, 12, 15)))


class PairCdWf(unittest.TestCase):
    def test_typed_cd_beats_later_countdown(self):
        # CD, then the last 10 s counted down before the WF.
        self.assertEqual(pair_cd_wf([100], [690], [702]), [(100, 702)])

    def test_countdown_without_cd(self):
        self.assertEqual(pair_cd_wf([], [100], [400]), [(100, 400)])

    def test_latest_typed_cd(self):
        self.assertEqual(pair_cd_wf([100, 160], [], [400]), [(160, 400)])

    def test_rounds(self):
        self.assertEqual(
            pair_cd_wf([100, 900], [500, 1300], [520, 1310, 1700]),
            [(100, 520), (900, 1310)],
        )
        self.assertEqual(pair_cd_wf([900], [100], [400, 1200]), [(100, 400), (900, 1200)])

    def test_wf_without_cd(self):
        self.assertEqual(pair_cd_wf([500], [], [400, 800]), [(500, 800)])


@unittest.skipUnless(HAVE_DEPS, "needs the ScrimTrimmer submodule, tesseract, ffprobe and Python deps")
class Bridge(unittest.TestCase):
    def test_detects_t0_and_match(self):
        out = run_bridge(6, "--chat-region", *CHAT_REGION)
        self.assertEqual(out["t0_utc"], "2026-04-04T18:01:54Z")
        self.assertEqual(out["t0_source"], "auto")
        self.assertEqual(out["pairs"], [[73, 109]])

    def test_provided_t0_lists_every_match(self):
        out = run_bridge(3, "--t0", "17:52:22")
        self.assertEqual(out["t0_utc"], "2026-04-04T17:52:22Z")
        self.assertEqual(out["t0_source"], "provided")
        self.assertEqual(out["pairs"], [[8, 41], [59, 95]])


if __name__ == "__main__":
    unittest.main()
