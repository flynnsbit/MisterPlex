#!/usr/bin/env python3
"""Continuous MS2109 HDMI capture watchdog, persistent-stream edition.

Scores the live HDMI feed as NO_SIGNAL / VALID_BLACK / VALID_CONTENT and alerts
on change, WITHOUT disturbing the source.

WHY PERSISTENT STREAM (do not "optimise" this back):
    Opening /dev/video0 makes the MS2109 re-assert hotplug/EDID, which forces
    the HDMI source to renegotiate and RE-SYNC ITS OUTPUT.  A watchdog that
    reopened the device every tick was therefore kicking the MiSTer's video
    every interval -- an active disturbance disguised as passive observation,
    and a likely cause of "menu not responding" reports.

    So: the device is opened EXACTLY ONCE, at startup, and the handle is held
    for the life of the process.  A reader thread drains frames continuously
    and keeps only the newest one in memory; scoring reads that in-memory
    frame.  There is no per-tick open, no per-tick close, no per-tick ffmpeg.

    Reopening is an error path only (stream EOF / device lost), is rate
    limited, and is logged as a RECONNECT event so it can never masquerade as
    normal operation.

MS2109 facts established by test on this rig:
    * Every stream open emits a run of filler frames of exactly RGB(7,7,7)
      before the card locks; the first good frame lands around index 11-14.
      With a single lifetime open we skip that run once at startup and never
      see filler again.
    * Real video black is 0 (or 16 limited range), never 7, so an unfed card
      and a genuinely black frame stay separable.
"""

import argparse
import json
import os
import subprocess
import sys
import threading
import time
from collections import deque

import numpy as np
from PIL import Image

FILLER_LEVEL = 7  # MS2109 no-signal / pre-lock filler value
FILLER_TOL = 0.75
BLACK_MEAN_MAX = 24.0  # limited-range black sits near 16
FLAT_STD_MAX = 2.0
CONTENT_STD_MIN = 3.0
CONTENT_DISTINCT_MIN = 12


class PersistentCapture:
    """One ffmpeg, one open of /dev/video0, for the life of the process."""

    def __init__(self, device, width, height, fps, warmup, emit):
        self.device, self.width, self.height = device, width, height
        self.fps, self.warmup, self.emit = fps, warmup, emit
        self.frame_bytes = width * height * 3
        self._lock = threading.Lock()
        self._latest = None
        self._count = 0
        self._opens = 0
        self._stop = threading.Event()
        self.proc = None
        self._thread = None

    def _spawn(self):
        cmd = [
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-f", "v4l2", "-input_format", "mjpeg",
            "-video_size", f"{self.width}x{self.height}",
            "-framerate", str(self.fps),
            "-i", self.device,
            "-pix_fmt", "rgb24", "-f", "rawvideo", "-",
        ]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL,
                                     bufsize=self.frame_bytes)
        self._opens += 1

    def _reader(self):
        """Drain frames forever. Only this thread ever touches the pipe."""
        seen = 0
        while not self._stop.is_set():
            buf = self.proc.stdout.read(self.frame_bytes)
            if not buf or len(buf) < self.frame_bytes:
                if self._stop.is_set():
                    return
                self.emit(f"STREAM_EOF after {seen} frames on this open", alert=True)
                return
            seen += 1
            if seen <= self.warmup:
                continue  # one-time filler skip, never repeated
            frame = np.frombuffer(buf, np.uint8).reshape(self.height, self.width, 3)
            with self._lock:
                self._latest = frame
                self._count += 1

    def start(self):
        self._spawn()
        self._thread = threading.Thread(target=self._reader, daemon=True)
        self._thread.start()
        self.emit(f"STREAM_OPEN #{self._opens} pid={self.proc.pid} "
                  f"{self.width}x{self.height}@{self.fps} warmup={self.warmup}")

    def alive(self):
        return self._thread is not None and self._thread.is_alive() \
            and self.proc is not None and self.proc.poll() is None

    def reconnect(self):
        """Exceptional path only. Costs the source an HDMI renegotiation."""
        self.emit(f"RECONNECT -- reopening {self.device} (open #{self._opens + 1}); "
                  f"this re-asserts hotplug on the source", alert=True)
        try:
            if self.proc and self.proc.poll() is None:
                self.proc.terminate()
                self.proc.wait(timeout=5)
        except Exception:
            pass
        if self._thread is not None:
            self._thread.join(timeout=5)
        with self._lock:
            self._latest, self._count = None, 0
        self.start()

    def latest(self):
        with self._lock:
            return (None, self._count) if self._latest is None \
                else (self._latest.copy(), self._count)

    def close(self):
        self._stop.set()
        try:
            if self.proc and self.proc.poll() is None:
                self.proc.terminate()
                self.proc.wait(timeout=5)
        except Exception:
            pass


def analyse(rgb):
    rgb = rgb.astype(np.float32)
    luma = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
    flat = rgb.reshape(-1, 3)
    return {
        "mean": float(luma.mean()),
        "std": float(luma.std()),
        "min": float(luma.min()),
        "max": float(luma.max()),
        "distinct": int(len(np.unique(luma.astype(np.uint8)))),
        "uniform_rgb": bool(np.all(flat.max(axis=0) == flat.min(axis=0))),
        "luma": luma,
    }


def classify(m):
    """NO_SIGNAL vs VALID_BLACK vs VALID_CONTENT.

    A flat frame from an unfed card is the filler value 7; a flat frame from a
    fed-but-black source is not.  That is the whole point of this function.
    """
    if m["uniform_rgb"] and abs(m["mean"] - FILLER_LEVEL) <= FILLER_TOL:
        return "NO_SIGNAL"
    if m["std"] >= CONTENT_STD_MIN or m["distinct"] >= CONTENT_DISTINCT_MIN:
        return "VALID_CONTENT"
    if m["std"] <= FLAT_STD_MAX and m["mean"] <= BLACK_MEAN_MAX:
        return "VALID_BLACK"
    return "VALID_CONTENT"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="/dev/video0")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--fps", type=int, default=5,
                    help="capture rate of the persistent stream")
    ap.add_argument("--interval", type=float, default=60.0,
                    help="scoring interval; costs the source nothing")
    ap.add_argument("--warmup", type=int, default=20,
                    help="filler frames skipped ONCE per open")
    ap.add_argument("--history", type=int, default=32)
    ap.add_argument("--delta-alert", type=float, default=1.5)
    ap.add_argument("--stall-ticks", type=int, default=2,
                    help="ticks with no new frame before a RECONNECT is allowed")
    ap.add_argument("--outdir", default=os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "artifacts", "hdmi-capture"))
    ap.add_argument("--ticks", type=int, default=0, help="0 = run forever")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    logpath = os.path.join(args.outdir, "hdmi_capture.log")
    jsonlpath = os.path.join(args.outdir, "hdmi_capture.jsonl")
    alertpath = os.path.join(args.outdir, "hdmi_alerts.log")
    statepath = os.path.join(args.outdir, "state.json")

    def emit(line, alert=False):
        text = f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {line}\n"
        with open(logpath, "a") as fh:
            fh.write(text)
        if alert:
            with open(alertpath, "a") as fh:
                fh.write(text)
        sys.stdout.write(text)
        sys.stdout.flush()

    cap = PersistentCapture(args.device, args.width, args.height,
                            args.fps, args.warmup, emit)
    emit(f"START dev={args.device} {args.width}x{args.height} interval={args.interval}s "
         f"mode=persistent-stream pid={os.getpid()}")
    cap.start()

    hist = deque(maxlen=args.history)
    prev_luma = prev_state = None
    prev_count = -1
    stalled = 0
    tick = 0
    try:
        while args.ticks == 0 or tick < args.ticks:
            time.sleep(args.interval)
            tick += 1
            frame, count = cap.latest()

            if frame is None or count == prev_count:
                stalled += 1
                dead = not cap.alive()
                state = "STREAM_STALL" if not dead else "STREAM_DEAD"
                changed = state != prev_state
                emit(f"tick={tick:06d} state={state:<13s} frames={count} "
                     f"stalled_ticks={stalled} alive={cap.alive()}"
                     + (f"  *** CHANGE {prev_state} -> {state} ***" if changed else ""),
                     alert=changed)
                prev_state, prev_count = state, count
                if stalled >= args.stall_ticks and (dead or frame is None):
                    cap.reconnect()
                    stalled, prev_count = 0, -1
                continue

            stalled = 0
            m = analyse(frame)
            state = classify(m)
            luma = m["luma"]
            delta = None if prev_luma is None or prev_luma.shape != luma.shape \
                else float(np.abs(luma - prev_luma).mean())
            changed = (state != prev_state) or \
                (delta is not None and delta >= args.delta_alert)

            rec = {"tick": tick, "ts": time.time(), "state": state,
                   "mean": round(m["mean"], 3), "std": round(m["std"], 3),
                   "min": m["min"], "max": m["max"], "distinct": m["distinct"],
                   "uniform_rgb": m["uniform_rgb"], "stream_frames": count,
                   "opens": cap._opens,
                   "delta": None if delta is None else round(delta, 4),
                   "changed": changed}
            hist.append(rec)

            line = (f"tick={tick:06d} state={state:<13s} mean={m['mean']:7.2f} "
                    f"std={m['std']:8.3f} distinct={m['distinct']:3d} "
                    f"frames={count:6d} opens={cap._opens} "
                    f"delta={'  n/a  ' if delta is None else format(delta, '7.4f')}")
            if changed:
                line += f"  *** CHANGE {prev_state} -> {state} ***"
                Image.fromarray(frame).save(
                    os.path.join(args.outdir, f"change_{tick:06d}_{state}.jpg"),
                    quality=88)
            emit(line, alert=changed)

            Image.fromarray(frame).save(os.path.join(args.outdir, "latest.jpg"),
                                        quality=88)
            with open(jsonlpath, "a") as fh:
                fh.write(json.dumps(rec) + "\n")
            with open(statepath, "w") as fh:
                json.dump({"current": rec, "history": list(hist)}, fh, indent=1)

            prev_state, prev_luma, prev_count = state, luma, count
    finally:
        cap.close()
        emit("STOP")


if __name__ == "__main__":
    main()
