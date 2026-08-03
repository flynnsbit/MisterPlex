#!/usr/bin/env python3
"""Refuse stale Verilator --Mdir caches that embed foreign absolute paths.

Verilator makefiles bake absolute source paths. If an Mdir is reused after the
source root moves (git worktree, repo relocate) or is populated with paths from
another tree, incremental make dies with:

  make: *** No rule to make target '/other/tree/build/foo_main.cpp' ...

That failure is confusing and machine-dependent. This guard:
  1. Records the resolved source root in <Mdir>/.misterplex_source_root
  2. Scans existing Mdir text artifacts for absolute paths under common repo
     prefixes that are NOT under the current source root
  3. On mismatch: LOUD message + purge Mdir so the next --build is clean

Exit 0 always after preparing Mdir (purge is success). Exit 2 on bad args.
Does not invoke Verilator.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
from pathlib import Path

ABS_PATH_RE = re.compile(r"(/home/[^\s:\"'\\]+|/Users/[^\s:\"'\\]+)")
TEXT_SUFFIXES = {
    "",
    ".mk",
    ".d",
    ".dat",
    ".cmake",
    ".txt",
    ".h",
    ".cpp",
    ".sv",
    ".v",
    ".vh",
    ".makefile",
}
TEXT_NAMES = {"Makefile", "makefile", "GMakefile"}


def resolve(p: Path) -> Path:
    return p.expanduser().resolve()


def is_text_artifact(path: Path) -> bool:
    if path.name in TEXT_NAMES:
        return True
    if path.suffix in TEXT_SUFFIXES:
        return True
    # Verilator timestamp / dep files sometimes have no suffix
    if path.is_file() and path.stat().st_size < 2_000_000:
        try:
            head = path.read_bytes()[:200]
        except OSError:
            return False
        if b"\0" in head:
            return False
        return True
    return False


def collect_foreign_paths(mdir: Path, source_root: Path) -> list[str]:
    """Return absolute path strings found under mdir that are outside source_root."""
    root_s = str(source_root)
    mdir_s = str(mdir)
    foreign: list[str] = []
    seen: set[str] = set()
    if not mdir.is_dir():
        return foreign
    for path in mdir.rglob("*"):
        if not path.is_file() or not is_text_artifact(path):
            continue
        try:
            text = path.read_text(errors="ignore")
        except OSError:
            continue
        for match in ABS_PATH_RE.finditer(text):
            cand = match.group(1).rstrip("\\")
            # Trim trailing punctuation from makefile fragments
            cand = cand.rstrip("\")',")
            if cand in seen:
                continue
            # Paths inside this Mdir or current source root are fine
            if cand == root_s or cand.startswith(root_s + os.sep):
                continue
            if cand == mdir_s or cand.startswith(mdir_s + os.sep):
                continue
            # Only care about paths that look like *this* project family
            if "MisterPlex" not in cand and "misterplex" not in cand.lower():
                continue
            # Ignore toolchain / oss-cad-suite
            if "oss-cad-suite" in cand or "/verilator/" in cand:
                continue
            seen.add(cand)
            foreign.append(cand)
            if len(foreign) >= 12:
                return foreign
    return foreign


def prepare_mdir(mdir: Path, source_root: Path) -> int:
    source_root = resolve(source_root)
    mdir = Path(os.path.abspath(str(mdir)))
    stamp = mdir / ".misterplex_source_root"
    reasons: list[str] = []

    if mdir.exists() and not mdir.is_dir():
        print(f"verilator_mdir_guard: HARD FAIL mdir is not a directory: {mdir}", file=sys.stderr)
        return 2

    if stamp.is_file():
        prev = stamp.read_text(encoding="utf-8").strip()
        if prev and prev != str(source_root):
            reasons.append(f"stamp_mismatch prev={prev} current={source_root}")

    foreign = collect_foreign_paths(mdir, source_root) if mdir.is_dir() else []
    if foreign:
        reasons.append("foreign_abs_paths=" + ",".join(foreign[:5]))

    if reasons:
        print(
            "verilator_mdir_guard: MDIR_STALE — refusing confusing incremental reuse",
            file=sys.stderr,
        )
        for r in reasons:
            print(f"verilator_mdir_guard: reason: {r}", file=sys.stderr)
        print(
            f"verilator_mdir_guard: purging mdir={mdir} source_root={source_root}",
            file=sys.stderr,
        )
        shutil.rmtree(mdir)

    mdir.mkdir(parents=True, exist_ok=True)
    stamp.write_text(str(source_root) + "\n", encoding="utf-8")
    print(
        f"verilator_mdir_guard: OK mdir={mdir} source_root={source_root} "
        f"purged={'yes' if reasons else 'no'}",
        file=sys.stderr,
    )
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mdir", required=True, type=Path, help="Verilator --Mdir path")
    ap.add_argument(
        "--source-root",
        required=True,
        type=Path,
        help="Resolved repo/worktree root that owns the RTL/sources for this build",
    )
    args = ap.parse_args()
    return prepare_mdir(args.mdir, args.source_root)


if __name__ == "__main__":
    raise SystemExit(main())
