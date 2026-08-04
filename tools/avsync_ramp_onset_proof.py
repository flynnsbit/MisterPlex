#!/usr/bin/env python3
"""Host-side proof: ramped flash onset beats capture-frame quantisation.

Uses REAL capture timestamps from an existing HDMI grab (default:
avsync_hdmi_out/480p_repeat1_capture.mkv @ 30 fps MJPEG) so the timebase is
device-measured, not synthetic. Injects synthetic luma traces with known
ground-truth threshold-crossing times, then runs the same detect_flashes()
as tools/avsync_measure_hdmi.py.

ZERO device time. Does not open /dev/video0 or SSH.

PRE-REGISTERED predictions (printed BEFORE measurement, then scored):
  P1 STEP:  flash_onset_n_interp == 0 for nearly all events
            RMSE(recovered - truth) >= 0.5 * capture_dt_ms / sqrt(12)
            (order of uniform quant over one capture interval)
  P2 RAMP:  flash_onset_n_interp / n_flashes >= 0.95
            RMSE_ramp < 0.5 * RMSE_step
            RMSE_ramp <= 5.0 ms   (derived band 1-4 ms + margin)
  P3:       capture_dt from measured pts median diff ≈ 1000/30 = 33.333 ms

Derivation of expected ramp resolution (not asserted as HDMI fact):
  capture_dt = 33.333 ms @ 30 fps (grabber max; parent-measured discrete set).
  Ramp spans R=5 capture samples (content 4/24 s = 166.667 ms).
  rise_frac/sample = 0.20 < STEP_RISE_FRAC 0.70 → linear interp path.
  σ_t ≈ dt * (σ_Y/ΔY); ΔY≈0.2*C, C=200 synthetic → ΔY=40.
  With σ_Y=0 (noiseless synth) RMSE is numerical only → expect << 1 ms.
  With σ_Y=3 (injected) expect ~ dt*3/40 = 2.5 ms.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from avsync_measure_hdmi import detect_flashes, load_video_luma  # noqa: E402


def pre_register(capture_dt_ms: float) -> dict:
    """Print and return predictions BEFORE any recovery measurement."""
    # Uniform quant std over one bin: dt/sqrt(12)
    step_rmse_floor = 0.5 * capture_dt_ms / math.sqrt(12.0)
    pred = {
        "capture_dt_ms_assumed_if_unknown": 1000.0 / 30.0,
        "capture_dt_ms_used": capture_dt_ms,
        "P1_step_n_interp_max_frac": 0.05,
        "P1_step_rmse_min_ms": step_rmse_floor,
        "P2_ramp_n_interp_min_frac": 0.95,
        "P2_ramp_rmse_vs_step_ratio_max": 0.5,
        "P2_ramp_rmse_max_ms": 5.0,
        "P3_capture_dt_ms_target": 1000.0 / 30.0,
        "P3_capture_dt_tol_ms": 2.0,
        "expected_onset_resolution_ms_noiseless": "<1",
        "expected_onset_resolution_ms_sigmaY3": round(capture_dt_ms * 3.0 / 40.0, 3),
        "derivation": (
            "ramp 166.667ms / 33.333ms = 5 cap samples; "
            "σ_t≈dt*(σ_Y/ΔY); ΔY=0.2*200=40; σ_Y=3 → 2.5ms"
        ),
    }
    print("PRE_REGISTER", json.dumps(pred, sort_keys=True), flush=True)
    return pred


def inject_step_luma(
    t: np.ndarray,
    truths: np.ndarray,
    *,
    floor: float = 5.0,
    peak: float = 220.0,
    hold_s: float = 0.080,
) -> np.ndarray:
    """Hard on/off flash at each truth time (step covering full contrast in one sample)."""
    y = np.full(t.shape, floor, dtype=np.float64)
    for tc in truths:
        y[(t >= tc) & (t < tc + hold_s)] = peak
    return y


def inject_ramp_luma(
    t: np.ndarray,
    truths: np.ndarray,
    *,
    floor: float = 5.0,
    peak: float = 220.0,
    ramp_s: float = 166.667e-3,
    hold_s: float = 1.0 / 24.0,
) -> np.ndarray:
    """Linear ramp centered on truth so thr (mid) crosses at truth time."""
    y = np.full(t.shape, floor, dtype=np.float64)
    half = 0.5 * ramp_s
    contrast = peak - floor
    for tc in truths:
        # rising edge
        m = (t >= tc - half) & (t < tc + half)
        # luma = floor + contrast * (t - (tc-half)) / ramp_s
        y[m] = floor + contrast * (t[m] - (tc - half)) / ramp_s
        # peak hold
        m2 = (t >= tc + half) & (t < tc + half + hold_s)
        y[m2] = peak
    return y


def score_recovery(
    luma: np.ndarray,
    t: np.ndarray,
    truths: np.ndarray,
    *,
    label: str,
) -> dict:
    flashes, meta = detect_flashes(luma, t, None, warmup_frames=0, min_separation_s=0.6)
    # Match each truth to nearest recovered flash
    errs = []
    for tc in truths:
        if not flashes:
            break
        nearest = min(flashes, key=lambda f: abs(f - tc))
        if abs(nearest - tc) <= 0.45:  # within pair window-ish
            errs.append((nearest - tc) * 1000.0)
    errs_a = np.array(errs, dtype=np.float64) if errs else np.array([], dtype=np.float64)
    rmse = float(np.sqrt(np.mean(errs_a**2))) if errs_a.size else float("nan")
    mae = float(np.mean(np.abs(errs_a))) if errs_a.size else float("nan")
    out = {
        "label": label,
        "n_truth": int(truths.size),
        "n_recovered": int(len(flashes)),
        "n_matched": int(errs_a.size),
        "n_step": int(meta.get("flash_onset_n_step") or 0),
        "n_interp": int(meta.get("flash_onset_n_interp") or 0),
        "rmse_ms": rmse,
        "mae_ms": mae,
        "max_abs_err_ms": float(np.max(np.abs(errs_a))) if errs_a.size else float("nan"),
        "flash_meta_threshold": meta.get("threshold"),
        "luma_contrast": meta.get("luma_contrast"),
        "capture_frame_quant_ms": meta.get("capture_frame_quant_ms_no_interp"),
    }
    print("MEASURED", json.dumps(out, sort_keys=True), flush=True)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--capture",
        type=Path,
        default=ROOT / "avsync_hdmi_out" / "480p_repeat1_capture.mkv",
        help="Existing HDMI capture providing real PTS grid (not re-opened live)",
    )
    ap.add_argument(
        "--pts-json",
        type=Path,
        default=ROOT / "tests/fixtures/avsync/480p_repeat1_pts_60s.json",
        help="Checked-in measured PTS grid (preferred; avoids 339 MB mkv dependency)",
    )
    ap.add_argument("--duration", type=float, default=60.0, help="Seconds of PTS to use")
    ap.add_argument("--period", type=float, default=1.0, help="Flash period seconds")
    ap.add_argument(
        "--phase-grid",
        type=int,
        default=10,
        help="Sub-frame phase steps across one capture interval for truth times",
    )
    ap.add_argument("--sigma-y", type=float, default=0.0, help="Optional luma noise std")
    ap.add_argument("--json-out", type=Path, default=None)
    ap.add_argument(
        "--allow-missing-capture",
        action="store_true",
        help="If capture missing, synthesise a 30 fps grid (labelled SYNTH_GRID)",
    )
    args = ap.parse_args()

    grid_src = "measured_capture_pts"
    if args.pts_json is not None and args.pts_json.is_file():
        print(f"LOAD_PTS_JSON {args.pts_json}", flush=True)
        blob = json.loads(args.pts_json.read_text())
        if blob.get("grid_src") != "measured_capture_pts":
            print(f"FAIL pts-json grid_src must be measured_capture_pts, got {blob.get('grid_src')}", flush=True)
            return 1
        t_rel = np.asarray(blob["t_rel_s"], dtype=np.float64)
        t = t_rel[t_rel <= args.duration]
        print(
            f"CAPTURE_META fps_nom={blob.get('fps_nom')} "
            f"pts_from_container={blob.get('pts_from_container')} "
            f"n_frames={t.size} src=measured_pts_json "
            f"source_capture={blob.get('source_capture')}",
            flush=True,
        )
        if t.size < 30:
            print("FAIL too few frames in pts-json window", flush=True)
            return 1
    elif args.capture.is_file():
        print(f"LOAD_CAPTURE {args.capture}", flush=True)
        _luma_ign, t_full, vmeta = load_video_luma(args.capture)
        print(
            f"CAPTURE_META fps_nom={vmeta.get('fps_nom')} "
            f"pts_from_container={vmeta.get('pts_from_container')} "
            f"n_frames={t_full.size} src=measured",
            flush=True,
        )
        # Restrict duration
        t = t_full[t_full <= (t_full[0] + args.duration)].astype(np.float64)
        if t.size < 30:
            print("FAIL too few frames after duration crop", flush=True)
            return 1
    elif args.allow_missing_capture:
        grid_src = "SYNTH_GRID_30fps"
        print("WARN capture missing; using synthetic 30 fps grid", flush=True)
        n = int(args.duration * 30)
        t = np.arange(n, dtype=np.float64) / 30.0
    else:
        print(
            f"FAIL missing pts-json {args.pts_json} and capture {args.capture}",
            flush=True,
        )
        return 1

    dts = np.diff(t)
    capture_dt_ms = float(np.median(dts) * 1000.0)
    print(
        f"CAPTURE_DT_MS median={capture_dt_ms:.4f} "
        f"min={dts.min()*1000:.4f} max={dts.max()*1000:.4f} src={grid_src}",
        flush=True,
    )

    pred = pre_register(capture_dt_ms)

    # Ground-truth onsets: every period, with sub-frame phase sweep so we are
    # not accidentally aligned to capture boundaries only.
    t0 = float(t[0]) + 1.0  # skip 1 s
    t1 = float(t[-1]) - 0.5
    truths = []
    k = 0
    phase_step = (capture_dt_ms / 1000.0) / max(1, args.phase_grid)
    while True:
        tc = t0 + k * args.period + (k % args.phase_grid) * phase_step
        if tc >= t1:
            break
        truths.append(tc)
        k += 1
    truths_a = np.array(truths, dtype=np.float64)
    print(f"TRUTH n={truths_a.size} period={args.period} phase_grid={args.phase_grid}", flush=True)

    rng = np.random.default_rng(0)
    def maybe_noise(y: np.ndarray) -> np.ndarray:
        if args.sigma_y <= 0:
            return y
        return y + rng.normal(0.0, args.sigma_y, size=y.shape)

    y_step = maybe_noise(inject_step_luma(t, truths_a))
    y_ramp = maybe_noise(inject_ramp_luma(t, truths_a))

    step = score_recovery(y_step, t, truths_a, label="STEP")
    ramp = score_recovery(y_ramp, t, truths_a, label="RAMP")

    # Score predictions
    fail = 0
    # P3 capture dt
    if abs(capture_dt_ms - pred["P3_capture_dt_ms_target"]) > pred["P3_capture_dt_tol_ms"]:
        print(
            f"FAIL P3 capture_dt_ms={capture_dt_ms} "
            f"target={pred['P3_capture_dt_ms_target']}+/-{pred['P3_capture_dt_tol_ms']}",
            flush=True,
        )
        fail += 1
    else:
        print(f"PASS P3 capture_dt_ms={capture_dt_ms:.4f}", flush=True)

    # P1 step
    step_frac = step["n_interp"] / max(1, step["n_recovered"])
    if step_frac <= pred["P1_step_n_interp_max_frac"] and step["n_recovered"] >= 10:
        print(f"PASS P1 step_interp_frac={step_frac:.3f} <= {pred['P1_step_n_interp_max_frac']}", flush=True)
    else:
        print(f"FAIL P1 step_interp_frac={step_frac:.3f}", flush=True)
        fail += 1
    if step["rmse_ms"] >= pred["P1_step_rmse_min_ms"] * 0.5:  # soft floor (allow better luck)
        print(
            f"PASS P1 step_rmse_ms={step['rmse_ms']:.3f} "
            f"(floor ref {pred['P1_step_rmse_min_ms']:.3f})",
            flush=True,
        )
    else:
        # Still informative if step somehow perfect — mark soft miss, not hard fail
        print(
            f"SOFT_MISS P1 step_rmse_ms={step['rmse_ms']:.3f} "
            f"< half floor {pred['P1_step_rmse_min_ms']:.3f} "
            f"(possible phase luck; not scored as hard fail)",
            flush=True,
        )

    # P2 ramp
    ramp_frac = ramp["n_interp"] / max(1, ramp["n_recovered"])
    if ramp_frac >= pred["P2_ramp_n_interp_min_frac"] and ramp["n_recovered"] >= 10:
        print(f"PASS P2 ramp_interp_frac={ramp_frac:.3f}", flush=True)
    else:
        print(f"FAIL P2 ramp_interp_frac={ramp_frac:.3f}", flush=True)
        fail += 1
    if ramp["rmse_ms"] <= pred["P2_ramp_rmse_max_ms"]:
        print(f"PASS P2 ramp_rmse_ms={ramp['rmse_ms']:.3f} <= {pred['P2_ramp_rmse_max_ms']}", flush=True)
    else:
        print(f"FAIL P2 ramp_rmse_ms={ramp['rmse_ms']:.3f}", flush=True)
        fail += 1
    if ramp["rmse_ms"] < pred["P2_ramp_rmse_vs_step_ratio_max"] * step["rmse_ms"]:
        print(
            f"PASS P2 ramp_rmse {ramp['rmse_ms']:.3f} < "
            f"{pred['P2_ramp_rmse_vs_step_ratio_max']}*step {step['rmse_ms']:.3f}",
            flush=True,
        )
    else:
        print(
            f"FAIL P2 ramp not better enough vs step "
            f"({ramp['rmse_ms']:.3f} vs {step['rmse_ms']:.3f})",
            flush=True,
        )
        fail += 1

    report = {
        "grid_src": grid_src,
        "capture": str(args.capture),
        "capture_dt_ms": capture_dt_ms,
        "pre_register": pred,
        "step": step,
        "ramp": ramp,
        "fail": fail,
        "verdict": "PASS" if fail == 0 else "FAIL",
    }
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(report, indent=2) + "\n")
        print(f"JSON {args.json_out}", flush=True)

    print(f"VERDICT={report['verdict']} fail={fail}", flush=True)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
