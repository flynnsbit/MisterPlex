#!/usr/bin/env python3
"""Gate that a skipped test never exits 0.

A skip that exits 0 is indistinguishable from a pass in every aggregator we
have: ``make`` sees success, the skip summariser sees success, and the fleet
records a green for a gate that measured nothing.  The standing rule is that a
skip exits 77.

The check is textual and deliberately narrow: it looks for a shell ``exit 0``
that is lexically dominated by a skip announcement (a ``SKIP`` heredoc, or an
echo/printf whose text contains SKIP) within the same enclosing ``if``/``fi``
region, with no intervening successful assertion.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP_MARK = re.compile(r"\bSKIP\b")
EXIT_ZERO = re.compile(r"^\s*exit\s+0\s*(?:#.*)?$")


def shell_files(base: Path, *roots: str) -> list[Path]:
    out = subprocess.check_output(
        ["git", "ls-files", "--", *roots], cwd=base, text=True
    )
    files: list[Path] = []
    for rel in out.splitlines():
        p = base / rel
        if p.suffix == ".sh":
            files.append(p)
        elif p.suffix == "" and p.is_file():
            try:
                if p.read_text(encoding="utf-8", errors="ignore").startswith("#!"):
                    files.append(p)
            except OSError:
                pass
    return files


def scan(path: Path) -> list[tuple[int, str]]:
    """Find ``exit 0`` still inside the shell block that announced a skip.

    Attribution stops as soon as the enclosing ``if``/``case``/loop closes, so a
    script's ordinary trailing ``exit 0`` after a real assertion is not flagged.
    """
    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    hits: list[tuple[int, str]] = []
    depth = 0
    skip_line = -1
    skip_depth = -1
    for idx, line in enumerate(lines):
        stripped = line.strip()
        opens = len(re.findall(r"(?:^|;|\bthen\b|\bdo\b|\belse\b)\s*(?:if|case|while|for|until)\b", line))
        closes = len(re.findall(r"(?:^|;)\s*(?:fi|esac|done)\b", line))
        depth += opens
        if skip_line >= 0 and depth - closes < skip_depth:
            skip_line = -1
            skip_depth = -1
        depth -= closes
        if depth < 0:
            depth = 0
        if SKIP_MARK.search(line) and not stripped.startswith("#"):
            skip_line = idx
            skip_depth = depth
        if EXIT_ZERO.match(line) and skip_line >= 0:
            hits.append((idx + 1, lines[skip_line].strip()[:70]))
    return hits


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--paths", nargs="*", default=["tests", "scripts"])
    ap.add_argument("--root", default=str(ROOT), help="Repository root to scan (defaults to this checkout)")
    args = ap.parse_args(argv)
    base = Path(args.root).resolve()
    files = shell_files(base, *args.paths)
    total_exit_zero = 0
    findings: list[tuple[Path, int, str]] = []
    for path in files:
        text = path.read_text(encoding="utf-8", errors="ignore")
        total_exit_zero += sum(1 for line in text.splitlines() if EXIT_ZERO.match(line))
        for lineno, why in scan(path):
            findings.append((path, lineno, why))
    print(
        f"Scope: skip-exit-code shell_files={len(files)} exit_zero_sites={total_exit_zero} "
        f"skip_dominated_exit_zero={len(findings)} required_skip_code=77",
        flush=True,
    )
    if findings:
        for path, lineno, why in findings:
            print(
                f"SKIP_EXITS_ZERO {path.relative_to(base)}:{lineno} skip_context={why!r}",
                file=sys.stderr,
            )
        print(
            "SKIP_EXIT_CODE_FAIL a skipped gate must exit 77, never 0; "
            f"{len(findings)} site(s) report success without measuring anything",
            file=sys.stderr,
        )
        return 1
    print(f"SKIP_EXIT_CODE_OK files={len(files)} exit_zero_sites={total_exit_zero} skip_dominated=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
