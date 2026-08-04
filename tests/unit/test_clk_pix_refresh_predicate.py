#!/usr/bin/env python3
"""Predicate: product exact-24 PASS vs trap 16.16 vs shared-30 24.242 vs adversarial raster.

Product: dedicated pll_pix 29.7 MHz × H1650×V750 → 24.000 Hz → fps_x10=240.
Shared-PLL 30 MHz trap → 24.242 → fps_x10=242 — FAIL_SHARED30 (do not ship).
Trap 20 MHz same-clock → 16.16 → fps_x10≈162.

rd-duck: VSync/fps alone is insufficient. PASS requires raster_ok which encodes:
  CE/frame=1_237_500, lines=750, CE/line=1650, DE/frame=921_600, DE/line=1280,
  active=720, underrun delta=0, CE≈1.
Adversarial H1375×V900 keeps HT*VT (and fps) but must FAIL raster_ok.
"""
from __future__ import annotations


def band(fps_x10: int) -> str:
    if 239 <= fps_x10 <= 241:
        return "PASS_240"
    if 242 <= fps_x10 <= 244:
        return "SHARED30"
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
    if b == "PASS_240" and fps_ok and pix_ok and ce_ok and de_ok and raster_ok and not trap:
        return "PASS_240HZ_PRODUCT"
    if b == "PASS_240" and fps_ok and not raster_ok:
        return "FAIL_RASTER_ADVERSARIAL"
    if b == "SHARED30":
        return "FAIL_SHARED30_TRAP"
    if b == "TRAP_16" or trap:
        return "FAIL_16HZ_TRAP"
    return "UNKNOWN_BAND"


def main() -> int:
    sys_hz = 20_000_000

    def fps_x10(period: float) -> int:
        return int((sys_hz * 10) / period)

    p240 = sys_hz / 24.0
    p242 = sys_hz / (30_000_000 / (1650 * 750))
    p162 = sys_hz / (20_000_000 / (1650 * 750))

    f240 = fps_x10(p240)
    f242 = fps_x10(p242)
    f162 = fps_x10(p162)
    print(f"product 29.7e6 → fps={29.7e6/(1650*750):.6f} period={p240:.1f} fps_x10={f240}")
    print(f"shared30 trap → fps={30e6/(1650*750):.6f} period={p242} fps_x10={f242}")
    print(f"trap 20e6 → fps={20e6/(1650*750):.6f} period={p162} fps_x10={f162}")
    print(f"adversarial 1375*900={1375*900} == 1650*750={1650*750}")

    flags_pass = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 5) | (1 << 6) | (1 << 7)
    flags_no_raster = flags_pass & ~(1 << 7)
    flags_trap = (1 << 0) | (1 << 1) | (1 << 3) | (1 << 4)

    checks = [
        (f240, flags_pass, "PASS_240HZ_PRODUCT"),
        (f242, flags_pass, "FAIL_SHARED30_TRAP"),
        (f162, flags_trap, "FAIL_16HZ_TRAP"),
        (f240, flags_no_raster, "FAIL_RASTER_ADVERSARIAL"),
    ]
    bad = 0
    for fx, fl, want in checks:
        got = verdict(fx, fl)
        okb = got == want
        print(f"{'OK' if okb else 'FAIL'} fps_x10={fx} flags=0x{fl:02x} → {got} (want {want})")
        if not okb:
            bad = 1
    if verdict(f240, flags_no_raster) == "PASS_240HZ_PRODUCT":
        print("FAIL NEG: PASS must require raster_ok"); bad = 1
    else:
        print("OK NEG: PASS requires raster_ok (adversarial rejected)")
    if verdict(f242, flags_pass) == "PASS_240HZ_PRODUCT":
        print("FAIL NEG: shared-30 must not PASS"); bad = 1
    else:
        print("OK NEG: shared-30 24.242 rejected (FAIL_SHARED30_TRAP)")

    if bad:
        print("FAIL test_clk_pix_refresh_predicate")
        return 1
    print("PASS test_clk_pix_refresh_predicate: 240 PASS / 242 SHARED30 / 162 TRAP / ADV raster")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
