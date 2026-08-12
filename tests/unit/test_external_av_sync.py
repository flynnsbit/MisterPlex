#!/usr/bin/env python3
"""Offline coverage for the external HDMI/USB A/V measurement harness."""
from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HARNESS_PATH = ROOT / "tests" / "hw" / "external_av_sync.py"
GENERATOR_PATH = ROOT / "tests" / "fixtures" / "external_av" / "generate_av_marker.py"
WORK = ROOT / "build" / "external-av-unit"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


generator = load_module("external_av_generator", GENERATOR_PATH)
harness = load_module("external_av_harness", HARNESS_PATH)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def run_harness(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(HARNESS_PATH), *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=180,
    )


def generate_fixture(name: str, profile: tuple[float, float, float]) -> tuple[Path, Path]:
    output = WORK / f"{name}.mkv"
    manifest = generator.generate(
        output,
        rate=generator.parse_rate("24000/1001"),
        width=160,
        height=90,
        marker_count=12,
        codec="lossless",
        flash_frames=2,
        lead_intervals=2,
        tail_intervals=2,
        offset_profile_ms=profile,
        force=True,
    )
    return output, manifest


def analyze(capture: Path, manifest: Path, out_name: str, adapter_ms: float) -> tuple[int, dict]:
    out = WORK / out_name
    result = run_harness(
        "--analyze",
        str(capture),
        "--out-dir",
        str(out),
        "--fixture-manifest",
        str(manifest),
        "--adapter-offset-ms",
        str(adapter_ms),
    )
    report = json.loads((out / "report.json").read_text())
    return result.returncode, report


def main() -> int:
    shutil.rmtree(WORK, ignore_errors=True)
    WORK.mkdir(parents=True)

    # Every required source rate has an exactly sample-aligned marker period.
    expected = {
        "24000/1001": 1001.0,
        "24": 1000.0,
        "25": 1000.0,
        "30000/1001": 1001.0,
        "30": 1000.0,
    }
    for text, expected_ms in expected.items():
        rate = generator.parse_rate(text)
        _frames, _samples, markers = generator.marker_schedule(
            rate, 12, 2, 2, (0.0, 0.0, 0.0)
        )
        require(len(markers) == 12, f"{text}: marker count")
        require(
            abs(rate.marker_period_samples * 1000.0 / generator.SAMPLE_RATE - expected_ms) < 1e-9,
            f"{text}: exact marker period",
        )
        require(
            all(marker["nominal_audio_sample"] == marker["audio_sample"] for marker in markers),
            f"{text}: default markers must be coincident",
        )
    print("PASS all five source rates have sample-exact flash/click schedules")

    # Synthetic inventory proves pairing is by physical USB parent, not card number.
    inventory = {
        "video": [
            {
                "path": "/dev/video8",
                "real_path": "/dev/video8",
                "by_id": ["/dev/v4l/by-id/usb-grabber-video-index0"],
                "usb_path": "/sys/devices/usb1/1-2",
            }
        ],
        "audio": [
            {
                "alsa_device": "hw:CARD=Grabber,DEV=0",
                "aliases": ["hw:3,0"],
                "usb_path": "/sys/devices/usb1/1-2",
            },
            {
                "alsa_device": "hw:CARD=Other,DEV=0",
                "aliases": ["hw:4,0"],
                "usb_path": "/sys/devices/usb1/1-4",
            },
        ],
    }
    video, audio = harness.validate_pair(
        inventory, "/dev/v4l/by-id/usb-grabber-video-index0", "hw:CARD=Grabber,DEV=0"
    )
    require(video["usb_path"] == audio["usb_path"], "matching USB parent accepted")
    try:
        harness.validate_pair(inventory, "/dev/video8", "hw:CARD=Other,DEV=0")
    except harness.BlockedError:
        pass
    else:
        raise AssertionError("unpaired ALSA endpoint was accepted")
    print("PASS explicit V4L2/ALSA binding rejects a different USB adapter")

    result = run_harness("--self-test")
    require(
        result.returncode == 0,
        f"event parser self-test failed\nstdout={result.stdout}\nstderr={result.stderr}",
    )
    print("PASS pure parser fixtures include non-monotonic and insufficient-marker cases")

    # Uniform synthetic adapter skew is removed only by the separately supplied
    # calibration value.
    capture, manifest = generate_fixture("uniform-offset", (60.0, 60.0, 60.0))
    rc, report = analyze(capture, manifest, "uniform-report", 60.0)
    require(rc == 0 and report["status"] == "PASS", f"calibrated fixture failed: {report}")
    require(
        all(abs(window["corrected_median_ms"]) < 1.0 for window in report["windows"].values()),
        f"fixed adapter offset was not removed: {report['windows']}",
    )
    print("PASS lossless media parser removes separately measured fixed adapter offset")

    # Start/end are good and equal, but the middle is deliberately bad. The
    # endpoint slope is zero, so only independent three-window gating catches it.
    capture_bad, manifest_bad = generate_fixture("middle-excursion", (10.0, 90.0, 10.0))
    rc, report = analyze(capture_bad, manifest_bad, "middle-report", 10.0)
    require(rc == 1 and report["status"] == "FAIL", f"middle excursion passed: {report}")
    require(
        abs(report["windows"]["start"]["corrected_median_ms"]) < 1.0
        and abs(report["windows"]["end"]["corrected_median_ms"]) < 1.0
        and report["windows"]["middle"]["corrected_median_ms"] > 42.0,
        f"middle-only failure was not localized: {report['windows']}",
    )
    print("PASS zero endpoint slope cannot hide a middle-window excursion")

    # Remove audio without touching video. Missing paired capture audio is a hard
    # BLOCKED result (rc=4), never a pass or soft skip.
    video_only = WORK / "video-only.mkv"
    subprocess.run(
        [
            "ffmpeg",
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(capture),
            "-map",
            "0:v:0",
            "-c:v",
            "copy",
            "-an",
            str(video_only),
        ],
        check=True,
        timeout=60,
    )
    rc, report = analyze(video_only, manifest, "video-only-report", 60.0)
    require(rc == 4 and report["status"] == "BLOCKED", f"missing audio was not blocked: {report}")
    print("PASS missing audio is BLOCKED with a persistent report")

    print("test_external_av_sync: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
