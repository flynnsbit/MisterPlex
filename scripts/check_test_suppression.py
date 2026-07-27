#!/usr/bin/env python3
"""Gate: detect suppressed test failures and env-var-gated pass-on-skip.

A test may not decide that a discrepancy does not matter.  Detecting a
difference and judging it unimportant are two separate jobs, and the second
does not belong inside the instrument.

This gate scans test and gate scripts for:
  1. ENV-VAR-GATED PASS-ON-SKIP: code paths where an environment variable
     converts a refuse/skip/error into exit 0 / return 0.
  2. JUDGEMENT WORDS NEAR SUCCESS RETURNS: comments containing "theoretical",
     "acceptable", "harmless", "not realistic", "won't happen", "safe to
     ignore", "known issue", "for now" within 5 lines of a success return.
  3. SUPPRESSED MISMATCH: code that computes a mismatch/error/violation
     count and then returns success.

Allowlisted patterns (documented and reviewed):
  Entries in the allowlist file are exempt.  The allowlist must have a
  written justification for each entry.

Exit codes:
  0 — no suppression patterns found (or all allowlisted)
  1 — suppression pattern detected
  4 — scan target not found

Does NOT prove:
  - That allowlisted entries are actually safe (only that they were reviewed)
  - That the scan is complete (regex-based, not AST-based)
  - That tolerance-based tests have correct thresholds
  - That generators reach their failure regions (requires per-test analysis)
"""

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Env vars that convert a refuse/skip into exit 0
PASS_ON_SKIP_VARS = [
    "ALLOW_MISSING_VERILATOR",
    "MISTERPLEX_ALLOW_LOW_MEMORY_TESTS",
]

# Judgement words that indicate an embedded assumption
JUDGEMENT_WORDS = re.compile(
    r"\b(theoretical|not realistic|won't happen|acceptable|harmless|"
    r"tolerable|negligible|safe to ignore|can be ignored|known issue|"
    r"expected drift|close enough|good enough)\b",
    re.IGNORECASE,
)

# Success returns
SUCCESS_RETURN = re.compile(
    r"^\s*(return\s+0|exit\s+0|sys\.exit\(0\))\s*$"
)

# Mismatch/error detection followed by success
MISMATCH_DETECT = re.compile(
    r"\b(mismatch|overflow|underflow|violation|wrong|corrupt|"
    r"discrepanc|diverge|out.of.range|exceed|saturate)\b",
    re.IGNORECASE,
)


def scan_file(path: Path) -> list[dict]:
    findings = []
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return findings

    # Use path relative to ROOT for portability
    try:
        rel_path = str(path.resolve().relative_to(ROOT))
    except ValueError:
        rel_path = str(path)

    lines = text.split("\n")

    # Pattern 1: env-var-gated pass-on-skip
    for var in PASS_ON_SKIP_VARS:
        if var in text:
            # Check if there's a path from this var to exit 0 / return 0
            for i, line in enumerate(lines):
                if var in line:
                    # Look within 10 lines for exit 0 / return 0
                    window = "\n".join(lines[i:min(i + 10, len(lines))])
                    if re.search(r"exit\s+0|return\s+0", window):
                        findings.append({
                            "file": rel_path,
                            "line": i + 1,
                            "pattern": "env_var_pass_on_skip",
                            "severity": "HIGH",
                            "var": var,
                            "detail": f"{var} converts refuse/skip to pass (exit 0)",
                        })
                        break  # One finding per var per file

    # Pattern 2: judgement words near success returns
    for i, line in enumerate(lines):
        m = JUDGEMENT_WORDS.search(line)
        if m:
            # Check if within 5 lines of a success return
            window_start = max(0, i - 5)
            window_end = min(len(lines), i + 6)
            window = "\n".join(lines[window_start:window_end])
            if re.search(r"return\s+0|exit\s+0|sys\.exit\(0\)", window):
                findings.append({
                    "file": rel_path,
                    "line": i + 1,
                    "pattern": "judgement_near_success",
                    "severity": "MEDIUM",
                    "word": m.group(1),
                    "detail": f'Judgement word "{m.group(1)}" within 5 lines of success return',
                    "context": line.strip(),
                })

    # Pattern 3: mismatch detection near success return without intervening failure
    for i, line in enumerate(lines):
        m = MISMATCH_DETECT.search(line)
        if m:
            # Look forward for return 0 without intervening return 1 / exit 1
            window = lines[i:min(i + 8, len(lines))]
            window_text = "\n".join(window)
            has_success = bool(re.search(r"return\s+0|exit\s+0", window_text))
            has_failure = bool(re.search(r"return\s+[1-9]|exit\s+[1-9]|raise|fail\(|assert", window_text))
            if has_success and not has_failure:
                # Check this isn't just a comment about what the test checks
                if not line.strip().startswith(("#", "//", "*", "print", "echo")):
                    findings.append({
                        "file": rel_path,
                        "line": i + 1,
                        "pattern": "mismatch_near_success",
                        "severity": "HIGH",
                        "word": m.group(1),
                        "detail": f'Mismatch/error "{m.group(1)}" near success return without failure path',
                        "context": line.strip(),
                    })

    return findings


def load_allowlist(path: Path) -> dict[str, str]:
    """Returns {file:line:pattern → justification}."""
    if not path.exists():
        return {}
    data = json.loads(path.read_text())
    return {
        f"{e['file']}:{e['line']}:{e['pattern']}": e.get("justification", "")
        for e in data.get("entries", [])
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scan-dirs", nargs="+",
                    default=[str(ROOT / "tests"), str(ROOT / "scripts"), str(ROOT / "tools")])
    ap.add_argument("--allowlist",
                    default=str(ROOT / "tests/fixtures/suppression_allowlist.json"))
    ap.add_argument("--write-findings",
                    help="Write raw findings to JSON for review")
    ap.add_argument("--known-findings",
                    help="JSON file of known active findings with owner. "
                         "Known findings are reported but do not fail. "
                         "NEW findings not in this file still fail.")
    args = ap.parse_args()

    allowlist = load_allowlist(Path(args.allowlist))

    all_findings = []
    for scan_dir in args.scan_dirs:
        p = Path(scan_dir)
        if not p.exists():
            print(f"REFUSE: scan target not found: {p}", file=sys.stderr)
            return 4
        for path in sorted(p.rglob("*")):
            if path.suffix in (".py", ".sh", ".cpp") and path.is_file():
                all_findings.extend(scan_file(path))

    # Deduplicate by file+line+pattern
    seen = set()
    unique = []
    for f in all_findings:
        key = f"{f['file']}:{f['line']}:{f['pattern']}"
        if key not in seen:
            seen.add(key)
            f["allowlisted"] = key in allowlist
            if f["allowlisted"]:
                f["allowlist_justification"] = allowlist[key]
            unique.append(f)

    if args.write_findings:
        out = Path(args.write_findings)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(unique, indent=2) + "\n")
        print(f"Wrote {len(unique)} findings to {out}")

    # Report
    unallowed = [f for f in unique if not f.get("allowlisted")]
    allowed = [f for f in unique if f.get("allowlisted")]

    print(f"Test suppression scan: {len(unique)} findings ({len(unallowed)} active, {len(allowed)} allowlisted)")

    if allowed:
        print(f"\nAllowlisted ({len(allowed)}):")
        for f in allowed:
            print(f"  [{f['severity']}] {f['file']}:{f['line']} — {f['detail']}")
            print(f"    Justification: {f.get('allowlist_justification', 'none')}")

    if unallowed:
        # Check for known findings
        known_keys: dict[str, str] = {}  # "file:line" -> owner
        if args.known_findings:
            kf_path = Path(args.known_findings)
            if kf_path.exists():
                kf_data = json.loads(kf_path.read_text())
                for e in kf_data.get("findings", []):
                    known_keys[e["key"]] = e["owner"]

        known = []
        new_findings = []
        for f in unallowed:
            key = f"{f['file']}:{f['line']}"
            if key in known_keys:
                f["known_owner"] = known_keys[key]
                known.append(f)
            else:
                new_findings.append(f)

        if known:
            print(f"\nKNOWN FINDINGS (owned, not blocking) ({len(known)}):")
            for f in sorted(known, key=lambda x: x["file"]):
                print(f"  [{f['severity']}] {f['file']}:{f['line']} owner={f['known_owner']}")

        if new_findings:
            print(f"\nNEW FINDINGS ({len(new_findings)}):")
            for f in sorted(new_findings, key=lambda x: (x["severity"], x["file"])):
                print(f"  [{f['severity']}] {f['file']}:{f['line']}")
                print(f"    {f['detail']}")
                if "context" in f:
                    print(f"    Context: {f['context']}")
            print(f"\nREJECTED: {len(new_findings)} NEW suppression pattern(s) found")
            return 1
        else:
            print(f"\nPASS: {len(known)} known finding(s) (owned), 0 new")
            return 0

    print("PASS: no unallowlisted suppression patterns")
    return 0


if __name__ == "__main__":
    sys.exit(main())
