#!/usr/bin/env python3
"""Option-b fabric present paths — static gates (rd-duck corrected).

PREFERRED: ddr_frame_base_mux (dynamic-base direct reader). M10K=0.
  Fabric READs decode buffer in place; no source→bank mover traffic.
  ABI for publishing the base is w-mem (not this gate).

SECONDARY: ddr_frame_dma (source→bank copy). Demoted.
  Retires uncached publication memcpy ONLY after pinned contig/SG +
  cache-coherency contract. Software decode/rawvideo still WRITES pixels.
  Adds full R+W payload vs present-only R on dyn-base path.

GREEN product default:
  - FABRIC_FRAME_DMA absent from QSF
  - both modules in files.qip
  - base_mux live inside ddr_frame_store as u_fill_base_mux (DYN_BASE_EN default 0)
  - PRODUCT_NO_STUB remains on
  - T_ideal_dma << T_copy_arm (arithmetic only; not a free-core claim)

RED:
  - FABRIC_FRAME_DMA on product QSF fails
  - missing base_mux / dma files fail
  - missing store u_fill_base_mux fails

NOT claimed here (rd-duck): free core during decode; ARM never touches pixels.
"""
from __future__ import annotations

import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"
QIP = ROOT / "fpga/Plex_MiSTer/files.qip"
DMA = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_dma.sv"
MUX = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_base_mux.sv"
STORE = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
CFG = ROOT / "fpga/Plex_MiSTer/rtl/plex_product_cfg.sv"
PLEX = ROOT / "fpga/Plex_MiSTer/Plex.sv"

FRAME_BYTES_720P = 1_382_400
FPS = 24
R_REQ_MB_S = FRAME_BYTES_720P * FPS / 1e6
T_COPY_ARM_MS = 14.978
CLK_DDR_HZ = 90e6
BYTES_PER_BEAT = 8
BOUNCE_DEPTH = 8  # MAX_BURST=8 (legal ≤ quantum); was 128 pre-rd-duck NACK
NOSTUB_RECLAIM_M10K = 268
BOUNCE_BYTES = BOUNCE_DEPTH * BYTES_PER_BEAT
# Cyclone V M10K max width 40b — 64b port is NOT native. bits/10240 is NOT a
# legal cost. Fit control (nostub-poststrip1): line_buf_ram DATA_W=64 → 2 M10K.
# Bounce 8×64 same width class → 2 EST.
PREREG_BOUNCE_M10K = 2
PREREG_MUX_M10K = 0  # pure mux
assert PREREG_BOUNCE_M10K == 2, "corrected cost must be 2"


def active_macros(qsf: str) -> set[str]:
    out: set[str] = set()
    for line in qsf.splitlines():
        s = line.split("#", 1)[0].strip()
        m = re.search(r'VERILOG_MACRO\s+"([^"]+)"', s)
        if m:
            out.add(m.group(1).split("=", 1)[0])
    return out


def main() -> int:
    qsf = QSF.read_text(encoding="utf-8", errors="replace")
    qip = QIP.read_text(encoding="utf-8", errors="replace")
    dma = DMA.read_text(encoding="utf-8", errors="replace") if DMA.is_file() else ""
    mux = MUX.read_text(encoding="utf-8", errors="replace") if MUX.is_file() else ""
    store = STORE.read_text(encoding="utf-8", errors="replace") if STORE.is_file() else ""
    plex = PLEX.read_text(encoding="utf-8", errors="replace")
    macros = active_macros(qsf)

    if "FABRIC_FRAME_DMA" in macros:
        print("FAIL: FABRIC_FRAME_DMA must NOT be product QSF default", file=sys.stderr)
        return 1
    if not DMA.is_file() or "module ddr_frame_dma" not in dma:
        print("FAIL: missing ddr_frame_dma.sv", file=sys.stderr)
        return 1
    if not MUX.is_file() or "module ddr_frame_base_mux" not in mux:
        print("FAIL: missing ddr_frame_base_mux.sv (preferred path)", file=sys.stderr)
        return 1
    if "ddr_frame_dma.sv" not in qip or "ddr_frame_base_mux.sv" not in qip:
        print("FAIL: dma/base_mux not in files.qip", file=sys.stderr)
        return 1
    # Live path: mux inside store (not a top-level keep-alive with zeroed bases)
    if "u_fill_base_mux" not in store or "ddr_frame_base_mux" not in store:
        print("FAIL: store must instance u_fill_base_mux", file=sys.stderr)
        return 1
    if not re.search(r"parameter\s+bit\s+DYN_BASE_EN\s*=\s*1'b0", store):
        print("FAIL: store DYN_BASE_EN default must be 0", file=sys.stderr)
        return 1
    if not re.search(r"\.base_w0\(\s*BASE_W0\s*\)", store) or not re.search(
        r"\.base_w1\(\s*BASE_W1\s*\)", store
    ):
        print("FAIL: store mux must wire BASE_W0/W1", file=sys.stderr)
        return 1
    if re.search(r"u_frame_base_mux", plex) and re.search(
        r"\.base_w0\(\s*29'd0\s*\)", plex
    ):
        print("FAIL: dark keep-alive base mux still in Plex.sv", file=sys.stderr)
        return 1
    if "PRODUCT_NO_STUB" not in macros:
        print("FAIL: PRODUCT_NO_STUB must remain product default", file=sys.stderr)
        return 1
    cfg = CFG.read_text(encoding="utf-8", errors="replace")
    if "fabric_frame_dma_en" not in cfg:
        print("FAIL: cfg stamp missing fabric_frame_dma_en", file=sys.stderr)
        return 1
    # Integration wire: dma + arbiter3 under FABRIC_FRAME_DMA (default OFF)
    if "u_frame_dma" not in plex or "ddr_bus_arbiter3" not in plex:
        print("FAIL: Plex.sv must wire u_frame_dma + ddr_bus_arbiter3 under FABRIC_FRAME_DMA",
              file=sys.stderr)
        return 1
    if "ddr_bus_arbiter3.sv" not in qip:
        print("FAIL: ddr_bus_arbiter3.sv not in files.qip", file=sys.stderr)
        return 1
    if "M10K" not in dma and "m10k" not in dma.lower():
        print("FAIL: ddr_frame_dma must state M10K cost in header", file=sys.stderr)
        return 1
    # Layout-aware cost must appear (reject retracted bits/10240 "1 M10K" claim)
    if not re.search(r"\b2\s*M10K\b", dma):
        print("FAIL: ddr_frame_dma header must state 2 M10K (64b width-bound)", file=sys.stderr)
        return 1
    if "f2sdram_safe_terminator" not in dma and "not to break the transaction" not in dma:
        print("FAIL: dma must cite f2sdram no-break-burst contract", file=sys.stderr)
        return 1
    if "MAX_BURST" not in dma:
        print("FAIL: dma must parameterize MAX_BURST", file=sys.stderr)
        return 1
    if "fabric_dma_store_kick" not in plex:
        print("FAIL: Plex must separate store kick from status[12] under FABRIC_FRAME_DMA", file=sys.stderr)
        return 1
    if re.search(r"8192 bits → \*\*1 M10K", dma) or re.search(
        r"DEPTH=128 → 8192 bits → \*\*1 M10K", dma
    ):
        print("FAIL: retracted 1-M10K bits/10240 claim still present", file=sys.stderr)
        return 1

    # Preferred path documents direct reader vs mover
    if "source" not in mux.lower():
        print("FAIL: base_mux must document contrast vs source→bank DMA", file=sys.stderr)
        return 1

    qwords = FRAME_BYTES_720P // BYTES_PER_BEAT
    t_ideal_dma_ms = 2.0 * qwords / CLK_DDR_HZ * 1e3  # R+W mover
    t_ideal_present_r_ms = 1.0 * qwords / CLK_DDR_HZ * 1e3  # direct reader: present R only
    if t_ideal_dma_ms >= T_COPY_ARM_MS:
        print(f"FAIL: dma ideal {t_ideal_dma_ms:.3f} not < T_copy_arm", file=sys.stderr)
        return 1
    if PREREG_BOUNCE_M10K > NOSTUB_RECLAIM_M10K:
        print("FAIL: bounce exceeds nostub reclaim", file=sys.stderr)
        return 1

    # RED twin
    red = qsf + '\nset_global_assignment -name VERILOG_MACRO "FABRIC_FRAME_DMA=1"\n'
    if "FABRIC_FRAME_DMA" not in active_macros(red):
        print("FAIL: red twin broken", file=sys.stderr)
        return 1

    print(
        "PASS option_b static | preferred=store.u_fill_base_mux m10k=0 DYN=0 | "
        f"secondary=dma bounce_m10k={PREREG_BOUNCE_M10K} | "
        f"R_req={R_REQ_MB_S:.4f}MB/s | T_copy_arm={T_COPY_ARM_MS}ms | "
        f"T_ideal_dma_RW={t_ideal_dma_ms:.3f}ms | T_ideal_present_R={t_ideal_present_r_ms:.3f}ms | "
        f"nostub_reclaim_m10k={NOSTUB_RECLAIM_M10K} | "
        "NOT_CLAIMED=free_core_during_decode;arm_never_touches_pixels"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
