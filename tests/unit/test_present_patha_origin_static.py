#!/usr/bin/env python3
"""Path A on origin/main: content_window + store PPC ports + P720 consume.

POSITIVE:
  - present_core instantiates present_content_window
  - ddr_frame_store has PX_PER_CLK + rd_r_n + yuv_bt601_npx
  - both include plex_720p_bw_contract.svh (not qip-only)

NEGATIVE:
  - Inline STORE_X_SCALE mul in present_core (window owns map)
  - qip lists contract without RTL include
  - scalar replicate pattern {PPC{fr}} if MULTI appears
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
STORE = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
QIP = ROOT / "fpga/Plex_MiSTer/files.qip"
WIN = ROOT / "fpga/Plex_MiSTer/rtl/present_content_window.sv"
NPX = ROOT / "fpga/Plex_MiSTer/rtl/yuv_bt601_npx.sv"
SVH = ROOT / "fpga/Plex_MiSTer/rtl/plex_720p_bw_contract.svh"


def fail(msg: str) -> int:
    print(f"FAIL patha_origin: {msg}", file=sys.stderr)
    return 1


def strip_comments(t: str) -> str:
    t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    t = re.sub(r"//.*", "", t)
    return t


def main() -> int:
    for p in (CORE, STORE, QIP, WIN, NPX, SVH):
        if not p.is_file():
            return fail(f"missing {p.relative_to(ROOT)}")

    core = CORE.read_text(encoding="utf-8", errors="replace")
    store = STORE.read_text(encoding="utf-8", errors="replace")
    qip = QIP.read_text(encoding="utf-8", errors="replace")
    c = strip_comments(core)
    s = strip_comments(store)

    if "present_content_window" not in c:
        return fail("present_core must instantiate present_content_window")
    if "u_content_window" not in c:
        return fail("present_core missing u_content_window instance")
    print("OK present: content_window instance")

    # NEGATIVE: present must not keep legacy inline STORE_X_SCALE map
    if re.search(r"localparam\s+int\s+STORE_X_SCALE\s*=", c):
        return fail("NEGATIVE: present_core still has inline STORE_X_SCALE (window owns map)")
    if "store_x_prod" in c:
        return fail("NEGATIVE: present_core still has store_x_prod inline map")
    print("OK NEGATIVE: no inline STORE_X_SCALE / store_x_prod")

    if "parameter int PX_PER_CLK" not in store and "parameter int PX_PER_CLK" not in s:
        return fail("ddr_frame_store missing PX_PER_CLK")
    if "rd_r_n" not in s:
        return fail("ddr_frame_store missing rd_r_n")
    if "yuv_bt601_npx" not in s:
        return fail("ddr_frame_store must instantiate yuv_bt601_npx for N-wide")
    print("OK store: PX_PER_CLK + rd_r_n + yuv_bt601_npx")

    if 'include "plex_720p_bw_contract.svh"' not in store.replace("`", ""):
        if "plex_720p_bw_contract.svh" not in store:
            return fail("ddr_frame_store must `include plex_720p_bw_contract.svh")
    if "plex_720p_bw_contract.svh" not in core:
        return fail("present_core must `include plex_720p_bw_contract.svh")
    if "p720_bw_contract_ok" not in s and "p720_present_contract_ok" not in c:
        return fail("P720 contract must have noprune consumer in store or present")
    print("OK P720 contract consumed in RTL (not qip-only)")

    if "plex_720p_bw_contract.svh" not in qip:
        return fail("files.qip must list plex_720p_bw_contract.svh")
    if "present_content_window.sv" not in qip:
        return fail("files.qip must list present_content_window.sv")
    if "yuv_bt601_npx.sv" not in qip:
        return fail("files.qip must list yuv_bt601_npx.sv")
    print("OK files.qip lists Path A modules")

    # NEGATIVE twin: if MULTI npx appears, forbid scalar replicate
    if re.search(r"mp_npx_r\s*=\s*\{PRESENT_PPC\{fr\}\}", c):
        return fail("NEGATIVE: mp_npx_r replicates scalar fr")
    print("OK NEGATIVE: no {PPC{fr}} replicate")

    npx = NPX.read_text(encoding="utf-8", errors="replace")
    if "src_x0 + X_W'(li)" not in npx and "src_x0+" not in npx.replace(" ", ""):
        return fail("yuv_bt601_npx must index lane i at src_x0+i")
    print("OK yuv_bt601_npx lane i = src_x0+i")

    # M10K claim locked in source comments (0 for mapper / npx extract)
    win = WIN.read_text(encoding="utf-8", errors="replace")
    if "0 M10K" not in win:
        return fail("present_content_window must state 0 M10K V1 cost in header")
    print("OK content_window documents 0 M10K V1 (UNVERIFIED by fit — comment only)")

    print("PASS test_present_patha_origin_static")
    return 0


if __name__ == "__main__":
    sys.exit(main())
