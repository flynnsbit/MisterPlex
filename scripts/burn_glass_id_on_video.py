#!/usr/bin/env python3
"""Burn OCR-proof glass ID band onto every frame of an existing video.

Preserves source timing as measured by ffprobe when --fps-num/--fps-den omitted.
Re-encodes Constrained Baseline no-B AAC 48 kHz for FPGA decoder contract.
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
from glass_frame_id import draw_id_band, format_text, geometry_for  # noqa: E402


def ffprobe_stream(path: Path) -> dict:
    cmd = [
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,duration",
        "-of", "json", str(path),
    ]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"ffprobe failed rc={p.returncode}: {p.stderr}")
    return json.loads(p.stdout)["streams"][0]


def parse_rate(s: str) -> tuple[int, int]:
    if "/" in s:
        a, b = s.split("/", 1)
        return int(a), int(b)
    return int(round(float(s) * 1001)), 1001  # should not happen for our fixtures


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--in", dest="inp", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--max-frames", type=int, default=0, help="0=all")
    ap.add_argument("--vbitrate", default="2500k")
    args = ap.parse_args()

    meta = ffprobe_stream(args.inp)
    w, h = int(meta["width"]), int(meta["height"])
    r = meta.get("r_frame_rate") or meta.get("avg_frame_rate")
    fps_num, fps_den = parse_rate(r)
    fps_str = f"{fps_num}/{fps_den}" if fps_den != 1 else str(fps_num)
    print(f"SOURCE measured {w}x{h} r_frame_rate={r} nb={meta.get('nb_frames')} dur={meta.get('duration')}", flush=True)
    print(f"ID_CONTRACT text={format_text(0)} geom={w}x{h} src=caller_supplied", flush=True)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    geom = geometry_for(w, h)
    bufsize = str(int(args.vbitrate[:-1]) * 2) + "k" if args.vbitrate[-1] in "kK" else args.vbitrate

    # decode raw rgb24
    dec = subprocess.Popen(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-i", str(args.inp),
            "-f", "rawvideo", "-pix_fmt", "rgb24",
            "-an", "pipe:1",
        ],
        stdout=subprocess.PIPE,
    )
    enc = subprocess.Popen(
        [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "rgb24",
            "-s", f"{w}x{h}", "-r", fps_str, "-i", "pipe:0",
            "-i", str(args.inp),
            "-map", "0:v:0", "-map", "1:a:0?",
            "-c:v", "libx264", "-profile:v", "baseline", "-bf", "0",
            "-x264-params", "cabac=0:ref=1:bframes=0:keyint=48",
            "-pix_fmt", "yuv420p",
            "-b:v", args.vbitrate, "-maxrate", args.vbitrate, "-bufsize", bufsize,
            "-r", fps_str,
            "-c:a", "aac", "-b:a", "128k", "-ar", "48000", "-ac", "2",
            "-shortest", "-movflags", "+faststart",
            str(args.out),
        ],
        stdin=subprocess.PIPE,
    )
    assert dec.stdout and enc.stdin
    frame_bytes = w * h * 3
    n = 0
    try:
        while True:
            buf = dec.stdout.read(frame_bytes)
            if len(buf) < frame_bytes:
                break
            rgb = np.frombuffer(buf, dtype=np.uint8).reshape((h, w, 3)).copy()
            draw_id_band(rgb, n, geom)
            enc.stdin.write(rgb.tobytes())
            n += 1
            if n % 500 == 0:
                print(f"  burned {n}", flush=True)
            if args.max_frames and n >= args.max_frames:
                break
    finally:
        enc.stdin.close()
        erc = enc.wait()
        dec.stdout.close()
        drc = dec.wait()
    print(f"decode_rc={drc} encode_rc={erc} frames_burned={n}", flush=True)
    if erc != 0:
        return erc
    print(f"OK {args.out} size={args.out.stat().st_size} n_frames={n}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
