#!/usr/bin/env python3
"""String read-back for playback overlay chrome (acceptance metric).

Recover a known string by template-matching the *shipped* MiSTerPlex overlay
glyph set (8x13 / 12x16 at bodyScale >= 2 from playback_overlay.hpp) against a
capture. Exact recovery is required for a measured PASS.

Capture geometry:
  - Content/coded rasters (~320-800 wide, height <= 600): matched directly.
  - HDMI grabber frames (e.g. 1920x1080): area-downsampled to a 640x480 content
    proxy before matching (DE ~529x240 -> ascal -> 1080p inverted approximately).
  - Unknown sizes: print verdict=UNSCORED and exit 77. Could-not-measure is
    never collapsed into measured-failure (rc=1).

Self-test pair (real HDMI, same device/grabber — the gate specification):
  RED  tests/unit/fixtures/overlay_readback/overlay_lowres_evidence.png
  GREEN tests/unit/fixtures/overlay_readback/overlay_FIXED_db3d9367_stopped.png

Prints recovered=... and a final line `true rc=N` (never through a pipe).
"""
from __future__ import annotations

import argparse
import struct
import sys
import zlib
from pathlib import Path

# Glyph tables MUST match host/libmisterplex/playback_overlay.hpp (CC0).
# 8x13 MSB=left of 8. 12x16 top-12 bits of uint16 MSB=left.

G8 = {
    "S": [0x00, 0x3C, 0x66, 0x60, 0x60, 0x3C, 0x06, 0x06, 0x06, 0x66, 0x3C, 0x00, 0x00],
    "T": [0x00, 0xFF, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x00],
    "O": [0x00, 0x3C, 0x66, 0xC3, 0xC3, 0xC3, 0xC3, 0xC3, 0xC3, 0x66, 0x3C, 0x00, 0x00],
    "P": [0x00, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x60, 0x60, 0x00, 0x00],
    "E": [0x00, 0x7E, 0x60, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00, 0x00],
    "D": [0x00, 0x78, 0x6C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00, 0x00],
    "A": [0x00, 0x3C, 0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x66, 0x66, 0x00, 0x00],
    "U": [0x00, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00, 0x00],
    "L": [0x00, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00, 0x00],
    "Y": [0x00, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x00],
    "I": [0x00, 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00],
    "N": [0x00, 0x66, 0x76, 0x7E, 0x7E, 0x6E, 0x66, 0x66, 0x66, 0x66, 0x66, 0x00, 0x00],
    "G": [0x00, 0x3C, 0x66, 0xC0, 0xC0, 0xDE, 0xC6, 0xC6, 0xC6, 0x66, 0x3C, 0x00, 0x00],
    "0": [0x00, 0x3C, 0x66, 0xC3, 0xC3, 0xC3, 0xC3, 0xC3, 0xC3, 0x66, 0x3C, 0x00, 0x00],
    "1": [0x00, 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00, 0x00],
    "2": [0x00, 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0xC0, 0xFE, 0x00, 0x00],
    "3": [0x00, 0x3C, 0x66, 0x06, 0x06, 0x1C, 0x06, 0x06, 0x06, 0x66, 0x3C, 0x00, 0x00],
    "4": [0x00, 0x0C, 0x1C, 0x3C, 0x6C, 0xCC, 0xFE, 0x0C, 0x0C, 0x0C, 0x0C, 0x00, 0x00],
    "5": [0x00, 0x7E, 0x60, 0x60, 0x7C, 0x06, 0x06, 0x06, 0x06, 0x66, 0x3C, 0x00, 0x00],
    "6": [0x00, 0x1C, 0x30, 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00, 0x00],
    "7": [0x00, 0xFE, 0x06, 0x0C, 0x0C, 0x18, 0x18, 0x30, 0x30, 0x30, 0x30, 0x00, 0x00],
    "8": [0x00, 0x3C, 0x66, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00, 0x00],
    "9": [0x00, 0x3C, 0x66, 0x66, 0x66, 0x3E, 0x06, 0x06, 0x06, 0x0C, 0x38, 0x00, 0x00],
    ":": [0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00],
    " ": [0] * 13,
}

G12 = {
    "S": [0x0000, 0x1F00, 0x30C0, 0x3000, 0x3000, 0x1F00, 0x00C0, 0x0060,
          0x0060, 0x0060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000, 0x0000],
    "T": [0x0000, 0x3FC0, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00,
          0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0000, 0x0000, 0x0000],
    "O": [0x0000, 0x1F00, 0x30C0, 0x6060, 0x6060, 0x6060, 0x6060, 0x6060,
          0x6060, 0x6060, 0x6060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000],
    "P": [0x0000, 0x3F00, 0x30C0, 0x3060, 0x3060, 0x30C0, 0x3F00, 0x3000,
          0x3000, 0x3000, 0x3000, 0x3000, 0x3000, 0x0000, 0x0000, 0x0000],
    "E": [0x0000, 0x3FC0, 0x3000, 0x3000, 0x3000, 0x3000, 0x3F00, 0x3000,
          0x3000, 0x3000, 0x3000, 0x3000, 0x3FC0, 0x0000, 0x0000, 0x0000],
    "D": [0x0000, 0x3E00, 0x3180, 0x30C0, 0x3060, 0x3060, 0x3060, 0x3060,
          0x3060, 0x3060, 0x30C0, 0x3180, 0x3E00, 0x0000, 0x0000, 0x0000],
    "A": [0x0000, 0x0F00, 0x1980, 0x30C0, 0x30C0, 0x30C0, 0x3FC0, 0x30C0,
          0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x0000, 0x0000],
    "U": [0x0000, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x30C0,
          0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000],
    "L": [0x0000, 0x3000, 0x3000, 0x3000, 0x3000, 0x3000, 0x3000, 0x3000,
          0x3000, 0x3000, 0x3000, 0x3000, 0x3FC0, 0x0000, 0x0000, 0x0000],
    "Y": [0x0000, 0x30C0, 0x30C0, 0x30C0, 0x1980, 0x0F00, 0x0600, 0x0600,
          0x0600, 0x0600, 0x0600, 0x0600, 0x0600, 0x0000, 0x0000, 0x0000],
    "I": [0x0000, 0x3F00, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00,
          0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x3F00, 0x0000, 0x0000, 0x0000],
    "N": [0x0000, 0x30C0, 0x38C0, 0x3CC0, 0x36C0, 0x36C0, 0x33C0, 0x31C0,
          0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x30C0, 0x0000, 0x0000, 0x0000],
    "G": [0x0000, 0x1F00, 0x30C0, 0x3000, 0x3000, 0x3000, 0x33C0, 0x3060,
          0x3060, 0x3060, 0x3060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000],
    "0": [0x0000, 0x1F00, 0x30C0, 0x6060, 0x6060, 0x6060, 0x6060, 0x6060,
          0x6060, 0x6060, 0x6060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000],
    "1": [0x0000, 0x0C00, 0x1C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x0C00,
          0x0C00, 0x0C00, 0x0C00, 0x0C00, 0x3F00, 0x0000, 0x0000, 0x0000],
    "2": [0x0000, 0x1F00, 0x30C0, 0x0060, 0x00C0, 0x0180, 0x0300, 0x0600,
          0x0C00, 0x1800, 0x3000, 0x3000, 0x3FC0, 0x0000, 0x0000, 0x0000],
    "3": [0x0000, 0x1F00, 0x30C0, 0x0060, 0x0060, 0x0F00, 0x0060, 0x0060,
          0x0060, 0x0060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000, 0x0000],
    "4": [0x0000, 0x0180, 0x0380, 0x0780, 0x0D80, 0x1980, 0x3180, 0x3FC0,
          0x0180, 0x0180, 0x0180, 0x0180, 0x0180, 0x0000, 0x0000, 0x0000],
    "5": [0x0000, 0x3FC0, 0x3000, 0x3000, 0x3F00, 0x00C0, 0x0060, 0x0060,
          0x0060, 0x0060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000, 0x0000],
    "6": [0x0000, 0x0F00, 0x1800, 0x3000, 0x3000, 0x3F00, 0x30C0, 0x3060,
          0x3060, 0x3060, 0x3060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000],
    "7": [0x0000, 0x3FC0, 0x0060, 0x00C0, 0x00C0, 0x0180, 0x0180, 0x0300,
          0x0300, 0x0600, 0x0600, 0x0600, 0x0600, 0x0600, 0x0000, 0x0000],
    "8": [0x0000, 0x1F00, 0x30C0, 0x3060, 0x3060, 0x30C0, 0x1F00, 0x30C0,
          0x3060, 0x3060, 0x3060, 0x30C0, 0x1F00, 0x0000, 0x0000, 0x0000],
    "9": [0x0000, 0x1F00, 0x30C0, 0x3060, 0x3060, 0x3060, 0x30C0, 0x1F60,
          0x0060, 0x0060, 0x0060, 0x00C0, 0x1F00, 0x0000, 0x0000, 0x0000],
    ":": [0x0000, 0x0000, 0x0C00, 0x0C00, 0x0000, 0x0000, 0x0000, 0x0000,
          0x0000, 0x0C00, 0x0C00, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000],
    " ": [0] * 16,
}

RC_PASS = 0
RC_FAIL = 1
RC_UNSCORED = 77


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def load_png_luma(path: Path):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"not a PNG: {path}")
    pos = 8
    width = height = None
    bit_depth = color_type = None
    idat = bytearray()
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        ctype = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            width, height, bit_depth, color_type, *_ = struct.unpack(">IIBBBBB", chunk)
        elif ctype == b"IDAT":
            idat.extend(chunk)
        elif ctype == b"IEND":
            break
    if width is None or bit_depth != 8 or color_type not in (2, 6):
        raise ValueError(f"unsupported PNG: {path}")
    raw = zlib.decompress(bytes(idat))
    bpp = 3 if color_type == 2 else 4
    stride = width * bpp + 1
    rows = []
    i = 0
    prev = bytearray(width * bpp)
    for _y in range(height):
        filt = raw[i]
        scan = bytearray(raw[i + 1 : i + stride])
        i += stride
        if filt == 1:
            for x in range(bpp, len(scan)):
                scan[x] = (scan[x] + scan[x - bpp]) & 255
        elif filt == 2:
            for x in range(len(scan)):
                scan[x] = (scan[x] + prev[x]) & 255
        elif filt == 3:
            for x in range(len(scan)):
                a = scan[x - bpp] if x >= bpp else 0
                scan[x] = (scan[x] + ((a + prev[x]) // 2)) & 255
        elif filt == 4:
            for x in range(len(scan)):
                a = scan[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                scan[x] = (scan[x] + pr) & 255
        elif filt != 0:
            raise ValueError(f"bad PNG filter {filt}")
        prev = scan
        row = []
        for x in range(width):
            r, g, b = scan[x * bpp], scan[x * bpp + 1], scan[x * bpp + 2]
            row.append((77 * r + 150 * g + 29 * b) >> 8)
        rows.append(row)
    return width, height, rows


def area_downsample(rows, tw: int, th: int):
    H = len(rows)
    W = len(rows[0]) if H else 0
    out = [[0] * tw for _ in range(th)]
    for y in range(th):
        y0 = y * H // th
        y1 = max(y0 + 1, (y + 1) * H // th)
        for x in range(tw):
            x0 = x * W // tw
            x1 = max(x0 + 1, (x + 1) * W // tw)
            s = n = 0
            for yy in range(y0, y1):
                r = rows[yy]
                for xx in range(x0, x1):
                    s += r[xx]
                    n += 1
            out[y][x] = s // n if n else 0
    return out


def normalize_capture(rows):
    """Map capture into a content-class raster. (rows, tag) or (None, reason)."""
    H = len(rows)
    W = len(rows[0]) if H else 0
    if W <= 0 or H <= 0:
        return None, "empty"
    if W >= 1280 and H >= 720:
        return area_downsample(rows, 640, 480), f"hdmi_norm_640x480_from_{W}x{H}"
    if 240 <= W <= 960 and 160 <= H <= 720:
        return rows, f"content_{W}x{H}"
    return None, f"unsupported_geometry_{W}x{H}"


def font_geom(font: str):
    if font == "8x13":
        return 8, 13, 9, G8
    if font == "12x16":
        return 12, 16, 13, G12
    raise ValueError(font)


def glyph_on(font: str, ch: str, row: int, col: int) -> bool:
    gw, gh, _adv, table = font_geom(font)
    key = ch.upper() if ch.isalpha() else ch
    bits = table.get(key, table.get(" ", [0] * gh))
    if row < 0 or row >= gh or col < 0 or col >= gw:
        return False
    if font == "12x16":
        return (bits[row] & (1 << (15 - col))) != 0
    return (bits[row] & (1 << (7 - col))) != 0


def render_mask(text: str, font: str, scale: int):
    gw, gh, adv, _ = font_geom(font)
    sc = max(1, scale)
    w = max(1, len(text) * adv * sc - sc + gw * sc)
    h = gh * sc
    mask = [[0] * w for _ in range(h)]
    x = 0
    for ch in text:
        for row in range(gh):
            for col in range(gw):
                if not glyph_on(font, ch, row, col):
                    continue
                for vr in range(sc):
                    for hr in range(sc):
                        yy = row * sc + vr
                        xx = x + col * sc + hr
                        if 0 <= yy < h and 0 <= xx < w:
                            mask[yy][xx] = 1
        x += adv * sc
    return mask


def separation_score(rows, x0: int, y0: int, mask) -> float:
    """Ink vs background separation in [0,1]. Tolerates mild ascal blur."""
    H = len(rows)
    W = len(rows[0]) if H else 0
    mh = len(mask)
    mw = len(mask[0]) if mh else 0
    on_s = on_n = off_s = off_n = 0
    for r in range(mh):
        yy = y0 + r
        if yy < 0 or yy >= H:
            continue
        row = rows[yy]
        mrow = mask[r]
        for c in range(mw):
            xx = x0 + c
            if xx < 0 or xx >= W:
                continue
            v = row[xx]
            if mrow[c]:
                on_s += v
                on_n += 1
            else:
                off_s += v
                off_n += 1
    if on_n < 8 or off_n < 8:
        return 0.0
    on_m = on_s / on_n
    off_m = off_s / off_n
    if on_m < 90:
        return 0.0
    sep = (on_m - off_m) / 255.0
    if sep < 0:
        return 0.0
    bright = max(0.0, (on_m - 80) / 175.0)
    return max(0.0, min(1.0, 0.55 * sep + 0.45 * min(1.0, bright)))


def find_string(rows, text: str):
    """Search bottom panel. Shipped fonts only: 8x13/12x16 at scale >= 2."""
    H = len(rows)
    W = len(rows[0]) if H else 0
    y_lo = int(H * 0.55)
    configs = [("12x16", 2), ("8x13", 2), ("12x16", 3), ("8x13", 3)]
    best = (0.0, "", None)

    def search(mask, font, sc, step_x, step_y, x_lo=0, x_hi=None, y0_lo=None, y0_hi=None):
        nonlocal best
        mh, mw = len(mask), len(mask[0])
        if x_hi is None:
            x_hi = max(1, W - mw)
        if y0_lo is None:
            y0_lo = y_lo & ~1
        if y0_hi is None:
            y0_hi = max(y0_lo + 1, H - mh - 1)
        for y0 in range(y0_lo, y0_hi, step_y):
            for x0 in range(x_lo, x_hi, step_x):
                s = separation_score(rows, x0, y0, mask)
                if s > best[0]:
                    best = (s, text if s >= 0.40 else "", {
                        "font": font, "scale": sc, "x": x0, "y": y0, "score": s,
                    })
                    if s >= 0.58:
                        return True
        return False

    for font, sc in configs:
        mask = render_mask(text, font, sc)
        coarse_x = max(2, sc * 2)
        coarse_y = max(2, sc * 2)
        if search(mask, font, sc, coarse_x, coarse_y):
            return text, best[0], best[2]
        if best[2] and best[2].get("font") == font and best[2].get("scale") == sc and best[0] >= 0.28:
            bx, by = best[2]["x"], best[2]["y"]
            mh, mw = len(mask), len(mask[0])
            if search(mask, font, sc, 1, 2,
                      x_lo=max(0, bx - coarse_x),
                      x_hi=min(W - mw, bx + coarse_x + 1),
                      y0_lo=max(y_lo & ~1, by - coarse_y),
                      y0_hi=min(H - mh, by + coarse_y + 1)):
                return text, best[0], best[2]
    score, recovered, meta = best
    if score < 0.40:
        recovered = ""
    return recovered, score, meta


def print_result(code: int, **fields) -> int:
    print(" ".join(f"{k}={v}" for k, v in fields.items()))
    print(f"true rc={code}")
    return code


def run_image(path: Path, expect: str) -> int:
    _w, _h, rows = load_png_luma(path)
    norm, tag = normalize_capture(rows)
    if norm is None:
        print(f"image={path}")
        print(f"geometry_tag={tag}")
        return print_result(RC_UNSCORED, recovered="<unscored>", expect=expect,
                            verdict="UNSCORED")
    recovered, score, meta = find_string(norm, expect)
    print(f"image={path}")
    print(f"geometry_tag={tag}")
    print(f"meta={meta}")
    print(f"score={score:.4f}")
    ok = recovered == expect
    return print_result(RC_PASS if ok else RC_FAIL,
                        recovered=recovered or "<empty>", expect=expect,
                        verdict="PASS" if ok else "FAIL")


def fixture_paths():
    """Prefer permanent unit fixtures; fall back to .agent-work / files copies."""
    root = repo_root()
    candidates_red = [
        root / "tests/unit/fixtures/overlay_readback/overlay_lowres_evidence.png",
        root / ".agent-work/osd-hires/overlay_lowres_evidence.png",
    ]
    candidates_green = [
        root / "tests/unit/fixtures/overlay_readback/overlay_FIXED_db3d9367_stopped.png",
        root / ".agent-work/osd-hires/overlay_FIXED_db3d9367_stopped.png",
        root / "files/device-evidence/overlay_FIXED_db3d9367_stopped.png",
    ]
    red = next((p for p in candidates_red if p.is_file()), candidates_red[0])
    green = next((p for p in candidates_green if p.is_file()), candidates_green[0])
    return red, green


def selftest_pair() -> int:
    red_path, green_path = fixture_paths()
    if not red_path.is_file() or not green_path.is_file():
        return print_result(RC_FAIL, recovered="<missing_fixtures>",
                            error=f"need {red_path} and {green_path}")
    expect = "STOPPED"

    _w, _h, rows = load_png_luma(red_path)
    norm, tag = normalize_capture(rows)
    if norm is None:
        return print_result(RC_UNSCORED, recovered="<unscored>", verdict="UNSCORED_RED",
                            geometry_tag=tag)
    r_rec, r_score, r_meta = find_string(norm, expect)
    red_ok = r_rec != expect
    print(f"red_image={red_path}")
    print(f"red_geometry_tag={tag}")
    print(f"red_meta={r_meta}")
    print(f"red_score={r_score:.4f} red_recovered={r_rec or '<empty>'}")

    _w, _h, rows = load_png_luma(green_path)
    norm, tag = normalize_capture(rows)
    if norm is None:
        return print_result(RC_UNSCORED, recovered="<unscored>", verdict="UNSCORED_GREEN",
                            geometry_tag=tag)
    g_rec, g_score, g_meta = find_string(norm, expect)
    green_ok = g_rec == expect
    print(f"green_image={green_path}")
    print(f"green_geometry_tag={tag}")
    print(f"green_meta={g_meta}")
    print(f"green_score={g_score:.4f} green_recovered={g_rec or '<empty>'}")

    if red_ok and green_ok:
        return print_result(RC_PASS, recovered=g_rec, expect=expect, verdict="PAIR_OK")
    if not red_ok and not green_ok:
        return print_result(RC_FAIL, recovered=g_rec or "<empty>", expect=expect,
                            verdict="PAIR_BOTH_WRONG")
    if not red_ok:
        return print_result(RC_FAIL, recovered=g_rec or "<empty>", expect=expect,
                            verdict="PAIR_FALSE_GREEN_ON_RED")
    return print_result(RC_FAIL, recovered=g_rec or "<empty>", expect=expect,
                        verdict="PAIR_FALSE_RED_ON_GREEN")


def selftest_synthetic_green() -> int:
    W, H = 640, 480
    rows = [[20] * W for _ in range(H)]
    margin = max(6, W // 40)
    panel_h = 120
    py = (H - panel_h - margin) & ~1
    for y in range(py, min(H, py + panel_h)):
        for x in range(margin, W - margin):
            rows[y][x] = 40
    sc = 2
    font = "12x16"
    gw, gh, adv, _ = font_geom(font)
    label_y = (py + 6) & ~1
    x = margin + 18 + 14 + 8 * sc
    text = "STOPPED"
    for ch in text:
        for row in range(gh):
            for col in range(gw):
                if not glyph_on(font, ch, row, col):
                    continue
                for vr in range(sc):
                    for hr in range(sc):
                        yy = label_y + row * sc + vr
                        xx = x + col * sc + hr
                        if 0 <= yy < H and 0 <= xx < W:
                            rows[yy][xx] = 235
        x += adv * sc
    culled = rows[0::2]
    full = []
    for r in culled:
        full.append(list(r))
        full.append(list(r))
    recovered, score, meta = find_string(full[:480], text)
    print(f"meta={meta}")
    print(f"score={score:.4f}")
    ok = recovered == text
    return print_result(RC_PASS if ok else RC_FAIL,
                        recovered=recovered or "<empty>", expect=text,
                        verdict="SYNTH_GREEN_OK" if ok else "SYNTH_GREEN_FAIL")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--image", type=Path)
    ap.add_argument("--expect", default="STOPPED")
    ap.add_argument("--selftest-pair", action="store_true",
                    help="RED on lowres evidence + GREEN on FIXED silicon capture")
    ap.add_argument("--selftest-red", action="store_true")
    ap.add_argument("--selftest-green", action="store_true",
                    help="Synthetic DE-cull GREEN (pair is the real gate)")
    args = ap.parse_args(argv)

    if args.selftest_pair:
        return selftest_pair()
    if args.selftest_red:
        red_path, _ = fixture_paths()
        _w, _h, rows = load_png_luma(red_path)
        norm, tag = normalize_capture(rows)
        if norm is None:
            return print_result(RC_UNSCORED, recovered="<unscored>", verdict="UNSCORED")
        rec, score, meta = find_string(norm, args.expect)
        print(f"evidence={red_path}")
        print(f"geometry_tag={tag}")
        print(f"meta={meta}")
        print(f"score={score:.4f}")
        ok_red = rec != args.expect
        return print_result(RC_PASS if ok_red else RC_FAIL,
                            recovered=rec or "<empty>", expect=args.expect,
                            verdict="RED_OK" if ok_red else "FALSE_GREEN")
    if args.selftest_green:
        return selftest_synthetic_green()
    if not args.image:
        ap.error("need --image or --selftest-pair")
    return run_image(args.image, args.expect)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print(f"error={e}", file=sys.stderr)
        print("true rc=1")
        sys.exit(1)
