#!/usr/bin/env python3
"""Detect shell constructs that launder a MISSING TOOL into a MEASUREMENT.

Motivating defect (W-E2E-O5, handoff §31): a probe used

    pgrep_count=$(pgrep -c misterplexd 2>/dev/null || echo 0)

`pgrep` does not exist on the MiSTer. The substitution therefore returned the
literal `0`, which was read as "zero processes running" and published as
"misterplexd is NOT running". The daemon was alive the whole time.

The general fault: a fallback literal on the failure branch of a command
substitution is indistinguishable, at the read site, from a real measurement of
that value. Absent tools must report UNMEASURABLE, never a value.

Exit contract (fleet-wide): 0 = evaluated and clean, 1 = evaluated and findings,
77 = could not evaluate.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

EXIT_CLEAN = 0
EXIT_FINDINGS = 1
EXIT_UNEVALUABLE = 77

# $( ... || echo <literal> )  /  ` ... || echo <literal> `
_SUBST_FALLBACK = re.compile(
    r"\$\([^()]*\|\|\s*echo\s+(?P<lit>[^)]*)\)"
)
# var=$(cmd) with no guard, where cmd is a tool that may be absent, is NOT
# flagged: failure yields empty string, which is falsy and usually safe.

# A numeric or boolean-ish literal is the dangerous case: it is a plausible
# measurement value. An explicit sentinel word is the correct pattern.
_SAFE_SENTINELS = re.compile(
    r"(UNMEASURABLE|UNKNOWN|ABSENT|MISSING|UNAVAILABLE|NOT_FOUND|REFUSE|N/?A)",
    re.IGNORECASE,
)


def scan_text(text: str, path: str) -> list[tuple[int, str, str]]:
    """Return (lineno, literal, source_line) for each laundering site."""
    findings: list[tuple[int, str, str]] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        for m in _SUBST_FALLBACK.finditer(line):
            lit = m.group("lit").strip().strip("\"'")
            if not lit:
                continue
            if _SAFE_SENTINELS.search(lit):
                continue  # explicit sentinel: correct pattern
            if _TERNARY.search(m.group(0)):
                continue  # `cond && echo A || echo B` is a shell ternary, not a tool fallback
            findings.append((lineno, lit, line.strip()))
    return findings


def _self_test() -> int:
    cases = [
        # (text, expect_finding, label)
        ("x=$(pgrep -c foo 2>/dev/null || echo 0)", True, "numeric-fallback"),
        ("x=$(pgrep -c foo 2>/dev/null || echo UNMEASURABLE)", False, "sentinel-ok"),
        ("x=$(cmd || echo 1)", True, "one-fallback"),
        ("x=$(cmd || echo ABSENT_UNMEASURABLE)", False, "sentinel-suffix-ok"),
        ("# x=$(cmd || echo 0)", False, "comment-ignored"),
        ("x=$(cmd)", False, "no-fallback-ok"),
        ("echo \"n=$(nproc || echo 4)\"", True, "nested-in-string"),
        ("v=$(devmem 0x30 32 || echo 0x00000000)", True, "hex-fallback"),
    ]
    failures = 0
    for text, expect, label in cases:
        got = bool(scan_text(text, "<self-test>"))
        ok = got == expect
        print(f"  {'PASS' if ok else 'FAIL'}  {label}: expect_finding={expect} got={got}")
        if not ok:
            failures += 1
    print(f"SELF_TEST: {len(cases) - failures}/{len(cases)} passed")
    return EXIT_CLEAN if failures == 0 else EXIT_FINDINGS


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", help="files or directories to scan")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return _self_test()

    if not args.paths:
        print("REFUSE: no paths given — nothing was scanned, so this is not a pass.",
              file=sys.stderr)
        return EXIT_UNEVALUABLE

    files: list[Path] = []
    for raw in args.paths:
        p = Path(raw)
        if p.is_dir():
            for ext in ("*.sh", "*.py", "*.bash"):
                files.extend(p.rglob(ext))
        elif p.is_file():
            files.append(p)
    files = [f for f in files if ".worktrees" not in f.parts]

    if not files:
        print("REFUSE: paths matched no scannable files — denominator is 0.",
              file=sys.stderr)
        return EXIT_UNEVALUABLE

    total = 0
    for f in sorted(set(files)):
        try:
            text = f.read_text(errors="replace")
        except OSError:
            continue
        for lineno, lit, src in scan_text(text, str(f)):
            total += 1
            print(f"{f}:{lineno}: laundered fallback literal '{lit}' — "
                  f"a missing tool becomes a measurement here")
            print(f"    {src}")

    print(f"TOOL_LAUNDERING: scanned {len(files)} files, {total} finding(s)")
    if total:
        print("Fix: emit an explicit sentinel (UNMEASURABLE/ABSENT), never a value.")
    return EXIT_FINDINGS if total else EXIT_CLEAN


if __name__ == "__main__":
    sys.exit(main())
