#!/usr/bin/env python3
"""A/V sync soak with OCR-proof glass ID + simultaneous (or delayed) markers.

Encoding contract (every element): scripts/ENCODING_avsync_glass_sync.md
ID band detail: docs/glass_frame_id_contract.md / tools/glass_frame_id.py

Default: 624x480 @ 24/1, 600 s, marker every 2.000 s, audio_delay_ms=0.
Also emits +100 ms audio-lag twin when --also-plus100.
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
from glass_frame_id import (  # noqa: E402
    BAR_Y1,
    CANVAS_H,
    CANVAS_W,
    draw_id_band,
    format_text,
    geometry_for,
)

# ---- caller_supplied design constants (see ENCODING_avsync_glass_sync.md) ----
FPS_NUM = 24
FPS_DEN = 1
PERIOD_S = 2.0
RAMP_FRAMES = 4
PEAK_FRAMES = 1
BEEP_S = 0.050
ATTACK_S = 0.001
BEEP_HZ = 1000.0
SR = 48000
ID_BOTTOM = BAR_Y1  # 88 — body flash starts here; ID never whitened


def write_pcm(
    path: Path,
    duration_s: float,
    *,
    period_s: float = PERIOD_S,
    audio_delay_s: float = 0.0,
    sample_rate: int = SR,
) -> list[float]:
    """Write s16le stereo PCM; return designed beep onset times (seconds)."""
    n = int(round(duration_s * sample_rate))
    onsets: list[float] = []
    k = 0
    while True:
        t0 = k * period_s + audio_delay_s
        if t0 >= duration_s:
            break
        if t0 >= 0.0:
            onsets.append(t0)
        k += 1
    with path.open("wb") as f:
        for i in range(n):
            t = i / sample_rate
            v = 0
            for t0 in onsets:
                phase = t - t0
                if 0.0 <= phase < BEEP_S:
                    env = (phase / ATTACK_S) if phase < ATTACK_S else 1.0
                    v = int(0.9 * 32767 * env * math.sin(2 * math.pi * BEEP_HZ * t))
                    break
            f.write(struct.pack("<hh", v, v))
    return onsets


def body_luma(n: int, fps: float, period_s: float) -> int:
    """Body (y>=ID_BOTTOM) luma 0..255. Ramp centered on k*period so thr@phase0."""
    t = n / float(fps)
    # distance to nearest marker time
    k = int(round(t / period_s))
    t_m = k * period_s
    dt = t - t_m
    ramp_s = RAMP_FRAMES / float(fps)
    half = 0.5 * ramp_s
    peak_s = PEAK_FRAMES / float(fps)
    if -half <= dt < half:
        return int(round(255.0 * (dt + half) / ramp_s))
    if half <= dt < half + peak_s:
        return 255
    return 0


def render_frame(n: int, fps: float, period_s: float) -> np.ndarray:
    y = body_luma(n, fps, period_s)
    rgb = np.zeros((CANVAS_H, CANVAS_W, 3), dtype=np.uint8)
    # body only below ID band
    rgb[ID_BOTTOM:, :, :] = y
    # above ID_BOTTOM left black; draw_id_band paints plate+bars+text
    draw_id_band(rgb, n, geometry_for(CANVAS_W, CANVAS_H))
    return rgb


def gen_one(
    out: Path,
    *,
    duration_s: float,
    audio_delay_ms: float,
    period_s: float,
    vbitrate: str,
) -> dict:
    out.parent.mkdir(parents=True, exist_ok=True)
    fps = FPS_NUM / float(FPS_DEN)
    fps_str = f"{FPS_NUM}/{FPS_DEN}" if FPS_DEN != 1 else str(FPS_NUM)
    n_frames = int(round(duration_s * fps))
    audio_delay_s = audio_delay_ms / 1000.0
    bufsize = str(int(vbitrate[:-1]) * 2) + "k" if vbitrate[-1] in "kK" else vbitrate

    # designed video thr-crossing times (center of ramp = marker time)
    vid_marks = []
    k = 0
    while True:
        t_m = k * period_s
        if t_m >= duration_s:
            break
        vid_marks.append(t_m)
        k += 1

    meta = {
        "out": str(out),
        "encoding_doc": "scripts/ENCODING_avsync_glass_sync.md",
        "id_contract_doc": "docs/glass_frame_id_contract.md",
        "n_frames_ground_truth": n_frames,
        "fps_rational_requested": fps_str,
        "duration_s_requested": duration_s,
        "geometry": f"{CANVAS_W}x{CANVAS_H}",
        "period_s": period_s,
        "audio_delay_ms_designed": audio_delay_ms,
        "designed_offset_ms": audio_delay_ms,  # t_audio - t_video
        "designed_offset_sign": "offset_ms=(t_audio-t_video)*1000 per avsync_measure_hdmi",
        "ramp_frames": RAMP_FRAMES,
        "beep_s": BEEP_S,
        "attack_s": ATTACK_S,
        "id_bottom_y": ID_BOTTOM,
        "text_example": format_text(2358),
        "checksum_rule": "C = (sum of six zero-padded digits of n) mod 10",
        "video_marker_times_s_designed": vid_marks[:5] + (["..."] if len(vid_marks) > 5 else []),
        "n_markers_designed": len(vid_marks),
        "src_design": "caller_supplied",
    }

    with tempfile.TemporaryDirectory(prefix="avgs_", dir=str(out.parent)) as td:
        pcm = Path(td) / "a.s16"
        beep_onsets = write_pcm(pcm, duration_s, period_s=period_s, audio_delay_s=audio_delay_s)
        meta["audio_onset_times_s_designed"] = beep_onsets[:5] + (
            ["..."] if len(beep_onsets) > 5 else []
        )
        meta["n_beeps_designed"] = len(beep_onsets)
        cmd = [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "rgb24",
            "-s", f"{CANVAS_W}x{CANVAS_H}", "-r", fps_str, "-i", "pipe:0",
            "-f", "s16le", "-ar", str(SR), "-ac", "2", "-i", str(pcm),
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "libx264", "-profile:v", "baseline", "-bf", "0",
            "-x264-params", "cabac=0:ref=1:bframes=0:keyint=48",
            "-pix_fmt", "yuv420p",
            "-b:v", vbitrate, "-maxrate", vbitrate, "-bufsize", bufsize,
            "-r", fps_str, "-g", str(int(round(fps * 2))),
            "-c:a", "aac", "-b:a", "128k", "-ar", str(SR), "-ac", "2",
            "-shortest", "-movflags", "+faststart",
            str(out),
        ]
        meta["ffmpeg_cmd"] = " ".join(cmd)
        print("GEN", out, flush=True)
        print(
            f"DESIGN offset_ms={audio_delay_ms} period_s={period_s} "
            f"n_frames={n_frames} n_markers={len(vid_marks)} src=caller_supplied",
            flush=True,
        )
        print("ID", format_text(0), "checksum_rule=sum(digits)%10 bars=primary", flush=True)
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        assert proc.stdin is not None
        try:
            step = max(1, n_frames // 20)
            for n in range(n_frames):
                proc.stdin.write(render_frame(n, fps, period_s).tobytes())
                if (n + 1) % step == 0:
                    print(f"  frames {n+1}/{n_frames}", flush=True)
        finally:
            proc.stdin.close()
            rc = proc.wait()
        if rc != 0:
            raise SystemExit(f"ffmpeg failed rc={rc}")
    meta["size_bytes"] = out.stat().st_size
    meta_path = out.with_suffix(out.suffix + ".meta.json")
    meta_path.write_text(json.dumps(meta, indent=2))
    print("OK", out, meta["size_bytes"], "meta", meta_path, flush=True)
    return meta


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--duration", type=float, default=600.0)
    ap.add_argument("--period", type=float, default=PERIOD_S)
    ap.add_argument("--audio-delay-ms", type=float, default=0.0,
                    help="Designed t_audio-t_video in ms (0=aligned, 100=audio lags)")
    ap.add_argument("--also-plus100", action="store_true",
                    help="Also write sibling with +100 ms audio delay")
    ap.add_argument("--vbitrate", default="2000k")
    args = ap.parse_args()

    gen_one(
        args.out,
        duration_s=args.duration,
        audio_delay_ms=args.audio_delay_ms,
        period_s=args.period,
        vbitrate=args.vbitrate,
    )
    if args.also_plus100:
        p100 = args.out.with_name(args.out.stem + "_audioPlus100ms" + args.out.suffix)
        gen_one(
            p100,
            duration_s=args.duration,
            audio_delay_ms=100.0,
            period_s=args.period,
            vbitrate=args.vbitrate,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
