#!/usr/bin/env python3
"""Route B content-DE pixel budget vs host 1280 tier (rd-duck BLOCKING).

Contract (parent + w-clock, Route B PRODUCT):
  - Core beam is TRUE content DE at clk_sys=20 MHz, 1 pixel/clk
  - ascal upscales glass to 1280×720 — glass is NOT content DE
  - PRESENT_BEAM_960 first-fit: FRAME <= 960×540; forbids MULTI_PIXEL combo
  - present_beam_content_de clamps: H_TOTAL >= H_DE+32, V_TOTAL >= V_ACT+16

rd-duck: w-path auto TranscodeHd720 → store/request 1280×720 for source>720.
  Active alone 1280*720*24 = 22.118e6 > 20e6.
  With min totals 1312*736 → f_max = 20e6/(1312*736) ≈ 20.712 Hz for BOTH
  24 and 30 classes → silent underspeed / drop on library HD items.

This gate (w-osd cross-lane):
  1) Math: 1280 path RED under Route B 1ppc/20M; 960×540@30 GREEN
  2) This tree must not auto-pin host request/store 1280×720 as content DE
     without PRESENT_MULTI_PIXEL evidence (path defect class)
  3) chrome_cmds must keep CORE_DE 960 and HDMI glass 1280 distinct

Does NOT edit w-path plex_resolve (owner). FAIL here if defect merges onto w-osd.
"""
from __future__ import annotations

import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CLK = 20_000_000.0
HTOT_PAD = 32
VTOT_PAD = 16


def max_fps(h_de: int, v_act: int) -> float:
    htot = h_de + HTOT_PAD
    vtot = v_act + VTOT_PAD
    return CLK / (htot * vtot)


def active_mpix(h_de: int, v_act: int, fps: float) -> float:
    return h_de * v_act * fps


def main() -> int:
    fails = 0

    # --- 1) Budget math (awk-free) ---
    f1280 = max_fps(1280, 720)
    f960 = max_fps(960, 540)
    print(
        f"budget clk={CLK:.0f} min_blank H+{HTOT_PAD} V+{VTOT_PAD} "
        f"fmax_1280x720={f1280:.3f} fmax_960x540={f960:.3f}"
    )
    # Observation that must FAIL under Route B if someone claims 1280@24 ok:
    if f1280 >= 24.0 - 1e-9:
        print(
            f"FAIL Route-B: 1280x720 min-total fmax={f1280:.3f} >= 24 — "
            "budget model too loose or pad wrong",
            file=sys.stderr,
        )
        fails += 1
    else:
        print(f"OK 1280x720 fmax={f1280:.3f} < 24 (cannot sustain film class)")

    if f1280 >= 30.0 - 1e-9:
        print(f"FAIL 1280x720 fmax={f1280:.3f} >= 30", file=sys.stderr)
        fails += 1
    else:
        print(f"OK 1280x720 fmax={f1280:.3f} < 30 (cannot sustain 30 class either)")

    # Active-only bound (duck 22.118 Mpix/s @24)
    a24 = active_mpix(1280, 720, 24.0)
    if a24 <= CLK:
        print(
            f"FAIL active-only 1280*720*24={a24:.0f} <= clk — duck bound inverted",
            file=sys.stderr,
        )
        fails += 1
    else:
        print(f"OK active 1280*720*24={a24:.0f} > clk={CLK:.0f}")

    a960_30 = active_mpix(960, 540, 30.0)
    if a960_30 > CLK:
        print(
            f"FAIL 960*540*30={a960_30:.0f} > clk — max tier should fit Route B",
            file=sys.stderr,
        )
        fails += 1
    else:
        print(f"OK 960*540*30 active={a960_30:.0f} <= clk")

    # Product H_TOTAL=1182 V_TOTAL=564 @960×540 → ~30.00
    f_prod_960 = CLK / (1182 * 564)
    if f_prod_960 < 29.5:
        print(
            f"FAIL product 1182x564 f={f_prod_960:.3f} < 29.5 (tier broken)",
            file=sys.stderr,
        )
        fails += 1
    else:
        print(f"OK product H_TOTAL=1182 V_TOTAL=564 → f={f_prod_960:.3f}")

    # Exact duck number check (20e6/(1312*736))
    duck_f = CLK / (1312 * 736)
    if abs(duck_f - 20.712) > 0.02:
        print(
            f"FAIL duck f_max model 20e6/(1312*736)={duck_f:.3f} (want ~20.712)",
            file=sys.stderr,
        )
        fails += 1
    else:
        print(f"OK duck f_max 20e6/(1312*736)={duck_f:.3f}")

    # --- 2) Host auto 1280 content-DE pin (path defect) must not be on this tree ---
    resolve = ROOT / "arm" / "misterplexd" / "plex_resolve.cpp"
    if resolve.is_file():
        rt = resolve.read_text(encoding="utf-8", errors="replace")
        # Path signature: TranscodeHd720 → request/store 1280
        bad = False
        if "TranscodeHd720" in rt and re.search(
            r"TranscodeHd720[\s\S]{0,400}requestWidth\s*=\s*.*720|1280",
            rt,
        ):
            # tighter: storeWidth = request after 720p profile
            if re.search(
                r"PlayDeliveryRegime::TranscodeHd720[\s\S]{0,600}"
                r"storeWidth\s*=\s*r\.requestWidth",
                rt,
            ) or re.search(r"transcode_hd_720", rt):
                bad = True
        if bad:
            print(
                "FAIL plex_resolve auto TranscodeHd720 pins store/request 1280 "
                "content DE under Route B 1ppc — cap <=960x540 or require "
                "PRESENT_MULTI_PIXEL (owner w-path)",
                file=sys.stderr,
            )
            fails += 1
        else:
            print(
                "OK this tree plex_resolve has no TranscodeHd720→1280 content-DE pin "
                "(path may still carry defect on its branch)"
            )
    else:
        print("NOTE no plex_resolve.cpp on tree")

    # --- 3) chrome plane separation: CORE_DE 960 vs glass 1280 ---
    cmds = ROOT / "host" / "libmisterplex" / "plex_chrome_cmds.hpp"
    if cmds.is_file():
        ct = cmds.read_text(encoding="utf-8", errors="replace")
        if "kCoreDeW" in ct and not re.search(r"kCoreDeW\s*=\s*960", ct):
            print("FAIL kCoreDeW must be 960 under Route B first-fit", file=sys.stderr)
            fails += 1
        elif "kCoreDeW" in ct:
            print("OK kCoreDeW=960")
        if "kHdmiOutW" in ct and not re.search(r"kHdmiOutW\s*=\s*1280", ct):
            print("FAIL kHdmiOutW should remain 1280 glass (post-ascal)", file=sys.stderr)
            fails += 1
        elif "kHdmiOutW" in ct:
            print("OK kHdmiOutW=1280 glass (not content DE)")
        # Refuse conflating glass with storage
        if re.search(r"kStorageW\s*=\s*1280", ct):
            print("FAIL kStorageW=1280 — storage must not be glass under Route B", file=sys.stderr)
            fails += 1
    else:
        print("FAIL missing plex_chrome_cmds.hpp", file=sys.stderr)
        fails += 1

    # --- 4) Optional: if present_core has BEAM_960, must forbid >960 without MULTI ---
    pc = ROOT / "fpga" / "Plex_MiSTer" / "rtl" / "present_core.sv"
    if pc.is_file():
        pt = pc.read_text(encoding="utf-8", errors="replace")
        if "PRESENT_BEAM_960" in pt:
            if "forbids FRAME >960" not in pt and "FRAME_W > 960" not in pt:
                print(
                    "NOTE PRESENT_BEAM_960 present without explicit >960 forbid text "
                    "(w-clock owns; check first-fit on merge)",
                )
            else:
                print("OK present_core BEAM_960 forbids FRAME>960 class")
        else:
            print("NOTE PRESENT_BEAM_960 not on this present_core (clock lane)")

    if fails:
        print(f"FAIL test_route_b_content_de_budget_static fails={fails}", file=sys.stderr)
        return 1
    print("PASS test_route_b_content_de_budget_static")
    return 0


if __name__ == "__main__":
    sys.exit(main())
