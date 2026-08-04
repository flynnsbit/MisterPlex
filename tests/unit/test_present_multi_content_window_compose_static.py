#!/usr/bin/env python3
"""Compose gate: MULTI/L4 content_window must drive store map (not Template orphan).

Negative cases a naive wrong implementation fails:
  1) MULTI still comments that fstore is wired to Template store_x
  2) L4 hardwires win_enable(1'b1) instead of runtime port
  3) Plex ties content_w=0 under MULTI (geom hierarchy missing)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
PLEX = ROOT / "fpga/Plex_MiSTer/Plex.sv"
QIP = ROOT / "fpga/Plex_MiSTer/files.qip"


def fail(msg: str) -> int:
    print(f"FAIL compose: {msg}", file=sys.stderr)
    return 1


def main() -> int:
    core = CORE.read_text(encoding="utf-8")
    plex = PLEX.read_text(encoding="utf-8")
    qip = QIP.read_text(encoding="utf-8")

    # --- NEGATIVE 1: Template-hc orphan must be gone ---
    if "fstore still wired to store_x/y from Template" in core:
        return fail(
            "NEGATIVE: MULTI still admits Template store_x orphan "
            "(compose incomplete)"
        )
    if "full MULTI\n\t// store remap is a follow-up" in core:
        return fail("NEGATIVE: MULTI store remap still deferred")

    # --- POSITIVE: MULTI instantiates content_window on glass ---
    if "u_mp_content_window" not in core:
        return fail("MULTI missing u_mp_content_window instance")
    if not re.search(r"\.hc\s*\(\s*mp_glass_x0", core):
        return fail("MULTI content_window must take mp_glass_x0 as hc")
    # integ names fs_rd_*_w (path compose); accept either while landing.
    if not re.search(r"assign\s+fs_rd_x(_w)?\s*=\s*mp_win_x", core):
        return fail("fs_rd_x(_w) must be driven by mp_win_x under MULTI")
    if not re.search(r"assign\s+fs_vsync_(pulse|w)\s*=\s*mp_fstart", core):
        return fail("MULTI bank swap must track mp_fstart not Template fstart")
    print("OK MULTI: content_window on glass → fs_rd_*")

    # --- NEGATIVE 2: L4 must not hardwire win_enable ---
    # Match L4 instance region roughly
    l4 = core
    if re.search(r"u_content_window\s*\([\s\S]*?\.win_enable\s*\(\s*1'b1\s*\)", l4):
        return fail("NEGATIVE: L4 content_window hardwires win_enable(1'b1)")
    if not re.search(
        r"u_content_window\s*\([\s\S]*?\.win_enable\s*\(\s*win_enable\s*\)", l4
    ):
        return fail("L4 content_window must take runtime win_enable port")
    if not re.search(r"\.content_x0\s*\(\s*content_x0\s*\)", core):
        return fail("L4 must pass content_x0 port (not hardwired 0 only)")
    print("OK L4: runtime win_enable/content_x0 ports")

    # Fabric full-DE when win_enable (not shrink-to-content)
    if "beam_hde_req  = win_enable ? 11'(L4_H_DE)" not in core.replace(" ", ""):
        # allow spaced form
        if "win_enable ? 11'(L4_H_DE)" not in core and 'win_enable ? 11\'(L4_H_DE)' not in core:
            if "win_enable ? 11'(L4_H_DE)" not in core:
                # broader
                if not re.search(r"beam_hde_req\s*=\s*win_enable\s*\?\s*11'\(L4_H_DE\)", core):
                    return fail("L4 beam must stay full DE when win_enable (fabric scale)")
    print("OK L4: win_enable keeps full DE for fabric scale")

    # --- 720p ABI for MULTI (integ: ddr_frame_abi_select.svh) ---
    # FRAME 1280×720 selects 720p bank for L4 *or* MULTI (not L4-only ifdef).
    abi = (ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_abi_select.svh").read_text(
        encoding="utf-8"
    )
    if "DDR_FS_USE_720P_ABI" not in abi and "FS_USE_720P_ABI" not in core:
        return fail("missing DDR_FS_USE_720P_ABI / FS_USE_720P_ABI")
    multi_via_frame = (
        "PRESENT_MULTI_PIXEL" in abi
        and re.search(
            r"DDR_FS_USE_720P_ABI\s*=\s*\(FRAME_W\s*==\s*1280\s*&&\s*FRAME_H\s*==\s*720\)",
            abi,
        )
    )
    multi_via_core = re.search(
        r"PRESENT_MULTI_PIXEL[\s\S]{0,200}FS_USE_720P_ABI\s*=\s*\(FRAME_W\s*==\s*1280",
        core,
    )
    if not multi_via_frame and not multi_via_core:
        return fail("MULTI@1280x720 must select 720p DDR ABI (FRAME_W/H gate)")
    # NEGATIVE: L4-only gate would leave MULTI on 624×480 (rd-duck)
    if re.search(
        r"DDR_FS_USE_720P_ABI\s*=\s*1'b1", abi
    ) and "PLEX_PRESENT_720P_L4" in abi and "PRESENT_MULTI_PIXEL" not in abi:
        return fail("NEGATIVE: 720p ABI must not be L4-only")
    print("OK ABI: MULTI@1280×720 → 720p bank")    # --- Plex wires ---
    if "PLEX_PRESENT_GEOM_HIER" not in plex:
        return fail("Plex must elaborate geom hierarchy under MULTI too")
    if not re.search(r"`elsif\s+PRESENT_MULTI_PIXEL", plex):
        return fail("Plex present_core inst missing MULTI window port arm")
    if plex.count(".win_enable(present_win_enable)") < 1:
        return fail("Plex must drive present.win_enable from geom mux")
    print("OK Plex: geom hierarchy + window ports for L4/MULTI")

    # --- present_core ports exist ---
    for port in ("win_enable", "content_x0", "content_y0", "win_h_de", "win_v_de"):
        if not re.search(rf"input\s+wire\s+.*\b{port}\b", core):
            return fail(f"present_core missing input port {port}")
    print("OK present_core window ports")

    # --- nn scaler in qip (leaf; not product-instantiated to avoid empty M10K) ---
    if "present_nn_linebuf_scaler.sv" not in qip:
        return fail("nn linebuf must remain in files.qip")
    if "u_nn_linebuf_keep" in core:
        return fail("do not noprune-instantiate empty nn linebuf (wastes M10K)")
    print("OK nn linebuf: qip leaf, no empty product instance")

    print("PASS test_present_multi_content_window_compose_static")
    return 0


if __name__ == "__main__":
    sys.exit(main())
