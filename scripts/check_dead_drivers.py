#!/usr/bin/env python3
"""Gate: dead driver / dangling logic detector.

Parses Quartus compile.log (Warning 10036: "assigned but never read")
and Plex.map.rpt (Port Connectivity: "dangling logic") to find signals
that are driven but consumed by nothing in the PRODUCT build.

This catches:
  - want_y_s2 class: explicitly warned by Quartus as "assigned but never read"
  - dangling output ports: Quartus reports "connected to dangling logic"

Coverage gap (documented):
  - fs_swap class: signal IS syntactically connected but dead inside an ifdef
    branch. Quartus silently optimizes these away without warning. Detecting
    this requires source-level ifdef analysis with product macros — future work,
    reusable from define-parity's macro extraction.

Unlike module-instantiation (which catches entire missing modules), this
catches individual signals and ports that are dead within instantiated
modules — a finer-grained failure that is ALSO configuration-dependent.

Evaluates the configuration that actually ships because it reads Quartus
output produced under the product macro set (DDR_FRAME_STORE=1 per Plex.qsf:82).

Exit codes:
  0 = PASS — no new dead drivers beyond the known set
  1 = REJECTED — new dead driver(s) found
  4 = REFUSE — compile log or map report not available
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KNOWN_DEAD_PATH = ROOT / "tests" / "fixtures" / "dead_driver_known.json"

# Only report warnings from owned RTL, not from sys/ or vendor IP
OWNED_PATHS = {'Plex.sv', 'rtl/', 'emu/'}
VENDOR_PATHS = {'sys/', 'pll/', 'altera', 'cyclonev', 'arriav'}


def is_owned_file(filepath: str) -> bool:
    """Is this file in owned RTL (not vendor/sys)?"""
    fl = filepath.lower()
    if any(v in fl for v in VENDOR_PATHS):
        return False
    # Match bare filenames (Plex.sv) and paths with owned prefixes
    if fl.endswith('.sv') or fl.endswith('.v'):
        if any(v in fl for v in VENDOR_PATHS):
            return False
        return True
    if any(o in fl for o in OWNED_PATHS):
        return True
    return False


def parse_10036_warnings(compile_log: Path) -> list[dict]:
    """Parse Warning 10036: object assigned but never read."""
    findings = []
    pattern = re.compile(
        r'Warning \(10036\):.*?at (\S+)\((\d+)\): object "(\w+)" assigned a value but never read'
    )
    for line in compile_log.read_text(errors='replace').splitlines():
        m = pattern.search(line)
        if m:
            filepath, lineno, signal = m.group(1), m.group(2), m.group(3)
            if is_owned_file(filepath):
                findings.append({
                    "type": "10036_never_read",
                    "file": filepath,
                    "line": int(lineno),
                    "signal": signal,
                    "key": f"{filepath}:{lineno}:{signal}",
                    "detail": f"{signal} assigned but never read at {filepath}:{lineno}",
                })
    return findings


def parse_dangling_ports(map_rpt: Path) -> list[dict]:
    """Parse Port Connectivity 'dangling logic' entries on owned modules."""
    findings = []
    current_entity = ""

    for line in map_rpt.read_text(errors='replace').splitlines():
        # Track which entity's port connectivity we're in
        entity_match = re.search(r'Port Connectivity Checks: "([^"]+)"', line)
        if entity_match:
            current_entity = entity_match.group(1)
            continue

        if 'dangling logic' in line.lower() and current_entity:
            # Only report for owned RTL entities
            entity_parts = current_entity.split('|')
            # Check if any part matches owned modules
            owned_entity = any(
                part.split(':')[0] in (
                    'emu', 'present_core', 'stream_path', 'decode_stub',
                    'ddr_frame_store', 'ddr_bus_arbiter', 'ddr_bitstream_reader',
                    'slice_hdr_parser', 'sps_parser', 'pps_parser',
                    'nalu_scanner', 'stream_ingest', 'audio_ingest',
                    'audio_fifo', 'colorbars', 'frame_ingest',
                )
                for part in entity_parts
            )
            if not owned_entity:
                continue

            # Extract port name
            port_match = re.match(r';\s*(\S+)\s*;\s*Output\s*;\s*Info\s*;.*dangling', line)
            if port_match:
                port = port_match.group(1)
                findings.append({
                    "type": "dangling_output",
                    "entity": current_entity,
                    "port": port,
                    "key": f"{current_entity}|{port}",
                    "detail": f"Output {port} on {current_entity.split('|')[-1]} connected to dangling logic (removed by fitter)",
                })

    return findings


def main() -> int:
    import argparse, os
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compile-log", type=Path, default=None)
    parser.add_argument("--map-rpt", type=Path, default=None)
    parser.add_argument("--known-findings", type=Path, default=KNOWN_DEAD_PATH)
    args = parser.parse_args()

    compile_log = args.compile_log or (Path(os.environ["COMPILE_LOG"]) if os.environ.get("COMPILE_LOG") else None)
    map_rpt = args.map_rpt or (Path(os.environ["MAP_RPT"]) if os.environ.get("MAP_RPT") else None)

    # If explicit paths given, verify they exist
    if args.compile_log and not args.compile_log.exists():
        print(f"REFUSE: specified compile-log not found: {args.compile_log}", file=sys.stderr)
        return 4
    if args.map_rpt and not args.map_rpt.exists():
        print(f"REFUSE: specified map-rpt not found: {args.map_rpt}", file=sys.stderr)
        return 4

    # Try defaults only when no explicit path given
    if not compile_log:
        for candidate in [
            ROOT / "fpga/Plex_MiSTer/remote_out/slot11/compile.log",
            ROOT / "fpga/Plex_MiSTer/remote_out/slot12/compile.log",
        ]:
            if candidate.exists():
                compile_log = candidate
                break
    if not map_rpt:
        for candidate in [
            ROOT / "fpga/Plex_MiSTer/remote_out/slot11/Plex.map.rpt",
            ROOT / "fpga/Plex_MiSTer/remote_out/slot12/Plex.map.rpt",
        ]:
            if candidate.exists():
                map_rpt = candidate
                break

    if (not compile_log or not compile_log.exists()) and (not map_rpt or not map_rpt.exists()):
        print("REFUSE: no compile.log or map report available.", file=sys.stderr)
        return 4

    # Gather findings
    findings = []
    if compile_log and compile_log.exists():
        findings.extend(parse_10036_warnings(compile_log))
    if map_rpt and map_rpt.exists():
        findings.extend(parse_dangling_ports(map_rpt))

    # Load known findings
    known_keys: dict[str, str] = {}  # key -> owner/reason
    if args.known_findings and args.known_findings.exists():
        try:
            kf = json.loads(args.known_findings.read_text())
            known_keys = {e["key"]: e.get("owner", "unassigned") for e in kf.get("findings", [])}
        except (json.JSONDecodeError, KeyError):
            pass

    known = [f for f in findings if f["key"] in known_keys]
    new_findings = [f for f in findings if f["key"] not in known_keys]

    print(f"Dead driver scan: {len(findings)} finding(s) "
          f"({len(new_findings)} new, {len(known)} known)")

    if known:
        print(f"\nKNOWN ({len(known)}) — tracked, not blocking:")
        # Group by file for readability
        by_type = {}
        for f in known:
            by_type.setdefault(f["type"], []).append(f)
        for ftype, items in sorted(by_type.items()):
            print(f"  [{ftype}] {len(items)} finding(s)")

    if new_findings:
        print(f"\nNEW FINDINGS ({len(new_findings)}):")
        for f in sorted(new_findings, key=lambda x: x["key"]):
            print(f"  {f['detail']}")
        print(f"\nREJECTED: {len(new_findings)} new dead driver(s)")
        return 1

    if not findings:
        print("PASS: no dead drivers detected")
    else:
        print(f"\nPASS: {len(known)} known finding(s), 0 new")
    return 0


if __name__ == "__main__":
    sys.exit(main())
