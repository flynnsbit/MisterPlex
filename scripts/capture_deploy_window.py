#!/usr/bin/env python3
"""Continuous multi-frame HDMI capture across a deploy window.

Acquires the shared capture lock on the git-common-dir (shared across all
worktrees on this machine), then captures frames continuously for --duration
seconds, saving each frame and reporting per-frame stats.  Designed for
deploy-transition grading where signal classification must change state
(e.g. BLACK_SIGNAL → CONTENT_PRESENT after a livelock fix).

IMPORTANT — warmup frame discarding:
  The MS2109 (534d:2109) emits a leading run of flat RGB(7,7,7) frames on each
  ffmpeg open until the HDMI receiver locks (~10-11 frames measured).  Each
  grab_frame() call invokes a fresh ffmpeg process, so the first frame after a
  3-second interval may be a warmup frame.  This script discards any frame with
  spatial_std < SPATIAL_CONTENT as a likely warmup.  The discard is safe: a
  genuinely black or disconnected source produces std≈0 on EVERY attempt, so
  it will still be classified BLACK_SIGNAL/NO_SIGNAL once warmup budget is gone.

IMPORTANT — black-screen ambiguity:
  With the MiSTer powered off, the MS2109 delivers flat RGB(7,7,7) which is
  identical to the black-screen RBF output.  Pass --host 192.168.1.183 to
  probe reachability when a BLACK verdict is reached; the summary will then
  attribute black to source_unreachable vs core_paints_black.

Classification states reported per-frame:
  CONTENT_PRESENT  — luma >= LUMA_BLACK, spatial_std >= SPATIAL_CONTENT
  BLACK_SIGNAL     — luma < LUMA_BLACK (screen output, but black)
  NO_SIGNAL        — spatial_std < SPATIAL_CONTENT (no HDMI signal at all)
  STALE_CAPTURE    — consecutive identical frames (device buffering / frozen)
  WARMUP           — leading flat frame discarded (not scored)

Exit codes:
  0  any frame reached CONTENT_PRESENT before --duration expired
  1  capture completed without CONTENT_PRESENT (stuck black or no-signal)
  2  capture error / device problem
  77 device not available (no node / busy)

Usage:
  python3 scripts/capture_deploy_window.py
  python3 scripts/capture_deploy_window.py --duration 90 --out-dir build/deploy-capture
  python3 scripts/capture_deploy_window.py --device /dev/video0 --interval 2.0 --host 192.168.1.183
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent


def _git_common_dir(repo_root: Path) -> Path:
    """Return the git common dir (shared across all worktrees on this machine)."""
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            cwd=repo_root, capture_output=True, text=True, timeout=5,
        )
        if r.returncode == 0:
            p = r.stdout.strip()
            if not Path(p).is_absolute():
                p = str(repo_root / p)
            return Path(p).resolve()
    except Exception:
        pass
    return repo_root

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
    ap.add_argument("--lock-file", default=None,
                    help="flock path. Defaults to git-common-dir/video0.lock "
                         "(shared across all worktrees on this machine).")
    ap.add_argument("--lock-timeout", type=float, default=15.0)
    ap.add_argument("--host", default=None,
                    help="MiSTer host (e.g. 192.168.1.183). When a BLACK verdict is "
                         "reached this host is probed; unreachable → REFUSE attribution "
                         "rather than core-defect attribution.")
    ap.add_argument("--warmup-max", type=int, default=5,
                    help="Max consecutive leading flat frames to discard as MS2109 warmup. "
                         "0 = disable discarding.")
    args = ap.parse_args()

    out_dir = ROOT / args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    # Resolve lock path: git-common-dir is shared across all worktrees
    if args.lock_file:
        lock_path = Path(args.lock_file)
        if not lock_path.is_absolute():
            lock_path = ROOT / args.lock_file
    else:
        git_dir = _git_common_dir(ROOT)
        lock_path = git_dir / "video0.lock"
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
    warmup_discarded = 0      # leading flat frames discarded
    got_non_warmup = False    # once we've seen a real frame, no more discarding

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

                # Warmup discard: leading flat frames from MS2109 HDMI receiver lock
                if (args.warmup_max > 0 and not got_non_warmup
                        and warmup_discarded < args.warmup_max
                        and std_v < SPATIAL_CONTENT):
                    warmup_discarded += 1
                    print(f"  [{elapsed:6.1f}s] WARMUP #{warmup_discarded}: "
                          f"luma={luma_v:.2f} std={std_v:.2f} sha={sha[:8]} "
                          f"(MS2109 receiver-lock artefact, discarded)", flush=True)
                    frame_idx += 1
                    sleep_t = max(0.0, args.interval - (time.time() - t0))
                    if sleep_t > 0:
                        time.sleep(sleep_t)
                    continue

                got_non_warmup = True
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

    # Probe host reachability if black and --host was given
    # (a powered-off MiSTer produces flat RGB(7,7,7) — indistinguishable from black-RBF)
    black_attribution = None
    if black_frames and not content_frames and args.host:
        try:
            r = subprocess.run(["ping", "-c", "1", "-W", "3", args.host],
                               capture_output=True, timeout=6)
            reachable = r.returncode == 0
        except Exception:
            reachable = False
        if not reachable:
            black_attribution = "source_host_unreachable"
            print(f"  HOST_PROBE: {args.host} UNREACHABLE — black frames cannot be blamed "
                  f"on the core (MS2109 outputs flat RGB(7,7,7) when source is off)", flush=True)
        else:
            black_attribution = "source_host_reachable_core_paints_black"
            print(f"  HOST_PROBE: {args.host} REACHABLE — black is attributable to core/daemon", flush=True)

    verdict = "CONTENT_PRESENT" if content_frames else (
        "REFUSE_SOURCE_OFFLINE" if black_attribution == "source_host_unreachable" else (
        "BLACK_SIGNAL" if black_frames else (
        "NO_SIGNAL" if nosig_frames else (
        "STALE_CAPTURE" if stale_frames else "CAPTURE_ERROR"))))

    summary = {
        "total_frames": total_frames,
        "warmup_discarded": warmup_discarded,
        "content_frames": len(content_frames),
        "black_frames": len(black_frames),
        "nosig_frames": len(nosig_frames),
        "stale_frames": len(stale_frames),
        "error_frames": len(error_frames),
        "first_content_t": first_content_t,
        "luma_range": [luma_min, luma_max],
        "black_attribution": black_attribution,
        "verdict": verdict,
        "frames": frames_data,
    }
    summary_path = out_dir / "deploy_window_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2))
    print(f"\nDEPLOY_WINDOW_SUMMARY:", flush=True)
    print(f"  Scope: {total_frames} frames over {args.duration:.0f}s window "
          f"(warmup_discarded={warmup_discarded})", flush=True)
    print(f"  CONTENT_PRESENT: {len(content_frames)} frames", flush=True)
    print(f"  BLACK_SIGNAL:    {len(black_frames)} frames", flush=True)
    print(f"  NO_SIGNAL:       {len(nosig_frames)} frames", flush=True)
    print(f"  STALE_CAPTURE:   {len(stale_frames)} frames", flush=True)
    print(f"  CAPTURE_ERROR:   {len(error_frames)} frames", flush=True)
    print(f"  luma range:      {luma_min}..{luma_max}", flush=True)
    print(f"  first_content:   {first_content_t}s", flush=True)
    print(f"  black_attr:      {black_attribution}", flush=True)
    print(f"  VERDICT:         {verdict}", flush=True)
    print(f"  summary JSON:    {summary_path}", flush=True)

    return 0 if content_frames else 1

if __name__ == "__main__":
    sys.exit(main())
