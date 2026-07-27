#!/usr/bin/env python3
"""MiSTerPlex hardware visual-regression capture comparator.

This tool is intentionally geometry-aware. It reads the 480p DDR frame geometry
from the shared host/RTL layout headers, compares only the displayed picture
region, and reports quantified pixel errors plus a side-by-side diff artifact.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
HOST_LAYOUT = ROOT / "host" / "libmisterplex" / "ddr_frame_layout.hpp"
RTL_LAYOUT = ROOT / "fpga" / "Plex_MiSTer" / "rtl" / "ddr_frame_layout_params.svh"
DEFAULT_DEV = "/dev/video4"
DEFAULT_FORMAT = "mjpeg"
DEFAULT_SIZE = "1280x720"
DEFAULT_FPS = "60"
DEFAULT_WARMUP = 60
DEFAULT_ATTEMPTS = 5


class HarnessError(RuntimeError):
    exit_code = 2


class StaleCaptureError(HarnessError):
    exit_code = 3


class CorruptCaptureError(HarnessError):
    exit_code = 4


class CaptureAbsentError(HarnessError):
    exit_code = 5


class CaptureBusyError(HarnessError):
    exit_code = 6


CORRUPT_LOG_PATTERNS = (
    "corrupt",
    "v4l2 buffer contains corrupted data",
    "bad buffer",
    "input/output error",
    "cannot dequeue buffer",
    "error submitting packet to decoder",
    "invalid data found when processing input",
)


def classify_capture_log(stderr: str) -> str | None:
    """Return a capture-integrity class for ffmpeg/v4l2 stderr, if any."""
    low = stderr.lower()
    for pat in CORRUPT_LOG_PATTERNS:
        if pat in low:
            return "corrupt"
    return None


def reject_corrupt_capture_log(path: str | None) -> None:
    """Reject externally captured frames when their ffmpeg/V4L2 log is corrupt."""
    if not path:
        return
    p = Path(path)
    log = p.read_text(encoding="utf-8", errors="replace")
    if classify_capture_log(log) == "corrupt":
        raise CorruptCaptureError(
            f"capture log {p} reports corrupted V4L2/FFmpeg data; not grading image"
        )


@dataclass(frozen=True)
class Geometry:
    coded_width: int
    coded_height: int
    display_width: int
    display_height: int
    presented_width: int
    presented_height: int
    crop_left: int
    crop_right: int
    crop_top: int
    crop_bottom: int
    pillarbox_left: int
    pillarbox_right: int

    @property
    def active_box(self) -> tuple[int, int, int, int]:
        x0 = self.pillarbox_left
        y0 = 0
        return (x0, y0, x0 + self.display_width, y0 + self.display_height)


def _parse_cpp_constants(path: Path) -> dict[str, int]:
    text = path.read_text(encoding="utf-8")
    out: dict[str, int] = {}
    for name, value in re.findall(r"constexpr\s+int\s+kPlex480p([A-Za-z0-9_]+)\s*=\s*([^;]+);", text):
        value = value.strip()
        if value.startswith("0x"):
            out[name] = int(value, 16)
        else:
            out[name] = int(value)
    return out


def _parse_svh_constants(path: Path) -> dict[str, int]:
    text = path.read_text(encoding="utf-8")
    out: dict[str, int] = {}
    for name, value in re.findall(r"localparam\s+int\s+DDR_FRAME_([A-Z0-9_]+)\s*=\s*([^;]+);", text):
        value = value.strip().replace("_", "")
        if "'h" in value:
            out[name] = int(value.split("'h", 1)[1], 16)
        elif value.startswith("32'h"):
            out[name] = int(value[4:], 16)
        else:
            out[name] = int(value, 0)
    return out


def load_geometry() -> Geometry:
    cpp = _parse_cpp_constants(HOST_LAYOUT)
    svh = _parse_svh_constants(RTL_LAYOUT)
    pairs = {
        "CodedWidth": "CODED_WIDTH",
        "CodedHeight": "CODED_HEIGHT",
        "DisplayWidth": "DISPLAY_WIDTH",
        "DisplayHeight": "DISPLAY_HEIGHT",
        "PresentedWidth": "PRESENTED_WIDTH",
        "PresentedHeight": "PRESENTED_HEIGHT",
        "CropLeft": "CROP_LEFT",
        "CropRight": "CROP_RIGHT",
        "CropTop": "CROP_TOP",
        "CropBottom": "CROP_BOTTOM",
        "PillarboxLeft": "PILLARBOX_LEFT",
        "PillarboxRight": "PILLARBOX_RIGHT",
    }
    for c_name, r_name in pairs.items():
        if c_name not in cpp:
            raise HarnessError(f"missing {c_name} in {HOST_LAYOUT}")
        if r_name not in svh:
            raise HarnessError(f"missing {r_name} in {RTL_LAYOUT}")
        if cpp[c_name] != svh[r_name]:
            raise HarnessError(
                f"layout divergence {c_name}/{r_name}: host={cpp[c_name]} rtl={svh[r_name]}"
            )
    g = Geometry(
        coded_width=cpp["CodedWidth"],
        coded_height=cpp["CodedHeight"],
        display_width=cpp["DisplayWidth"],
        display_height=cpp["DisplayHeight"],
        presented_width=cpp["PresentedWidth"],
        presented_height=cpp["PresentedHeight"],
        crop_left=cpp["CropLeft"],
        crop_right=cpp["CropRight"],
        crop_top=cpp["CropTop"],
        crop_bottom=cpp["CropBottom"],
        pillarbox_left=cpp["PillarboxLeft"],
        pillarbox_right=cpp["PillarboxRight"],
    )
    if g.display_width + g.crop_left + g.crop_right != g.coded_width:
        raise HarnessError(f"invalid crop geometry: {g}")
    if g.pillarbox_left + g.display_width + g.pillarbox_right != g.presented_width:
        raise HarnessError(f"invalid pillarbox geometry: {g}")
    return g


def load_rgb(path: Path, g: Geometry) -> np.ndarray:
    try:
        im = Image.open(path).convert("RGB")
    except Exception as e:
        raise HarnessError(f"could not load image {path}: {e}") from e
    if im.size != (g.presented_width, g.presented_height):
        im = im.resize((g.presented_width, g.presented_height), Image.Resampling.BILINEAR)
    return np.array(im, dtype=np.uint8)


def save_rgb(path: Path, frame: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(np.clip(frame, 0, 255).astype(np.uint8), "RGB").save(path)


def capture_v4l2_once(path: Path, dev: str, input_format: str, size: str, framerate: str,
                      warmup: int) -> tuple[np.ndarray | None, str, int]:
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "warning",
        "-f", "v4l2", "-input_format", input_format, "-video_size", size,
        "-framerate", framerate, "-i", dev,
        "-vf", f"select=gte(n\\,{warmup})", "-frames:v", "1", "-update", "1",
        "-y", str(path),
    ]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=30 + warmup)
    log = (r.stderr or r.stdout or "").strip()
    if r.returncode != 0 or not path.exists() or path.stat().st_size == 0:
        return None, log, r.returncode
    if classify_capture_log(log) == "corrupt":
        return None, log, 4
    return np.array(Image.open(path).convert("RGB"), dtype=np.uint8), log, 0


def capture_v4l2(path: Path, dev: str, input_format: str, size: str, framerate: str,
                 warmup: int, attempts: int) -> np.ndarray:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not Path(dev).exists():
        raise CaptureAbsentError(f"capture device {dev} is absent")
    try:
        busy = subprocess.run(["fuser", dev], capture_output=True, text=True, timeout=5)
        holders = (busy.stdout + busy.stderr).strip()
        if busy.returncode == 0 and holders:
            raise CaptureBusyError(f"capture device {dev} is busy/exclusive-open ({holders})")
    except FileNotFoundError:
        pass
    corrupt_logs: list[str] = []
    other_logs: list[str] = []
    for attempt in range(1, attempts + 1):
        frame, log, rc = capture_v4l2_once(path, dev, input_format, size, framerate, warmup)
        if frame is not None:
            if attempt > 1:
                print(f"capture recovered after {attempt - 1} corrupt/failed attempt(s)",
                      file=sys.stderr)
            return frame
        if classify_capture_log(log) == "corrupt" or rc == 4:
            corrupt_logs.append(f"attempt {attempt}: {log}")
        else:
            other_logs.append(f"attempt {attempt}: rc={rc} {log}")
    if corrupt_logs:
        raise CorruptCaptureError(
            f"V4L2/ffmpeg reported corrupted capture data for {dev} "
            f"({input_format} {size}@{framerate}) on all usable attempts; "
            f"not grading. last log: {corrupt_logs[-1]}"
        )
    raise HarnessError(
        f"ffmpeg capture failed for {dev} ({input_format} {size}@{framerate}); "
        f"last log: {other_logs[-1] if other_logs else 'no attempts'}"
    )


def parse_compare_box(spec: str | None, g: Geometry) -> tuple[int, int, int, int]:
    if not spec or spec == "active":
        return g.active_box
    try:
        x, y, w, h = [int(p) for p in spec.split(",")]
    except ValueError as e:
        raise HarnessError(f"invalid compare box {spec!r}; expected x,y,w,h") from e
    x0, y0, x1, y1 = x, y, x + w, y + h
    if x0 < 0 or y0 < 0 or w <= 0 or h <= 0 or x1 > g.presented_width or y1 > g.presented_height:
        raise HarnessError(
            f"compare box {spec!r} outside presented frame {g.presented_width}x{g.presented_height}"
        )
    return x0, y0, x1, y1


def active_view(frame: np.ndarray, g: Geometry,
                box: tuple[int, int, int, int] | None = None) -> np.ndarray:
    x0, y0, x1, y1 = box if box else g.active_box
    return frame[y0:y1, x0:x1, :]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rgb_to_yuv601(rgb: np.ndarray) -> np.ndarray:
    r = rgb[..., 0].astype(np.float64)
    g = rgb[..., 1].astype(np.float64)
    b = rgb[..., 2].astype(np.float64)
    y = 0.299 * r + 0.587 * g + 0.114 * b
    u = -0.168736 * r - 0.331264 * g + 0.5 * b + 128.0
    v = 0.5 * r - 0.418688 * g - 0.081312 * b + 128.0
    return np.clip(np.rint(np.stack([y, u, v], axis=-1)), 0, 255).astype(np.int16)


def diff_stats(golden: np.ndarray, captured: np.ndarray, g: Geometry,
               box: tuple[int, int, int, int] | None = None) -> dict:
    ga = active_view(golden, g, box).astype(np.int16)
    ca = active_view(captured, g, box).astype(np.int16)
    if ga.shape != ca.shape:
        raise HarnessError(f"active region shape mismatch golden={ga.shape} captured={ca.shape}")
    diff = ca - ga
    ad = np.abs(diff)
    per_plane_mae = ad.reshape(-1, 3).mean(axis=0)
    per_plane_exact = (ad == 0).reshape(-1, 3).sum(axis=0)
    per_plane_max = ad.reshape(-1, 3).max(axis=0)
    gy = rgb_to_yuv601(ga)
    cy = rgb_to_yuv601(ca)
    yuv_ad = np.abs(cy - gy)
    yuv_mae = yuv_ad.reshape(-1, 3).mean(axis=0)
    yuv_exact = (yuv_ad == 0).reshape(-1, 3).sum(axis=0)
    yuv_max = yuv_ad.reshape(-1, 3).max(axis=0)
    exact = np.all(ad == 0, axis=2)
    worst_flat = int(np.argmax(ad))
    wy, wx, wc = np.unravel_index(worst_flat, ad.shape)
    x0, y0, _x1, _y1 = box if box else g.active_box
    return {
        "active_pixels": int(exact.size),
        "exact_match_pixels": int(exact.sum()),
        "exact_match_ratio": float(exact.sum() / exact.size),
        "per_plane_exact_match_pixels_rgb": [int(x) for x in per_plane_exact],
        "per_plane_exact_match_ratio_rgb": [float(x / exact.size) for x in per_plane_exact],
        "per_plane_mae_rgb": [float(x) for x in per_plane_mae],
        "per_plane_max_abs_rgb": [int(x) for x in per_plane_max],
        "per_plane_exact_match_pixels_yuv": [int(x) for x in yuv_exact],
        "per_plane_exact_match_ratio_yuv": [float(x / exact.size) for x in yuv_exact],
        "per_plane_mae_yuv": [float(x) for x in yuv_mae],
        "per_plane_max_abs_yuv": [int(x) for x in yuv_max],
        "overall_mae": float(ad.mean()),
        "max_abs": int(ad[wy, wx, wc]),
        "worst": {
            "x_presented": int(x0 + wx),
            "y_presented": int(y0 + wy),
            "x_display": int(wx),
            "y_display": int(wy),
            "plane": "RGB"[wc],
            "golden": int(ga[wy, wx, wc]),
            "captured": int(ca[wy, wx, wc]),
            "delta": int(diff[wy, wx, wc]),
        },
    }


def diff_artifact(golden: np.ndarray, captured: np.ndarray, g: Geometry, out: Path,
                  box: tuple[int, int, int, int] | None = None) -> None:
    x0, y0, x1, y1 = box if box else g.active_box
    gg = golden.copy()
    cc = captured.copy()
    # Highlight compared active rectangle without altering the interior.
    for frame, color in ((gg, np.array([0, 255, 0], dtype=np.uint8)),
                         (cc, np.array([0, 255, 0], dtype=np.uint8))):
        frame[y0:y1, x0:x0 + 1] = color
        frame[y0:y1, x1 - 1:x1] = color
        frame[y0:y0 + 1, x0:x1] = color
        frame[y1 - 1:y1, x0:x1] = color
    d = np.zeros_like(golden)
    active_diff = np.abs(active_view(captured, g, box).astype(np.int16) -
                         active_view(golden, g, box).astype(np.int16))
    d[y0:y1, x0:x1, :] = np.clip(active_diff * 8, 0, 255).astype(np.uint8)
    sep = np.full((g.presented_height, 8, 3), 32, dtype=np.uint8)
    tiled = np.concatenate([gg, sep, cc, sep, d], axis=1)
    save_rgb(out, tiled)


def measured_noise(frames: list[np.ndarray], g: Geometry,
                   box: tuple[int, int, int, int] | None = None) -> dict:
    if len(frames) < 2:
        raise HarnessError("noise measurement needs at least two frames")
    base = active_view(frames[0], g, box).astype(np.int16)
    maes = []
    worst = 0
    exact = []
    hashes = []
    for fr in frames:
        hashes.append(hashlib.sha256(fr.tobytes()).hexdigest())
    for fr in frames[1:]:
        cur = active_view(fr, g, box).astype(np.int16)
        ad = np.abs(cur - base)
        maes.append(ad.reshape(-1, 3).mean(axis=0))
        worst = max(worst, int(ad.max()))
        exact.append(int(np.all(ad == 0, axis=2).sum()))
    arr = np.array(maes, dtype=np.float64)
    max_mae = arr.max(axis=0) if arr.size else np.zeros(3)
    # Threshold is measured floor plus one code value. HDMI often measures zero;
    # analogue capture gets the measured spread with margin.
    plane_thresholds = np.maximum(1.0, max_mae * 3.0 + 1.0)
    max_abs_threshold = max(2, worst * 3 + 2)
    return {
        "frames": len(frames),
        "unique_hashes": len(set(hashes)),
        "active_pixels": int(base.shape[0] * base.shape[1]),
        "max_pair_mae_rgb": [float(x) for x in max_mae],
        "max_abs_noise": int(worst),
        "exact_match_pixels_vs_first": exact,
        "threshold_mae_rgb": [float(x) for x in plane_thresholds],
        "threshold_max_abs": int(max_abs_threshold),
    }


def compare_ok(stats: dict, noise: dict | None, max_mae: float | None, max_abs: int | None) -> bool:
    maes = stats["per_plane_mae_rgb"]
    if noise:
        mae_limits = noise["threshold_mae_rgb"]
        abs_limit = int(noise["threshold_max_abs"])
    else:
        mae_limits = [max_mae if max_mae is not None else 0.0] * 3
        abs_limit = max_abs if max_abs is not None else 0
    return all(maes[i] <= mae_limits[i] for i in range(3)) and stats["max_abs"] <= abs_limit


def cmd_geometry(_args: argparse.Namespace) -> int:
    print(json.dumps(asdict(load_geometry()), indent=2, sort_keys=True))
    return 0


def cmd_capture(args: argparse.Namespace) -> int:
    capture_v4l2(Path(args.out), args.device, args.input_format, args.video_size,
                 args.framerate, args.warmup, args.attempts)
    print(f"captured {args.out} ({args.input_format} {args.video_size}@{args.framerate})")
    return 0


def cmd_noise(args: argparse.Namespace) -> int:
    g = load_geometry()
    box = parse_compare_box(args.compare_box, g)
    frames = [load_rgb(Path(p), g) for p in args.frames]
    report = measured_noise(frames, g, box)
    report["geometry"] = asdict(g)
    report["compare_box"] = list(box)
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


def cmd_compare(args: argparse.Namespace) -> int:
    g = load_geometry()
    box = parse_compare_box(args.compare_box, g)
    reject_corrupt_capture_log(args.capture_log)
    golden = load_rgb(Path(args.golden), g)
    captured = load_rgb(Path(args.capture), g)
    freshness = None
    if args.previous:
        prev = load_rgb(Path(args.previous), g)
        if np.array_equal(prev, captured):
            raise StaleCaptureError(
                "STALE capture: current frame is byte-identical to previous condition"
            )
        freshness = {
            "previous": str(args.previous),
            "previous_sha256": hashlib.sha256(prev.tobytes()).hexdigest(),
            "capture_sha256": hashlib.sha256(captured.tobytes()).hexdigest(),
            "byte_identical": False,
        }
    stats = diff_stats(golden, captured, g, box)
    noise = None
    if args.noise_report:
        noise = json.loads(Path(args.noise_report).read_text(encoding="utf-8"))
    ok = compare_ok(stats, noise, args.max_mae, args.max_abs)
    report = {
        "ok": ok,
        "golden": str(args.golden),
        "capture": str(args.capture),
        "capture_log": str(args.capture_log) if args.capture_log else None,
        "geometry": asdict(g),
        "compare_box": list(box),
        "freshness": freshness,
        "stats": stats,
        "thresholds": {
            "source": str(args.noise_report) if args.noise_report else "cli",
            "mae_rgb": noise["threshold_mae_rgb"] if noise else [args.max_mae] * 3,
            "max_abs": noise["threshold_max_abs"] if noise else args.max_abs,
        },
    }
    if args.diff:
        diff_artifact(golden, captured, g, Path(args.diff), box)
        report["diff"] = str(args.diff)
    if args.report:
        out = Path(args.report)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if ok else 1


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("geometry", help="print shared host/RTL geometry")
    p.set_defaults(func=cmd_geometry)

    p = sub.add_parser("capture", help="capture one frame from v4l2")
    p.add_argument("--out", required=True)
    p.add_argument("--device", default=DEFAULT_DEV)
    p.add_argument("--input-format", default=DEFAULT_FORMAT,
                   help="v4l2 input format (default: mjpeg; use yuyv422 for luma-critical edges)")
    p.add_argument("--video-size", default=DEFAULT_SIZE)
    p.add_argument("--framerate", default=DEFAULT_FPS)
    p.add_argument("--warmup", type=int, default=DEFAULT_WARMUP)
    p.add_argument("--attempts", type=int, default=DEFAULT_ATTEMPTS,
                   help="retry corrupt-buffer grabs; only a clean attempt is returned")
    p.set_defaults(func=cmd_capture)

    p = sub.add_parser("noise", help="measure capture noise from repeated static frames")
    p.add_argument("--frames", nargs="+", required=True)
    p.add_argument("--compare-box", help="presented-frame ROI x,y,w,h; defaults to shared active region")
    p.add_argument("--out")
    p.set_defaults(func=cmd_noise)

    p = sub.add_parser("compare", help="compare a capture against the checked-in golden")
    p.add_argument("--golden", required=True)
    p.add_argument("--capture", required=True)
    p.add_argument("--capture-log",
                   help="ffmpeg/V4L2 log for this capture; corrupt logs return rc=4 before grading")
    p.add_argument("--previous", help="previous-condition frame for stale-capture rejection")
    p.add_argument("--noise-report")
    p.add_argument("--compare-box", help="presented-frame ROI x,y,w,h; defaults to shared active region")
    p.add_argument("--max-mae", type=float, default=0.0)
    p.add_argument("--max-abs", type=int, default=0)
    p.add_argument("--diff", help="PNG artifact: golden | captured | amplified diff")
    p.add_argument("--report", help="write JSON report")
    p.set_defaults(func=cmd_compare)

    return ap


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except HarnessError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return e.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
