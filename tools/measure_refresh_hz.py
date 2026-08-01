#!/usr/bin/env python3
"""Measure display/grabber refresh from HDMI-USB capture PTS (not DEFAULT_ASSUMED).

Hard-won guards (encode, do not rediscover):
  * Discard first WARMUP frames (default 15) — grabber junk.
  * /dev/video0 EXCLUSIVE — fuser busy => distinct error, never zero Hz.
  * Empty capture => NO_DATA (rc=77), never report 0.0 Hz as a measurement.
  * md5-distinctness is INVALID both ways — not used here.
  * mean luma is INVALID — not used here.

Derivation printed with every field (rd-review standing rule).

Exit: 0 measured, 77 UNSCORED/NO_DATA, 2 DEVICE_BUSY, 1 usage.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

RC_OK = 0
RC_USAGE = 1
RC_BUSY = 2
RC_UNSCORED = 77
WARMUP_DEFAULT = 15


def fuser_holders(dev: str) -> str:
    try:
        r = subprocess.run(
            ["fuser", "-v", dev],
            capture_output=True,
            text=True,
            check=False,
        )
        return (r.stderr or r.stdout or "").strip()
    except FileNotFoundError:
        return "fuser_absent"


def measure_from_pts(pts: list[float], warmup: int) -> dict:
    if len(pts) <= warmup + 5:
        return {
            "verdict": "NO_DATA",
            "rc": RC_UNSCORED,
            "reason": f"pts_n={len(pts)} <= warmup+5={warmup+5} — empty/short, not zero Hz",
        }
    use = pts[warmup:]
    dts = [use[i] - use[i - 1] for i in range(1, len(use)) if use[i] > use[i - 1]]
    if len(dts) < 10:
        return {
            "verdict": "NO_DATA",
            "rc": RC_UNSCORED,
            "reason": f"dt_n={len(dts)} after warmup — NO_DATA not zero",
            "pts_n": len(pts),
            "warmup": warmup,
        }
    # quantise to 0.1 ms bins for mode
    bins = [round(d * 10000) / 10000.0 for d in dts]  # 0.1ms
    mode_dt, mode_n = Counter(bins).most_common(1)[0]
    if mode_dt <= 1e-6:
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": "modal_dt~0 — refuse",
        }
    hz = 1.0 / mode_dt
    med = sorted(dts)[len(dts) // 2]
    mean = sum(dts) / len(dts)
    return {
        "verdict": "MEASURED",
        "rc": RC_OK,
        "refresh_hz": hz,
        "refresh_hz_der": "1/modal_pts_dt_after_warmup",
        "refresh_hz_tag": "measured",
        "modal_dt_s": mode_dt,
        "modal_dt_n": mode_n,
        "median_dt_s": med,
        "mean_dt_s": mean,
        "dt_n": len(dts),
        "pts_n": len(pts),
        "warmup_discarded": warmup,
        "warmup_der": "grabber_junk_first_frames",
        "span_s": use[-1] - use[0],
        "note": "ALL_hold_d_using_this_hz_are_conditional_on_this_measurement",
    }


def capture_pts(dev: str, nframes: int, size: str, out_dir: Path) -> tuple[list[float], str]:
    mkv = out_dir / "cap.mkv"
    # copy bitstream path for pts
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
        str(nframes),
        "-c",
        "copy",
        "-y",
        str(mkv),
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        err = (r.stderr or r.stdout or "").strip()
        if "busy" in err.lower() or "Device or resource busy" in err:
            return [], f"DEVICE_BUSY {err}"
        return [], f"ffmpeg_fail rc={r.returncode} {err}"
    if not mkv.is_file() or mkv.stat().st_size < 1000:
        return [], "NO_DATA empty_mkv"
    pr = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "frame=pts_time",
            "-of",
            "csv=p=0",
            str(mkv),
        ],
        capture_output=True,
        text=True,
    )
    pts = []
    for line in (pr.stdout or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            pts.append(float(line.split(",")[0]))
        except ValueError:
            continue
    if not pts:
        return [], "NO_DATA empty_pts"
    return pts, "ok"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--device", default="/dev/video0")
    ap.add_argument("--frames", type=int, default=90)
    ap.add_argument("--warmup", type=int, default=WARMUP_DEFAULT)
    ap.add_argument("--size", default="1280x720", help="grabber size; 720p60 preferred")
    ap.add_argument("--pts-file", type=Path, help="skip capture; one pts_time per line")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        print("PRE-REGISTER measure_refresh_hz:")
        print("  warmup discard; busy!=zero; empty=NO_DATA; modal 1/dt = hz measured")
        # synthetic 60 Hz
        pts = [i / 60.0 for i in range(80)]
        r = measure_from_pts(pts, 15)
        print(r)
        ok = r["rc"] == RC_OK and abs(r["refresh_hz"] - 60.0) < 0.5
        # empty
        r2 = measure_from_pts([0.0, 0.01], 15)
        ok = ok and r2["rc"] == RC_UNSCORED
        print("PASS" if ok else "FAIL", "self-test")
        return RC_OK if ok else 2

    if args.pts_file:
        pts = []
        for line in args.pts_file.read_text().splitlines():
            line = line.strip()
            if line:
                pts.append(float(line.split(",")[0]))
        rep = measure_from_pts(pts, args.warmup)
    else:
        holders = fuser_holders(args.device)
        if holders and "ffmpeg" not in holders.lower():
            # any holder is a problem if device will open busy
            pass
        if not Path(args.device).exists():
            print(f"NO_DEVICE {args.device}")
            return RC_UNSCORED
        # Project-local scratch (never /tmp — agent policy).
        root = Path(__file__).resolve().parents[1]
        work = root / ".agent-work" / "w-instr" / f"mref_{os.getpid()}_{int(time.time())}"
        work.mkdir(parents=True, exist_ok=True)
        try:
            pts, st = capture_pts(args.device, args.frames, args.size, work)
            if st.startswith("DEVICE_BUSY"):
                print(f"DEVICE_BUSY der=open_fail fuser={holders!r} detail={st}")
                print("rc=2 — never report refresh_hz=0")
                return RC_BUSY
            if st.startswith("NO_DATA") or not pts:
                print(f"NO_DATA der={st} fuser={holders!r} — empty means no-data not zero")
                return RC_UNSCORED
            rep = measure_from_pts(pts, args.warmup)
            rep["fuser"] = holders or "none"
            rep["device"] = args.device
            rep["capture_size"] = args.size
            rep["capture_size_tag"] = "caller_supplied"
        finally:
            shutil.rmtree(work, ignore_errors=True)

    print(
        f"VERDICT={rep.get('verdict')} rc={rep.get('rc')} "
        f"refresh_hz={rep.get('refresh_hz')} "
        f"refresh_hz_der={rep.get('refresh_hz_der')} "
        f"refresh_hz_tag={rep.get('refresh_hz_tag')} "
        f"modal_dt_s={rep.get('modal_dt_s')} "
        f"warmup_discarded={rep.get('warmup_discarded')} "
        f"dt_n={rep.get('dt_n')} "
        f"note={rep.get('note') or rep.get('reason')}"
    )
    if rep.get("rc") == RC_OK:
        print(
            f"USE: publish_swap_delta setVsyncHzMeasured({rep['refresh_hz']:.6f}) "
            f"or --vsync-hz {rep['refresh_hz']:.6f} on offline scorer"
        )
    return int(rep["rc"])


if __name__ == "__main__":
    sys.exit(main())
