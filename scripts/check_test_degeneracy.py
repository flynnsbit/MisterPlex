#!/usr/bin/env python3
"""Gate: test degeneracy detector.

Detects tests that compare outputs against references without asserting
the reference actually CHANGED the input — the w-deblock #18 pattern.

A degenerate test compares A vs B where B == A is possible (and trivial),
producing a green result that proves nothing.  The defence is a "degeneracy
guard": an assertion that the reference/golden output differs from the
input, or that a non-zero number of elements were modified.

This gate scans test source files for:
  1. Comparison assertions (REQUIRE, assertEqual, assert, expect, etc.)
  2. Presence/absence of a degeneracy guard near those assertions.

Files with comparisons but NO degeneracy guard are flagged.  Allowlisted
files (with justification) are excluded from the reject count.

Exit codes:
  0 = PASS — all test files either have degeneracy guards or are allowlisted
  1 = REJECTED — one or more test files lack degeneracy guards
  4 = REFUSE — scan directory does not exist
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = ROOT / "tests"
ALLOWLIST_PATH = ROOT / "tests" / "fixtures" / "degeneracy_allowlist.json"

# Patterns that indicate a comparison assertion exists
COMPARISON_PATTERNS = [
    re.compile(r'\bREQUIRE\s*\(.*=='),
    re.compile(r'\bCHECK\s*\(.*=='),
    re.compile(r'\bassert.*==', re.IGNORECASE),
    re.compile(r'\bassert_array_equal\b', re.IGNORECASE),
    re.compile(r'\bnp\.array_equal\b', re.IGNORECASE),
    re.compile(r'\bassert_allclose\b', re.IGNORECASE),
    re.compile(r'\bnp\.testing\.assert', re.IGNORECASE),
    re.compile(r'\bexpect\b.*\b(eq|equal|toBe)\b', re.IGNORECASE),
    re.compile(r'\bAssertEqual\b', re.IGNORECASE),
    re.compile(r'\bmbExact\b'),
    re.compile(r'\bscorePlane\b'),
]

# Patterns that indicate a degeneracy guard IS present
DEGENERACY_GUARD_PATTERNS = [
    # Explicit degeneracy/non-trivial assertions
    re.compile(r'\b(degenerac|non.?trivial|nontrivial)\b', re.IGNORECASE),
    # Asserting something changed / differs from input
    re.compile(r'\b(assert|REQUIRE|CHECK|expect).*!=\s*(input|original|src|before)', re.IGNORECASE),
    re.compile(r'!=\s*(input|original|src|before).*\b(assert|REQUIRE|CHECK)', re.IGNORECASE),
    # Counting changes and asserting > 0
    re.compile(r'(changed|modified|filtered|differ|delta|nonzero).*>\s*0', re.IGNORECASE),
    re.compile(r'>\s*0.*(changed|modified|filtered|differ|delta|nonzero)', re.IGNORECASE),
    re.compile(r'\b(assert|REQUIRE|CHECK).*\b(count|num|n_)\w*\s*>\s*0', re.IGNORECASE),
    # Explicit "output must differ from input" patterns
    re.compile(r'(output|result|recon|filtered|decoded).*!=.*(input|original|src|raw)', re.IGNORECASE),
    re.compile(r'(input|original|src|raw).*!=.*(output|result|recon|filtered|decoded)', re.IGNORECASE),
    # "at least one" / "some must change" assertions
    re.compile(r'at.least.one.*(changed|modified|filtered|differ)', re.IGNORECASE),
    re.compile(r'(any|some)\b.*(changed|modified|filtered|differ)', re.IGNORECASE),
    # np.any / np.count_nonzero on difference
    re.compile(r'np\.(any|count_nonzero)\s*\(.*(-|diff|delta)', re.IGNORECASE),
    re.compile(r'assert.*np\.(any|sum)\s*\(', re.IGNORECASE),
    # Specific guard patterns from this codebase
    re.compile(r'samples_filtered\s*[>!]=?\s*0', re.IGNORECASE),
    re.compile(r'(expect|assert).*\bnot\b.*\bidentical\b', re.IGNORECASE),
]

# File patterns that are inherently non-degenerate (infrastructure, not signal tests)
INFRA_PATTERNS = [
    re.compile(r'test_confstr'),
    re.compile(r'test_mister_ini'),
    re.compile(r'test_no_conflict'),
    re.compile(r'test_no_private'),
    re.compile(r'test_release_rbf'),
    re.compile(r'test_resource_preflight'),
    re.compile(r'test_rtl_invariants'),
    re.compile(r'test_bench_rtl_filelists'),
    re.compile(r'test_companion_http'),
    re.compile(r'test_play_file_delivery'),
    re.compile(r'test_plex_browse'),
    re.compile(r'test_capture_rig'),
    re.compile(r'check_'),  # gate scripts themselves
]


def is_infra_file(path: Path) -> bool:
    name = path.name
    return any(p.search(name) for p in INFRA_PATTERNS)


def scan_file(path: Path) -> dict | None:
    """Returns finding dict if file has comparisons but no degeneracy guard."""
    try:
        content = path.read_text(errors='replace')
    except OSError:
        return None

    lines = content.splitlines()

    # Check if file has comparison assertions
    has_comparison = False
    comparison_lines = []
    for i, line in enumerate(lines, 1):
        for pat in COMPARISON_PATTERNS:
            if pat.search(line):
                has_comparison = True
                comparison_lines.append((i, line.strip()[:100]))
                break

    if not has_comparison:
        return None

    # Check if file has a degeneracy guard
    has_guard = False
    guard_lines = []
    for i, line in enumerate(lines, 1):
        for pat in DEGENERACY_GUARD_PATTERNS:
            if pat.search(line):
                has_guard = True
                guard_lines.append((i, line.strip()[:100]))
                break

    if has_guard:
        return None

    # File has comparisons but no degeneracy guard
    return {
        "file": str(path.relative_to(ROOT)),
        "comparison_count": len(comparison_lines),
        "first_comparison": comparison_lines[0] if comparison_lines else None,
        "has_guard": False,
    }


def run(known_findings_path: Path | None = None) -> int:
    if not TESTS_DIR.exists():
        print(f"REFUSE: test directory {TESTS_DIR} does not exist", file=sys.stderr)
        return 4

    # Load allowlist — justification is REQUIRED
    allowlist = {}
    if ALLOWLIST_PATH.exists():
        data = json.loads(ALLOWLIST_PATH.read_text())
        for e in data.get("entries", []):
            if not e.get("justification", "").strip():
                print(f"REJECTED: allowlist entry '{e.get('file', '?')}' has empty justification",
                      file=sys.stderr)
                return 1
            allowlist[e["file"]] = e["justification"]

    # Scan all test files
    test_files = []
    for ext in ('*.py', '*.cpp', '*.sh'):
        test_files.extend(TESTS_DIR.rglob(ext))
    # Also scan tools/ for scorers
    tools_dir = ROOT / "tools"
    if tools_dir.exists():
        for ext in ('*.py', '*.cpp'):
            test_files.extend(tools_dir.rglob(ext))

    findings = []
    guarded = []
    skipped_infra = []

    for path in sorted(set(test_files)):
        if is_infra_file(path):
            skipped_infra.append(str(path.relative_to(ROOT)))
            continue

        result = scan_file(path)
        if result is None:
            # Either no comparisons, or has a guard — both fine
            guarded.append(str(path.relative_to(ROOT)))
            continue
        findings.append(result)

    print(f"Scope: scanned {len(test_files)} test/tool files, "
          f"{len(guarded)} guarded, {len(skipped_infra)} infra-skipped")

    # Separate allowlisted from active
    active = []
    allowlisted_findings = []
    for f in findings:
        if f["file"] in allowlist:
            f["justification"] = allowlist[f["file"]]
            allowlisted_findings.append(f)
        else:
            active.append(f)

    # Report
    print(f"Test degeneracy scan: {len(findings)} findings "
          f"({len(active)} active, {len(allowlisted_findings)} allowlisted, "
          f"{len(skipped_infra)} infra-skipped)")
    print()

    if allowlisted_findings:
        print(f"Allowlisted ({len(allowlisted_findings)}):")
        for f in allowlisted_findings:
            print(f"  {f['file']} ({f['comparison_count']} comparisons)")
            print(f"    Justification: {f['justification']}")
        print()

    if active:
        # Load known findings if provided
        known_files: dict[str, str] = {}  # file -> owner
        if known_findings_path and known_findings_path.exists():
            kf_data = json.loads(known_findings_path.read_text())
            known_files = {e["file"]: e["owner"] for e in kf_data.get("findings", [])}

        known_active = [f for f in active if f["file"] in known_files]
        new_active = [f for f in active if f["file"] not in known_files]

        if known_active:
            print(f"KNOWN FINDINGS (owned, not blocking) ({len(known_active)}):")
            for f in known_active:
                line_no, line_text = f["first_comparison"]
                owner = known_files[f["file"]]
                print(f"  [{f['file']}:{line_no}] owner={owner}, {f['comparison_count']} comparison(s)")
            print()

        if new_active:
            print(f"NEW FINDINGS — tests with comparisons but NO degeneracy guard ({len(new_active)}):")
            for f in new_active:
                line_no, line_text = f["first_comparison"]
                print(f"  [{f['file']}:{line_no}] {f['comparison_count']} comparison(s), no guard")
                print(f"    First: {line_text}")
            print()
            print(f"REJECTED: {len(new_active)} NEW test(s) lack degeneracy guards")
            print("  Add an assertion that the reference/golden output differs from input,")
            print("  or allowlist with justification in tests/fixtures/degeneracy_allowlist.json")
            return 1
        else:
            print(f"PASS: {len(known_active)} known finding(s) (owned), 0 new")
            return 0
        return 1

    print("PASS: all test files with comparisons either have degeneracy guards or are allowlisted")
    return 0


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--known-findings", type=Path, default=None,
                        help="JSON file of known active findings with owner. "
                             "Known findings are reported but do not fail the gate. "
                             "NEW findings (not in the file) still fail.")
    args = parser.parse_args()
    return run(known_findings_path=args.known_findings)


if __name__ == "__main__":
    sys.exit(main())
