#!/usr/bin/env python3
"""Capture and measure external HDMI-to-USB video plus its paired USB audio."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

import numpy as np


ROOT = Path(__file__).resolve().parents[2]
SELF_TEST_FIXTURE = ROOT / "tests" / "fixtures" / "external_av" / "synthetic_events.json"
EXIT_FAIL = 1
EXIT_USAGE = 2
EXIT_BLOCKED = 4
SUPPORTED_RATES = {
    (24000, 1001),
    (24, 1),
    (25, 1),
    (30000, 1001),
    (30, 1),
}


class BlockedError(RuntimeError):
    pass


def finite_number(value: Any, name: str) -> float:
    if isinstance(value, bool):
        raise ValueError(f"{name} must be numeric")
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be numeric") from exc
    if not math.isfinite(number):
        raise ValueError(f"{name} must be finite")
    return number


def positive_number(value: Any, name: str) -> float:
    number = finite_number(value, name)
    if number <= 0:
        raise ValueError(f"{name} must be positive")
    return number


def positive_int(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ValueError(f"{name} must be a positive integer")
    return value


def reject_nonfinite_numbers(value: Any, name: str) -> None:
    if isinstance(value, float) and not math.isfinite(value):
        raise ValueError(f"{name} contains a non-finite number")
    if isinstance(value, dict):
        for key, child in value.items():
            reject_nonfinite_numbers(child, f"{name}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_nonfinite_numbers(child, f"{name}[{index}]")


def finite_float_arg(text: str) -> float:
    try:
        return finite_number(text, "value")
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc


def positive_float_arg(text: str) -> float:
    try:
        return positive_number(text, "value")
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc


def positive_int_arg(text: str) -> int:
    try:
        value = int(text)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("value must be a positive integer") from exc
    if value <= 0:
        raise argparse.ArgumentTypeError("value must be a positive integer")
    return value


def coverage_arg(text: str) -> float:
    value = positive_float_arg(text)
    if value > 1.0:
        raise argparse.ArgumentTypeError("coverage must be in (0, 1]")
    return value


def read_text(path: Path) -> str:
    try:
        return path.read_text().strip()
    except OSError:
        return ""


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as src:
        while True:
            chunk = src.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def command_version(command: str) -> str | None:
    exe = shutil.which(command)
    if exe is None:
        return None
    result = subprocess.run(
        [exe, "-version"] if command in {"ffmpeg", "ffprobe"} else [exe, "--version"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    text = result.stdout or result.stderr
    return text.splitlines()[0] if text else exe


def usb_identity(device_path: Path) -> dict[str, str | None]:
    try:
        current = device_path.resolve()
    except OSError:
        current = device_path
    for parent in (current, *current.parents):
        vendor = parent / "idVendor"
        product = parent / "idProduct"
        if vendor.is_file() and product.is_file():
            return {
                "usb_path": str(parent),
                "usb_vendor_id": read_text(vendor).lower() or None,
                "usb_product_id": read_text(product).lower() or None,
                "usb_serial": read_text(parent / "serial") or None,
                "usb_product": read_text(parent / "product") or None,
                "usb_manufacturer": read_text(parent / "manufacturer") or None,
            }
    return {
        "usb_path": None,
        "usb_vendor_id": None,
        "usb_product_id": None,
        "usb_serial": None,
        "usb_product": None,
        "usb_manufacturer": None,
    }


def video_by_id_links(device: Path) -> list[str]:
    links: list[str] = []
    by_id = Path("/dev/v4l/by-id")
    if not by_id.is_dir():
        return links
    try:
        target = device.resolve()
    except OSError:
        return links
    for link in sorted(by_id.iterdir()):
        try:
            if link.resolve() == target:
                links.append(str(link))
        except OSError:
            continue
    return links


def enumerate_video_devices() -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    root = Path("/sys/class/video4linux")
    if not root.is_dir():
        return entries
    for node in sorted(root.glob("video*")):
        device = Path("/dev") / node.name
        sys_device = node / "device"
        identity = usb_identity(sys_device)
        entry: dict[str, Any] = {
            "path": str(device),
            "real_path": os.path.realpath(device),
            "name": read_text(node / "name"),
            "sysfs_path": os.path.realpath(sys_device),
            "by_id": video_by_id_links(device),
        }
        entry.update(identity)
        entries.append(entry)
    return entries


def enumerate_audio_devices() -> list[dict[str, Any]]:
    arecord = shutil.which("arecord")
    if arecord is None:
        return []
    env = os.environ.copy()
    env["LC_ALL"] = "C"
    result = subprocess.run(
        [arecord, "-l"],
        capture_output=True,
        text=True,
        timeout=15,
        env=env,
    )
    text = result.stdout + "\n" + result.stderr
    pattern = re.compile(
        r"^card\s+(\d+):\s*([^\s]+)\s+\[([^\]]*)\],\s*"
        r"device\s+(\d+):\s*([^\[]+)\[([^\]]*)\]",
        re.MULTILINE,
    )
    entries: list[dict[str, Any]] = []
    for match in pattern.finditer(text):
        card_num = int(match.group(1))
        parsed_card_id = match.group(2)
        card_id = read_text(Path(f"/proc/asound/card{card_num}/id")) or parsed_card_id
        device_num = int(match.group(4))
        sys_device = Path(f"/sys/class/sound/card{card_num}/device")
        identity = usb_identity(sys_device)
        stable = f"hw:CARD={card_id},DEV={device_num}"
        entry: dict[str, Any] = {
            "alsa_device": stable,
            "aliases": [f"hw:{card_num},{device_num}", f"plughw:CARD={card_id},DEV={device_num}"],
            "card_number": card_num,
            "card_id": card_id,
            "card_name": match.group(3).strip(),
            "device_number": device_num,
            "device_name": match.group(5).strip(),
            "pcm_name": match.group(6).strip(),
            "sysfs_path": os.path.realpath(sys_device),
        }
        entry.update(identity)
        entries.append(entry)
    return entries


def enumerate_inventory() -> dict[str, Any]:
    inventory = {
        "schema": "misterplex.external-av.inventory.v1",
        "video": enumerate_video_devices(),
        "audio": enumerate_audio_devices(),
    }
    for video in inventory["video"]:
        video["matching_audio"] = [
            audio["alsa_device"]
            for audio in inventory["audio"]
            if video.get("usb_path") and video.get("usb_path") == audio.get("usb_path")
        ]
    return inventory


def find_video(inventory: dict[str, Any], requested: str) -> dict[str, Any]:
    requested_real = os.path.realpath(requested)
    for entry in inventory.get("video", []):
        names = {entry.get("path"), entry.get("real_path"), *entry.get("by_id", [])}
        real_names = {os.path.realpath(str(name)) for name in names if name}
        if requested in names or requested_real in real_names:
            return entry
    raise BlockedError(f"selected V4L2 endpoint is not in inventory: {requested}")


def find_audio(inventory: dict[str, Any], requested: str) -> dict[str, Any]:
    for entry in inventory.get("audio", []):
        names = {entry.get("alsa_device"), *entry.get("aliases", [])}
        if requested in names:
            return entry
    raise BlockedError(f"selected ALSA capture endpoint is not in inventory: {requested}")


def validate_pair(
    inventory: dict[str, Any], video_name: str, audio_name: str
) -> tuple[dict[str, Any], dict[str, Any]]:
    video = find_video(inventory, video_name)
    matching = [
        audio
        for audio in inventory.get("audio", [])
        if video.get("usb_path") and video.get("usb_path") == audio.get("usb_path")
    ]
    if not matching:
        raise BlockedError("selected HDMI-to-USB video endpoint has no matching USB ALSA capture endpoint")
    audio = find_audio(inventory, audio_name)
    if not video.get("usb_path") or not audio.get("usb_path"):
        raise BlockedError("cannot prove the selected video and audio endpoints share one USB adapter")
    if video["usb_path"] != audio["usb_path"]:
        raise BlockedError(
            f"ALSA endpoint {audio_name} is not paired with V4L2 endpoint {video_name}"
        )
    for key in ("usb_vendor_id", "usb_product_id", "usb_serial"):
        v_value = video.get(key)
        a_value = audio.get(key)
        if v_value not in (None, "") and a_value not in (None, "") and v_value != a_value:
            raise BlockedError(
                f"paired USB identity mismatch for {key}: video={v_value!r} audio={a_value!r}"
            )
    return video, audio


def owners_of_device(device: Path) -> tuple[list[dict[str, Any]], bool]:
    target = device.resolve()
    target_stat = target.stat()
    if not stat.S_ISCHR(target_stat.st_mode):
        raise BlockedError(f"selected V4L2 endpoint is not a character device: {device}")
    pids: set[int] = set()
    complete = True

    fuser = shutil.which("fuser")
    if fuser:
        result = subprocess.run([fuser, str(target)], capture_output=True, text=True, timeout=10)
        # fuser prints the device label on stderr; parsing it would mistake the
        # numeric suffix in /dev/videoN for a PID.
        for token in re.findall(r"\b\d+\b", result.stdout):
            pids.add(int(token))

    proc = Path("/proc")
    for pid_dir in proc.glob("[0-9]*"):
        try:
            pid = int(pid_dir.name)
        except ValueError:
            continue
        if pid == os.getpid():
            continue
        fd_dir = pid_dir / "fd"
        try:
            fds = list(fd_dir.iterdir())
        except PermissionError:
            complete = complete and fuser is not None
            continue
        except OSError:
            continue
        for fd in fds:
            try:
                opened = fd.stat()
            except OSError:
                continue
            if stat.S_ISCHR(opened.st_mode) and opened.st_rdev == target_stat.st_rdev:
                pids.add(pid)
                break

    owners = []
    for pid in sorted(pids):
        if pid == os.getpid():
            continue
        owners.append({"pid": pid, "comm": read_text(Path(f"/proc/{pid}/comm")) or "unknown"})
    return owners, complete


def load_manifest(path: Path) -> dict[str, Any]:
    manifest = json.loads(path.read_text())
    reject_nonfinite_numbers(manifest, "fixture manifest")
    if manifest.get("schema") != "misterplex.external-av.fixture.v1":
        raise ValueError("fixture manifest has an unsupported schema")
    source = manifest.get("source_rate", {})
    rate = (
        positive_int(source.get("num"), "fixture source numerator"),
        positive_int(source.get("den"), "fixture source denominator"),
    )
    if rate not in SUPPORTED_RATES:
        raise ValueError(f"fixture rate {rate[0]}/{rate[1]} is not in the required source-rate set")
    schedule = manifest.get("schedule")
    if not isinstance(schedule, dict):
        raise ValueError("fixture manifest has no schedule")
    period = positive_number(schedule.get("marker_period_ms"), "fixture marker_period_ms")
    expected_period = 1001.0 if rate[1] == 1001 else 1000.0
    if abs(period - expected_period) > 1e-6:
        raise ValueError(
            f"fixture marker_period_ms={period} does not match rate "
            f"{rate[0]}/{rate[1]} ({expected_period} ms)"
        )
    expected_frames = rate[0] // 1000 if rate[1] == 1001 else rate[0]
    expected_samples = 48048 if rate[1] == 1001 else 48000
    if positive_int(schedule.get("marker_period_frames"), "fixture marker_period_frames") != expected_frames:
        raise ValueError("fixture marker_period_frames does not match its source rate")
    if positive_int(schedule.get("marker_period_samples"), "fixture marker_period_samples") != expected_samples:
        raise ValueError("fixture marker_period_samples does not match its source rate")
    markers = schedule.get("markers")
    if not isinstance(markers, list) or len(markers) < 9:
        raise ValueError("fixture manifest must describe at least 9 markers")
    return manifest


def load_calibration(
    offset_file: Path | None,
    offset_ms: float | None,
    video: dict[str, Any] | None = None,
    *,
    require_provenance: bool = False,
) -> dict[str, Any]:
    if (offset_file is None) == (offset_ms is None):
        raise ValueError("provide exactly one of --adapter-offset-file or --adapter-offset-ms")
    if offset_file is not None:
        calibration = json.loads(offset_file.read_text())
        reject_nonfinite_numbers(calibration, "adapter calibration")
        if calibration.get("schema") != "misterplex.external-av.adapter-offset.v1":
            raise ValueError("adapter offset file has an unsupported schema")
        if "audio_minus_video_ms" not in calibration:
            raise ValueError("adapter offset file lacks audio_minus_video_ms")
        calibration["audio_minus_video_ms"] = finite_number(
            calibration["audio_minus_video_ms"], "adapter audio_minus_video_ms"
        )
        if require_provenance:
            for field in ("measured_at", "method"):
                value = calibration.get(field)
                if not isinstance(value, str) or not value.strip():
                    raise ValueError(
                        f"hardware capture adapter offset file requires non-empty {field}"
                    )
    else:
        calibration = {
            "schema": "misterplex.external-av.adapter-offset.v1",
            "audio_minus_video_ms": finite_number(offset_ms, "adapter offset"),
            "source": "explicit command-line value",
        }
    if video is not None:
        validate_calibration_identity(calibration, video)
    return calibration


def validate_calibration_identity(
    calibration: dict[str, Any], video: dict[str, Any]
) -> None:
    for key in ("usb_vendor_id", "usb_product_id", "usb_serial"):
        expected = calibration.get(key)
        actual = video.get(key)
        if expected not in (None, "") and expected != actual:
            raise BlockedError(
                f"adapter calibration {key}={expected!r} does not match selected device {actual!r}"
            )


def ffprobe_json(capture: Path) -> dict[str, Any]:
    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_streams",
            "-show_format",
            "-of",
            "json",
            str(capture),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=60,
    )
    return json.loads(result.stdout)


def parse_ffprobe_pts_lines(text: str) -> list[float]:
    # ffprobe csv=p=0 can append side-data after best_effort_timestamp_time.
    times: list[float] = []
    for raw_line in text.splitlines():
        first = raw_line.strip().split(",", 1)[0].strip()
        if not first:
            continue
        try:
            candidate = float(first)
        except ValueError:
            continue
        try:
            times.append(finite_number(candidate, "video frame PTS"))
        except ValueError:
            raise RuntimeError(f"capture contains an invalid video frame PTS: {first!r}")
    return times


def first_packet_pts(capture: Path, stream: str) -> float:
    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            stream,
            "-read_intervals",
            "%+#1",
            "-show_packets",
            "-show_entries",
            "packet=pts_time",
            "-of",
            "json",
            str(capture),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=60,
    )
    packets = json.loads(result.stdout).get("packets", [])
    if packets and packets[0].get("pts_time") not in (None, "N/A"):
        return finite_number(packets[0]["pts_time"], f"{stream} first packet PTS")
    return 0.0


def video_luma(capture: Path, stream_info: dict[str, Any]) -> tuple[np.ndarray, np.ndarray]:
    width, height = 64, 36
    raw = subprocess.run(
        [
            "ffmpeg",
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(capture),
            "-map",
            "0:v:0",
            "-vf",
            f"scale={width}:{height},format=gray",
            "-fps_mode",
            "passthrough",
            "-f",
            "rawvideo",
            "pipe:1",
        ],
        check=True,
        capture_output=True,
        timeout=300,
    ).stdout
    pixels = np.frombuffer(raw, dtype=np.uint8)
    frame_size = width * height
    frame_count = pixels.size // frame_size
    luma = pixels[: frame_count * frame_size].reshape(frame_count, frame_size).mean(axis=1)

    pts_result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_frames",
            "-show_entries",
            "frame=best_effort_timestamp_time",
            "-of",
            "csv=p=0",
            str(capture),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=300,
    )
    times = parse_ffprobe_pts_lines(pts_result.stdout)
    if not times:
        rate_text = stream_info.get("avg_frame_rate") or stream_info.get("r_frame_rate") or "0/1"
        num_text, den_text = rate_text.split("/", 1)
        numerator = positive_number(num_text, "capture video frame-rate numerator")
        denominator = positive_number(den_text, "capture video frame-rate denominator")
        fps = positive_number(numerator / denominator, "capture video frame rate")
        start = finite_number(stream_info.get("start_time") or 0.0, "capture video start time")
        times = [start + i / fps for i in range(frame_count)]
    count = min(frame_count, len(times))
    return luma[:count], np.asarray(times[:count], dtype=float)


def validate_audio_capture_samples(samples: np.ndarray) -> None:
    if samples.size == 0:
        raise BlockedError("capture audio stream contains no samples")
    unique_count = int(np.unique(samples).size)
    variance = float(np.var(samples.astype(np.float64)))
    if unique_count <= 2 or variance < 1.0:
        raise BlockedError(
            "capture audio is degenerate "
            f"(unique_samples={unique_count} variance={variance:.3f}); "
            "power-cycle or replace the HDMI-to-USB adapter before grading A/V"
        )


def audio_envelope(capture: Path, sample_rate: int = 48_000) -> tuple[np.ndarray, np.ndarray]:
    origin = first_packet_pts(capture, "a:0")
    raw = subprocess.run(
        [
            "ffmpeg",
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(capture),
            "-map",
            "0:a:0",
            "-ac",
            "1",
            "-ar",
            str(sample_rate),
            "-f",
            "s16le",
            "pipe:1",
        ],
        check=True,
        capture_output=True,
        timeout=300,
    ).stdout
    raw_samples = np.frombuffer(raw, dtype=np.int16)
    validate_audio_capture_samples(raw_samples)
    samples = raw_samples.astype(np.float64)
    window = sample_rate // 1000
    count = samples.size // window
    if count == 0:
        return np.asarray([], dtype=float), np.asarray([], dtype=float)
    envelope = np.abs(samples[: count * window]).reshape(count, window).mean(axis=1)
    times = origin + np.arange(count, dtype=float) * window / sample_rate
    return envelope, times


def detect_rising_edges(
    values: np.ndarray, times: np.ndarray, *, min_contrast: float, threshold_fraction: float
) -> tuple[list[float], dict[str, float]]:
    if values.size == 0 or times.size == 0:
        return [], {"floor": 0.0, "peak": 0.0, "threshold": 0.0, "contrast": 0.0}
    floor = float(np.percentile(values, 50.0))
    peak = float(np.percentile(values, 99.5))
    contrast = peak - floor
    threshold = floor + threshold_fraction * contrast
    if contrast < min_contrast:
        return [], {
            "floor": floor,
            "peak": peak,
            "threshold": threshold,
            "contrast": contrast,
        }
    hot = values > threshold
    events: list[float] = []
    for index in range(1, hot.size):
        if hot[index] and not hot[index - 1]:
            event = float(times[index])
            if not events or event - events[-1] >= 0.45:
                events.append(event)
    return events, {
        "floor": floor,
        "peak": peak,
        "threshold": threshold,
        "contrast": contrast,
    }


def pair_events(
    video_events: list[float], audio_events: list[float], pair_window_ms: float
) -> list[dict[str, float]]:
    pairs: list[dict[str, float]] = []
    unused = set(range(len(audio_events)))
    window_s = pair_window_ms / 1000.0
    for video_time in video_events:
        candidates = [index for index in unused if abs(audio_events[index] - video_time) <= window_s]
        if not candidates:
            continue
        chosen = min(candidates, key=lambda index: abs(audio_events[index] - video_time))
        unused.remove(chosen)
        audio_time = audio_events[chosen]
        pairs.append(
            {
                "video_s": video_time,
                "audio_s": audio_time,
                "raw_audio_minus_video_ms": (audio_time - video_time) * 1000.0,
            }
        )
    return pairs


def median(values: list[float]) -> float:
    return float(np.median(np.asarray(values, dtype=float)))


def validate_event_times(events: list[float], name: str) -> list[float]:
    validated = [finite_number(value, f"{name} event time") for value in events]
    for index in range(1, len(validated)):
        if validated[index] <= validated[index - 1]:
            raise ValueError(f"{name} event times must be strictly increasing")
    return validated


def period_summary(events: list[float], expected_ms: float) -> dict[str, Any]:
    events = validate_event_times(events, "period")
    expected_ms = positive_number(expected_ms, "expected marker period")
    periods = [(events[i] - events[i - 1]) * 1000.0 for i in range(1, len(events))]
    if not periods:
        return {
            "count": 0,
            "median_ms": None,
            "error_ms": None,
            "mad_ms": None,
            "min_ms": None,
            "max_ms": None,
            "max_abs_error_ms": None,
        }
    med = median(periods)
    errors = [value - expected_ms for value in periods]
    return {
        "count": len(periods),
        "median_ms": round(med, 3),
        "error_ms": round(med - expected_ms, 3),
        "mad_ms": round(median([abs(value - med) for value in periods]), 3),
        "min_ms": round(min(periods), 3),
        "max_ms": round(max(periods), 3),
        "max_abs_error_ms": round(max(abs(value) for value in errors), 3),
    }


def evaluate_markers(
    *,
    video_events: list[float],
    audio_events: list[float],
    capture_start_s: float,
    duration_s: float,
    adapter_offset_ms: float,
    expected_period_ms: float,
    min_markers_per_window: int,
    pair_window_ms: float,
    max_abs_offset_ms: float,
    max_window_span_ms: float,
    max_period_error_ms: float,
    max_interval_error_ms: float,
    max_offset_step_ms: float,
    min_paired_coverage: float,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    video_events = validate_event_times(video_events, "video")
    audio_events = validate_event_times(audio_events, "audio")
    capture_start_s = finite_number(capture_start_s, "capture start")
    duration_s = positive_number(duration_s, "capture duration")
    adapter_offset_ms = finite_number(adapter_offset_ms, "adapter offset")
    expected_period_ms = positive_number(expected_period_ms, "expected marker period")
    pair_window_ms = positive_number(pair_window_ms, "pair window")
    max_abs_offset_ms = positive_number(max_abs_offset_ms, "maximum marker offset")
    max_window_span_ms = positive_number(max_window_span_ms, "maximum window span")
    max_period_error_ms = positive_number(max_period_error_ms, "maximum median period error")
    max_interval_error_ms = positive_number(
        max_interval_error_ms, "maximum individual interval error"
    )
    max_offset_step_ms = positive_number(max_offset_step_ms, "maximum offset step")
    min_paired_coverage = positive_number(min_paired_coverage, "minimum paired coverage")
    if min_paired_coverage > 1.0:
        raise ValueError("minimum paired coverage must be in (0, 1]")
    if (
        isinstance(min_markers_per_window, bool)
        or not isinstance(min_markers_per_window, int)
        or min_markers_per_window < 1
    ):
        raise ValueError("minimum markers per window must be a positive integer")

    pairs = pair_events(video_events, audio_events, pair_window_ms)
    for pair in pairs:
        pair["corrected_audio_minus_video_ms"] = (
            pair["raw_audio_minus_video_ms"] - adapter_offset_ms
        )
    boundaries = [
        capture_start_s,
        capture_start_s + duration_s / 3.0,
        capture_start_s + 2.0 * duration_s / 3.0,
        capture_start_s + duration_s,
    ]
    labels = ("start", "middle", "end")
    windows: dict[str, Any] = {}
    failures: list[str] = []
    medians: list[float] = []
    for index, label in enumerate(labels):
        selected = [
            pair
            for pair in pairs
            if boundaries[index] <= pair["video_s"] <
            (boundaries[index + 1] if index < 2 else boundaries[index + 1] + 1e-9)
        ]
        corrected = [float(pair["corrected_audio_minus_video_ms"]) for pair in selected]
        raw = [float(pair["raw_audio_minus_video_ms"]) for pair in selected]
        window: dict[str, Any] = {
            "range_s": [round(boundaries[index], 6), round(boundaries[index + 1], 6)],
            "markers": len(selected),
            "raw_median_ms": round(median(raw), 3) if raw else None,
            "corrected_median_ms": round(median(corrected), 3) if corrected else None,
            "max_abs_corrected_ms": (
                round(max(abs(value) for value in corrected), 3) if corrected else None
            ),
            "corrected_mad_ms": (
                round(median([abs(value - median(corrected)) for value in corrected]), 3)
                if corrected
                else None
            ),
        }
        windows[label] = window
        if len(selected) < min_markers_per_window:
            failures.append(
                f"{label} window has {len(selected)} markers; need {min_markers_per_window}"
            )
        elif float(window["max_abs_corrected_ms"]) > max_abs_offset_ms:
            failures.append(
                f"{label} marker offset {window['max_abs_corrected_ms']} ms exceeds "
                f"{max_abs_offset_ms} ms; median={window['corrected_median_ms']} ms"
            )
        if window["corrected_median_ms"] is not None:
            medians.append(float(window["corrected_median_ms"]))

    if len(medians) == 3 and max(medians) - min(medians) > max_window_span_ms:
        failures.append(
            f"start/middle/end span {max(medians) - min(medians):.3f} ms exceeds "
            f"{max_window_span_ms} ms"
        )

    paired_denominator = max(len(video_events), len(audio_events))
    paired_coverage = len(pairs) / paired_denominator if paired_denominator else 0.0
    if paired_coverage < min_paired_coverage:
        failures.append(
            f"paired marker coverage {paired_coverage:.3f} is below {min_paired_coverage:.3f}"
        )

    corrected_offsets = [float(pair["corrected_audio_minus_video_ms"]) for pair in pairs]
    offset_steps = [
        abs(corrected_offsets[index] - corrected_offsets[index - 1])
        for index in range(1, len(corrected_offsets))
    ]
    max_offset_step = max(offset_steps, default=0.0)
    if max_offset_step > max_offset_step_ms:
        failures.append(
            f"marker offset step {max_offset_step:.3f} ms exceeds {max_offset_step_ms} ms"
        )

    video_period = period_summary(video_events, expected_period_ms)
    audio_period = period_summary(audio_events, expected_period_ms)
    for label, summary in (("video", video_period), ("audio", audio_period)):
        error = summary.get("error_ms")
        if error is None or abs(float(error)) > max_period_error_ms:
            failures.append(
                f"{label} marker period error {error} ms exceeds {max_period_error_ms} ms"
            )
        interval_error = summary.get("max_abs_error_ms")
        if interval_error is None or float(interval_error) > max_interval_error_ms:
            failures.append(
                f"{label} maximum marker interval error {interval_error} ms exceeds "
                f"{max_interval_error_ms} ms"
            )

    endpoint_slope = None
    if windows["start"]["corrected_median_ms"] is not None and windows["end"][
        "corrected_median_ms"
    ] is not None:
        span_min = (boundaries[2] - boundaries[0]) / 60.0
        if span_min > 0:
            endpoint_slope = (
                float(windows["end"]["corrected_median_ms"])
                - float(windows["start"]["corrected_median_ms"])
            ) / span_min

    report = {
        "status": "PASS" if not failures else "FAIL",
        "adapter_audio_minus_video_ms": adapter_offset_ms,
        "detected": {
            "video_flashes": len(video_events),
            "audio_clicks": len(audio_events),
            "paired_markers": len(pairs),
            "paired_coverage": round(paired_coverage, 6),
        },
        "windows": windows,
        "periods": {"video": video_period, "audio": audio_period},
        "continuity": {
            "max_offset_step_ms": round(max_offset_step, 3),
        },
        "endpoint_slope_ms_per_min_diagnostic_only": (
            round(endpoint_slope, 3) if endpoint_slope is not None else None
        ),
        "gate_note": (
            "Every marker, interval, adjacent offset step, pairing coverage, and each "
            "start/middle/end window are gated; medians and endpoint slope are diagnostic only."
        ),
        "failures": failures,
    }
    return report, pairs


def analyse_capture(
    capture: Path,
    out_dir: Path,
    manifest: dict[str, Any],
    calibration: dict[str, Any],
    args: argparse.Namespace,
) -> dict[str, Any]:
    probe = ffprobe_json(capture)
    write_json(out_dir / "ffprobe.json", probe)
    video_streams = [stream for stream in probe.get("streams", []) if stream.get("codec_type") == "video"]
    audio_streams = [stream for stream in probe.get("streams", []) if stream.get("codec_type") == "audio"]
    if not video_streams:
        raise BlockedError("capture has no video stream")
    if not audio_streams:
        raise BlockedError("capture has no audio stream; external A/V verification is BLOCKED")

    duration_value = probe.get("format", {}).get("duration")
    duration = 0.0
    if duration_value not in (None, "N/A", ""):
        duration = positive_number(duration_value, "capture format duration")
    if duration == 0.0:
        durations = [
            positive_number(stream["duration"], "capture stream duration")
            for stream in probe.get("streams", [])
            if stream.get("duration") not in (None, "N/A")
        ]
        duration = max(durations, default=0.0)
    if not math.isfinite(duration) or duration <= 0:
        raise RuntimeError("capture duration is unavailable")

    luma, video_times = video_luma(capture, video_streams[0])
    envelope, audio_times = audio_envelope(capture)
    flashes, video_detection = detect_rising_edges(
        luma, video_times, min_contrast=35.0, threshold_fraction=0.55
    )
    clicks, audio_detection = detect_rising_edges(
        envelope, audio_times, min_contrast=150.0, threshold_fraction=0.35
    )
    capture_start = min(
        float(video_times[0]) if video_times.size else 0.0,
        float(audio_times[0]) if audio_times.size else 0.0,
    )
    expected_period_ms = float(manifest["schedule"]["marker_period_ms"])
    report, pairs = evaluate_markers(
        video_events=flashes,
        audio_events=clicks,
        capture_start_s=capture_start,
        duration_s=duration,
        adapter_offset_ms=float(calibration["audio_minus_video_ms"]),
        expected_period_ms=expected_period_ms,
        min_markers_per_window=args.min_markers_per_window,
        pair_window_ms=args.pair_window_ms,
        max_abs_offset_ms=args.max_abs_offset_ms,
        max_window_span_ms=args.max_window_span_ms,
        max_period_error_ms=args.max_period_error_ms,
        max_interval_error_ms=args.max_interval_error_ms,
        max_offset_step_ms=args.max_offset_step_ms,
        min_paired_coverage=args.min_paired_coverage,
    )
    markers = {
        "schema": "misterplex.external-av.markers.v1",
        "video": {"events_s": flashes, "detection": video_detection},
        "audio": {"events_s": clicks, "detection": audio_detection},
        "pairs": pairs,
    }
    write_json(out_dir / "markers.json", markers)
    report.update(
        {
            "schema": "misterplex.external-av.report.v1",
            "capture": {
                "path": str(capture.resolve()),
                "sha256": sha256_file(capture),
                "bytes": capture.stat().st_size,
                "duration_s": duration,
            },
            "source_rate": manifest["source_rate"],
            "fixture_marker_period_ms": expected_period_ms,
            "calibration": calibration,
            "thresholds": {
                "min_markers_per_window": args.min_markers_per_window,
                "pair_window_ms": args.pair_window_ms,
                "max_abs_offset_ms": args.max_abs_offset_ms,
                "max_window_span_ms": args.max_window_span_ms,
                "max_period_error_ms": args.max_period_error_ms,
                "max_interval_error_ms": args.max_interval_error_ms,
                "max_offset_step_ms": args.max_offset_step_ms,
                "min_paired_coverage": args.min_paired_coverage,
            },
        }
    )
    return report


def prepare_out_dir(path: Path) -> None:
    if path.exists():
        raise ValueError(f"refusing to overwrite existing evidence directory: {path}")
    path.mkdir(parents=True)


def blocked_report(out_dir: Path, reason: str, **details: Any) -> dict[str, Any]:
    report = {
        "schema": "misterplex.external-av.report.v1",
        "status": "BLOCKED",
        "reason": reason,
    }
    report.update(details)
    write_json(out_dir / "report.json", report)
    return report


def run_analysis(args: argparse.Namespace) -> int:
    prepare_out_dir(args.out_dir)
    try:
        manifest = load_manifest(args.fixture_manifest)
        calibration = load_calibration(args.adapter_offset_file, args.adapter_offset_ms)
        write_json(args.out_dir / "fixture_manifest.json", manifest)
        write_json(args.out_dir / "adapter_offset.json", calibration)
        report = analyse_capture(args.analyze, args.out_dir, manifest, calibration, args)
        write_json(args.out_dir / "report.json", report)
        print(json.dumps(report, indent=2))
        return 0 if report["status"] == "PASS" else EXIT_FAIL
    except BlockedError as exc:
        report = blocked_report(args.out_dir, str(exc))
        print(json.dumps(report, indent=2))
        return EXIT_BLOCKED


def capture_command(args: argparse.Namespace, capture: Path) -> list[str]:
    return [
        "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "info",
        "-thread_queue_size",
        "2048",
        "-use_wallclock_as_timestamps",
        "1",
        "-f",
        "v4l2",
        "-input_format",
        args.input_format,
        "-video_size",
        args.video_size,
        "-framerate",
        str(args.framerate),
        "-i",
        args.video_device,
        "-thread_queue_size",
        "2048",
        "-use_wallclock_as_timestamps",
        "1",
        "-f",
        "alsa",
        "-ac",
        str(args.audio_channels),
        "-ar",
        str(args.audio_rate),
        "-i",
        args.audio_device,
        "-copyts",
        "-start_at_zero",
        "-map",
        "0:v:0",
        "-map",
        "1:a:0",
        "-t",
        str(args.duration),
        "-c:v",
        "ffv1",
        "-level",
        "3",
        "-c:a",
        "pcm_s16le",
        str(capture),
    ]


def run_capture(args: argparse.Namespace) -> int:
    prepare_out_dir(args.out_dir)
    try:
        manifest = load_manifest(args.fixture_manifest)
        calibration = load_calibration(
            args.adapter_offset_file,
            args.adapter_offset_ms,
            require_provenance=True,
        )
        inventory = enumerate_inventory()
        write_json(args.out_dir / "inventory.json", inventory)
        video, audio = validate_pair(inventory, args.video_device, args.audio_device)
        validate_calibration_identity(calibration, video)
        write_json(args.out_dir / "fixture_manifest.json", manifest)
        write_json(args.out_dir / "adapter_offset.json", calibration)
        write_json(args.out_dir / "binding.json", {"video": video, "audio": audio})

        device = Path(args.video_device)
        if not device.exists():
            raise BlockedError(f"selected V4L2 endpoint does not exist: {device}")
        owners, complete = owners_of_device(device)
        write_json(
            args.out_dir / "ownership.json",
            {"owners": owners, "inspection_complete": complete},
        )
        if owners:
            raise BlockedError(
                "selected V4L2 endpoint is already open; stop the preview explicitly before capture"
            )
        if not complete:
            raise BlockedError("cannot prove the selected V4L2 endpoint is unowned")

        v4l2 = shutil.which("v4l2-ctl")
        if v4l2:
            probe = subprocess.run(
                [v4l2, "--device", args.video_device, "--list-formats-ext"],
                capture_output=True,
                text=True,
                timeout=20,
            )
            (args.out_dir / "v4l2_formats.txt").write_text(probe.stdout + probe.stderr)

        owners, complete = owners_of_device(device)
        if owners or not complete:
            raise BlockedError("V4L2 ownership changed during setup; capture was not started")

        capture = args.out_dir / "capture.mkv"
        command = capture_command(args, capture)
        write_json(
            args.out_dir / "capture_command.json",
            {"argv": command, "note": "contains device names only; no network credentials"},
        )
        write_json(
            args.out_dir / "environment.json",
            {
                "python": sys.version.split()[0],
                "ffmpeg": command_version("ffmpeg"),
                "ffprobe": command_version("ffprobe"),
                "v4l2_ctl": command_version("v4l2-ctl"),
                "arecord": command_version("arecord"),
            },
        )
        try:
            result = subprocess.run(
                command,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
                timeout=args.duration + 60,
            )
        except subprocess.TimeoutExpired as exc:
            text = exc.stderr if isinstance(exc.stderr, str) else (exc.stderr or b"").decode(errors="replace")
            (args.out_dir / "ffmpeg.stderr.log").write_text(text)
            raise RuntimeError("ffmpeg capture timed out") from exc
        (args.out_dir / "ffmpeg.stderr.log").write_text(result.stderr)
        if result.returncode != 0:
            raise RuntimeError(f"ffmpeg capture failed rc={result.returncode}")
        if not capture.is_file() or capture.stat().st_size == 0:
            raise RuntimeError("ffmpeg returned success without a capture artifact")

        report = analyse_capture(capture, args.out_dir, manifest, calibration, args)
        report["binding"] = {"video": video, "audio": audio}
        write_json(args.out_dir / "report.json", report)
        print(json.dumps(report, indent=2))
        return 0 if report["status"] == "PASS" else EXIT_FAIL
    except BlockedError as exc:
        report = blocked_report(args.out_dir, str(exc))
        print(json.dumps(report, indent=2))
        return EXIT_BLOCKED
    except Exception as exc:
        report = {
            "schema": "misterplex.external-av.report.v1",
            "status": "FAIL",
            "reason": str(exc),
        }
        write_json(args.out_dir / "report.json", report)
        print(json.dumps(report, indent=2))
        return EXIT_FAIL


def run_self_test() -> int:
    fixture = json.loads(SELF_TEST_FIXTURE.read_text())
    failures: list[str] = []
    for case in fixture["cases"]:
        expected_status = case["expected_status"]
        if case.get("audio_events_s") is None:
            got = "BLOCKED"
        else:
            report, _pairs = evaluate_markers(
                video_events=case["video_events_s"],
                audio_events=case["audio_events_s"],
                capture_start_s=0.0,
                duration_s=case["duration_s"],
                adapter_offset_ms=case["adapter_offset_ms"],
                expected_period_ms=case["expected_period_ms"],
                min_markers_per_window=case["min_markers_per_window"],
                pair_window_ms=250.0,
                max_abs_offset_ms=42.0,
                max_window_span_ms=42.0,
                max_period_error_ms=25.0,
                max_interval_error_ms=75.0,
                max_offset_step_ms=42.0,
                min_paired_coverage=0.95,
            )
            got = report["status"]
        if got != expected_status:
            failures.append(f"{case['name']}: expected {expected_status}, got {got}")
        else:
            print(f"PASS {case['name']}: {got}")
    if failures:
        for failure in failures:
            print(f"FAIL {failure}", file=sys.stderr)
        return EXIT_FAIL
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--list-devices", action="store_true")
    mode.add_argument("--capture", action="store_true")
    mode.add_argument("--analyze", type=Path, metavar="CAPTURE")
    mode.add_argument("--self-test", action="store_true")
    parser.add_argument("--out-dir", type=Path)
    parser.add_argument("--fixture-manifest", type=Path)
    parser.add_argument("--adapter-offset-file", type=Path)
    parser.add_argument("--adapter-offset-ms", type=finite_float_arg)
    parser.add_argument("--video-device")
    parser.add_argument("--audio-device")
    parser.add_argument("--input-format", default="mjpeg")
    parser.add_argument("--video-size", default="1280x720")
    parser.add_argument("--framerate", type=positive_float_arg, default=60.0)
    parser.add_argument("--audio-rate", type=positive_int_arg, default=48_000)
    parser.add_argument("--audio-channels", type=positive_int_arg, default=2)
    parser.add_argument("--duration", type=positive_float_arg, default=36.0)
    parser.add_argument("--min-markers-per-window", type=positive_int_arg, default=3)
    parser.add_argument("--pair-window-ms", type=positive_float_arg, default=250.0)
    parser.add_argument("--max-abs-offset-ms", type=positive_float_arg, default=42.0)
    parser.add_argument("--max-window-span-ms", type=positive_float_arg, default=42.0)
    parser.add_argument("--max-period-error-ms", type=positive_float_arg, default=25.0)
    parser.add_argument("--max-interval-error-ms", type=positive_float_arg, default=75.0)
    parser.add_argument("--max-offset-step-ms", type=positive_float_arg, default=42.0)
    parser.add_argument("--min-paired-coverage", type=coverage_arg, default=0.95)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.list_devices:
        print(json.dumps(enumerate_inventory(), indent=2))
        return 0
    if args.self_test:
        return run_self_test()
    if args.out_dir is None or args.fixture_manifest is None:
        parser.error("--out-dir and --fixture-manifest are required")
    if args.capture and (not args.video_device or not args.audio_device):
        parser.error("--capture requires explicit --video-device and --audio-device")
    if args.capture:
        if args.adapter_offset_file is None or args.adapter_offset_ms is not None:
            parser.error(
                "--capture requires --adapter-offset-file; "
                "--adapter-offset-ms is offline analysis only"
            )
    elif (args.adapter_offset_file is None) == (args.adapter_offset_ms is None):
        parser.error("provide exactly one of --adapter-offset-file or --adapter-offset-ms")
    try:
        if args.capture:
            return run_capture(args)
        return run_analysis(args)
    except (OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError) as exc:
        print(f"external_av_sync: ERROR: {exc}", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    raise SystemExit(main())
