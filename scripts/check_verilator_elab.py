#!/usr/bin/env python3
"""Fast Verilator elaboration guard for synthesis-fatal owned RTL errors.

This gate is intentionally narrower than a Quartus fit and broader than the
curated static Quartus subset scanner: it elaborates the product Quartus RTL
file list with the product macro set and fails on Verilator errors physically
reported against MiSTerPlex-owned RTL. It exists to catch undeclared identifiers
and related build-stopping RTL mistakes before a scarce Quartus slot is used.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import rtl_lint

sys.path.insert(0, str(Path(__file__).resolve().parent))
import strict_argv

REFUSE_RC = 3
REJECT_RC = 1


def main() -> int:
    strict_argv.refuse_unrecognised_argv()
    root = rtl_lint.ROOT
    project = rtl_lint.PROJECT
    probe = subprocess.run(
        [str(root / "scripts" / "run_verilator.sh"), "--version"],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if probe.returncode == 127:
        print(
            f"VERILATOR_ELAB_REFUSED(exit={REFUSE_RC}): Verilator not found; "
            "owned RTL elaboration was NOT run.",
            file=sys.stderr,
        )
        print(
            "Install oss-cad-suite under ~/.local/oss-cad-suite or set "
            "VERILATOR=/path/to/verilator.",
            file=sys.stderr,
        )
        return REFUSE_RC
    if probe.returncode != 0:
        print("VERILATOR_ELAB_ERROR: Verilator probe failed:", file=sys.stderr)
        print(probe.stdout, file=sys.stderr)
        return probe.returncode

    files, macros = rtl_lint.discover_design()
    reportable = {rtl_lint.rel(p) for p in files if not rtl_lint.is_excluded(p)}
    plex_rel = "fpga/Plex_MiSTer/Plex.sv"
    module_files = [p for p in files if rtl_lint.rel(p) in reportable and rtl_lint.rel(p) != plex_rel]
    rc, output = rtl_lint.run_verilator(module_files, macros)

    plex_files = [p for p in files if rtl_lint.rel(p) == plex_rel]
    top_output = ""
    top_rc = 0
    if plex_files:
        all_context = sorted(
            {
                p
                for p in project.rglob("*")
                if p.suffix.lower() in {".sv", ".v"} and p not in plex_files
            }
        )
        top_rc, top_output = rtl_lint.run_verilator(plex_files + all_context, macros)

    (root / "build").mkdir(exist_ok=True)
    (root / "build" / "verilator_elab.log").write_text(
        "=== owned module elaboration pass ===\n"
        + output
        + "\n=== Plex.sv context elaboration pass ===\n"
        + top_output
    )

    owned_errors, ignored_errors = rtl_lint.reportable_errors(output, reportable - {plex_rel})
    top_owned_errors, top_ignored_errors = rtl_lint.reportable_errors(top_output, {plex_rel})
    ignored_errors += top_ignored_errors
    errors = owned_errors + top_owned_errors

    print(f"Verilator elaboration: using {probe.stdout.strip()}")
    print(
        f"Verilator elaboration: parsed {len(files)} Quartus RTL/context files; "
        f"checking {len(reportable)} owned files"
    )
    if macros:
        print("Verilator elaboration: propagated QSF macros " + " ".join(macros))
    if ignored_errors:
        print(
            f"Verilator elaboration: ignored {len(ignored_errors)} vendor/generated "
            "context errors; see build/verilator_elab.log"
        )
    if errors:
        print(
            "VERILATOR_ELAB_REJECTED(exit=1): Verilator reported errors in owned "
            "RTL (see build/verilator_elab.log):",
            file=sys.stderr,
        )
        for line in errors[:40]:
            print(f"  {line}", file=sys.stderr)
        return rc or top_rc or REJECT_RC

    print("VERILATOR_ELAB_PASS: no owned RTL elaboration errors")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
