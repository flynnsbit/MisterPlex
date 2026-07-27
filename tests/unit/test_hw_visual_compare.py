#!/usr/bin/env python3
"""Unit coverage for the hardware visual decode comparator."""
from __future__ import annotations

import json
import importlib.util
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "scripts" / "hw_visual_compare.py"
WORK = ROOT / "build" / "hw-visual-unit"
GOLDEN = ROOT / "tests" / "fixtures" / "hw_visual" / "plex_visual_640x480_golden.png"

spec = importlib.util.spec_from_file_location("hw_visual_compare", TOOL)
hw_visual_compare = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = hw_visual_compare
spec.loader.exec_module(hw_visual_compare)


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(TOOL), *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=60,
    )


def require(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


def write_png(path: Path, pixels: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(pixels.astype(np.uint8), "RGB").save(path)


def main() -> int:
    WORK.mkdir(parents=True, exist_ok=True)

    g = run("geometry")
    require(g.returncode == 0, f"geometry failed\nstdout={g.stdout}\nstderr={g.stderr}")
    geom = json.loads(g.stdout)
    require(geom["coded_width"] == 624, f"coded width wrong: {geom}")
    require(geom["display_width"] == 618, f"display width wrong: {geom}")
    require(geom["presented_width"] == 640, f"presented width wrong: {geom}")
    require(geom["pillarbox_left"] == 11, f"pillarbox wrong: {geom}")
    print("PASS shared host/RTL geometry parsed")

    golden = np.array(Image.open(GOLDEN).convert("RGB"), dtype=np.uint8)
    cap1 = WORK / "cap1.png"
    cap2 = WORK / "cap2.png"
    write_png(cap1, golden)
    write_png(cap2, golden)

    noise = WORK / "noise.json"
    n = run("noise", "--frames", str(cap1), str(cap2), "--out", str(noise))
    require(n.returncode == 0, f"noise failed\nstdout={n.stdout}\nstderr={n.stderr}")
    nr = json.loads(noise.read_text())
    require(nr["max_abs_noise"] == 0, f"expected zero synthetic HDMI noise: {nr}")
    print("PASS zero-noise floor measured from identical static frames")

    good_report = WORK / "good.json"
    good_diff = WORK / "good_diff.png"
    c = run(
        "compare",
        "--golden", str(GOLDEN),
        "--capture", str(cap2),
        "--noise-report", str(noise),
        "--report", str(good_report),
        "--diff", str(good_diff),
    )
    require(c.returncode == 0, f"known-good compare failed\nstdout={c.stdout}\nstderr={c.stderr}")
    gr = json.loads(good_report.read_text())
    require(gr["stats"]["exact_match_pixels"] == gr["stats"]["active_pixels"],
            f"known-good exact count wrong: {gr}")
    require(good_diff.exists() and good_diff.stat().st_size > 0, "good diff artifact missing")
    print("PASS known-good frame exact-matches active display region")

    bad = golden.copy()
    # Corrupt one active pixel, not a pillarbox pixel; this is the red-path proof
    # that the comparator reports a precise location and emits a useful diff.
    bad[20, 20, 1] = (int(bad[20, 20, 1]) + 64) & 0xFF
    bad_path = WORK / "bad.png"
    write_png(bad_path, bad)
    bad_report = WORK / "bad.json"
    bad_diff = WORK / "bad_diff.png"
    b = run(
        "compare",
        "--golden", str(GOLDEN),
        "--capture", str(bad_path),
        "--noise-report", str(noise),
        "--report", str(bad_report),
        "--diff", str(bad_diff),
    )
    require(b.returncode == 1, f"corrupted frame did not fail\nstdout={b.stdout}\nstderr={b.stderr}")
    br = json.loads(bad_report.read_text())
    require(br["stats"]["worst"]["x_presented"] == 20, f"wrong worst x: {br}")
    require(br["stats"]["worst"]["y_presented"] == 20, f"wrong worst y: {br}")
    require(br["stats"]["max_abs"] >= 64, f"bad max_abs too small: {br}")
    require(bad_diff.exists() and bad_diff.stat().st_size > 0, "bad diff artifact missing")
    print("PASS corrupted active pixel rejected with precise worst mismatch + diff artifact")

    stale = run(
        "compare",
        "--golden", str(GOLDEN),
        "--previous", str(cap1),
        "--capture", str(cap1),
        "--noise-report", str(noise),
    )
    require(stale.returncode == 3 and "STALE capture" in stale.stderr,
            f"stale capture was not rejected\nstdout={stale.stdout}\nstderr={stale.stderr}")
    print("PASS stale previous-condition capture rejected")

    v4l2_log = "[video4linux2,v4l2 @ 0x123] Dequeued v4l2 buffer contains corrupted data (0 bytes)."
    require(hw_visual_compare.classify_capture_log(v4l2_log) == "corrupt",
            "actual V4L2 corrupt-buffer wording was not classified as corrupt")
    mjpeg_log = "Error submitting packet to decoder: Invalid data found when processing input"
    require(hw_visual_compare.classify_capture_log(mjpeg_log) == "corrupt",
            "MJPEG decoder invalid-data wording was not classified as corrupt")
    print("PASS V4L2 corrupt-buffer diagnostic classified distinctly")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
