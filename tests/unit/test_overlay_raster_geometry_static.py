#!/usr/bin/env python3
"""Pin transport/idle overlay raster to the DDR bank/coded canvas — not decode tier.

User requirement: overlays must not inherit streaming content resolution.
Product ARM path can only author into the silicon bank (plex480pDdrFrameGeometry /
ddrGeometry.coded_*). True HDMI video_mode WxH is applied later by ascal and is
NOT known to the daemon (no video_mode read). This gate fails if paintIdle or
pause/play overlay compositing regresses to a hard-coded 320×240 or to outW_/outH_
decode ladder sizes.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / "arm" / "misterplexd" / "media_player.cpp"


def fail(msg: str) -> None:
    print(f"FAIL overlay_raster_geometry: {msg}", file=sys.stderr)
    sys.exit(1)


def extract_fn(src: str, name: str) -> str:
    m = re.search(rf"\n(?:bool|void)\s+MediaPlayer::{name}\s*\([^)]*\)\s*\{{", src)
    if not m:
        fail(f"missing MediaPlayer::{name}")
    start = m.start()
    i = src.find("{", m.end() - 1)
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[start : j + 1]
    fail(f"unbalanced braces in {name}")


def main() -> int:
    src = MEDIA.read_text()

    paint = extract_fn(src, "paintIdle")
    if "plex480pDdrFrameGeometry()" not in paint:
        fail("paintIdle must size chrome from plex480pDdrFrameGeometry() (bank/coded)")
    if re.search(r"const\s+int\s+w\s*=\s*320\s*;", paint) or re.search(
        r"const\s+int\s+h\s*=\s*240\s*;", paint
    ):
        fail("paintIdle must not hard-code 320×240 (decode-tier regression)")
    if "overlay_.renderRgb24(rgb.data(), cw, ch)" not in paint and \
       "overlay_.renderRgb24(buf.data(), cw, ch)" not in paint:
        # allow either rgb or buf name but must use cw,ch from geometry
        if not re.search(r"overlay_\.renderRgb24\([^,]+,\s*cw,\s*ch\)", paint):
            fail("paintIdle overlay must render at cw,ch from coded geometry")
    if "outW_" in paint or "outH_" in paint:
        fail("paintIdle must not size overlay from decode ladder outW_/outH_")

    pause = extract_fn(src, "publishPausedOverlayFrame")
    if "plex480pDdrFrameGeometry()" not in pause:
        fail("publishPausedOverlayFrame must use plex480pDdrFrameGeometry()")
    if "overlay_.renderYuv420p(yuv.data(), cw, ch)" not in pause:
        fail("pause overlay must renderYuv420p at coded cw,ch")
    if re.search(r"const\s+int\s+w\s*=\s*320\s*;", pause):
        fail("pause overlay must not hard-code 320")

    # Play path: rawW/rawH must come from ddrGeometry.coded_* (bank), not outW_
    if "const int rawW = ddrGeometry.coded_width.get();" not in src:
        fail("playback rawW must be ddrGeometry.coded_width (bank), not decode tier")
    if "const int rawH = ddrGeometry.coded_height.get();" not in src:
        fail("playback rawH must be ddrGeometry.coded_height (bank), not decode tier")
    if "overlay_.renderYuv420p(data, rawW, rawH)" not in src:
        fail("playback Yuv420p branch must call overlay_.renderYuv420p")

    # Post-upscale contract: FPGA present must force silicon bank, never
    # ddrFrameGeometryForPresentedSize(outW_, outH_) which identity-maps DECODE.
    if "ddrFrameGeometryForFpgaPresent(outW_, outH_)" not in src:
        fail("playback must use ddrFrameGeometryForFpgaPresent (bank), not presented-size(DECODE)")
    if re.search(
        r"ddrFrameGeometryForPresentedSize\(\s*outW_\s*,\s*outH_\s*\)", src
    ):
        fail(
            "REGRESSION: ddrFrameGeometryForPresentedSize(outW_, outH_) authors at "
            "DECODE when conf is 320×240 — overlay pre-upscale defect"
        )
    # Yuv420p overlay must not be a no-op (main still has bare break).
    yuv_case = re.search(
        r"case\s+RawVideoFormat::Yuv420p\s*:\s*(.*?)break\s*;",
        src,
        re.S,
    )
    if not yuv_case:
        fail("missing Yuv420p case in present path")
    # Find the renderOverlay lambda's Yuv branch specifically
    ro = re.search(
        r"auto\s+renderOverlay\s*=\s*\[\&\]\s*\(uint8_t\*\s*data\)\s*\{(.*?)\}\s*;",
        src,
        re.S,
    )
    if not ro:
        fail("missing renderOverlay lambda")
    body = ro.group(1)
    yuv_in_ro = re.search(
        r"case\s+RawVideoFormat::Yuv420p\s*:\s*(.*?)break\s*;", body, re.S
    )
    if not yuv_in_ro:
        fail("renderOverlay missing Yuv420p case")
    if "renderYuv420p" not in yuv_in_ro.group(1):
        fail("renderOverlay Yuv420p must call renderYuv420p (not empty break)")
    # RED twin: paintIdle sized at 320×240 must trip the bank-geometry rule.
    paint_bad = paint.replace(
        "const DdrFrameGeometry g = plex480pDdrFrameGeometry();\n"
        "    const int cw = g.coded_width.get();\n"
        "    const int ch = g.coded_height.get();",
        "const int cw = 320;\n"
        "    const int ch = 240;",
        1,
    )
    if paint_bad == paint or "plex480pDdrFrameGeometry()" in paint_bad:
        fail("could not build paintIdle 320×240 mutant for red twin")
    if "const int cw = 320" not in paint_bad:
        fail("red twin mutant missing 320 coded width")
    # Prove the gate's paintIdle checks would fail on the mutant body.
    if "plex480pDdrFrameGeometry()" in paint_bad:
        fail("red twin still has bank geometry")
    if not re.search(r"const\s+int\s+cw\s*=\s*320\s*;", paint_bad):
        fail("red twin did not hard-code 320")

    print(
        "test_overlay_raster_geometry_static: OK "
        "paintIdle+pause=plex480pDdrFrameGeometry "
        "playback=rawW/rawH from ddrGeometry.coded_* "
        "no 320×240 overlay authoring; "
        "NOTE: HDMI video_mode WxH is ascal-side — ARM has no output-mode read"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
