#!/usr/bin/env python3
"""Multi-life soak totals from misterplexd.frame_ledger (survives restarts).

Defect class (parent): clean daemon rc=0 mid-soak re-zeroes droppedFrames_/
presentCount_; a single-life "drops=N flat" claim is false across respawns.

Positive capability:
  sum(session_end frames/presents/drops/publish_misses/residual) across the
  ledger window, and EXPLICITLY declare process_starts / process_exits /
  restarts_spanned. Never print a SINGLE_LIFE_CLEAN claim when restarts>0.

Companion: soak_continuity_assert.py refuses single-life claims when epoch
changes. This tool is the multi-life number that still exists after refuse.

Exit codes (capture DIRECTLY: cmd; echo "true rc=$?"):
  0   REPORT_OK (single- or multi-life totals printed)
  2   NO_SESSIONS (ledger has no session_end rows — cannot form a soak number)
  77  NO-DATA (ledger missing/unreadable)
  1   usage
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

RC_OK = 0
RC_USAGE = 1
RC_NO_SESSIONS = 2
RC_NO_DATA = 77

RE_EVENT = re.compile(r"\bevent=([a-z_]+)\b")
RE_KV = re.compile(r"\b([a-z_]+)=([^\s]+)")


def parse_line(line: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
    m = RE_EVENT.search(line)
    if m:
        out["event"] = m.group(1)
    for k, v in RE_KV.findall(line):
        out[k] = v
    return out


def analyze(lines: List[str]) -> Tuple[int, str, dict]:
    starts = exits = sessions = 0
    frames = presents = drops = publish_misses = residual = 0
    exit_whys: List[str] = []
    for line in lines:
        d = parse_line(line)
        ev = d.get("event")
        if ev == "process_start":
            starts += 1
        elif ev == "process_exit":
            exits += 1
            if "why" in d:
                exit_whys.append(d["why"])
        elif ev == "session_end":
            sessions += 1
            frames += int(d.get("frames", "0") or 0)
            presents += int(d.get("presents", "0") or 0)
            drops += int(d.get("drops", "0") or 0)
            publish_misses += int(d.get("publish_misses", "0") or 0)
            residual += int(d.get("residual", "0") or 0)

    # restarts_spanned: max(0, starts-1) when we see multiple lives in the file.
    restarts = max(0, starts - 1)
    if exits > restarts:
        restarts = exits  # exit without a following start still interrupts soak

    info = {
        "process_starts": starts,
        "process_exits": exits,
        "session_ends": sessions,
        "restarts_spanned": restarts,
        "sum_frames": frames,
        "sum_presents": presents,
        "sum_drops": drops,
        "sum_publish_misses": publish_misses,
        "sum_residual": residual,
        "exit_whys": exit_whys[:8],
        "tag": "measured",
    }

    if sessions == 0:
        return (
            RC_NO_SESSIONS,
            "SOAK_LEDGER_NO_SESSIONS: no event=session_end rows — refuse soak number",
            info,
        )

    if restarts > 0:
        claim = "MULTI_LIFE"
        clean = "REFUSE_SINGLE_LIFE_CLEAN"
    else:
        claim = "SINGLE_LIFE"
        clean = "SINGLE_LIFE_OK"

    msg = (
        f"SOAK_LEDGER_OK claim={claim} {clean} "
        f"restarts_spanned={restarts} process_starts={starts} process_exits={exits} "
        f"session_ends={sessions} "
        f"sum_frames={frames} sum_presents={presents} sum_drops={drops} "
        f"sum_publish_misses={publish_misses} sum_residual={residual} tag=measured"
    )
    return RC_OK, msg, info


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--ledger",
        action="append",
        default=[],
        required=False,
        help="misterplexd.frame_ledger path (repeatable)",
    )
    args = ap.parse_args(argv)
    if not args.ledger:
        print("usage: soak_ledger_report.py --ledger PATH", file=sys.stderr)
        return RC_USAGE

    lines: List[str] = []
    any_file = False
    for p in args.ledger:
        path = Path(p)
        if not path.is_file():
            continue
        any_file = True
        try:
            lines.extend(path.read_text(errors="replace").splitlines())
        except OSError:
            continue

    if not any_file:
        print("SOAK_LEDGER_NO_DATA: ledger path missing/unreadable")
        return RC_NO_DATA

    rc, msg, info = analyze(lines)
    print(msg)
    for k, v in info.items():
        print(f"  {k}={v}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
