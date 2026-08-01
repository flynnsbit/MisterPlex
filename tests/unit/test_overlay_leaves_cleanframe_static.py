#!/usr/bin/env python3
"""Pin: F1 chrome is baked via renderOverlay(cleanFrame) before publishDdrFrame.

Parent root line (this tip ~3156/3162): that is the user bug mechanism.
When CHROME_PLANE / plane=1 lands, presentCleanFrame must NOT call
renderOverlay into cleanFrame. Until then this gate documents the defect path
and fails if the call is removed without a plane branch (silent chrome loss).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / "arm" / "misterplexd" / "media_player.cpp"


def fail(msg: str) -> None:
    print(f"FAIL overlay_leaves_cleanframe: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    src = MEDIA.read_text()
    # presentCleanFrame must still contain renderOverlay(cleanFrame) for plane=0
    if src.count("renderOverlay(cleanFrame)") < 1:
        fail("missing renderOverlay(cleanFrame) — plane=0 path regress or incomplete plane cutover")
    # Must still publish DDR after present path exists
    if "publishDdrFrame(frame, \"playback DDR\"" not in src and 'publishDdrFrame(frame, "playback DDR"' not in src:
        fail("missing playback DDR publish")
    # Design docs must exist for native path
    design = ROOT / "docs" / "osd-native-raster-arm-design.md"
    if not design.is_file():
        fail("missing docs/osd-native-raster-arm-design.md")
    d = design.read_text()
    if "renderOverlay(cleanFrame)" not in d and "3156" not in d:
        fail("design must cite the cleanFrame bake line")
    if "plane=1" not in d:
        fail("design must define plane=1 skip of F1 bake")
    # content_width must not be recommended as HDMI size
    if re.search(r"content_width.*output", d, re.I) and "must **not**" not in d and "must not" not in d.lower():
        fail("design must not treat content_width as HDMI without negation")
    print("PASS overlay_leaves_cleanframe: F1 bake path present; native design pinned")
    return 0


if __name__ == "__main__":
    sys.exit(main())
