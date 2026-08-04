#!/usr/bin/env python3
"""Predicate bands: product 24.242 vs exact-24 vs 16.16 trap."""
H, V = 1650, 750
PPF = H * V  # 1_237_500
assert PPF == 1_237_500

def fps(clk: float) -> float:
    return clk / PPF

def fps_x10_period(sys_hz: float, period: float) -> int:
    return int((sys_hz * 10) / period)

PASS_LO, PASS_HI = 241, 244
EXACT_LO, EXACT_HI = 238, 240
TRAP_LO, TRAP_HI = 150, 170
SYS = 20_000_000

def main() -> int:
    fails = []
    # Product 30 MHz
    f242 = fps(30_000_000)
    p242 = SYS / f242
    x242 = fps_x10_period(SYS, p242)
    print(f"product 30e6 → fps={f242:.6f} period={p242:.1f} fps_x10={x242}")
    # Exact 24
    f240 = 24.0
    p240 = SYS / f240
    x240 = fps_x10_period(SYS, p240)
    print(f"exact 24.0 → period={p240:.1f} fps_x10={x240}")
    # Trap 20 MHz
    f162 = fps(20_000_000)
    p162 = SYS / f162
    x162 = fps_x10_period(SYS, p162)
    print(f"trap 20e6 → fps={f162:.6f} period={p162:.1f} fps_x10={x162}")

    if not (PASS_LO <= x242 <= PASS_HI):
        fails.append(f"product x10 {x242} not in PASS [{PASS_LO},{PASS_HI}]")
    if not (EXACT_LO <= x240 <= EXACT_HI):
        fails.append(f"exact24 x10 {x240} not in EXACT [{EXACT_LO},{EXACT_HI}]")
    if not (TRAP_LO <= x162 <= TRAP_HI):
        fails.append(f"trap x10 {x162} not in TRAP [{TRAP_LO},{TRAP_HI}]")
    # Separation
    if x242 == x240:
        fails.append("product and exact24 must differ in fps_x10")
    if abs(x242 - x240) < 1:
        fails.append("need ≥1 x10 unit separation 242 vs 240")
    if PASS_LO <= x240 <= PASS_HI:
        fails.append("exact24 must NOT fall in product PASS band")
    if PASS_LO <= x162 <= PASS_HI:
        fails.append("trap must NOT fall in product PASS band")
    # Illegal 29.7 arithmetic still exact-24 rate but not product PLL
    f297 = fps(29_700_000)
    print(f"illegal 29.7e6 would give fps={f297:.6f} (exact 24) — PLL rejected")
    if abs(f297 - 24.0) > 1e-9:
        fails.append("29.7e6/PPF must be exact 24")

    if fails:
        for f in fails:
            print("FAIL", f)
        return 1
    print("PASS test_clk_pix_refresh_predicate: 242 PASS / 240 EXACT / 162 TRAP separated")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
