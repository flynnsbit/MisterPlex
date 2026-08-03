#!/usr/bin/env python3
"""Post-fit guard: plex_chrome command-list RAM must survive Quartus.

c74c6863 proved the failure mode: BOOT_DEMO + list_we tied 0 ⇒ map marks
list_a[*] Stuck at GND ⇒ entity remains but Block Memory Bits=0 / M10Ks=0.
A fit whose chrome cannot hold a PLXC list is NO-DATA for the overlay bug.

Exit codes:
  0  PASS — plex_chrome present with non-trivial list RAM
  1  FAIL — missing instance, elided RAM, or stuck list_* evidence
  2  usage / bad args
  4  missing report file
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Reuse hierarchy parser (same column model as make post-fit-hierarchy).
_SCRIPTS = Path(__file__).resolve().parent
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))
from check_quartus_fit_hierarchy import HierRow, parse_hierarchy_report  # noqa: E402

# Dual bank list: 2 * MAX_CMDS(64) * 64-bit = 8192 bits. One M10K is enough
# if packed; require at least 1 M10K OR >= half a bank in block bits so a
# partial keep still fails the known elision (0/0).
DEFAULT_MIN_M10K = 1
DEFAULT_MIN_BLOCK_BITS = 4096  # one full 64x64 list

ENTITY = "plex_chrome"
HIER_HINT = "plex_chrome"
LIST_STUCK_RE = re.compile(
    r"plex_chrome[^;\n]*\|list_[ab](?:\[[^\]]*\])*.*Stuck at (?:GND|VCC)",
    re.I,
)


def find_chrome(rows: list[HierRow]) -> HierRow | None:
    cands = [
        r
        for r in rows
        if r.entity == ENTITY or HIER_HINT in r.full_hierarchy or HIER_HINT in r.hierarchy_node
    ]
    if not cands:
        return None
    return max(
        cands,
        key=lambda r: r.m10ks * 1e6 + r.block_memory_bits + r.registers + r.alms_needed,
    )


def scan_map_stuck(path: Path | None) -> list[str]:
    if not path or not path.exists():
        return []
    hits: list[str] = []
    for line in path.read_text(errors="ignore").splitlines():
        if LIST_STUCK_RE.search(line):
            hits.append(line.strip())
    return hits


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fit-rpt", type=Path, required=True, help="Plex.fit.rpt (or excerpt)")
    ap.add_argument(
        "--map-rpt",
        type=Path,
        help="Optional Plex.map.rpt — stuck list_* lines are hard FAIL",
    )
    ap.add_argument("--min-m10k", type=float, default=DEFAULT_MIN_M10K)
    ap.add_argument("--min-block-bits", type=float, default=DEFAULT_MIN_BLOCK_BITS)
    args = ap.parse_args(argv[1:])

    if not args.fit_rpt.exists():
        print(f"CHROME_ELISION_REFUSED(exit=4): missing {args.fit_rpt}", file=sys.stderr)
        return 4

    try:
        rows = parse_hierarchy_report(args.fit_rpt)
    except OSError as e:
        print(f"CHROME_ELISION_REFUSED(exit=4): {e}", file=sys.stderr)
        return 4

    chrome = find_chrome(rows)
    print("CHROME_ELISION_TABLE_BEGIN")
    print("| entity | hierarchy | ALMs | registers | block_bits | M10Ks | status |")
    print("|---|---|---:|---:|---:|---:|---|")
    if not chrome:
        print(f"| `{ENTITY}` | — | — | — | — | — | MISSING |")
    else:
        print(
            f"| `{chrome.entity}` | `{chrome.full_hierarchy}` | "
            f"{chrome.alms_needed:g} | {chrome.registers:g} | "
            f"{chrome.block_memory_bits:g} | {chrome.m10ks:g} | present |"
        )
    print("CHROME_ELISION_TABLE_END")

    errors: list[str] = []
    if not chrome:
        errors.append(
            f"{ENTITY}: missing from fitted hierarchy — chrome plane not in this RBF"
        )
    else:
        elided = (
            chrome.m10ks < args.min_m10k
            and chrome.block_memory_bits < args.min_block_bits
        )
        if elided:
            errors.append(
                f"{ENTITY}: RAM ELIDED — M10Ks={chrome.m10ks:g} (need >={args.min_m10k:g}) "
                f"and block_bits={chrome.block_memory_bits:g} (need >={args.min_block_bits:g}). "
                "Known cause: list_we tied off / BOOT_DEMO-only ⇒ Quartus drops list_a/list_b. "
                "Product PLXC write path was never live (c74c6863 NO-DATA)."
            )
        else:
            if chrome.m10ks < args.min_m10k:
                errors.append(
                    f"{ENTITY}: M10Ks={chrome.m10ks:g} < required {args.min_m10k:g} "
                    f"(block_bits={chrome.block_memory_bits:g})"
                )
            if chrome.block_memory_bits < args.min_block_bits:
                errors.append(
                    f"{ENTITY}: block_bits={chrome.block_memory_bits:g} < required "
                    f"{args.min_block_bits:g} (M10Ks={chrome.m10ks:g})"
                )

    stuck = scan_map_stuck(args.map_rpt)
    if stuck:
        errors.append(
            f"map.rpt: {len(stuck)} stuck list_a/list_b bit(s) under plex_chrome "
            "(clock_enable/data tied — RAM not writable)"
        )
        for hit in stuck[:6]:
            errors.append(f"  {hit[:160]}")

    if errors:
        print("CHROME_ELISION_REJECTED(exit=1):", file=sys.stderr)
        for err in errors:
            print(f"  {err}", file=sys.stderr)
        return 1

    print(
        f"PASS plex_chrome RAM retained: M10Ks={chrome.m10ks:g} "
        f"block_bits={chrome.block_memory_bits:g} "
        f"(mins {args.min_m10k:g}/{args.min_block_bits:g})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
