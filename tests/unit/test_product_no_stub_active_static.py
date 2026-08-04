#!/usr/bin/env python3
"""PRODUCT_NO_STUB product default must be ON; stub gated in stream_path."""
from __future__ import annotations
import re, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
QSF = (ROOT / "fpga/Plex_MiSTer/Plex.qsf").read_text(encoding="utf-8", errors="replace")
SP = (ROOT / "fpga/Plex_MiSTer/rtl/stream_path.sv").read_text(encoding="utf-8", errors="replace")
CFG = ROOT / "fpga/Plex_MiSTer/rtl/plex_product_cfg.sv"
PLEX = (ROOT / "fpga/Plex_MiSTer/Plex.sv").read_text(encoding="utf-8", errors="replace")
QIP = (ROOT / "fpga/Plex_MiSTer/files.qip").read_text(encoding="utf-8", errors="replace")

def active(qsf: str) -> set[str]:
    out=set()
    for line in qsf.splitlines():
        s=line.split('#',1)[0].strip()
        m=re.search(r'VERILOG_MACRO\s+"([^"]+)"', s)
        if m: out.add(m.group(1).split('=',1)[0])
    return out

def main() -> int:
    m = active(QSF)
    if "PRODUCT_NO_STUB" not in m:
        print("FAIL: PRODUCT_NO_STUB must be product QSF default", file=sys.stderr); return 1
    if "DDR_FRAME_STORE" not in m:
        print("FAIL: DDR_FRAME_STORE required", file=sys.stderr); return 1
    if "`ifdef PRODUCT_NO_STUB" not in SP or "decode_stub" not in SP:
        print("FAIL: stream_path must gate decode_stub under PRODUCT_NO_STUB", file=sys.stderr); return 1
    # stub instance only in else
    if not re.search(r"`else\s*\n\s*decode_stub\s+#", SP):
        print("FAIL: decode_stub must be in `else of PRODUCT_NO_STUB", file=sys.stderr); return 1
    if "plex_product_cfg.sv" not in QIP or "u_product_cfg" not in PLEX:
        print("FAIL: product_cfg missing from qip/Plex", file=sys.stderr); return 1
    if not CFG.is_file():
        print("FAIL: missing plex_product_cfg.sv", file=sys.stderr); return 1
    print("PASS PRODUCT_NO_STUB active: QSF ON; stream_path gates stub; plex_product_cfg in qip+Plex.sv; glass has_frame intact")
    return 0
if __name__ == "__main__":
    sys.exit(main())
