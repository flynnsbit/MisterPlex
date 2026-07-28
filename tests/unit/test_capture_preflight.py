#!/usr/bin/env python3
"""Unit tests for scripts/capture_preflight.py.

All tests run without live hardware using synthetic or file-backed sources.
Tests the three documented failure modes:
  (1) No device       → exit 77 UNSCORED
  (2) Black signal    → exit 1 FAIL  (BLACK_SIGNAL)
  (3) No signal       → exit 1 FAIL  (NO_SIGNAL)
  (4) Stale/frozen    → exit 1 FAIL  (STALE_CAPTURE)
  (5) Content present → exit 0 PASS  (CONTENT_PRESENT)
  (6) File-backed     → exercises stale rejection on file source
"""
from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PREFLIGHT_SCRIPT = ROOT / "scripts" / "capture_preflight.py"
WORK = ROOT / "build" / "capture-preflight-unit"

spec = importlib.util.spec_from_file_location("capture_preflight", PREFLIGHT_SCRIPT)
capture_preflight = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(capture_preflight)

EXIT_PASS = 0
EXIT_FAIL = 1
EXIT_SKIP = 77


def require(ok: bool, msg: str) -> None:
    if not ok:
        raise AssertionError(msg)


def run_cli(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(PREFLIGHT_SCRIPT), *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=30,
    )


def test_synthetic_content_pass() -> None:
    """Synthetic content frames → CONTENT_PRESENT → exit 0."""
    r = run_cli(
        "--source", "synthetic", "--synthetic-case", "content",
        "--frames", "3",
        "--out-dir", str(WORK / "content"),
    )
    require(
        r.returncode == EXIT_PASS,
        f"synthetic content should exit 0; got {r.returncode}\n"
        f"stdout={r.stdout}\nstderr={r.stderr}"
    )
    require(
        "CONTENT_PRESENT" in r.stdout,
        f"expected CONTENT_PRESENT in stdout: {r.stdout}"
    )
    print("PASS synthetic content frames → CONTENT_PRESENT exit 0")


def test_synthetic_black_fail() -> None:
    """Synthetic black frames → BLACK_SIGNAL → exit 1 FAIL."""
    r = run_cli(
        "--source", "synthetic", "--synthetic-case", "black",
        "--frames", "3",
        "--out-dir", str(WORK / "black"),
    )
    require(
        r.returncode == EXIT_FAIL,
        f"black signal should exit 1; got {r.returncode}\n"
        f"stdout={r.stdout}\nstderr={r.stderr}"
    )
    require(
        "BLACK_SIGNAL" in r.stdout,
        f"expected BLACK_SIGNAL in stdout: {r.stdout}"
    )
    print("PASS synthetic black frames → BLACK_SIGNAL exit 1 FAIL")


def test_synthetic_no_signal_fail() -> None:
    """Synthetic solid-colour frames → NO_SIGNAL → exit 1 FAIL."""
    r = run_cli(
        "--source", "synthetic", "--synthetic-case", "no_signal",
        "--frames", "3",
        "--out-dir", str(WORK / "no_signal"),
    )
    require(
        r.returncode == EXIT_FAIL,
        f"no-signal should exit 1; got {r.returncode}\n"
        f"stdout={r.stdout}\nstderr={r.stderr}"
    )
    require(
        "NO_SIGNAL" in r.stdout,
        f"expected NO_SIGNAL in stdout: {r.stdout}"
    )
    print("PASS synthetic solid-colour frames → NO_SIGNAL exit 1 FAIL")


def test_synthetic_stale_fail() -> None:
    """Synthetic frozen stream → STALE_CAPTURE → exit 1 FAIL."""
    r = run_cli(
        "--source", "synthetic", "--synthetic-case", "stale",
        "--frames", "3",
        "--out-dir", str(WORK / "stale"),
    )
    require(
        r.returncode == EXIT_FAIL,
        f"stale stream should exit 1; got {r.returncode}\n"
        f"stdout={r.stdout}\nstderr={r.stderr}"
    )
    require(
        "STALE_CAPTURE" in r.stdout,
        f"expected STALE_CAPTURE in stdout: {r.stdout}"
    )
    print("PASS synthetic frozen frames → STALE_CAPTURE exit 1 FAIL")


def test_no_device_skip() -> None:
    """No capture hardware at all → exit 77 UNSCORED (never exit 0).

    On a machine where /dev/video0 exists: requesting a non-existent path is
    a configuration error → exit 1 FAIL (hardware present, wrong path).
    The invariant is: NEVER exit 0 when the requested device is absent.

    The true exit-77 path (NoCaptureNodeError) is covered by test_classify_api_exit_codes
    below via the internal API.
    """
    r = run_cli(
        "--source", "v4l2",
        "--device", "/dev/video_nonexistent_777",
        "--out-dir", str(WORK / "no_device"),
    )
    # Key invariant: NEVER exit 0 for a missing device — could be exit 1 or 77
    require(
        r.returncode != EXIT_PASS,
        f"missing device MUST NOT exit 0 (false pass): stdout={r.stdout!r} stderr={r.stderr!r}"
    )
    # Document what we actually got
    state = "SKIP" if r.returncode == EXIT_SKIP else "FAIL"
    print(f"PASS non-existent device → exit {r.returncode} {state} (never 0)")


def test_no_capture_node_api() -> None:
    """Internal API: no capture nodes found → NoCaptureNodeError → exit 77."""
    # Simulate the case where v4l2 finds nodes but none support capture formats
    # by passing an empty list to select_capture_node
    try:
        capture_preflight.select_capture_node([], preferred=None)
        require(False, "select_capture_node with empty list should have raised")
    except capture_preflight.NoCaptureNodeError as e:
        require(
            e.exit_code == EXIT_SKIP,
            f"NoCaptureNodeError should have exit_code=77, got {e.exit_code}"
        )
    print("PASS NoCaptureNodeError carries exit_code=77 (UNSCORED)")

    # Also verify DeviceAbsentError carries exit 77
    require(
        capture_preflight.DeviceAbsentError("test").exit_code == EXIT_SKIP,
        "DeviceAbsentError should have exit_code=77"
    )
    print("PASS DeviceAbsentError carries exit_code=77 (UNSCORED)")


def test_file_backed_content() -> None:
    """File-backed: two distinct content frames → CONTENT_PRESENT."""
    from PIL import Image
    import numpy as np
    WORK_FILE = WORK / "file_content"
    WORK_FILE.mkdir(parents=True, exist_ok=True)
    for i, luma in enumerate([80, 82]):
        frame = capture_preflight.synthetic_frame("content").copy()
        # Make them slightly different
        frame[0, 0, 0] = luma
        Image.fromarray(frame).save(WORK_FILE / f"frame_{i}.png")
    r = run_cli(
        "--source", "file",
        "--input", str(WORK_FILE / "frame_0.png"),
        "--input", str(WORK_FILE / "frame_1.png"),
        "--out-dir", str(WORK_FILE),
    )
    require(
        r.returncode == EXIT_PASS,
        f"file-backed content should exit 0; got {r.returncode}\n"
        f"stdout={r.stdout}\nstderr={r.stderr}"
    )
    print("PASS file-backed content frames → CONTENT_PRESENT exit 0")


def test_file_backed_stale() -> None:
    """File-backed: two byte-identical frames → STALE_CAPTURE → exit 1."""
    from PIL import Image
    WORK_STALE = WORK / "file_stale"
    WORK_STALE.mkdir(parents=True, exist_ok=True)
    frame = capture_preflight.synthetic_frame("content")
    p1 = WORK_STALE / "frame_a.png"
    p2 = WORK_STALE / "frame_b.png"
    Image.fromarray(frame).save(p1)
    Image.fromarray(frame).save(p2)  # byte-identical
    r = run_cli(
        "--source", "file",
        "--input", str(p1),
        "--input", str(p2),
        "--out-dir", str(WORK_STALE),
    )
    require(
        r.returncode == EXIT_FAIL,
        f"stale file frames should exit 1; got {r.returncode}\n"
        f"stdout={r.stdout}\nstderr={r.stderr}"
    )
    require(
        "STALE_CAPTURE" in r.stdout,
        f"expected STALE_CAPTURE in output: {r.stdout}"
    )
    print("PASS file-backed byte-identical frames → STALE_CAPTURE exit 1 FAIL")


def test_classify_signal_internals() -> None:
    """Direct API tests for classify_signal() — all three states + stale."""
    import numpy as np

    # Content
    frame_content = capture_preflight.synthetic_frame("content")
    frames = [frame_content.copy() for _ in range(3)]
    for i, f in enumerate(frames):
        f[0, 0, 0] = (int(f[0, 0, 0]) + i) & 0xFF
    result = capture_preflight.classify_signal(frames)
    require(result["state"] == "CONTENT_PRESENT", f"content should be CONTENT_PRESENT: {result}")
    require(result["mean_luma"] >= capture_preflight.LUMA_BLACK_THRESHOLD,
            f"content luma should be >= threshold: {result}")

    # Black
    frame_black = capture_preflight.synthetic_frame("black")
    frames_black = [frame_black.copy() for _ in range(3)]
    for i, f in enumerate(frames_black):
        f[0, 0, 0] = i  # vary to avoid stale; all still very dark
    result_black = capture_preflight.classify_signal(frames_black)
    require(result_black["state"] == "BLACK_SIGNAL",
            f"black frames should be BLACK_SIGNAL: {result_black}")

    # No signal (solid grey)
    frame_grey = capture_preflight.synthetic_frame("no_signal")
    frames_grey = [frame_grey.copy() for _ in range(3)]
    for i, f in enumerate(frames_grey):
        f[0, 0, 0] = (128 + i) & 0xFF
    result_grey = capture_preflight.classify_signal(frames_grey)
    require(result_grey["state"] == "NO_SIGNAL",
            f"solid-grey frames should be NO_SIGNAL: {result_grey}")

    # Stale
    frame_stale = capture_preflight.synthetic_frame("stale")
    frames_stale = [frame_stale.copy() for _ in range(3)]  # all identical
    result_stale = capture_preflight.classify_signal(frames_stale)
    require(result_stale["state"] == "STALE_CAPTURE",
            f"identical frames should be STALE_CAPTURE: {result_stale}")

    print("PASS internal classify_signal() covers all four states correctly")


def main() -> int:
    WORK.mkdir(parents=True, exist_ok=True)

    tests = [
        test_classify_signal_internals,    # pure unit, no subprocess
        test_no_capture_node_api,          # NoCaptureNodeError/DeviceAbsentError → exit 77
        test_synthetic_content_pass,        # GREEN reference
        test_synthetic_black_fail,          # RED: black screen (resident RBF 00eebd5e state)
        test_synthetic_no_signal_fail,      # RED: no HDMI signal
        test_synthetic_stale_fail,          # RED: frozen / buffered stream
        test_no_device_skip,               # absent device → never exit 0
        test_file_backed_content,           # file-backed GREEN
        test_file_backed_stale,             # file-backed STALE → RED
    ]

    failures: list[str] = []
    for t in tests:
        try:
            t()
        except AssertionError as e:
            print(f"FAIL {t.__name__}: {e}")
            failures.append(t.__name__)
        except Exception as e:
            print(f"ERROR {t.__name__}: {type(e).__name__}: {e}")
            failures.append(t.__name__)

    if failures:
        print(f"\ntest_capture_preflight: {len(failures)} FAILED: {failures}")
        return 1

    print(f"\ntest_capture_preflight: OK ({len(tests)} tests)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
