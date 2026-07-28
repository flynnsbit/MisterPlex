#!/usr/bin/env python3
"""Unit coverage for the G-VID1 edge-capture grading harness."""
from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CHECK_EDGES = ROOT / "scripts" / "check_edges.py"
HW_VISUAL_COMPARE = ROOT / "scripts" / "hw_visual_compare.py"
VALIDATE_PLAYBACK = ROOT / "scripts" / "validate_playback_controls_hw.sh"
BANK_RELEASE_VISUAL = ROOT / "tests" / "hw" / "test_bank_release_visual.sh"
WORK = ROOT / "build" / "capture-rig-unit"

spec = importlib.util.spec_from_file_location("check_edges", CHECK_EDGES)
check_edges = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = check_edges
spec.loader.exec_module(check_edges)

visual_spec = importlib.util.spec_from_file_location("hw_visual_compare", HW_VISUAL_COMPARE)
hw_visual_compare = importlib.util.module_from_spec(visual_spec)
assert visual_spec.loader is not None
sys.modules[visual_spec.name] = hw_visual_compare
visual_spec.loader.exec_module(hw_visual_compare)


def require(ok: bool, msg: str) -> None:
    if not ok:
        raise AssertionError(msg)


def grade(kind: str) -> list[str]:
    frame = check_edges.synthetic_frame(kind)
    _lines, problems = check_edges.grade_frame(frame.astype(int))
    return problems


def run_cli(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(CHECK_EDGES), *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=30,
    )


def main() -> int:
    WORK.mkdir(parents=True, exist_ok=True)

    require(check_edges.DEFAULT_DEV == "/dev/video0",
            f"edge capture default must be /dev/video0, got {check_edges.DEFAULT_DEV}")
    require(check_edges.DEFAULT_FORMAT == "mjpeg",
            f"edge capture default must be MJPEG, got {check_edges.DEFAULT_FORMAT}")
    require(check_edges.DEFAULT_SIZE == "1280x720",
            f"edge capture size must be 1280x720, got {check_edges.DEFAULT_SIZE}")
    require(hw_visual_compare.DEFAULT_DEV == "/dev/video0",
            f"visual compare default must be /dev/video0, got {hw_visual_compare.DEFAULT_DEV}")
    require(hw_visual_compare.DEFAULT_FORMAT == "mjpeg",
            f"visual compare default must be MJPEG, got {hw_visual_compare.DEFAULT_FORMAT}")
    require(hw_visual_compare.DEFAULT_SIZE == "1280x720",
            f"visual compare size must be 1280x720, got {hw_visual_compare.DEFAULT_SIZE}")
    require(hw_visual_compare.DEFAULT_FPS == "60",
            f"visual compare fps must be 60, got {hw_visual_compare.DEFAULT_FPS}")
    text = VALIDATE_PLAYBACK.read_text(encoding="utf-8")
    require("read -r ans" not in text and "[assumed yes]" not in text,
            "playback controls hardware validation must not accept human confirmation")
    bank_text = BANK_RELEASE_VISUAL.read_text(encoding="utf-8")
    require("HUMAN_RESULT=PASS" not in bank_text and "PLEASE ANSWER" not in bank_text,
            "bank-release visual gate must not be scoreable by human questionnaire")
    print("PASS capture harness defaults to /dev/video0 MJPEG 1280x720@60 with no human confirmation")

    problems = grade("good")
    require(not problems, f"known-good aligned frame failed: {problems}")
    print("PASS synthetic known-good aligned frame")

    problems = grade("hwrap")
    require(any(p.startswith("H WRAP") or p.startswith("H leading edge") for p in problems),
            f"horizontal wrap did not identify H edge: {problems}")
    require(not any(p.startswith("V ") for p in problems),
            f"horizontal wrap should not blame vertical edge: {problems}")
    print("PASS synthetic 1-source-pixel horizontal wrap rejected on H edge")

    problems = grade("vshift")
    require(any(p.startswith("V leading edge") for p in problems),
            f"vertical shift did not identify V leading edge: {problems}")
    print("PASS synthetic 1-source-pixel vertical shift rejected")

    baseline = WORK / "baseline.png"
    good = WORK / "good.png"
    stale = WORK / "stale.png"
    check_edges.save_image(baseline, check_edges.synthetic_frame("baseline"))
    check_edges.save_image(good, check_edges.synthetic_frame("good"))
    check_edges.save_image(stale, check_edges.synthetic_frame("good"))

    r = run_cli("--source", "file", "--input", str(baseline), "--input", str(good))
    require(r.returncode == 0 and "PASS: all four edges correct" in r.stdout,
            f"file-backed good capture failed rc={r.returncode}\nstdout={r.stdout}\nstderr={r.stderr}")
    print("PASS file-backed capture mode grades changed good frame")

    r = run_cli("--source", "file", "--input", str(good), "--input", str(stale))
    require(r.returncode == 2 and "STALE capture" in r.stderr,
            f"stale file-backed capture was not rejected rc={r.returncode}\nstdout={r.stdout}\nstderr={r.stderr}")
    print("PASS byte-identical consecutive grabs rejected as STALE")

    r = run_cli("--source", "synthetic", "--synthetic-case", "stale")
    require(r.returncode == 2 and "STALE capture" in r.stderr,
            f"synthetic stale case was not rejected rc={r.returncode}\nstdout={r.stdout}\nstderr={r.stderr}")
    print("PASS synthetic stale source rejected before grading")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
