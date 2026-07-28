#!/usr/bin/env python3
"""Adversarial tests for scripts/check_qip_coverage.py.

The target script is copied into disposable miniature git repos under build/.
Each case is a complete independent project so the target's hard-coded relative
paths and `git ls-files` behaviour are exercised directly.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
from pathlib import Path


DEFAULT_TARGET = Path("/home/flynnsbit/Projects/mp-wt-integ/scripts/check_qip_coverage.py")


def run(cmd: list[str], cwd: Path) -> tuple[int, str]:
    p = subprocess.run(
        cmd,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    return p.returncode, p.stdout


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def make_repo(base: Path, target: Path, case: str, rtl_name: str, qip_text: str, *, qsf_text: str = "") -> Path:
    root = base / case
    if root.exists():
        shutil.rmtree(root)
    (root / "scripts").mkdir(parents=True)
    shutil.copy2(target, root / "scripts/check_qip_coverage.py")
    write(root / f"fpga/Plex_MiSTer/rtl/{rtl_name}", f"module {rtl_name[:-3]}; endmodule\n")
    write(root / "fpga/Plex_MiSTer/files.qip", qip_text)
    if qsf_text:
        write(root / "fpga/Plex_MiSTer/Plex.qsf", qsf_text)
    run(["git", "init", "-q"], root)
    run(["git", "add", "scripts/check_qip_coverage.py", "fpga"], root)
    return root


def case_run(root: Path, require: str | None = None) -> tuple[int, str]:
    cmd = ["python3", "scripts/check_qip_coverage.py"]
    if require:
        cmd += ["--require", require]
    return run(cmd, root)


def print_case(name: str, rc: int, truth: str, out: str) -> None:
    print(f"CASE {name} rc={rc} truth={truth}")
    for line in out.splitlines():
        if (
            line.startswith("Scope:")
            or line.startswith("tracked but")
            or line.startswith("  ")
            or line.startswith("REQUIRED_")
            or line.startswith("QIP_COVERAGE_")
            or line.startswith("SKIP:")
            or line.startswith("REFUSED:")
        ):
            print(f"  {line}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--target", type=Path, default=DEFAULT_TARGET)
    args = ap.parse_args()

    audit_root = Path(__file__).resolve().parents[1]
    base = audit_root / "build/w_audit_qip_coverage_attack"
    base.mkdir(parents=True, exist_ok=True)

    target = args.target
    print(f"TARGET {target}")

    cases: list[tuple[str, str, str, str | None, str]] = [
        (
            "control_missing_is_red",
            "foo.sv",
            "set_global_assignment -name SYSTEMVERILOG_FILE rtl/other_compiled_file.sv\n",
            "foo",
            "NOT_COMPILED: tracked rtl/foo.sv is absent from active qip",
        ),
        (
            "commented_assignment_false_green",
            "foo.sv",
            "# set_global_assignment -name SYSTEMVERILOG_FILE rtl/foo.sv\n",
            "foo",
            "NOT_COMPILED: assignment is a comment, Quartus will not compile foo.sv",
        ),
        (
            "wrong_directory_basename_false_green",
            "foo.sv",
            "set_global_assignment -name SYSTEMVERILOG_FILE rtl_old/foo.sv\n",
            "foo",
            "NOT_COMPILED: qip names rtl_old/foo.sv, not product rtl/foo.sv",
        ),
        (
            "allowed_absent_false_green",
            "h264_decode_skeleton.sv",
            "set_global_assignment -name SYSTEMVERILOG_FILE rtl/other_compiled_file.sv\n",
            None,
            "NOT_COMPILED: allowlist hides missing tracked RTL without checking reachability",
        ),
        (
            "qsf_direct_assignment_false_red",
            "foo.sv",
            "set_global_assignment -name SYSTEMVERILOG_FILE rtl/other_compiled_file.sv\n",
            "foo",
            "COMPILED_ELSEWHERE: Plex.qsf directly lists rtl/foo.sv but files.qip omits it",
        ),
    ]

    for name, rtl_name, qip, require, truth in cases:
        qsf = ""
        if name == "qsf_direct_assignment_false_red":
            qsf = "set_global_assignment -name SYSTEMVERILOG_FILE rtl/foo.sv\n"
        root = make_repo(base, target, name, rtl_name, qip, qsf_text=qsf)
        rc, out = case_run(root, require)
        print_case(name, rc, truth, out)

    absent = base / "qip_absent_skip"
    if absent.exists():
        shutil.rmtree(absent)
    (absent / "scripts").mkdir(parents=True)
    shutil.copy2(target, absent / "scripts/check_qip_coverage.py")
    write(absent / "fpga/Plex_MiSTer/rtl/foo.sv", "module foo; endmodule\n")
    run(["git", "init", "-q"], absent)
    run(["git", "add", "scripts/check_qip_coverage.py", "fpga"], absent)
    rc, out = case_run(absent, "foo")
    print_case("missing_qip_returns_skip", rc, "UNSCORED: no file-list oracle exists", out)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
