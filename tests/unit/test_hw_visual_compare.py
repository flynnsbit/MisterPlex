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
COLOR_ARGS = (
    "--golden-color-matrix", "bt601",
    "--golden-color-range", "full",
    "--capture-color-matrix", "bt601",
    "--capture-color-range", "full",
)
WCAP_CORRUPT_LOG = (
    ROOT / "tests" / "fixtures" / "hw_visual" / "capture_logs" /
    "wcap_fe7673bc_yuyv422_corrupt.log"
)
WCAP_CORRUPT_640_LOG = (
    ROOT / "tests" / "fixtures" / "hw_visual" / "capture_logs" /
    "wcap_fe7673bc_yuyv422_640_corrupt.log"
)
RELOAD_STALE_CAPTURE = (
    ROOT / "tests" / "fixtures" / "hw_visual" / "reload_determinism" /
    "plex_bytes_in4_stale_screen.png"
)
RELOAD_STALE_STATUS = (
    ROOT / "tests" / "fixtures" / "hw_visual" / "reload_determinism" /
    "plex_bytes_in4_status.txt"
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
    print("PASS known-good frame exact-matches active display region")

    missing_colour = run(
        "compare",
        "--golden", str(GOLDEN),
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
        "--previous", str(cap1),
        "--capture", str(cap1),
        "--noise-report", str(noise),
    )
    require(stale.returncode == 3 and "STALE capture" in stale.stderr,
            f"stale capture was not rejected\nstdout={stale.stdout}\nstderr={stale.stderr}")
    print("PASS stale previous-condition capture rejected")

    require(RELOAD_STALE_CAPTURE.exists(), "natural bytes_in=4 stale capture fixture missing")
    require(RELOAD_STALE_STATUS.exists(), "natural bytes_in=4 status fixture missing")
    stale_delivery = run(
        "compare",
        "--golden", str(RELOAD_STALE_CAPTURE),
        *COLOR_ARGS,
        "--capture", str(RELOAD_STALE_CAPTURE),
        "--noise-report", str(noise),
        "--status-log", str(RELOAD_STALE_STATUS),
        "--min-bytes-in", "512",
        "--require-status-field", "has_frame=1",
        "--require-status-field", "has_stream=1",
        "--require-status-field", "has_idr=1",
    )
    require(stale_delivery.returncode == 7 and
            "STATUS_TELEMETRY_LAYER: bytes_in=4 equals nalu=4" in stale_delivery.stderr,
            "bytes_in=4/nalu=4 stale-screen status must be refused as status-telemetry aliasing "
            "before an exact pixel match can pass, not graded\n"
            f"stdout={stale_delivery.stdout}\nstderr={stale_delivery.stderr}")
    print("PASS natural bytes_in=4/nalu=4 stale-screen fixture is rejected as telemetry-layer aliasing")

    fresh_status_before = WORK / "status_before_token.txt"
    fresh_status_after = WORK / "status_after_token.txt"
    fresh_status_before.write_text(
        "status has_frame=1 has_stream=1 has_idr=1 sps_valid=1 pps_valid=1 "
        "frame_bank=0 frame_format=yuv420p frame_seq=41 bytes_in=4096\n",
        encoding="utf-8",
    )
    fresh_status_after.write_text(
        "status has_frame=1 has_stream=1 has_idr=1 sps_valid=1 pps_valid=1 "
        "frame_bank=1 frame_format=yuv420p frame_seq=42 bytes_in=6227\n",
        encoding="utf-8",
    )
    fresh_report = WORK / "fresh_delivery.json"
    fresh_delivery = run(
        "compare",
        "--golden", str(GOLDEN),
        *COLOR_ARGS,
        "--expected-rbf-md5", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "--actual-rbf-md5", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  /media/fat/_Utility/Plex.rbf",
        "--capture", str(cap2),
        "--noise-report", str(noise),
        "--status-log", str(fresh_status_after),
        "--previous-status-log", str(fresh_status_before),
        "--min-bytes-in", "512",
        "--require-status-field", "has_frame=1",
        "--require-status-field", "has_stream=1",
        "--require-status-field", "has_idr=1",
        "--require-token-change",
        "--report", str(fresh_report),
    )
    require(fresh_delivery.returncode == 0,
            f"fresh delivery status with changed token did not allow exact compare\n"
            f"stdout={fresh_delivery.stdout}\nstderr={fresh_delivery.stderr}")
    fr = json.loads(fresh_report.read_text())
    require(fr["delivery_freshness"]["token_changed"] is True,
            f"fresh token change not reported: {fr['delivery_freshness']}")
    require(fr["rbf_identity"]["match"] is True,
            f"matching RBF identity not reported: {fr['rbf_identity']}")
    print("PASS fresh delivery counters, matching RBF md5, and shared {bank,format,seq} token allow grading")

    unchanged_token = run(
        "compare",
        "--golden", str(GOLDEN),
        *COLOR_ARGS,
        "--capture", str(cap2),
        "--noise-report", str(noise),
        "--status-log", str(fresh_status_before),
        "--previous-status-log", str(fresh_status_before),
        "--min-bytes-in", "512",
        "--require-status-field", "has_frame=1",
        "--require-status-field", "has_stream=1",
        "--require-status-field", "has_idr=1",
        "--require-token-change",
    )
    require(unchanged_token.returncode == 7 and "frame token did not change" in unchanged_token.stderr,
            "unchanged DDR frame token must be refused when token freshness is required, "
            f"not graded\nstdout={unchanged_token.stdout}\nstderr={unchanged_token.stderr}")
    print("PASS unchanged shared frame token is rejected before pixel grading")

    wrong_core = run(
        "compare",
        "--golden", str(GOLDEN),
        *COLOR_ARGS,
        "--expected-rbf-md5", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "--actual-rbf-md5", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  /media/fat/_Utility/Plex.rbf",
        "--capture", str(cap2),
        "--noise-report", str(noise),
        "--status-log", str(fresh_status_after),
        "--min-bytes-in", "512",
    )
    require(wrong_core.returncode == 8 and "loaded core md5 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" in wrong_core.stderr,
            "wrong loaded RBF md5 must be refused before an exact pixel match can pass, "
            f"not graded\nstdout={wrong_core.stdout}\nstderr={wrong_core.stderr}")
    undeclared_core = run(
        "compare",
        "--golden", str(GOLDEN),
        *COLOR_ARGS,
        "--actual-rbf-md5", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  /media/fat/_Utility/Plex.rbf",
        "--capture", str(cap2),
        "--noise-report", str(noise),
    )
    require(undeclared_core.returncode == 8 and "expected RBF md5 was not declared" in undeclared_core.stderr,
            "loaded RBF md5 without declared expected artifact must be refused, "
            f"not graded\nstdout={undeclared_core.stdout}\nstderr={undeclared_core.stderr}")
    print("PASS wrong or undeclared loaded RBF identity is rejected before pixel grading")

    non_yuv_status = WORK / "status_non_yuv_debug.txt"
    non_yuv_status.write_text(
        "status has_frame=1 has_stream=1 has_idr=1 sps_valid=1 pps_valid=1 "
        "frame_bank=1 frame_format=yuv420p frame_seq=43 frame_debug=0xe1 bytes_in=6227\n",
        encoding="utf-8",
    )
    non_yuv = run(
        "compare",
        "--golden", str(GOLDEN),
        *COLOR_ARGS,
        "--capture", str(cap2),
        "--noise-report", str(noise),
        "--status-log", str(non_yuv_status),
        "--min-bytes-in", "512",
    )
    require(non_yuv.returncode == 7 and "non-YUV DDR doorbell/debug format error" in non_yuv.stderr,
            "frame_debug=0xe1 must be surfaced as a named non-YUV doorbell freshness failure, "
            f"not graded\nstdout={non_yuv.stdout}\nstderr={non_yuv.stderr}")
    print("PASS frame-store 0xe1 non-YUV doorbell debug is surfaced as a named refusal")

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
