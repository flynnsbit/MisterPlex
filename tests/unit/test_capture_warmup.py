#!/usr/bin/env python3
"""Unit coverage for MS2109 capture-warmup discard in capture_preflight.

Measured on the lab rig (534d:2109 -> /dev/video0, MJPG 1280x720@60):
``grab_frame`` opens ffmpeg once per frame, and each open emits a leading run
of flat RGB(7,7,7) frames (spatial std 0.0) until the HDMI receiver locks.
A 60-frame burst showed 10 leading flat frames; a 20-frame burst showed 11.

With the previous default of 3 scored frames and no warmup discard, 2 of 6
identical live runs classified a screen with real picture content as
BLACK_SIGNAL -- a 33% false-negative rate on the fleet's primary capture
instrument.

These tests are deterministic (grab_frame is stubbed) and assert both
directions:
  * the leading flat run is discarded so real content is scored (green), and
  * a genuinely black source is STILL reported BLACK_SIGNAL (red) -- the
    discard can never manufacture a pass.
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
PREFLIGHT = ROOT / "scripts" / "capture_preflight.py"
WORK = ROOT / "build" / "capture-warmup-unit"

spec = importlib.util.spec_from_file_location("capture_preflight", PREFLIGHT)
cp = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(cp)

H, W = 64, 64
# Measured flat warmup frame value from the real rig.
FLAT = np.full((H, W, 3), 7, dtype=np.uint8)
# A GENUINELY black screen from the core, distinct from the filler above.
# RGB(7,7,7) cannot serve as a black-screen fixture: it is exactly what the
# capture device paints when it has no lock, so it is graded NO_SIGNAL.
BLACK = np.full((H, W, 3), 2, dtype=np.uint8)


def require(ok: bool, msg: str) -> None:
    if not ok:
        raise AssertionError(msg)


def content_frame(seed: int) -> np.ndarray:
    """Distinct, non-flat, non-black frame (spatial std well above threshold)."""
    rng = np.random.default_rng(seed)
    base = np.linspace(0, 255, W, dtype=np.float64)
    frame = np.tile(base, (H, 1))
    frame = frame + rng.integers(0, 8, size=(H, W))
    frame = np.clip(frame, 0, 255).astype(np.uint8)
    return np.stack([frame, frame, frame], axis=-1)


def install_stub(sequence: list[np.ndarray]) -> list[int]:
    """Replace grab_frame with one returning `sequence` (last value repeats)."""
    calls: list[int] = []

    def fake_grab_frame(dev, fmt, size, fps, out):  # noqa: ANN001
        idx = len(calls)
        calls.append(idx)
        frame = sequence[idx] if idx < len(sequence) else sequence[-1]
        return frame, "stub-log", {"codec": "mjpeg", "size": "1280x720", "fps": "60"}

    cp.grab_frame = fake_grab_frame
    return calls


def run_grab(sequence: list[np.ndarray], n: int, warmup: int):
    install_stub(sequence)
    return cp.grab_n_frames("/dev/stub", "mjpeg", "1280x720", "60", n, WORK,
                            warmup_discard=warmup)


def main() -> int:
    WORK.mkdir(parents=True, exist_ok=True)

    # --- GREEN: leading warmup run is discarded, real content is scored ------
    seq = [FLAT] * 11 + [content_frame(i) for i in range(20)]
    frames, _log, _neg, discarded = run_grab(seq, n=8, warmup=12)
    require(discarded == 11, f"expected 11 warmup frames discarded, got {discarded}")
    require(len(frames) == 8, f"expected 8 scored frames, got {len(frames)}")
    require(all(f.std() > cp.SPATIAL_CONTENT_THRESHOLD for f in frames),
            "a flat warmup frame leaked into the scored set")
    cls = cp.classify_signal(frames)
    require(cls["state"] == "CONTENT_PRESENT",
            f"content after 11 warmup frames misclassified: {cls['state']} ({cls['note']})")
    print("PASS 11 leading warmup frames discarded; real content scored CONTENT_PRESENT")

    # --- RED: a genuinely black source is still BLACK_SIGNAL ----------------
    # This is the safety property: the discard must never manufacture a pass.
    frames, _log, _neg, discarded = run_grab([BLACK], n=8, warmup=12)
    require(len(frames) == 8, f"black source must still yield 8 scored frames, got {len(frames)}")
    require(all(f.std() == 0 for f in frames), "black source produced non-flat scored frames")
    cls = cp.classify_signal(frames)
    require(cls["state"] == "BLACK_SIGNAL",
            f"genuinely black screen was masked by warmup discard: {cls['state']}")
    require(cp._signal_exit_code(cls) == cp.EXIT_FAIL,
            "black screen did not map to a FAIL exit code")
    print("PASS genuinely black source still BLACK_SIGNAL (warmup discard cannot mask it)")

    # --- RED: reproduces the historical false negative (warmup=0) -----------
    seq = [FLAT] * 11 + [content_frame(i) for i in range(20)]
    frames, _log, _neg, discarded = run_grab(seq, n=3, warmup=0)
    require(discarded == 0, "warmup=0 must not discard anything")
    cls = cp.classify_signal(frames)
    # The historical bug is that warmup=0 grades the capture device's filler
    # frames as a real screen state instead of content.  That still reproduces.
    # The STATE NAME improved: it used to be BLACK_SIGNAL, which wrongly blamed
    # the core for painting black; filler is now correctly NO_SIGNAL (no lock).
    require(cls["state"] == "NO_SIGNAL",
            f"regression guard broken: old behaviour no longer reproduces the "
            f"false negative (got {cls['state']})")
    require(cls["state"] != "CONTENT_PRESENT",
            "warmup=0 must not manufacture a content pass from filler frames")
    print("PASS historical false negative reproduced at warmup-discard=0 (documents the bug)")

    # --- RED: only a LEADING flat run is discarded --------------------------
    # Flat frames that appear after content are real signal loss and must be kept.
    seq = [content_frame(1)] + [FLAT] * 20
    frames, _log, _neg, discarded = run_grab(seq, n=6, warmup=12)
    require(discarded == 0,
            f"flat frames after content must not be discarded, dropped {discarded}")
    require(len(frames) == 6, f"expected 6 scored frames, got {len(frames)}")
    require(any(f.std() == 0 for f in frames),
            "mid-stream flat frames were wrongly dropped from the scored set")
    print("PASS mid-stream flat frames retained (only a leading run is discarded)")

    # --- Bound: never grabs more than n + warmup_discard frames -------------
    calls = install_stub([FLAT])
    cp.grab_n_frames("/dev/stub", "mjpeg", "1280x720", "60", 8, WORK, warmup_discard=12)
    require(len(calls) == 20, f"grab bound violated: {len(calls)} grabs, expected 8+12=20")
    print("PASS grab count bounded at frames + warmup_discard")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
