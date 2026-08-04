#!/usr/bin/env python3
"""PRODUCT_NO_STUB product default gates decode_stub out of stream_path.

GREEN: QSF PRODUCT_NO_STUB=1 + DDR_FRAME_STORE=1; stream_path has ifdef gate;
       plex_product_cfg.sv in qip and instanced in Plex.sv.
RED: QSF without PRODUCT_NO_STUB fails this gate.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"
STREAM = ROOT / "fpga/Plex_MiSTer/rtl/stream_path.sv"
PLEX = ROOT / "fpga/Plex_MiSTer/Plex.sv"
QIP = ROOT / "fpga/Plex_MiSTer/files.qip"
CFG = ROOT / "fpga/Plex_MiSTer/rtl/plex_product_cfg.sv"
PRESENT = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"


def active_macro_names(qsf: str) -> set[str]:
    out: set[str] = set()
    for line in qsf.splitlines():
        s = line.split("#", 1)[0].strip()
        m = re.search(r'VERILOG_MACRO\s+"([^"]+)"', s)
        if not m:
            continue
        out.add(m.group(1).split("=", 1)[0])
    return out


def main() -> int:
    qsf = QSF.read_text(encoding="utf-8", errors="replace")
    stream = STREAM.read_text(encoding="utf-8", errors="replace")
    plex = PLEX.read_text(encoding="utf-8", errors="replace")
    qip = QIP.read_text(encoding="utf-8", errors="replace")
    present = PRESENT.read_text(encoding="utf-8", errors="replace")
    macros = active_macro_names(qsf)

    if "DDR_FRAME_STORE" not in macros:
        print("FAIL: DDR_FRAME_STORE must stay product default", file=sys.stderr)
        return 1
    if "PRODUCT_NO_STUB" not in macros:
        print("FAIL: PRODUCT_NO_STUB must be product QSF default", file=sys.stderr)
        return 1
    if not CFG.is_file():
        print("FAIL: missing rtl/plex_product_cfg.sv", file=sys.stderr)
        return 1
    if "plex_product_cfg.sv" not in qip:
        print("FAIL: plex_product_cfg.sv not in files.qip", file=sys.stderr)
        return 1
    if "plex_product_cfg" not in plex or "u_product_cfg" not in plex:
        print("FAIL: Plex.sv must instance plex_product_cfg", file=sys.stderr)
        return 1
    if "product_cfg_no_stub" not in plex:
        print("FAIL: product_cfg_no_stub must be kept live in Plex.sv", file=sys.stderr)
        return 1

    m = re.search(r"`ifdef\s+PRODUCT_NO_STUB(.*?)`else(.*?)`endif", stream, re.S)
    if not m:
        print("FAIL: stream_path missing PRODUCT_NO_STUB if/else", file=sys.stderr)
        return 1
    if "decode_stub" in m.group(1):
        print("FAIL: decode_stub in PRODUCT_NO_STUB arm", file=sys.stderr)
        return 1
    if "decode_stub" not in m.group(2):
        print("FAIL: decode_stub missing from research else arm", file=sys.stderr)
        return 1
    if not re.search(r"assign\s+fs_wr_en\s*=\s*1'b0", m.group(1)):
        print("FAIL: nostub arm must tie fs_wr_en=0", file=sys.stderr)
        return 1

    pnt = re.sub(r"\s+", "", present)
    if "use_ext=has_frame&&!use_frame_store" not in pnt:
        print("FAIL: glass mux must stay has_frame", file=sys.stderr)
        return 1

    # RED twin: QSF without macro
    red = "\n".join(ln for ln in qsf.splitlines() if "PRODUCT_NO_STUB" not in ln)
    if "PRODUCT_NO_STUB" in active_macro_names(red):
        print("FAIL: red twin still has macro", file=sys.stderr)
        return 1

    print(
        "PASS PRODUCT_NO_STUB active: QSF ON; stream_path gates stub; "
        "plex_product_cfg in qip+Plex.sv; glass has_frame intact"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
