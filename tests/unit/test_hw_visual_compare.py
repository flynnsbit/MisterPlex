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
ROLLBACK_GOLDEN = (
    ROOT / "tests" / "fixtures" / "hw_visual" /
    "plex_real_baseline_320x240_57674f2e_mjpeg720_golden.png"
)
COLOR_ARGS = (
    "--golden-color-matrix", "bt601",
    "--golden-color-range", "full",
    "--capture-color-matrix", "bt601",
    "--capture-color-range", "full",
)
RBF_MD5 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OTHER_RBF_MD5 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
ROLLBACK_RBF_MD5 = "57674f2e4c11551898275e99bd4c3067"
RBF_ARGS = ("--expected-rbf-md5", RBF_MD5, "--actual-rbf-md5", RBF_MD5)
WCAP_CORRUPT_LOG = (
    ROOT / "tests" / "fixtures" / "hw_visual" / "capture_logs" /
    "wcap_fe7673bc_yuyv422_corrupt.log"
)
WCAP_CORRUPT_640_LOG = (
    ROOT / "tests" / "fixtures" / "hw_visual" / "capture_logs" /
    "wcap_fe7673bc_yuyv422_640_corrupt.log"
)

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
    box = hw_visual_compare.parse_compare_box("11,0,160,120", hw_visual_compare.load_geometry())
    require(box == (11, 0, 171, 120), f"compare-box parsing wrong: {box}")
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
        *COLOR_ARGS,
        *RBF_ARGS,
        "--capture", str(cap2),
        "--noise-report", str(noise),
        "--report", str(good_report),
        "--diff", str(good_diff),
    )
    require(c.returncode == 0, f"known-good compare failed\nstdout={c.stdout}\nstderr={c.stderr}")
    gr = json.loads(good_report.read_text())
    require(gr["stats"]["exact_match_pixels"] == gr["stats"]["active_pixels"],
            f"known-good exact count wrong: {gr}")
    require(gr["stats"]["per_plane_exact_match_pixels_rgb"] ==
            [gr["stats"]["active_pixels"]] * 3,
            f"known-good per-plane exact counts wrong: {gr}")
    require(gr["stats"]["per_plane_exact_match_pixels_yuv"] ==
            [gr["stats"]["active_pixels"]] * 3,
            f"known-good YUV per-plane exact counts wrong: {gr}")
    require(good_diff.exists() and good_diff.stat().st_size > 0, "good diff artifact missing")
    require(gr["color_provenance"]["golden"] == {"matrix": "bt601", "range": "full"},
            f"good compare did not record golden colour provenance: {gr}")
    require(gr["color_provenance"]["capture"] == {"matrix": "bt601", "range": "full"},
            f"good compare did not record capture colour provenance: {gr}")
    require(gr["rbf_identity"]["expected_md5"] == RBF_MD5 and gr["rbf_identity"]["match"],
            f"good compare did not record matching RBF provenance: {gr}")
    print("PASS known-good frame exact-matches active display region")

    wrong_core = run(
        "compare",
        "--golden", str(GOLDEN),
        *COLOR_ARGS,
        "--expected-rbf-md5", RBF_MD5,
        "--actual-rbf-md5", OTHER_RBF_MD5,
        "--capture", str(cap2),
        "--noise-report", str(noise),
    )
    require(wrong_core.returncode == 8 and "loaded core md5 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" in wrong_core.stderr,
            "wrong loaded RBF md5 must be refused before an exact pixel match can pass, "
            f"not graded\nstdout={wrong_core.stdout}\nstderr={wrong_core.stderr}")
    undeclared_core = run(
        "compare",
        "--golden", str(GOLDEN),
        *COLOR_ARGS,
        "--actual-rbf-md5", RBF_MD5,
        "--capture", str(cap2),
        "--noise-report", str(noise),
    )
    require(undeclared_core.returncode == 8 and "does not declare a source RBF md5" in undeclared_core.stderr,
            "unbound visual golden plus loaded RBF md5 must be refused unless expected md5 is explicit, "
            f"not graded\nstdout={undeclared_core.stdout}\nstderr={undeclared_core.stderr}")
    rollback_ok = run(
        "compare",
        "--golden", str(ROLLBACK_GOLDEN),
        *COLOR_ARGS,
        "--actual-rbf-md5", ROLLBACK_RBF_MD5,
        "--capture", str(ROLLBACK_GOLDEN),
        "--noise-report", str(noise),
    )
    require(rollback_ok.returncode == 0,
            "rollback visual golden should grade only when loaded RBF md5 matches its sidecar, "
            f"stdout={rollback_ok.stdout}\nstderr={rollback_ok.stderr}")
    rollback_wrong_requested = run(
        "compare",
        "--golden", str(ROLLBACK_GOLDEN),
        *COLOR_ARGS,
        "--expected-rbf-md5", OTHER_RBF_MD5,
        "--actual-rbf-md5", OTHER_RBF_MD5,
        "--capture", str(ROLLBACK_GOLDEN),
        "--noise-report", str(noise),
    )
    require(rollback_wrong_requested.returncode == 8 and "does not match golden source RBF md5" in rollback_wrong_requested.stderr,
            "explicitly requesting a different RBF for the rollback golden must be refused, "
            f"not graded\nstdout={rollback_wrong_requested.stdout}\nstderr={rollback_wrong_requested.stderr}")
    print("PASS wrong or undeclared loaded RBF identity is rejected before pixel grading")

    missing_colour = run(
        "compare",
        "--golden", str(GOLDEN),
        *RBF_ARGS,
        "--capture", str(cap2),
        "--noise-report", str(noise),
    )
    require(missing_colour.returncode == 2 and "colour matrix/range provenance is required" in missing_colour.stderr,
            "compare without colour provenance must be refused, "
            f"not graded\nstdout={missing_colour.stdout}\nstderr={missing_colour.stderr}")
    mismatched_colour = run(
        "compare",
        "--golden", str(GOLDEN),
        "--golden-color-matrix", "bt601",
        "--golden-color-range", "full",
        *RBF_ARGS,
        "--capture", str(cap2),
        "--capture-color-matrix", "bt709",
        "--capture-color-range", "full",
        "--noise-report", str(noise),
    )
    require(mismatched_colour.returncode == 2 and "different colour provenance" in mismatched_colour.stderr,
            "compare with mismatched colour provenance must be refused, "
            f"not graded\nstdout={mismatched_colour.stdout}\nstderr={mismatched_colour.stderr}")
    print("PASS unknown/mismatched colour provenance refused before grading")

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
        *COLOR_ARGS,
        *RBF_ARGS,
        "--capture", str(bad_path),
        "--noise-report", str(noise),
        "--report", str(bad_report),
        "--shift-radius", "1",
        "--diff", str(bad_diff),
    )
    require(b.returncode == 1, f"corrupted frame did not fail\nstdout={b.stdout}\nstderr={b.stderr}")
    br = json.loads(bad_report.read_text())
    require(br["stats"]["worst"]["x_presented"] == 20, f"wrong worst x: {br}")
    require(br["stats"]["worst"]["y_presented"] == 20, f"wrong worst y: {br}")
    require(br["stats"]["mismatch_bbox"]["presented"] == [20, 20, 20, 20],
            f"wrong mismatch bbox: {br}")
    require(br["stats"]["max_abs"] >= 64, f"bad max_abs too small: {br}")
    require(br["stats"]["per_plane_exact_match_pixels_rgb"][1] ==
            br["stats"]["active_pixels"] - 1,
            f"bad per-plane exact count should isolate one green-plane pixel: {br}")
    require(br["stats"]["per_plane_mae_yuv"][0] > 0,
            f"bad YUV per-plane MAE did not report the injected pixel: {br}")
    require(br["shift_sweep"][0]["captured_dx"] == 0 and br["shift_sweep"][0]["captured_dy"] == 0,
            f"shift sweep should prefer no shift for single-pixel corruption: {br['shift_sweep'][:3]}")
    require(bad_diff.exists() and bad_diff.stat().st_size > 0, "bad diff artifact missing")
    print("PASS corrupted active pixel rejected with precise worst mismatch + diff artifact")

    stale = run(
        "compare",
        "--golden", str(GOLDEN),
        *COLOR_ARGS,
        *RBF_ARGS,
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
    require(WCAP_CORRUPT_LOG.exists(), "W-CAP corrupt capture log fixture missing")
    wcap_log = WCAP_CORRUPT_LOG.read_text()
    wcap_640_log = WCAP_CORRUPT_640_LOG.read_text()
    require("1843200 bytes" in wcap_log and "yuyv422, 1280x720" in wcap_log,
            "W-CAP 1280x720 fixture lost exact corrupt-buffer details")
    require("614400 bytes" in wcap_640_log,
            "W-CAP 640x480 fixture lost exact corrupt-buffer details")
    require(hw_visual_compare.classify_capture_log(wcap_log) == "corrupt",
            "W-CAP fe7673bc corrupt capture log fixture was not classified as corrupt")
    require(hw_visual_compare.classify_capture_log(wcap_640_log) == "corrupt",
            "W-CAP fe7673bc 640x480 corrupt capture log fixture was not classified as corrupt")
    corrupt_logged = run(
        "compare",
        "--golden", str(GOLDEN),
        *COLOR_ARGS,
        *RBF_ARGS,
        "--capture", str(cap2),
        "--capture-log", str(WCAP_CORRUPT_LOG),
        "--noise-report", str(noise),
    )
    require(corrupt_logged.returncode == 4,
            "compare with W-CAP corrupt capture log must return capture-integrity rc=4, "
            f"not grade pixels\nstdout={corrupt_logged.stdout}\nstderr={corrupt_logged.stderr}")
    print("PASS V4L2 corrupt-buffer diagnostics classified distinctly")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
