#!/usr/bin/env python3
"""Glass frame-ID contract: writer geometry + bar decoder (not OCR).

CONTRACT (w-asset480 writer ↔ w-instr reader) — do not drift independently.
=========================================================================
Canvas: 624 x 480 (DDR bank). Origin top-left.

1) Opaque plate (always solid black RGB 0,0,0 — never translucent):
     x=0..623  y=PLATE_Y0..PLATE_Y1-1   (PLATE_Y0=0, PLATE_Y1=56)

2) Human digits (secondary; OCR may still fail — bars are authoritative):
     Text at (TEXT_X, TEXT_Y) = (8, 6)
     Format EXACTLY:  "G n=DDDDDD c=C"
       DDDDDD = zero-padded frame index, FIXED width DIGITS=6  (000000..999999)
       C      = checksum digit = (sum of six decimal digits) mod 10
     Colour: yellow (255,255,0) on the opaque black plate.
     Font: DejaVu Sans Bold, size FONT_PX=40, stroke_width=3 black.
     After draw: even_row_paint on full plate band (odd rows copy even).

3) Binary bar strip (PRIMARY machine channel) — authoritative ID:
     y = BAR_Y0 .. BAR_Y1-1   (BAR_Y0=56, BAR_Y1=88)  height=32 (even)
     x full width 0..623
     N_CELLS = 20 cells, cell_w = 624 // 20 = 31  (last 4 px unused margin)
     Cell i occupies x=[i*31, (i+1)*31)

     Bit layout MSB-left (cell 0 = left):
       [0]     START  = 1 (white)   — framing
       [1:16]  16-bit Grey code of (n & 0xFFFF)  — bit15 at cell1, bit0 at cell16
       [17]    PARITY = even parity over the 16 grey bits (1=white if odd count→wait:
               even parity bit: set so total number of 1s among bits[1..17] is even)
       [18]    STOP   = 0 (black)
       [19]    LOCK   = 1 (white)   — second framing check

     White = RGB(240,240,240)  Black = RGB(0,0,0)  (high contrast, no grey levels)

     Grey code: g = n ^ (n >> 1)  standard binary-reflected.
     Decode:    n = grey_to_bin(g)

4) even_row_paint: for y in plate∪bars, odd y copies even y-1 (present_core
   STORE_Y_SCALE=2 drops odd store rows — present_core.sv:164).

5) Position: top band only. Lower band reserved for player chrome. Do not place
   ID below y=100.

Reader algorithm (bars only — no OCR required for PASS):
  - Sample each cell mean luma at vertical mid of bar band (after any capture
    squash, map y via scale).
  - Threshold mid = 0.5*(p20+p80) of the 20 cell means (or fixed 128).
  - Require cell0==1, cell18==0, cell19==1 else UNRESOLVED.
  - Extract 16 grey bits, check even parity at cell17 else UNRESOLVED.
  - n = grey_to_bin(g). If n > MAX_N_SANE (1_000_000) UNRESOLVED.
  - Optional: if OCR digits present and disagree with bars → UNRESOLVED
    (never guess).

Provenance labels: any printed fps/geometry must tag measured|caller_supplied|
DEFAULT_ASSUMED. This module does not print fps defaults as measurements.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np

# ---- geometry (canvas 624x480) ----
CANVAS_W = 624
CANVAS_H = 480
PLATE_Y0 = 0
PLATE_Y1 = 56
BAR_Y0 = 56
BAR_Y1 = 88
TEXT_X = 8
TEXT_Y = 6
FONT_PX = 40
STROKE_W = 3
DIGITS = 6
N_CELLS = 20
CELL_W = CANVAS_W // N_CELLS  # 31
START_CELL = 0
GREY_CELLS = range(1, 17)  # 16 bits
PARITY_CELL = 17
STOP_CELL = 18
LOCK_CELL = 19
WHITE = (240, 240, 240)
BLACK = (0, 0, 0)
YELLOW = (255, 255, 0)
MAX_N_SANE = 1_000_000


def checksum_digit(n: int) -> int:
    """Sum of zero-padded DIGITS decimal digits mod 10."""
    s = f"{n:0{DIGITS}d}"
    if len(s) > DIGITS:
        s = s[-DIGITS:]
    return sum(int(ch) for ch in s) % 10


def format_text(n: int) -> str:
    return f"G n={n:0{DIGITS}d} c={checksum_digit(n)}"


def to_grey(n: int) -> int:
    n = int(n) & 0xFFFF
    return n ^ (n >> 1)


def from_grey(g: int) -> int:
    g = int(g) & 0xFFFF
    n = g
    n ^= n >> 1
    n ^= n >> 2
    n ^= n >> 4
    n ^= n >> 8
    return n & 0xFFFF


def even_parity_bits(g: int) -> int:
    """Return 0 or 1 such that popcount(grey_bits)+parity is even."""
    return bin(g & 0xFFFF).count("1") % 2  # 1 if odd → parity bit 1 makes even


def cell_bits_for_n(n: int) -> list[int]:
    g = to_grey(n)
    bits = [0] * N_CELLS
    bits[START_CELL] = 1
    for i, cell in enumerate(GREY_CELLS):
        # bit15 at first grey cell
        bits[cell] = (g >> (15 - i)) & 1
    bits[PARITY_CELL] = even_parity_bits(g)
    bits[STOP_CELL] = 0
    bits[LOCK_CELL] = 1
    return bits


def paint_even_rows(rgb: np.ndarray, y0: int, y1: int) -> None:
    """In-place: odd rows in [y0,y1) copy from row-1 (even source)."""
    y0 = max(0, y0 - (y0 % 2))
    y1 = min(rgb.shape[0], y1)
    for y in range(y0, y1 - 1, 2):
        rgb[y + 1] = rgb[y]


def draw_id_band(rgb: np.ndarray, n: int) -> None:
    """Paint opaque plate + bars + text into rgb HxWx3 uint8 canvas (624x480)."""
    from PIL import Image, ImageDraw, ImageFont

    h, w = rgb.shape[:2]
    assert w == CANVAS_W and h == CANVAS_H, f"canvas must be {CANVAS_W}x{CANVAS_H}, got {w}x{h}"
    # opaque black plate
    rgb[PLATE_Y0:PLATE_Y1, :, :] = 0
    # bars background black
    rgb[BAR_Y0:BAR_Y1, :, :] = 0
    bits = cell_bits_for_n(n)
    for i, b in enumerate(bits):
        x0 = i * CELL_W
        x1 = x0 + CELL_W
        color = WHITE if b else BLACK
        rgb[BAR_Y0:BAR_Y1, x0:x1, :] = color

    img = Image.fromarray(rgb, mode="RGB")
    draw = ImageDraw.Draw(img)
    font = None
    for fp in (
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/liberation/LiberationSans-Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    ):
        try:
            font = ImageFont.truetype(fp, size=FONT_PX)
            break
        except Exception:
            continue
    if font is None:
        font = ImageFont.load_default()
    draw.text(
        (TEXT_X, TEXT_Y),
        format_text(n),
        font=font,
        fill=YELLOW,
        stroke_width=STROKE_W,
        stroke_fill=BLACK,
    )
    out = np.array(img)
    paint_even_rows(out, PLATE_Y0, BAR_Y1)
    rgb[:] = out


@dataclass
class DecodeResult:
    ok: bool
    n: int | None
    status: str  # OK | UNRESOLVED
    reason: str
    bits: list[int] | None = None
    grey: int | None = None
    src: str = "measured"  # bars are measured from pixels


def _sample_cells(rgb: np.ndarray, bar_y0: int, bar_y1: int, cell_w: int) -> np.ndarray:
    """Return mean luma per cell."""
    mid_y = (bar_y0 + bar_y1) // 2
    mid_y = min(max(0, mid_y), rgb.shape[0] - 1)
    means = []
    for i in range(N_CELLS):
        x0 = i * cell_w
        x1 = min(rgb.shape[1], x0 + cell_w)
        if x1 <= x0:
            means.append(0.0)
            continue
        # sample center 50% of cell width to avoid boundaries
        m = (x1 - x0) // 4
        xs = slice(x0 + m, x1 - m if x1 - m > x0 + m else x1)
        patch = rgb[mid_y, xs, :].astype(np.float64)
        means.append(float(patch.mean()))
    return np.array(means, dtype=np.float64)


def decode_bars_from_rgb(
    rgb: np.ndarray,
    *,
    # geometry may be scaled (capture). If None, assume native 624 canvas.
    bar_y0: float | None = None,
    bar_y1: float | None = None,
    cell_w: float | None = None,
) -> DecodeResult:
    """Decode frame index from bar strip. Never guesses — UNRESOLVED on doubt."""
    h, w = rgb.shape[:2]
    scale_x = w / float(CANVAS_W)
    scale_y = h / float(CANVAS_H)
    by0 = int(round((BAR_Y0 if bar_y0 is None else bar_y0) * (scale_y if bar_y0 is None else 1.0)))
    by1 = int(round((BAR_Y1 if bar_y1 is None else bar_y1) * (scale_y if bar_y1 is None else 1.0)))
    if bar_y0 is not None:
        by0 = int(round(bar_y0))
        by1 = int(round(bar_y1))  # type: ignore[arg-type]
    cw = int(round(CELL_W * scale_x if cell_w is None else cell_w))
    if cw < 2 or by1 - by0 < 2:
        return DecodeResult(False, None, "UNRESOLVED", "geometry_too_small", src="measured")

    means = _sample_cells(rgb, by0, by1, cw)
    # adaptive threshold
    lo = float(np.percentile(means, 20))
    hi = float(np.percentile(means, 80))
    thr = 0.5 * (lo + hi) if hi - lo > 20 else 128.0
    bits = [1 if m >= thr else 0 for m in means]

    if bits[START_CELL] != 1:
        return DecodeResult(False, None, "UNRESOLVED", "bad_start", bits=bits, src="measured")
    if bits[STOP_CELL] != 0:
        return DecodeResult(False, None, "UNRESOLVED", "bad_stop", bits=bits, src="measured")
    if bits[LOCK_CELL] != 1:
        return DecodeResult(False, None, "UNRESOLVED", "bad_lock", bits=bits, src="measured")

    g = 0
    for i, cell in enumerate(GREY_CELLS):
        g = (g << 1) | bits[cell]
    if bits[PARITY_CELL] != even_parity_bits(g):
        return DecodeResult(False, None, "UNRESOLVED", "bad_parity", bits=bits, grey=g, src="measured")

    n = from_grey(g)
    if n >= MAX_N_SANE:
        return DecodeResult(False, None, "UNRESOLVED", "n_insane", bits=bits, grey=g, src="measured")
    return DecodeResult(True, n, "OK", "bars_ok", bits=bits, grey=g, src="measured")


def simulate_capture_chain(rgb_624: np.ndarray) -> np.ndarray:
    """Approximate device path for host gate (not a device measurement).

    1) even-row cull (present_core STORE_Y_SCALE=2)
    2) scale to 1920x1440 (video_mode=12 parent-verified)
    3) vertical squash to 1920x1080 grabber (0.75)
    """
    from PIL import Image

    even = rgb_624[0::2, :, :]  # 240 x 624
    im = Image.fromarray(even, mode="RGB")
    im = im.resize((1920, 1440), Image.Resampling.BILINEAR)
    im = im.resize((1920, 1080), Image.Resampling.BILINEAR)  # 0.75 vertical
    return np.array(im)


def contract_dict() -> dict[str, Any]:
    return {
        "canvas": f"{CANVAS_W}x{CANVAS_H}",
        "digits": DIGITS,
        "text_format": "G n=DDDDDD c=C",
        "checksum": "sum(digits) mod 10",
        "plate": {"y0": PLATE_Y0, "y1": PLATE_Y1, "color": "black_opaque"},
        "bars": {
            "y0": BAR_Y0,
            "y1": BAR_Y1,
            "n_cells": N_CELLS,
            "cell_w": CELL_W,
            "layout": "START(1) + GREY16 + PARITY_EVEN + STOP(0) + LOCK(1)",
            "grey": "n^(n>>1)",
            "authoritative": True,
        },
        "text_secondary": True,
        "even_row_paint": True,
        "chrome_exclusion": "y>=100 reserved lower; ID in y<88",
    }


if __name__ == "__main__":
    import json
    print(json.dumps(contract_dict(), indent=2))
