#!/usr/bin/env python3
"""Find a recording's match windows and EVE time base with ScrimTrimmer.

Called by `scrim-positions --chat-log`. Uses the ScrimTrimmer submodule
(third_party/ScrimTrimmer) unchanged:

  - t0 (EVE time at video second 0) from `log_matcher.detect_t0`, which matches
    the Local chat log against OCR of the chat region, or from `--t0`. That pass
    samples sparsely (ScrimTrimmer's own 30 s), so its t0 can be up to a sample
    interval early; `refine_t0` then pins it to the second by OCR'ing only the
    few seconds where some matched messages must have first appeared;
  - CD / WF (GF) video seconds from `chat_log_parser.parse_chat_logs`, paired by
    `chat_analyzer.pair_cd_wf`.

Prints one JSON object on stdout; everything else goes to stderr:

  {"t0_utc": "2026-04-04T17:43:55Z", "t0_source": "auto", "duration_s": 41.0,
   "pairs": [[4, 38]]}

`t0_utc` is a full UTC date and time: ScrimTrimmer's t0 is seconds since
midnight, and the date comes from the chat log.
"""

import argparse
import contextlib
import json
import os
import sys
from datetime import datetime, timedelta, timezone

TRIMMER_SRC = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "third_party", "ScrimTrimmer", "src"
)


def _import_trimmer():
    if not os.path.isdir(TRIMMER_SRC):
        sys.exit(
            f"ScrimTrimmer not found at {os.path.normpath(TRIMMER_SRC)}; "
            "run `git submodule update --init`"
        )
    sys.path.insert(0, TRIMMER_SRC)
    try:
        import chat_analyzer
        import chat_log_parser
        import frame_extractor
        import log_matcher
        import ocr_processor
    except ImportError as e:
        sys.exit(f"{e}; install the bridge's Python deps: pip install -r scripts/requirements-trimmer.txt")
    return chat_analyzer, chat_log_parser, frame_extractor, log_matcher, ocr_processor


def t0_datetime(t0_sec: int, log_first: datetime) -> datetime:
    """The UTC datetime whose time of day is `t0_sec`, on whichever of the day before, of or
    after the log's first entry puts it nearest that entry (the log may cross midnight)."""
    midnight = log_first.replace(hour=0, minute=0, second=0, microsecond=0)
    candidates = [midnight + timedelta(days=d, seconds=t0_sec) for d in (-1, 0, 1)]
    return min(candidates, key=lambda c: abs((c - log_first).total_seconds()))


# How many messages `refine_t0` tries, and how many first appearances it needs before it stops.
REFINE_TRIES = 8
REFINE_WANT = 5


def _wrap_day(d: int) -> int:
    """`d` seconds moved by a day, if needed, into (-12 h, 12 h] (a log crossing midnight)."""
    if d <= -43200:
        return d + 86400
    if d > 43200:
        return d - 86400
    return d


def refine_t0(log_matcher, ocr_processor, chat_logs, video, chat_region, t0_coarse, interval,
              duration, verbose=False):
    """t0 to the second, from a coarse `detect_t0` result sampled every `interval` s.

    The coarse t0 is a lower bound at most `interval` early, so a log message sent at game second
    g first showed on screen at a video second in [g - t0_coarse - interval, g - t0_coarse]. For a
    few of the longest unique messages, check it is on screen at the end of that window, then
    binary-search the window for its first appearance; each gives t0 = g - first_seen. Falls back
    to `t0_coarse` when no message can be pinned down.
    """
    import cv2
    import numpy as np

    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        return t0_coarse
    fps = cap.get(cv2.CAP_PROP_FPS)
    texts = {}

    def ocr(sec):
        if sec not in texts:
            cap.set(cv2.CAP_PROP_POS_FRAMES, int(sec * fps))
            ok, frame = cap.read()
            texts[sec] = log_matcher._normalize(ocr_processor.run_ocr_on_region(
                np.ascontiguousarray(ocr_processor.crop_chat_region(frame, *chat_region))
            )) if ok else ""
        return texts[sec]

    try:
        unique = log_matcher._load_unique_messages(chat_logs)
        windows = []
        for msg, game_sec in unique.items():
            hi = _wrap_day(game_sec - t0_coarse)
            lo = max(hi - interval - 1, 0)
            if 0 <= hi < duration:
                windows.append((len(msg), msg, game_sec, lo, hi))
        windows.sort(reverse=True)

        candidates = []
        for _, msg, game_sec, lo, hi in windows[:REFINE_TRIES]:
            if msg not in ocr(hi):
                continue
            # First second in (lo, hi] showing msg; `hi` is known to show it.
            while hi - lo > 1:
                mid = (lo + hi) // 2
                if msg in ocr(mid):
                    hi = mid
                else:
                    lo = mid
            if lo == 0 and msg in ocr(0):
                hi = 0
            t0 = t0_coarse + _wrap_day(game_sec - hi - t0_coarse)
            if verbose:
                print(f"    refine: '{msg[:50]}' first seen {hi}s -> t0={t0}")
            candidates.append(t0)
            if len(candidates) >= REFINE_WANT:
                break
    finally:
        cap.release()

    if not candidates:
        print(f"  warning: could not refine t0; using the {interval} s-sampled estimate", file=sys.stderr)
        return t0_coarse
    t0 = log_matcher._find_best_t0(candidates)
    print(f"  t0 refined {t0_coarse} -> {t0} s from {len(candidates)} message(s), {len(texts)} OCR'd frame(s)")
    return t0


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("video")
    p.add_argument("--chat-log", action="append", required=True, dest="chat_logs")
    p.add_argument(
        "--chat-region", type=float, nargs=4, metavar=("X1", "Y1", "X2", "Y2"),
        help="chat window as fractions of the frame (left top right bottom); needed unless --t0",
    )
    p.add_argument("--t0", metavar="HH:MM:SS", help="EVE time at video second 0 (skips detection)")
    p.add_argument(
        "--sample-interval", type=int, default=30, metavar="S",
        help="OCR one chat frame every S seconds when detecting t0 (default 30, as ScrimTrimmer). "
        "The result is then refined to the second around a few messages' first appearances",
    )
    p.add_argument(
        "--no-refine", action="store_false", dest="refine",
        help="keep the sampled t0, which can be up to --sample-interval seconds early",
    )
    p.add_argument("--tournament", action="store_true", help="tournament start/end system messages")
    p.add_argument("--no-detect-countdown", action="store_false", dest="detect_countdown")
    p.add_argument("--verbose", "-v", action="store_true")
    args = p.parse_args()

    chat_analyzer, chat_log_parser, frame_extractor, log_matcher, ocr_processor = _import_trimmer()

    entries = [e for path in args.chat_logs for e in chat_log_parser.read_chat_log(path)]
    if not entries:
        sys.exit("no chat lines found in " + ", ".join(args.chat_logs))
    log_first = min(ts for ts, _, _ in entries)

    duration = frame_extractor.probe_duration(args.video)
    if duration is None:
        duration = frame_extractor.get_video_duration(args.video)

    # ScrimTrimmer prints progress on stdout; keep stdout for the JSON.
    with contextlib.redirect_stdout(sys.stderr):
        if args.t0:
            t0_sec = chat_log_parser.game_time_to_seconds(args.t0)
            source = "provided"
        else:
            if args.chat_region is None:
                sys.exit("--chat-region is required to detect t0 (or pass --t0)")
            try:
                t0_sec = log_matcher.detect_t0(
                    args.chat_logs, args.video, chat_region=tuple(args.chat_region),
                    sample_interval=args.sample_interval, verbose=args.verbose,
                )
            except (RuntimeError, ValueError) as e:
                sys.exit(str(e))
            if args.refine and args.sample_interval > 1:
                t0_sec = refine_t0(
                    log_matcher, ocr_processor, args.chat_logs, args.video,
                    tuple(args.chat_region), t0_sec, args.sample_interval, duration,
                    verbose=args.verbose,
                )
            source = "auto"
        cd, wf = chat_log_parser.parse_chat_logs(
            args.chat_logs, t0_sec, duration,
            tournament_mode=args.tournament, detect_countdown=args.detect_countdown,
        )
        pairs = chat_analyzer.pair_cd_wf(cd, wf)
        print(f"  t0 {t0_sec} s ({source}); CDs {cd}; WFs {wf}; pairs {pairs}")

    t0 = t0_datetime(t0_sec, log_first).astimezone(timezone.utc)
    json.dump(
        {
            "t0_utc": t0.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "t0_source": source,
            "duration_s": duration,
            "pairs": [[int(a), int(b)] for a, b in pairs],
        },
        sys.stdout,
    )
    print()


if __name__ == "__main__":
    main()
