#!/usr/bin/env python3
"""Detect shell gates whose pipeline status can be hidden by tail/head/grep/tee."""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCAN_ROOTS = ("scripts", "tests")
DANGEROUS_PIPE_RE = re.compile(r"\|\s*(tail|head|grep|tee)\b")
PIPEFAIL_RE = re.compile(r"^\s*set\s+(?:-[A-Za-z]*o?\s*)?[^#\n]*\bpipefail\b|^\s*set\s+-o\s+pipefail\b", re.M)


def fail(msg: str) -> None:
    print(f"PIPE_EXIT_SAFETY_FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def tracked_files() -> list[Path]:
    try:
        out = subprocess.check_output(
            ["git", "ls-files", "--", *SCAN_ROOTS],
            cwd=ROOT,
            text=True,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        fail(f"could not enumerate tracked test/script files: {exc}")
    return [ROOT / line for line in out.splitlines()]


def is_shell(path: Path, text: str) -> bool:
    return path.suffix == ".sh" or text.startswith("#!/usr/bin/env bash") or text.startswith("#!/bin/bash")


def strip_comments(text: str) -> str:
    out: list[str] = []
    for line in text.splitlines(keepends=True):
        stripped = line.lstrip()
        if stripped.startswith("#") and not stripped.startswith("#!"):
            out.append("\n" if line.endswith("\n") else "")
        else:
            out.append(line)
    return "".join(out)


def main() -> int:
    offenders: list[str] = []
    pipe_files = 0
    pipe_sites = 0
    for path in tracked_files():
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if not is_shell(path, text):
            continue
        active = strip_comments(text)
        matches = list(DANGEROUS_PIPE_RE.finditer(active))
        if not matches:
            continue
        pipe_files += 1
        pipe_sites += len(matches)
        if not PIPEFAIL_RE.search(active):
            rel = path.relative_to(ROOT)
            ops = ",".join(sorted({m.group(1) for m in matches}))
            offenders.append(f"{rel} ops={ops} sites={len(matches)}")

    if offenders:
        for offender in offenders:
            print(f"PIPE_WITHOUT_PIPEFAIL {offender}", file=sys.stderr)
        fail("shell files with tail/head/grep/tee pipelines must enable pipefail")

    print(f"PIPE_EXIT_SAFETY_OK files_with_pipes={pipe_files} pipe_sites={pipe_sites}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
