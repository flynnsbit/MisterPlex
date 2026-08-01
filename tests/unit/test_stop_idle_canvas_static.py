#!/usr/bin/env python3
"""Host gate: stop/idle chrome authors on product 624x480 bank, not DECODE tier.

Parent measured STOPPED word span as 8x13-class on one capture; product font pick
is 12x16 only when canvas is bank-class (w>=600 or h>=480). paintIdle must:
  - call plex480pDdrFrameGeometry()
  - pass that cw/ch into overlay_.renderRgb24
  - log idle overlay canvas=WxH font=...
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / "arm" / "misterplexd" / "media_player.cpp"
OV = ROOT / "host" / "libmisterplex" / "playback_overlay.hpp"


def fail(msg: str) -> None:
    print(f"FAIL stop_idle_canvas: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    media = MEDIA.read_text()
    ov = OV.read_text()

    m = re.search(r"void\s+MediaPlayer::paintIdle\s*\(\s*\)\s*\{(.*?)\n\}", media, re.S)
    if not m:
        fail("paintIdle not found")
    body = m.group(1)
    if "plex480pDdrFrameGeometry()" not in body:
        fail("paintIdle must use plex480pDdrFrameGeometry() (product bank)")
    if "overlay_.renderRgb24(rgb.data(), cw, ch)" not in body:
        fail("paintIdle must render overlay at cw,ch from product geometry")
    if 'idle overlay canvas=' not in body:
        fail('paintIdle must log "idle overlay canvas=" for greppable WxH')

    # Font pick: product bank width or 480 height → 12x16
    if "w >= 600 || h >= 480" not in ov and "h >= 480 && m.bodyScale == 2" not in ov:
        # accept either new or old form if still product-correct
        fail("OverlayLayoutMetrics::compute must pick Large12x16 on product bank")
    if "w >= 600 || h >= 480" not in ov:
        fail("font pick must include w>=600 (product coded width) so short-H bank still gets 12x16")

    # Stopped sticky
    af = re.search(r"static int alphaFor\(const Snapshot& s, int64_t nowMs\) \{(.*?)\n    \}", ov, re.S)
    if not af or "PlaybackOverlayState::Stopped" not in af.group(1):
        fail("Stopped must be sticky in alphaFor (stop chrome survives warm-up)")

    print("stop_idle_canvas_static: OK")
    print("  paintIdle=plex480pDdrFrameGeometry → renderRgb24(cw,ch); Stopped sticky; font w>=600||h>=480")
    return 0


if __name__ == "__main__":
    sys.exit(main())
