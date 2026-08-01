#!/usr/bin/env python3
"""OCR-proof glass-ledger soak fixture (624x480 @ measured 24/1).

See tools/glass_frame_id.py for the full writer↔reader CONTRACT.
Primary ID = binary Grey-code bar strip (not OCR). Secondary = fixed-width
zero-padded digits + checksum on an opaque black plate.

Default duration 600 s (>=10 min) at fps 24/1 → n_frames=14400 ground truth.
Audio: 1 kHz beep 50 ms / 1 ms attack each integer second (A/V still measurable).
Flash: optional centered luma ramp for avsync (does not cover the ID plate).
"""
from __future__ import annotations

import argparse
import math
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

try:
    from PIL import Image, ImageDraw
except ImportError as e:
    raise SystemExit(f"Pillow required: {e}") from e

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from glass_frame_id import (  # noqa: E402
    BAR_Y1,
    CANVAS_H,
    CANVAS_W,
    draw_id_band,
    format_text,
)


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


def scene_luma(n: int, fps: float, ramp_frames: int = 4) -> int:
    """Body luma only (ID plate is always opaque on top). Centered ramp on integer s."""
    t = n / float(fps)
    phase = t - math.floor(t)
    dt = phase - 1.0 if phase > 0.5 else phase
    ramp_s = ramp_frames / float(fps)
    half = 0.5 * ramp_s
    if -half <= dt < half:
        return int(round(255.0 * (dt + half) / ramp_s))
    if half <= dt < half + 1.0 / fps:
        return 255
    return 0


def render_frame(n: int, fps: float, *, force_luma: int | None = None) -> np.ndarray:
    y = scene_luma(n, fps) if force_luma is None else int(force_luma)
    rgb = np.zeros((CANVAS_H, CANVAS_W, 3), dtype=np.uint8)
    rgb[:, :, :] = y
    # mouth bar
    t = n / fps
    phase = t - math.floor(t)
    if phase < 0.05 and force_luma is None:
        bx = (CANVAS_W - CANVAS_W // 4) // 2
        by = int(CANVAS_H * 3 / 4)
        rgb[by : by + CANVAS_H // 10, bx : bx + CANVAS_W // 4, :] = (255, 0, 0)
    draw_id_band(rgb, n)
    return rgb


def gen(
    out: Path,
    *,
    duration_s: float = 600.0,
    fps_num: int = 24,
    fps_den: int = 1,
    vbitrate: str = "2000k",
) -> dict:
    out.parent.mkdir(parents=True, exist_ok=True)
    fps_val = fps_num / float(fps_den)
    fps_str = f"{fps_num}/{fps_den}" if fps_den != 1 else str(fps_num)
    n_frames = int(round(duration_s * fps_val))
    bufsize = str(int(vbitrate[:-1]) * 2) + "k" if vbitrate[-1] in "kK" else vbitrate
    meta = {
        "out": str(out),
        "n_frames_ground_truth": n_frames,
        "fps_rational_requested": fps_str,
        "duration_s_requested": duration_s,
        "text_example": format_text(2358),
        "contract": "tools/glass_frame_id.py",
    }
    with tempfile.TemporaryDirectory(prefix="glass_", dir=str(out.parent)) as td:
        pcm = Path(td) / "a.s16"
        write_pcm_sharp(pcm, duration_s)
        cmd = [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "rgb24",
            "-s", f"{CANVAS_W}x{CANVAS_H}", "-r", fps_str, "-i", "pipe:0",
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
        print("GROUND_TRUTH n_frames=", n_frames, "fps_requested=", fps_str, "src=caller_supplied", flush=True)
        print("ID_CONTRACT bars=primary text=", format_text(0), "src=caller_supplied", flush=True)
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        assert proc.stdin is not None
        try:
            for n in range(n_frames):
                frame = render_frame(n, fps_val)
                proc.stdin.write(frame.tobytes())
                if (n + 1) % 720 == 0:
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
    ap.add_argument("--duration", type=float, default=600.0,
                    help="seconds; default 600 (>=10 min soak)")
    ap.add_argument("--fps-num", type=int, default=24)
    ap.add_argument("--fps-den", type=int, default=1)
    ap.add_argument("--vbitrate", default="2000k")
    args = ap.parse_args()
    gen(args.out, duration_s=args.duration, fps_num=args.fps_num,
        fps_den=args.fps_den, vbitrate=args.vbitrate)
    return 0


if __name__ == "__main__":
    sys.exit(main())
