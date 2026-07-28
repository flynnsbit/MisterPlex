#!/usr/bin/env python3
"""Adversarial tests for check_vacuous_control.py."""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts/check_vacuous_control.py"
SCRATCH = ROOT / "build/w_audit_vacuous_control_self_attack"


def run(args: list[str]) -> tuple[int, str]:
    p = subprocess.run(["python3", str(CHECKER), *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    return p.returncode, p.stdout


def strip_sv_comments(text: str) -> str:
    text = re.sub(r"//.*", "", text)
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(line.strip() for line in text.splitlines() if line.strip())


def strip_sdc_comments(text: str) -> str:
    return "\n".join(line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#"))


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def main() -> int:
    if SCRATCH.exists():
        shutil.rmtree(SCRATCH)

    # False negative for vacuity: byte-different SDC comments make --different
    # pass even though the effective constraints are identical.
    a = SCRATCH / "vacuous_pass_a"
    b = SCRATCH / "vacuous_pass_b"
    sdc_a = "# old comment\nset_max_delay -from [get_keepers {a}] -to [get_keepers {b}] 50.0\n"
    sdc_b = "# new comment only; constraint below is identical\nset_max_delay -from [get_keepers {a}] -to [get_keepers {b}] 50.0\n"
    write(a / "Plex.sdc", sdc_a)
    write(b / "Plex.sdc", sdc_b)
    rc, out = run(["--different", "Plex.sdc", str(a), str(b)])
    print("CASE vacuous_but_passes_comment_only_sdc")
    print(f"  normalized_constraints_same={int(strip_sdc_comments(sdc_a) == strip_sdc_comments(sdc_b))}")
    print(f"  checker_rc={rc}")
    for line in out.splitlines():
        if "RESULT" in line or "SUMMARY" in line:
            print(f"  {line}")

    # False positive for a sound semantic control: raw comments in RTL make
    # --same fail even though the synthesizable source text is identical after
    # comment stripping.
    c = SCRATCH / "sound_fails_a"
    d = SCRATCH / "sound_fails_b"
    sv_a = "module m(input wire a, output wire y); assign y = a; endmodule\n"
    sv_b = "// audit-only comment\nmodule m(input wire a, output wire y); assign y = a; endmodule\n"
    write(c / "rtl/m.sv", sv_a)
    write(d / "rtl/m.sv", sv_b)
    rc, out = run(["--same", "rtl", str(c), str(d)])
    print("CASE sound_but_fails_comment_only_rtl")
    print(f"  normalized_rtl_same={int(strip_sv_comments(sv_a) == strip_sv_comments(sv_b))}")
    print(f"  checker_rc={rc}")
    for line in out.splitlines():
        if "RESULT" in line or "SUMMARY" in line:
            print(f"  {line}")

    print("CONCLUSION checker_is_byte_premise_not_semantic_premise")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
