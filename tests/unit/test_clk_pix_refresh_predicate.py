#!/usr/bin/env python3
"""Hard PASS/FAIL predicate for refresh measure — pure arithmetic control.

fps_eff = clk_pix / (H_TOTAL * V_TOTAL)
COMPACT: H=1650 V=750 → period=1_237_500

  20e6 / 1_237_500 = 16.1616... → fps_x10 ≈ 162
  29.7e6 / 1_237_500 = 24.000   → fps_x10 = 240

PASS band [230,250] must include 240 and exclude 162.
FAIL trap [150,170] must include 162 and exclude 240.
"""
from __future__ import annotations

H, V = 1650, 750
PERIOD = H * V
assert PERIOD == 1_237_500

def fps(clk: float) -> float:
    return clk / PERIOD

def fps_x10(clk: float) -> int:
    return int(round(fps(clk) * 10))

PASS_LO, PASS_HI = 230, 250
TRAP_LO, TRAP_HI = 150, 170

def pred_pass(x10: int) -> bool:
    return PASS_LO <= x10 <= PASS_HI

def pred_trap(x10: int) -> bool:
    return TRAP_LO <= x10 <= TRAP_HI

def main() -> int:
    x24 = fps_x10(29_700_000)
    x16 = fps_x10(20_000_000)
    print(f"arith 29.7e6 → fps={fps(29_700_000):.4f} fps_x10={x24}")
    print(f"arith 20.0e6 → fps={fps(20_000_000):.4f} fps_x10={x16}")
    fails = []
    if x24 != 240:
        fails.append(f"29.7 MHz must be exactly 24.000 Hz (x10=240), got {x24}")
    if not (161 <= x16 <= 162):
        fails.append(f"20 MHz trap x10 expected 161-162, got {x16}")
    if not pred_pass(x24):
        fails.append("PASS predicate must accept 240")
    if pred_pass(x16):
        fails.append("PASS predicate must REJECT 16.16 (x10~162) — NEGATIVE")
    if not pred_trap(x16):
        fails.append("TRAP predicate must catch 162")
    if pred_trap(x24):
        fails.append("TRAP predicate must not fire on 240")
    # margin: gap between bands
    gap = PASS_LO - TRAP_HI
    print(f"band gap trap_hi={TRAP_HI} pass_lo={PASS_LO} gap={gap}")
    if gap < 50:
        fails.append("bands too close")
    if fails:
        for f in fails:
            print("FAIL:", f)
        return 1
    print("PASS test_clk_pix_refresh_predicate: 24 PASS / 16.16 FAIL with margin")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
