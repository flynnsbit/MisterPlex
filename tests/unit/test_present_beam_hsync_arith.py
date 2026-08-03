#!/usr/bin/env python3
"""Arithmetic twin of rd-duck #1: L4 HSync asserted_cycles.

Models present_beam_content_de rt-mode porch selection.
POS: H_SYNC-relative porches → width 8.
NEG: H_FP=32 defaults only → width 0 (the bug).
"""
from __future__ import annotations
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def hs_width(h_de, h_total, h_fp, h_sw, h_sync_s, h_sync_e, use_rel: bool) -> tuple[int, int, int]:
    if use_rel and h_sync_s >= h_de and h_sync_e > h_sync_s:
        fp = h_sync_s - h_de
        sw = h_sync_e - h_sync_s
    else:
        fp, sw = h_fp, h_sw
    hs_s = h_de + fp
    hs_e = h_de + fp + sw
    w = sum(1 for hc in range(h_total) if hs_s <= hc < hs_e)
    return w, hs_s, hs_e


def main() -> int:
    fails = []

    def check(c, m):
        if not c:
            fails.append(m)
        else:
            print(f"OK {m}")

    # L4 params as present_core
    H_DE, H_TOT = 1280, 1312
    H_SYNC_S, H_SYNC_E = 1288, 1296
    H_FP_DEF, H_SW_DEF = 32, 64

    w_bug, s_bug, e_bug = hs_width(H_DE, H_TOT, H_FP_DEF, H_SW_DEF, H_SYNC_S, H_SYNC_E, False)
    check(w_bug == 0, f"NEG bug model width={w_bug} (want 0) hs={s_bug}..{e_bug}")
    check(s_bug == 1312, f"NEG bug hs_s={s_bug} (==htot → never)")

    w_fix, s_fix, e_fix = hs_width(H_DE, H_TOT, H_FP_DEF, H_SW_DEF, H_SYNC_S, H_SYNC_E, True)
    check(w_fix == 8, f"POS fix width={w_fix} (==8)")
    check(s_fix == 1288 and e_fix == 1296, f"POS fix window {s_fix}..{e_fix}")

    # VSync L4 defaults OK even without rel
    V_ACT, V_TOT = 720, 762
    V_FP, V_SW = 8, 6
    vs_s, vs_e = V_ACT + V_FP, V_ACT + V_FP + V_SW
    vw = sum(1 for v in range(V_TOT) if vs_s <= v < vs_e)
    check(vw == 6, f"VSync lines={vw} (==6) window {vs_s}..{vs_e}")
    check(vs_e <= V_TOT - 1 or vs_e <= V_TOT, "VSync ends inside frame")

    # 320 class
    w320, s320, e320 = hs_width(320, 400, 32, 64, 328, 336, True)
    check(w320 == 8 and s320 == 328, f"320 width={w320} start={s320}")
    w320b, _, _ = hs_width(320, 400, 32, 64, 328, 336, False)
    # defaults 32+64 don't fit: 320+32=352, +64=416 > 400 → partial or 0?
    # hc only to 399: hs_s=352 hs_e=416 → width = 400-352 = 48 (partial clamp by range)
    check(w320b == 48, f"NEG 320 default-FP partial width={w320b} (!=8 exact)")

    # Source must contain H_FP_RT derivation
    beam = (ROOT / "fpga/Plex_MiSTer/rtl/present_beam_content_de.sv").read_text()
    check("H_FP_RT" in beam, "beam RTL defines H_FP_RT")
    check("H_SYNC_REL_OK" in beam, "beam RTL defines H_SYNC_REL_OK")

    if fails:
        print("FAIL:", *fails, sep="\n  ", file=sys.stderr)
        return 1
    print("PASS test_present_beam_hsync_arith")
    return 0


if __name__ == "__main__":
    sys.exit(main())
