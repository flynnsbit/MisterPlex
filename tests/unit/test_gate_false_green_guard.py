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
    # Python RTL paths were BLIND to this guard (only scanned *.sh + exit N).
    "*verilator*.py",
    "*dequant*.py",
    "*rtl_model*.py",
)

# False-green patterns (multiline-ish via window).
# 1) After "Verilator not found", an exit 0 without exit 77 nearby is banned.
# Match "Verilator not found", "Verilator runner not found", etc.
MISSING_VL = re.compile(r"Verilator(?:\s+runner)?\s+not\s+found", re.I)
EXIT0 = re.compile(r"\bexit\s+0\b")
RETURN0 = re.compile(r"\breturn\s+0\b")
EXIT77 = re.compile(r"\bexit\s+77\b")
RETURN77 = re.compile(r"\breturn\s+77\b|sys\.exit\(77\)")
EXIT3 = re.compile(r"\bexit\s+3\b")
RETURN3 = re.compile(r"\breturn\s+3\b|sys\.exit\(3\)")
ALLOW = re.compile(r"ALLOW_MISSING_VERILATOR")
SKIP_NOT_PASS = re.compile(r"SKIP-NOT-PASS")
BARE_VERILATOR_FALLBACK = re.compile(
    r"""command\s+-v\s+verilator|oss-cad-suite[^\n]*bin/verilator""",
    re.I,
)


def collect_scripts() -> list[Path]:
    seen: set[Path] = set()
    out: list[Path] = []
    skip_names = {
        "verilator_invoke.py",  # helper, not a gate
        "test_gate_false_green_guard.py",
    }
    for pat in GLOBS:
        for p in UNIT.glob(pat):
            if p in seen or not p.is_file():
                continue
            if p.name in skip_names:
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
            soft0 = bool(EXIT0.search(window) or RETURN0.search(window))
            soft77 = bool(EXIT77.search(window) or RETURN77.search(window))
            soft3 = bool(EXIT3.search(window) or RETURN3.search(window))
            if ALLOW.search(window) and soft0 and not soft77:
                errs.append(
                    f"{rel}:{i+1}: ALLOW_MISSING_VERILATOR path exits/returns 0 "
                    f"(must exit/return 77 SKIP-NOT-PASS; soft-skip≠PASS)"
                )
            if soft0 and not soft77 and not soft3:
                errs.append(
                    f"{rel}:{i+1}: 'Verilator not found' followed by exit/return 0 without 77 "
                    f"(missing tool must not green the gate)"
                )
            if ALLOW.search(window) and soft77 and not (
                SKIP_NOT_PASS.search(window) or SKIP_NOT_PASS.search(text)
            ):
                errs.append(
                    f"{rel}:{i+1}: ALLOW_MISSING_VERILATOR exit/return 77 without SKIP-NOT-PASS marker "
                    f"(skip summary cannot classify coverage holes)"
                )

    # Bare `command -v verilator` / pinned oss-cad path bypasses run_verilator.sh
    # PINNOTFOUND→rc=2. Prefer the wrapper exclusively.
    if BARE_VERILATOR_FALLBACK.search(text) and "run_verilator.sh" in text:
        # Allowed only if the bare path is unreachable dead code after wrapper; still flag.
        if re.search(r"elif\s+command\s+-v\s+verilator|elif\s+\[\[\s+-x\s+\"\$HOME/.local/oss-cad", text):
            errs.append(
                f"{rel}: bare verilator/oss-cad fallback after run_verilator.sh "
                f"(PINNOTFOUND guard bypass — use wrapper only)"
            )

    # Any SKIP path that exits 0 is a false green (covers wording variants).
    if re.search(r"^[^#\n]*\bSKIP\b", text, re.M | re.I):
        lines = text.splitlines()
        for i, line in enumerate(lines):
            if line.lstrip().startswith("#"):
                continue
            if not re.search(r"\bSKIP\b", line, re.I):
                continue
            if "SKIP-NOT-PASS" in line:
                # look ahead for exit
                window = "\n".join(lines[i : min(len(lines), i + 12)])
            else:
                window = "\n".join(lines[i : min(len(lines), i + 12)])
            if EXIT0.search(window) and not (EXIT77.search(window) or EXIT3.search(window)):
                # success path later in file may contain exit 0; require exit 0 within 8 lines
                near = "\n".join(lines[i : min(len(lines), i + 8)])
                if EXIT0.search(near) and not EXIT77.search(near) and not EXIT3.search(near):
                    # ignore end-of-file success `exit 0` far from SKIP
                    if re.search(r"exit\s+0", near):
                        # If this SKIP block's near window has exit 0 as the only exit, flag.
                        exits = re.findall(r"\bexit\s+(\d+)\b", near)
                        if exits and exits[0] == "0":
                            errs.append(
                                f"{rel}:{i+1}: SKIP path exits 0 (must be 77 SKIP-NOT-PASS or 3 refuse)"
                            )

    # Python that shells out to verilator binary must use verilator_invoke
    # (PINNOTFOUND/%Error with rc=0 + stale TB was a proven false-green).
    if path.suffix == ".py" and re.search(r"--cc\s+--exe|--exe\s+--build", text):
        if "verilator_invoke" not in text and "run_verilator_build" not in text:
            if "run_verilator.sh" not in text:
                errs.append(
                    f"{rel}: Python RTL build calls verilator directly without "
                    f"verilator_invoke.run_verilator_build (PINNOTFOUND rc=0 + stale TB false-green)"
                )

    # Scripts that build/run a Verilator TB must prove the TB executed.
    # Python that shells out to verilator binary must use verilator_invoke
    # (PINNOTFOUND/%Error with rc=0 + stale TB was a proven false-green).
    if path.suffix == ".py" and re.search(r"--cc\s+--exe|--exe\s+--build", text):
        if "verilator_invoke" not in text and "run_verilator_build" not in text:
            if "run_verilator.sh" not in text:
                errs.append(
                    f"{rel}: Python RTL build calls verilator directly without "
                    f"verilator_invoke.run_verilator_build (PINNOTFOUND rc=0 + stale TB false-green)"
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

    # RED-before-GREEN: fake verilator that exits 0 after printing PINNOTFOUND
    # must still yield process rc=2 (the historic false-green class).
    import os
    import stat
    import subprocess
    import tempfile
    from pathlib import Path as _P

    with tempfile.TemporaryDirectory(prefix="pinnotfound-rbg-") as td:
        fake = _P(td) / "fake_verilator"
        fake.write_text(
            "#!/usr/bin/env bash\n"
            "echo '%Error: PINNOTFOUND: x.v:1: pin foo not found'\n"
            "exit 0\n",
            encoding="utf-8",
        )
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        env = os.environ.copy()
        env["VERILATOR"] = str(fake)
        red = subprocess.run(
            ["bash", str(ROOT / "scripts" / "run_verilator.sh"), "--lint-only", "x.v"],
            cwd=str(ROOT),
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        print(f"PINNOTFOUND_RBG_RED true rc={red.returncode}")
        if red.returncode != 2:
            errors.append(
                f"run_verilator PINNOTFOUND RBG RED failed: want rc=2 got {red.returncode} "
                f"out={(red.stdout or '')[-200:]} err={(red.stderr or '')[-200:]}"
            )
        if "HARD FAIL" not in (red.stderr or "") + (red.stdout or ""):
            errors.append("run_verilator PINNOTFOUND RBG RED missing HARD FAIL marker")

        fake.write_text(
            "#!/usr/bin/env bash\n"
            "echo 'Verilator clean OK'\n"
            "exit 0\n",
            encoding="utf-8",
        )
        green = subprocess.run(
            ["bash", str(ROOT / "scripts" / "run_verilator.sh"), "--lint-only", "x.v"],
            cwd=str(ROOT),
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        print(f"PINNOTFOUND_RBG_GREEN true rc={green.returncode}")
        if green.returncode != 0:
            errors.append(
                f"run_verilator clean path RBG GREEN failed: want rc=0 got {green.returncode}"
            )

    print(f"gate_false_green_guard: scanned {len(scripts)} RTL sim scripts")
    if errors:
        print("FAIL gate_false_green_guard: false-green patterns remain:", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        print(f"true rc=1")
        return 1
    print(
        "PASS gate_false_green_guard: no missing-Verilator exit-0 false greens; "
        "run_verilator PINNOTFOUND hard-fail RBG both dirs"
    )
    print("true rc=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
