#!/usr/bin/env python3
"""Capture-rate vs marker-period beat analysis (quant floor honesty).

If marker period and capture frame period are near-commensurate, flash phase
walks slowly through the capture bin and residual wander can rise/fall over
tens of seconds WITHOUT any device defect. The simple floor T/sqrt(12) assumes
uniform independent phase each flash — wrong under a slow beat.

Inputs:
  --capture-period-ms  measured median frame dt (from report flash_meta)
  --marker-period-s    fixture marker period (2.0 for rk=20)
  --timeseries         optional offset CSV to measure phase walk empirically
  --report             optional report.json

Every value tagged measured|caller_supplied|DEFAULT_ASSUMED|derived|NO-DATA.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import sys
from pathlib import Path


def beat_model(T_cap_ms: float, T_mark_s: float) -> dict:
    T_mark_ms = float(T_mark_s) * 1000.0
    if T_cap_ms <= 0 or T_mark_ms <= 0:
        return {"ok": False, "reason": "nonpositive_period"}
    # phase advance of marker relative to capture grid, per marker
    ratio = T_mark_ms / T_cap_ms
    n_frames = int(math.floor(ratio + 1e-12))
    frac = ratio - n_frames  # fractional bin advance per marker in [0,1)
    # also exact mod
    phase_step_ms = T_mark_ms - n_frames * T_cap_ms
    if phase_step_ms < -1e-9:
        phase_step_ms += T_cap_ms
    # beat: how many markers until phase wraps ~1 bin
    if abs(phase_step_ms) < 1e-9 or abs(frac) < 1e-12 or abs(1 - frac) < 1e-12:
        markers_per_beat = None
        beat_s = None
        commensurate = True
    else:
        # k * phase_step ≡ 0 (mod T_cap) → k = T_cap / gcd(phase_step, T_cap)
        # integer-µs gcd (stable for lab 33ms / 20ms → k=33 markers → 66s)
        from math import gcd
        ps_us = int(round(abs(phase_step_ms) * 1000.0))
        tc_us = int(round(T_cap_ms * 1000.0))
        g = gcd(ps_us, tc_us) or 1
        markers_per_beat = float(tc_us // g)
        beat_s = markers_per_beat * T_mark_s
        commensurate = False
    quant_rms = T_cap_ms / math.sqrt(12.0)
    # If phase is slow-walking, residual of offset vs time can show period ~beat_s
    # Peak-to-peak sampling error bound still <= T_cap; RMS still ~T/sqrt(12) if
    # many full beats average — but a 60s window covering partial beat can look
    # STABLE or WANDER depending on which arc of the beat is sampled.
    return {
        "ok": True,
        "capture_period_ms": T_cap_ms,
        "capture_period_ms_src": "caller_or_measured",
        "marker_period_s": T_mark_s,
        "marker_period_ms": T_mark_ms,
        "frames_per_marker_ratio": ratio,
        "frames_per_marker_floor": n_frames,
        "fractional_bin_advance": frac,
        "phase_step_ms": phase_step_ms,
        "commensurate_exact": commensurate,
        "markers_per_beat_approx": markers_per_beat,
        "beat_period_s_approx": beat_s,
        "quant_rms_uniform_ms": quant_rms,
        "quant_model": "T/sqrt(12) valid iff flash phase ~U(0,T) independent each marker",
        "quant_model_valid_when": (
            "async OR many full beats averaged; INVALID as sole floor for a "
            "window shorter than ~1 beat when phase_step is small but nonzero"
        ),
        "note": (
            "If beat_period_s is tens of seconds, STABLE/WANDER flips across "
            "adjacent 60s windows can be sampling different beat phases — not "
            "device intermittency (parent ERROR 21 class)."
        ),
    }


def empirical_phase(times_s: list[float], T_cap_ms: float) -> dict:
    if len(times_s) < 3 or T_cap_ms <= 0:
        return {"ok": False, "src": "NO-DATA"}
    T = T_cap_ms / 1000.0
    # phase in [0,T): t mod T
    phases = [math.fmod(t, T) for t in times_s]
    # unwrap steps
    steps = []
    for i in range(1, len(phases)):
        d = phases[i] - phases[i - 1]
        # bring to [-T/2,T/2]
        while d > T / 2:
            d -= T
        while d < -T / 2:
            d += T
        steps.append(d * 1000.0)
    return {
        "ok": True,
        "n": len(phases),
        "phase_ms_p50": statistics.median([p * 1000 for p in phases]),
        "phase_step_ms_median": statistics.median(steps) if steps else None,
        "phase_step_ms_mean": statistics.fmean(steps) if steps else None,
        "src": "measured_from_t_flash_mod_Tcap",
        "note": "wallclock PTS may not sit on a rigid capture grid; interpret cautiously",
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--capture-period-ms", type=float, default=None)
    ap.add_argument("--marker-period-s", type=float, default=2.0)
    ap.add_argument("--marker-period-src", default="caller_supplied")
    ap.add_argument("--report", type=Path, default=None)
    ap.add_argument("--timeseries", type=Path, default=None)
    ap.add_argument("--json-out", type=Path, default=None)
    args = ap.parse_args()

    T_cap = args.capture_period_ms
    T_src = "caller_supplied" if T_cap is not None else "NO-DATA"
    times: list[float] = []

    if args.report and args.report.is_file():
        doc = json.loads(args.report.read_text())
        r = doc.get("result") or {}
        fm = r.get("flash_meta") or {}
        m = r.get("margin") or doc.get("margin") or {}
        per = m.get("video_sample_period_ms") or fm.get("capture_frame_period_ms")
        if per is not None and T_cap is None:
            T_cap = float(per)
            T_src = "measured_report"
        for p in r.get("pairs") or []:
            times.append(float(p["t_flash_s"]))
        if not times and doc.get("flash_onset_s"):
            times = [float(x) for x in doc["flash_onset_s"]]

    if args.timeseries and args.timeseries.is_file():
        with args.timeseries.open() as f:
            rd = csv.DictReader(f)
            for row in rd:
                times.append(float(row["t_flash_s"]))

    if T_cap is None:
        print("capture_period_ms=NO-DATA src=NO-DATA")
        print("VERDICT=UNSCORED rc=77 reason=need_capture_period_ms_or_report")
        return 77

    print(f"capture_period_ms={T_cap} src={T_src}")
    print(f"marker_period_s={args.marker_period_s} src={args.marker_period_src}")
    model = beat_model(float(T_cap), float(args.marker_period_s))
    for k, v in model.items():
        if k == "ok":
            continue
        src = "derived" if k not in (
            "capture_period_ms", "marker_period_s", "marker_period_ms"
        ) else T_src if "capture" in k else args.marker_period_src
        print(f"{k}={v} src={src}")

    emp = empirical_phase(times, float(T_cap)) if times else {"ok": False, "src": "NO-DATA"}
    print(f"empirical_phase={emp}")

    # Live lab default numbers for parent paste
    print("=== LAB DEFAULTS (from prior live reports if T=33.0 mark=2.0) ===")
    lab = beat_model(33.0, 2.0)
    print(
        f"lab_T_cap_ms=33.0 lab_mark_s=2.0 phase_step_ms={lab['phase_step_ms']:.6f} "
        f"beat_period_s_approx={lab['beat_period_s_approx']} "
        f"quant_rms={lab['quant_rms_uniform_ms']:.4f} src=derived_from_measured_T33"
    )
    if lab["beat_period_s_approx"]:
        print(
            f"lab_note: ~{lab['beat_period_s_approx']:.1f}s beat → two adjacent 60s "
            f"windows can sample different arcs; STABLE/WANDER flip ≠ intermittency"
        )

    out = {"model": model, "empirical_phase": emp, "capture_period_ms_src": T_src}
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(out, indent=2) + "\n")
        print(f"json_out={args.json_out}")

    print("VERDICT=BEAT_MODEL_OK rc=0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
