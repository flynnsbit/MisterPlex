#!/usr/bin/env python3
"""Predicate: product 24.242 PASS vs trap 16.16 vs exact-24 vs adversarial raster.

rd-duck: VSync/fps alone is insufficient. PASS requires raster_ok which encodes:
  CE/frame=1_237_500, lines=750, CE/line=1650, DE/frame=921_600, DE/line=1280,
  active=720, underrun delta=0, CE≈1.
Adversarial H1375×V900 keeps HT*VT (and fps) but must FAIL raster_ok.
"""
from __future__ import annotations

def band(fps_x10: int) -> str:
    if 241 <= fps_x10 <= 244:
        return "PASS_242"
    if 238 <= fps_x10 <= 240:
        return "EXACT24"
    if 150 <= fps_x10 <= 170:
        return "TRAP_16"
    return "OTHER"

def verdict(fps_x10: int, flags: int) -> str:
    valid = flags & 1
    pix_ok = (flags >> 1) & 1
    fps_ok = (flags >> 2) & 1
    trap = (flags >> 4) & 1
    ce_ok = (flags >> 5) & 1
    de_ok = (flags >> 6) & 1
    raster_ok = (flags >> 7) & 1
    b = band(fps_x10)
    if not valid:
        return "INVALID"
    if b == "PASS_242" and fps_ok and pix_ok and ce_ok and de_ok and raster_ok and not trap:
        return "PASS_242HZ_PRODUCT"
    if b == "PASS_242" and fps_ok and not raster_ok:
        return "FAIL_RASTER_ADVERSARIAL"
    if b == "EXACT24":
        return "EXACT24_NOT_PRODUCT"
    if b == "TRAP_16" or trap:
        return "FAIL_16HZ_TRAP"
    return "UNKNOWN_BAND"

def main() -> int:
    # fps_x10 from period
    sys_hz = 20_000_000
    def fps_x10(period: float) -> int:
        return int((sys_hz * 10) / period)

    p242 = sys_hz / (30_000_000 / (1650 * 750))  # 825000
    p240 = sys_hz / 24.0
    p162 = sys_hz / (20_000_000 / (1650 * 750))

    f242 = fps_x10(p242)
    f240 = fps_x10(p240)
    f162 = fps_x10(p162)
    print(f"product 30e6 → fps={30e6/(1650*750):.6f} period={p242} fps_x10={f242}")
    print(f"exact 24.0 → period={p240:.1f} fps_x10={f240}")
    print(f"trap 20e6 → fps={20e6/(1650*750):.6f} period={p162} fps_x10={f162}")
    print("illegal 29.7e6 would give fps=24.000000 (exact 24) — PLL rejected")
    print(f"adversarial 1375*900={1375*900} == 1650*750={1650*750} (same CE/frame, wrong lines)")

    # flags with all ok bits
    ok = 0b1110_0111  # raster de ce pll fps pix valid — trap=0
    # valid|pix|fps|pll = 0b0000_1111, ce|de|raster = 0b1110_0000 → 0xE7 if pll on
    flags_pass = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 5) | (1 << 6) | (1 << 7)
    flags_no_raster = flags_pass & ~(1 << 7)
    flags_trap = (1 << 0) | (1 << 1) | (1 << 3) | (1 << 4)  # valid pix pll trap

    checks = [
        (f242, flags_pass, "PASS_242HZ_PRODUCT"),
        (f240, flags_pass, "EXACT24_NOT_PRODUCT"),
        (f162, flags_trap, "FAIL_16HZ_TRAP"),
        (f242, flags_no_raster, "FAIL_RASTER_ADVERSARIAL"),
    ]
    bad = 0
    for fx, fl, want in checks:
        got = verdict(fx, fl)
        okb = got == want
        print(f"{'OK' if okb else 'FAIL'} fps_x10={fx} flags=0x{fl:02x} → {got} (want {want})")
        if not okb:
            bad = 1
    # Negative: PASS must not accept missing raster
    if verdict(f242, flags_no_raster) == "PASS_242HZ_PRODUCT":
        print("FAIL NEG: PASS must require raster_ok")
        bad = 1
    else:
        print("OK NEG: PASS requires raster_ok (adversarial rejected)")

    if bad:
        print("FAIL test_clk_pix_refresh_predicate")
        return 1
    print("PASS test_clk_pix_refresh_predicate: 242 PASS / 240 EXACT / 162 TRAP / ADV raster separated")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
