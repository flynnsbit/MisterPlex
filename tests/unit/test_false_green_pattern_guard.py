#!/usr/bin/env python3
"""Static guard: self-asserting greens, poisoned fixtures, lab-number locks.

Parent patterns that shipped green-on-fiction this week:
  (1) av_phase_rtl_quanta.hpp pinned kParentClusterSepMsX100=11710 and unit
      asserted iabs(kSevenDispMsX100 - kParentClusterSepMsX100)==9 — tree green
      because of a number that does not exist (scrubbed on w-avsync 8a7df256).
  (2) avsync_session_latch self-test used withdrawn Q4 lab medians as gold.
  (3) Unobservable tests (failure-only log greps) — audited separately.

This scanner FAILS the suite if those classes re-enter the tree. It does not
weaken any scoring tool. Exit 0 = clean. Exit 1 = findings.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Retracted parent cluster constant (OLD-argv / instrument artifact).
PARENT_CLUSTER_DEF = re.compile(
    r"kParentClusterSepMsX100\s*=\s*11710\b"
)
# Any restored symbol definition (even non-11710) is banned; use #error guard only.
PARENT_CLUSTER_SYMBOL_DEF = re.compile(
    r"(?:constexpr|const|#define)\s+.*?kParentClusterSepMsX100\b"
)

# Withdrawn within-session Q4 capture medians (parent 2026-08 broadcast).
# Must not appear as expected values in self-tests / golden fixtures.
Q4_LAB_MEDIANS = re.compile(
    r"(?<![0-9.])(?:-293\.33|-296\.00|-292\.67|-286\.00|-171\.08|116\.89|117\.10)(?![0-9])"
)

# Self-test functions that embed Q4 numbers without an explicit synthetic label
# in the same function body are treated as poisoned fixtures.
SELF_TEST_DEF = re.compile(r"^\s*def\s+_?self_test\b", re.M)

SCAN_GLOBS = (
    "host/**/*.hpp",
    "host/**/*.h",
    "host/**/*.cpp",
    "arm/**/*.hpp",
    "arm/**/*.h",
    "arm/**/*.cpp",
    "tests/unit/**/*.cpp",
    "tests/unit/**/*.py",
    "tests/unit/**/*.hpp",
    "tests/hw/**/*.py",
    "tools/**/*.py",
    "docs/evidence/**/*.md",
)


def iter_files() -> list[Path]:
    seen: set[Path] = set()
    out: list[Path] = []
    for pat in SCAN_GLOBS:
        for p in ROOT.glob(pat):
            if not p.is_file() or p in seen:
                continue
            # Skip this guard's own documentation of banned numbers.
            if p.name == "test_false_green_pattern_guard.py":
                continue
            if p.name == "w_lint_FALSE_GREEN_HUNT.md":
                continue
            seen.add(p)
            out.append(p)
    return sorted(out)


def audit_text(path: Path, text: str) -> list[str]:
    rel = path.relative_to(ROOT).as_posix()
    errs: list[str] = []
    lines = text.splitlines()

    for i, line in enumerate(lines, 1):
        # Allow documentation of the retraction / #error guard lines.
        if "retract" in line.lower() or "DELETED" in line or "#error" in line:
            if "kParentClusterSepMsX100" in line and "=" not in line.split("kParentCluster")[0][-20:]:
                continue
        if PARENT_CLUSTER_DEF.search(line):
            errs.append(f"{rel}:{i}: POISONED_CONST kParentClusterSepMsX100=11710 reintroduced")
        elif PARENT_CLUSTER_SYMBOL_DEF.search(line) and "error" not in line.lower():
            # definition-like line restoring the symbol
            if re.search(r"kParentClusterSepMsX100\s*=", line):
                errs.append(f"{rel}:{i}: SELF_ASSERT_SYMBOL kParentClusterSepMsX100 defined (retracted)")

    # Self-test bodies: Q4 lab numbers without synthetic/caller-supplied label nearby
    if path.suffix == ".py" and SELF_TEST_DEF.search(text):
        for m in SELF_TEST_DEF.finditer(text):
            start = m.start()
            # crude function body: until next top-level def or EOF
            rest = text[start:]
            nxt = re.search(r"\n(?:def |class )", rest[1:])
            body = rest[: nxt.start() + 1] if nxt else rest
            if Q4_LAB_MEDIANS.search(body):
                # allow if body explicitly marks synthetic / not lab
                if not re.search(
                    r"synthetic|NOT lab|not a lab|caller.supplied|fixture for the classifier",
                    body,
                    re.I,
                ):
                    # line number of first bad median
                    body_lines = body.splitlines()
                    base_line = text[:start].count("\n") + 1
                    for j, bl in enumerate(body_lines):
                        if Q4_LAB_MEDIANS.search(bl):
                            errs.append(
                                f"{rel}:{base_line + j}: POISONED_FIXTURE self_test embeds "
                                f"withdrawn lab median without synthetic label: {bl.strip()[:80]}"
                            )
                            break

    # Unit tests that pin kSevenDisp to parent cluster sep (the exact burned assert)
    if path.suffix == ".cpp":
        for i, line in enumerate(lines, 1):
            if re.search(
                r"iabs\s*\(\s*kSevenDispMsX100\s*-\s*kParentClusterSepMsX100\s*\)",
                line,
            ) or re.search(
                r"iabs\s*\(\s*kParentClusterSepMsX100\s*-\s*kSevenDispMsX100\s*\)",
                line,
            ):
                errs.append(
                    f"{rel}:{i}: SELF_ASSERT_GREEN pins 7*T_disp to retracted parent cluster sep"
                )

    return errs


def main() -> int:
    errs: list[str] = []
    for p in iter_files():
        try:
            text = p.read_text(encoding="utf-8", errors="ignore")
        except OSError as exc:
            errs.append(f"{p}: read error {exc}")
            continue
        errs.extend(audit_text(p, text))

    if errs:
        print("FALSE_GREEN_PATTERN_FAIL")
        for e in errs:
            print(e)
        print(f"FALSE_GREEN_PATTERN_COUNT={len(errs)}")
        return 1

    print("FALSE_GREEN_PATTERN_OK scanned_clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
