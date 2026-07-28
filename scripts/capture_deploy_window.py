#!/usr/bin/env python3
"""Continuous multi-frame HDMI capture across a deploy window.

Acquires the shared capture lock (build/video0.lock), then captures frames
continuously for --duration seconds, saving each frame and reporting per-frame
stats.  Designed for deploy-transition grading where signal classification must
change from one state to another across a menu bounce/core load.

Classification states reported per-frame:
  CONTENT_PRESENT  — luma >= LUMA_BLACK, spatial_std >= SPATIAL_CONTENT
  BLACK_SIGNAL     — luma < LUMA_BLACK (screen output, but black)
  NO_SIGNAL        — spatial_std < SPATIAL_CONTENT (no HDMI signal at all)
  STALE_CAPTURE    — consecutive identical frames (device buffering / frozen)

Exit codes:
  0  any frame reached CONTENT_PRESENT before --duration expired
  1  capture completed without CONTENT_PRESENT (stuck black or no-signal)
  2  capture error / device problem
  77 device not available (no node / busy)

Usage:
  python3 scripts/capture_deploy_window.py
  python3 scripts/capture_deploy_window.py --duration 90 --out-dir build/deploy-capture
  python3 scripts/capture_deploy_window.py --device /dev/video0 --interval 2.0
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import sys
import time
from pathlib import Path
from typing import Optional

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import subprocess

LUMA_BLACK: float = 8.0
SPATIAL_CONTENT: float = 3.0

def _sha16(arr: np.ndarray) -> str:
    return hashlib.sha256(arr.tobytes()).hexdigest()[:16]

def _luma(frame: np.ndarray) -> float:
    r, g, b = frame[...,0].astype(float), frame[...,1].astype(float), frame[...,2].astype(float)
    return float((0.299*r + 0.587*g + 0.114*b).mean())

def _std(frame: np.ndarray) -> float:
    return float(frame.astype(float).std())

def _classify(frames: list[np.ndarray]) -> str:
    hashes = [_sha16(f) for f in frames]
    unique = len(set(hashes))
    last = frames[-1]
    luma = _luma(last)
    std = _std(last)
    if luma < LUMA_BLACK:
        return "BLACK_SIGNAL"
    if std < SPATIAL_CONTENT:
        return "NO_SIGNAL"
    if len(frames) >= 2 and unique == 1:
        return "STALE_CAPTURE"
    return "CONTENT_PRESENT"

def grab_frame(dev: str, out: Path) -> tuple[Optional[np.ndarray], str]:
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-f", "v4l2",
        "-input_format", "mjpeg",
        "-video_size", "1280x720",
        "-framerate", "60",
        "-i", dev,
        "-vf", "format=rgb24",
        "-frames:v", "1",
        "-update", "1",
        "-y", str(out),
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=45)
    except Exception as e:
        return None, str(e)
    log = (r.stderr + r.stdout).strip()
    if r.returncode != 0 or not out.exists() or out.stat().st_size == 0:
        return None, f"ffmpeg rc={r.returncode}: {log[:300]}"
    try:
        arr = np.array(Image.open(out).convert("RGB"), dtype=np.uint8)
        return arr, ""
    except Exception as e:
        return None, f"image load error: {e}"

def main() -> int:
    ap = argparse.ArgumentParser(description="Continuous deploy-window HDMI capture")
    ap.add_argument("--device", default="/dev/video0")
    ap.add_argument("--duration", type=float, default=90.0,
                    help="Total capture window in seconds")
    ap.add_argument("--interval", type=float, default=3.0,
                    help="Seconds between frames (ffmpeg startup overhead ~2s each)")
    ap.add_argument("--out-dir", default="build/deploy-capture",
                    help="Directory for captured frames and summary JSON")
    ap.add_argument("--lock-file", default="build/video0.lock",
                    help="flock path for exclusive device access")
    ap.add_argument("--lock-timeout", type=float, default=15.0)
    args = ap.parse_args()

    out_dir = ROOT / args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    lock_path = ROOT / args.lock_file
    lock_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"Scope: deploying against device={args.device} duration={args.duration}s interval={args.interval}s", flush=True)
    print(f"       outdir={out_dir}", flush=True)

    # Acquire exclusive capture lock
    lock_fd = open(lock_path, "w")
    try:
        deadline = time.monotonic() + args.lock_timeout
        while True:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    print(f"CAPTURE_LOCK_TIMEOUT: {lock_path} held by another process after {args.lock_timeout}s → exit 77")
                    return 77
                time.sleep(0.5)
        print(f"LOCK_ACQUIRED: {lock_path}", flush=True)
    except Exception as e:
        print(f"LOCK_ERROR: {e} → exit 77")
        return 77

    frames_data = []
    window_start = time.time()
    frame_idx = 0
    consecutive_hashes = []
    first_content_t = None

    try:
        while time.time() - window_start < args.duration:
            t0 = time.time()
            frame_path = out_dir / f"frame_{frame_idx:04d}.png"
            frame, err = grab_frame(args.device, frame_path)
            elapsed = time.time() - window_start
            cap_ms = int((time.time() - t0) * 1000)

            if frame is None:
                state = "CAPTURE_ERROR"
                luma_v = 0.0
                std_v = 0.0
                sha = "error"
                note = err
            else:
                luma_v = _luma(frame)
                std_v = _std(frame)
                sha = _sha16(frame)
                consecutive_hashes.append(sha)
                if len(consecutive_hashes) > 4:
                    consecutive_hashes = consecutive_hashes[-4:]
                state = _classify([frame] if len(consecutive_hashes) < 2 else
                                  [frame, frame] if consecutive_hashes[-1] == consecutive_hashes[-2] else
                                  [frame])
                note = ""

            row = {
                "idx": frame_idx,
                "t_elapsed": round(elapsed, 2),
                "state": state,
                "luma": round(luma_v, 2),
                "spatial_std": round(std_v, 2),
                "sha16": sha,
                "cap_ms": cap_ms,
                "frame_path": str(frame_path),
                "note": note,
            }
            frames_data.append(row)
            stale_mark = " *STALE*" if state == "STALE_CAPTURE" else ""
            print(f"  [{elapsed:6.1f}s] frame={frame_idx:03d} state={state:<18} "
                  f"luma={luma_v:6.2f} std={std_v:6.2f} sha={sha[:8]}{stale_mark}", flush=True)

            if state == "CONTENT_PRESENT" and first_content_t is None:
                first_content_t = elapsed
                print(f"  *** CONTENT_PRESENT first detected at t={elapsed:.1f}s ***", flush=True)

            frame_idx += 1
            # Pace ourselves; subtract capture time
            sleep_t = max(0.0, args.interval - (time.time() - t0))
            if sleep_t > 0:
                time.sleep(sleep_t)

    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()
        print(f"LOCK_RELEASED: {lock_path}", flush=True)

    # Summary
    total_frames = len(frames_data)
    content_frames = [r for r in frames_data if r["state"] == "CONTENT_PRESENT"]
    black_frames = [r for r in frames_data if r["state"] == "BLACK_SIGNAL"]
    nosig_frames = [r for r in frames_data if r["state"] == "NO_SIGNAL"]
    stale_frames = [r for r in frames_data if r["state"] == "STALE_CAPTURE"]
    error_frames = [r for r in frames_data if r["state"] == "CAPTURE_ERROR"]

    lumas = [r["luma"] for r in frames_data if r["luma"] > 0]
    luma_min = round(min(lumas), 2) if lumas else 0
    luma_max = round(max(lumas), 2) if lumas else 0

    verdict = "CONTENT_PRESENT" if content_frames else (
        "BLACK_SIGNAL" if black_frames else (
        "NO_SIGNAL" if nosig_frames else (
        "STALE_CAPTURE" if stale_frames else "CAPTURE_ERROR")))

    summary = {
        "total_frames": total_frames,
        "content_frames": len(content_frames),
        "black_frames": len(black_frames),
        "nosig_frames": len(nosig_frames),
        "stale_frames": len(stale_frames),
        "error_frames": len(error_frames),
        "first_content_t": first_content_t,
        "luma_range": [luma_min, luma_max],
        "verdict": verdict,
        "frames": frames_data,
    }
    summary_path = out_dir / "deploy_window_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2))
    print(f"\nDEPLOY_WINDOW_SUMMARY:", flush=True)
    print(f"  Scope: {total_frames} frames over {args.duration:.0f}s window", flush=True)
    print(f"  CONTENT_PRESENT: {len(content_frames)} frames", flush=True)
    print(f"  BLACK_SIGNAL:    {len(black_frames)} frames", flush=True)
    print(f"  NO_SIGNAL:       {len(nosig_frames)} frames", flush=True)
    print(f"  STALE_CAPTURE:   {len(stale_frames)} frames", flush=True)
    print(f"  CAPTURE_ERROR:   {len(error_frames)} frames", flush=True)
    print(f"  luma range:      {luma_min}..{luma_max}", flush=True)
    print(f"  first_content:   {first_content_t}s", flush=True)
    print(f"  VERDICT:         {verdict}", flush=True)
    print(f"  summary JSON:    {summary_path}", flush=True)

    return 0 if content_frames else 1

if __name__ == "__main__":
    sys.exit(main())
