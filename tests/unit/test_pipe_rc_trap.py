#!/usr/bin/env python3
"""Static lint: never capture a pipeline's exit status as the left command's rc.

The parent has been bitten three separate times by:

    cmd | tail
    echo "true rc=$?"     # <- this is tail's status, not cmd's

A FAILING gate then reports true rc=0. This scanner flags shell scripts under
scripts/, tests/unit/, tests/hw/ that assign $? on the same line as a `|` or
on the immediately following line after a pipeline, without PIPESTATUS.

Allowlist entries must be rare and justified in ALLOWLIST below.
Exit 0 = clean. Exit 1 = traps found.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCAN_DIRS = (
    ROOT / "scripts",
    ROOT / "tests" / "unit",
    ROOT / "tests" / "hw",
)

# path::lineno patterns that are reviewed false positives.
ALLOWLIST: set[str] = {
    # recover helpers: `fn || return $?` — $? is the function's status, not a pipe.
    # (no entries yet — add as path:line)
}

# Same-line: something | something ; rc=$?
SAME_LINE = re.compile(
    r"""
    (?<!\|)              # not ||
    \|
    (?!\|)               # not ||
    [^#\n]*?
    (?:;
       |\s+&&\s+
       |\s+\|\|\s+
    )
    [^#\n]*?
    (?:
        \brc\s*=\s*\$\?
      | \bstatus\s*=\s*\$\?
      | \btrue\s+rc=\$\?
      | echo\s+["'][^"']*\$\?
      | return\s+\$\?
    )
    """,
    re.X,
)

# Next-line after a pipeline ending line: rc=$?
NEXT_LINE_ASSIGN = re.compile(
    r"""^\s*(?:
        \w+\s*=\s*\$\?
      | echo\s+.*\$\?
    )""",
    re.X,
)

PIPE_LINE = re.compile(r"(?<!\|)\|(?!\|)")


def iter_shell_files() -> list[Path]:
    out: list[Path] = []
    for d in SCAN_DIRS:
        if not d.is_dir():
            continue
        for p in sorted(d.rglob("*")):
            if not p.is_file():
                continue
            if p.suffix in {".sh", ".bash"} or p.name.endswith(".sh"):
                out.append(p)
    return out


def scan_file(path: Path) -> list[str]:
    rel = path.relative_to(ROOT).as_posix()
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError as exc:
        return [f"{rel}: read error: {exc}"]
    lines = text.splitlines()
    hits: list[str] = []
    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        key = f"{rel}:{i+1}"
        if key in ALLOWLIST:
            continue
        # Ignore pure `set -o pipefail` / comments about pipes.
        if "pipefail" in stripped or "PIPESTATUS" in stripped:
            continue
        if SAME_LINE.search(line):
            # `cmd | tee log; rc=${PIPESTATUS[0]}` is OK — already excluded by PIPESTATUS check above if present
            if "PIPESTATUS" in line:
                continue
            hits.append(
                f"{key}: pipeline status captured on same line (use PIPESTATUS[0] or temp file): {stripped[:140]}"
            )
            continue
        if PIPE_LINE.search(line) and not line.rstrip().endswith("\\"):
            # Look at next non-empty non-comment line
            j = i + 1
            while j < len(lines) and (not lines[j].strip() or lines[j].strip().startswith("#")):
                j += 1
            if j < len(lines) and NEXT_LINE_ASSIGN.match(lines[j]):
                if "PIPESTATUS" in lines[j]:
                    continue
                key2 = f"{rel}:{j+1}"
                if key2 in ALLOWLIST:
                    continue
                hits.append(
                    f"{key2}: $? after pipeline on prior line {i+1} "
                    f"(captures rightmost stage, not the gate): {lines[j].strip()[:120]}"
                )
    return hits


def main() -> int:
    files = iter_shell_files()
    if not files:
        print("FAIL test_pipe_rc_trap: no shell scripts discovered", file=sys.stderr)
        return 2
    errors: list[str] = []
    for p in files:
        errors.extend(scan_file(p))
    print(f"pipe_rc_trap: scanned {len(files)} shell scripts")
    if errors:
        print("FAIL test_pipe_rc_trap: pipeline rc traps:", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        print(
            "Fix: capture with `set +e; out=$(cmd); rc=$?; set -e` "
            "or `cmd | tee log; rc=${PIPESTATUS[0]}`. Never `cmd | tail; echo rc=$?`.",
            file=sys.stderr,
        )
        return 1
    print("PASS test_pipe_rc_trap: no pipeline-$? traps in scripts/tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
