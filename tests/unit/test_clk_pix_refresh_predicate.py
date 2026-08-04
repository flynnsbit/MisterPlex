#!/usr/bin/env python3
"""Predicate: product exact-24 PASS vs trap ~16.67 vs defect 242 vs adversarial raster.

Product: shared pll 28.8 MHz × H1600×V750 → 24.000 Hz → fps_x10=240.
Defect 242 (retired 30 MHz/H1650 24.242) MUST FAIL.
Trap 20 MHz same-clock → ~16.67 → fps_x10≈167.
"""
from __future__ import annotations


def band(fps_x10: int) -> str:
    if 239 <= fps_x10 <= 241:
        return "PASS_240"
    if 242 <= fps_x10 <= 244:
        return "DEFECT_242"
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
    if b == "DEFECT_242":
        return "FAIL_242_DEFECT"
    if b == "TRAP_16" or trap:
        return "FAIL_16HZ_TRAP"
    return "UNKNOWN_BAND"


def main() -> int:
    sys_hz = 20_000_000

    def fps_x10(period: float) -> int:
        return int((sys_hz * 10) / period)

    p240 = sys_hz / 24.0
    p242 = sys_hz / 24.242424  # retired defect period
    p167 = sys_hz / (20_000_000 / (1600 * 750))  # 16.666... Hz

    f240 = fps_x10(p240)
    f242 = fps_x10(p242)
    f167 = fps_x10(p167)
    print(f"product 28.8e6 H1600 → fps={28.8e6/(1600*750):.6f} period={p240:.1f} fps_x10={f240}")
    print(f"defect 24.242 → period={p242:.1f} fps_x10={f242}")
    print(f"trap 20e6 H1600 → fps={20e6/(1600*750):.6f} period={p167} fps_x10={f167}")
    print(f"adversarial 1500*800={1500*800} == 1600*750={1600*750}")

    flags_pass = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 5) | (1 << 6) | (1 << 7)
    flags_no_raster = flags_pass & ~(1 << 7)
    flags_trap = (1 << 0) | (1 << 1) | (1 << 3) | (1 << 4)

    checks = [
        (f240, flags_pass, "PASS_240HZ_PRODUCT"),
        (f242, flags_pass, "FAIL_242_DEFECT"),
        (f167, flags_trap, "FAIL_16HZ_TRAP"),
        (f240, flags_no_raster, "FAIL_RASTER_ADVERSARIAL"),
    ]
    bad = 0
    for fx, fl, want in checks:
        got = verdict(fx, fl)
        okb = got == want
        print(f"{'OK' if okb else 'FAIL'} fps_x10={fx} flags=0x{fl:02x} → {got} (want {want})")
        if not okb:
            bad = 1
    if verdict(f242, flags_pass) == "PASS_240HZ_PRODUCT":
        print("FAIL NEG: 242 must not PASS"); bad = 1
    else:
        print("OK NEG: 242 rejected (FAIL_242_DEFECT)")
    if f240 < 239 or f240 > 241:
        print("FAIL POS: 240 not in PASS band"); bad = 1
    else:
        print("OK POS: fps_x10=240 in PASS band [239,241]")

    if bad:
        print("FAIL test_clk_pix_refresh_predicate")
        return 1
    print("PASS test_clk_pix_refresh_predicate: 240 PASS / 242 FAIL / 167 TRAP / ADV raster")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
