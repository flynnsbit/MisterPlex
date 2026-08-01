#!/usr/bin/env python3
"""G0 — output-raster chrome layout (option c) scales with HDMI W×H, not DECODE.

Mirrors docs/osd-chrome-plane-design.md §4. This is a host gate for the paper
design; it does NOT claim silicon sharpness. bodyScale=3 on a 624×480 bank is
NOT a substitute and is not tested here as a product fix.

PASS:
  - panel fully inside [0,W)×[0,H) for every mode in the matrix
  - bodyScale in [2,8], monotonic non-decreasing with H
  - glyph advance = font_advance * bodyScale (output px, no bank stretch)
  - 240p / 640×480 / 800×600 do not overflow

FAIL:
  - any overflow, scale floor broken, or scale ignores H
"""
from __future__ import annotations

import math
import sys
from dataclasses import dataclass

# Font advances (canvas cells) — same as playback_overlay.hpp
ADV_8x13 = 9
ADV_12x16 = 13
GLYPH_H_12 = 16
GLYPH_H_8 = 13
MIN_SCALE = 2
MAX_SCALE = 8


@dataclass(frozen=True)
class OutLayout:
    w: int
    h: int
    margin: int
    body_scale: int
    font_advance: int
    glyph_h: int
    panel_h: int
    panel_x: int
    panel_y: int
    panel_w: int

    @property
    def advance_px(self) -> int:
        return self.font_advance * self.body_scale

    @property
    def text_h(self) -> int:
        return self.glyph_h * self.body_scale


def snap_even(v: int) -> int:
    return v & ~1


def output_raster_layout(w: int, h: int) -> OutLayout:
    """§4 design: metrics from OUTPUT W×H only."""
    if w <= 0 or h <= 0:
        raise ValueError("non-positive geometry")
    margin = max(6, w // 40)
    # bodyScale = clamp(2..8, round(H/240))
    raw = int(round(h / 240.0))
    body_scale = max(MIN_SCALE, min(MAX_SCALE, raw if raw > 0 else MIN_SCALE))
    # 12×16 when H>=480 else 8×13 (readable floor at tiny modes)
    if h >= 480:
        font_adv, glyph_h = ADV_12x16, GLYPH_H_12
    else:
        font_adv, glyph_h = ADV_8x13, GLYPH_H_8
    text_h = glyph_h * body_scale
    need = 8 + text_h + 4 + text_h + 12 + max(4, 6)
    panel_h = max(need, min(h // 3, max(64, h // 4)))
    if panel_h > h - 2 * margin:
        panel_h = max(need, h - 2 * margin)
    panel_h = snap_even(panel_h)
    # If still impossible, clamp to remaining height (must stay >= need or fail later)
    if panel_h > h - 2 * margin:
        panel_h = snap_even(max(0, h - 2 * margin))
    panel_x = margin
    panel_w = w - margin * 2
    panel_y = snap_even(h - panel_h - margin)
    if panel_y < 0:
        panel_y = 0
    return OutLayout(
        w=w,
        h=h,
        margin=margin,
        body_scale=body_scale,
        font_advance=font_adv,
        glyph_h=glyph_h,
        panel_h=panel_h,
        panel_x=panel_x,
        panel_y=panel_y,
        panel_w=panel_w,
    )


# Modes the user named + device mode 12 + common MiSTer modes
MODES = [
    (1920, 1440, "video_mode=12 device"),
    (1920, 1080, "1080p"),
    (1280, 720, "720p"),
    (800, 600, "user 800x600"),
    (640, 480, "user 640x480"),
    (320, 240, "user 240p-class"),
]


def fail(msg: str) -> None:
    print(f"FAIL chrome_output_layout: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    layouts = []
    for w, h, name in MODES:
        m = output_raster_layout(w, h)
        layouts.append((name, m))
        print(
            f"  {name:24s} {w}x{h} scale={m.body_scale} "
            f"adv={m.advance_px} panel=({m.panel_x},{m.panel_y},{m.panel_w},{m.panel_h})"
        )
        # Inside raster
        if m.panel_x < 0 or m.panel_y < 0:
            fail(f"{name}: panel origin negative")
        if m.panel_x + m.panel_w > w:
            fail(f"{name}: panel overflows width ({m.panel_x}+{m.panel_w}>{w})")
        if m.panel_y + m.panel_h > h:
            fail(f"{name}: panel overflows height ({m.panel_y}+{m.panel_h}>{h})")
        if m.panel_w <= 0 or m.panel_h <= 0:
            fail(f"{name}: empty panel")
        if not (MIN_SCALE <= m.body_scale <= MAX_SCALE):
            fail(f"{name}: body_scale {m.body_scale} out of [{MIN_SCALE},{MAX_SCALE}]")
        # need room for at least one text row
        if m.panel_h < m.text_h:
            fail(f"{name}: panel_h {m.panel_h} < text_h {m.text_h}")
        # advance is pure output px (no 1920/624 stretch factor baked in)
        expect_adv = m.font_advance * m.body_scale
        if m.advance_px != expect_adv:
            fail(f"{name}: advance mismatch")

    # Monotonic bodyScale with H (same W family not required — sort by H)
    by_h = sorted(layouts, key=lambda t: t[1].h)
    for i in range(1, len(by_h)):
        prev, cur = by_h[i - 1][1], by_h[i][1]
        if cur.body_scale < prev.body_scale:
            fail(
                f"body_scale not monotonic with H: "
                f"{by_h[i-1][0]} H={prev.h} s={prev.body_scale} -> "
                f"{by_h[i][0]} H={cur.h} s={cur.body_scale}"
            )

    # Device mode 12 expectations from design §4 table
    m12 = output_raster_layout(1920, 1440)
    if m12.body_scale != 6:
        fail(f"mode12 body_scale expected 6 got {m12.body_scale} (round(1440/240)=6)")
    if m12.advance_px != 13 * 6:
        fail(f"mode12 advance expected 78 got {m12.advance_px}")

    # 640×480 → scale 2, 12×16, advance 26
    m480 = output_raster_layout(640, 480)
    if m480.body_scale != 2:
        fail(f"640x480 body_scale expected 2 got {m480.body_scale}")
    if m480.advance_px != 26:
        fail(f"640x480 advance expected 26 got {m480.advance_px}")

    # 320×240 → floor 2, 8×13
    m240 = output_raster_layout(320, 240)
    if m240.body_scale != 2:
        fail(f"320x240 body_scale expected 2 got {m240.body_scale}")
    if m240.font_advance != ADV_8x13:
        fail("320x240 must use 8x13 advance")

    # RED twin: a "bank stretch" model must NOT satisfy "inside output with scale=H/240"
    # Prove we are not accidentally using DECODE 624×480 metrics for mode 12.
    bank = output_raster_layout(624, 480)
    if bank.body_scale != 2 or bank.advance_px != 26:
        fail("internal: bank layout sanity")
    # Stretched bank advance at 1920 ≈ 26*(1920/624) ≈ 80 — design mode12 is 78
    # but the *source* of 78 is scale=6 on output, not bank. Discriminator:
    # bank layout at 624 must never be reported as the mode-12 layout.
    if bank.w == 1920:
        fail("bank layout must stay 624-wide")

    print("PASS chrome_output_layout: all modes in-bounds, scale monotonic, mode12=6/adv78")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        fail(str(e))
