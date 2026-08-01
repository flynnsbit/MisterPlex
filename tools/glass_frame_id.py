#!/usr/bin/env python3
"""Glass frame-ID contract: writer geometry + bar decoder (not OCR).

Full human-readable contract: docs/glass_frame_id_contract.md
=========================================================================
Canvas default: 624 x 480 (DDR bank). Origin top-left (x right, y down).

TEXT (secondary): opaque black plate + fixed-width "G n=DDDDDD c=C"
BARS (PRIMARY / authoritative): 20 cells, Grey-coded n, even parity, framing.

Worked example n=2358:
  text = "G n=002358 c=8"
  grey = n^(n>>1) = 0x0DAD
  bits MSB-left =
    [1, 0,0,0,0,1,1,0, 1,1,0,1,0,1,1,0, 1,  0,  0, 1]
     ^START  <--- grey bit15..bit0 --->  ^P ^S  ^L
  P = even parity over 16 grey bits = popcount(0x0DAD)%2 = 0
  S = STOP 0, L = LOCK 1

Capture-space (host sim of device path — NOT a device measurement):
  even-row cull → scale 1920x1440 → squash 1920x1080
  Expected bar band ≈ y[126, 198), cell pitch ≈ 95.38 px, origin_x ≈ 0
  Live HDMI may differ (ascal / pillar); pass origin_x+pitch into decode_bars_from_rgb.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np

# ---- geometry (canvas 624x480 bank default) ----
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
CELL_W = CANVAS_W // N_CELLS  # 31; right margin = 4 px
START_CELL = 0
GREY_CELLS = range(1, 17)  # 16 bits, cell1=bit15 (MSB) .. cell16=bit0 (LSB)
PARITY_CELL = 17
STOP_CELL = 18
LOCK_CELL = 19
WHITE = (240, 240, 240)
BLACK = (0, 0, 0)
YELLOW = (255, 255, 0)
MAX_N_SANE = 1_000_000

CELL_NAMES = (
    ["START"]
    + [f"G{15 - i}" for i in range(16)]
    + ["PARITY_EVEN", "STOP", "LOCK"]
)


@dataclass(frozen=True)
class IdGeometry:
    """Per-canvas ID band geometry. Bit layout is identical for all sizes."""

    width: int
    height: int
    plate_y0: int
    plate_y1: int
    bar_y0: int
    bar_y1: int
    text_x: int
    text_y: int
    font_px: int
    stroke_w: int
    n_cells: int = N_CELLS

    @property
    def cell_w(self) -> int:
        return self.width // self.n_cells

    @property
    def margin_right(self) -> int:
        return self.width - self.n_cells * self.cell_w


def geometry_for(width: int, height: int) -> IdGeometry:
    """Scale the 624x480 reference band into another coded size."""
    if width == CANVAS_W and height == CANVAS_H:
        return IdGeometry(
            CANVAS_W, CANVAS_H, PLATE_Y0, PLATE_Y1, BAR_Y0, BAR_Y1,
            TEXT_X, TEXT_Y, FONT_PX, STROKE_W,
        )
    plate_h = max(24, int(round(height * (PLATE_Y1 - PLATE_Y0) / CANVAS_H)))
    if plate_h % 2:
        plate_h += 1
    bar_h = max(16, int(round(height * (BAR_Y1 - BAR_Y0) / CANVAS_H)))
    if bar_h % 2:
        bar_h += 1
    font = max(16, int(round(FONT_PX * width / CANVAS_W)))
    stroke = max(1, int(round(STROKE_W * width / CANVAS_W)))
    tx = max(2, int(round(TEXT_X * width / CANVAS_W)))
    ty = max(2, int(round(TEXT_Y * height / CANVAS_H)))
    return IdGeometry(
        width, height, 0, plate_h, plate_h, plate_h + bar_h, tx, ty, font, stroke
    )


def checksum_digit(n: int) -> int:
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
    return bin(g & 0xFFFF).count("1") % 2


def cell_bits_for_n(n: int) -> list[int]:
    """20 bits, index 0 = leftmost cell on canvas.

    [0] START=1
    [1..16] grey bit15 .. bit0  (MSB at left, next to START)
    [17] even parity over the 16 grey bits
    [18] STOP=0
    [19] LOCK=1
    """
    g = to_grey(n)
    bits = [0] * N_CELLS
    bits[START_CELL] = 1
    for i, cell in enumerate(GREY_CELLS):
        bits[cell] = (g >> (15 - i)) & 1
    bits[PARITY_CELL] = even_parity_bits(g)
    bits[STOP_CELL] = 0
    bits[LOCK_CELL] = 1
    return bits


def paint_even_rows(rgb: np.ndarray, y0: int, y1: int) -> None:
    y0 = max(0, y0 - (y0 % 2))
    y1 = min(rgb.shape[0], y1)
    for y in range(y0, y1 - 1, 2):
        rgb[y + 1] = rgb[y]


def draw_id_band(rgb: np.ndarray, n: int, geom: IdGeometry | None = None) -> None:
    from PIL import Image, ImageDraw, ImageFont

    h, w = rgb.shape[:2]
    g = geom or geometry_for(w, h)
    if w != g.width or h != g.height:
        raise AssertionError(f"canvas {w}x{h} != geom {g.width}x{g.height}")

    rgb[g.plate_y0 : g.plate_y1, :, :] = 0
    rgb[g.bar_y0 : g.bar_y1, :, :] = 0
    bits = cell_bits_for_n(n)
    cw = g.cell_w
    for i, b in enumerate(bits):
        x0 = i * cw
        x1 = x0 + cw
        color = WHITE if b else BLACK
        rgb[g.bar_y0 : g.bar_y1, x0:x1, :] = color

    img = Image.fromarray(rgb, mode="RGB")
    draw = ImageDraw.Draw(img)
    # Contract: fixed-width "G n=DDDDDD c=C". Proportional fonts shift digit
    # cells (thin '1') and break parent fixed-cell template decode.
    font = None
    for fp in (
        "/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
        "/usr/share/fonts/liberation/LiberationMono-Bold.ttf",
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        # last resort proportional — host gate may still use SIM auto cells
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    ):
        try:
            font = ImageFont.truetype(fp, size=g.font_px)
            break
        except Exception:
            continue
    if font is None:
        font = ImageFont.load_default()
    draw.text(
        (g.text_x, g.text_y),
        format_text(n),
        font=font,
        fill=YELLOW,
        stroke_width=g.stroke_w,
        stroke_fill=BLACK,
    )
    out = np.array(img)
    paint_even_rows(out, g.plate_y0, g.bar_y1)
    rgb[:] = out


@dataclass
class DecodeResult:
    ok: bool
    n: int | None
    status: str
    reason: str
    bits: list[int] | None = None
    grey: int | None = None
    means: list[float] | None = None
    thr: float | None = None
    geometry_used: dict[str, float] | None = None
    src: str = "measured"


def capture_space_expect(
    canvas_w: int = CANVAS_W,
    canvas_h: int = CANVAS_H,
    *,
    out_w: int = 1920,
    out_h_pre: int = 1440,
    grab_h: int = 1080,
    geom: IdGeometry | None = None,
) -> dict[str, Any]:
    """Expected bar geometry after host sim path (caller_supplied model).

    Path: even-row cull → 1920x1440 → 1920x1080.
    Live HDMI may add offset — calibrate origin_x from START edge.
    """
    g = geom or geometry_for(canvas_w, canvas_h)
    bar_y0_cull = g.bar_y0 / 2.0
    bar_y1_cull = g.bar_y1 / 2.0
    h_cull = canvas_h / 2.0
    sx = out_w / float(canvas_w)
    sy1 = out_h_pre / h_cull
    sy2 = grab_h / float(out_h_pre)
    return {
        "origin_x": 0.0,
        "pitch": g.cell_w * sx,
        "bar_y0": bar_y0_cull * sy1 * sy2,
        "bar_y1": bar_y1_cull * sy1 * sy2,
        "n_cells": g.n_cells,
        "margin_right_capture": g.margin_right * sx,
        "model": "even_cull->1920x1440->1920x1080",
        "src": "caller_supplied_model",
    }


def _sample_cells_pitched(
    rgb: np.ndarray,
    bar_y0: int,
    bar_y1: int,
    origin_x: float,
    pitch: float,
    n_cells: int = N_CELLS,
) -> np.ndarray:
    mid_y = (bar_y0 + bar_y1) // 2
    mid_y = min(max(0, mid_y), rgb.shape[0] - 1)
    means = []
    for i in range(n_cells):
        x0 = origin_x + i * pitch
        x1 = origin_x + (i + 1) * pitch
        m = 0.25 * (x1 - x0)
        xa = int(round(x0 + m))
        xb = int(round(x1 - m))
        xa = max(0, min(rgb.shape[1] - 1, xa))
        xb = max(xa + 1, min(rgb.shape[1], xb))
        patch = rgb[mid_y, xa:xb, :].astype(np.float64)
        means.append(float(patch.mean()) if patch.size else 0.0)
    return np.array(means, dtype=np.float64)


def decode_bars_from_rgb(
    rgb: np.ndarray,
    *,
    bar_y0: float | None = None,
    bar_y1: float | None = None,
    cell_w: float | None = None,
    origin_x: float | None = None,
    pitch: float | None = None,
    canvas_w: int = CANVAS_W,
    canvas_h: int = CANVAS_H,
) -> DecodeResult:
    """Decode frame index from bar strip. Never guesses — UNRESOLVED on doubt.

    Prefer explicit origin_x+pitch+bar_y0/y1 on live HDMI captures.
    """
    h, w = rgb.shape[:2]
    geom = geometry_for(canvas_w, canvas_h)

    if origin_x is not None and pitch is not None and bar_y0 is not None and bar_y1 is not None:
        by0, by1 = int(round(bar_y0)), int(round(bar_y1))
        ox, p = float(origin_x), float(pitch)
    elif cell_w is not None and bar_y0 is not None and bar_y1 is not None:
        by0, by1 = int(round(bar_y0)), int(round(bar_y1))
        ox, p = float(origin_x or 0.0), float(cell_w)
    else:
        scale_x = w / float(canvas_w)
        scale_y = h / float(canvas_h)
        if bar_y0 is None:
            by0 = int(round(geom.bar_y0 * scale_y))
            by1 = int(round(geom.bar_y1 * scale_y))
        else:
            by0 = int(round(bar_y0))
            by1 = int(round(bar_y1))  # type: ignore[arg-type]
        ox = float(origin_x or 0.0)
        p = float(pitch if pitch is not None else (cell_w if cell_w is not None else geom.cell_w * scale_x))

    used = {"origin_x": ox, "pitch": p, "bar_y0": float(by0), "bar_y1": float(by1)}
    if p < 2 or by1 - by0 < 2:
        return DecodeResult(
            False, None, "UNRESOLVED", "geometry_too_small", geometry_used=used, src="measured"
        )

    means = _sample_cells_pitched(rgb, by0, by1, ox, p, N_CELLS)
    lo = float(np.percentile(means, 20))
    hi = float(np.percentile(means, 80))
    thr = 0.5 * (lo + hi) if hi - lo > 20 else 128.0
    bits = [1 if m >= thr else 0 for m in means]

    if bits[START_CELL] != 1:
        return DecodeResult(
            False, None, "UNRESOLVED", "bad_start", bits=bits,
            means=list(means), thr=thr, geometry_used=used, src="measured",
        )
    if bits[STOP_CELL] != 0:
        return DecodeResult(
            False, None, "UNRESOLVED", "bad_stop", bits=bits,
            means=list(means), thr=thr, geometry_used=used, src="measured",
        )
    if bits[LOCK_CELL] != 1:
        return DecodeResult(
            False, None, "UNRESOLVED", "bad_lock", bits=bits,
            means=list(means), thr=thr, geometry_used=used, src="measured",
        )

    gval = 0
    for i, cell in enumerate(GREY_CELLS):
        gval = (gval << 1) | bits[cell]
    if bits[PARITY_CELL] != even_parity_bits(gval):
        return DecodeResult(
            False, None, "UNRESOLVED", "bad_parity", bits=bits, grey=gval,
            means=list(means), thr=thr, geometry_used=used, src="measured",
        )

    n = from_grey(gval)
    if n >= MAX_N_SANE:
        return DecodeResult(
            False, None, "UNRESOLVED", "n_insane", bits=bits, grey=gval,
            means=list(means), thr=thr, geometry_used=used, src="measured",
        )
    return DecodeResult(
        True, n, "OK", "bars_ok", bits=bits, grey=gval,
        means=list(means), thr=thr, geometry_used=used, src="measured",
    )


def simulate_capture_chain(rgb_src: np.ndarray) -> np.ndarray:
    """Approximate device path for host gate (not a device measurement)."""
    from PIL import Image

    even = rgb_src[0::2, :, :]
    im = Image.fromarray(even, mode="RGB")
    im = im.resize((1920, 1440), Image.Resampling.BILINEAR)
    im = im.resize((1920, 1080), Image.Resampling.BILINEAR)
    return np.array(im)


def contract_dict() -> dict[str, Any]:
    ex = cell_bits_for_n(2358)
    return {
        "canvas_default": f"{CANVAS_W}x{CANVAS_H}",
        "digits": DIGITS,
        "text_format": "G n=DDDDDD c=C",
        "checksum": "sum of six decimal digits of zero-padded n, mod 10",
        "checksum_example": {"n": 2358, "text": format_text(2358), "c": checksum_digit(2358)},
        "plate": {"y0": PLATE_Y0, "y1": PLATE_Y1, "color": "black_opaque RGB(0,0,0)"},
        "bars": {
            "y0": BAR_Y0,
            "y1": BAR_Y1,
            "n_cells": N_CELLS,
            "cell_w_canvas": CELL_W,
            "cell_x0_canvas": [i * CELL_W for i in range(N_CELLS)],
            "margin_right_px": CANVAS_W - N_CELLS * CELL_W,
            "bit_order": (
                "MSB-left: cell0=START=1, cell1=grey_bit15, cell16=grey_bit0, "
                "cell17=even_parity(grey), cell18=STOP=0, cell19=LOCK=1"
            ),
            "cell_names": list(CELL_NAMES),
            "grey": "g = (n & 0xFFFF) ^ ((n & 0xFFFF) >> 1)",
            "grey_decode": "BRGC inverse xor cascade >>1,2,4,8",
            "parity": "parity_bit == popcount(g)&1 (even parity over grey bits)",
            "white_rgb": list(WHITE),
            "black_rgb": list(BLACK),
            "authoritative": True,
            "example_n_2358": {
                "text": format_text(2358),
                "grey_hex": f"0x{to_grey(2358):04X}",
                "bits": ex,
                "bits_named": dict(zip(CELL_NAMES, ex)),
            },
        },
        "capture_space_host_model": capture_space_expect(),
        "text_secondary": True,
        "even_row_paint": True,
        "chrome_exclusion": "y>=100 reserved lower on 624x480; ID in y<88",
        "decoder": "tools/glass_frame_id.decode_bars_from_rgb",
        "doc": "docs/glass_frame_id_contract.md",
    }


if __name__ == "__main__":
    import json
    print(json.dumps(contract_dict(), indent=2))
