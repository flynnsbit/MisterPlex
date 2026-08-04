#!/usr/bin/env python3
"""L4 gate: dead modules become INSTANTIATED behind default-off PLEX_PRESENT_720P_L4.

Default product (macro off):
  - PLEX_PRESENT_720P_L4 must NOT be an active QSF macro
  - FRAME_W/H stay 640/480
  - present_core still has colorbars Template path text

When scanning sources (ifdef bodies count as instantiation intent):
  - present_geom_latch, plex_present_geom_mux appear in Plex.sv under L4
  - present_content_window appears in present_core under L4
  - Beam totals 1312×762 and DE 1280×720 are named in present_core L4 path
  - Dual-header 720p24 beam constants match

Negative: dropping u_content_window instance name fails the gate.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"
PLEX = ROOT / "fpga/Plex_MiSTer/Plex.sv"
CORE = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
QIP = ROOT / "fpga/Plex_MiSTer/files.qip"
SVH = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh"
HPP = ROOT / "host/libmisterplex/ddr_frame_layout.hpp"


def active_macros(qsf: str) -> list[str]:
    return re.findall(
        r'^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"([^"]+)"',
        qsf,
        flags=re.M,
    )


def main() -> int:
    qsf = QSF.read_text(errors="ignore")
    plex = PLEX.read_text(errors="ignore")
    core = CORE.read_text(errors="ignore")
    qip = QIP.read_text(errors="ignore")
    svh = SVH.read_text(errors="ignore")
    hpp = HPP.read_text(errors="ignore")
    fails: list[str] = []

    act = active_macros(qsf)
    for m in act:
        if m.startswith("PLEX_PRESENT_720P_L4") or m.startswith("FABRIC_NATIVE_720P_GEOM"):
            fails.append(f"DEFAULT_OFF=no active QSF macro {m}")
    if not any("FRAME_W=640" in m for m in act):
        fails.append("DEFAULT product FRAME_W=640 missing from active QSF")
    if not any("FRAME_H=480" in m for m in act):
        fails.append("DEFAULT product FRAME_H=480 missing from active QSF")
    if not any("PLEX_PRESENT_720P_L4" in line and line.strip().startswith("#") for line in qsf.splitlines()):
        fails.append("QSF missing commented PLEX_PRESENT_720P_L4 enable recipe")
    if not any("FABRIC_NATIVE_720P_GEOM" in line and line.strip().startswith("#") for line in qsf.splitlines()):
        fails.append("QSF missing commented FABRIC_NATIVE_720P_GEOM recipe")
    if not any("FRAME_W=1280" in line and line.strip().startswith("#") for line in qsf.splitlines()):
        fails.append("QSF missing commented FRAME_W=1280 L4 recipe")

    # Instantiation intent (ifdef bodies)
    checks = [
        ("present_geom_latch", "u_plxg_latch" in plex and "present_geom_latch" in plex),
        ("plex_present_geom_mux", "u_present_geom_mux" in plex and "plex_present_geom_mux" in plex),
        ("present_content_window", "u_content_window" in core and "present_content_window" in core),
        (
            "beam_720p24",
            "u_beam_720p24" in core
            and (
                # Legacy localparams or parameterized defaults (same 1312×762)
                ("L4_H_TOTAL = 1312" in core and "L4_V_TOTAL = 762" in core)
                or (
                    "L4_H_TOTAL_P = 1312" in core
                    and "L4_V_TOTAL_P = 762" in core
                    and "L4_H_TOTAL = L4_H_TOTAL_P" in core
                    and "L4_V_TOTAL = L4_V_TOTAL_P" in core
                )
            ),
        ),
        ("PLEX_PRESENT_720P_L4_gate", "`ifdef PLEX_PRESENT_720P_L4" in core and "`ifdef PLEX_PRESENT_720P_L4" in plex),
        ("colorbars_default", "colorbars bars" in core),
    ]
    for name, ok in checks:
        if ok:
            print(f"OK INSTANTIATED_INTENT={name}")
        else:
            fails.append(f"INSTANTIATED_INTENT=no {name}")

    for mod in (
        "present_content_window.sv",
        "present_geom_latch.sv",
        "plex_present_geom_mux.sv",
        "present_beam_content_de.sv",
        "present_video_timing_720p.sv",
    ):
        if f"rtl/{mod}" not in qip:
            fails.append(f"IN_FILES_QIP=no {mod}")
        else:
            print(f"OK IN_FILES_QIP={mod}")

    # Dual-header beam
    for name, val in (
        ("DDR_FRAME_720P24_BEAM_H_TOTAL", "1312"),
        ("DDR_FRAME_720P24_BEAM_V_TOTAL", "762"),
        ("DDR_FRAME_720P24_BEAM_H_DE", "1280"),
        ("DDR_FRAME_720P24_BEAM_V_ACTIVE", "720"),
        ("DDR_FRAME_720P24_CLK_SYS_HZ", "24_000_000"),
    ):
        if name not in svh or val not in svh:
            fails.append(f"svh missing {name}={val}")
    for name, val in (
        ("kPlex720p24BeamHTotal", "1312"),
        ("kPlex720p24BeamVTotal", "762"),
        ("kPlex720p24ClkSysHz", "24000000"),
    ):
        if name not in hpp or val not in hpp:
            fails.append(f"hpp missing {name}={val}")

    # Negative twin: content_window instance must be load-bearing in the gate
    if "u_content_window" in core:
        twin = core.replace(") u_content_window (", ") u_GONE (")
        if "u_content_window" in twin:
            fails.append("negative twin could not rename u_content_window instance")
        else:
            print("OK negative twin: removing u_content_window would fail this gate")

    # Glass DE fixed at L4 full size; content_w feeds window not beam (ascal island bug).
    if "win_content_w" not in core or "win_content_h" not in core:
        fails.append("L4 missing win_content_w/h (content island separate from glass DE)")
    else:
        print("OK L4 win_content_* separates DDR island from glass DE")
    if ".content_w(beam_hde_req)" in core or ".content_h(beam_vact_req)" in core:
        fails.append("L4 still wires content_window from beam_* (identity-only / shrinks DE)")
    else:
        print("OK L4 content_window not driven by beam_* size")

    # Plex.sv L4 must drive present_core from geom_mux, not hardwired 11'd0.
    # Negative: only 11'd0 under L4 → identity-only island (ascal-quarter class).
    m_pres = re.search(
        r"present_core\s+#\s*\(.*?\)\s*present\s*\((.*?)\);",
        plex,
        flags=re.S,
    )
    if not m_pres:
        fails.append("could not locate present_core present(…) instance in Plex.sv")
    else:
        pres = m_pres.group(1)
        if ".content_w(present_content_w)" not in pres:
            fails.append("Plex L4 missing .content_w(present_content_w) on present_core")
        else:
            print("OK Plex L4 .content_w(present_content_w)")
        if ".content_h(present_content_h)" not in pres:
            fails.append("Plex L4 missing .content_h(present_content_h) on present_core")
        else:
            print("OK Plex L4 .content_h(present_content_h)")
        if ".content_x0(present_content_x0)" not in pres:
            fails.append("Plex L4 missing .content_x0(present_content_x0) on present_core")
        else:
            print("OK Plex L4 .content_x0(present_content_x0)")
        if ".content_y0(present_content_y0)" not in pres:
            fails.append("Plex L4 missing .content_y0(present_content_y0) on present_core")
        else:
            print("OK Plex L4 .content_y0(present_content_y0)")
        twin = (
            pres.replace(".content_w(present_content_w)", ".content_w(11'd0)")
            .replace(".content_h(present_content_h)", ".content_h(11'd0)")
        )
        if ".content_w(present_content_w)" in twin:
            fails.append("negative twin could not strip present_content_w wire")
        elif ".content_w(11'd0)" not in twin:
            fails.append("negative twin did not produce hardcoded content_w")
        else:
            print("OK negative twin: hardcoded L4 content_w=0 would fail this gate")
    if ".content_x0(content_x0)" not in core or ".content_y0(content_y0)" not in core:
        fails.append("present_core L4 content_window still hardwires content_x0/y0")
    else:
        print("OK present_core passes content_x0/y0 into content_window")
    if "beam_hde_req  = 11'(L4_H_DE)" not in core and "beam_hde_req = 11'(L4_H_DE)" not in core:
        # tolerate whitespace variants
        if "L4_H_DE)" not in core or "beam_hde_req" not in core:
            fails.append("L4 beam_hde_req not fixed to L4_H_DE")
        else:
            # require assignment not content_w ternary
            m = re.search(r"beam_hde_req\s*=\s*([^;]+);", core)
            if not m or "L4_H_DE" not in m.group(1) or "content_w" in m.group(1):
                fails.append(f"L4 beam_hde_req must be fixed L4_H_DE, got: {m.group(1) if m else 'missing'}")
            else:
                print("OK L4 glass DE fixed to L4_H_DE (not content_w)")
    else:
        print("OK L4 glass DE fixed to L4_H_DE (not content_w)")

    # fps arithmetic check (integer): 24000000 / (1312*762) milli
    pix = 1312 * 762
    fps_milli = (24_000_000 * 1000) // pix
    if fps_milli != 24006:
        fails.append(f"beam fps_milli want 24006 got {fps_milli} (24e6/(1312*762))")
    else:
        print("OK beam arithmetic 24e6/(1312*762) → 24.006 Hz")

    if fails:
        print("FAIL present_720p_l4_static:")
        for f in fails:
            print(" ", f)
        return 1
    print("PASS present_720p_l4_static: L4 instantiate-behind-flag, default-off")
    return 0


if __name__ == "__main__":
    sys.exit(main())
