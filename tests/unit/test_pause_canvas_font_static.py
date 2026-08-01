#!/usr/bin/env python3
"""Host gate: pause chrome authors at product bank + logs canvas/font.

S1/S2: publishPausedOverlayFrame must call plex480pDdrFrameGeometry and
renderYuv420p(cw,ch), and log media: pause overlay canvas=... font=...
so a short-canvas claim is greppable. Localization fix lives in
tools/readback_overlay_text.py (coarse_y=2 + left-label pass).
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / "arm" / "misterplexd" / "media_player.cpp"
READBACK = ROOT / "tools" / "readback_overlay_text.py"


def fail(msg: str) -> None:
    print(f"FAIL pause_canvas_font: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    media = MEDIA.read_text()
    rb = READBACK.read_text()
    m = re.search(
        r"bool\s+MediaPlayer::publishPausedOverlayFrame\s*\(\s*\)\s*\{(.*?)\n\}",
        media,
        re.S,
    )
    if not m:
        fail("publishPausedOverlayFrame not found")
    body = m.group(1)
    if "plex480pDdrFrameGeometry()" not in body:
        fail("pause path must use plex480pDdrFrameGeometry()")
    if "overlay_.renderYuv420p(yuv.data(), cw, ch)" not in body:
        fail("pause must renderYuv420p at cw,ch from product geometry")
    if "pause overlay canvas=" not in body:
        fail('must log "pause overlay canvas=" with font=')
    if 'font=' not in body:
        fail("pause canvas log must include font=")
    # Localization: must not regress to coarse_y = sc*2 (step 4)
    if "coarse_y = 2" not in rb:
        fail("readback find_string must use coarse_y = 2 (step-4 missed PAUSED y=350)")
    if "selftest_pause_localize" not in rb:
        fail("missing --selftest-pause-localize gate")
    print("pause_canvas_font_static: OK")
    print("  pause=plex480p + renderYuv420p(cw,ch) + canvas/font log; readback coarse_y=2")
    return 0


if __name__ == "__main__":
    sys.exit(main())
