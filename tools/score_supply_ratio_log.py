#!/usr/bin/env python3
"""Score misterplexd media: lines for supply_ratio (stream starvation).

Reads a daemon log (or stdin). Prefers the printed interval field
  supply_ratio=… supply_ratio_class=…
When the field is absent (old daemon), falls back to reconstructing
interval ratios from consecutive audio_s/wall_s pairs — same derivation.

Exit codes (direct; never through a pipe when you capture them):
  0  last established interval class=ok (and no starved in window if --any-starved)
  2  starved detected (hard FAIL — never demoted to 77)
 77  NO-DATA / no established interval in the file

Labels every printed value measured | reconstructed | DEFAULT_ASSUMED | NO-DATA.
Does NOT touch the device.
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from typing import List, Optional, Tuple


RE_SR = re.compile(
    r"supply_ratio=(?P<sr>NO-DATA|[0-9.]+)"
    r".*?supply_ratio_class=(?P<cls>ok|starved|NO-DATA)"
)
RE_AUDIO = re.compile(r"\baudio_s=(?P<a>[0-9.]+)\b")
RE_WALL = re.compile(r"\bwall_s=(?P<w>[0-9.]+)\b")
RE_MEDIA = re.compile(r"\bmedia:")


@dataclass
class Hit:
    kind: str  # measured | reconstructed
    ratio: Optional[float]
    cls: str
    line_no: int
    audio_s: Optional[float] = None
    wall_s: Optional[float] = None


def parse_line(line: str, line_no: int, prev: Optional[Tuple[float, float]],
               ok_min: float) -> Tuple[Optional[Hit], Optional[Tuple[float, float]]]:
    if not RE_MEDIA.search(line):
        return None, prev
    # Skip supply_bucket companion lines
    if "supply_bucket" in line or "supply_ledger" in line:
        return None, prev

    m = RE_SR.search(line)
    a_m = RE_AUDIO.search(line)
    w_m = RE_WALL.search(line)
    a = float(a_m.group("a")) if a_m else None
    w = float(w_m.group("w")) if w_m else None
    new_prev = prev
    if a is not None and w is not None:
        new_prev = (a, w)

    if m:
        raw = m.group("sr")
        cls = m.group("cls")
        if raw == "NO-DATA" or cls == "NO-DATA":
            return Hit("measured", None, "NO-DATA", line_no, a, w), new_prev
        try:
            ratio = float(raw)
        except ValueError:
            return Hit("measured", None, "NO-DATA", line_no, a, w), new_prev
        return Hit("measured", ratio, cls, line_no, a, w), new_prev

    # Reconstruct interval from consecutive cumulative pairs (old daemon).
    if a is None or w is None or prev is None:
        return None, new_prev
    pa, pw = prev
    da = a - pa
    dw = w - pw
    if dw < 0.40 or da < 0.0:
        return Hit("reconstructed", None, "NO-DATA", line_no, a, w), new_prev
    ratio = da / dw
    cls = "starved" if ratio < ok_min else "ok"
    return Hit("reconstructed", ratio, cls, line_no, a, w), new_prev


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("log", nargs="?", help="daemon log path (default stdin)")
    ap.add_argument("--ok-min", type=float, default=0.90,
                    help="starved if ratio < this (DEFAULT_ASSUMED 0.90)")
    ap.add_argument("--ok-min-src", default="DEFAULT_ASSUMED")
    ap.add_argument("--any-starved", action="store_true",
                    help="rc=2 if ANY established starved interval (default: last)")
    ap.add_argument("--min-established", type=int, default=1)
    args = ap.parse_args()

    if args.log:
        with open(args.log, "r", errors="replace") as f:
            lines = f.readlines()
        log_src = args.log
    else:
        lines = sys.stdin.readlines()
        log_src = "stdin"

    hits: List[Hit] = []
    prev = None
    for i, line in enumerate(lines, 1):
        h, prev = parse_line(line, i, prev, args.ok_min)
        if h is not None:
            hits.append(h)

    established = [h for h in hits if h.cls in ("ok", "starved") and h.ratio is not None]
    starved = [h for h in established if h.cls == "starved"]
    ok_hits = [h for h in established if h.cls == "ok"]

    print(f"score_supply_ratio log_src={log_src} tag=caller_supplied")
    print(f"ok_min={args.ok_min:.3f} ok_min_src={args.ok_min_src}")
    print(f"n_media_hits={len(hits)} n_established={len(established)} "
          f"n_starved={len(starved)} n_ok={len(ok_hits)} tag=measured")

    if len(established) < args.min_established:
        print("VERDICT=NO-DATA reason=no_established_interval tag=NO-DATA")
        print("NOTE rc=77 is never a pass")
        return 77

    last = established[-1]
    print(f"last_ratio={last.ratio:.6f} last_class={last.cls} "
          f"last_kind={last.kind} last_line={last.line_no} tag={last.kind}")
    if starved:
        s = starved[-1]
        print(f"last_starved_ratio={s.ratio:.6f} line={s.line_no} tag={s.kind}")

    if args.any_starved and starved:
        print("VERDICT=STARVED scope=any_interval tag=measured")
        return 2
    if last.cls == "starved":
        print("VERDICT=STARVED scope=last_interval tag=measured")
        return 2
    print("VERDICT=OK scope=last_interval tag=measured")
    return 0


if __name__ == "__main__":
    rc = main()
    # Caller must capture:  cmd; echo "true rc=$?"
    sys.exit(rc)
