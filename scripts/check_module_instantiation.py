#!/usr/bin/env python3
"""Gate: module instantiation coverage.

Every RTL module in files.qip that declares a `module` keyword MUST appear
in the Quartus product map report hierarchy. If it does not, this gate goes
RED unless the module is explicitly acknowledged in the known-findings file
with an owner and reason.

This is the gate that catches instrument failure #19: verified modules
connected to nothing. It goes RED by default on any module absent from
the product — acknowledgement is opt-in, not opt-out.

The two modules that define #19:
  h264_intra4x4_pred   — h264_intra_pred.sv:7, tested, instantiated nowhere
  h264_intra16x16_pred — h264_intra_pred.sv:145, tested, instantiated nowhere

Exit codes:
  0 = PASS — all non-product modules acknowledged in known-findings
  1 = REJECTED — module(s) absent from product AND not acknowledged
  4 = REFUSE — map report not available
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RTL_DIR = ROOT / "fpga" / "Plex_MiSTer" / "rtl"
QIP_PATH = ROOT / "fpga" / "Plex_MiSTer" / "files.qip"
KNOWN_PATH = ROOT / "tests" / "fixtures" / "module_instantiation_known.json"


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


def get_qip_files() -> list[str]:
    """Return list of .sv files referenced in files.qip."""
    files = []
    if not QIP_PATH.exists():
        return files
    for line in QIP_PATH.read_text().splitlines():
        m = re.match(r'set_global_assignment\s+-name\s+SYSTEMVERILOG_FILE\s+(.+)', line)
        if m:
            files.append(m.group(1).strip())
    return files


def get_rtl_modules_from_qip() -> dict[str, str]:
    """Return {module_name: source_file} for modules in files.qip .sv files."""
    modules = {}
    qip_files = get_qip_files()
    project_dir = ROOT / "fpga" / "Plex_MiSTer"
    for rel_path in qip_files:
        sv_path = project_dir / rel_path
        if not sv_path.exists():
            continue
        content = sv_path.read_text(errors='replace')
        for m in re.findall(r'^\s*module\s+(\w+)', content, re.MULTILINE):
            modules[m.lower()] = str(sv_path.relative_to(ROOT))
    return modules


def main() -> int:
    import argparse, os
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--map-rpt", type=Path, default=None,
                        help="Path to Plex.map.rpt")
    parser.add_argument("--known-findings", type=Path, default=KNOWN_PATH,
                        help="JSON file of known non-product modules with owner/reason")
    parser.add_argument("--no-known", action="store_true",
                        help="Ignore known-findings file (shows raw RED state)")
    args = parser.parse_args()

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

    # Get modules from files.qip (what Quartus compiles)
    rtl_modules = get_rtl_modules_from_qip()
    if not rtl_modules:
        # Fallback to RTL_DIR scan
        rtl_modules = get_rtl_modules()

    product_modules = get_product_modules(map_rpt)

    # Every module NOT in product is a finding
    not_in_product = []
    in_product = []
    for module, source in sorted(rtl_modules.items()):
        if module in product_modules:
            in_product.append(module)
        else:
            not_in_product.append({"module": module, "source": source})

    # Load known findings (acknowledged non-product modules)
    known: dict[str, dict] = {}  # module -> {owner, reason}
    if not args.no_known and args.known_findings and args.known_findings.exists():
        try:
            kf = json.loads(args.known_findings.read_text())
            for entry in kf.get("findings", []):
                if not entry.get("owner", "").strip():
                    print(f"REJECTED: known-finding '{entry.get('module', '?')}' has empty owner",
                          file=sys.stderr)
                    return 1
                if not entry.get("reason", "").strip():
                    print(f"REJECTED: known-finding '{entry.get('module', '?')}' has empty reason",
                          file=sys.stderr)
                    return 1
                known[entry["module"].lower()] = entry
        except (json.JSONDecodeError, KeyError) as e:
            print(f"REJECTED: cannot parse known-findings: {e}", file=sys.stderr)
            return 1

    known_findings = [f for f in not_in_product if f["module"] in known]
    new_findings = [f for f in not_in_product if f["module"] not in known]

    # Report
    print(f"Scope: {len(rtl_modules)} modules from files.qip cross-referenced against "
          f"{len(product_modules)} product hierarchy entries from {map_rpt.name}")
    print(f"Module instantiation: {len(rtl_modules)} total, "
          f"{len(in_product)} in product, "
          f"{len(not_in_product)} NOT in product "
          f"({len(known_findings)} known, {len(new_findings)} NEW)")
    print()

    if in_product:
        print(f"IN PRODUCT ({len(in_product)}):")
        for m in sorted(in_product):
            print(f"  ✓ {m}")
        print()

    if known_findings:
        print(f"KNOWN — not in product, acknowledged ({len(known_findings)}):")
        for f in sorted(known_findings, key=lambda x: x["module"]):
            k = known[f["module"]]
            print(f"  ✗ {f['module']} — owner={k['owner']} reason={k['reason']}")
        print()

    if new_findings:
        print(f"NEW — not in product, NOT acknowledged ({len(new_findings)}):")
        for f in sorted(new_findings, key=lambda x: x["module"]):
            print(f"  ✗ {f['module']} ({f['source']})")
        print()
        print(f"REJECTED: {len(new_findings)} module(s) in files.qip but absent from product hierarchy")
        print("  Add to module_instantiation_known.json with owner and reason, or instantiate in product.")
        return 1

    if not not_in_product:
        print("PASS: all modules in files.qip are instantiated in the product")
    else:
        print(f"PASS: {len(known_findings)} non-product module(s) acknowledged, 0 new")
    return 0


if __name__ == "__main__":
    sys.exit(main())
