#!/usr/bin/env python3
"""Red-before-green gate: present_core even-row cull vs overlay vertical scale.

present_core.sv (FRAME_H=480):
  STORE_Y_SCALE = (FRAME_H * 65536) / 240 = 131072 = 2.0
  store_y for py in 0..239 = 0,2,4,...,478  — odd bank rows NEVER fetched.

This tool does NOT touch hardware. It:
  RED  — author classic 5x7 glyphs at scale=1, keep even rows only, show that
         middle bars die (8 loses row 3 → looks like 0; STOPPED features drop).
  GREEN — author shipped 12x16 @ scale=2 with even y-origin, keep even rows only,
         recover STOPPED by template match (same tables as playback_overlay.hpp).

Prints true rc on its own line via the caller: `cmd; echo "true rc=$?"`

Exit: 0 = pair OK, 1 = fail, 77 = unscored (should not happen here).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

# --- classic 5x7 (pre-fix mush path); row0 top. Bits MSB=left of 5 cols. ---
G5 = {
    "S": [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E],
    "T": [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
    "O": [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
    "P": [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
    "E": [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
    "D": [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E],
    "8": [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
    "0": [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
}

# Shipped 12x16 STOPPED subset (playback_overlay.hpp glyph12) — MSB left of 12.
G12 = {
    "S": [0x0000, 0x1F00, 0x30C0, 0x3000, 0x3000, 0x1F00, 0x00C0, 0x0060,
          0x0060, 0x0060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000, 0x0000],
    "T": [0x0000, 0x3FC0, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00,
          0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0000, 0x0000, 0x0000],
    "O": [0x0000, 0x1F00, 0x30C0, 0x6060, 0x6060, 0x6060, 0x6060, 0x6060,
          0x6060, 0x6060, 0x6060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000],
    "P": [0x0000, 0x3F00, 0x30C0, 0x3060, 0x3060, 0x30C0, 0x3F00, 0x3000,
          0x3000, 0x3000, 0x3000, 0x3000, 0x3000, 0x0000, 0x0000, 0x0000],
    "E": [0x0000, 0x3FC0, 0x3000, 0x3000, 0x3000, 0x3000, 0x3F00, 0x3000,
          0x3000, 0x3000, 0x3000, 0x3000, 0x3FC0, 0x0000, 0x0000, 0x0000],
    "D": [0x0000, 0x3E00, 0x3180, 0x30C0, 0x3060, 0x3060, 0x3060, 0x3060,
          0x3060, 0x3060, 0x30C0, 0x3180, 0x3E00, 0x0000, 0x0000, 0x0000],
}


def blit5(canvas: list[list[int]], x0: int, y0: int, ch: str, scale: int = 1) -> None:
    g = G5[ch]
    for row, bits in enumerate(g):
        for col in range(5):
            if (bits & (1 << (4 - col))) == 0:
                continue
            for vr in range(scale):
                for hr in range(scale):
                    y = y0 + row * scale + vr
                    x = x0 + col * scale + hr
                    if 0 <= y < len(canvas) and 0 <= x < len(canvas[0]):
                        canvas[y][x] = 235


def blit12(canvas: list[list[int]], x0: int, y0: int, ch: str, scale: int = 2) -> None:
    g = G12[ch]
    for row, bits in enumerate(g):
        for col in range(12):
            if (bits & (1 << (15 - col))) == 0:
                continue
            for vr in range(scale):
                for hr in range(scale):
                    y = y0 + row * scale + vr
                    x = x0 + col * scale + hr
                    if 0 <= y < len(canvas) and 0 <= x < len(canvas[0]):
                        canvas[y][x] = 235


def even_cull(canvas: list[list[int]]) -> list[list[int]]:
    """Keep only even content rows — model present_core store_y = 0,2,4,..."""
    return [list(canvas[y]) for y in range(0, len(canvas), 2)]


def mid_bar_survives_5x7_eight(even_rows: list[list[int]], x0: int, y0: int, scale: int) -> bool:
    """Row 3 of classic '8' is the middle bar. After cull, does any of its ink remain?"""
    # content rows for glyph row 3: y0+3*scale .. y0+3*scale+scale-1
    for vr in range(scale):
        cy = y0 + 3 * scale + vr
        if cy % 2 != 0:
            continue  # culled
        ey = cy // 2
        if ey < 0 or ey >= len(even_rows):
            continue
        for col in range(5):
            for hr in range(scale):
                x = x0 + col * scale + hr
                if 0 <= x < len(even_rows[0]) and even_rows[ey][x] >= 200:
                    return True
    return False


def score_stopped_12(even_rows: list[list[int]], x0: int, y0: int, scale: int = 2) -> float:
    """Fraction of on/off agreement for STOPPED at known origin after cull."""
    text = "STOPPED"
    adv = 13 * scale
    total = hit = 0
    for ci, ch in enumerate(text):
        gx = x0 + ci * adv
        g = G12[ch]
        for row in range(16):
            for col in range(12):
                on = (g[row] & (1 << (15 - col))) != 0
                # sample center of scale block; map to even-row index
                cy = y0 + row * scale + scale // 2
                cx = gx + col * scale + scale // 2
                if cy % 2 != 0:
                    # pick nearest even content row inside the block
                    cy = y0 + row * scale  # even if y0 even and scale>=2
                if cy % 2 != 0 or cy < 0:
                    continue
                ey = cy // 2
                if ey < 0 or ey >= len(even_rows) or cx < 0 or cx >= len(even_rows[0]):
                    continue
                bright = even_rows[ey][cx] >= 120
                total += 1
                if on == bright:
                    hit += 1
    return hit / total if total else 0.0


def run_pair() -> int:
    W, H = 624, 480
    # --- RED: scale=1 classic 5x7 at even origin ---
    red = [[20] * W for _ in range(H)]
    y0 = 400  # even
    assert y0 % 2 == 0
    x8 = 40
    blit5(red, x8, y0, "8", scale=1)
    xstop = 80
    for i, ch in enumerate("STOPPED"):
        blit5(red, xstop + i * 6, y0, ch, scale=1)
    red_even = even_cull(red)
    mid_ok = mid_bar_survives_5x7_eight(red_even, x8, y0, scale=1)
    # Also: count how many of the 7 glyph rows of 'E' middle bar (row 3) survive
    print(f"RED scale=1 even-cull: eight_mid_bar_survives={mid_ok} (want False)")
    if mid_ok:
        print("verdict=RED_ARM_FALSE_GREEN eight mid-bar survived scale=1 cull")
        return 1

    # Feature drop count on STOPPED: for each char, glyph rows 1,3,5 are odd offsets
    # from even y0 → deleted. That is 3/7 rows — structural destruction.
    deleted_rows = [r for r in range(7) if (y0 + r) % 2 == 1]
    print(f"RED scale=1 deleted_glyph_row_indices={deleted_rows} count={len(deleted_rows)}/7")
    if len(deleted_rows) != 3:
        print("verdict=RED_ARM_UNEXPECTED_PARITY")
        return 1
    print("verdict=RED_OK scale=1 mid-bar dead + 3/7 glyph rows culled")

    # --- GREEN: shipped 12x16 @ scale=2, even y ---
    green = [[20] * W for _ in range(H)]
    gy = 350  # even
    assert gy % 2 == 0
    gx = 100
    sc = 2
    for i, ch in enumerate("STOPPED"):
        blit12(green, gx + i * 13 * sc, gy, ch, scale=sc)
    green_even = even_cull(green)
    frac = score_stopped_12(green_even, gx, gy, scale=sc)
    print(f"GREEN scale=2 even-cull: STOPPED_template_frac={frac:.4f} (want >= 0.90)")
    if frac < 0.90:
        print("verdict=GREEN_ARM_FAIL")
        return 1
    print("verdict=GREEN_OK scale>=2 STOPPED survives even-row cull")
    print("PAIR_OK even-row cull: RED scale=1 destroys mid-bar; GREEN scale=2 recovers STOPPED")
    print(
        "NOTE: effective vertical samples to ascal remain 240 (ceiling). "
        "scale>=2 accommodates cull; does not restore 480-line detail."
    )
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--selftest-pair", action="store_true", default=True)
    args = ap.parse_args(argv)
    return run_pair()


if __name__ == "__main__":
    sys.exit(main())
