#!/usr/bin/env python3
"""Real-content BBB soak / ladder with glass ID + hard A/V markers.

Burns OCR-proof glass ID on EVERY frame (no enable= guard). Body (y>=ID band)
gets a short white flash centered on each marker time; audio gets a 1 kHz beep
with 1 ms attack at the SAME content time (designed offset 0.0 ms).

Encodes H.264 Constrained Baseline, bf=0, AAC 48 kHz — FPGA decoder contract.

Example:
  python3 scripts/gen_real_bbb_avsync_soak.py \\
    --src .agent-work/fixtures-real/bbb_720p_src.mp4 \\
    --out assets/avsync/real_bbb_glass_av_624x480_24_1200s.mp4 \\
    --width 624 --height 480 --duration 1200 --period 2.0
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
from glass_frame_id import BAR_Y1, draw_id_band, format_text, geometry_for  # noqa: E402

FPS_NUM = 24
FPS_DEN = 1
SR = 48000
BEEP_S = 0.050
ATTACK_S = 0.001
BEEP_HZ = 1000.0
FLASH_FRAMES = 2  # full-white body hold at marker (plus neighbors optional)


def ffprobe_json(path: Path) -> dict:
    cmd = [
        "ffprobe", "-v", "error",
        "-show_entries", "format=duration",
        "-show_entries",
        "stream=index,codec_type,codec_name,width,height,r_frame_rate,"
        "avg_frame_rate,nb_frames,duration,profile,has_b_frames,sample_rate",
        "-of", "json", str(path),
    ]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"ffprobe failed rc={p.returncode}: {p.stderr}")
    return json.loads(p.stdout)


def write_beep_track(
    path: Path,
    duration_s: float,
    *,
    period_s: float,
    sample_rate: int = SR,
) -> list[float]:
    """s16le stereo beep-only track; return designed onset times (seconds)."""
    n = int(round(duration_s * sample_rate))
    onsets: list[float] = []
    k = 0
    while True:
        t0 = k * period_s
        if t0 >= duration_s:
            break
        onsets.append(t0)
        k += 1
    # Vectorized — pure-Python sample loop is multi-minute for 20 min audio.
    mono = np.zeros(n, dtype=np.float64)
    t = np.arange(n, dtype=np.float64) / float(sample_rate)
    for t0 in onsets:
        i0 = int(round(t0 * sample_rate))
        i1 = min(n, i0 + int(round(BEEP_S * sample_rate)))
        if i0 >= n or i1 <= i0:
            continue
        phase = t[i0:i1] - t0
        env = np.where(phase < ATTACK_S, phase / ATTACK_S, 1.0)
        mono[i0:i1] = 0.85 * env * np.sin(2 * math.pi * BEEP_HZ * t[i0:i1])
    s16 = np.clip(mono * 32767.0, -32768, 32767).astype(np.int16)
    stereo = np.column_stack([s16, s16]).reshape(-1)
    path.write_bytes(stereo.tobytes())
    return onsets

def body_flash_gain(n: int, fps: float, period_s: float) -> float:
    """1.0 = full white body at marker frame; 0.0 = leave content."""
    t = n / float(fps)
    k = int(round(t / period_s))
    t_m = k * period_s
    dn = int(round((t - t_m) * fps))
    # FLASH_FRAMES centered: dn in {0, 1} roughly → white
    if 0 <= dn < FLASH_FRAMES:
        return 1.0
    return 0.0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--src", type=Path, required=True, help="real content source (e.g. BBB)")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--width", type=int, default=624)
    ap.add_argument("--height", type=int, default=480)
    ap.add_argument("--duration", type=float, default=1200.0, help="output seconds (loop src)")
    ap.add_argument("--period", type=float, default=2.0, help="A/V marker period seconds")
    ap.add_argument("--vbitrate", default="2500k")
    ap.add_argument("--work", type=Path, default=None)
    args = ap.parse_args()

    if not args.src.is_file():
        raise SystemExit(f"missing src {args.src}")

    w, h = args.width, args.height
    fps = FPS_NUM / float(FPS_DEN)
    fps_str = f"{FPS_NUM}/{FPS_DEN}" if FPS_DEN != 1 else str(FPS_NUM)
    n_frames = int(round(args.duration * fps))
    geom = geometry_for(w, h)
    id_bottom = geom.bar_y1  # even; body flash below ID band
    bufsize = (
        str(int(args.vbitrate[:-1]) * 2) + "k"
        if args.vbitrate[-1] in "kK"
        else args.vbitrate
    )

    work = args.work or Path(tempfile.mkdtemp(prefix="bbb_av_"))
    work.mkdir(parents=True, exist_ok=True)
    args.out.parent.mkdir(parents=True, exist_ok=True)

    src_meta = ffprobe_json(args.src)
    print(
        f"SRC measured {json.dumps(src_meta, indent=2)[:500]}",
        flush=True,
    )
    print(
        f"OUT_PLAN w={w} h={h} fps={fps_str} duration_s={args.duration} "
        f"n_frames={n_frames} period_s={args.period} id_bottom={id_bottom} "
        f"text0={format_text(0)} designed_av_offset_ms=0.0",
        flush=True,
    )

    beep_pcm = work / "beep.s16"
    onsets = write_beep_track(beep_pcm, args.duration, period_s=args.period)
    print(f"beep_onsets_n={len(onsets)} first={onsets[:3]} last={onsets[-3:]}", flush=True)

    # Decode looped+scaled real content as rgb24; re-encode with mixed audio.
    # stream_loop -1 before -i loops infinitely; -t on output via frame count.
    dec_cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-stream_loop", "-1",
        "-i", str(args.src),
        "-an",
        "-vf", f"scale={w}:{h}:flags=bicubic,fps={fps_str}",
        "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-frames:v", str(n_frames),
        "pipe:1",
    ]
    # Audio: amix original (looped, 48k) + beep track, duration exact.
    # Use filter_complex via second ffmpeg reading pipe video + two audio inputs.
    enc_cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-s", f"{w}x{h}", "-r", fps_str, "-i", "pipe:0",
        "-stream_loop", "-1", "-i", str(args.src),
        "-f", "s16le", "-ar", str(SR), "-ac", "2", "-i", str(beep_pcm),
        "-filter_complex",
        f"[1:a]aresample={SR},aformat=sample_fmts=fltp:channel_layouts=stereo,"
        f"atrim=0:{args.duration},asetpts=PTS-STARTPTS,volume=0.85[a0];"
        f"[2:a]aformat=sample_fmts=fltp:channel_layouts=stereo,"
        f"atrim=0:{args.duration},asetpts=PTS-STARTPTS[a1];"
        f"[a0][a1]amix=inputs=2:duration=first:dropout_transition=0,"
        f"atrim=0:{args.duration},asetpts=PTS-STARTPTS[aout]",
        "-map", "0:v:0", "-map", "[aout]",
        "-c:v", "libx264", "-profile:v", "baseline", "-bf", "0",
        "-x264-params", "cabac=0:ref=1:bframes=0:keyint=48",
        "-pix_fmt", "yuv420p",
        "-b:v", args.vbitrate, "-maxrate", args.vbitrate, "-bufsize", bufsize,
        "-r", fps_str,
        "-c:a", "aac", "-b:a", "160k", "-ar", str(SR), "-ac", "2",
        "-t", str(args.duration),
        "-movflags", "+faststart",
        str(args.out),
    ]

    print("DEC", " ".join(dec_cmd), flush=True)
    print("ENC", " ".join(enc_cmd), flush=True)

    dec = subprocess.Popen(dec_cmd, stdout=subprocess.PIPE)
    enc = subprocess.Popen(enc_cmd, stdin=subprocess.PIPE)
    assert dec.stdout and enc.stdin

    frame_bytes = w * h * 3
    n = 0
    try:
        while n < n_frames:
            buf = dec.stdout.read(frame_bytes)
            if len(buf) < frame_bytes:
                print(f"WARN short read at n={n} got={len(buf)}", flush=True)
                break
            rgb = np.frombuffer(buf, dtype=np.uint8).reshape((h, w, 3)).copy()
            g = body_flash_gain(n, fps, args.period)
            if g > 0.0:
                # Opaque white body — ID band never touched here
                rgb[id_bottom:, :, :] = 255
            draw_id_band(rgb, n, geom)
            enc.stdin.write(rgb.tobytes())
            n += 1
            if n % 500 == 0:
                print(f"  burned {n}/{n_frames}", flush=True)
    finally:
        enc.stdin.close()
        erc = enc.wait()
        dec.stdout.close()
        drc = dec.wait()

    print(f"decode_rc={drc} encode_rc={erc} frames_burned={n}", flush=True)
    if erc != 0 or n != n_frames:
        return 1 if erc == 0 else erc

    # Measure output
    meta = ffprobe_json(args.out)
    report = {
        "out": str(args.out),
        "src": str(args.src),
        "caller_supplied": {
            "width": w,
            "height": h,
            "fps": f"{FPS_NUM}/{FPS_DEN}",
            "duration_s": args.duration,
            "period_s": args.period,
            "designed_av_offset_ms": 0.0,
            "flash_frames": FLASH_FRAMES,
            "beep_s": BEEP_S,
            "id_text_example": format_text(0),
            "id_bottom_y": id_bottom,
            "vbitrate": args.vbitrate,
            "profile": "baseline (Constrained Baseline via cabac=0)",
            "bf": 0,
            "audio": "aac 48k mix(src+beep)",
        },
        "measured_ffprobe": meta,
        "frames_burned": n,
        "beep_onsets_n": len(onsets),
        "size_bytes": args.out.stat().st_size,
    }
    rep_path = args.out.with_suffix(args.out.suffix + ".meta.json")
    rep_path.write_text(json.dumps(report, indent=2))
    print(f"OK {args.out} size={args.out.stat().st_size} meta={rep_path}", flush=True)
    print(json.dumps({"measured_streams": meta.get("streams"), "format": meta.get("format")}, indent=2), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
