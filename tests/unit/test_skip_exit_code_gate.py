#!/usr/bin/env python3
"""Unit coverage for the skip-exit-code gate.

A skip that exits 0 is a false green: make, the skip summariser and the fleet
log all record success for a gate that measured nothing.  This proves the
detector fires on that shape and stays quiet on a correct 77 skip.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "check_skip_exit_codes.py"

BAD = """#!/usr/bin/env bash
set -euo pipefail
if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP: verilator missing; nothing was simulated." >&2
  exit 0
fi
echo ok
"""

GOOD = """#!/usr/bin/env bash
set -euo pipefail
if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP: verilator missing; nothing was simulated." >&2
  exit 77
fi
echo ok
exit 0
"""


def require(ok: bool, msg: str) -> None:
    if not ok:
        raise AssertionError(msg)


def run(paths: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(GATE), "--root", str(cwd), "--paths", *paths],
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=120,
    )


def main() -> int:
    real = subprocess.run(
        [sys.executable, str(GATE)], cwd=ROOT, capture_output=True, text=True, timeout=180
    )
    combined = real.stdout + real.stderr
    require(real.stdout.startswith("Scope: skip-exit-code"), f"gate must print Scope first\n{combined}")
    require(real.returncode == 0, f"repository must have no skip-dominated exit 0\n{combined}")
    print(real.stdout.splitlines()[0])
    print("PASS repository has no skip path that exits 0")

    with tempfile.TemporaryDirectory(dir=ROOT / "build" if (ROOT / "build").is_dir() else None) as tmp:
        d = Path(tmp)
        subprocess.run(["git", "init", "-q"], cwd=d, check=True)
        (d / "scripts").mkdir()
        (d / "tests").mkdir()
        (ROOT / "scripts" / "check_skip_exit_codes.py").read_bytes()
        (d / "scripts" / "check_skip_exit_codes.py").write_bytes(GATE.read_bytes())
        (d / "tests" / "t_bad.sh").write_text(BAD)
        subprocess.run(["git", "add", "-A"], cwd=d, check=True)
        red = run(["tests"], d)
        red_combined = red.stdout + red.stderr
        require(
            red.returncode == 1 and "SKIP_EXITS_ZERO tests/t_bad.sh:5" in red_combined,
            f"skip-exits-0 fixture did not go red\n{red_combined}",
        )
        print("PASS a skip path exiting 0 is reported red")

        (d / "tests" / "t_bad.sh").write_text(GOOD)
        subprocess.run(["git", "add", "-A"], cwd=d, check=True)
        green = run(["tests"], d)
        green_combined = green.stdout + green.stderr
        require(
            green.returncode == 0 and "SKIP_EXIT_CODE_OK" in green_combined,
            f"exit 77 skip fixture did not go green\n{green_combined}",
        )
        require(
            "exit_zero_sites=1" in green_combined,
            f"a non-skip trailing exit 0 must still be counted, not flagged\n{green_combined}",
        )
        print("PASS the same script exiting 77 goes green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
