#!/usr/bin/env python3
"""Static gates for clk_pix CDC (dedicated PLL async). No fit."""
from __future__ import annotations
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NPX = ROOT / "fpga/Plex_MiSTer/rtl/present_npx_path.sv"
CORE = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
PLEX = ROOT / "fpga/Plex_MiSTer/Plex.sv"
QIP = ROOT / "fpga/Plex_MiSTer/files.qip"
SDC = ROOT / "fpga/Plex_MiSTer/Plex_clk_pix_cdc.sdc"
SYNC = ROOT / "fpga/Plex_MiSTer/rtl/cdc_sync_bit.sv"
PULSE = ROOT / "fpga/Plex_MiSTer/rtl/cdc_pulse_toggle.sv"
INV = ROOT / "docs/cdc-clk-pix-crossings.md"

def die(msg: str) -> None:
    print(f"FAIL {msg}", file=sys.stderr)
    sys.exit(1)

def main() -> int:
    for p in (NPX, CORE, PLEX, QIP, SDC, SYNC, PULSE, INV):
        if not p.is_file():
            die(f"missing {p}")

    npx = NPX.read_text(encoding="utf-8")
    core = CORE.read_text(encoding="utf-8")
    plex = PLEX.read_text(encoding="utf-8")
    qip = QIP.read_text(encoding="utf-8")
    sdc = SDC.read_text(encoding="utf-8")
    sync = SYNC.read_text(encoding="utf-8")

    # Product prefill uses cdc_sync_bit, not bare assign
    if "cdc_sync_bit" not in npx:
        die("present_npx_path must instantiate cdc_sync_bit for prefill_go")
    if "u_prefill_go_sync" not in npx:
        die("missing u_prefill_go_sync instance")
    if "async_fifo" not in npx:
        die("present_npx_path must use async_fifo for multi-bit groups")
    # FAULT default off in product present_core
    if not re.search(r"FAULT_NO_PREFILL_SYNC\s*\(\s*1'b0\s*\)", core):
        die("present_core must set FAULT_NO_PREFILL_SYNC(1'b0)")
    # Preserve on sync chain
    if "preserve" not in sync:
        die("cdc_sync_bit must mark preserve on chain")

    # frame_start pulse CDC under CLK_PIX_PLL
    if "cdc_pulse_toggle" not in core or "u_mp_fstart_cdc" not in core:
        die("present_core must CDC mp_out_fs via cdc_pulse_toggle when CLK_PIX_PLL")

    # CLK_VIDEO same domain as CE_PIXEL under MULTI+PLL
    if "PRESENT_MULTI_PIXEL" not in plex or "clk_pix_pll" not in plex:
        die("Plex.sv must gate CLK_VIDEO to clk_pix_pll under MULTI+PLL")
    # Must not unconditionally assign CLK_VIDEO = clk_sys only
    if re.search(r"assign\s+CLK_VIDEO\s*=\s*clk_sys\s*;", plex) and \
       "PRESENT_CLK_PIX_PLL" not in plex.split("CLK_VIDEO")[0][-200:]:
        # allow clk_sys arms inside ifdefs; require ifdef near CLK_VIDEO
        blk = plex[plex.find("CLK_VIDEO")-400:plex.find("CLK_VIDEO")+200]
        if "PRESENT_CLK_PIX_PLL" not in blk:
            die("CLK_VIDEO must be ifdef-gated for clk_pix")

    # QIP uses # comments for new lines (TCL)
    if "cdc_sync_bit.sv" not in qip or "cdc_pulse_toggle.sv" not in qip:
        die("files.qip must list cdc_*.sv")
    for line in qip.splitlines():
        if "cdc_sync_bit" in line and line.strip().startswith("//"):
            die("files.qip cdc line must not use // comment style alone")

    # SDC: max_delay present, no blanket false_path on RGB
    if "set_max_delay" not in sdc:
        die("Plex_clk_pix_cdc.sdc must use set_max_delay on handshake data")
    for line in sdc.splitlines():
        s = line.split("#", 1)[0].strip()
        if not s.startswith("set_false_path"):
            continue
        if "CE_PIXEL" in s or "VGA_" in s:
            die("must not false_path CE_PIXEL/VGA data")
        if "u_mp_npx_path" in s and "mem" in s:
            die("must not false_path npx fifo data plane")

    # Inventory exhaustive marker
    inv = INV.read_text(encoding="utf-8")
    for key in ("P1 ", "P2 ", "P3 ", "P4 ", "P5 ", "file:line", "NOT multi-bit bit-sync"):
        if key not in inv:
            die(f"inventory missing '{key}'")

    print("PASS test_clk_pix_cdc_static")
    return 0

if __name__ == "__main__":
    sys.exit(main())
