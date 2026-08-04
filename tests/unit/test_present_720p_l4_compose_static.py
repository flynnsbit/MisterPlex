#!/usr/bin/env python3
"""L4 host↔RTL composition gate (w-nostub compose lane).

Proves the 720p tier constants and present_core FS_* bind form a single contract
with host plex720pDdrFrameStoreLayout / kPlex720p*, without enabling L4 in the
default QSF (fitgate owns the candidate enable).

Negative case: a naive 480p doorbell or phys base on the 720p tier must fail.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOST = ROOT / "host/libmisterplex/ddr_frame_layout.hpp"
RTL = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh"
PRESENT = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"
PARITY = ROOT / "scripts/check_define_parity.py"


def fail(msg: str) -> None:
    print(f"FAIL {msg}", file=sys.stderr)
    raise SystemExit(1)


def ok(msg: str) -> None:
    print(f"OK {msg}")


def parse_int_token(raw: str) -> int:
    s = raw.strip().strip('"').replace("_", "")
    s = re.sub(r"[uUlL]+$", "", s)
    m = re.fullmatch(r"(?:\d+)?'([hHdDbBoO])([0-9a-fA-F]+)", s)
    if m:
        base = {"h": 16, "H": 16, "d": 10, "D": 10, "b": 2, "B": 2, "o": 8, "O": 8}[m.group(1)]
        return int(m.group(2), base)
    if re.fullmatch(r"0[xX][0-9a-fA-F]+", s):
        return int(s, 16)
    if re.fullmatch(r"-?\d+", s):
        return int(s, 10)
    raise ValueError(raw)


def host_consts(text: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for m in re.finditer(
        r"constexpr\s+(?:\w+\s+)+(kPlex720p\w+)\s*(?:=\s*([^;]+);|\{\s*([^}]+)\s*\}\s*;)",
        text,
    ):
        raw = m.group(2) if m.group(2) is not None else m.group(3)
        try:
            out[m.group(1)] = parse_int_token(raw)
        except ValueError:
            continue
    return out


def rtl_consts(text: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for m in re.finditer(r"localparam\s+int\s+(DDR_FRAME_720P_[A-Z0-9_]+)\s*=\s*([^;]+);", text):
        out[m.group(1)] = parse_int_token(m.group(2))
    return out


PAIRS = [
    ("kPlex720pCodedWidth", "DDR_FRAME_720P_CODED_WIDTH"),
    ("kPlex720pCodedHeight", "DDR_FRAME_720P_CODED_HEIGHT"),
    ("kPlex720pDisplayWidth", "DDR_FRAME_720P_DISPLAY_WIDTH"),
    ("kPlex720pDisplayHeight", "DDR_FRAME_720P_DISPLAY_HEIGHT"),
    ("kPlex720pPresentedWidth", "DDR_FRAME_720P_PRESENTED_WIDTH"),
    ("kPlex720pPresentedHeight", "DDR_FRAME_720P_PRESENTED_HEIGHT"),
    ("kPlex720pYStrideBytes", "DDR_FRAME_720P_Y_STRIDE_BYTES"),
    ("kPlex720pChromaStrideBytes", "DDR_FRAME_720P_CHROMA_STRIDE_BYTES"),
    ("kPlex720pYuv420pBytes", "DDR_FRAME_720P_YUV420P_BYTES"),
    ("kPlex720pYPlaneOffset", "DDR_FRAME_720P_Y_PLANE_OFFSET"),
    ("kPlex720pUPlaneOffset", "DDR_FRAME_720P_U_PLANE_OFFSET"),
    ("kPlex720pVPlaneOffset", "DDR_FRAME_720P_V_PLANE_OFFSET"),
    ("kPlex720pYuvLumaLineQwords", "DDR_FRAME_720P_YUV_LUMA_LINE_QWORDS"),
    ("kPlex720pYuvChromaLineQwords", "DDR_FRAME_720P_YUV_CHROMA_LINE_QWORDS"),
    ("kPlex720pYuv420pBankStride", "DDR_FRAME_720P_YUV420P_BANK_STRIDE"),
    ("kPlex720pPhysBase", "DDR_FRAME_720P_PHYS_BASE"),
    ("kPlex720pYuv420pDoorbellPhys", "DDR_FRAME_720P_YUV420P_DOORBELL_PHYS"),
]


def main() -> int:
    host_t = HOST.read_text(errors="ignore")
    rtl_t = RTL.read_text(errors="ignore")
    present_t = PRESENT.read_text(errors="ignore")
    qsf_t = QSF.read_text(errors="ignore")
    parity_t = PARITY.read_text(errors="ignore")

    h = host_consts(host_t)
    r = rtl_consts(rtl_t)

    for hn, rn in PAIRS:
        if hn not in h:
            fail(f"host missing {hn}")
        if rn not in r:
            fail(f"rtl missing {rn}")
        if h[hn] != r[rn]:
            fail(f"compose VALUE-DIFF {hn}={h[hn]} != {rn}={r[rn]}")
    ok(f"host/RTL 720p pairs shared ({len(PAIRS)})")

    # Geometry arithmetic (identity I420).
    if h["kPlex720pCodedWidth"] != 1280 or h["kPlex720pCodedHeight"] != 720:
        fail("L4 coded must be 1280x720")
    y = h["kPlex720pCodedWidth"] * h["kPlex720pCodedHeight"]
    if h["kPlex720pUPlaneOffset"] != y or h["kPlex720pVPlaneOffset"] != y + y // 4:
        fail("720p plane offsets must be Y then U then V contiguous I420")
    if h["kPlex720pYuv420pBytes"] != y * 3 // 2:
        fail("720p frame bytes must be coded*1.5")
    expect_db = h["kPlex720pPhysBase"] + 2 * h["kPlex720pYuv420pBankStride"] - 0x1000
    if h["kPlex720pYuv420pDoorbellPhys"] != expect_db:
        fail(f"doorbell {h['kPlex720pYuv420pDoorbellPhys']:#x} != {expect_db:#x}")
    if h["kPlex720pPhysBase"] == 0x30000000:
        fail("L4 phys must not collapse onto 480p base 0x30000000")
    if h["kPlex720pYuv420pDoorbellPhys"] == 0x300FF000:
        fail("L4 doorbell must not collapse onto 480p 0x300FF000")
    ok("720p plane/doorbell/phys arithmetic")

    # Host composition API present.
    for needle in (
        "plex720pDdrFrameGeometry()",
        "plex720pDdrFrameStoreLayout()",
        "ddrFrameLayoutMatchesL4Silicon(",
        "MISTERPLEX_PRODUCT_720P_L4",
        "productDdrFrameStoreLayout()",
    ):
        if needle not in host_t:
            fail(f"host missing composition API {needle!r}")
    ok("host L4 composition APIs")

    # present_core L4 FS bind uses named 720p params (not bare 0 crop literals only).
    present_raw = re.sub(r"\s+", "", present_t)
    for needle in (
        "FS_CODED_W=DDR_FRAME_720P_CODED_WIDTH",
        "FS_PHYS_BASE=DDR_FRAME_720P_PHYS_BASE",
        "FS_DOORBELL=DDR_FRAME_720P_YUV420P_DOORBELL_PHYS",
        "FS_BANK_STRIDE=DDR_FRAME_720P_YUV420P_BANK_STRIDE",
        "FS_CROP_LEFT=DDR_FRAME_720P_CROP_LEFT",
        "FS_CROP_TOP=DDR_FRAME_720P_CROP_TOP",
        "ifdefPLEX_PRESENT_720P_L4",
    ):
        if needle not in present_raw:
            fail(f"present_core missing L4 bind {needle}")
    ok("present_core FS_* L4 bind")

    # Default product QSF still 480p (compose must not force L4 on).
    if 'VERILOG_MACRO "FRAME_W=640"' not in qsf_t or 'VERILOG_MACRO "FRAME_H=480"' not in qsf_t:
        fail("default QSF must keep FRAME 640x480 (L4 is opt-in)")
    if re.search(
        r'^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"PLEX_PRESENT_720P_L4=1"',
        qsf_t,
        re.M,
    ):
        fail("PLEX_PRESENT_720P_L4 must stay commented default-off (fitgate enables candidate)")
    ok("QSF default-off L4 (480p product intact)")

    # define-parity knows 720p pairs.
    if "DDR_LAYOUT_720P_PAIRS" not in parity_t or "kPlex720pPhysBase" not in parity_t:
        fail("check_define_parity.py must pair kPlex720p* ↔ DDR_FRAME_720P_*")
    if "kPlex720p" not in parity_t:
        fail("host layout parser must include kPlex720p*")
    ok("define-parity 720p pairs present")

    # --- Negative twins (naive wrong composition must fail this gate) ---
    bad_db = rtl_t.replace(
        "DDR_FRAME_720P_YUV420P_DOORBELL_PHYS = 32'h3047_F000",
        "DDR_FRAME_720P_YUV420P_DOORBELL_PHYS = 32'h300F_F000",  # 480p doorbell
    )
    if "32'h300F_F000" not in bad_db:
        fail("negative twin setup: could not inject 480p doorbell into 720p tier")
    bad_r = rtl_consts(bad_db)
    if bad_r.get("DDR_FRAME_720P_YUV420P_DOORBELL_PHYS") == h["kPlex720pYuv420pDoorbellPhys"]:
        fail("negative twin did not change doorbell")
    if bad_r["DDR_FRAME_720P_YUV420P_DOORBELL_PHYS"] == h["kPlex720pYuv420pDoorbellPhys"]:
        fail("negative: 480p doorbell twin still matches host (gate worthless)")
    # Simulate pair check
    if bad_r["DDR_FRAME_720P_YUV420P_DOORBELL_PHYS"] != h["kPlex720pYuv420pDoorbellPhys"]:
        ok("negative twin: 480p doorbell on 720p tier would VALUE-DIFF (gate red)")
    else:
        fail("negative twin failed to diverge")

    bad_phys_host = host_t.replace(
        "constexpr uint32_t kPlex720pPhysBase = 0x30180000u;",
        "constexpr uint32_t kPlex720pPhysBase = 0x30000000u;",
    )
    bad_h = host_consts(bad_phys_host)
    if bad_h.get("kPlex720pPhysBase") == r["DDR_FRAME_720P_PHYS_BASE"]:
        fail("negative twin phys collapse still matches RTL")
    ok("negative twin: 480p phys on kPlex720pPhysBase would VALUE-DIFF")

    print("PASS present_720p_l4_compose_static: host↔RTL L4 contract + default-off + negatives")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
