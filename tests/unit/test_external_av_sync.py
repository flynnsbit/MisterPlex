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


def require_raises(exc_type, fn, message: str) -> None:
    try:
        fn()
    except exc_type:
        return
    raise AssertionError(message)


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
    require_raises(
        ValueError,
        lambda: generator.marker_schedule(
            generator.parse_rate("24"), 12, 2, 2, (float("nan"), 0.0, 0.0)
        ),
        "generator accepted a non-finite synthetic offset",
    )
    require_raises(
        ValueError,
        lambda: generator.marker_schedule(generator.Rate(0, 1), 12, 2, 2, (0.0, 0.0, 0.0)),
        "generator accepted a non-positive source rate",
    )
    print("PASS fixture generator rejects non-finite offsets and invalid rates")

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
    missing_period = harness.period_summary(
        [1, 2, 3, 4, 5, 7, 8, 9, 10, 11], 1000.0
    )
    require(
        missing_period["median_ms"] == 1000.0
        and missing_period["max_abs_error_ms"] == 1000.0,
        f"missing-marker red fixture no longer proves median-only false green: {missing_period}",
    )
    outlier_report, _pairs = harness.evaluate_markers(
        video_events=[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
        audio_events=[1, 2, 3.06, 4, 5, 6, 7, 8, 9, 10, 11],
        capture_start_s=0.0,
        duration_s=12.0,
        adapter_offset_ms=0.0,
        expected_period_ms=1000.0,
        min_markers_per_window=3,
        pair_window_ms=250.0,
        max_abs_offset_ms=42.0,
        max_window_span_ms=42.0,
        max_period_error_ms=25.0,
        max_interval_error_ms=75.0,
        max_offset_step_ms=42.0,
        min_paired_coverage=0.95,
    )
    require(
        outlier_report["windows"]["start"]["corrected_median_ms"] == 0.0
        and outlier_report["windows"]["start"]["max_abs_corrected_ms"] == 60.0
        and outlier_report["status"] == "FAIL",
        f"three-marker median hid an offset outlier: {outlier_report}",
    )
    print("PASS parser red fixtures cover missing/short-long markers and hidden offset outliers")

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

    # Invalid numeric inputs must fail before analysis. In particular, argparse's
    # float type accepts NaN/Inf unless the harness rejects them explicitly.
    invalid_cli = [
        ("adapter-nan", "--adapter-offset-ms", "nan"),
        ("period-threshold-nan", "--max-period-error-ms", "nan"),
        ("interval-threshold-zero", "--max-interval-error-ms", "0"),
        ("pair-window-negative", "--pair-window-ms", "-1"),
        ("duration-inf", "--duration", "inf"),
        ("coverage-over-one", "--min-paired-coverage", "1.1"),
    ]
    for label, option, value in invalid_cli:
        out = WORK / f"invalid-{label}"
        arguments = [
            "--analyze",
            str(capture),
            "--out-dir",
            str(out),
            "--fixture-manifest",
            str(manifest),
            "--adapter-offset-ms",
            "0",
            option,
            value,
        ]
        if option == "--adapter-offset-ms":
            del arguments[6:8]
        result = run_harness(*arguments)
        require(
            result.returncode == 2 and not out.exists(),
            f"{option}={value} was not rejected before analysis: "
            f"rc={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}",
        )
    print("PASS NaN/Inf and non-positive CLI thresholds/rates/duration are rejected")

    manifest_data = json.loads(manifest.read_text())
    nan_manifest = WORK / "nan-period.manifest.json"
    manifest_data["schedule"]["marker_period_ms"] = float("nan")
    nan_manifest.write_text(json.dumps(manifest_data, allow_nan=True))
    result = run_harness(
        "--analyze",
        str(capture),
        "--out-dir",
        str(WORK / "nan-period-report"),
        "--fixture-manifest",
        str(nan_manifest),
        "--adapter-offset-ms",
        "0",
    )
    require(
        result.returncode == 2 and "non-finite" in result.stderr,
        f"NaN manifest period was not rejected: rc={result.returncode}\n{result.stderr}",
    )

    zero_rate_manifest = WORK / "zero-rate.manifest.json"
    manifest_data = json.loads(manifest.read_text())
    manifest_data["source_rate"]["num"] = 0
    zero_rate_manifest.write_text(json.dumps(manifest_data))
    result = run_harness(
        "--analyze",
        str(capture),
        "--out-dir",
        str(WORK / "zero-rate-report"),
        "--fixture-manifest",
        str(zero_rate_manifest),
        "--adapter-offset-ms",
        "0",
    )
    require(
        result.returncode == 2 and "positive integer" in result.stderr,
        f"non-positive manifest rate was not rejected: rc={result.returncode}\n{result.stderr}",
    )

    nan_calibration = WORK / "nan-calibration.json"
    nan_calibration.write_text(
        json.dumps(
            {
                "schema": "misterplex.external-av.adapter-offset.v1",
                "audio_minus_video_ms": float("nan"),
            },
            allow_nan=True,
        )
    )
    result = run_harness(
        "--analyze",
        str(capture),
        "--out-dir",
        str(WORK / "nan-calibration-report"),
        "--fixture-manifest",
        str(manifest),
        "--adapter-offset-file",
        str(nan_calibration),
    )
    require(
        result.returncode == 2 and "non-finite" in result.stderr,
        f"NaN calibration was not rejected: rc={result.returncode}\n{result.stderr}",
    )
    print("PASS non-finite manifest and calibration values are rejected")

    no_provenance = WORK / "no-provenance-calibration.json"
    no_provenance.write_text(
        json.dumps(
            {
                "schema": "misterplex.external-av.adapter-offset.v1",
                "audio_minus_video_ms": 10.0,
            }
        )
    )
    require_raises(
        ValueError,
        lambda: harness.load_calibration(
            no_provenance, None, require_provenance=True
        ),
        "hardware calibration accepted a file without provenance",
    )
    proven_calibration = WORK / "provenance-calibration.json"
    proven_calibration.write_text(
        json.dumps(
            {
                "schema": "misterplex.external-av.adapter-offset.v1",
                "audio_minus_video_ms": 10.0,
                "measured_at": "2026-08-12",
                "method": "known-synchronous local fixture",
            }
        )
    )
    loaded_calibration = harness.load_calibration(
        proven_calibration, None, require_provenance=True
    )
    require(
        loaded_calibration["audio_minus_video_ms"] == 10.0,
        "valid provenance-bearing calibration was rejected",
    )
    capture_out = WORK / "capture-direct-ms-must-not-run"
    result = run_harness(
        "--capture",
        "--video-device",
        "/dev/not-opened-by-unit-test",
        "--audio-device",
        "hw:CARD=NOT_OPENED,DEV=0",
        "--out-dir",
        str(capture_out),
        "--fixture-manifest",
        str(manifest),
        "--adapter-offset-ms",
        "0",
    )
    require(
        result.returncode == 2
        and not capture_out.exists()
        and "requires --adapter-offset-file" in result.stderr,
        f"hardware capture accepted direct offset or advanced to device setup: "
        f"rc={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}",
    )
    print("PASS hardware capture requires a provenance-bearing offset file before device setup")

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
