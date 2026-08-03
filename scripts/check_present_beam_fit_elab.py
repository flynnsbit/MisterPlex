#!/usr/bin/env python3
"""Gate: PRESENT_BEAM_960 fit macros elaborate against *files.qip* product list.

rd-duck: Verilator TBs listed present_beam_content_de.sv explicitly, so a missing
files.qip entry stayed green. This script:
  1) Requires beam (+ timing) paths in fpga/Plex_MiSTer/files.qip
  2) Elaborates the QIP-discovered product RTL with the *exact fit macro set*
     (PRESENT_BEAM_960, FRAME_W=960, FRAME_H=540, plus QSF macros)
  3) If quartus_map is available, runs Analysis & Elaboration only (no fit)

Exit: 0 PASS, 1 REJECT, 3 Verilator missing, 4 Quartus missing when required.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import rtl_lint  # noqa: E402
from check_define_parity import verilator_define_args  # noqa: E402

PROJECT = ROOT / "fpga" / "Plex_MiSTer"
QIP = PROJECT / "files.qip"
REQUIRED_QIP = (
    "rtl/present_beam_content_de.sv",
    "rtl/present_video_timing_960.sv",
    "rtl/present_content_window.sv",
    "rtl/present_core.sv",
)

# Exact near-term ascal true-DE fit set (fit card). Do not include FAULT/scale macros.
FIT_MACROS = (
    "PRESENT_BEAM_960=1",
    "FRAME_W=960",
    "FRAME_H=540",
    "DDR_FRAME_STORE=1",
)

REJECT = 1
VERILATOR_MISS = 3
QUARTUS_MISS = 4


def qip_text() -> str:
    return QIP.read_text(encoding="utf-8", errors="replace")


def check_qip() -> list[str]:
    text = qip_text()
    missing = []
    for rel in REQUIRED_QIP:
        # Match assignment line, not comments only
        pat = re.compile(
            rf"set_global_assignment\s+-name\s+SYSTEMVERILOG_FILE\s+{re.escape(rel)}\b"
        )
        if not pat.search(text):
            missing.append(rel)
    return missing


def fit_define_args() -> list[str]:
    """QSF defines, then fit overrides (later -D wins in Verilator)."""
    base = verilator_define_args(PROJECT / "Plex.qsf")
    # Strip FRAME_W/H from base so fit 960/540 wins cleanly if duplicated.
    filtered = []
    for a in base:
        if a.startswith("+define+FRAME_W=") or a.startswith("+define+FRAME_H="):
            continue
        if a.startswith("+define+PRESENT_BEAM_"):
            continue
        filtered.append(a)
    for m in FIT_MACROS:
        filtered.append(f"+define+{m}")
    return filtered


def run_verilator_fit_elab() -> tuple[int, str]:
    files, _macros = rtl_lint.discover_design()
    # Ensure required sources resolved from QIP
    rels = {rtl_lint.rel(p) for p in files}
    need = {f"fpga/Plex_MiSTer/{r}" for r in REQUIRED_QIP}
    missing_disc = sorted(need - rels)
    if missing_disc:
        return REJECT, "QIP_DISCOVER_MISS " + " ".join(missing_disc)

    stub = rtl_lint.write_intel_stubs()
    reportable = {rtl_lint.rel(p) for p in files if not rtl_lint.is_excluded(p)}
    module_files = [
        p
        for p in files
        if rtl_lint.rel(p) in reportable and rtl_lint.rel(p) != "fpga/Plex_MiSTer/Plex.sv"
    ]
    ordered = sorted(module_files, key=lambda p: rtl_lint.rel(p))
    cmd = [
        str(ROOT / "scripts" / "run_verilator.sh"),
        "--lint-only",
        "-Wall",
        "-Wno-fatal",
        "-Wno-DECLFILENAME",
        "-Wno-PINCONNECTEMPTY",
        "-Wno-PINMISSING",
        "-Wno-MULTITOP",
        "-Wno-EOFNEWLINE",
        "-Wno-GENUNNAMED",
        "-Wno-UNUSED",
        "-Wno-UNDRIVEN",
        "-Wno-WIDTHTRUNC",
        "-Wno-WIDTHEXPAND",
        f"-I{ROOT / 'build' / 'rtl_lint_generated'}",
        f"-I{PROJECT}",
        f"-I{PROJECT / 'sys'}",
        f"-I{PROJECT / 'rtl'}",
        str(stub),
    ] + fit_define_args() + [str(p) for p in ordered]

    proc = subprocess.run(cmd, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return proc.returncode, proc.stdout


def run_quartus_analysis() -> tuple[int, str]:
    """Analysis & Elaboration only — never a full fit."""
    qmap = shutil.which("quartus_map")
    if not qmap:
        return QUARTUS_MISS, "quartus_map not on PATH"
    # Work in a scratch project dir under build/ (not /tmp).
    work = ROOT / "build" / "quartus_beam_fit_elab"
    work.mkdir(parents=True, exist_ok=True)
    # Use product project; pass macros via --verilog_macro / QSF copy is heavy.
    # Prefer: quartus_map Plex --analysis_and_elaboration with --set
    cmd = [
        qmap,
        "Plex",
        "--analysis_and_elaboration",
        "--read_settings_files=on",
        "--write_settings_files=off",
        f"--verilog_macro=PRESENT_BEAM_960=1",
        f"--verilog_macro=FRAME_W=960",
        f"--verilog_macro=FRAME_H=540",
        f"--verilog_macro=DDR_FRAME_STORE=1",
    ]
    proc = subprocess.run(
        cmd,
        cwd=PROJECT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=os.environ.copy(),
    )
    log = work / "quartus_map_elab.log"
    log.write_text(proc.stdout)
    return proc.returncode, proc.stdout


def main() -> int:
    print("CASE present_beam_fit_elab EXECUTED")
    missing = check_qip()
    if missing:
        print(
            "FAIL files.qip missing SYSTEMVERILOG_FILE entries: " + ", ".join(missing),
            file=sys.stderr,
        )
        print("QIP_BEAM_MISS")
        return REJECT
    print("PASS qip_lists_beam_rtl " + " ".join(REQUIRED_QIP))

    # Red path: if someone deletes beam from disk but leaves qip, discover fails later.
    for rel in REQUIRED_QIP:
        p = PROJECT / rel
        if not p.is_file():
            print(f"FAIL missing source file {rel}", file=sys.stderr)
            return REJECT

    probe = subprocess.run(
        [str(ROOT / "scripts" / "run_verilator.sh"), "--version"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if probe.returncode == 127:
        print(f"VERILATOR_MISS(exit={VERILATOR_MISS}): not installed", file=sys.stderr)
        return VERILATOR_MISS
    if probe.returncode != 0:
        print(probe.stdout, file=sys.stderr)
        return probe.returncode

    print("FIT_MACROS " + " ".join(FIT_MACROS))
    print("Verilator: " + probe.stdout.strip())
    rc, out = run_verilator_fit_elab()
    (ROOT / "build").mkdir(exist_ok=True)
    (ROOT / "build" / "present_beam_fit_elab.log").write_text(out)
    owned = {
        "fpga/Plex_MiSTer/rtl/present_beam_content_de.sv",
        "fpga/Plex_MiSTer/rtl/present_core.sv",
        "fpga/Plex_MiSTer/rtl/present_content_window.sv",
        "fpga/Plex_MiSTer/rtl/present_video_timing_960.sv",
        "fpga/Plex_MiSTer/Plex.sv",
    }
    errors, _ign = rtl_lint.reportable_errors(out, owned)
    # Also catch bare module-not-found for beam
    if "present_beam_content_de" in out and re.search(
        r"%Error.*present_beam_content_de|Cannot find.*present_beam_content_de|Unknown module",
        out,
    ):
        errors.append("beam module resolution error — see build/present_beam_fit_elab.log")

    if rc != 0 and not errors:
        # Non-zero without owned errors: still fail if beam mentioned as missing
        if re.search(r"%Error", out):
            # pull first few errors globally for visibility
            for line in out.splitlines():
                if line.startswith("%Error"):
                    errors.append(line)
                    if len(errors) >= 15:
                        break

    if errors:
        print("FAIL VERILATOR_FIT_ELAB under PRESENT_BEAM_960:", file=sys.stderr)
        for e in errors[:30]:
            print(f"  {e}", file=sys.stderr)
        return REJECT

    print("PASS verilator_fit_elab PRESENT_BEAM_960 FRAME_W=960 FRAME_H=540")

    # Quartus A&E when available (optional unless REQUIRE_QUARTUS_ELAB=1)
    qrc, qout = run_quartus_analysis()
    require_q = os.environ.get("REQUIRE_QUARTUS_ELAB", "0") == "1"
    if qrc == QUARTUS_MISS:
        msg = "quartus_map absent — Verilator fit-elab only"
        if require_q:
            print(f"FAIL {msg}", file=sys.stderr)
            return QUARTUS_MISS
        print(f"SKIP_QUARTUS_AE {msg}")
    elif qrc != 0:
        print("FAIL quartus_map --analysis_and_elaboration:", file=sys.stderr)
        print(qout[-4000:], file=sys.stderr)
        return REJECT
    else:
        print("PASS quartus_analysis_and_elaboration PRESENT_BEAM_960")

    print("OK present_beam_fit_elab")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
