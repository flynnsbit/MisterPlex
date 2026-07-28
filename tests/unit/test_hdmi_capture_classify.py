#!/usr/bin/env python3
"""Unit coverage for HDMI no-signal/black/content classification."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "scripts" / "hdmi_capture_classify.py"
WORK = ROOT / "build" / "hdmi-capture-classify-unit"


def save(path: Path, frame: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(frame.astype(np.uint8), "RGB").save(path)


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(TOOL), "--source", "file", "--video-size", "1280x720", *args],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=30,
    )


def require(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


def main() -> int:
    print(
        "Scope: hdmi_capture_classify unit; synthetic PNG frames exercise VALID_CONTENT, "
        "VALID_BLACK, and NO_SIGNAL classifications plus a content-vs-black red check. "
        "It does not open /dev/video0 or prove real HDMI signal integrity."
    )
    WORK.mkdir(parents=True, exist_ok=True)
    black = np.zeros((720, 1280, 3), dtype=np.uint8)
    content = black.copy()
    content[:, :, :] = 18
    content[200:520, 360:920, 1] = 180
    content[260:460, 520:760, 2] = 230
    no_signal = np.full((720, 1280, 3), 80, dtype=np.uint8)

    black_p = WORK / "black.png"
    content_p = WORK / "content.png"
    no_signal_p = WORK / "no_signal.png"
    save(black_p, black)
    save(content_p, content)
    save(no_signal_p, no_signal)

    r = run("--input", str(content_p), "--expect", "content")
    require(r.returncode == 0 and "HDMI_CAPTURE_RESULT class=VALID_CONTENT" in r.stdout,
            f"content frame failed rc={r.returncode}\n{r.stdout}")
    print("PASS synthetic content classified VALID_CONTENT")

    r = run("--input", str(black_p), "--expect", "black")
    require(r.returncode == 0 and "HDMI_CAPTURE_RESULT class=VALID_BLACK" in r.stdout,
            f"black frame failed rc={r.returncode}\n{r.stdout}")
    print("PASS synthetic black classified VALID_BLACK")

    r = run("--input", str(no_signal_p), "--expect", "no-signal")
    require(r.returncode == 0 and "HDMI_CAPTURE_RESULT class=NO_SIGNAL" in r.stdout,
            f"no-signal frame failed rc={r.returncode}\n{r.stdout}")
    print("PASS synthetic flat nonblack classified NO_SIGNAL")

    r = run("--input", str(black_p), "--expect", "content")
    require(r.returncode == 1 and "HDMI_CAPTURE_EXPECT_FAIL got=VALID_BLACK want=VALID_CONTENT" in r.stdout,
            f"red check did not reject black-as-content rc={r.returncode}\n{r.stdout}")
    print("PASS red-check black frame rejected as content")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
