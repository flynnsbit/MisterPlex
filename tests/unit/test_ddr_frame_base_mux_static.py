#!/usr/bin/env python3
"""Static gates for ddr_frame_base_mux product identity + store integration.

GREEN:
  - module in files.qip; default DYN_BASE_EN=0
  - fixed equation is bank ? base_w1 : base_w0 (matches former store L737 shape)
  - ddr_frame_store instances u_fill_base_mux with BASE_W0/W1 and DYN_BASE_EN param
  - product default DYN_BASE_EN=0 on store (parameter default)
  - no top-level keep-alive with zeroed bases (that was dark)

RED:
  - missing store instance fails
  - store still using inline fill_bank ? BASE_W1 : BASE_W0 wire fails (must be mux)
  - DYN_BASE_EN default 1 fails
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MUX = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_base_mux.sv"
STORE = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
PLEX = ROOT / "fpga/Plex_MiSTer/Plex.sv"
QIP = ROOT / "fpga/Plex_MiSTer/files.qip"


def main() -> int:
    mux = MUX.read_text(encoding="utf-8", errors="replace")
    store = STORE.read_text(encoding="utf-8", errors="replace")
    plex = PLEX.read_text(encoding="utf-8", errors="replace")
    qip = QIP.read_text(encoding="utf-8", errors="replace")

    if "ddr_frame_base_mux.sv" not in qip:
        print("FAIL: not in files.qip", file=sys.stderr)
        return 1
    if "module ddr_frame_base_mux" not in mux:
        print("FAIL: module missing", file=sys.stderr)
        return 1
    if not re.search(r"parameter\s+bit\s+DYN_BASE_EN\s*=\s*1'b0", mux):
        print("FAIL: mux default DYN_BASE_EN must be 0", file=sys.stderr)
        return 1

    # Mux fixed equation shape (former store L737)
    if not re.search(r"fixed_base\s*=\s*bank\s*\?\s*base_w1\s*:\s*base_w0", mux):
        print("FAIL: mux fixed_base must be bank ? base_w1 : base_w0", file=sys.stderr)
        return 1
    if not re.search(r"assign\s+fill_bank_base\s*=\s*fixed_base", mux):
        print("FAIL: g_fixed must assign fill_bank_base = fixed_base", file=sys.stderr)
        return 1

    # Store must OWN the mux (real path), not keep inline wire
    if "u_fill_base_mux" not in store or "ddr_frame_base_mux" not in store:
        print("FAIL: ddr_frame_store must instance u_fill_base_mux", file=sys.stderr)
        return 1
    if not re.search(r"\.base_w0\(\s*BASE_W0\s*\)", store):
        print("FAIL: store mux must take BASE_W0", file=sys.stderr)
        return 1
    if not re.search(r"\.base_w1\(\s*BASE_W1\s*\)", store):
        print("FAIL: store mux must take BASE_W1", file=sys.stderr)
        return 1
    if not re.search(r"\.bank\(\s*fill_bank\s*\)", store):
        print("FAIL: store mux bank must be fill_bank", file=sys.stderr)
        return 1
    # Product default parameter on store
    if not re.search(r"parameter\s+bit\s+DYN_BASE_EN\s*=\s*1'b0", store):
        print("FAIL: store DYN_BASE_EN default must be 0", file=sys.stderr)
        return 1

    # RED: inline equation must be GONE (replaced by mux)
    if re.search(
        r"wire\s*\[28:0\]\s*fill_bank_base\s*=\s*fill_bank\s*\?\s*BASE_W1\s*:\s*BASE_W0",
        store,
    ):
        print(
            "FAIL: store still has inline fill_bank_base equation; must use mux",
            file=sys.stderr,
        )
        return 1

    # Top-level keep-alive with dummy bases must not return (dark silicon pattern)
    if re.search(r"u_frame_base_mux", plex) and re.search(
        r"\.base_w0\(\s*29'd0\s*\)", plex
    ):
        print("FAIL: Plex still has zeroed keep-alive base mux (dark)", file=sys.stderr)
        return 1

    print(
        "PASS ddr_frame_base_mux static | mux DYN=0 | "
        "store u_fill_base_mux BASE_W0/W1 fill_bank | "
        "no inline L737 wire | no dark keep-alive | "
        "PREREG_ALM=0..4 PREREG_M10K=0"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
