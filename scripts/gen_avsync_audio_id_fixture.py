#!/usr/bin/env python3
"""Glass video ID + self-checking audio FSK packets (index+checksum).

ENCODING: docs/audio_frame_id_contract.md
          docs/glass_frame_id_contract.md
          scripts/ENCODING_avsync_glass_sync.md (video body flash)

Default: 624x480 @ 24/1, period 2.000 s, audio_delay_ms=0.
Long soak default duration 1800 s (drift arithmetic in audio contract).
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from audio_frame_id import (  # noqa: E402
    PERIOD_S,
    SR,
    contract_dict as audio_contract,
    fps,
    sampling_margin_report,
    synthesize_pcm,
    write_pcm_s16le_stereo,
)
from glass_frame_id import (  # noqa: E402
    BAR_Y1,
    CANVAS_H,
    CANVAS_W,
    draw_id_band,
    format_text,
    geometry_for,
)

ID_BOTTOM = BAR_Y1
RAMP_FRAMES = 4
PEAK_FRAMES = 1


def body_luma(n: int, fps_v: float, period_s: float) -> int:
    t = n / float(fps_v)
    k = int(round(t / period_s))
    t_m = k * period_s
    dt = t - t_m
    ramp_s = RAMP_FRAMES / float(fps_v)
    half = 0.5 * ramp_s
    peak_s = PEAK_FRAMES / float(fps_v)
    if -half <= dt < half:
        return int(round(255.0 * (dt + half) / ramp_s))
    if half <= dt < half + peak_s:
        return 255
    return 0


def render_frame(n: int, fps_v: float, period_s: float) -> np.ndarray:
    y = body_luma(n, fps_v, period_s)
    rgb = np.zeros((CANVAS_H, CANVAS_W, 3), dtype=np.uint8)
    rgb[ID_BOTTOM:, :, :] = y
    draw_id_band(rgb, n, geometry_for(CANVAS_W, CANVAS_H))
    return rgb


def gen(
    out: Path,
    *,
    duration_s: float,
    period_s: float,
    audio_delay_ms: float,
    vbitrate: str,
) -> dict:
    out.parent.mkdir(parents=True, exist_ok=True)
    fps_v = fps()
    fps_str = "24/1"
    n_frames = int(round(duration_s * fps_v))
    audio_delay_s = audio_delay_ms / 1000.0
    bufsize = str(int(vbitrate[:-1]) * 2) + "k" if vbitrate[-1] in "kK" else vbitrate

    pcm_mono, markers = synthesize_pcm(
        duration_s, period_s=period_s, audio_delay_s=audio_delay_s, sr=SR
    )
    meta = {
        "out": str(out),
        "docs": [
            "docs/audio_frame_id_contract.md",
            "docs/glass_frame_id_contract.md",
        ],
        "n_frames_ground_truth": n_frames,
        "fps_rational_requested": fps_str,
        "duration_s_requested": duration_s,
        "geometry": f"{CANVAS_W}x{CANVAS_H}",
        "period_s": period_s,
        "audio_delay_ms_designed": audio_delay_ms,
        "designed_offset_ms": audio_delay_ms,
        "n_markers": len(markers),
        "markers_head": markers[:3],
        "text_example": format_text(2358),
        "video_checksum_rule": "C = sum(six digits of n) mod 10",
        "audio_contract": audio_contract(),
        "sampling_margin": sampling_margin_report(),
        "drift_justification": {
            "formula": "drift_ms = ppm * T_s * 0.001",
            "T_s": duration_s,
            "at_10ppm_ms": 10 * duration_s * 0.001,
            "at_50ppm_ms": 50 * duration_s * 0.001,
            "why": "onset noise ~2ms; need multi-sigma drift for slow clock mismatch",
        },
        "src_design": "caller_supplied",
    }

    with tempfile.TemporaryDirectory(prefix="audid_", dir=str(out.parent)) as td:
        pcm_path = Path(td) / "a.s16"
        write_pcm_s16le_stereo(pcm_path, pcm_mono)
        cmd = [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "rgb24",
            "-s", f"{CANVAS_W}x{CANVAS_H}", "-r", fps_str, "-i", "pipe:0",
            "-f", "s16le", "-ar", str(SR), "-ac", "2", "-i", str(pcm_path),
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "libx264", "-profile:v", "baseline", "-bf", "0",
            "-x264-params", "cabac=0:ref=1:bframes=0:keyint=48",
            "-pix_fmt", "yuv420p",
            "-b:v", vbitrate, "-maxrate", vbitrate, "-bufsize", bufsize,
            "-r", fps_str, "-g", "48",
            "-c:a", "aac", "-b:a", "128k", "-ar", str(SR), "-ac", "2",
            "-shortest", "-movflags", "+faststart",
            str(out),
        ]
        meta["ffmpeg_cmd"] = " ".join(cmd)
        print("GEN", out, flush=True)
        print(
            f"DESIGN dur={duration_s}s frames={n_frames} markers={len(markers)} "
            f"offset_ms={audio_delay_ms} bit_ms={meta['sampling_margin']['bit_s_ms']} "
            f"src=caller_supplied",
            flush=True,
        )
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        assert proc.stdin is not None
        try:
            step = max(1, n_frames // 20)
            for n in range(n_frames):
                proc.stdin.write(render_frame(n, fps_v, period_s).tobytes())
                if (n + 1) % step == 0:
                    print(f"  frames {n+1}/{n_frames}", flush=True)
        finally:
            proc.stdin.close()
            rc = proc.wait()
        if rc != 0:
            raise SystemExit(f"ffmpeg rc={rc}")
    meta["size_bytes"] = out.stat().st_size
    out.with_suffix(out.suffix + ".meta.json").write_text(json.dumps(meta, indent=2))
    print("OK", out, meta["size_bytes"], flush=True)
    return meta


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--duration", type=float, default=1800.0,
                    help="seconds; default 1800 (10ppm→18ms drift)")
    ap.add_argument("--period", type=float, default=PERIOD_S)
    ap.add_argument("--audio-delay-ms", type=float, default=0.0)
    ap.add_argument("--also-plus100", action="store_true")
    ap.add_argument("--vbitrate", default="2000k")
    args = ap.parse_args()
    gen(args.out, duration_s=args.duration, period_s=args.period,
        audio_delay_ms=args.audio_delay_ms, vbitrate=args.vbitrate)
    if args.also_plus100:
        p = args.out.with_name(args.out.stem + "_audioPlus100ms" + args.out.suffix)
        gen(p, duration_s=args.duration, period_s=args.period,
            audio_delay_ms=100.0, vbitrate=args.vbitrate)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
