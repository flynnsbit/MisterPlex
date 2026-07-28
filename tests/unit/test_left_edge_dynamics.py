#!/usr/bin/env python3
"""Unit gate for scripts/analyze_left_edge_dynamics.py.

Runs the tool's hermetic self-test through its real CLI, then asserts the
non-obvious guarantees that a self-test alone would not pin down:

  * a noisy capture REFUSES rather than claiming either verdict
  * exit codes are the documented 0/1/2 and never a silent 0 on bad input
  * the tool refuses unknown arguments instead of ignoring them (the failure
    mode the parent flagged on check_rtl_module_instantiations.py, where a
    checker accepted --help and printed a confident green)
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "scripts" / "analyze_left_edge_dynamics.py"

checks: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: object = "") -> None:
    checks.append((name, bool(ok), str(detail)))


def run(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(TOOL)] + args,
                          capture_output=True, text=True)


def main() -> int:
    check("tool exists", TOOL.is_file(), TOOL)
    if not TOOL.is_file():
        print("FAIL tool missing")
        return 2

    r = run(["--self-test"])
    check("self-test passes (rc=0)", r.returncode == 0, f"rc={r.returncode}\n{r.stdout}")
    check("self-test proves a MOVING positive control",
          "PASS moving artifact -> MOVING" in r.stdout, r.stdout)
    check("self-test proves a STATIC negative control",
          "PASS static artifact -> STATIC" in r.stdout, r.stdout)
    check("self-test proves noise REFUSES instead of claiming motion",
          "PASS static + heavy noise -> REFUSE (never MOVING)" in r.stdout, r.stdout)

    r = run([])
    check("no arguments REFUSES (rc=2), never a silent pass",
          r.returncode == 2, f"rc={r.returncode}")

    r = run(["--frames-dir", str(ROOT / "does" / "not" / "exist")])
    check("missing frames dir REFUSES (rc=2)", r.returncode == 2, f"rc={r.returncode}")

    r = run(["--self-test", "--not-a-real-flag"])
    check("unknown argument is a hard error, not silently ignored",
          r.returncode != 0 and "unrecognized" in r.stderr,
          f"rc={r.returncode} stderr={r.stderr[:200]}")

    ok = 0
    for name, passed, detail in checks:
        print(f"{'PASS' if passed else 'FAIL'} {name}" + ("" if passed else f"  [{detail}]"))
        ok += passed
    print(f"\n{ok}/{len(checks)} checks passed")
    if ok != len(checks):
        print("LEFT_EDGE_DYNAMICS_GATE_FAIL")
        return 1
    print("LEFT_EDGE_DYNAMICS_GATE_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
