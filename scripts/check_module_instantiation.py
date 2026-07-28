#!/usr/bin/env python3
"""Gate: module instantiation coverage.

Detects RTL modules that exist in the source tree but are instantiated
NEITHER in the product hierarchy (Quartus map report) NOR declared as
bench-only. This is the instrument failure #19 pattern: verified modules
that are connected to nothing.

A module that exists, is tested, and is instantiated nowhere is a known
failure mode of this project — the entire intra prediction subsystem was
in this state for the life of the project.

Each module must be either:
  - PRODUCT: present in the Quartus map report synthesis hierarchy
  - BENCH_ONLY: explicitly declared as bench/testbench/simulation-only
  - PENDING: tracked with owner, waiting for datapath integration

Exit codes:
  0 = PASS — all modules accounted for
  1 = REJECTED — unaccounted module(s) found
  4 = REFUSE — map report or manifest not available
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RTL_DIR = ROOT / "fpga" / "Plex_MiSTer" / "rtl"
MANIFEST_PATH = ROOT / "tests" / "fixtures" / "module_instantiation_manifest.json"


def get_rtl_modules() -> dict[str, str]:
    """Return {module_name: source_file} for all modules declared in RTL dir."""
    modules = {}
    for f in sorted(RTL_DIR.glob("*.sv")):
        content = f.read_text(errors='replace')
        for m in re.findall(r'^\s*module\s+(\w+)', content, re.MULTILINE):
            modules[m.lower()] = str(f.relative_to(ROOT))
    return modules


def get_product_modules(map_rpt: Path) -> set[str]:
    """Extract entity names from Quartus map report."""
    modules = set()
    in_section = False
    separator_count = 0

    for line in map_rpt.read_text(errors='replace').splitlines():
        if 'Analysis & Synthesis Resource Utilization by Entity' in line and ';' in line:
            in_section = True
            separator_count = 0
            continue
        if not in_section:
            continue
        if line.startswith('+--'):
            separator_count += 1
            if separator_count >= 3:
                break
            continue
        if separator_count < 2:
            continue
        if not line.startswith(';'):
            continue
        cols = [c.strip() for c in line.split(';')]
        if len(cols) >= 4:
            entity_name = cols[-3].strip()
            if entity_name and entity_name not in ('Entity Name', ''):
                modules.add(entity_name.lower())

    return modules


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--map-rpt", type=Path, default=None,
                        help="Path to Plex.map.rpt")
    args = parser.parse_args()

    import os
    map_rpt = args.map_rpt or (Path(os.environ["MAP_RPT"]) if os.environ.get("MAP_RPT") else None)

    # Try default locations
    if not map_rpt or not map_rpt.exists():
        for candidate in [
            ROOT / "fpga/Plex_MiSTer/remote_out/slot11/Plex.map.rpt",
            ROOT / "fpga/Plex_MiSTer/remote_out/slot12/Plex.map.rpt",
        ]:
            if candidate.exists():
                map_rpt = candidate
                break

    if not map_rpt or not map_rpt.exists():
        print("REFUSE: no map report available. Set MAP_RPT= or provide --map-rpt.",
              file=sys.stderr)
        return 4

    if not MANIFEST_PATH.exists():
        print(f"REFUSE: manifest not found at {MANIFEST_PATH}", file=sys.stderr)
        return 4

    # Load manifest
    manifest = json.loads(MANIFEST_PATH.read_text())
    bench_only: dict[str, str] = {}  # module -> reason
    pending: dict[str, str] = {}  # module -> owner
    for entry in manifest.get("bench_only", []):
        if not entry.get("reason", "").strip():
            print(f"REJECTED: bench_only entry '{entry.get('module', '?')}' has empty reason",
                  file=sys.stderr)
            return 1
        bench_only[entry["module"].lower()] = entry["reason"]
    for entry in manifest.get("pending_integration", []):
        if not entry.get("owner", "").strip():
            print(f"REJECTED: pending entry '{entry.get('module', '?')}' has empty owner",
                  file=sys.stderr)
            return 1
        pending[entry["module"].lower()] = entry["owner"]

    # Get module sets
    rtl_modules = get_rtl_modules()
    product_modules = get_product_modules(map_rpt)

    # Classify each RTL module
    in_product = []
    in_bench_only = []
    in_pending = []
    unaccounted = []

    for module, source in sorted(rtl_modules.items()):
        if module in product_modules:
            in_product.append(module)
        elif module in bench_only:
            in_bench_only.append(module)
        elif module in pending:
            in_pending.append(module)
        else:
            unaccounted.append((module, source))

    # Report
    print(f"Scope: {len(rtl_modules)} RTL module declarations cross-referenced against "
          f"{len(product_modules)} product hierarchy entries from {map_rpt.name}")
    print(f"Module instantiation coverage: {len(rtl_modules)} RTL modules")
    print(f"  In product:         {len(in_product):3d}")
    print(f"  Bench-only:         {len(in_bench_only):3d}")
    print(f"  Pending (owned):    {len(in_pending):3d}")
    print(f"  UNACCOUNTED:        {len(unaccounted):3d}")
    print()

    if in_pending:
        print(f"PENDING INTEGRATION ({len(in_pending)}) — modules awaiting datapath:")
        for m in sorted(in_pending):
            print(f"  {m} — owner={pending[m]}")
        print()

    if unaccounted:
        print(f"UNACCOUNTED ({len(unaccounted)}) — not in product, not declared bench-only or pending:")
        for module, source in unaccounted:
            print(f"  {module} ({source})")
        print()
        print(f"REJECTED: {len(unaccounted)} module(s) not accounted for")
        print("  Add to module_instantiation_manifest.json as bench_only or pending_integration")
        return 1

    print("PASS: all RTL modules accounted for (product, bench-only, or pending)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
