#!/usr/bin/env python3
"""Glass-ledger soak fixture: every frame uniquely ID'd after even-row cull.

Why
---
present_core.sv STORE_Y_SCALE = (FRAME_H*65536)/240 with FRAME_H=480 → scale 2.0.
Display line py maps to store_y = py*2, so **odd store rows are never fetched**
(quoted: present_core.sv:164-200). A thin-stroke counter loses horizontal bars
under that cull. This generator:
  1. Draws a LARGE yellow counter with thick stroke at top-left.
  2. **Even-row paints** the counter band: for each odd y, copy RGB from y-1
     so the culled path still sees a complete glyph.
  3. Emits exact ground-truth frame count = round(duration * fps).

Contract (decoder path under user conf DECODE=624x480, do not change conf):
  - coded 624x480 (DDR bank), H.264 Constrained Baseline, -bf 0, AAC 48 kHz
  - fps stated as rational and MUST be re-measured with ffprobe after encode
  - duration default 360 s: failure regime seen ~12 drops @ ~21 s; 360/21 ≈ 17×
    that window distinguishes flat startup loss from a growing leak
    (if 0.57 drop/s continued → ~200 by EOF; if flat → still ~12).

Also keeps 1 Hz flash+beep (centered ramp) so A/V instrument still works.
Label TREK24 for tools/hdmi_motion_instrument.py OCR path.
"""
from __future__ import annotations

import argparse
import math
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError as e:
    raise SystemExit(f"Pillow required: {e}") from e

ROOT = Path(__file__).resolve().parents[1]
FONT_CANDIDATES = (
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/liberation/LiberationSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
)


def pick_font(size: int):
    for f in FONT_CANDIDATES:
        if Path(f).is_file():
            return ImageFont.truetype(f, size=size)
    return ImageFont.load_default()


def write_pcm_sharp(path: Path, duration_s: float, sr: int = 48000) -> None:
    n = int(round(duration_s * sr))
    attack_s, beep_s = 0.001, 0.050
    with path.open("wb") as f:
        for i in range(n):
            t = i / sr
            sec = int(math.floor(t))
            phase = t - sec
            if sec < int(duration_s) and 0.0 <= phase < beep_s:
                env = (phase / attack_s) if phase < attack_s else 1.0
                v = int(0.9 * 32767 * env * math.sin(2 * math.pi * 1000.0 * t))
            else:
                v = 0
            f.write(struct.pack("<hh", v, v))


def frame_luma_centered_ramp(n: int, fps: float, ramp_frames: int = 4, peak_frames: int = 1) -> int:
    t = n / float(fps)
    phase = t - math.floor(t)
    dt = phase - 1.0 if phase > 0.5 else phase
    ramp_s = ramp_frames / float(fps)
    half = 0.5 * ramp_s
    peak_s = peak_frames / float(fps)
    if -half <= dt < half:
        return int(round(255.0 * (dt + half) / ramp_s))
    if half <= dt < half + peak_s:
        return 255
    return 0


def even_row_paint_band(img: Image.Image, y0: int, y1: int) -> None:
    """Copy even rows onto following odd rows inside [y0,y1).

    After present_core even-row fetch, display sees only store y=0,2,4,...
    Making odd==even in the counter band means the culled picture still holds
    a full-thickness glyph (no missing horizontal strokes).
    """
    px = img.load()
    w, h = img.size
    y0 = max(0, y0)
    y1 = min(h, y1)
    # Ensure band starts on even row
    if y0 % 2 == 1:
        y0 -= 1
    for y in range(y0, y1 - 1, 2):
        for x in range(w):
            px[x, y + 1] = px[x, y]


def draw_frame(
    width: int,
    height: int,
    n: int,
    fps: float,
    *,
    label: str,
    font,
    font_big,
    ramp_frames: int,
) -> Image.Image:
    y = frame_luma_centered_ramp(n, fps, ramp_frames=ramp_frames)
    img = Image.new("RGB", (width, height), (y, y, y))
    draw = ImageDraw.Draw(img)
    t = n / fps
    phase = t - math.floor(t)
    if phase < 0.05:
        bx = (width - width // 4) // 2
        by = int(height * 3 / 4)
        draw.rectangle([bx, by, bx + width // 4, by + height // 10], fill=(255, 0, 0))

    # Counter: large, thick, top-left. Digit field wide enough for 360*24=8640 (4+ digits)
    # and 600*24=14400 (5 digits). Use >=5 digit field in the string always via plain n.
    text = f"{label} n={n}"
    # Black underplate for contrast on white flash frames
    try:
        l, t0, r, b = draw.textbbox((0, 0), text, font=font_big, stroke_width=4)
        tw, th = r - l, b - t0
    except Exception:
        tw, th = int(draw.textlength(text, font=font_big)), 48
    pad = 8
    x0, y0 = 8, 8
    draw.rectangle([x0 - 4, y0 - 4, x0 + tw + pad, y0 + th + pad], fill=(0, 0, 0))
    draw.text(
        (x0, y0),
        text,
        font=font_big,
        fill=(255, 255, 0),
        stroke_width=4,
        stroke_fill=(0, 0, 0),
    )
    # Even-row paint the counter band (generous height)
    band_y1 = y0 + th + pad + 8
    # snap band_y1 up to even
    if band_y1 % 2:
        band_y1 += 1
    even_row_paint_band(img, 0, min(height, max(band_y1, 96)))

    if y > 0:
        try:
            l, t0, r, b = draw.textbbox((0, 0), "RAMP", font=font)
            tw, th = r - l, b - t0
        except Exception:
            tw, th = 80, 40
        draw.text(((width - tw) / 2, height / 3), "RAMP", font=font, fill=(0, 0, 0))

    # Bottom ground-truth strip: big block of n mod 10 as grey bars (backup, cull-safe)
    # 10 cells across bottom; cell k lit if digit matches — survives as solid blocks.
    cell_w = width // 10
    digit = n % 10
    by0 = height - 24
    # paint even rows only pattern via full rect then even_row_paint
    for k in range(10):
        color = (220, 220, 220) if k == digit else (20, 20, 20)
        draw.rectangle([k * cell_w, by0, (k + 1) * cell_w - 1, height - 1], fill=color)
    even_row_paint_band(img, by0 if by0 % 2 == 0 else by0 - 1, height)

    return img


def gen(
    out: Path,
    *,
    width: int = 624,
    height: int = 480,
    fps_num: int = 24,
    fps_den: int = 1,
    duration_s: float = 360.0,
    vbitrate: str = "2000k",
    label: str = "TREK24",
    ramp_frames: int = 4,
) -> dict:
    if width != 624 or height != 480:
        raise SystemExit(f"glass ledger requires 624x480 bank geometry, got {width}x{height}")
    out.parent.mkdir(parents=True, exist_ok=True)
    fps_val = fps_num / float(fps_den)
    fps_str = f"{fps_num}/{fps_den}" if fps_den != 1 else str(fps_num)
    n_frames = int(round(duration_s * fps_val))
    # Font ~1/10 of height so after 2:1 cull still ~24 px on 240-line store
    font_big = pick_font(max(36, height // 10))
    font = pick_font(max(20, height // 16))
    bufsize = str(int(vbitrate[:-1]) * 2) + "k" if vbitrate[-1] in "kK" else vbitrate

    meta = {
        "out": str(out),
        "width": width,
        "height": height,
        "fps_num": fps_num,
        "fps_den": fps_den,
        "fps_rational_requested": fps_str,
        "duration_s_requested": duration_s,
        "n_frames_ground_truth": n_frames,
        "label": label,
        "even_row_paint": True,
        "duration_rationale": (
            "drops≈12 @ ~21s observed on 480p; duration=360s ≈17× that window "
            "to separate fixed startup loss from accumulating leak"
        ),
    }

    with tempfile.TemporaryDirectory(prefix="glass_", dir=str(out.parent)) as td:
        pcm = Path(td) / "a.s16"
        write_pcm_sharp(pcm, duration_s)
        cmd = [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "rgb24",
            "-s", f"{width}x{height}", "-r", fps_str, "-i", "pipe:0",
            "-f", "s16le", "-ar", "48000", "-ac", "2", "-i", str(pcm),
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "libx264", "-profile:v", "baseline", "-bf", "0",
            "-x264-params", "cabac=0:ref=1:bframes=0:keyint=48",
            "-pix_fmt", "yuv420p",
            "-b:v", vbitrate, "-maxrate", vbitrate, "-bufsize", bufsize,
            "-r", fps_str, "-g", str(int(round(fps_val * 2))),
            "-c:a", "aac", "-b:a", "128k", "-ar", "48000", "-ac", "2",
            "-shortest", "-movflags", "+faststart",
            str(out),
        ]
        meta["ffmpeg_cmd"] = " ".join(cmd)
        print("GEN", out, flush=True)
        print("GROUND_TRUTH n_frames=", n_frames, "fps_requested=", fps_str, flush=True)
        print("CMD", meta["ffmpeg_cmd"], flush=True)
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        assert proc.stdin is not None
        try:
            for n in range(n_frames):
                img = draw_frame(
                    width, height, n, fps_val,
                    label=label, font=font, font_big=font_big, ramp_frames=ramp_frames,
                )
                proc.stdin.write(img.tobytes())
                if (n + 1) % 480 == 0:
                    print(f"  frames {n+1}/{n_frames}", flush=True)
        finally:
            proc.stdin.close()
            rc = proc.wait()
        if rc != 0:
            raise SystemExit(f"ffmpeg failed rc={rc}")
    meta["size_bytes"] = out.stat().st_size
    print("OK", out, meta["size_bytes"], flush=True)
    return meta


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path,
                    default=ROOT / "assets" / "avsync" / "sync_glass_ledger_480p24.mp4")
    ap.add_argument("--duration", type=float, default=360.0)
    ap.add_argument("--fps-num", type=int, default=24)
    ap.add_argument("--fps-den", type=int, default=1)
    ap.add_argument("--vbitrate", default="2000k")
    ap.add_argument("--label", default="TREK24")
    args = ap.parse_args()
    gen(
        args.out,
        duration_s=args.duration,
        fps_num=args.fps_num,
        fps_den=args.fps_den,
        vbitrate=args.vbitrate,
        label=args.label,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
