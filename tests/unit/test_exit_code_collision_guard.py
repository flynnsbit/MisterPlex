#!/usr/bin/env python3
"""Gate: semantically opposite failure classes must not share one exit code.

Parent T1 (this session): tools/glass_template_skip.py had SKIP_FAIL and
INSTRUMENT_OR_FIXTURE_FAIL both return rc=2 — device skip vs instrument break
were indistinguishable. w-instr fixed to RC_SKIP_FAIL=2 / RC_INSTRUMENT_FAIL=3.
This guard locks that split and scans for the re-collision class.

Also requires each named failure class to emit an explicit verdict= string in
the glass tool (not exit-code-only).

Exit 0 clean, 1 findings, 2 tool broken.
"""
from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GLASS = ROOT / "tools" / "glass_template_skip.py"

# Pair names that must never share a numeric value when both assigned as RC_*.
MUST_DISTINCT_PAIRS = (
    ("RC_SKIP_FAIL", "RC_INSTRUMENT_FAIL"),
    ("RC_OK", "RC_UNSCORED"),
    ("RC_OK", "RC_SKIP_FAIL"),
    ("RC_OK", "RC_INSTRUMENT_FAIL"),
)


def parse_rc_constants(path: Path) -> dict[str, int]:
    text = path.read_text(encoding="utf-8", errors="replace")
    # RC_FOO = 2
    found: dict[str, int] = {}
    for m in re.finditer(r"^(RC_[A-Z0-9_]+)\s*=\s*(\d+)\b", text, re.M):
        found[m.group(1)] = int(m.group(2))
    # aliases: RC_FAIL = RC_SKIP_FAIL — resolve one hop
    for m in re.finditer(r"^(RC_[A-Z0-9_]+)\s*=\s*(RC_[A-Z0-9_]+)\b", text, re.M):
        alias, target = m.group(1), m.group(2)
        if target in found:
            found[alias] = found[target]
    return found


def audit_glass() -> list[str]:
    errs: list[str] = []
    if not GLASS.is_file():
        return [f"MISSING {GLASS.relative_to(ROOT)} — T1 tool not in tree"]
    rcs = parse_rc_constants(GLASS)
    for a, b in MUST_DISTINCT_PAIRS:
        if a not in rcs or b not in rcs:
            errs.append(f"glass missing constant {a} or {b} got={sorted(rcs)}")
            continue
        if rcs[a] == rcs[b]:
            errs.append(
                f"COLLISION {a}={rcs[a]} == {b}={rcs[b]} "
                f"(device skip vs instrument must differ)"
            )
    text = GLASS.read_text(encoding="utf-8", errors="replace")
    # verdict assignment for both classes
    if 'verdict, rc = "SKIP_FAIL"' not in text and 'verdict = "SKIP_FAIL"' not in text:
        if "SKIP_FAIL" not in text or "verdict" not in text:
            errs.append("glass missing explicit SKIP_FAIL verdict string path")
    if "INSTRUMENT_OR_FIXTURE_FAIL" not in text:
        errs.append("glass missing INSTRUMENT_OR_FIXTURE_FAIL verdict")
    # Self-test must assert distinctness
    if "RC_SKIP_FAIL == RC_INSTRUMENT_FAIL" not in text:
        errs.append("glass self-test lost D2 distinct-rc assertion")
    return errs


def audit_repo_shared_fail_rc() -> list[str]:
    """Heuristic: same function assigns two different verdict labels then return same literal."""
    errs: list[str] = []
    # Keep narrow: only tools that declare multiple RC_* equal to same int
    for path in sorted((ROOT / "tools").glob("*.py")):
        if path.name == "test_exit_code_collision_guard.py":
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        rcs = parse_rc_constants(path)
        if len(rcs) < 2:
            continue
        # invert
        by_val: dict[int, list[str]] = {}
        for k, v in rcs.items():
            if k in {"RC_FAIL"}:  # alias ok if points at one class
                continue
            by_val.setdefault(v, []).append(k)
        for val, names in by_val.items():
            # Allow OK-only uniqueness; flag two *FAIL* names on same code
            fails = [n for n in names if "FAIL" in n or "ERROR" in n]
            if len(fails) >= 2:
                rel = path.relative_to(ROOT).as_posix()
                errs.append(f"{rel}: FAIL-class constants share rc={val}: {fails}")
    return errs


def run_self_test() -> int:
    errors: list[str] = []
    # Synthetic collision detector
    sample = "RC_SKIP_FAIL = 2\nRC_INSTRUMENT_FAIL = 2\n"
    tmp = ROOT / ".agent-work" / "w-lint" / "_rc_coll_sample.py"
    tmp.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_text(sample)
    rcs = parse_rc_constants(tmp)
    if rcs.get("RC_SKIP_FAIL") == rcs.get("RC_INSTRUMENT_FAIL") == 2:
        print("RBG_RED_HIT synthetic shared rc=2")
    else:
        errors.append("RBG_RED_MISS")
    tmp.write_text("RC_SKIP_FAIL = 2\nRC_INSTRUMENT_FAIL = 3\n")
    rcs = parse_rc_constants(tmp)
    if rcs["RC_SKIP_FAIL"] != rcs["RC_INSTRUMENT_FAIL"]:
        print("RBG_GREEN_OK distinct 2 vs 3")
    else:
        errors.append("RBG_GREEN_FAIL")
    tmp.unlink(missing_ok=True)

    real = audit_glass()
    if real:
        errors.extend(real)
        print("RBG_REAL_GLASS_FAIL", real)
    else:
        print("RBG_REAL_GLASS_OK distinct SKIP_FAIL vs INSTRUMENT")

    if errors:
        print("SELFTEST_FAIL")
        for e in errors:
            print(e)
        return 1
    print("SELFTEST_OK exit_code_collision_guard")
    return 0


def main(argv: list[str] | None = None) -> int:
    if argv and "--self-test" in argv:
        rc = run_self_test()
        print(f"true rc={rc}")
        return rc

    findings = audit_glass() + audit_repo_shared_fail_rc()
    print("EXIT_CODE_COLLISION_BEGIN")
    print(f"findings={len(findings)}")
    for f in findings:
        print(f"FIND {f}")
    print("EXIT_CODE_COLLISION_END")
    if findings:
        print(f"EXIT_CODE_COLLISION_FAIL count={len(findings)}")
        print("true rc=1")
        return 1
    print("EXIT_CODE_COLLISION_OK")
    print("true rc=0")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
