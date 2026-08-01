#!/usr/bin/env python3
"""Full-bleed 624x480 (SAR 1:1) soak — unambiguous geometry + V-res + A/V.

WHY
  Library RK6 is tagged 624x480 but ffprobe shows sample_aspect_ratio=160:117
  display_aspect_ratio=16:9 → players letterbox active picture (~350 rows).
  This fixture fills EVERY coded row with content, forces SAR=1:1, DAR=624:480
  (=13:10, NOT 16:9). Any delivery with <<480 active rows is then a defect.

CONTENT (every non-flash frame)
  - Opaque glass ID band (docs/glass_frame_id_contract.md) at top
  - Left third: 1-row alternating black/white (Nyquist vertical) — collapses to
    solid if only even store rows survive
  - Mid third: horizontal 1px line-pair zones (periods 2,4,8,16)
  - Right third: vertical frequency chirp (period 2→32 over height)
  - Moving high-contrast diagonal so motion/decode stay non-trivial

A/V MARKER (w-avsync contract: period 2.000 s, designed offset 0)
  - Video: 2-frame opaque WHITE body flash (y>=id_bottom), ID band never flashed
  - Audio: 1 kHz beep 50 ms, 1 ms attack at same content time

Encode: H.264 Constrained Baseline, bf=0, AAC 48 kHz, -sar 1:1.
"""
from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from glass_frame_id import draw_id_band, format_text, geometry_for  # noqa: E402

W, H = 624, 480
FPS_NUM, FPS_DEN = 24, 1
SR = 48000
PERIOD_S = 2.0
FLASH_FRAMES = 2
BEEP_S = 0.050
ATTACK_S = 0.001
BEEP_HZ = 1000.0


def write_beep_pcm(path: Path, duration_s: float, period_s: float = PERIOD_S) -> list[float]:
    n = int(round(duration_s * SR))
    onsets = []
    k = 0
    while True:
        t0 = k * period_s
        if t0 >= duration_s:
            break
        onsets.append(t0)
        k += 1
    mono = np.zeros(n, dtype=np.float64)
    t = np.arange(n, dtype=np.float64) / float(SR)
    for t0 in onsets:
        i0 = int(round(t0 * SR))
        i1 = min(n, i0 + int(round(BEEP_S * SR)))
        if i0 >= n or i1 <= i0:
            continue
        phase = t[i0:i1] - t0
        env = np.where(phase < ATTACK_S, phase / ATTACK_S, 1.0)
        mono[i0:i1] = 0.9 * env * np.sin(2 * math.pi * BEEP_HZ * t[i0:i1])
    s16 = np.clip(mono * 32767.0, -32768, 32767).astype(np.int16)
    path.write_bytes(np.column_stack([s16, s16]).reshape(-1).tobytes())
    return onsets


def render_frame(n: int, fps: float, id_bottom: int) -> np.ndarray:
    """Full-bleed 624x480. No letterbox bars. Rows 0..479 all carry signal."""
    rgb = np.zeros((H, W, 3), dtype=np.uint8)
    body_h = H - id_bottom
    # --- base: mid grey full body so "empty" rows are still non-black ---
    rgb[id_bottom:, :, :] = 48

    # column thirds over full body height
    x0, x1, x2, x3 = 0, W // 3, 2 * W // 3, W
    ys = np.arange(body_h, dtype=np.int32)

    # LEFT: 1-row alternating B/W (period-2 vertical Nyquist)
    alt = np.where((ys % 2) == 0, 255, 0).astype(np.uint8)
    left = np.repeat(alt[:, None], x1 - x0, axis=1)
    rgb[id_bottom:, x0:x1, 0] = left
    rgb[id_bottom:, x0:x1, 1] = left
    rgb[id_bottom:, x0:x1, 2] = left

    # MID: stacked zones period 2,4,8,16 horizontal line pairs
    zone_h = body_h // 4
    for zi, period in enumerate((2, 4, 8, 16)):
        y0 = id_bottom + zi * zone_h
        y1 = id_bottom + (zi + 1) * zone_h if zi < 3 else H
        for y in range(y0, y1):
            v = 255 if ((y - y0) % period) < (period // 2) else 0
            rgb[y, x1:x2, :] = v

    # RIGHT: vertical frequency chirp period 2 → 32 over body height
    # local period p(y) = 2 + 30 * (y_local/body_h)
    y_loc = ys.astype(np.float64)
    # phase accumulates 2π / p(y)
    p = 2.0 + 30.0 * (y_loc / max(body_h - 1, 1))
    # integrate dphi = 2π/p per row
    dphi = 2.0 * math.pi / p
    phase = np.cumsum(dphi)
    wave = (255.0 * (0.5 + 0.5 * np.sin(phase))).astype(np.uint8)
    right = np.repeat(wave[:, None], x3 - x2, axis=1)
    rgb[id_bottom:, x2:x3, 0] = right
    rgb[id_bottom:, x2:x3, 1] = right
    rgb[id_bottom:, x2:x3, 2] = right

    # Moving diagonal (decode/motion load) — 8px white stripe
    body = rgb[id_bottom:, :, :]
    by, bx = np.mgrid[0:body_h, 0:W]
    diag = ((bx - (n * 3 + by)) % W) < 8
    body[diag] = 220
    # A/V flash: full body white, ID untouched (drawn after)
    t = n / fps
    k = int(round(t / PERIOD_S))
    t_m = k * PERIOD_S
    dn = int(round((t - t_m) * fps))
    if 0 <= dn < FLASH_FRAMES:
        rgb[id_bottom:, :, :] = 255

    draw_id_band(rgb, n, geometry_for(W, H))
    return rgb


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--duration", type=float, default=1200.0,
                    help="seconds; default 1200 (20 min) for multi-round soak")
    ap.add_argument("--vbitrate", default="3000k")
    ap.add_argument("--work", type=Path, default=None)
    args = ap.parse_args()

    fps = FPS_NUM / float(FPS_DEN)
    fps_str = str(FPS_NUM) if FPS_DEN == 1 else f"{FPS_NUM}/{FPS_DEN}"
    n_frames = int(round(args.duration * fps))
    geom = geometry_for(W, H)
    id_bottom = geom.bar_y1
    bufsize = str(int(args.vbitrate[:-1]) * 2) + "k" if args.vbitrate[-1] in "kK" else args.vbitrate

    work = args.work or Path(tempfile.mkdtemp(prefix="bank480_"))
    work.mkdir(parents=True, exist_ok=True)
    args.out.parent.mkdir(parents=True, exist_ok=True)

    pcm = work / "beep.s16"
    onsets = write_beep_pcm(pcm, args.duration)
    print(
        f"PLAN w={W} h={H} sar=1:1 dar={W}:{H} fps={fps_str} "
        f"duration_s={args.duration} n_frames={n_frames} period_s={PERIOD_S} "
        f"id_bottom={id_bottom} text0={format_text(0)} "
        f"designed_av_offset_ms=0.0 n_beeps={len(onsets)}",
        flush=True,
    )

    enc = subprocess.Popen(
        [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "rgb24",
            "-s", f"{W}x{H}", "-r", fps_str, "-i", "pipe:0",
            "-f", "s16le", "-ar", str(SR), "-ac", "2", "-i", str(pcm),
            # Square samples + DAR = coded size (624:480=13:10). NOT 16:9.
            "-filter_complex", "[0:v]setsar=1/1,setdar=624/480,format=yuv420p[v]",
            "-map", "[v]", "-map", "1:a:0",
            "-c:v", "libx264", "-profile:v", "baseline", "-bf", "0",
            "-x264-params", "cabac=0:ref=1:bframes=0:keyint=48",
            "-b:v", args.vbitrate, "-maxrate", args.vbitrate, "-bufsize", bufsize,
            "-r", fps_str,
            "-c:a", "aac", "-b:a", "128k", "-ar", str(SR), "-ac", "2",
            "-t", str(args.duration),
            "-movflags", "+faststart",
            str(args.out),
        ],
        stdin=subprocess.PIPE,
    )
    assert enc.stdin
    n = 0
    try:
        for n in range(n_frames):
            enc.stdin.write(render_frame(n, fps, id_bottom).tobytes())
            if (n + 1) % 500 == 0:
                print(f"  wrote {n+1}/{n_frames}", flush=True)
    finally:
        enc.stdin.close()
        erc = enc.wait()
    print(f"encode_rc={erc} frames_written={n_frames}", flush=True)
    if erc != 0:
        return erc

    cmd = [
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries",
        "stream=width,height,sample_aspect_ratio,display_aspect_ratio,"
        "r_frame_rate,avg_frame_rate,nb_frames,duration,profile,has_b_frames",
        "-show_entries", "stream_tags=rotate",
        "-of", "json", str(args.out),
    ]
    p = subprocess.run(cmd, capture_output=True, text=True)
    print(f"ffprobe_v true rc={p.returncode}", flush=True)
    vmeta = json.loads(p.stdout) if p.returncode == 0 else {"error": p.stderr}

    pa = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=codec_name,sample_rate,channels",
            "-of", "json", str(args.out),
        ],
        capture_output=True, text=True,
    )
    print(f"ffprobe_a true rc={pa.returncode}", flush=True)
    ameta = json.loads(pa.stdout) if pa.returncode == 0 else {"error": pa.stderr}

    report = {
        "out": str(args.out),
        "size_bytes": args.out.stat().st_size,
        "caller_supplied": {
            "width": W, "height": H, "sar": "1:1",
            "dar_pixel_ratio": f"{W}:{H}",
            "note_dar": "624/480=13:10 at SAR 1:1; not 16:9; not classic 4:3 (640x480)",
            "fps": f"{FPS_NUM}/{FPS_DEN}",
            "duration_s": args.duration,
            "period_s": PERIOD_S,
            "designed_av_offset_ms": 0.0,
            "flash_frames": FLASH_FRAMES,
            "beep_s": BEEP_S,
            "full_bleed": True,
            "letterbox_in_pixels": False,
            "v_res_instruments": [
                "left_third_1row_alternating_bw",
                "mid_third_linepair_periods_2_4_8_16",
                "right_third_vertical_chirp_period_2_to_32",
                "moving_diagonal",
            ],
        },
        "measured_video": vmeta,
        "measured_audio": ameta,
        "n_beep_onsets": len(onsets),
    }
    meta_path = args.out.with_suffix(args.out.suffix + ".meta.json")
    meta_path.write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2)[:2000], flush=True)
    print(f"OK {args.out} meta={meta_path}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
