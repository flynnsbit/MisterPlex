#!/usr/bin/env python3
"""Host↔RTL 720p product composition (w-nostub on integ/720p-compose).

When QSF FRAME_W/H=1280x720, fabric uses DDR_FS_USE_720P_ABI (phys 0x30180000).
Host misterplexd must build with MISTERPLEX_PRODUCT_DDR_720P=1 or it still
publishes 480p @ 0x30000000 — black/shear, not “almost 720p”.

Positive: plane/qword/phys pairs; host APIs; Makefile daemon flag; abi crop names.
Negative: 480p doorbell on 720p tier; missing daemon product flag when QSF is 720p.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOST = ROOT / "host/libmisterplex/ddr_frame_layout.hpp"
RTL = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh"
ABI = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_abi_select.svh"
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"
MAKE = ROOT / "Makefile"


def fail(msg: str) -> None:
    print(f"FAIL {msg}", file=sys.stderr)
    raise SystemExit(1)


def ok(msg: str) -> None:
    print(f"OK {msg}")


def parse_int(raw: str) -> int:
    s = raw.strip().strip('"').replace("_", "")
    s = re.sub(r"[uUlL]+$", "", s)
    m = re.fullmatch(r"(?:\d+)?'([hHdDbBoO])([0-9a-fA-F]+)", s)
    if m:
        base = {"h": 16, "H": 16, "d": 10, "D": 10, "b": 2, "B": 2, "o": 8, "O": 8}[m.group(1)]
        return int(m.group(2), base)
    if re.fullmatch(r"0[xX][0-9a-fA-F]+", s):
        return int(s, 16)
    return int(s, 10)


def host_720(text: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for m in re.finditer(
        r"constexpr\s+(?:\w+\s+)+(kPlex720p\w+)\s*(?:=\s*([^;]+);|\{\s*([^}]+)\s*\}\s*;)",
        text,
    ):
        raw = m.group(2) if m.group(2) is not None else m.group(3)
        try:
            out[m.group(1)] = parse_int(raw)
        except ValueError:
            continue
    return out


def rtl_720(text: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for m in re.finditer(r"localparam\s+int\s+(DDR_FRAME_720P_[A-Z0-9_]+)\s*=\s*([^;]+);", text):
        out[m.group(1)] = parse_int(m.group(2))
    return out


PAIRS = [
    ("kPlex720pCodedWidth", "DDR_FRAME_720P_CODED_WIDTH"),
    ("kPlex720pUPlaneOffset", "DDR_FRAME_720P_U_PLANE_OFFSET"),
    ("kPlex720pVPlaneOffset", "DDR_FRAME_720P_V_PLANE_OFFSET"),
    ("kPlex720pYuvLumaLineQwords", "DDR_FRAME_720P_YUV_LUMA_LINE_QWORDS"),
    ("kPlex720pYuvChromaLineQwords", "DDR_FRAME_720P_YUV_CHROMA_LINE_QWORDS"),
    ("kPlex720pPhysBase", "DDR_FRAME_720P_PHYS_BASE"),
    ("kPlex720pYuv420pDoorbellPhys", "DDR_FRAME_720P_YUV420P_DOORBELL_PHYS"),
    ("kPlex720pYuv420pBankStride", "DDR_FRAME_720P_YUV420P_BANK_STRIDE"),
]


def main() -> int:
    host_t = HOST.read_text(errors="ignore")
    rtl_t = RTL.read_text(errors="ignore")
    abi_t = ABI.read_text(errors="ignore")
    qsf_t = QSF.read_text(errors="ignore")
    make_t = MAKE.read_text(errors="ignore")

    h, r = host_720(host_t), rtl_720(rtl_t)
    for hn, rn in PAIRS:
        if hn not in h or rn not in r:
            fail(f"missing pair {hn}/{rn}")
        if h[hn] != r[rn]:
            fail(f"VALUE-DIFF {hn}={h[hn]} != {rn}={r[rn]}")
    ok(f"host/RTL pairs ({len(PAIRS)})")

    expect_db = h["kPlex720pPhysBase"] + 2 * h["kPlex720pYuv420pBankStride"] - 0x1000
    if h["kPlex720pYuv420pDoorbellPhys"] != expect_db:
        fail(f"doorbell arithmetic {h['kPlex720pYuv420pDoorbellPhys']:#x} != {expect_db:#x}")
    if h["kPlex720pPhysBase"] == 0x30000000 or h["kPlex720pYuv420pDoorbellPhys"] == 0x300FF000:
        fail("720p phys/doorbell collapsed onto 480p")
    ok("phys/doorbell arithmetic")

    for needle in (
        "plex720pDdrFrameGeometry()",
        "plex720pDdrFrameStoreLayout()",
        "ddrFrameLayoutMatchesL4Silicon(",
        "MISTERPLEX_PRODUCT_DDR_720P",
        "productDdrFrameStoreLayout()",
    ):
        if needle not in host_t:
            fail(f"host missing {needle!r}")
    ok("host composition APIs")

    if "DDR_FRAME_720P_CROP_LEFT" not in abi_t:
        fail("abi_select must use named DDR_FRAME_720P_CROP_LEFT")
    ok("abi_select named 720p crop")

    # QSF active FRAME 1280×720 (integ enable) requires daemon product flag.
    qsf_active = [
        ln
        for ln in qsf_t.splitlines()
        if "VERILOG_MACRO" in ln and not ln.lstrip().startswith("#")
    ]
    fw = any('FRAME_W=1280' in ln for ln in qsf_active)
    fh = any('FRAME_H=720' in ln for ln in qsf_active)
    if fw and fh:
        if "MISTERPLEX_PRODUCT_DDR_720P" not in make_t or "MPLEX_PRODUCT_DDR_FLAGS" not in make_t:
            fail("QSF FRAME 1280x720 but Makefile missing MPLEX_PRODUCT_DDR_FLAGS for misterplexd")
        if not re.search(
            r"\$\(CXX\).*\$\(MPLEX_PRODUCT_DDR_FLAGS\).*misterplexd|MPLEX_PRODUCT_DDR_FLAGS.*misterplexd|"
            r"\$\(CXX\) \$\(CXXFLAGS\) \$\(MPLEX_PRODUCT_DDR_FLAGS\)",
            make_t,
        ):
            # direct check: misterplexd rule uses the flag
            if "MPLEX_PRODUCT_DDR_FLAGS" not in make_t.split("build/misterplexd")[1][:800]:
                fail("misterplexd link line must pass MPLEX_PRODUCT_DDR_FLAGS")
        ok("QSF 720p + Makefile misterplexd PRODUCT_DDR_720P flag")
    else:
        ok("QSF not 720p active — daemon flag not required this tree")

    # Negative: 480p doorbell on 720p RTL tier
    bad = rtl_t.replace(
        "DDR_FRAME_720P_YUV420P_DOORBELL_PHYS = 32'h3047_F000",
        "DDR_FRAME_720P_YUV420P_DOORBELL_PHYS = 32'h300F_F000",
    )
    br = rtl_720(bad)
    if br.get("DDR_FRAME_720P_YUV420P_DOORBELL_PHYS") == h["kPlex720pYuv420pDoorbellPhys"]:
        fail("negative twin did not diverge doorbell")
    ok("negative twin: 480p doorbell on 720p tier VALUE-DIFF")

    # Negative: strip daemon flag while QSF 720p would fail this gate
    if fw and fh:
        make_neg = make_t.replace("MPLEX_PRODUCT_DDR_FLAGS", "MPLEX_PRODUCT_DDR_FLAGS_REMOVED")
        if "MPLEX_PRODUCT_DDR_FLAGS" in make_neg.split("build/misterplexd")[1][:800]:
            fail("negative twin setup failed")
        ok("negative twin: removing MPLEX_PRODUCT_DDR_FLAGS would fail QSF↔host gate")

    print(
        "PASS present_720p_host_compose_static | planes+phys+APIs | "
        "daemon flag when QSF 720p | NEG doorbell/flag | "
        "M10K=0 (headers) | NOT_CLAIMED=refresh_Hz"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
