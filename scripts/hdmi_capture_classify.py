#!/usr/bin/env python3
"""Capture/classify MiSTer HDMI as no-signal, valid black, or visible content."""
from __future__ import annotations

import argparse
import fcntl
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DEV = "/dev/video0"
DEFAULT_FORMAT = "mjpeg"
DEFAULT_SIZE = "1280x720"
DEFAULT_FPS = "60"
DEFAULT_OUT = ROOT / "build" / "hdmi_capture" / "frame.png"
DEFAULT_LOCK = ROOT / "build" / "hdmi_capture.lock"
RC_FAIL = 1
RC_UNSEEN = 2
RC_UNSCORED = 77

# A drawn marker is an exactly-saturated primary; MJPEG capture of a real panel
# does not produce long straight runs of these.
OVERLAY_SAT_HI = 250
OVERLAY_SAT_LO = 12
OVERLAY_RUN_FRACTION = 0.30

SCOPE = (
    "Scope: HDMI capture classifier for MiSTer idle/visual gates; captures MJPEG "
    "1280x720@60 from the local USB-HDMI adapter or reads a PNG, then classifies "
    "NO_SIGNAL, VALID_BLACK, or VALID_CONTENT from frame presence, geometry, "
    "luma mean/stddev, and dark/nonblack fractions. It refuses to score a frame "
    "carrying a drawn annotation overlay, because a marker line supplies exactly "
    "the structure the black/content test reads. It does not prove exact Plex "
    "logo shape, decoder correctness, or RBF identity, and its overlay guard "
    "keys on exactly-saturated primaries in long straight runs, so it does not "
    "claim to detect every derived image."
)


class Unscored(RuntimeError):
    pass


def parse_size(spec: str) -> tuple[int, int]:
    try:
        w_s, h_s = spec.lower().split("x", 1)
        return int(w_s), int(h_s)
    except Exception as exc:
        raise SystemExit(f"invalid --video-size {spec!r}; expected WIDTHxHEIGHT") from exc


def check_device_ready(dev: str) -> None:
    if not Path(dev).exists():
        raise Unscored(f"capture-device-absent:{dev}")
    try:
        r = subprocess.run(["fuser", dev], capture_output=True, text=True, timeout=5)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return
    holders = (r.stdout + r.stderr).strip()
    if r.returncode == 0 and holders:
        raise Unscored(f"capture-device-busy:{dev}:{holders}")


def capture_frame(args: argparse.Namespace) -> tuple[Path, str, int]:
    check_device_ready(args.device)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    vf = f"select=gte(n\\,{args.warmup}),scale=out_range=full,format=rgb24"
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "warning",
        "-f", "v4l2", "-input_format", args.input_format,
        "-video_size", args.video_size, "-framerate", args.framerate,
        "-i", args.device, "-vf", vf, "-frames:v", "1", "-update", "1",
        "-y", str(out),
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30 + args.warmup)
    except FileNotFoundError as exc:
        raise Unscored("ffmpeg-missing") from exc
    log = (r.stderr or r.stdout or "").strip()
    return out, log, r.returncode


def load_frame(path: Path) -> np.ndarray | None:
    try:
        if not path.exists() or path.stat().st_size == 0:
            return None
        return np.array(Image.open(path).convert("RGB"), dtype=np.uint8)
    except Exception:
        return None


def longest_run(mask_1d: np.ndarray) -> int:
    if not mask_1d.any():
        return 0
    idx = np.flatnonzero(np.diff(np.concatenate(([0], mask_1d.view(np.int8), [0]))))
    return int((idx[1::2] - idx[::2]).max())


def detect_drawn_overlay(frame: np.ndarray) -> dict[str, object] | None:
    """Return evidence when the frame carries a drawn annotation marker."""
    h, w, _ = frame.shape
    px = frame.astype(np.int16)
    hi = px.max(axis=2)
    lo = np.sort(px, axis=2)[:, :, 1]  # second-highest channel
    sat = (hi >= OVERLAY_SAT_HI) & (lo <= OVERLAY_SAT_LO)
    if not sat.any():
        return None

    col_need = max(4, int(OVERLAY_RUN_FRACTION * h))
    row_need = max(4, int(OVERLAY_RUN_FRACTION * w))
    col_counts = sat.sum(axis=0)
    row_counts = sat.sum(axis=1)

    for axis, need, counts in (("column", col_need, col_counts), ("row", row_need, row_counts)):
        for i in np.flatnonzero(counts >= need):
            line = sat[:, i] if axis == "column" else sat[i, :]
            run = longest_run(line)
            if run >= need:
                return {
                    "class": "UNSCORED_ANNOTATED",
                    "reason": f"drawn-overlay-{axis}:{int(i)}",
                    "width": w,
                    "height": h,
                    "overlay_run": run,
                    "overlay_run_needed": need,
                    "overlay_pixels": int(sat.sum()),
                }
    return None


def classify(frame: np.ndarray | None, expected_size: tuple[int, int]) -> dict[str, object]:
    if frame is None:
        return {"class": "NO_SIGNAL", "reason": "no-decodable-frame"}
    h, w, _ = frame.shape
    if (w, h) != expected_size:
        return {"class": "NO_SIGNAL", "reason": f"wrong-size:{w}x{h}"}

    lum = frame.astype(np.float32).mean(axis=2)
    mean = float(lum.mean())
    std = float(lum.std())
    p01 = float(np.percentile(lum, 1))
    p99 = float(np.percentile(lum, 99))
    dark_fraction = float((lum < 24.0).mean())
    nonblack_fraction = float((lum > 40.0).mean())

    if std < 3.0 and mean >= 30.0:
        cls = "NO_SIGNAL"
        reason = "flat-nonblack-frame"
    elif (std < 3.0 and mean < 30.0) or (dark_fraction > 0.985 and p99 < 45.0):
        cls = "VALID_BLACK"
        reason = "valid-frame-dark"
    else:
        cls = "VALID_CONTENT"
        reason = "valid-frame-nonblack-structure"
    return {
        "class": cls,
        "reason": reason,
        "width": w,
        "height": h,
        "mean": mean,
        "std": std,
        "p01": p01,
        "p99": p99,
        "dark_fraction": dark_fraction,
        "nonblack_fraction": nonblack_fraction,
    }


def fmt_metric(value: object) -> str:
    if isinstance(value, float):
        return f"{value:.6f}"
    return str(value)


def print_result(result: dict[str, object], *, log: str = "") -> None:
    fields = " ".join(f"{k}={fmt_metric(v)}" for k, v in result.items())
    print(f"HDMI_CAPTURE_RESULT {fields}")
    if log:
        one_line = " ".join(log.split())[:300]
        print(f"HDMI_CAPTURE_LOG {one_line}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", choices=("capture", "file"), default="capture")
    ap.add_argument("--device", default=os.environ.get("HDMI_DEV", DEFAULT_DEV))
    ap.add_argument("--input-format", default=os.environ.get("VISUAL_CAPTURE_FORMAT", DEFAULT_FORMAT))
    ap.add_argument("--video-size", default=os.environ.get("VISUAL_CAPTURE_SIZE", DEFAULT_SIZE))
    ap.add_argument("--framerate", default=os.environ.get("VISUAL_CAPTURE_FPS", DEFAULT_FPS))
    ap.add_argument("--warmup", type=int, default=int(os.environ.get("VISUAL_CAPTURE_WARMUP", "30")))
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    ap.add_argument("--input", help="PNG/JPEG frame for --source=file")
    ap.add_argument("--lock", default=str(DEFAULT_LOCK))
    ap.add_argument("--expect", choices=("any", "content", "black", "no-signal"), default="any")
    ap.add_argument(
        "--allow-annotated",
        action="store_true",
        help="score even if a drawn overlay is detected (unsafe: markers read as content)",
    )
    args = ap.parse_args()

    print(SCOPE, flush=True)
    expected_size = parse_size(args.video_size)
    log = ""

    try:
        if args.source == "file":
            if not args.input:
                raise SystemExit("--source=file requires --input")
            frame = load_frame(Path(args.input))
        else:
            lock_path = Path(args.lock)
            lock_path.parent.mkdir(parents=True, exist_ok=True)
            with lock_path.open("w") as lock_f:
                try:
                    fcntl.flock(lock_f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as exc:
                    raise Unscored(f"capture-lock-busy:{lock_path}") from exc
                path, log, rc = capture_frame(args)
            frame = load_frame(path) if rc == 0 else None
            if rc != 0 and frame is None:
                log = log or f"ffmpeg rc={rc}"
        if frame is not None and not args.allow_annotated:
            overlay = detect_drawn_overlay(frame)
            if overlay is not None:
                print_result(overlay, log=log)
                return RC_UNSEEN
        result = classify(frame, expected_size)
    except Unscored as exc:
        print(f"HDMI_CAPTURE_UNSCORED reason={exc}")
        return RC_UNSCORED

    print_result(result, log=log)
    got = str(result["class"])
    want = {
        "any": None,
        "content": "VALID_CONTENT",
        "black": "VALID_BLACK",
        "no-signal": "NO_SIGNAL",
    }[args.expect]
    if want is not None and got != want:
        print(f"HDMI_CAPTURE_EXPECT_FAIL got={got} want={want}")
        return RC_FAIL
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
