#!/usr/bin/env python3
"""Round-trip: cell_bits_for_n → draw → decode_bars (native + capture chain).

RED if decoder cannot recover n. No device. Exit 0 only on full pass.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from glass_frame_id import (  # noqa: E402
    CANVAS_H,
    CANVAS_W,
    cell_bits_for_n,
    checksum_digit,
    decode_bars_from_rgb,
    draw_id_band,
    format_text,
    from_grey,
    geometry_for,
    simulate_capture_chain,
    to_grey,
    capture_space_expect,
    CELL_NAMES,
)


def _frame(n: int, luma: int, w: int = CANVAS_W, h: int = CANVAS_H) -> np.ndarray:
    rgb = np.zeros((h, w, 3), dtype=np.uint8)
    rgb[:, :, :] = int(luma)
    draw_id_band(rgb, n, geometry_for(w, h))
    return rgb


def main() -> int:
    fail = 0
    pass_n = 0

    # --- pure grey/parity identities ---
    for n in [0, 1, 2, 7, 255, 2352, 2358, 2378, 7199, 14399, 65535]:
        g = to_grey(n)
        if from_grey(g) != (n & 0xFFFF):
            print(f"FAIL grey_roundtrip n={n} g={g} back={from_grey(g)}")
            fail += 1
        else:
            pass_n += 1
        bits = cell_bits_for_n(n)
        if len(bits) != 20 or bits[0] != 1 or bits[18] != 0 or bits[19] != 1:
            print(f"FAIL framing n={n} bits={bits}")
            fail += 1
        else:
            pass_n += 1
        # rebuild g from bits
        g2 = 0
        for i in range(16):
            g2 = (g2 << 1) | bits[1 + i]
        if g2 != g or bits[17] != (bin(g).count("1") % 2):
            print(f"FAIL bits_pack n={n} g={g} g2={g2} p={bits[17]}")
            fail += 1
        else:
            pass_n += 1

    # worked example frozen
    bits_2358 = cell_bits_for_n(2358)
    expect = [1, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1]
    if bits_2358 != expect:
        print(f"FAIL worked_example bits={bits_2358} expect={expect}")
        fail += 1
    else:
        print(f"PASS worked_example n=2358 bits={bits_2358}")
        print(f"  named={dict(zip(CELL_NAMES, bits_2358))}")
        print(f"  text={format_text(2358)} checksum={checksum_digit(2358)}")
        pass_n += 1
    if format_text(2358) != "G n=002358 c=8":
        print(f"FAIL text {format_text(2358)!r}")
        fail += 1
    else:
        pass_n += 1

    # --- draw + decode native ---
    cases = [0, 1, 42, 2352, 2358, 2378, 1000, 9999, 14399]
    for n in cases:
        for luma in (0, 255):
            rgb = _frame(n, luma)
            r = decode_bars_from_rgb(rgb)
            tag = f"native n={n} luma={luma}"
            if not r.ok or r.n != n:
                print(f"FAIL {tag} status={r.status} got={r.n} reason={r.reason} bits={r.bits}")
                fail += 1
            else:
                pass_n += 1

    # --- capture chain (even cull + 0.75 squash) ---
    exp = capture_space_expect()
    print(
        f"capture_model origin_x={exp['origin_x']} pitch={exp['pitch']:.4f} "
        f"bar_y=[{exp['bar_y0']:.1f},{exp['bar_y1']:.1f}] src={exp['src']}"
    )
    for n in cases:
        for luma in (0, 255):
            rgb = _frame(n, luma)
            cap = simulate_capture_chain(rgb)
            # auto scale path
            r1 = decode_bars_from_rgb(cap)
            # explicit capture model path
            r2 = decode_bars_from_rgb(
                cap,
                origin_x=exp["origin_x"],
                pitch=exp["pitch"],
                bar_y0=exp["bar_y0"],
                bar_y1=exp["bar_y1"],
            )
            tag = f"chain n={n} luma={luma}"
            ok = (r1.ok and r1.n == n) or (r2.ok and r2.n == n)
            if not ok:
                print(
                    f"FAIL {tag} auto={r1.status}/{r1.n}/{r1.reason} "
                    f"model={r2.status}/{r2.n}/{r2.reason}"
                )
                fail += 1
            else:
                pass_n += 1

    # --- 320x240 geometry ---
    g240 = geometry_for(320, 240)
    print(
        f"geom_240 plate=[0,{g240.plate_y1}) bar=[{g240.bar_y0},{g240.bar_y1}) "
        f"cell_w={g240.cell_w} font={g240.font_px}"
    )
    for n in (0, 2358, 5000):
        rgb = _frame(n, 0, 320, 240)
        r = decode_bars_from_rgb(rgb, canvas_w=320, canvas_h=240)
        if not r.ok or r.n != n:
            print(f"FAIL 240p n={n} status={r.status} got={r.n} reason={r.reason}")
            fail += 1
        else:
            pass_n += 1
        cap = simulate_capture_chain(rgb)
        r2 = decode_bars_from_rgb(cap, canvas_w=320, canvas_h=240)
        # also try capture_space_expect for 320x240
        e2 = capture_space_expect(320, 240, geom=g240)
        r3 = decode_bars_from_rgb(
            cap,
            origin_x=e2["origin_x"],
            pitch=e2["pitch"],
            bar_y0=e2["bar_y0"],
            bar_y1=e2["bar_y1"],
            canvas_w=320,
            canvas_h=240,
        )
        if not ((r2.ok and r2.n == n) or (r3.ok and r3.n == n)):
            print(
                f"FAIL 240p_chain n={n} auto={r2.status}/{r2.n} model={r3.status}/{r3.n}"
            )
            fail += 1
        else:
            pass_n += 1

    # non-bank sizes native
    for wh in ((624, 352), (640, 480), (720, 480)):
        w, h = wh
        rgb = _frame(2358, 0, w, h)
        r = decode_bars_from_rgb(rgb, canvas_w=w, canvas_h=h)
        if not r.ok or r.n != 2358:
            print(f"FAIL nonbank {w}x{h} got={r.n} {r.reason}")
            fail += 1
        else:
            pass_n += 1
            print(f"PASS nonbank {w}x{h} n=2358")

    print(f"=== SUMMARY pass={pass_n} fail={fail} ===")
    if fail:
        print("GLASS_FRAME_ID_ROUNDTRIP_FAIL")
        return 1
    print("GLASS_FRAME_ID_ROUNDTRIP_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
