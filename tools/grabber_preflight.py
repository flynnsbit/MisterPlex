#!/usr/bin/env python3
"""Grabber pre-flight: is the HDMI capture path alive?

Parent incident (2026-08-02): MacroSilicon unlocked (Active 0x0, Pixelclock 0 Hz)
produced uniform pixel=7 frames. An innocent daemon was rolled back on that dead
instrument. Run this BEFORE any cast/capture evidence is accepted for promote.

Exit codes:
  0  SIGNAL_OK — DV timings locked and/or sample frame is a real picture
  78 CAPTURE_NO_SIGNAL — unlocked or uniform no-signal frame (NOT device black)
  77 UNSCORED — device busy / missing tools / cannot assess (never promote PASS)
  2  usage / hard error

Does NOT touch the MiSTer device — host grabber only.
Does NOT depend on hdmi_motion_instrument (self-contained uniform check).
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

RC_OK = 0
RC_NO_SIGNAL = 78
RC_UNSCORED = 77
RC_ERR = 2

DEFAULT_DEV = os.environ.get("HDMI_DEV", "/dev/video0")


def _run(cmd: list[str], timeout: float = 8.0) -> tuple[int, str, str]:
    try:
        p = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False
        )
        return int(p.returncode), p.stdout or "", p.stderr or ""
    except FileNotFoundError:
        return 127, "", f"missing binary: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


def query_dv_timings(dev: str) -> dict:
    rc, out, err = _run(["v4l2-ctl", f"--device={dev}", "--query-dv-timings"])
    text = out + err

    def _i(pat: str):
        m = re.search(pat, text)
        return int(m.group(1)) if m else None

    active_w = _i(r"Active width:\s*(\d+)")
    active_h = _i(r"Active height:\s*(\d+)")
    pix = None
    m = re.search(r"Pixelclock:\s*([0-9.]+)\s*([MGmu]?Hz)", text, re.I)
    if m:
        val = float(m.group(1))
        unit = m.group(2).lower()
        if unit.startswith("m"):
            pix = val * 1e6
        elif unit.startswith("g"):
            pix = val * 1e9
        else:
            pix = val
    locked = bool(
        active_w and active_h and active_w > 0 and active_h > 0 and pix and pix > 0
    )
    return {
        "rc": rc,
        "active_w": active_w,
        "active_h": active_h,
        "pixelclock_hz": pix,
        "locked": locked,
        "raw": text.strip()[:800],
    }


def fuser_busy(dev: str) -> str | None:
    rc, out, err = _run(["fuser", "-v", dev], timeout=3.0)
    text = (out + err).strip()
    return text or None


def classify_rgb_array(rgb) -> dict:
    """Uniform min==max ⇒ NO_SIGNAL (dead grabber), not device black."""
    amin = int(rgb.min())
    amax = int(rgb.max())
    mean = float(rgb.mean())
    if rgb.shape[0] > 240 and rgb.shape[1] > 320:
        std = float(rgb[::8, ::8].std())
    else:
        std = float(rgb.std())
    uniform = amin == amax
    return {
        "no_signal": bool(uniform),
        "uniform": uniform,
        "pixel_min": amin,
        "pixel_max": amax,
        "pixel_mean": round(mean, 3),
        "pixel_std": round(std, 4),
        "signal_class": "NO_SIGNAL" if uniform else "REAL_PICTURE",
    }


def classify_from_stats(pixel_min: float, pixel_max: float, pixel_std: float) -> dict:
    """Host inject path (no device): same rule as live sample."""
    uniform = float(pixel_min) == float(pixel_max) or float(pixel_std) < 0.0001
    return {
        "no_signal": uniform,
        "uniform": uniform,
        "pixel_min": pixel_min,
        "pixel_max": pixel_max,
        "pixel_std": pixel_std,
        "signal_class": "NO_SIGNAL" if uniform else "REAL_PICTURE",
    }


def sample_frame(dev: str, size: str = "1920x1080") -> dict:
    try:
        import numpy as np
        from PIL import Image
    except ImportError:
        return {"ok": False, "error": "numpy/PIL required for frame sample"}

    with tempfile.TemporaryDirectory(prefix="grabber_preflight_") as td:
        cmd = [
            "ffmpeg",
            "-v",
            "error",
            "-f",
            "v4l2",
            "-input_format",
            "mjpeg",
            "-video_size",
            size,
            "-i",
            dev,
            "-frames:v",
            "3",
            "-y",
            str(Path(td) / "f_%02d.png"),
        ]
        rc, _o, err = _run(cmd, timeout=15.0)
        frames = sorted(Path(td).glob("f_*.png"))
        if rc != 0 or not frames:
            busy = "Device or resource busy" in (err or "")
            return {
                "ok": False,
                "ffmpeg_rc": rc,
                "error": (err or "").strip()[:300] or "no frames",
                "busy": busy,
            }
        path = frames[-1]
        rgb = __import__("numpy").asarray(
            __import__("PIL.Image", fromlist=["Image"]).Image.open(path).convert("RGB")
        )
        sig = classify_rgb_array(rgb)
        return {"ok": True, "n_grabbed": len(frames), **sig, "ffmpeg_rc": rc}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--device", default=DEFAULT_DEV)
    ap.add_argument("--size", default="1920x1080")
    ap.add_argument("--skip-frame", action="store_true")
    ap.add_argument(
        "--inject-stats",
        metavar="MIN,MAX,STD",
        help="Host-only inject (no /dev/video0). RED: 7,7,0 → rc=78",
    )
    ap.add_argument(
        "--inject-dv",
        metavar="W,H,PIX_HZ",
        help="Host-only DV inject e.g. 0,0,0 or 1920,1080,148500000",
    )
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    # --- host inject path (unit / promote gate without grabber hardware) ---
    if args.inject_stats or args.inject_dv:
        unlocked = False
        frame_nosig = False
        frame_real = False
        locked = False
        if args.inject_dv:
            parts = args.inject_dv.split(",")
            if len(parts) != 3:
                print(f"VERDICT=ERR rc={RC_ERR} reason=bad_inject_dv")
                return RC_ERR
            w, h, pix = float(parts[0]), float(parts[1]), float(parts[2])
            locked = w > 0 and h > 0 and pix > 0
            unlocked = not locked
            print(
                f"dv_timings active={int(w)}x{int(h)} pixelclock_hz={pix} "
                f"locked={locked} [inject]"
            )
        if args.inject_stats:
            parts = args.inject_stats.split(",")
            if len(parts) != 3:
                print(f"VERDICT=ERR rc={RC_ERR} reason=bad_inject_stats")
                return RC_ERR
            mn, mx, sd = float(parts[0]), float(parts[1]), float(parts[2])
            sig = classify_from_stats(mn, mx, sd)
            print(
                f"sample_frame signal_class={sig['signal_class']} "
                f"min={sig['pixel_min']} max={sig['pixel_max']} "
                f"std={sig['pixel_std']} [inject]"
            )
            frame_nosig = bool(sig["no_signal"])
            frame_real = not frame_nosig
        if unlocked or frame_nosig:
            print(
                f"VERDICT=CAPTURE_NO_SIGNAL rc={RC_NO_SIGNAL} "
                f"device_state=UNKNOWN capture_path=FAULT — "
                f"uniform/unlocked grabber is NOT device black; do not rollback software"
            )
            return RC_NO_SIGNAL
        if frame_real or locked:
            print(
                f"VERDICT=SIGNAL_OK rc={RC_OK} dv_locked={locked} "
                f"frame_real={frame_real} capture_path=LIVE"
            )
            return RC_OK
        print(f"VERDICT=UNSCORED rc={RC_UNSCORED} reason=inject_incomplete")
        return RC_UNSCORED

    dev = args.device
    if not Path(dev).exists():
        print(f"VERDICT=UNSCORED rc={RC_UNSCORED} reason=missing_device {dev}")
        return RC_UNSCORED

    busy = fuser_busy(dev)
    if busy and "ffmpeg" not in (busy or "").lower():
        print(
            f"VERDICT=UNSCORED rc={RC_UNSCORED} "
            f"reason=device_busy fuser={busy!r} — release exclusive holders "
            f"(OBS/nautilus/preview) before capture"
        )
        return RC_UNSCORED

    dv = query_dv_timings(dev)
    print(
        f"dv_timings active={dv.get('active_w')}x{dv.get('active_h')} "
        f"pixelclock_hz={dv.get('pixelclock_hz')} locked={dv.get('locked')} "
        f"[measured]"
    )
    if dv.get("raw"):
        for line in (dv["raw"] or "").splitlines():
            if any(
                k in line
                for k in ("Active width", "Active height", "Pixelclock", "Error")
            ):
                print(f"  | {line.strip()}")

    frame_info = None
    if not args.skip_frame:
        frame_info = sample_frame(dev, size=args.size)
        if frame_info.get("ok"):
            print(
                f"sample_frame signal_class={frame_info.get('signal_class')} "
                f"min={frame_info.get('pixel_min')} max={frame_info.get('pixel_max')} "
                f"std={frame_info.get('pixel_std')} mean={frame_info.get('pixel_mean')} "
                f"[measured]"
            )
        else:
            print(
                f"sample_frame FAILED error={frame_info.get('error')!r} "
                f"busy={frame_info.get('busy')}"
            )

    unlocked = dv.get("locked") is False and (
        dv.get("active_w") in (0, None) or (dv.get("pixelclock_hz") or 0) == 0
    )
    frame_nosig = bool(
        frame_info and frame_info.get("ok") and frame_info.get("no_signal")
    )
    frame_real = bool(
        frame_info and frame_info.get("ok") and not frame_info.get("no_signal")
    )

    if unlocked or frame_nosig:
        reason = []
        if unlocked:
            reason.append(
                f"DV unlocked active={dv.get('active_w')}x{dv.get('active_h')} "
                f"pixelclock={dv.get('pixelclock_hz')}"
            )
        if frame_nosig:
            reason.append(
                f"sample uniform pixel={frame_info.get('pixel_min')} std=0 "
                f"(MacroSilicon no-signal synthetic — NOT a black screen)"
            )
        print(
            f"VERDICT=CAPTURE_NO_SIGNAL rc={RC_NO_SIGNAL} "
            f"device_state=UNKNOWN capture_path=FAULT — " + "; ".join(reason)
        )
        print(
            "ACTION: re-plug HDMI into grabber / power-cycle MS2109; "
            "do NOT rollback device software on this symptom alone"
        )
        return RC_NO_SIGNAL

    if frame_real or dv.get("locked"):
        print(
            f"VERDICT=SIGNAL_OK rc={RC_OK} "
            f"dv_locked={dv.get('locked')} frame_real={frame_real} "
            f"capture_path=LIVE"
        )
        return RC_OK

    print(
        f"VERDICT=UNSCORED rc={RC_UNSCORED} "
        f"reason=could_not_confirm_signal dv_locked={dv.get('locked')} "
        f"frame={frame_info}"
    )
    return RC_UNSCORED


if __name__ == "__main__":
    sys.exit(main())
