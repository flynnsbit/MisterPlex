#!/usr/bin/env python3
"""Grabber pre-flight: is the HDMI capture path alive?

Parent incident: MacroSilicon unlocked (Active 0x0, pixelclock 0 Hz) produced
uniform pixel=7 frames. A new daemon deploy was nearly blamed. Run this BEFORE
any cast/capture session.

Exit codes:
  0  SIGNAL_OK — DV timings locked and/or sample frame is a real picture
  78 CAPTURE_NO_SIGNAL — unlocked or uniform no-signal frame
  77 UNSCORED — device busy / missing tools / cannot assess
  2  usage / hard error

Does NOT touch the MiSTer device — host grabber only.
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
    def _i(pat: str) -> int | None:
        m = re.search(pat, text)
        return int(m.group(1)) if m else None
    def _f(pat: str) -> float | None:
        m = re.search(pat, text)
        return float(m.group(1)) if m else None
    active_w = _i(r"Active width:\s*(\d+)")
    active_h = _i(r"Active height:\s*(\d+)")
    # Pixelclock: 148.500 MHz  OR  0 Hz
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
        "src": "measured",
    }


def fuser_busy(dev: str) -> str | None:
    rc, out, err = _run(["fuser", "-v", dev], timeout=3.0)
    text = (out + err).strip()
    return text or None


def sample_frame(dev: str, size: str = "1920x1080") -> dict:
    """Grab one frame; classify uniform no-signal vs real picture."""
    try:
        import numpy as np
        from PIL import Image
    except ImportError:
        return {"ok": False, "error": "numpy/PIL required for frame sample"}

    # Import classifier from sibling instrument without scoring.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from hdmi_motion_instrument import classify_frame_signal  # noqa: WPS433

    with tempfile.TemporaryDirectory(prefix="grabber_preflight_") as td:
        out = Path(td) / "s.png"
        # Small burst; discard is caller's problem — we only need one non-junk if any.
        cmd = [
            "ffmpeg", "-v", "error",
            "-f", "v4l2", "-input_format", "mjpeg",
            "-video_size", size, "-i", dev,
            "-frames:v", "3", "-y", str(Path(td) / "f_%02d.png"),
        ]
        rc, _o, err = _run(cmd, timeout=15.0)
        frames = sorted(Path(td).glob("f_*.png"))
        if rc != 0 or not frames:
            busy = "Device or resource busy" in (err or "")
            return {
                "ok": False,
                "ffmpeg_rc": rc,
                "error": err.strip()[:300] or "no frames",
                "busy": busy,
            }
        # Prefer last frame (after micro warm-up)
        path = frames[-1]
        rgb = np.asarray(Image.open(path).convert("RGB"))
        sig = classify_frame_signal(rgb)
        return {
            "ok": True,
            "path": str(path.name),
            "n_grabbed": len(frames),
            **sig,
            "ffmpeg_rc": rc,
        }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--device", default=DEFAULT_DEV, help="v4l2 device (default /dev/video0)")
    ap.add_argument("--size", default="1920x1080", help="capture size for sample frame")
    ap.add_argument("--skip-frame", action="store_true", help="only query DV timings")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    dev = args.device
    report: dict = {"device": dev, "device_src": "caller_supplied"}

    if not Path(dev).exists():
        print(f"VERDICT=UNSCORED rc={RC_UNSCORED} reason=missing_device {dev}")
        return RC_UNSCORED

    busy = fuser_busy(dev)
    report["fuser"] = busy
    report["fuser_src"] = "measured"
    if busy and "ffmpeg" not in (busy or "").lower():
        # something holds the device
        print(
            f"VERDICT=UNSCORED rc={RC_UNSCORED} "
            f"reason=device_busy fuser={busy!r} — release exclusive holders "
            f"(OBS/nautilus/preview) before capture"
        )
        return RC_UNSCORED

    dv = query_dv_timings(dev)
    report["dv"] = dv
    print(
        f"dv_timings active={dv.get('active_w')}x{dv.get('active_h')} "
        f"pixelclock_hz={dv.get('pixelclock_hz')} locked={dv.get('locked')} "
        f"[measured]"
    )
    if dv.get("raw"):
        # Quote key lines only
        for line in (dv["raw"] or "").splitlines():
            if any(k in line for k in ("Active width", "Active height", "Pixelclock", "Error")):
                print(f"  | {line.strip()}")

    frame_info = None
    if not args.skip_frame:
        frame_info = sample_frame(dev, size=args.size)
        report["frame"] = frame_info
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

    # Decision
    unlocked = dv.get("locked") is False and dv.get("active_w") == 0
    frame_nosig = bool(frame_info and frame_info.get("ok") and frame_info.get("no_signal"))
    frame_real = bool(frame_info and frame_info.get("ok") and not frame_info.get("no_signal"))

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
        if args.json:
            import json
            print(json.dumps(report, indent=2, default=str))
        return RC_NO_SIGNAL

    if frame_real or dv.get("locked"):
        print(
            f"VERDICT=SIGNAL_OK rc={RC_OK} "
            f"dv_locked={dv.get('locked')} frame_real={frame_real} "
            f"capture_path=LIVE"
        )
        if args.json:
            import json
            print(json.dumps(report, indent=2, default=str))
        return RC_OK

    print(
        f"VERDICT=UNSCORED rc={RC_UNSCORED} "
        f"reason=could_not_confirm_signal dv_locked={dv.get('locked')} "
        f"frame={frame_info}"
    )
    return RC_UNSCORED


if __name__ == "__main__":
    sys.exit(main())
