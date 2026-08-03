#!/usr/bin/env python3
"""Sweep 480p-era geometry hardcodes on the present path.

Inventory is evidence: each row is file:line + literal + meaning + on_720p_path.
Structural gates:
  - Template/FBAR keeps H_DE=529 / V_STORE=240 (default-off product behaviour).
  - L4 ifdef branch must NOT localparam H_DE=529 (negative: leftover hardcode).
  - L4 content_window STORE_W/H and DE defaults derive from FRAME_*/L4_*.
  - Product QSF stays FRAME 640×480 with PLEX_PRESENT_720P_L4 commented.

Prediction (pre-registered before full count): 18–25 sites total, ~8–12 on 720p path.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PRESENT_CORE = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
GEOM_MUX = ROOT / "fpga/Plex_MiSTer/rtl/plex_present_geom_mux.sv"
CONTENT_WIN = ROOT / "fpga/Plex_MiSTer/rtl/present_content_window.sv"
PLEX_SV = ROOT / "fpga/Plex_MiSTer/Plex.sv"
PLEX_QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"
LAYOUT = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh"

# Pre-registered prediction (parent task). Published miss is computed at end.
PRED_TOTAL_MIN, PRED_TOTAL_MAX = 18, 25
PRED_ON720_MIN, PRED_ON720_MAX = 8, 12


def die(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def ok(msg: str) -> None:
    print(f"OK  {msg}")


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace")


def l4_content_window_params(core: str) -> str:
    """Parameter #() block of u_content_window (L4 store-map)."""
    m = re.search(
        r"present_content_window\s*#\s*\((.*?)\)\s*u_content_window",
        core,
        re.S,
    )
    if not m:
        die("u_content_window instance missing in present_core.sv")
    return m.group(1)


def main() -> int:
    core = read(PRESENT_CORE)
    mux = read(GEOM_MUX)
    win = read(CONTENT_WIN)
    plex = read(PLEX_SV)
    qsf = read(PLEX_QSF)
    layout = read(LAYOUT)

    # ---- Inventory table (measured) ----
    # on_720p_path: True if the literal is elaborated / used when L4 is enabled.
    rows: list[tuple[str, str, str, bool]] = []

    def add(path: Path, lit: str, meaning: str, on720: bool, pat: str | None = None) -> None:
        text = read(path) if path != PRESENT_CORE else core
        if path == GEOM_MUX:
            text = mux
        elif path == CONTENT_WIN:
            text = win
        elif path == PLEX_SV:
            text = plex
        elif path == LAYOUT:
            text = layout
        rx = pat or re.escape(lit)
        m = re.search(rx, text)
        if not m:
            die(f"inventory miss: {path.name} missing {lit!r}")
        line = text.count("\n", 0, m.start()) + 1
        rows.append((f"{path.relative_to(ROOT)}:{line}", lit, meaning, on720))

    # present_core — Template-only (NOT on 720p path after branch split)
    add(PRESENT_CORE, "10'd529", "Template FBAR H_DE (colorbars)", False, r"localparam\s+H_DE\s*=\s*10'd529")
    add(PRESENT_CORE, "10'd240", "Template V_STORE (scandouble domain)", False, r"localparam\s+V_STORE\s*=\s*10'd240")
    add(PRESENT_CORE, "39647", "Template store_x mul-shift scale num", False)
    add(PRESENT_CORE, "/ 320", "Template STORE_X_SCALE denom (legacy 320 store)", False, r"\*\s*39647\)\s*/\s*320")
    add(PRESENT_CORE, "/ 240", "Template STORE_Y_SCALE denom", False, r"\*\s*65536\)\s*/\s*240")
    add(PRESENT_CORE, "py >= 10'd240", "Template past_last_row G-VID1", False, r"past_last_row\s*=\s*\(py\s*>=\s*10'd240\)")
    add(PRESENT_CORE, "10'd239", "Template last store row clamp", False, r"past_last_row\s*\?\s*10'd239")

    # present_core — L4 path (ON 720p)
    add(PRESENT_CORE, "1280", "L4_H_DE content active width", True, r"localparam\s+int\s+L4_H_DE\s*=\s*1280")
    add(PRESENT_CORE, "720", "L4_V_ACT content active height", True, r"localparam\s+int\s+L4_V_ACT\s*=\s*720")
    add(PRESENT_CORE, "1312", "L4_H_TOTAL beam", True, r"localparam\s+int\s+L4_H_TOTAL\s*=\s*1312")
    add(PRESENT_CORE, "762", "L4_V_TOTAL beam", True, r"localparam\s+int\s+L4_V_TOTAL\s*=\s*762")
    add(PRESENT_CORE, "STORE_W(FRAME_W)", "L4 store width derives from FRAME_W", True)
    add(PRESENT_CORE, "STORE_H(FRAME_H)", "L4 store height derives from FRAME_H", True)
    add(
        PRESENT_CORE,
        "DDR_FRAME_720P_YUV420P_BANK_STRIDE",
        "L4 DDR bank stride via dual-header (1.5 MiB)",
        True,
        r"FS_BANK_STRIDE\s*=\s*DDR_FRAME_720P_YUV420P_BANK_STRIDE",
    )

    # content_window defaults (params; L4 overrides STORE/DE via present_core)
    add(CONTENT_WIN, "STORE_W = 1280", "default param store W (720p-ready)", True, r"parameter\s+int\s+STORE_W\s*=\s*1280")
    add(CONTENT_WIN, "STORE_H = 720", "default param store H (720p-ready)", True, r"parameter\s+int\s+STORE_H\s*=\s*720")
    add(CONTENT_WIN, "H_DE_DEFAULT = 529", "default param Template DE (legacy win_enable=0)", False, r"parameter\s+int\s+H_DE_DEFAULT\s*=\s*529")
    add(CONTENT_WIN, "/ 320", "legacy STORE_X_SCALE denom (win_enable=0)", False, r"\*\s*39647\)\s*/\s*320")

    # geom mux native fallbacks (ON 720p when FABRIC_NATIVE_720P_GEOM)
    add(GEOM_MUX, "11'd1280", "force_native_720p content/DE width", True, r"force_native_720p\s*\?\s*11'd1280")
    add(GEOM_MUX, "11'd720", "force_native_720p content/DE height", True, r"force_native_720p\s*\?\s*11'd720")
    add(GEOM_MUX, "11'd640", "720p chroma stride W/2", True, r"force_native_720p\s*\?\s*11'd640")
    add(GEOM_MUX, "11'd640 : 11'd320", "O[4] ladder content width base", False, r"content_res_640x480\s*\?\s*11'd640\s*:\s*11'd320")
    add(GEOM_MUX, "11'd480 : 11'd240", "O[4] ladder content height base", False, r"content_res_640x480\s*\?\s*11'd480\s*:\s*11'd240")

    # Plex.sv content ladder (default-off product path)
    add(PLEX_SV, "10'd640", "content_width when res_640x480", False, r"content_res_640x480\s*\?\s*10'd640\s*:\s*10'd320")
    add(PLEX_SV, "10'd480", "content_height when res_640x480", False, r"content_res_640x480\s*\?\s*10'd480\s*:\s*10'd240")

    # dual-header bank / beam (ON 720p when host/core select 720p layout)
    add(
        LAYOUT,
        "32'h0018_0000",
        "720p bank stride constant",
        True,
        r"DDR_FRAME_720P_YUV420P_BANK_STRIDE\s*=\s*32'h0018_0000",
    )
    add(LAYOUT, "1312", "720p24 beam H_TOTAL", True, r"DDR_FRAME_720P24_BEAM_H_TOTAL\s*=\s*1312")
    add(LAYOUT, "762", "720p24 beam V_TOTAL", True, r"DDR_FRAME_720P24_BEAM_V_TOTAL\s*=\s*762")

    print("=== HARDCODE INVENTORY (measured) ===")
    print(f"{'file:line':<52} {'literal':<22} {'on720':<6} meaning")
    for loc, lit, meaning, on720 in rows:
        print(f"{loc:<52} {lit:<22} {str(on720):<6} {meaning}")

    total = len(rows)
    on720 = sum(1 for *_, o in rows if o)
    print(f"COUNT total={total} on_720p_path={on720}")
    print(
        f"PREDICTION was total={PRED_TOTAL_MIN}-{PRED_TOTAL_MAX} "
        f"on720={PRED_ON720_MIN}-{PRED_ON720_MAX}"
    )
    if PRED_TOTAL_MIN <= total <= PRED_TOTAL_MAX:
        print("PREDICTION total: HIT")
    else:
        print(f"PREDICTION total: MISS (measured {total})")
    if PRED_ON720_MIN <= on720 <= PRED_ON720_MAX:
        print("PREDICTION on720: HIT")
    else:
        print(f"PREDICTION on720: MISS (measured {on720})")

    # ---- Structural gates ----
    cw_params = l4_content_window_params(core)
    cw_code = "\n".join(
        ln for ln in cw_params.splitlines() if not ln.strip().startswith("//")
    )
    # NEGATIVE: L4 must not pass Template H_DE=529 into content_window.
    if re.search(r"H_DE_DEFAULT\s*\(\s*529\s*\)", cw_code) or re.search(
        r"H_DE_DEFAULT\s*\(\s*10'd529\s*\)", cw_code
    ):
        die("NEGATIVE: L4 content_window H_DE_DEFAULT still 529")
    ok("L4 content_window H_DE_DEFAULT is not Template 529")

    if "STORE_W(FRAME_W)" not in cw_params or "STORE_H(FRAME_H)" not in cw_params:
        die("L4 content_window must derive STORE_W/H from FRAME_*")
    ok("L4 STORE_W/H derive from FRAME_W/FRAME_H")

    if "H_DE_DEFAULT(L4_H_DE)" not in cw_params or "V_DE_DEFAULT(L4_V_ACT)" not in cw_params:
        die("L4 must pass L4_H_DE/L4_V_ACT as content_window defaults")
    ok("L4 H_DE_DEFAULT/V_DE_DEFAULT from L4_*")

    # Template branch must retain G-VID1 anchors (default behaviour)
    if "localparam H_DE    = 10'd529" not in core:
        die("Template H_DE=529 missing — default FBAR path broken")
    if "past_last_row = (py >= 10'd240)" not in core:
        die("Template past_last_row G-VID1 anchor missing")
    ok("Template H_DE=529 / past_last_row G-VID1 retained")

    # Product default-off
    if re.search(r'^[^#]*PLEX_PRESENT_720P_L4=1', qsf, re.M):
        die("PLEX_PRESENT_720P_L4 active in product QSF")
    if not re.search(r'^set_global_assignment -name VERILOG_MACRO "FRAME_W=640"', qsf, re.M):
        die("FRAME_W!=640 in product QSF")
    if not re.search(r'^set_global_assignment -name VERILOG_MACRO "FRAME_H=480"', qsf, re.M):
        die("FRAME_H!=480 in product QSF")
    ok("product QSF default-off FRAME 640×480, L4 commented")

    # Dual-geometry contract: 720p H_DE must not equal Template 529
    # (mirrors present_geom_dual_tb negative)
    if "L4_H_DE    = 1280" not in core and "L4_H_DE = 1280" not in core:
        # allow spacing variants already matched via inventory
        if not re.search(r"L4_H_DE\s*=\s*1280", core):
            die("L4_H_DE != 1280")
    if re.search(r"L4_H_DE\s*=\s*529", core):
        die("NEGATIVE fail: L4_H_DE hardcoded to 529")
    ok("L4_H_DE=1280 and not 529 (negative hardcode rejected)")

    print("PASS test_present_hardcode_sweep")
    return 0


if __name__ == "__main__":
    sys.exit(main())
