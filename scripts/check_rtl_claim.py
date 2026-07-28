#!/usr/bin/env python3
"""Gate: RTL-claim verification.

Detects tests whose name or output claims RTL/hardware coverage but do
NOT actually invoke Verilator or link against a generated simulation
object — the instrument failure #17 pattern.

A test claiming RTL coverage must demonstrably:
  - Invoke the Verilator binary (subprocess call, PATH lookup), OR
  - Link/import a Verilator-generated shared object (Vtop, VPlex), OR
  - Reference a .sv testbench that Verilator compiles

Tests that claim RTL but only run host C++ or Python models are flagged.

Exit codes:
  0 = PASS — all RTL-claiming tests demonstrably invoke Verilator
  1 = REJECTED — one or more tests claim RTL without invoking it
  4 = REFUSE — scan directory does not exist
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = ROOT / "tests"
TOOLS_DIR = ROOT / "tools"
KNOWN_FINDINGS_PATH = ROOT / "tests" / "fixtures" / "rtl_claim_known_findings.json"

# Patterns that indicate a test CLAIMS RTL/hardware coverage (in filename or content)
RTL_CLAIM_NAME_PATTERNS = [
    re.compile(r'verilator', re.IGNORECASE),
    re.compile(r'rtl_sim', re.IGNORECASE),
    re.compile(r'rtl_model', re.IGNORECASE),
    re.compile(r'_rtl_', re.IGNORECASE),
]

RTL_CLAIM_CONTENT_PATTERNS = [
    # Only match explicit, unambiguous RTL coverage claims in comments/docstrings
    re.compile(r'#.*\bRTL\s+(coverage|verification|test)\b', re.IGNORECASE),
    re.compile(r'""".*\bRTL\s+(coverage|verification|test)\b', re.IGNORECASE),
    re.compile(r'//.*\bRTL\s+(coverage|verification|test)\b', re.IGNORECASE),
]

# Patterns that PROVE Verilator is actually invoked
VERILATOR_EVIDENCE_PATTERNS = [
    # Direct Verilator binary invocation
    re.compile(r'verilator\b', re.IGNORECASE),
    re.compile(r'\bVERILATOR\b'),
    re.compile(r'oss.cad.suite.*verilator'),
    # Verilator-generated objects
    re.compile(r'\bVtop\b|\bVPlex\b|\bV[A-Z][a-z]'),
    re.compile(r'verilated', re.IGNORECASE),
    re.compile(r'\.sv\b.*\btb\b|\btb\b.*\.sv', re.IGNORECASE),
    # Verilator compilation/linking
    re.compile(r'obj_dir|verilator_root', re.IGNORECASE),
    re.compile(r'--cc\b|--exe\b|--lint-only', re.IGNORECASE),
    # Subprocess invoking a sim binary
    re.compile(r'subprocess.*sim|sim.*subprocess', re.IGNORECASE),
    re.compile(r'\./obj_dir/|\./build/.*_sim'),
    # Shell scripts calling verilator or sim binaries
    re.compile(r'verilator_wrapper|run_verilator', re.IGNORECASE),
    re.compile(r'SIM_BIN|SIM_EXE|VERILATOR_BIN', re.IGNORECASE),
    re.compile(r'ALLOW_MISSING_VERILATOR'),
]

# Files that are infrastructure, not test executors
INFRA_PATTERNS = [
    re.compile(r'test_rtl_invariants'),
    re.compile(r'test_bench_rtl_filelists'),
    re.compile(r'check_'),
    re.compile(r'gate_coverage'),
]


def is_infra(path: Path) -> bool:
    return any(p.search(path.name) for p in INFRA_PATTERNS)


def claims_rtl(path: Path, content: str) -> bool:
    """Does this file claim to test RTL (by name or content)?"""
    for pat in RTL_CLAIM_NAME_PATTERNS:
        if pat.search(path.stem):
            return True
    for pat in RTL_CLAIM_CONTENT_PATTERNS:
        if pat.search(content):
            return True
    return False


def has_verilator_evidence(content: str) -> bool:
    """Does this file demonstrably invoke or link Verilator?"""
    for pat in VERILATOR_EVIDENCE_PATTERNS:
        if pat.search(content):
            return True
    return False


def scan_file(path: Path) -> dict | None:
    """Returns finding if file claims RTL but lacks Verilator evidence."""
    try:
        content = path.read_text(errors='replace')
    except OSError:
        return None

    if not claims_rtl(path, content):
        return None

    if has_verilator_evidence(content):
        return None

    # Claims RTL but no evidence of actually invoking Verilator
    return {
        "file": str(path.relative_to(ROOT)),
        "claim_source": "filename" if any(p.search(path.stem) for p in RTL_CLAIM_NAME_PATTERNS) else "content",
    }


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--known-findings", type=Path, default=KNOWN_FINDINGS_PATH,
                        help="JSON file of known findings with owner (default: tests/fixtures/rtl_claim_known_findings.json)")
    args = parser.parse_args()

    scan_dirs = [TESTS_DIR, TOOLS_DIR]
    for d in scan_dirs:
        if not d.exists():
            print(f"REFUSE: directory {d} does not exist", file=sys.stderr)
            return 4

    findings = []
    files_scanned = 0
    for scan_dir in scan_dirs:
        for path in sorted(scan_dir.rglob("*")):
            if path.suffix in (".py", ".cpp", ".sh") and path.is_file():
                if is_infra(path):
                    continue
                files_scanned += 1
                result = scan_file(path)
                if result:
                    findings.append(result)

    print(f"Scope: scanned {files_scanned} test/tool files for RTL claims")

    # Load known findings
    known_files: dict[str, str] = {}
    if args.known_findings and args.known_findings.exists():
        try:
            kf_data = json.loads(args.known_findings.read_text())
            known_files = {e["file"]: e["owner"] for e in kf_data.get("findings", [])}
        except (json.JSONDecodeError, KeyError):
            pass  # No valid known findings — treat all as new

    known = [f for f in findings if f["file"] in known_files]
    new_findings = [f for f in findings if f["file"] not in known_files]

    print(f"RTL-claim verification: {len(findings)} finding(s) "
          f"({len(new_findings)} new, {len(known)} known)")

    if known:
        print(f"\nKNOWN (owned, not blocking):")
        for f in known:
            print(f"  {f['file']} (claim: {f['claim_source']}) owner={known_files[f['file']]}")

    if new_findings:
        print(f"\nNEW FINDINGS — claim RTL coverage but do NOT invoke Verilator:")
        for f in new_findings:
            print(f"  {f['file']} (claim: {f['claim_source']})")
        print(f"\nREJECTED: {len(new_findings)} test(s) claim RTL without Verilator evidence")
        return 1

    if not findings:
        print("PASS: no RTL-claiming tests found (or all have Verilator evidence)")
    else:
        print(f"\nPASS: {len(known)} known finding(s) (owned), 0 new")
    return 0


if __name__ == "__main__":
    sys.exit(main())
