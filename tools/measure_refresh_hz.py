#!/usr/bin/env python3
"""Measure display/grabber refresh from HDMI-USB capture PTS (not DEFAULT_ASSUMED).

Hard-won guards (encode, do not rediscover):
  * Discard first WARMUP frames (default 15) — grabber junk.
  * /dev/video0 EXCLUSIVE — fuser busy => distinct error, never zero Hz.
  * Empty capture => NO_DATA (rc=77), never report 0.0 Hz as a measurement.
  * md5-distinctness is INVALID both ways — not used here.
  * mean luma is INVALID — not used here.

Glass vs grabber cadence (lab method, idle still image):
  * MS2109 UVC exposes discrete intervals only (e.g. 1280x720: 60/50/30/20/10).
    Ideal glass 24.24 / trap 16.16 are NOT UVC enum rates — PTS modal near those
    would be surprising but scoreable; modal ~30/31.25/60 with cross-RBF invariance
    is grabber/USB delivery quantize, not glass pixel clock.
  * Multi-request probe: vary --framerate / --size / --input-format; if modal tracks
    the *requested* UVC rate (or sticks at ~0.032 s) while RBF/PLL claims differ,
    label cadence GRABBER_OR_USB not glass.
  * RATE_PASS only if MEASURED modal lands in 23.5..24.5 (parent band). Soft-skip ≠ PASS.

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

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from artifact_stamp import (  # noqa: E402
    add_stamp_args,
    require_stamp,
    stamp_from_namespace,
)

RC_OK = 0
RC_USAGE = 1
RC_BUSY = 2
RC_UNSCORED = 77
WARMUP_DEFAULT = 15

# Product CEA totals (720p pack): H_TOTAL*V_TOTAL
PIX_PER_FRAME = 1650 * 750  # 1_237_500
# Settled product PLL string on cut-b tip: 30.000000 MHz → 24.2424… glass
HYP_GLASS_30MHZ = 30_000_000 / PIX_PER_FRAME  # ≈24.242424
HYP_GLASS_29_7 = 29_700_000 / PIX_PER_FRAME  # 24.000 exactly
HYP_TRAP_20MHZ = 20_000_000 / PIX_PER_FRAME  # ≈16.161616
RATE_PASS_LO = 23.5
RATE_PASS_HI = 24.5

# Named hypotheses for discriminator table (hz, name, meaning)
DEFAULT_HYPOTHESES: list[tuple[float, str, str]] = [
    (HYP_GLASS_30MHZ, "glass_30MHz_CEA", "30e6/(1650*750) PLL product string"),
    (HYP_GLASS_29_7, "glass_29p7_CEA", "29.7e6/(1650*750) classic 720p24 pack"),
    (HYP_TRAP_20MHZ, "trap_clk_sys_20MHz", "20e6/(1650*750) MULTI+CEA no working pix PLL"),
    (25.0, "uvc_25", "MS2109 discrete"),
    (30.0, "uvc_30", "MS2109 discrete / HDMI-cap common"),
    (31.25, "usb_32ms_quantize", "1/0.032 — lab modal on STALE+cut-b; USB/host PTS quantize"),
    (50.0, "uvc_50", "MS2109 discrete"),
    (60.0, "uvc_60", "MS2109 discrete @1280x720"),
    (20.0, "uvc_20", "MS2109 discrete"),
    (10.0, "uvc_10", "MS2109 discrete"),
]


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


def _rate_band(hz: float) -> str:
    """Honest band label — RATE_PASS only in parent 23.5..24.5 window."""
    if RATE_PASS_LO <= hz <= RATE_PASS_HI:
        return "RATE_PASS_BAND"
    if 15.5 <= hz <= 16.8:
        return "RATE_FAIL_TRAP16"
    if 29.0 <= hz <= 32.5:
        return "GRABBER_OR_USB_30ish"
    if 55.0 <= hz <= 65.0:
        return "GRABBER_60ish"
    if 19.0 <= hz <= 21.0:
        return "UVC_20ish"
    if 24.5 < hz < 29.0:
        return "NEAR_30_NOT_GLASS24"
    return "OTHER_INVESTIGATE"


def hypothesis_table(
    hz: float,
    hyps: list[tuple[float, str, str]] | None = None,
) -> list[dict]:
    hyps = hyps or DEFAULT_HYPOTHESES
    rows = []
    for target, name, meaning in hyps:
        err = abs(hz - target)
        rel = err / target if target > 0 else float("inf")
        rows.append(
            {
                "name": name,
                "target_hz": target,
                "abs_err_hz": err,
                "rel_err": rel,
                "meaning": meaning,
            }
        )
    rows.sort(key=lambda r: r["abs_err_hz"])
    return rows


def measure_from_pts(
    pts: list[float],
    warmup: int,
    hist_top: int = 8,
) -> dict:
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
    ctr = Counter(bins)
    mode_dt, mode_n = ctr.most_common(1)[0]
    if mode_dt <= 1e-6:
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": "modal_dt~0 — refuse",
        }
    hz = 1.0 / mode_dt
    med = sorted(dts)[len(dts) // 2]
    mean = sum(dts) / len(dts)
    span = use[-1] - use[0]
    n_intervals = len(use) - 1
    span_hz = (n_intervals / span) if span > 1e-9 else float("nan")
    mean_hz = (1.0 / mean) if mean > 1e-9 else float("nan")
    med_hz = (1.0 / med) if med > 1e-9 else float("nan")
    top = ctr.most_common(hist_top)
    hist = ",".join(f"{dt:.4f}:{n}" for dt, n in top)
    mode_frac = mode_n / len(dts)
    hyps = hypothesis_table(hz)
    best = hyps[0] if hyps else None
    band = _rate_band(hz)
    # Cadence class: modal near UVC/USB quantize and far from glass/trap → grabber
    glass_err = min(abs(hz - HYP_GLASS_30MHZ), abs(hz - HYP_GLASS_29_7))
    trap_err = abs(hz - HYP_TRAP_20MHZ)
    grab_err = min(
        abs(hz - 30.0),
        abs(hz - 31.25),
        abs(hz - 60.0),
        abs(hz - 62.5),
        abs(hz - 50.0),
        abs(hz - 25.0),
        abs(hz - 20.0),
        abs(hz - 10.0),
        abs(hz - 5.0),
    )
    if band == "RATE_PASS_BAND":
        cadence_class = "GLASS_CANDIDATE_24"
    elif band == "RATE_FAIL_TRAP16":
        cadence_class = "GLASS_TRAP16"
    elif grab_err + 0.5 < glass_err and grab_err + 0.5 < trap_err:
        cadence_class = "GRABBER_OR_USB_CADENCE"
    elif band in ("GRABBER_OR_USB_30ish", "GRABBER_60ish", "UVC_20ish"):
        cadence_class = "GRABBER_OR_USB_CADENCE"
    else:
        cadence_class = "AMBIGUOUS"

    return {
        "verdict": "MEASURED",
        "rc": RC_OK,
        "refresh_hz": hz,
        "refresh_hz_der": "1/modal_pts_dt_after_warmup",
        "refresh_hz_tag": "measured",
        "modal_dt_s": mode_dt,
        "modal_dt_n": mode_n,
        "modal_frac": mode_frac,
        "modal_frac_der": "modal_dt_n/dt_n",
        "median_dt_s": med,
        "mean_dt_s": mean,
        "median_hz": med_hz,
        "mean_hz": mean_hz,
        "span_s": span,
        "span_hz": span_hz,
        "span_hz_der": "(pts_after_warmup-1)/span_s",
        "dt_n": len(dts),
        "pts_n": len(pts),
        "warmup_discarded": warmup,
        "warmup_der": "grabber_junk_first_frames",
        "dt_hist_top": hist,
        "dt_hist_top_der": "0.1ms_bins Counter.most_common",
        "rate_band": band,
        "rate_band_der": "23.5..24.5=RATE_PASS_BAND else trap/grabber labels",
        "cadence_class": cadence_class,
        "cadence_class_der": "compare modal to glass24/trap16 vs uvc30/31.25/60",
        "best_hyp": best["name"] if best else "NO-DATA",
        "best_hyp_target_hz": best["target_hz"] if best else None,
        "best_hyp_abs_err_hz": best["abs_err_hz"] if best else None,
        "best_hyp_der": "min abs(refresh_hz-target) over DEFAULT_HYPOTHESES",
        "hypotheses": hyps,
        "rate_pass_eligible": band == "RATE_PASS_BAND",
        "rate_pass_eligible_der": "modal in [23.5,24.5] only — soft-skip≠PASS",
        "note": "ALL_hold_d_using_this_hz_are_conditional_on_this_measurement",
    }


def capture_pts(
    dev: str,
    nframes: int,
    size: str,
    out_dir: Path,
    framerate: float | None = None,
    input_format: str = "mjpeg",
) -> tuple[list[float], str]:
    mkv = out_dir / "cap.mkv"
    # copy bitstream path for pts
    cmd = [
        "ffmpeg",
        "-v",
        "error",
        "-f",
        "v4l2",
        "-input_format",
        input_format,
        "-video_size",
        size,
    ]
    if framerate is not None and framerate > 0:
        # v4l2 timeperframe — discrete rates only on MS2109
        cmd.extend(["-framerate", str(framerate)])
    cmd.extend(
        [
            "-i",
            dev,
            "-frames:v",
            str(nframes),
            "-c",
            "copy",
            "-y",
            str(mkv),
        ]
    )
    # For YUYV, -c copy is not usable in mkv; re-encode to mjpeg for PTS extract
    if input_format.lower() in ("yuyv", "yuyv422", "yuv422"):
        cmd = [
            "ffmpeg",
            "-v",
            "error",
            "-f",
            "v4l2",
            "-input_format",
            "yuyv422",
            "-video_size",
            size,
        ]
        if framerate is not None and framerate > 0:
            cmd.extend(["-framerate", str(framerate)])
        cmd.extend(
            [
                "-i",
                dev,
                "-frames:v",
                str(nframes),
                "-c:v",
                "mjpeg",
                "-q:v",
                "5",
                "-y",
                str(mkv),
            ]
        )
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


def _print_measure(rep: dict, st, discriminate: bool) -> None:
    print(
        f"VERDICT={rep.get('verdict')} rc={rep.get('rc')} "
        f"refresh_hz={rep.get('refresh_hz')} "
        f"refresh_hz_der={rep.get('refresh_hz_der')} "
        f"refresh_hz_tag={rep.get('refresh_hz_tag')} "
        f"modal_dt_s={rep.get('modal_dt_s')} "
        f"modal_dt_n={rep.get('modal_dt_n')} "
        f"modal_frac={rep.get('modal_frac')} "
        f"mean_hz={rep.get('mean_hz')} median_hz={rep.get('median_hz')} "
        f"span_hz={rep.get('span_hz')} span_s={rep.get('span_s')} "
        f"warmup_discarded={rep.get('warmup_discarded')} "
        f"dt_n={rep.get('dt_n')} pts_n={rep.get('pts_n')} "
        f"rate_band={rep.get('rate_band')} cadence_class={rep.get('cadence_class')} "
        f"best_hyp={rep.get('best_hyp')} best_hyp_abs_err_hz={rep.get('best_hyp_abs_err_hz')} "
        f"rate_pass_eligible={1 if rep.get('rate_pass_eligible') else 0} "
        f"dt_hist_top={rep.get('dt_hist_top')} "
        f"artifact_pair={st.artifact_pair} decode_src={st.decode_src} "
        f"note={rep.get('note') or rep.get('reason')}"
    )
    if discriminate and rep.get("hypotheses"):
        print(
            "DISCRIMINATOR method=min_abs_err_vs_named_hyps "
            "glass_30MHz=30e6/(1650*750) trap16=20e6/(1650*750) "
            "usb_32ms=31.25 uvc_discrete=MS2109_list-formats-ext"
        )
        for i, h in enumerate(rep["hypotheses"][:6]):
            print(
                f"  hyp[{i}] name={h['name']} target_hz={h['target_hz']:.6f} "
                f"abs_err_hz={h['abs_err_hz']:.6f} rel_err={h['rel_err']:.4f} "
                f"meaning={h['meaning']}"
            )
    if rep.get("rc") == RC_OK:
        print(
            f"USE: publish_swap_delta setVsyncHzMeasured({rep['refresh_hz']:.6f}) "
            f"or --vsync-hz {rep['refresh_hz']:.6f} on offline scorer; "
            f"export MISTERPLEX_VSYNC_HZ={rep['refresh_hz']:.6f}"
        )
        if rep.get("rate_pass_eligible"):
            print(
                "RATE_PASS_ELIGIBLE=1 band=23.5..24.5 "
                "(parent still scores RATE_PASS; tool does not invent ship PASS)"
            )
        else:
            print(
                f"RATE_PASS_ELIGIBLE=0 rate_band={rep.get('rate_band')} "
                f"cadence_class={rep.get('cadence_class')} "
                "— soft-skip/measure ≠ RATE_PASS"
            )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--device", default="/dev/video0")
    ap.add_argument("--frames", type=int, default=90)
    ap.add_argument("--warmup", type=int, default=WARMUP_DEFAULT)
    ap.add_argument("--size", default="1280x720", help="grabber size; 720p preferred")
    ap.add_argument(
        "--framerate",
        type=float,
        default=None,
        help="v4l2 -framerate (MS2109 discrete only: 60/50/30/20/10…)",
    )
    ap.add_argument(
        "--input-format",
        default="mjpeg",
        help="v4l2 input format: mjpeg (default) or yuyv",
    )
    ap.add_argument("--pts-file", type=Path, help="skip capture; one pts_time per line")
    ap.add_argument(
        "--save-pts",
        type=Path,
        help="write measured pts_time lines for re-analysis",
    )
    ap.add_argument(
        "--keep-work",
        type=Path,
        help="keep capture workdir (mkv) under this path instead of rmtree",
    )
    ap.add_argument("--hist-top", type=int, default=8)
    ap.add_argument(
        "--discriminate",
        action="store_true",
        help="print hypothesis error table (24.24 vs 16.16 vs 30/31.25/60)",
    )
    ap.add_argument("--self-test", action="store_true")
    add_stamp_args(ap)
    args = ap.parse_args()

    if args.self_test:
        print("PRE-REGISTER measure_refresh_hz:")
        print("  warmup discard; busy!=zero; empty=NO_DATA; modal 1/dt = hz measured")
        print("  fleet: artifact pair required for scoreable MEASURED")
        print("  discriminate: glass24 / trap16 / grabber31.25 named hyps")
        ok = True
        # synthetic 60 Hz
        pts = [i / 60.0 for i in range(80)]
        r = measure_from_pts(pts, 15)
        print("self60", {k: r[k] for k in (
            "rc", "refresh_hz", "rate_band", "cadence_class", "best_hyp"
        ) if k in r})
        ok = ok and r["rc"] == RC_OK and abs(r["refresh_hz"] - 60.0) < 0.5
        ok = ok and r.get("cadence_class") == "GRABBER_OR_USB_CADENCE"
        # synthetic 24.2424 glass
        g = HYP_GLASS_30MHZ
        pts_g = [i / g for i in range(100)]
        rg = measure_from_pts(pts_g, 15)
        print("self24.24", {k: rg[k] for k in (
            "rc", "refresh_hz", "rate_band", "cadence_class", "rate_pass_eligible", "best_hyp"
        ) if k in rg})
        ok = ok and rg["rc"] == RC_OK and RATE_PASS_LO <= rg["refresh_hz"] <= RATE_PASS_HI
        ok = ok and rg.get("rate_pass_eligible") is True
        ok = ok and rg.get("cadence_class") == "GLASS_CANDIDATE_24"
        # trap 16.16
        t = HYP_TRAP_20MHZ
        pts_t = [i / t for i in range(100)]
        rt = measure_from_pts(pts_t, 15)
        print("self16.16", {k: rt[k] for k in (
            "rc", "refresh_hz", "rate_band", "cadence_class", "best_hyp"
        ) if k in rt})
        ok = ok and rt["rc"] == RC_OK and rt.get("rate_band") == "RATE_FAIL_TRAP16"
        # lab 31.25
        pts_u = [i * 0.032 for i in range(100)]
        ru = measure_from_pts(pts_u, 15)
        print("self31.25", {k: ru[k] for k in (
            "rc", "refresh_hz", "rate_band", "cadence_class", "best_hyp", "rate_pass_eligible"
        ) if k in ru})
        ok = ok and ru["rc"] == RC_OK and abs(ru["refresh_hz"] - 31.25) < 0.2
        ok = ok and ru.get("rate_pass_eligible") is False
        ok = ok and ru.get("cadence_class") == "GRABBER_OR_USB_CADENCE"
        # empty
        r2 = measure_from_pts([0.0, 0.01], 15)
        ok = ok and r2["rc"] == RC_UNSCORED
        st = stamp_from_namespace(args)
        o, _, rc = require_stamp(st)
        ok = ok and (not o) and rc == RC_UNSCORED
        print("PASS" if ok else "FAIL", "self-test")
        return RC_OK if ok else 2

    st = stamp_from_namespace(args)
    print("STAMP", st.header_kv())
    ok_pair, reason, _rc_pair = require_stamp(st)
    if not ok_pair and not args.allow_unstamped:
        print(f"VERDICT=UNSCORED rc={RC_UNSCORED} reason={reason}")
        return RC_UNSCORED

    pts: list[float] = []
    if args.pts_file:
        for line in args.pts_file.read_text().splitlines():
            line = line.strip()
            if line:
                pts.append(float(line.split(",")[0]))
        rep = measure_from_pts(pts, args.warmup, hist_top=args.hist_top)
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
        if args.keep_work:
            work = args.keep_work
            work.mkdir(parents=True, exist_ok=True)
            cleanup = False
        else:
            work = root / ".agent-work" / "w-instr" / f"mref_{os.getpid()}_{int(time.time())}"
            work.mkdir(parents=True, exist_ok=True)
            cleanup = True
        try:
            # Do not shadow stamp object `st` (ArtifactStamp) — cap status is a str.
            pts, cap_status = capture_pts(
                args.device,
                args.frames,
                args.size,
                work,
                framerate=args.framerate,
                input_format=args.input_format,
            )
            if cap_status.startswith("DEVICE_BUSY"):
                print(f"DEVICE_BUSY der=open_fail fuser={holders!r} detail={cap_status}")
                print("rc=2 — never report refresh_hz=0")
                return RC_BUSY
            if cap_status.startswith("NO_DATA") or not pts:
                print(f"NO_DATA der={cap_status} fuser={holders!r} — empty means no-data not zero")
                return RC_UNSCORED
            rep = measure_from_pts(pts, args.warmup, hist_top=args.hist_top)
            rep["fuser"] = holders or "none"
            rep["device"] = args.device
            rep["capture_size"] = args.size
            rep["capture_size_tag"] = "caller_supplied"
            rep["capture_framerate"] = args.framerate if args.framerate is not None else "driver_default"
            rep["capture_input_format"] = args.input_format
        finally:
            if cleanup:
                shutil.rmtree(work, ignore_errors=True)

    if args.save_pts and pts:
        args.save_pts.parent.mkdir(parents=True, exist_ok=True)
        args.save_pts.write_text("\n".join(f"{p:.6f}" for p in pts) + "\n")
        print(f"SAVE_PTS path={args.save_pts} n={len(pts)}")

    if rep.get("rc") == RC_OK:
        # attach capture knobs for log completeness
        if not args.pts_file:
            print(
                f"CAPTURE device={rep.get('device')} size={rep.get('capture_size')} "
                f"framerate={rep.get('capture_framerate')} "
                f"input_format={rep.get('capture_input_format')} "
                f"fuser={rep.get('fuser')!r}"
            )
    _print_measure(rep, st, discriminate=args.discriminate or True)

    if not ok_pair:
        return RC_UNSCORED
    return int(rep["rc"])


if __name__ == "__main__":
    sys.exit(main())
