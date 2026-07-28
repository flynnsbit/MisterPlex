#!/usr/bin/env python3
"""Integrity guard for the reachability checker itself.

WHY THIS EXISTS
---------------
The fleet-mandated evidence command is

    check_rtl_module_instantiations.py --root <R> --require <M>

On several branches the shipped checker had **no argparse at all**: main() took
no argv, so every flag was silently discarded and the tool printed
`RTL_MODULE_INSTANTIATION_OK ... root=emu` and exited 0 no matter what was
asked of it. Measured on w-arm-idle-edge before this guard existed:

    --root emu --require h264_decode_core   -> rc=0   (false green)
    --help                                  -> rc=0   (false green)

h264_decode_core is ABSENT from the fitted silicon of fb4bad84, so that rc=0 was
the exact "proven working but not in the product" evidence the gate exists to
prevent. A checker that ignores its arguments is worse than no checker, because
it produces confident greens.

WHAT THIS LITERALLY CHECKS
--------------------------
  1. an unknown argument is a hard error (rc != 0), so a typo cannot masquerade
     as a pass
  2. --root is actually honoured, proved differentially: two different roots must
     produce different reachable counts, so the flag cannot be being ignored
  3. --require is actually honoured: a module that does not exist must fail

WHAT THIS DOES NOT COVER
------------------------
  It says nothing about whether the reachability *answer* is correct. It only
  proves the tool is listening. Correctness still needs both directions
  (trunk + subtree), the files.qip cross-check, and post-fit hierarchy.

Exit: 0 pass, 1 fail, 77 unscored.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts/check_rtl_module_instantiations.py"


def run(*args: str) -> tuple[int, str]:
    proc = subprocess.run(
        [sys.executable, str(CHECKER), *args],
        capture_output=True, text=True, cwd=str(ROOT),
    )
    return proc.returncode, proc.stdout + proc.stderr


def reachable_count(text: str) -> int | None:
    m = re.search(r"reachable=(\d+)", text)
    return int(m.group(1)) if m else None


def main() -> int:
    if not CHECKER.is_file():
        print(f"SKIP-NOT-PASS check_reachability_tool_integrity: missing {CHECKER}")
        return 77

    print("Scope: 3 integrity properties of check_rtl_module_instantiations.py "
          "(unknown-arg rejection, --root honoured differentially, --require honoured)")
    failures = 0

    rc, _ = run("--definitely-not-a-real-flag")
    if rc == 0:
        print("FAIL unknown argument was silently accepted (rc=0); flags may be ignored")
        failures += 1
    else:
        print(f"OK unknown argument rejected rc={rc}")

    rc_emu, out_emu = run("--root", "emu")
    rc_sub, out_sub = run("--root", "present_core")
    n_emu, n_sub = reachable_count(out_emu), reachable_count(out_sub)
    if n_emu is None or n_sub is None:
        print(f"FAIL could not parse reachable= from output (emu={n_emu} sub={n_sub})")
        failures += 1
    elif n_emu == n_sub:
        print(f"FAIL --root appears ignored: emu and present_core both "
              f"report reachable={n_emu}")
        failures += 1
    else:
        print(f"OK --root honoured differentially: emu reachable={n_emu} "
              f"vs present_core reachable={n_sub}")

    rc, out = run("--require", "module_that_does_not_exist_wgate")
    if rc == 0:
        print("FAIL --require accepted a nonexistent module (rc=0); flag may be ignored")
        failures += 1
    else:
        print(f"OK --require honoured for a nonexistent module rc={rc}")

    if failures:
        print(f"RESULT FAIL reachability tool integrity failures={failures}/3")
        return 1
    print("RESULT PASS reachability tool integrity 3/3: the checker is listening "
          "to its arguments")
    return 0


if __name__ == "__main__":
    sys.exit(main())
