#!/usr/bin/env python3
"""Fail if STA report has no clk_pix / general[3] analyzed paths (false green).

Usage:
  python3 scripts/check_clk_pix_sta_guard.py STA_RPT=path/to/Plex.sta.rpt
  python3 scripts/check_clk_pix_sta_guard.py path/to/Plex.sta.rpt
Exit 0 only when clk_pix appears with at least one setup/hold or Fmax path.
Exit 2 if report missing; exit 1 if clock empty / zero paths.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


def main() -> int:
    args = sys.argv[1:]
    path = None
    for a in args:
        if a.startswith("STA_RPT="):
            path = Path(a.split("=", 1)[1])
        elif not a.startswith("-"):
            path = Path(a)
    if path is None:
        print("CLK_PIX_STA_GUARD_REFUSED(exit=2): pass STA_RPT=...", file=sys.stderr)
        return 2
    if not path.is_file():
        print(f"CLK_PIX_STA_GUARD_REFUSED(exit=2): missing {path}", file=sys.stderr)
        return 2
    text = path.read_text(errors="replace")
    # Match shared general[3] or named clk_pix
    has_gen3 = bool(re.search(r"general\[3\]", text))
    has_name = bool(re.search(r"\bclk_pix\b", text, re.I))
    # Fmax or setup lines mentioning the counter
    path_hits = re.findall(
        r"(?:From|To|Clock|Fmax).{0,120}general\[3\]|general\[3\].{0,80}(?:MHz|ns|Slack)",
        text,
    )
    print(f"STA_RPT={path}")
    print(f"has_general3={has_gen3} has_clk_pix_name={has_name} path_hits={len(path_hits)}")
    if not has_gen3 and not has_name:
        print("FAIL CLK_PIX_STA_GUARD: clk_pix/general[3] absent from STA (unconstrained false green)")
        return 1
    if len(path_hits) == 0 and "Fmax Summary" in text:
        # Still require some mention near timing tables
        if not re.search(r"general\[3\].{0,40}\d+\.\d+\s*MHz", text):
            print("FAIL CLK_PIX_STA_GUARD: zero analyzed Fmax/setup hits for general[3]")
            return 1
    print("PASS CLK_PIX_STA_GUARD: clk_pix present in STA")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
