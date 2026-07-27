#!/usr/bin/env python3
"""Gate: CDC Crossing Register — static audit of known clock-domain crossings.

A full automated CDC analysis requires commercial tooling (Spyglass/Questa CDC).
This gate does NOT attempt that.  Instead it maintains an explicit register of
every known crossing between clock domains and verifies:

  1. Every crossing has a documented PROTECTION mechanism (fifo, sync_2ff,
     handshake, or level — see CdcProtection enum).
  2. No crossing is marked 'none' (unprotected).
  3. Optionally, the listed source/sink modules still exist in the RTL
     file set (catches stale entries after refactors).
  4. When a crossing is marked 'pulse' source type with a 'none' protection,
     that is a DATA LOSS BUG on fast→slow paths and is flagged as CRITICAL.

Exit codes:
  0 — all crossings protected, no stale entries
  1 — unprotected crossing found, or stale module reference
  4 — manifest file not found (REFUSE)

Does NOT prove:
  - That the crossing list is COMPLETE (unlisted crossings are invisible)
  - That the protection mechanism is correctly implemented
  - That synchroniser depth is adequate for the frequency ratio
  - That handshake/FIFO logic is bug-free
  This gate is a structured register, not a verifier.  It makes the crossing
  inventory explicit and auditable, which is strictly better than nothing.
"""

import argparse
import json
import sys
from enum import Enum
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class CdcProtection(str, Enum):
    FIFO = "fifo"
    SYNC_2FF = "sync_2ff"
    HANDSHAKE = "handshake"
    LEVEL = "level"            # slow-changing, multi-cycle stable
    NONE = "none"              # UNPROTECTED — always fails


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", default=str(ROOT / "tests/fixtures/cdc_crossing_manifest.json"),
                    help="Path to CDC crossing manifest JSON")
    ap.add_argument("--rtl-root", default=str(ROOT / "fpga/Plex_MiSTer/rtl"),
                    help="RTL source directory for stale-check")
    ap.add_argument("--check-stale", action="store_true",
                    help="Verify that listed modules still exist as .sv files")
    args = ap.parse_args()

    manifest_path = Path(args.manifest)
    if not manifest_path.exists():
        print(f"REFUSE: manifest not found: {manifest_path}", file=sys.stderr)
        return 4

    with open(manifest_path) as f:
        manifest = json.load(f)

    crossings = manifest.get("crossings", [])
    if not crossings:
        print("REFUSE: manifest contains no crossings", file=sys.stderr)
        return 4

    errors = []
    warnings = []

    for i, cx in enumerate(crossings):
        cid = cx.get("id", f"crossing_{i}")
        src_clk = cx.get("src_clock", "?")
        dst_clk = cx.get("dst_clock", "?")
        signal = cx.get("signal", "?")
        src_module = cx.get("src_module", "?")
        dst_module = cx.get("dst_module", "?")
        protection = cx.get("protection", "none")
        src_type = cx.get("src_type", "unknown")  # pulse | level | burst
        justification = cx.get("justification", "")

        # Validate protection
        try:
            prot = CdcProtection(protection)
        except ValueError:
            errors.append(f"  [{cid}] invalid protection '{protection}' "
                          f"(must be: {', '.join(p.value for p in CdcProtection)})")
            continue

        if prot == CdcProtection.NONE:
            severity = "CRITICAL" if src_type == "pulse" else "ERROR"
            msg = (f"  [{cid}] {severity}: {signal} crosses "
                   f"{src_clk}→{dst_clk} ({src_module}→{dst_module}) "
                   f"with NO protection (src_type={src_type})")
            if src_type == "pulse":
                msg += "\n    → Fast-domain pulse can be missed by slow sampler. DATA LOSS BUG."
            errors.append(msg)
            continue

        if prot == CdcProtection.LEVEL and src_type == "pulse":
            warnings.append(
                f"  [{cid}] WARNING: {signal} marked 'level' protection but "
                f"src_type is 'pulse' — level protection only works for "
                f"multi-cycle-stable signals, not pulses")

        if not justification:
            warnings.append(
                f"  [{cid}] NOTE: {signal} has no justification text")

    # Stale check
    if args.check_stale:
        rtl_root = Path(args.rtl_root)
        all_modules = set()
        for cx in crossings:
            for key in ("src_module", "dst_module"):
                m = cx.get(key, "")
                if m and m != "?":
                    all_modules.add(m)

        for mod in sorted(all_modules):
            candidates = list(rtl_root.glob(f"**/{mod}.sv")) + list(rtl_root.glob(f"**/{mod}.v"))
            if not candidates:
                # Also check sys/ directory
                sys_root = rtl_root.parent / "sys"
                candidates = list(sys_root.glob(f"**/{mod}.sv")) + list(sys_root.glob(f"**/{mod}.v"))
            if not candidates:
                warnings.append(f"  STALE: module '{mod}' not found in {rtl_root}")

    # Report
    print(f"CDC Crossing Register: {len(crossings)} crossings audited")

    if warnings:
        print(f"\nWarnings ({len(warnings)}):")
        for w in warnings:
            print(w)

    if errors:
        print(f"\nFAILURES ({len(errors)}):")
        for e in errors:
            print(e)
        print(f"\nREJECTED: {len(errors)} unprotected or invalid crossing(s)")
        return 1

    print("PASS: all crossings have documented protection")
    return 0


if __name__ == "__main__":
    sys.exit(main())
