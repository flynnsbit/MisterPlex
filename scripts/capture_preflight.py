#!/usr/bin/env python3
"""Capture rig preflight for MiSTerPlex visual gates.

Enumerates /dev/video* nodes, identifies the real HDMI capture node (vs metadata
nodes that enumerate but return no capture formats), negotiates the requested MJPEG
format, grabs N live frames, proves they are not frozen (byte-identical), and
classifies the signal into one of three states that matter to the project:

  CONTENT_PRESENT   live, non-frozen, has picture content (mean luma ≥ threshold)
  BLACK_SIGNAL      live, non-frozen, screen is black (e.g. resident RBF 00eebd5e)
  NO_SIGNAL         live, non-frozen, but only solid colour (HDMI disconnected / no source)

Additional operational states:
  STALE_CAPTURE     N consecutive frames are byte-identical (frozen / buffered stream)
  CAPTURE_ERROR     device opened but capture failed or corrupt buffer
  DEVICE_BUSY       device held exclusively by another process (e.g. OBS)
  NO_DEVICE         no /dev/videoN node found (exit 77 UNSCORED)
  NO_CAPTURE_NODE   nodes found but none support video capture formats (exit 77 UNSCORED)

Exit codes:
  0  PASS   CONTENT_PRESENT
  1  FAIL   BLACK_SIGNAL, NO_SIGNAL, STALE_CAPTURE, CAPTURE_ERROR, DEVICE_BUSY
  77 SKIP   NO_DEVICE, NO_CAPTURE_NODE

Three-question audit:
  (1) What does it literally compare?
      Mean luma and spatial std of the last captured frame; SHA-256 hashes of all
      frames for STALE detection.
  (2) What does it NOT cover?
      Content correctness (that is the visual golden's job), colour accuracy, scan
      timing.  It proves the rig is alive and the signal is non-trivial — nothing
      more.
  (3) Can you make it fail?
      Yes.  --source synthetic --synthetic-case black  → exit 1 (BLACK_SIGNAL)
             --source synthetic --synthetic-case no_signal → exit 1 (NO_SIGNAL)
             --source synthetic --synthetic-case stale     → exit 1 (STALE_CAPTURE)
             --device /dev/nonexistent                     → exit 77 (NO_DEVICE)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Optional

import numpy as np
from PIL import Image

# --------------------------------------------------------------------------- #
# Thresholds
# --------------------------------------------------------------------------- #
# Mean BT.601 luma below this → signal is black (e.g. black-screen RBF state).
# MJPEG codec adds ~1-2 LSB noise even on solid black; threshold kept at 8.
LUMA_BLACK_THRESHOLD: float = 8.0

# Spatial std below this → solid-colour frame, no HDMI picture content.
# Typical live content: std ≥ 15.  JPEG noise on a solid frame: std ≤ 2.
SPATIAL_CONTENT_THRESHOLD: float = 3.0

EXIT_PASS = 0
EXIT_FAIL = 1
EXIT_SKIP = 77

# --------------------------------------------------------------------------- #
# Exceptions
# --------------------------------------------------------------------------- #


class PreflightError(RuntimeError):
    exit_code: int = EXIT_FAIL


class DeviceAbsentError(PreflightError):
    exit_code = EXIT_SKIP


class NoCaptureNodeError(PreflightError):
    exit_code = EXIT_SKIP


class DeviceBusyError(PreflightError):
    exit_code = EXIT_FAIL


class StaleCaptureError(PreflightError):
    exit_code = EXIT_FAIL


class BlackSignalError(PreflightError):
    exit_code = EXIT_FAIL


class NoSignalError(PreflightError):
    exit_code = EXIT_FAIL


# --------------------------------------------------------------------------- #
# Device enumeration
# --------------------------------------------------------------------------- #

CORRUPT_LOG_PATTERNS = (
    "corrupt",
    "v4l2 buffer contains corrupted data",
    "bad buffer",
    "input/output error",
    "cannot dequeue buffer",
    "error submitting packet to decoder",
    "invalid data found when processing input",
)


def _classify_log(stderr: str) -> Optional[str]:
    low = stderr.lower()
    for p in CORRUPT_LOG_PATTERNS:
        if p in low:
            return "corrupt"
    return None


def enumerate_devices() -> list[dict]:
    """Return raw v4l2-ctl --list-devices output as text."""
    try:
        r = subprocess.run(
            ["v4l2-ctl", "--list-devices"],
            capture_output=True, text=True, timeout=8,
        )
        return [{"raw": r.stdout + r.stderr}]
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return [{"raw": "v4l2-ctl not found or timed out"}]


def probe_node_formats(dev: str) -> list[str]:
    """Return list of 4-CC format codes supported by dev, or [] if metadata node."""
    try:
        r = subprocess.run(
            ["v4l2-ctl", "-d", dev, "--list-formats-ext"],
            capture_output=True, text=True, timeout=8,
        )
        text = r.stdout + r.stderr
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return []
    # A metadata/audio node returns "Type: Video Capture" header but no format entries;
    # a real capture node has at least one 'XXXX' entry after the Type line.
    formats = re.findall(r"\[\d+\]:\s+'([A-Z0-9]{3,4})'", text)
    return formats


def find_capture_nodes(preferred: Optional[str] = None) -> list[dict]:
    """Enumerate /dev/videoN; return nodes that support capture formats."""
    video_nodes = sorted(Path("/dev").glob("video*"))
    if not video_nodes:
        return []
    results = []
    for node in video_nodes:
        dev = str(node)
        fmts = probe_node_formats(dev)
        results.append({"dev": dev, "formats": fmts, "is_capture": bool(fmts)})
    return results


def select_capture_node(nodes: list[dict], preferred: Optional[str]) -> dict:
    """Pick the best capture node, preferring MJPG-capable nodes."""
    capture_nodes = [n for n in nodes if n["is_capture"]]
    if not capture_nodes:
        raise NoCaptureNodeError(
            "no /dev/videoN node supports video capture formats; "
            "device is present but has no capture node (check v4l2-ctl --list-formats-ext)"
        )
    if preferred:
        for n in capture_nodes:
            if n["dev"] == preferred:
                return n
        # Preferred was specified but not found among capture nodes
        raise PreflightError(
            f"requested device {preferred} is not a capture node or does not exist; "
            f"available capture nodes: {[n['dev'] for n in capture_nodes]}"
        )
    for n in capture_nodes:
        if "MJPG" in n["formats"]:
            return n
    return capture_nodes[0]


def check_busy(dev: str) -> None:
    """Raise DeviceBusyError if fuser shows exclusive holders."""
    try:
        r = subprocess.run(["fuser", dev], capture_output=True, text=True, timeout=5)
        # fuser output may include mode letters after PIDs (m=mmap, e=exec, f=open, etc.)
        # Extract only the numeric PID part from tokens like "180999m" or "12345"
        raw = (r.stdout + r.stderr).strip()
        if r.returncode == 0 and raw:
            pids = re.findall(r'\b(\d+)', raw)
            if pids:
                cmdlines = []
                for pid in pids[:3]:
                    try:
                        cl = (Path(f"/proc/{pid}/cmdline")
                              .read_bytes()
                              .replace(b"\x00", b" ")
                              .decode(errors="replace")
                              .strip())
                        cmdlines.append(f"{pid}:{cl[:40]}")
                    except OSError:
                        cmdlines.append(pid)
                raise DeviceBusyError(
                    f"capture device {dev} is held exclusively by: {'; '.join(cmdlines)}"
                )
    except FileNotFoundError:
        pass  # fuser not installed; attempt capture and let ffmpeg fail naturally


# --------------------------------------------------------------------------- #
# Frame capture
# --------------------------------------------------------------------------- #


def _parse_negotiated_format(log: str) -> dict:
    """Extract actually negotiated codec/size/fps from ffmpeg informational output."""
    m = re.search(
        r"Stream #0:0[^:]*: Video:\s+(\S+)[^\n]*?,\s*[^\n]*?(\d+x\d+)[^\n]*?(\d+(?:\.\d+)?)\s+fps",
        log, re.IGNORECASE,
    )
    if m:
        return {"codec": m.group(1).rstrip(","), "size": m.group(2), "fps": m.group(3)}
    # Fallback: just look for WxH
    m2 = re.search(r"(\d{3,4}x\d{3,4})", log)
    return {"codec": "unknown", "size": m2.group(1) if m2 else "unknown", "fps": "unknown"}


def grab_frame(dev: str, fmt: str, size: str, fps: str, out: Path) -> tuple[np.ndarray, str, dict]:
    """Grab one frame via v4l2.  Returns (image, ffmpeg_log, negotiated_format)."""
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "info",
        "-f", "v4l2",
        "-input_format", fmt,
        "-video_size", size,
        "-framerate", fps,
        "-i", dev,
        "-vf", "format=rgb24",
        "-frames:v", "1",
        "-update", "1",
        "-y", str(out),
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=45)
    except FileNotFoundError:
        raise PreflightError("ffmpeg not found; cannot capture HDMI")
    log = (r.stderr + r.stdout).strip()
    if r.returncode != 0 or not out.exists() or out.stat().st_size == 0:
        raise PreflightError(
            f"ffmpeg capture failed for {dev} "
            f"({fmt} {size}@{fps}fps) rc={r.returncode}: {log[:500]}"
        )
    if _classify_log(log) == "corrupt":
        raise PreflightError(f"V4L2/ffmpeg reported corrupted buffer on {dev}: {log[:300]}")
    negotiated = _parse_negotiated_format(log)
    arr = np.array(Image.open(out).convert("RGB"), dtype=np.uint8)
    return arr, log, negotiated


def grab_n_frames(dev: str, fmt: str, size: str, fps: str,
                  n: int, out_dir: Path) -> tuple[list[np.ndarray], str, dict]:
    """Grab N frames.  Returns (frames, last_log, negotiated_format)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    frames: list[np.ndarray] = []
    last_log = ""
    negotiated: dict = {}
    for i in range(n):
        out = out_dir / f"preflight_{i}.png"
        frame, log, neg = grab_frame(dev, fmt, size, fps, out)
        frames.append(frame)
        last_log = log
        if not negotiated:
            negotiated = neg
    return frames, last_log, negotiated


# --------------------------------------------------------------------------- #
# Signal classification
# --------------------------------------------------------------------------- #


def frame_sha(arr: np.ndarray) -> str:
    return hashlib.sha256(arr.tobytes()).hexdigest()[:16]


def mean_luma_bt601(frame: np.ndarray) -> float:
    r = frame[..., 0].astype(np.float64)
    g = frame[..., 1].astype(np.float64)
    b = frame[..., 2].astype(np.float64)
    return float((0.299 * r + 0.587 * g + 0.114 * b).mean())


def spatial_std(frame: np.ndarray) -> float:
    return float(frame.astype(np.float64).std())


def classify_signal(frames: list[np.ndarray]) -> dict:
    """Classify signal state from N captured frames.

    Returns a dict with keys: state, note, mean_luma, spatial_std, unique_hashes.
    Caller converts state to exit code.

    Classification order (important):
      1. Luma    → BLACK_SIGNAL  (stable black frames from 00eebd5e RBF are byte-identical;
                                  STALE check must not mask this — low-entropy MJPEG encodes
                                  black content to the same bytes every time)
      2. Spatial → NO_SIGNAL     (solid-colour frame = no HDMI signal)
      3. STALE   → STALE_CAPTURE (byte-identical frames that are NOT black and NOT no-signal
                                  = genuinely frozen picture of real content)
      4. Otherwise CONTENT_PRESENT
    """
    hashes = [frame_sha(f) for f in frames]
    unique = len(set(hashes))
    total = len(frames)

    frame = frames[-1]
    luma = mean_luma_bt601(frame)
    std = spatial_std(frame)

    # Check luma FIRST — a black-screen RBF produces stable MJPEG output where
    # all N frames may share the same SHA-256 prefix.  STALE before luma would
    # incorrectly report STALE_CAPTURE for a valid-but-black signal.
    if luma < LUMA_BLACK_THRESHOLD:
        return {
            "state": "BLACK_SIGNAL",
            "unique_hashes": unique,
            "total_frames": total,
            "mean_luma": round(luma, 2),
            "spatial_std": round(std, 2),
            "note": (
                f"signal is black (mean luma {luma:.2f} < threshold {LUMA_BLACK_THRESHOLD}); "
                "HDMI source is outputting a black screen. "
                "Known cause: resident RBF 00eebd5e (frame-store livelock, no picture delivered)."
            ),
        }

    if std < SPATIAL_CONTENT_THRESHOLD:
        return {
            "state": "NO_SIGNAL",
            "unique_hashes": unique,
            "total_frames": total,
            "mean_luma": round(luma, 2),
            "spatial_std": round(std, 2),
            "note": (
                f"solid-colour frame (spatial std {std:.2f} < threshold {SPATIAL_CONTENT_THRESHOLD}); "
                "HDMI input may be disconnected or the source has no active output"
            ),
        }

    # STALE: only meaningful with ≥2 frames and only for content-level (non-black, non-flat)
    # frames.  With a single frame, unique==1 is trivially true.
    if total >= 2 and unique == 1:
        return {
            "state": "STALE_CAPTURE",
            "unique_hashes": unique,
            "total_frames": total,
            "mean_luma": round(luma, 2),
            "spatial_std": round(std, 2),
            "note": (
                f"all {total} captured frames are byte-identical (same SHA-256 prefix) "
                f"but luma ({luma:.2f}) and spatial std ({std:.2f}) indicate real content; "
                "stream is frozen, buffered, or the device is returning a cached frame"
            ),
        }

    return {
        "state": "CONTENT_PRESENT",
        "unique_hashes": unique,
        "total_frames": total,
        "mean_luma": round(luma, 2),
        "spatial_std": round(std, 2),
        "note": (
            f"live signal with picture content "
            f"(mean luma {luma:.2f} ≥ {LUMA_BLACK_THRESHOLD}, "
            f"spatial std {std:.2f} ≥ {SPATIAL_CONTENT_THRESHOLD})"
        ),
    }


# --------------------------------------------------------------------------- #
# Synthetic sources (for unit testing without live hardware)
# --------------------------------------------------------------------------- #


def synthetic_frame(case: str) -> np.ndarray:
    """Return a 320x240 synthetic frame for the given test case."""
    h, w = 240, 320
    if case == "content":
        frame = np.zeros((h, w, 3), dtype=np.uint8)
        # Gradient + markers: definitely above both luma and std thresholds
        for y in range(h):
            for x in range(w):
                frame[y, x] = [
                    int(x * 255 / w),
                    int(y * 255 / h),
                    128,
                ]
        return frame
    if case == "black":
        # Pure black: luma=0 → BLACK_SIGNAL
        return np.zeros((h, w, 3), dtype=np.uint8)
    if case == "no_signal":
        # Solid grey: luma≈128, std≈0 → NO_SIGNAL
        return np.full((h, w, 3), 128, dtype=np.uint8)
    if case == "stale":
        # Content-level gradient, pixel-identical across frames — ensures STALE check
        # is reached (luma ≥ threshold, spatial std ≥ threshold, but all frames frozen).
        # Using the same gradient as "content" ensures we exercise the STALE branch, not
        # the NO_SIGNAL branch (which would fire for a solid-colour stale frame).
        frame = np.zeros((h, w, 3), dtype=np.uint8)
        for y in range(h):
            for x in range(w):
                frame[y, x] = [int(x * 255 / w), int(y * 255 / h), 128]
        return frame
    raise ValueError(f"unknown synthetic case: {case!r}")


def load_synthetic_frames(case: str, n: int) -> list[np.ndarray]:
    frame = synthetic_frame(case)
    if case == "stale":
        return [frame.copy() for _ in range(n)]
    # For non-stale cases, vary each frame slightly so hashes differ:
    # the signal classification is on content, not stale-ness.
    frames = []
    for i in range(n):
        f = frame.copy()
        if case != "black" and case != "no_signal":
            # Add a tiny unique pixel so hashes differ but content is still representative
            f[0, 0, 0] = (int(f[0, 0, 0]) + i) & 0xFF
        else:
            # For black/no_signal, vary a single subpixel at an edge pixel
            f[0, 0, 0] = (int(f[0, 0, 0]) + i) & 0xFF
        frames.append(f)
    return frames


def load_file_frames(inputs: list[str]) -> list[np.ndarray]:
    frames = []
    for path in inputs:
        try:
            arr = np.array(Image.open(path).convert("RGB"), dtype=np.uint8)
        except Exception as e:
            raise PreflightError(f"could not load frame {path}: {e}") from e
        frames.append(arr)
    return frames


# --------------------------------------------------------------------------- #
# Main preflight logic
# --------------------------------------------------------------------------- #


def run_preflight(args: argparse.Namespace) -> int:
    """Run the full preflight.  Returns exit code."""
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    result: dict = {
        "requested_device": args.device,
        "requested_format": args.input_format,
        "requested_size": args.video_size,
        "requested_fps": args.framerate,
        "source": args.source,
        "frames_requested": args.frames,
    }

    # ------------------------------------------------------------------ #
    # Synthetic / file-backed paths (no hardware required)
    # ------------------------------------------------------------------ #
    if args.source == "synthetic":
        frames = load_synthetic_frames(args.synthetic_case, args.frames)
        result["device_enumeration"] = "synthetic"
        result["selected_node"] = "synthetic"
        result["negotiated_format"] = {"codec": "synthetic", "size": "320x240", "fps": "N/A"}
        classification = classify_signal(frames)
        result["signal"] = classification
        _print_report(result, classification)
        return _signal_exit_code(classification)

    if args.source == "file":
        if not args.input:
            print("FAIL: --source file requires --input paths", file=sys.stderr)
            return EXIT_FAIL
        frames = load_file_frames(args.input)
        result["device_enumeration"] = "file"
        result["selected_node"] = args.input[-1]
        result["negotiated_format"] = {"codec": "file", "size": "from_file", "fps": "N/A"}
        classification = classify_signal(frames)
        result["signal"] = classification
        _print_report(result, classification)
        return _signal_exit_code(classification)

    # ------------------------------------------------------------------ #
    # Live v4l2 path
    # ------------------------------------------------------------------ #
    # Step 1: Enumerate
    all_nodes = find_capture_nodes(args.device)
    result["all_nodes"] = all_nodes
    result["device_enumeration"] = enumerate_devices()[0]["raw"].strip()

    if not any(n["is_capture"] or Path(n["dev"]).exists() for n in all_nodes):
        # No /dev/video* nodes at all
        msg = "no /dev/video* nodes found; capture hardware is absent"
        result["error"] = msg
        print(f"SKIP: {msg}", file=sys.stderr)
        _write_report(out_dir, result)
        return EXIT_SKIP

    # Step 2: Select capture node
    try:
        node = select_capture_node(all_nodes, args.device)
    except NoCaptureNodeError as e:
        result["error"] = str(e)
        print(f"SKIP: {e}", file=sys.stderr)
        _write_report(out_dir, result)
        return EXIT_SKIP
    except PreflightError as e:
        result["error"] = str(e)
        print(f"FAIL: {e}", file=sys.stderr)
        _write_report(out_dir, result)
        return EXIT_FAIL

    result["selected_node"] = node["dev"]
    result["supported_formats"] = node["formats"]

    # Print full node enumeration with acceptance/rejection evidence
    # (the parent's key concern: /dev/video1 must be rejected on format evidence, not by index)
    capture_nodes = [n for n in all_nodes if n["is_capture"]]
    rejected_nodes = [n for n in all_nodes if not n["is_capture"]]
    for n in rejected_nodes:
        print(f"  NODE {n['dev']}: REJECTED  no capture formats (metadata/audio node per v4l2-ctl --list-formats-ext)")
    for n in capture_nodes:
        marker = "SELECTED" if n["dev"] == node["dev"] else "candidate"
        print(f"  NODE {n['dev']}: {marker}  formats={n['formats']}")
    print(f"Scope: 1 device ({node['dev']}), formats={node['formats']}")

    # Step 3: Busy check
    try:
        check_busy(node["dev"])
    except DeviceBusyError as e:
        result["error"] = str(e)
        print(f"FAIL: {e}", file=sys.stderr)
        _write_report(out_dir, result)
        return EXIT_FAIL

    # Step 4: Grab N frames and report negotiated format
    try:
        frames, log, negotiated = grab_n_frames(
            node["dev"], args.input_format, args.video_size,
            args.framerate, args.frames, out_dir / "frames",
        )
    except PreflightError as e:
        result["error"] = str(e)
        print(f"FAIL: {e}", file=sys.stderr)
        _write_report(out_dir, result)
        return EXIT_FAIL

    result["negotiated_format"] = negotiated
    requested = f"{args.input_format} {args.video_size}@{args.framerate}fps"
    actual = f"{negotiated.get('codec','?')} {negotiated.get('size','?')}@{negotiated.get('fps','?')}fps"
    print(f"NEGOTIATED: requested={requested}  actual={actual}")

    # Step 5: Classify signal
    classification = classify_signal(frames)
    result["signal"] = classification
    _print_report(result, classification)
    _write_report(out_dir, result)
    return _signal_exit_code(classification)


def _signal_exit_code(classification: dict) -> int:
    state = classification["state"]
    if state == "CONTENT_PRESENT":
        return EXIT_PASS
    return EXIT_FAIL


def _print_report(result: dict, classification: dict) -> None:
    state = classification["state"]
    luma = classification.get("mean_luma")
    std = classification.get("spatial_std")
    unique = classification.get("unique_hashes")
    total = classification.get("total_frames")
    print(f"SIGNAL_STATE: {state}")
    if luma is not None:
        print(f"  mean_luma={luma}  spatial_std={std}  unique_frames={unique}/{total}")
    print(f"  note: {classification['note']}")
    neg = result.get("negotiated_format", {})
    if neg:
        print(f"  negotiated_format: codec={neg.get('codec')} size={neg.get('size')} fps={neg.get('fps')}")


def _write_report(out_dir: Path, result: dict) -> None:
    rpt = out_dir / "preflight_report.json"
    try:
        rpt.write_text(json.dumps(result, indent=2, default=str) + "\n", encoding="utf-8")
    except OSError:
        pass


def cmd_detect(preferred: Optional[str] = None) -> int:
    """Enumerate capture nodes and print the best one.

    Prints exactly one line: the selected device path (e.g. /dev/video0).
    Exit 77 if no capture node found.  Intended for shell script substitution:
        HDMI_DEV=$(python3 scripts/capture_preflight.py detect)
    """
    all_nodes = find_capture_nodes(preferred=preferred)
    if not all_nodes:
        print("SKIP: no /dev/video* nodes; capture hardware absent", file=sys.stderr)
        return EXIT_SKIP
    try:
        node = select_capture_node(all_nodes, preferred)
    except (NoCaptureNodeError, DeviceAbsentError) as e:
        print(f"SKIP: {e}", file=sys.stderr)
        return EXIT_SKIP
    except PreflightError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return EXIT_FAIL
    print(node["dev"])
    return EXIT_PASS


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="subcmd")

    # detect subcommand: just print the best capture device path and exit
    det = sub.add_parser("detect", help="print best capture device path and exit (77 if absent)")
    det.add_argument("--device", default=None)

    ap.add_argument("--source", choices=("v4l2", "synthetic", "file"), default="v4l2",
                    help="frame source (default: v4l2 for live capture)")
    ap.add_argument("--synthetic-case", choices=("content", "black", "no_signal", "stale"),
                    default="content",
                    help="synthetic test case (only used with --source synthetic)")
    ap.add_argument("--input", action="append", default=[],
                    help="file-backed frame paths (only used with --source file)")
    ap.add_argument("--device", default=None,
                    help="specific capture device to use; if omitted, best MJPG node is selected")
    ap.add_argument("--input-format", default="mjpeg",
                    help="v4l2 input format to request (default: mjpeg)")
    ap.add_argument("--video-size", default="1280x720",
                    help="resolution to request (default: 1280x720)")
    ap.add_argument("--framerate", default="60",
                    help="frame rate to request (default: 60)")
    ap.add_argument("--frames", type=int, default=3,
                    help="number of frames to grab for liveness check (default: 3)")
    ap.add_argument("--out-dir", default="build/capture_preflight",
                    help="directory for captured frames and JSON report")
    return ap


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.subcmd == "detect":
            return cmd_detect(getattr(args, "device", None))
        return run_preflight(args)
    except PreflightError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return e.exit_code
    except KeyboardInterrupt:
        return EXIT_FAIL


if __name__ == "__main__":
    raise SystemExit(main())
