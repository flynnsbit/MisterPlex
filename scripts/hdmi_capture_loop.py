#!/usr/bin/env python3
"""Continuous MS2109 HDMI capture watchdog.

Scores each tick as NO_SIGNAL / VALID_BLACK / VALID_CONTENT and alerts on change.

MS2109 (534d:2109) facts established by test on this rig:
  * Every stream open emits a run of filler frames of exactly RGB(7,7,7)
    before the card locks and real content appears.  With a generous capture
    the first good frame lands at index 11-14, but a SHORT capture can come
    back entirely filler -- the card does not lock at all if the stream is torn
    down after a fraction of a second.  A short capture therefore ALWAYS
    yields "uniform luma 7, distinct=1" no matter what the source is sending.
    The fix is to hold the stream open for a generous frame count and score
    only the tail.
  * 1920x1080 is advertised but dead on this input: every frame stays
    RGB(7,7,7).  1280x720 MJPG carries real content.
  * Because the filler is exactly 7 and real video black is 0 (or 16 limited
    range), an unfed card and a genuinely black frame are separable.
"""

import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import time
from collections import deque

import numpy as np
from PIL import Image

FILLER_LEVEL = 7  # MS2109 no-signal / dead-mode filler value
FILLER_TOL = 0.75
BLACK_MEAN_MAX = 24.0  # limited-range black sits near 16
FLAT_STD_MAX = 2.0
CONTENT_STD_MIN = 3.0
CONTENT_DISTINCT_MIN = 12


def analyse(path):
    rgb = np.asarray(Image.open(path).convert("RGB")).astype(np.float32)
    luma = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
    flat_rgb = rgb.reshape(-1, 3)
    uniform_rgb = bool(np.all(flat_rgb.max(axis=0) == flat_rgb.min(axis=0)))
    return {
        "mean": float(luma.mean()),
        "std": float(luma.std()),
        "min": float(luma.min()),
        "max": float(luma.max()),
        "distinct": int(len(np.unique(luma.astype(np.uint8)))),
        "uniform_rgb": uniform_rgb,
        "bytes": os.path.getsize(path),
        "luma": luma,
    }


def classify(m):
    """NO_SIGNAL vs VALID_BLACK vs VALID_CONTENT.

    A flat frame from an unfed card is the filler value 7; a flat frame from a
    fed-but-black source is not.  That is the whole point of this function.
    """
    filler = m["uniform_rgb"] and abs(m["mean"] - FILLER_LEVEL) <= FILLER_TOL
    if filler:
        return "NO_SIGNAL"
    if m["std"] >= CONTENT_STD_MIN or m["distinct"] >= CONTENT_DISTINCT_MIN:
        return "VALID_CONTENT"
    if m["std"] <= FLAT_STD_MAX and m["mean"] <= BLACK_MEAN_MAX:
        return "VALID_BLACK"
    return "VALID_CONTENT"


def capture(dev, w, h, total, workdir):
    for f in glob.glob(os.path.join(workdir, "cap_*.jpg")):
        os.remove(f)
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-f", "v4l2", "-input_format", "mjpeg",
        "-video_size", f"{w}x{h}", "-i", dev,
        "-frames:v", str(total), "-q:v", "2",
        os.path.join(workdir, "cap_%03d.jpg"),
    ]
    try:
        subprocess.run(cmd, capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        return []
    return sorted(glob.glob(os.path.join(workdir, "cap_*.jpg")))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="/dev/video0")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--interval", type=float, default=20.0)
    ap.add_argument("--frames", type=int, default=150,
                    help="frames pulled per tick; the card needs a long open to lock")
    ap.add_argument("--score-frames", type=int, default=4,
                    help="tail frames actually scored")
    ap.add_argument("--relock-tries", type=int, default=3,
                    help="re-captures allowed when a tick comes back all-filler")
    ap.add_argument("--history", type=int, default=32)
    ap.add_argument("--delta-alert", type=float, default=1.5,
                    help="mean abs luma delta vs previous tick that counts as CHANGE")
    ap.add_argument("--outdir", default=os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "artifacts", "hdmi-capture"))
    ap.add_argument("--ticks", type=int, default=0, help="0 = run forever")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    workdir = os.path.join(args.outdir, "work")
    os.makedirs(workdir, exist_ok=True)
    logpath = os.path.join(args.outdir, "hdmi_capture.log")
    jsonlpath = os.path.join(args.outdir, "hdmi_capture.jsonl")
    alertpath = os.path.join(args.outdir, "hdmi_alerts.log")
    statepath = os.path.join(args.outdir, "state.json")

    def emit(line, alert=False):
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        text = f"{stamp} {line}\n"
        with open(logpath, "a") as fh:
            fh.write(text)
        if alert:
            with open(alertpath, "a") as fh:
                fh.write(text)
        sys.stdout.write(text)
        sys.stdout.flush()

    hist = deque(maxlen=args.history)
    prev_luma = None
    prev_state = None
    emit(f"START dev={args.device} {args.width}x{args.height} interval={args.interval}s "
         f"frames={args.frames} score={args.score_frames} pid={os.getpid()}")

    scored = []
    tick = 0
    while args.ticks == 0 or tick < args.ticks:
        tick += 1
        # An all-filler tick may be a slow re-lock rather than a real loss of
        # signal, so confirm before letting NO_SIGNAL stand.
        for _attempt in range(args.relock_tries):
            frames = capture(args.device, args.width, args.height,
                             args.frames, workdir)
            scored = frames[-args.score_frames:]
            if not scored:
                break
            if any(classify(analyse(f)) != "NO_SIGNAL" for f in scored):
                break
            time.sleep(2.0)
        if not scored:
            state = "CAPTURE_FAIL"
            rec = {"tick": tick, "ts": time.time(), "state": state,
                   "frames": len(frames)}
            changed = state != prev_state
            emit(f"tick={tick:06d} state=CAPTURE_FAIL frames={len(frames)}"
                 + (f"  *** CHANGE {prev_state} -> {state} ***" if changed else ""),
                 alert=changed)
            prev_state, prev_luma = state, None
            hist.append(rec)
            with open(jsonlpath, "a") as fh:
                fh.write(json.dumps(rec) + "\n")
            time.sleep(args.interval)
            continue

        metrics = [analyse(f) for f in scored]
        states = [classify(m) for m in metrics]
        # Worst-to-best precedence: any real content in the window wins.
        if "VALID_CONTENT" in states:
            state = "VALID_CONTENT"
        elif "VALID_BLACK" in states:
            state = "VALID_BLACK"
        else:
            state = "NO_SIGNAL"

        best = metrics[states.index(state)]
        luma = best["luma"]
        delta = None if prev_luma is None or prev_luma.shape != luma.shape \
            else float(np.abs(luma - prev_luma).mean())

        changed = (state != prev_state) or (delta is not None and delta >= args.delta_alert)
        rec = {
            "tick": tick, "ts": time.time(), "state": state,
            "mean": round(best["mean"], 3), "std": round(best["std"], 3),
            "min": best["min"], "max": best["max"],
            "distinct": best["distinct"], "uniform_rgb": best["uniform_rgb"],
            "bytes": best["bytes"],
            "delta": None if delta is None else round(delta, 4),
            "changed": changed,
        }
        hist.append(rec)

        line = (f"tick={tick:06d} state={state:<13s} mean={best['mean']:7.2f} "
                f"std={best['std']:8.3f} distinct={best['distinct']:3d} "
                f"bytes={best['bytes']:7d} "
                f"delta={'  n/a  ' if delta is None else format(delta, '7.4f')}")
        if changed:
            line += f"  *** CHANGE {prev_state} -> {state} ***"
            shutil.copyfile(scored[states.index(state)],
                            os.path.join(args.outdir, f"change_{tick:06d}_{state}.jpg"))
        emit(line, alert=changed)

        shutil.copyfile(scored[-1], os.path.join(args.outdir, "latest.jpg"))
        with open(jsonlpath, "a") as fh:
            fh.write(json.dumps(rec) + "\n")
        with open(statepath, "w") as fh:
            json.dump({"current": rec, "history": list(hist)}, fh, indent=1)

        prev_state, prev_luma = state, luma
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
