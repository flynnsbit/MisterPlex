#!/usr/bin/env python3
"""Static guard: RTL/unit gates must not be able to false-green.

Catches the class that burned two Quartus fits this session:
  - Verilator missing → exit 0 (looks like PASS)
  - ALLOW_MISSING_VERILATOR=1 → exit 0
  - Soft-skip without SKIP-NOT-PASS wording

Does not execute sims. Exit 0 only when the scanned corpus is clean.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UNIT = ROOT / "tests" / "unit"

# Scripts that intentionally probe Verilator / RTL sims.
GLOBS = (
    "*rtl_sim*.sh",
    "*verilator*.sh",
    "*ddr*frame*.sh",
    "*sdram*.sh",
    "*stream_path*.sh",
    "*ddram*.sh",
    "*hybrid_gate*.sh",
    "*scanout*.sh",
)

# False-green patterns (multiline-ish via window).
# 1) After "Verilator not found", an exit 0 without exit 77 nearby is banned.
MISSING_VL = re.compile(r"Verilator not found", re.I)
EXIT0 = re.compile(r"\bexit\s+0\b")
EXIT77 = re.compile(r"\bexit\s+77\b")
ALLOW = re.compile(r"ALLOW_MISSING_VERILATOR")
SKIP_NOT_PASS = re.compile(r"SKIP-NOT-PASS")


def collect_scripts() -> list[Path]:
    seen: set[Path] = set()
    out: list[Path] = []
    for pat in GLOBS:
        for p in UNIT.glob(pat):
            if p in seen or not p.is_file():
                continue
            seen.add(p)
            out.append(p)
    return sorted(out)


# Positive execution proof after a TB binary is invoked.
EXEC_PROOF = re.compile(
    r"assert_sim_executed|"
    r"SIM_EXECUTED|"
    r"grep\s+-q[^\n]*PASS|"
    r"grep\s+-qE[^\n]*PASS|"
    r"grep\s+-q[^\n]*OK"
)


def audit_script(path: Path) -> list[str]:
    text = path.read_text(errors="ignore")
    rel = path.relative_to(ROOT).as_posix()
    errs: list[str] = []

    # Missing-Verilator soft-skip must never exit 0.
    if MISSING_VL.search(text):
        lines = text.splitlines()
        for i, line in enumerate(lines):
            if not MISSING_VL.search(line):
                continue
            window = "\n".join(lines[i : min(len(lines), i + 18)])
            if ALLOW.search(window) and EXIT0.search(window) and not EXIT77.search(window):
                errs.append(
                    f"{rel}:{i+1}: ALLOW_MISSING_VERILATOR path exits 0 "
                    f"(must exit 77 SKIP-NOT-PASS; soft-skip≠PASS)"
                )
            if EXIT0.search(window) and not EXIT77.search(window):
                errs.append(
                    f"{rel}:{i+1}: 'Verilator not found' followed by exit 0 without exit 77 "
                    f"(missing tool must not green the gate)"
                )
            if ALLOW.search(window) and EXIT77.search(window) and not SKIP_NOT_PASS.search(window):
                errs.append(
                    f"{rel}:{i+1}: ALLOW_MISSING_VERILATOR exit 77 without SKIP-NOT-PASS marker "
                    f"(skip summary cannot classify coverage holes)"
                )

    # Scripts that build/run a Verilator TB must prove the TB executed.
    runs_tb = bool(
        re.search(r"run_verilator\.sh|--cc\s+--exe|--exe\s+--build", text)
        or re.search(r"/V[A-Za-z0-9_]+\b", text)
    )
    if runs_tb and path.name != "lib_rtl_sim_gate.sh":
        if not EXEC_PROOF.search(text):
            # Accept red-before-green suites that capture TB rc/out and emit OK.
            has_red_harness = bool(
                re.search(r"expected_red\.py", text)
                or re.search(r"_RC=\$\?|_rc=\$\?", text)
            )
            has_ok_line = bool(
                re.search(r'echo\s+"OK\s', text)
                or re.search(r'echo\s+".*: OK\b', text)
                or re.search(r"RED OK|RED proof|red-check", text)
            )
            has_grep_log = bool(re.search(r"grep\s+-q", text))
            if not ((has_red_harness and has_ok_line) or (has_grep_log and has_ok_line)):
                errs.append(
                    f"{rel}: RTL sim gate has no assert_sim_executed/grep-PASS/"
                    f"red-check proof-of-execution (compile-only can false-green)"
                )
    return errs


def main() -> int:
    scripts = collect_scripts()
    if not scripts:
        print("FAIL test_gate_false_green_guard: no RTL sim scripts discovered", file=sys.stderr)
        return 2

    errors: list[str] = []
    for p in scripts:
        errors.extend(audit_script(p))

    # Shared library must exist and encode the contract.
    lib = UNIT / "lib_rtl_sim_gate.sh"
    if not lib.is_file():
        errors.append("tests/unit/lib_rtl_sim_gate.sh missing")
    else:
        lib_t = lib.read_text(errors="ignore")
        for needle in ("exit 77", "SKIP-NOT-PASS", "assert_sim_executed", "ALLOW_MISSING_VERILATOR"):
            if needle not in lib_t:
                errors.append(f"lib_rtl_sim_gate.sh missing contract token: {needle}")

    # run_verilator must hard-fail PINNOTFOUND.
    rv = (ROOT / "scripts" / "run_verilator.sh").read_text(errors="ignore")
    if "PINNOTFOUND" not in rv or "exit 2" not in rv:
        errors.append("scripts/run_verilator.sh must HARD FAIL PINNOTFOUND with exit 2")

    print(f"gate_false_green_guard: scanned {len(scripts)} RTL sim scripts")
    if errors:
        print("FAIL gate_false_green_guard: false-green patterns remain:", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        return 1
    print("PASS gate_false_green_guard: no missing-Verilator exit-0 false greens; run_verilator PINNOTFOUND hard-fail present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
