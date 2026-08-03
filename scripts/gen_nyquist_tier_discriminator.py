#!/usr/bin/env python3
"""240-vs-480 tier discriminator: vertical energy at the sampling ceiling.

Why real content failed (parent): band-limited below ceiling → spectral test
INCONCLUSIVE. This fixture puts FULL-CONTRAST energy at vertical Nyquist.

Two matched assets (same duration, glass ID band, CB no-B AAC):
  A) 624x480  — body rows alternate W/B every 1 line (period-2 = Nyquist @ 480)
  B) 320x240  — body rows alternate W/B every 1 line (Nyquist @ 240)

After legacy present path (even-row cull STORE_Y_SCALE=2):
  A) period-2 → all fetched rows same phase → FLAT field (even_odd≈0, low rowdiff)
  B) when force-scaled to 480 then culled, OR when 240 is line-doubled, residual
     structure differs — host gate scores both pre and post chain.

Also paints large 40px-tall horizontal bar pairs in a side panel so that even
after 17% column loss + dual resample, a spatial “stripe zone” remains w-instr
scoreable (not a 1-px feature).

See docs/nyquist_tier_discriminator.md
"""
from __future__ import annotations

import argparse
import json
import math
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from glass_frame_id import draw_id_band, format_text, geometry_for  # noqa: E402

FPS = 24
SR = 48000


def pcm_silence(path: Path, duration_s: float) -> None:
    n = int(round(duration_s * SR))
    with path.open("wb") as f:
        z = struct.pack("<hh", 0, 0)
        for _ in range(n):
            f.write(z)


def render(n: int, w: int, h: int, *, phase0: int = 0) -> np.ndarray:
    """Nyquist horizontal stripes in body; glass ID on top; side ruler."""
    geom = geometry_for(w, h)
    rgb = np.zeros((h, w, 3), dtype=np.uint8)
    # Body: vertical Nyquist — alternate full rows (period 2)
    # phase0 flips which parity is white (two variants if needed)
    ys = np.arange(h)[:, None, None]
    white = ((ys + phase0) % 2 == 0)
    body = np.where(white, 255, 0).astype(np.uint8)
    rgb[:] = body
    # Large stripe block on right third: 8-row period (survives cull as 4-row)
    # so glass still shows *some* structure if full-field flattens
    x0 = int(w * 2 / 3)
    for y in range(h):
        band = (y // 8) % 2
        rgb[y, x0:, :] = 255 if band == 0 else 0
    # 40px-tall ticker bar moving with n (hold/judder optional cue) — thick
    bh = max(16, h // 12)
    if bh % 2:
        bh += 1
    yb = geom.bar_y1 + ((n * 2) % max(1, h - geom.bar_y1 - bh))
    # ensure even y for cull survival of bar top
    yb = yb - (yb % 2)
    rgb[yb : yb + bh, w // 8 : w // 2, :] = (255, 0, 0)
    draw_id_band(rgb, n, geom)
    return rgb


def gen(out: Path, w: int, h: int, duration_s: float, vbitrate: str) -> dict:
    out.parent.mkdir(parents=True, exist_ok=True)
    n_frames = int(round(duration_s * FPS))
    fps_str = "24/1"
    bufsize = str(int(vbitrate[:-1]) * 2) + "k" if vbitrate[-1] in "kK" else vbitrate
    meta = {
        "out": str(out),
        "width": w,
        "height": h,
        "n_frames": n_frames,
        "fps": fps_str,
        "pattern": "vertical_nyquist_period2_rows + period8_side_panel + glass_id",
        "text_example": format_text(0),
        "doc": "docs/nyquist_tier_discriminator.md",
        "src": "caller_supplied",
    }
    with tempfile.TemporaryDirectory(prefix="nyq_", dir=str(out.parent)) as td:
        pcm = Path(td) / "a.s16"
        pcm_silence(pcm, duration_s)
        cmd = [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}", "-r", fps_str,
            "-i", "pipe:0",
            "-f", "s16le", "-ar", str(SR), "-ac", "2", "-i", str(pcm),
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "libx264", "-profile:v", "baseline", "-bf", "0",
            "-x264-params", "cabac=0:ref=1:bframes=0:keyint=48",
            "-pix_fmt", "yuv420p",
            "-b:v", vbitrate, "-maxrate", vbitrate, "-bufsize", bufsize,
            "-r", fps_str,
            "-c:a", "aac", "-b:a", "96k", "-ar", str(SR),
            "-shortest", "-movflags", "+faststart", str(out),
        ]
        meta["ffmpeg_cmd"] = " ".join(cmd)
        print("GEN", out, f"{w}x{h}", n_frames, flush=True)
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        assert proc.stdin
        try:
            for n in range(n_frames):
                proc.stdin.write(render(n, w, h).tobytes())
                if (n + 1) % max(1, n_frames // 10) == 0:
                    print(f"  {n+1}/{n_frames}", flush=True)
        finally:
            proc.stdin.close()
            rc = proc.wait()
        if rc != 0:
            raise SystemExit(f"ffmpeg rc={rc}")
    meta["size"] = out.stat().st_size
    out.with_suffix(out.suffix + ".meta.json").write_text(json.dumps(meta, indent=2))
    print("OK", out, meta["size"], flush=True)
    return meta


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out-dir", type=Path, required=True)
    ap.add_argument("--duration", type=float, default=30.0)
    args = ap.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    gen(args.out_dir / "disc_nyquist_480p_624x480.mp4", 624, 480, args.duration, "2500k")
    gen(args.out_dir / "disc_nyquist_240p_320x240.mp4", 320, 240, args.duration, "800k")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
