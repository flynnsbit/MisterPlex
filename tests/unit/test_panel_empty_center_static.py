#!/usr/bin/env python3
"""Host red-before-green: pause panel empty center must not be translucent pure black.

Silicon (3883f5ab Test B residual): solid black rectangle inside paused panel at
approx store x247-397 y360-404 (HDMI rows 809-910 / x740-1190), interior luma ~40
vs surrounding chrome grey.

Source RCA (quoted, not guessed):
  playback_overlay.hpp render(): historically
    fillRect(..., black, (170 * alpha) / 255);
  with no title/metadata drawn into the band right of the state label. That is
  NOT a separate title widget and NOT a dirty-rect hole (dirtyBounds = full panel).
  Classification: (c) empty panel interior under translucent pure-black fill.

GREEN requires:
  - panel fill uses an opaque/high-alpha non-black panelBg (not pure black@170)
  - setTitle + title draw path exists so the band can carry media title text
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OV = ROOT / "host" / "libmisterplex" / "playback_overlay.hpp"
MEDIA_H = ROOT / "arm" / "misterplexd" / "media_player.hpp"
MAIN = ROOT / "arm" / "misterplexd" / "main.cpp"


def fail(msg: str) -> None:
    print(f"FAIL panel_empty_center: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    ov = OV.read_text()
    media_h = MEDIA_H.read_text()
    main_cpp = MAIN.read_text()

    # Locate render() panel fill.
    m = re.search(
        r"static void render\(Target& t, const Snapshot& s, int w, int h, int64_t nowMs\) \{(.*)\n    \}",
        ov,
        re.S,
    )
    if not m:
        fail("render() not found")
    body = m.group(1)

    # RED pattern: pure black panel at alpha 170 (the silicon hole).
    if re.search(r"fillRect\(\s*t,\s*p\.x,\s*p\.y,\s*p\.w,\s*p\.h,\s*black\s*,\s*\(170\s*\*\s*alpha\)", body):
        fail("panel still fillRect black@(170*alpha) — translucent pure-black hole")

    if "panelBg" not in body:
        fail("render must use named panelBg chrome color (not anonymous black)")

    # Must fill with panelBg at full (or near-full) alpha — not * 170/255.
    if not re.search(r"fillRect\(\s*t,\s*p\.x,\s*p\.y,\s*p\.w,\s*p\.h,\s*panelBg\s*,\s*alpha\s*\)", body):
        fail("panel fill must be fillRect(..., panelBg, alpha) opaque chrome")

    # panelBg must not be pure black {0,0,0}.
    bg = re.search(r"constexpr Color panelBg\{(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\}", body)
    if not bg:
        fail("panelBg RGB literal not found")
    r, g, b = int(bg.group(1)), int(bg.group(2)), int(bg.group(3))
    if r + g + b < 60:
        fail(f"panelBg too dark ({r},{g},{b}) — would still read as black hole")
    if max(r, g, b) > 120:
        fail(f"panelBg too light ({r},{g},{b}) — chrome should stay dark grey")

    # Title path: setTitle + draw into former empty band.
    if "void setTitle(" not in ov:
        fail("PlaybackOverlay::setTitle missing")
    if "s.titleText" not in body and "titleText" not in body:
        fail("render must draw titleText into panel")
    if "fitText(" not in ov:
        fail("fitText helper required for title truncation")

    # Plumbing: daemon exposes setOverlayTitle and doPlay sets it from resolve.
    if "setOverlayTitle" not in media_h:
        fail("MediaPlayer::setOverlayTitle missing")
    if "setOverlayTitle(resolved.title)" not in main_cpp:
        fail("main doPlay must player.setOverlayTitle(resolved.title)")

    print("panel_empty_center_static: OK")
    print(f"  panelBg=({r},{g},{b}) opaque alpha; title path present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
