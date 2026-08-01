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
    # Localization: default coarse_y=2; legacy RED arm uses coarse_y=4
    if "coarse_y: int = 2" not in rb and "coarse_y=2" not in rb:
        fail("readback find_string default must be coarse_y=2 (step-4 missed PAUSED y=350)")
    if "coarse_y=4" not in rb or "left_label_pass=False" not in rb:
        fail("selftest must keep RED arm with coarse_y=4,left_label_pass=False")
    if "selftest_pause_localize" not in rb:
        fail("missing --selftest-pause-localize gate")
    if "PAUSE_LOCALIZE_PAIR_OK" not in rb and "RED_legacy" not in rb:
        fail("pause localize must be a RED/GREEN pair, not green-only")
    print("pause_canvas_font_static: OK")
    print("  pause=plex480p + renderYuv420p(cw,ch) + canvas/font log; readback coarse_y=2")
    return 0


if __name__ == "__main__":
    sys.exit(main())
