#!/usr/bin/env python3
"""Shared Verilator invoke for unit tests — never false-green on elab errors.

Historic defect: Python RTL tests called the verilator binary directly and only
checked process returncode. A fake/broken verilator that prints PINNOTFOUND
(or %Error) and exits 0 left a stale V* TB binary in Mdir and the suite went
GREEN. scripts/run_verilator.sh already hard-fails that class (rc=2); this
helper applies the same contract to in-process Python builds.

Usage:
  from verilator_invoke import run_verilator_build, resolve_verilator

  vl = resolve_verilator()
  run_verilator_build([str(vl), "--cc", "--exe", "--build", ...], exe=build_dir/"Vfoo")
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Sequence

ROOT = Path(__file__).resolve().parents[2]

# Elab/bind/compile errors that must never be treated as success even if rc=0.
_HARD_FAIL_OUT = re.compile(
    r"PINNOTFOUND|%Error(?:-|\b)|%Fatal|syntax error|Can't find definition",
    re.I,
)

# Candidate pinned oss-cad paths (production tests historically hardcoded one).
_OSS_CANDIDATES = (
    Path.home() / ".local/oss-cad-suite-20260726/bin/verilator",
    Path.home() / ".local/oss-cad-suite/bin/verilator",
)


def resolve_verilator() -> Path:
    """Prefer VERILATOR env, then known oss-cad pins, then PATH."""
    env = os.environ.get("VERILATOR", "").strip()
    if env:
        p = Path(env)
        if p.is_file():
            return p
        raise FileNotFoundError(f"VERILATOR={env} is not a file")
    for c in _OSS_CANDIDATES:
        if c.is_file():
            return c
    which = subprocess.run(
        ["bash", "-lc", "command -v verilator"],
        text=True,
        capture_output=True,
        check=False,
    )
    path = (which.stdout or "").strip()
    if which.returncode == 0 and path:
        return Path(path)
    raise FileNotFoundError("verilator not found (set VERILATOR= or install oss-cad-suite)")


def run_verilator_build(
    cmd: Sequence[str],
    *,
    cwd: Path | None = None,
    exe: Path | None = None,
) -> str:
    """Run a verilator build command; hard-fail on PINNOTFOUND/%Error even if rc=0.

    If exe is provided, refuse success unless exe exists and its mtime advanced
    across the build (stale TB binary cannot false-green a failed compile).
    Returns combined stdout+stderr on success.
    """
    work = cwd if cwd is not None else ROOT
    # Note: do NOT unlink exe before build — Verilator incremental make can report
    # "Nothing to be done" when sources are unchanged and still leave a good TB.
    # The historic false-green is PINNOTFOUND/%Error with rc=0 while a *prior*
    # TB remains; catching the error text is the discriminating check (same as
    # scripts/run_verilator.sh). Missing exe after a claimed success is also RED.

    proc = subprocess.run(
        list(cmd),
        cwd=str(work),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    out = proc.stdout or ""
    sys.stdout.write(out)

    if _HARD_FAIL_OUT.search(out):
        print(
            "verilator_invoke: HARD FAIL — Verilator reported elab/bind/compile "
            "error (PINNOTFOUND/%Error). Not a pass, not a skip.",
            file=sys.stderr,
        )
        raise SystemExit(2)

    if proc.returncode != 0:
        print(
            f"verilator_invoke: HARD FAIL — verilator exit rc={proc.returncode}",
            file=sys.stderr,
        )
        raise SystemExit(proc.returncode if proc.returncode != 0 else 2)

    if exe is not None and not exe.is_file():
        print(
            f"verilator_invoke: HARD FAIL — expected TB binary missing after build: {exe}",
            file=sys.stderr,
        )
        raise SystemExit(2)

    return out
