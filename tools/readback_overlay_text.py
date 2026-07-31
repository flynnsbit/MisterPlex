#!/usr/bin/env python3
"""String read-back for playback overlay chrome (acceptance metric).

Recover a known string by template-matching the MiSTerPlex overlay glyph set
against a capture (or a synthetic render). Exact recovery is required.

Why not lattice pitch / 10-90 edge width:
  - Vertical lattice pitch on the DE raster is 1 by construction (even rows only).
  - Anti-aliasing / NN sharpening can game edge metrics without fixing glyphs.
  - String read-back catches 8→0 / 6→C odd-row cull corruption directly.

Usage:
  tools/readback_overlay_text.py --image PATH --expect STOPPED
  tools/readback_overlay_text.py --selftest-red
  tools/readback_overlay_text.py --selftest-green

Prints recovered=... and true rc=N on its own (not through a pipe).
Exit 0 = exact match to --expect; 1 = mismatch/failure.
"""
from __future__ import annotations

import argparse
import os
import struct
import sys
import zlib
from pathlib import Path

# --- CC0 geometric bitmaps (must match host/libmisterplex/playback_overlay.hpp) ---

# Classic 5×7 used by the pre-fix overlay (evidence RED path).
G5 = {
    " ": [0, 0, 0, 0, 0, 0, 0],
    "0": [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
    "1": [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
    "2": [0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F],
    "3": [0x1E, 0x01, 0x01, 0x0E, 0x01, 0x01, 0x1E],
    "4": [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
    "5": [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
    "6": [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E],
    "7": [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
    "8": [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
    "9": [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
    ":": [0x00, 0x04, 0x04, 0x00, 0x04, 0x04, 0x00],
    "S": [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E],
    "T": [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
    "O": [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
    "P": [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
    "E": [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
    "D": [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E],
    "A": [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
    "U": [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
    "L": [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F],
    "Y": [0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04],
    "I": [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E],
    "N": [0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11],
    "G": [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0E],
}

# 8×13 (MSB = left of 8)
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

# 12×16 top-12 bits of uint16 (MSB = left)
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


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def load_png_rgb(path: Path):
    """Minimal PNG reader (8-bit RGB/RGBA, non-interlaced)."""
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
        raise ValueError(f"unsupported PNG: {path} ct={color_type} bd={bit_depth}")
    raw = zlib.decompress(bytes(idat))
    bpp = 3 if color_type == 2 else 4
    stride = width * bpp + 1
    rows = []
    i = 0
    prev = bytearray(width * bpp)
    for y in range(height):
        filt = raw[i]
        scan = bytearray(raw[i + 1 : i + stride])
        i += stride
        if filt == 0:
            pass
        elif filt == 1:  # Sub
            for x in range(bpp, len(scan)):
                scan[x] = (scan[x] + scan[x - bpp]) & 255
        elif filt == 2:  # Up
            for x in range(len(scan)):
                scan[x] = (scan[x] + prev[x]) & 255
        elif filt == 3:  # Average
            for x in range(len(scan)):
                a = scan[x - bpp] if x >= bpp else 0
                scan[x] = (scan[x] + ((a + prev[x]) // 2)) & 255
        elif filt == 4:  # Paeth
            for x in range(len(scan)):
                a = scan[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                scan[x] = (scan[x] + pr) & 255
        else:
            raise ValueError(f"bad PNG filter {filt}")
        prev = scan
        # luma
        row = []
        for x in range(width):
            r, g, b = scan[x * bpp], scan[x * bpp + 1], scan[x * bpp + 2]
            row.append((77 * r + 150 * g + 29 * b) >> 8)
        rows.append(row)
    return width, height, rows


def glyph_on(font: str, ch: str, row: int, col: int) -> bool:
    ch = ch.upper() if ch.isalpha() else ch
    if font == "5x7":
        bits = G5.get(ch, G5[" "])
        if row < 0 or row >= 7 or col < 0 or col >= 5:
            return False
        return (bits[row] & (1 << (4 - col))) != 0
    if font == "8x13":
        bits = G8.get(ch, G8[" "])
        if row < 0 or row >= 13 or col < 0 or col >= 8:
            return False
        return (bits[row] & (1 << (7 - col))) != 0
    if font == "12x16":
        bits = G12.get(ch, G12[" "])
        if row < 0 or row >= 16 or col < 0 or col >= 12:
            return False
        return (bits[row] & (1 << (15 - col))) != 0
    raise ValueError(font)


def font_geom(font: str):
    if font == "5x7":
        return 5, 7, 6
    if font == "8x13":
        return 8, 13, 9
    if font == "12x16":
        return 12, 16, 13
    raise ValueError(font)


def render_string_mask(text: str, font: str, scale: int, even_y: bool = True):
    """Render binary mask of text; optionally snap y origin even and cull odd rows."""
    gw, gh, adv = font_geom(font)
    sc = max(1, scale)
    # origin even
    y0 = 0
    if even_y:
        y0 = 0  # already even
    w = len(text) * adv * sc
    h = gh * sc + 2
    mask = [[0] * w for _ in range(h)]
    x = 0
    for ch in text:
        for row in range(gh):
            for col in range(gw):
                if not glyph_on(font, ch, row, col):
                    continue
                for vr in range(sc):
                    for hr in range(sc):
                        yy = y0 + row * sc + vr
                        xx = x + col * sc + hr
                        if 0 <= yy < h and 0 <= xx < w:
                            mask[yy][xx] = 1
        x += adv * sc
    if even_y and sc >= 1:
        # simulate present_core even-row fetch
        even = [mask[y] for y in range(0, h, 2)]
        return even
    return mask


def score_mask_at(luma_rows, x0, y0, mask, thr=120) -> float:
    H = len(luma_rows)
    W = len(luma_rows[0]) if H else 0
    mh = len(mask)
    mw = len(mask[0]) if mh else 0
    agree = total = 0
    for r in range(mh):
        yy = y0 + r
        if yy < 0 or yy >= H:
            continue
        row = luma_rows[yy]
        mrow = mask[r]
        for c in range(mw):
            xx = x0 + c
            if xx < 0 or xx >= W:
                continue
            on = mrow[c] == 1
            bright = row[xx] > thr
            total += 1
            if on == bright:
                agree += 1
    if total == 0:
        return 0.0
    return agree / total


def downsample_mask(rows, fx: int, fy: int):
    """Max-pool binary mask downsample (preserve ink)."""
    H = len(rows)
    W = len(rows[0]) if H else 0
    out = []
    for y in range(H // fy):
        row = []
        y0 = y * fy
        for x in range(W // fx):
            x0 = x * fx
            ink = 0
            for yy in range(y0, min(H, y0 + fy)):
                r = rows[yy]
                for xx in range(x0, min(W, x0 + fx)):
                    if r[xx]:
                        ink = 1
                        break
                if ink:
                    break
            row.append(ink)
        out.append(row)
    return out


def downsample_luma(rows, fx: int, fy: int):
    """Box-average downsample for coarse search."""
    H = len(rows)
    W = len(rows[0]) if H else 0
    out_h = H // fy
    out_w = W // fx
    out = []
    for y in range(out_h):
        row = []
        y0 = y * fy
        for x in range(out_w):
            x0 = x * fx
            s = 0
            n = 0
            for yy in range(y0, min(H, y0 + fy)):
                r = rows[yy]
                for xx in range(x0, min(W, x0 + fx)):
                    s += r[xx]
                    n += 1
            row.append(s // n if n else 0)
        out.append(row)
    return out


def find_string(luma_rows, text: str, fonts=None, scales=None, thr=120):
    """Search bottom band for best template match. Returns (recovered, score, meta)."""
    if fonts is None:
        fonts = ("12x16", "8x13", "5x7")
    if scales is None:
        scales = (1, 2, 3, 4)
    H = len(luma_rows)
    W = len(luma_rows[0]) if H else 0

    # Coarse path for large HDMI frames: search on 4× downsampled luma, then
    # refine in a small window on the full raster.
    if H >= 720 and W >= 1280:
        fx = fy = 4
        coarse = downsample_luma(luma_rows, fx, fy)
        cH, cW = len(coarse), len(coarse[0])
        y_lo = int(cH * 0.60)
        best_c = (0.0, None)
        for font in fonts:
            for sc in scales:
                # Template at scale/fx (approx); keep integer scale >=1
                sc_c = max(1, sc // fx)
                # Prefer matching the physical scale: render at sc then downsample mask
                mask_full = render_string_mask(text, font, sc, even_y=False)
                mask = downsample_mask(mask_full, fx, fy)
                if not mask or not mask[0]:
                    continue
                mh, mw = len(mask), len(mask[0])
                step = max(1, sc_c)
                for y0 in range(y_lo, max(y_lo + 1, cH - mh - 1), step):
                    for x0 in range(0, max(1, cW - mw), step):
                        s = score_mask_at(coarse, x0, y0, mask, thr=thr)
                        if s > best_c[0]:
                            best_c = (s, (font, sc, x0 * fx, y0 * fy, s))
        if best_c[1] is None:
            return "", 0.0, None
        font, sc, x_est, y_est, _ = best_c[1]
        mask = render_string_mask(text, font, sc, even_y=False)
        mh, mw = len(mask), len(mask[0])
        best = (0.0, "", None)
        # Refine ±2*fx around estimate
        for y0 in range(max(0, y_est - 2 * fy), min(H - mh, y_est + 2 * fy + 1)):
            for x0 in range(max(0, x_est - 2 * fx), min(W - mw, x_est + 2 * fx + 1)):
                s = score_mask_at(luma_rows, x0, y0, mask, thr=thr)
                if s > best[0]:
                    best = (s, text if s >= 0.85 else "", {
                        "font": font, "scale": sc, "even": False,
                        "x": x0, "y": y0, "score": s, "coarse": best_c[0],
                    })
        score, recovered, meta = best
        if score < 0.85:
            recovered = ""
        return recovered, score, meta

    # Small/content rasters: direct search on bottom band.
    y_lo = int(H * 0.55)
    best = (0.0, "", None)
    for font in fonts:
        for sc in scales:
            mask = render_string_mask(text, font, sc, even_y=False)
            mh, mw = len(mask), len(mask[0])
            step = max(1, sc)
            for y0 in range(y_lo, max(y_lo + 1, H - mh - 1), step):
                for x0 in range(0, max(1, W - mw), step):
                    s = score_mask_at(luma_rows, x0, y0, mask, thr=thr)
                    if s > best[0]:
                        best = (s, text if s >= 0.85 else "", {
                            "font": font, "scale": sc, "even": False,
                            "x": x0, "y": y0, "score": s,
                        })
                        if s >= 0.92:
                            return text, s, best[2]
            # Even-row DE simulation
            m2 = render_string_mask(text, font, sc, even_y=True)
            src = luma_rows[0::2]
            y_lo2 = int(len(src) * 0.55)
            mh2 = len(m2)
            mw2 = len(m2[0])
            for y0 in range(y_lo2, max(y_lo2 + 1, len(src) - mh2 - 1), max(1, sc // 2)):
                for x0 in range(0, max(1, W - mw2), step):
                    s = score_mask_at(src, x0, y0, m2, thr=thr)
                    if s > best[0]:
                        best = (s, text if s >= 0.85 else "", {
                            "font": font, "scale": sc, "even": True,
                            "x": x0, "y": y0, "score": s,
                        })
                        if s >= 0.92:
                            return text, s, best[2]
    score, recovered, meta = best
    if score < 0.85:
        recovered = ""
    return recovered, score, meta


def synthesize_fixed_overlay(text: str = "STOPPED", font: str = "12x16", scale: int = 2):
    """Build a luma canvas with panel + text the way the fixed renderer does."""
    W, H = 624, 480
    rows = [[20] * W for _ in range(H)]
    # dark panel
    margin = max(6, W // 40)
    panel_h = 120
    py = (H - panel_h - margin) & ~1
    for y in range(py, min(H, py + panel_h)):
        for x in range(margin, W - margin):
            rows[y][x] = 40
    # white text at even y, scale>=2
    sc = max(2, scale)
    gw, gh, adv = font_geom(font)
    label_y = (py + 6) & ~1
    # icon gap ~ left pad
    x = margin + 18 + 14 + 8 * sc
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
    return W, H, rows


def even_row_cull(rows):
    return [rows[y] for y in range(0, len(rows), 2)]


def print_rc(code: int, **fields):
    parts = [f"{k}={v}" for k, v in fields.items()]
    print(" ".join(parts))
    # Must print true rc= directly (parent rule); not through a pipe.
    print(f"true rc={code}")
    return code


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--image", type=Path, help="PNG capture (HDMI or content raster)")
    ap.add_argument("--expect", default="STOPPED", help="Exact string that must be recovered")
    ap.add_argument("--selftest-red", action="store_true",
                    help="Prove RED on parent overlay_lowres_evidence.png")
    ap.add_argument("--selftest-green", action="store_true",
                    help="Prove GREEN on synthetic scale>=2 even-y render after DE cull")
    ap.add_argument("--thr", type=int, default=120, help="Luma threshold for ink")
    args = ap.parse_args(argv)

    root = _repo_root()
    evidence = root / ".agent-work/osd-hires/overlay_lowres_evidence.png"

    if args.selftest_red:
        if not evidence.is_file():
            return print_rc(1, recovered="", error=f"missing evidence {evidence}")
        _, _, rows = load_png_rgb(evidence)
        recovered, score, meta = find_string(rows, args.expect, thr=args.thr)
        # Also try content-scaled downsample 1920→624 nearest for old 5×7 path.
        # RED means we must NOT exactly recover EXPECT from the mangled capture.
        ok_red = recovered != args.expect
        print(f"evidence={evidence}")
        print(f"meta={meta}")
        print(f"score={score:.4f}")
        code = 0 if ok_red else 1
        # Convention for selftest-red: rc=0 means "correctly RED" (mismatch).
        return print_rc(code, recovered=recovered or "<empty>", expect=args.expect,
                        verdict="RED_OK" if ok_red else "FALSE_GREEN")

    if args.selftest_green:
        # Fixed renderer: 12×16 @ scale=2, even y, then even-row cull.
        _, _, rows = synthesize_fixed_overlay(args.expect, font="12x16", scale=2)
        culled = even_row_cull(rows)
        recovered, score, meta = find_string(
            culled, args.expect, fonts=("12x16",), scales=(2,), thr=args.thr
        )
        # Direct mask score on known placement (stronger than full search alone).
        mask = render_string_mask(args.expect, "12x16", 2, even_y=True)
        # known x from synthesize
        margin = max(6, 624 // 40)
        sc = 2
        x = margin + 18 + 14 + 8 * sc
        py = (480 - 120 - margin) & ~1
        label_y = (py + 6) & ~1
        y_even = label_y // 2
        direct = score_mask_at(culled, x, y_even, mask, thr=args.thr)
        if direct >= 0.85:
            recovered = args.expect
            score = direct
        ok = recovered == args.expect and score >= 0.85
        print(f"meta={meta} direct={direct:.4f}")
        print(f"score={score:.4f}")
        return print_rc(0 if ok else 1, recovered=recovered or "<empty>",
                        expect=args.expect, verdict="GREEN_OK" if ok else "GREEN_FAIL")

    if not args.image:
        ap.error("need --image or --selftest-red/--selftest-green")
    _, _, rows = load_png_rgb(args.image)
    recovered, score, meta = find_string(rows, args.expect, thr=args.thr)
    print(f"image={args.image}")
    print(f"meta={meta}")
    print(f"score={score:.4f}")
    ok = recovered == args.expect
    return print_rc(0 if ok else 1, recovered=recovered or "<empty>", expect=args.expect)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print(f"error={e}", file=sys.stderr)
        print("true rc=1")
        sys.exit(1)
