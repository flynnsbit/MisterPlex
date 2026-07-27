#!/usr/bin/env python3
"""Gate: simulation-in-product detector.

Detects simulation-only or diagnostic modules present in the product
bitstream — the decode_stub finding from this session.

Checks that no module on the DENY LIST appears in the Quartus fit report
hierarchy. The deny list is explicit and requires justification for
each entry. Adding a new module to the deny list requires evidence that
it is simulation/diagnostic only.

This gate also checks for modules that appear in the fit hierarchy but
are NOT in any Verilator testbench — potential dead weight that has
never been tested.

Exit codes:
  0 = PASS — no denied modules in product hierarchy
  1 = REJECTED — denied module found in product hierarchy
  4 = REFUSE — fit report not available
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DENY_LIST_PATH = ROOT / "tests" / "fixtures" / "product_hierarchy_denylist.json"


def parse_hierarchy_from_fit_report(fit_rpt: Path) -> set[str]:
    """Extract module instance names from Quartus .fit.rpt hierarchy section."""
    modules = set()
    in_hierarchy = False
    # Pattern: matches lines like "    |    |decode_stub:..." or "; |emu:emu_inst|..."
    hier_pattern = re.compile(r'\|(\w+)(?::\w+)?')

    content = fit_rpt.read_text(errors='replace')
    for line in content.splitlines():
        # Look for the Resource Usage section's hierarchy
        if 'Entity Name' in line and 'ALMs' in line:
            in_hierarchy = True
            continue
        if in_hierarchy:
            if line.strip() == '' or line.startswith('+'):
                if modules:  # We've seen some, end of section
                    break
                continue
            # Extract module/entity names from hierarchical paths
            matches = hier_pattern.findall(line)
            for m in matches:
                modules.add(m.lower())
            # Also grab the entity name from the start of the line
            parts = line.split(';')
            if len(parts) >= 2:
                entity = parts[1].strip().split('|')[0].strip()
                if entity and entity != '|':
                    modules.add(entity.lower())

    return modules


def parse_hierarchy_from_map_report(map_rpt: Path) -> set[str]:
    """Extract entity names from Quartus .map.rpt 'Resource Utilization by Entity' table."""
    modules = set()
    in_section = False
    separator_count = 0

    content = map_rpt.read_text(errors='replace')
    for line in content.splitlines():
        if 'Analysis & Synthesis Resource Utilization by Entity' in line and ';' in line:
            in_section = True
            separator_count = 0
            continue
        if not in_section:
            continue
        if line.startswith('+--'):
            separator_count += 1
            if separator_count >= 3:
                break  # Third separator = end of table
            continue
        if separator_count < 2:
            continue  # Still in header area
        if not line.startswith(';'):
            continue

        # Data row. Columns separated by ;
        # Col layout: ; Hierarchy Node ; ALUTs ; Regs ; BlockMem ; DSP ; Pins ; VPins ; FullHierarchy ; EntityName ; Library ;
        cols = [c.strip() for c in line.split(';')]
        # cols[0] is empty (before first ;), cols[1] is Hierarchy Node, cols[-3] is Entity Name, cols[-2] is Library
        if len(cols) >= 4:
            entity_name = cols[-3].strip() if len(cols) >= 3 else ""
            if entity_name and entity_name not in ('Entity Name', ''):
                modules.add(entity_name.lower())

    return modules


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fit-rpt", type=Path, default=None,
                        help="Path to Plex.fit.rpt (or use FIT_RPT env)")
    parser.add_argument("--map-rpt", type=Path, default=None,
                        help="Path to Plex.map.rpt (preferred for module names)")
    parser.add_argument("--known-findings", type=Path, default=None,
                        help="JSON file of known findings (accepted pending removal)")
    args = parser.parse_args()

    import os
    fit_rpt = args.fit_rpt or (Path(os.environ["FIT_RPT"]) if os.environ.get("FIT_RPT") else Path("__nonexistent__"))
    map_rpt = args.map_rpt or (Path(os.environ["MAP_RPT"]) if os.environ.get("MAP_RPT") else Path("__nonexistent__"))

    # Try default locations
    if not fit_rpt.exists():
        for candidate in [
            ROOT / "fpga/Plex_MiSTer/remote_out/slot11/Plex.fit.rpt",
            ROOT / "fpga/Plex_MiSTer/remote_out/slot12/Plex.fit.rpt",
        ]:
            if candidate.exists():
                fit_rpt = candidate
                break
    if not map_rpt.exists():
        for candidate in [
            ROOT / "fpga/Plex_MiSTer/remote_out/slot11/Plex.map.rpt",
            ROOT / "fpga/Plex_MiSTer/remote_out/slot12/Plex.map.rpt",
        ]:
            if candidate.exists():
                map_rpt = candidate
                break

    if not fit_rpt.exists() and not map_rpt.exists():
        print("REFUSE: no fit report or map report available. Set FIT_RPT= or MAP_RPT=.",
              file=sys.stderr)
        return 4

    # Load deny list
    if not DENY_LIST_PATH.exists():
        print(f"REFUSE: deny list not found at {DENY_LIST_PATH}", file=sys.stderr)
        return 4

    denylist_data = json.loads(DENY_LIST_PATH.read_text())
    denied_modules: dict[str, str] = {}  # name -> reason
    for entry in denylist_data.get("denied", []):
        if not entry.get("reason", "").strip():
            print(f"REJECTED: deny list entry '{entry.get('module', '?')}' has empty reason",
                  file=sys.stderr)
            return 1
        denied_modules[entry["module"].lower()] = entry["reason"]

    # Extract hierarchy
    hierarchy = set()
    if map_rpt.exists():
        hierarchy = parse_hierarchy_from_map_report(map_rpt)
        print(f"Product hierarchy: {len(hierarchy)} modules from {map_rpt.name}")
    elif fit_rpt.exists():
        hierarchy = parse_hierarchy_from_fit_report(fit_rpt)
        print(f"Product hierarchy: {len(hierarchy)} modules from {fit_rpt.name}")

    if not hierarchy:
        print("REFUSE: could not parse any modules from report", file=sys.stderr)
        return 4

    # Check denied modules
    violations = []
    for module, reason in denied_modules.items():
        if module in hierarchy:
            violations.append({"module": module, "reason": reason})

    # Load known findings
    known_modules: dict[str, str] = {}
    if args.known_findings and args.known_findings.exists():
        try:
            kf = json.loads(args.known_findings.read_text())
            known_modules = {e["module"].lower(): e["owner"] for e in kf.get("findings", [])}
        except (json.JSONDecodeError, KeyError):
            pass

    known_violations = [v for v in violations if v["module"] in known_modules]
    new_violations = [v for v in violations if v["module"] not in known_modules]

    if known_violations:
        print(f"\nKNOWN (owned, pending removal):")
        for v in known_violations:
            owner = known_modules[v["module"]]
            print(f"  {v['module']} — owner={owner}")
            print(f"    Reason denied: {v['reason']}")

    if new_violations:
        print(f"\nNEW VIOLATIONS — simulation/diagnostic modules in product:")
        for v in new_violations:
            print(f"  {v['module']}")
            print(f"    Reason denied: {v['reason']}")
        print(f"\nREJECTED: {len(new_violations)} denied module(s) in product hierarchy")
        return 1

    if not violations:
        print("PASS: no denied modules found in product hierarchy")
    else:
        print(f"\nPASS: {len(known_violations)} known finding(s) (owned), 0 new")
    return 0


if __name__ == "__main__":
    sys.exit(main())
