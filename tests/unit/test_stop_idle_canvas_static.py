#!/usr/bin/env python3
"""Host gate: stop/idle chrome authors on product 624x480 bank, not DECODE tier.

Product font pick is 12x16 only when h>=480 && bodyScale==2 (no w>=600 mask).
paintIdle must:
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

    # Font pick: h>=480 && bodyScale==2 only (no w>=600 mask — that would hide short-H).
    if "h >= 480 && m.bodyScale == 2" not in ov:
        fail("OverlayLayoutMetrics::compute must pick Large12x16 when h>=480 && bodyScale==2")
    if "w >= 600" in ov:
        fail("font pick must NOT use w>=600 (dead on product path; masks h<480 defect)")
    # Stopped sticky
    af = re.search(r"static int alphaFor\(const Snapshot& s, int64_t nowMs\) \{(.*?)\n    \}", ov, re.S)
    if not af or "PlaybackOverlayState::Stopped" not in af.group(1):
        fail("Stopped must be sticky in alphaFor (stop chrome survives warm-up)")

    print("stop_idle_canvas_static: OK")
    print("  paintIdle=plex480pDdrFrameGeometry → renderRgb24(cw,ch); Stopped sticky; font h>=480&&scale2 only")
    return 0


if __name__ == "__main__":
    sys.exit(main())
