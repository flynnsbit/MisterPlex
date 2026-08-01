#!/usr/bin/env python3
"""Definitive glass-side hold + skip instrument (primary while ARM frames_done is void).

Context (parent 2026-08-01)
---------------------------
Deployed RBF c5382bee packs bank_vsync_count into the field labelled frames_done
(increment every vsync). Tip frames_done_d2 never fitted. ARM drops/presents/
FRAME_LEDGER derived from that field are **void**. Glass OCR / captured pixels
are the only trustworthy skip evidence until a new RBF lands.

This tool is the single entry point the parent runs on a capture directory.
It wraps tools/glass_template_skip.py (checksum + completeness + ERROR18/19
margin) and adds the hold-length / timing report the parent needs to match
publish-interval and catch-up findings.

Emits
-----
  - hold_length_histogram  (consecutive accepted captures with same n)
  - hold_mean / hold_median / hold_trimmed_mean (trim 5% each tail)
  - skip count (genuine only if sampling margin OK — else UNSCORED candidates)
  - plateau fraction hold>=4 (comparable to parent HDMI ge4)
  - inter-accept interval median/trimmed mean from pts.csv (span-local;
    startup/teardown trimmed; NEVER raw mean alone — parent sigma_ms=500 trap)
  - acf lag-1 of hold lengths or of advance intervals (catch-up signature)
  - PASS / FAIL / UNSCORED with pre-registered thresholds printed FIRST

Pre-register (locked before scoring — do not move below compute)
---------------------------------------------------------------
  Ideal hold at cap_fps/src_fps (e.g. 60/24 = 2.5).
  P_hold_mean_ok_band     = ideal ± 0.08
  P_frac_ge4_healthy      = [0.00, 0.03]   # pure 2/3
  P_frac_ge4_device_lean  = [0.05, 0.15]   # matches parent HDMI ~0.10
  P_genuine_skip_frac_fail = 0.005         # ≥0.5% genuine → FAIL when margin OK
  P_min_accepted           = 200
  Sampling margin: max_pts_iv < min_hold_ms = 1000/refresh (RTL 1 vsync)
    else UNSCORED (ERROR18/19) — never PASS, never FAIL-as-device.

Exit codes
----------
  0  HOLD_SKIP_OK
  2  HOLD_SKIP_FAIL   (genuine skips over threshold OR hold ge4 in fail band with margin)
  3  INSTRUMENT_FAIL  (decreasing pairs / decode physics)
  77 UNSCORED         (margin refuse / insufficient / fps assumed) — never a pass
  1  usage

Provenance: every number tagged measured | caller_supplied | DEFAULT_ASSUMED.

Usage
-----
  python3 tools/glass_hold_skip.py --self-test; echo "true rc=$?"
  python3 tools/glass_hold_skip.py /tmp/p60/png \\
      --templates /tmp/p60/T60.pkl --pts /tmp/p60/pts.csv \\
      --source-fps 24 --capture-fps 60 --refresh-hz 60 --force-mode 720 \\
      ; echo "true rc=$?"
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from glass_template_skip import (  # noqa: E402
    PROVENANCE_CALLER,
    PROVENANCE_DEFAULT,
    PROVENANCE_MEASURED,
    RC_INSTRUMENT_FAIL,
    RC_OK,
    RC_SKIP_FAIL,
    RC_UNSCORED,
    RC_USAGE,
    TemplateBank,
    leave_one_frame_out,
    score_capture_dir,
)

# Pre-registered constants (design bounds — labelled DEFAULT_ASSUMED in report)
P_HOLD_MEAN_TOL = 0.08
P_FRAC_GE4_HEALTHY = (0.00, 0.03)
P_FRAC_GE4_DEVICE = (0.05, 0.15)
P_GENUINE_SKIP_FRAC_FAIL = 0.005
P_MIN_ACCEPTED = 200
P_TRIM_FRAC = 0.05
P_STARTUP_DROP_FRAC = 0.05  # drop first/last 5% of intervals (startup/teardown)


def pre_register(
    *,
    source_fps: float,
    capture_fps: float,
    refresh_hz: float,
    source_fps_src: str,
    capture_fps_src: str,
    refresh_hz_src: str,
) -> dict[str, Any]:
    ideal_hold = capture_fps / source_fps if source_fps > 0 else float("nan")
    min_hold_ms = 1000.0 / refresh_hz if refresh_hz > 0 else float("nan")
    pr = {
        "PRE_REGISTER": True,
        "ideal_hold_captures_per_source": ideal_hold,
        "ideal_hold_src": (
            "caller_supplied_ratio"
            if source_fps_src != PROVENANCE_DEFAULT
            and capture_fps_src != PROVENANCE_DEFAULT
            else PROVENANCE_DEFAULT
        ),
        "P_hold_mean_ok_band": [
            ideal_hold - P_HOLD_MEAN_TOL,
            ideal_hold + P_HOLD_MEAN_TOL,
        ],
        "P_frac_ge4_healthy": list(P_FRAC_GE4_HEALTHY),
        "P_frac_ge4_device_lean": list(P_FRAC_GE4_DEVICE),
        "P_genuine_skip_frac_fail": P_GENUINE_SKIP_FRAC_FAIL,
        "P_min_accepted": P_MIN_ACCEPTED,
        "P_trim_frac": P_TRIM_FRAC,
        "P_startup_teardown_drop_frac": P_STARTUP_DROP_FRAC,
        "min_hold_ms_rtl": min_hold_ms,
        "min_hold_ms_src": "RTL_derived(1_vsync)",
        "refresh_hz": refresh_hz,
        "refresh_hz_src": refresh_hz_src,
        "source_fps": source_fps,
        "source_fps_src": source_fps_src,
        "capture_fps": capture_fps,
        "capture_fps_src": capture_fps_src,
        "note": (
            "UNSCORED if sampling margin violated or accepted<P_min. "
            "FAIL only on margin-OK genuine skip frac or instrument physics. "
            "ge4 in device band is reported; does not alone FAIL without margin."
        ),
        "arm_frames_done_void": True,
        "arm_frames_done_void_reason": (
            "deployed RBF c5382bee packs bank_vsync_count as frames_done; "
            "glass is sole skip evidence until new fit"
        ),
    }
    print("PRE-REGISTER glass_hold_skip (before any scoring):")
    for k, v in pr.items():
        if k == "PRE_REGISTER":
            continue
        print(f"  {k}={v}")
    return pr


def _trimmed_mean(x: np.ndarray, frac: float = P_TRIM_FRAC) -> float:
    if x.size == 0:
        return float("nan")
    y = np.sort(np.asarray(x, dtype=np.float64))
    k = int(np.floor(frac * len(y)))
    if 2 * k >= len(y):
        return float(np.mean(y))
    return float(np.mean(y[k : len(y) - k]))


def _acf_lag1(x: np.ndarray) -> float:
    if x.size < 3:
        return float("nan")
    y = x.astype(np.float64)
    y = y - y.mean()
    v = float(np.dot(y, y))
    if v < 1e-18:
        return 0.0
    return float(np.dot(y[:-1], y[1:]) / v)


def holds_from_accepted(accepted_ns: list[int]) -> list[int]:
    """RLE plateau lengths on the accepted counter sequence (capture units)."""
    if not accepted_ns:
        return []
    holds: list[int] = []
    run = 1
    for a, b in zip(accepted_ns, accepted_ns[1:]):
        if b == a:
            run += 1
        else:
            holds.append(run)
            run = 1
    holds.append(run)
    return holds


def span_local_intervals_ms(pts_s: list[float] | None) -> dict[str, Any]:
    """Median/trimmed mean of capture intervals; drop startup/teardown tails."""
    out: dict[str, Any] = {
        "n_raw": 0,
        "n_span_local": 0,
        "median_ms": None,
        "trimmed_mean_ms": None,
        "mean_ms_raw_DO_NOT_USE_ALONE": None,
        "sigma_ms_raw": None,
        "src": PROVENANCE_DEFAULT,
    }
    if not pts_s or len(pts_s) < 4:
        return out
    iv = np.diff(np.asarray(pts_s, dtype=np.float64)) * 1000.0
    # drop absurd outliers (>100ms) then startup/teardown by index fraction
    finite = iv[np.isfinite(iv)]
    core = finite[finite < 100.0]
    n = len(core)
    drop = int(np.floor(P_STARTUP_DROP_FRAC * n))
    if 2 * drop < n:
        span = core[drop : n - drop]
    else:
        span = core
    out.update(
        {
            "n_raw": int(len(finite)),
            "n_span_local": int(len(span)),
            "median_ms": round(float(np.median(span)), 4) if span.size else None,
            "trimmed_mean_ms": round(_trimmed_mean(span), 4) if span.size else None,
            "mean_ms_raw_DO_NOT_USE_ALONE": round(float(np.mean(finite)), 4)
            if finite.size
            else None,
            "sigma_ms_raw": round(float(np.std(finite)), 4) if finite.size else None,
            "src": PROVENANCE_MEASURED,
            "note": (
                "Use median/trimmed_mean on span-local intervals. "
                "Raw mean+sigma are outlier-contaminated (parent mean=50.4 sigma=500)."
            ),
        }
    )
    return out


def analyze_holds_and_verdict(rep: dict[str, Any], pr: dict[str, Any]) -> dict[str, Any]:
    """Build hold hist + verdict on top of glass_template_skip report."""
    # Rebuild accepted n sequence from genuine path is not in rep — need per_frame.
    # score_capture_dir doesn't return full per_frame; use summary fields + optional
    # reconstruction from events. For holds we need the accepted sequence.
    # Caller must pass accepted_ns via rep['_accepted_ns'] when available.
    accepted_ns = list(rep.get("_accepted_ns") or [])
    holds = holds_from_accepted(accepted_ns)
    hc = Counter(holds)
    n_h = len(holds)
    mean_h = float(np.mean(holds)) if holds else float("nan")
    med_h = float(np.median(holds)) if holds else float("nan")
    trim_h = _trimmed_mean(np.asarray(holds, dtype=np.float64)) if holds else float("nan")
    ge4 = sum(v for k, v in hc.items() if k >= 4)
    frac_ge4 = ge4 / n_h if n_h else float("nan")
    c2, c3 = hc.get(2, 0), hc.get(3, 0)
    ratio23 = (c2 / c3) if c3 else float("nan")
    acf_h = _acf_lag1(np.asarray(holds, dtype=np.float64)) if holds else float("nan")

    # advance series for catch-up: deltas of accepted n on adjacent accepts
    adv = []
    for a, b in zip(accepted_ns, accepted_ns[1:]):
        adv.append(b - a)
    acf_adv = _acf_lag1(np.asarray(adv, dtype=np.float64)) if len(adv) >= 3 else float("nan")

    sm = rep.get("sampling_margin") or {}
    refuse = bool(sm.get("refuse_skip_verdict", True))
    n_acc = int(rep.get("n_accepted") or 0)
    genuine = int(rep.get("genuine_display_skips") or 0)
    span = max(1, int(rep.get("adv_span") or 1))
    genuine_frac = genuine / float(span)

    ideal = float(pr["ideal_hold_captures_per_source"])
    hold_mean_ok = abs(mean_h - ideal) <= P_HOLD_MEAN_TOL if n_h else False

    # Verdict
    if n_acc < P_MIN_ACCEPTED:
        verdict, rc = "UNSCORED", RC_UNSCORED
        reason = f"accepted={n_acc}<{P_MIN_ACCEPTED}"
    elif int(rep.get("decreasing_pairs") or 0) > 0:
        verdict, rc = "INSTRUMENT_FAIL", RC_INSTRUMENT_FAIL
        reason = f"decreasing_pairs={rep.get('decreasing_pairs')}"
    elif refuse:
        verdict, rc = "UNSCORED", RC_UNSCORED
        reason = str(sm.get("reason", "sampling_margin_refused"))
    elif rep.get("rc") == RC_INSTRUMENT_FAIL:
        verdict, rc = "INSTRUMENT_FAIL", RC_INSTRUMENT_FAIL
        reason = str(rep.get("reason"))
    elif genuine_frac >= P_GENUINE_SKIP_FRAC_FAIL and genuine > 0:
        verdict, rc = "HOLD_SKIP_FAIL", RC_SKIP_FAIL
        reason = f"genuine_frac={genuine_frac:.4f}>={P_GENUINE_SKIP_FRAC_FAIL}"
    elif genuine > 0:
        # margin OK but below fail frac — still FAIL on any proven skip (strict)
        verdict, rc = "HOLD_SKIP_FAIL", RC_SKIP_FAIL
        reason = f"genuine_display_skips={genuine} (any proven skip is FAIL)"
    elif rep.get("verdict") == "SKIP_OK" or (
        genuine == 0 and not refuse and n_acc >= P_MIN_ACCEPTED
    ):
        verdict, rc = "HOLD_SKIP_OK", RC_OK
        reason = (
            f"genuine=0 margin_ok hold_mean={mean_h:.3f} ideal={ideal:.3f} "
            f"frac_ge4={frac_ge4:.4f}"
        )
    else:
        verdict, rc = "UNSCORED", RC_UNSCORED
        reason = str(rep.get("reason", "underlying_unscored"))

    # Band labels for hold ge4 (informational; do not alone drive FAIL)
    if n_h >= 50 and not np.isnan(frac_ge4):
        if P_FRAC_GE4_HEALTHY[0] <= frac_ge4 <= P_FRAC_GE4_HEALTHY[1]:
            ge4_band = "healthy_2_3"
        elif P_FRAC_GE4_DEVICE[0] <= frac_ge4 <= P_FRAC_GE4_DEVICE[1]:
            ge4_band = "device_lean_matches_hdmi"
        else:
            ge4_band = "other"
    else:
        ge4_band = "unscored_n"

    return {
        "verdict": verdict,
        "rc": rc,
        "reason": reason,
        "hold_hist": {str(k): int(hc[k]) for k in sorted(hc)},
        "hold_n": n_h,
        "hold_n_src": PROVENANCE_MEASURED,
        "hold_mean": round(mean_h, 4) if holds else None,
        "hold_median": round(med_h, 4) if holds else None,
        "hold_trimmed_mean": round(trim_h, 4) if holds else None,
        "hold_mean_ok": hold_mean_ok,
        "hold_frac_ge4": round(frac_ge4, 4) if n_h else None,
        "hold_ge4_band": ge4_band,
        "hold_ratio_2_3": round(ratio23, 4) if c3 else None,
        "hold_acf_lag1": round(acf_h, 4) if holds else None,
        "advance_acf_lag1": round(acf_adv, 4) if len(adv) >= 3 else None,
        "acf_note": (
            "negative lag1 ⇒ long followed by short (catch-up); "
            f"parent publish acf_lag1=-0.1950 caller_supplied"
        ),
        "genuine_display_skips": genuine,
        "genuine_frac_of_span": round(genuine_frac, 6),
        "margin_unresolved_candidates": rep.get("margin_unresolved_candidates"),
        "confirmed_torn": rep.get("torn_transition_not_skip"),
        "unresolved_band": rep.get("unresolved_band"),
        "ideal_hold": ideal,
        "ideal_hold_src": pr["ideal_hold_src"],
    }


def score(
    capture_dir: Path,
    *,
    templates: Path,
    pts: Path | None,
    source_fps: float,
    capture_fps: float,
    refresh_hz: float,
    source_fps_src: str,
    capture_fps_src: str,
    refresh_hz_src: str,
    force_mode: str | None,
    warmup_skip: int,
    progress: bool,
) -> dict[str, Any]:
    pr = pre_register(
        source_fps=source_fps,
        capture_fps=capture_fps,
        refresh_hz=refresh_hz,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
        refresh_hz_src=refresh_hz_src,
    )
    bank = TemplateBank.load(templates)
    # Need accepted n sequence — call score_capture_dir then re-decode is expensive.
    # Patch: use internal list via a thin re-implementation path.
    from glass_template_skip import (
        derive_overlay_geometry,
        decode_frame,
        list_pngs,
        load_pts_ms,
        sampling_margin_gate,
        analyze_completeness,
        yellow_mask,
    )
    from PIL import Image

    files = list_pngs(capture_dir)
    pts_s = None
    pts_src = PROVENANCE_DEFAULT
    if pts is not None and Path(pts).is_file():
        pts_s, pts_src = load_pts_ms(Path(pts))

    margin = sampling_margin_gate(
        pts_s,
        source_fps=source_fps,
        refresh_hz=refresh_hz,
        source_fps_src=source_fps_src,
        refresh_hz_src=refresh_hz_src,
    )
    geom = None
    per_frame: list[dict[str, Any]] = []
    for i, path in enumerate(files):
        if i < warmup_skip:
            per_frame.append(
                {
                    "idx": i,
                    "path": str(path),
                    "ok": False,
                    "n": None,
                    "status": "warmup_skip",
                }
            )
            continue
        rgb = np.asarray(Image.open(path).convert("RGB"))
        if geom is None:
            geom = derive_overlay_geometry(rgb, force_mode=force_mode)
        r = decode_frame(rgb, bank, geom=geom, force_mode=force_mode, dist_max=8.0)
        r["idx"] = i
        r["path"] = str(path)
        if pts_s is not None and i < len(pts_s):
            r["pts_s"] = pts_s[i]
        per_frame.append(r)
        if progress and (i + 1) % 400 == 0:
            print(
                f"  ... {i+1}/{len(files)} ok={sum(1 for x in per_frame if x.get('ok'))}",
                file=sys.stderr,
            )

    rep = analyze_completeness(
        per_frame,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
        margin=margin,
        bank=bank,
        geom=geom,
        enable_band_validation=True,
        dist_max=8.0,
    )
    accepted_ns = [
        int(r["n"])
        for r in per_frame
        if r.get("ok") and r.get("n") is not None
    ]
    rep["_accepted_ns"] = accepted_ns
    hold = analyze_holds_and_verdict(rep, pr)
    iv = span_local_intervals_ms(pts_s)

    out = {
        **hold,
        "n_frames": rep.get("n_frames"),
        "n_accepted": rep.get("n_accepted"),
        "accepted_frac": rep.get("accepted_frac"),
        "span_ratio": rep.get("span_ratio"),
        "adj_hist": rep.get("adjacent_delta_histogram"),
        "sampling_margin": margin,
        "capture_intervals": iv,
        "pre_register": pr,
        "underlying_verdict": rep.get("verdict"),
        "underlying_rc": rep.get("rc"),
        "underlying_reason": rep.get("reason"),
        "genuine_events": rep.get("genuine_events"),
        "margin_unresolved_events": rep.get("margin_unresolved_events"),
        "band_validation": rep.get("band_validation"),
        "G_grabber_confound": rep.get("G_grabber_confound"),
        "G_note": rep.get("G_note"),
        "templates": str(templates),
        "capture_dir": str(capture_dir),
        "pts_src": pts_src,
    }
    return out


def run_self_test() -> int:
    """Synth green/red via glass_template_skip fixtures + hold stats."""
    from glass_template_skip import (
        bootstrap_templates_sim,
        _synth_sequence,
        _render_hdmi_frame,
    )

    work = ROOT / ".agent-work" / "w-instr" / "hold-skip-gate"
    work.mkdir(parents=True, exist_ok=True)
    bank, _ = bootstrap_templates_sim(path=work / "templates_sim.npz")
    green = work / "green120"
    red = work / "red120"
    g_pts = work / "g_pts.csv"
    r_pts = work / "r_pts.csv"
    _synth_sequence(green, n0=1000, n_source_frames=48, capture_fps=120.0, pts_path=g_pts)
    _synth_sequence(
        red,
        n0=1000,
        n_source_frames=72,
        capture_fps=120.0,
        skip_at_source={1017, 1034, 1051, 1068},
        pts_path=r_pts,
    )
    tpath = work / "templates_sim.npz"
    bank.save(tpath)

    ok = True
    g = score(
        green,
        templates=tpath,
        pts=g_pts,
        source_fps=24.0,
        capture_fps=120.0,
        refresh_hz=60.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
        refresh_hz_src=PROVENANCE_CALLER,
        force_mode="sim",
        warmup_skip=0,
        progress=False,
    )
    print(
        f"GREEN verdict={g['verdict']} rc={g['rc']} hold_mean={g['hold_mean']} "
        f"hist={g['hold_hist']} genuine={g['genuine_display_skips']}"
    )
    if g["rc"] != RC_OK or g["genuine_display_skips"] != 0:
        print("FAIL GREEN")
        ok = False
    else:
        print("PASS GREEN")

    r = score(
        red,
        templates=tpath,
        pts=r_pts,
        source_fps=24.0,
        capture_fps=120.0,
        refresh_hz=60.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
        refresh_hz_src=PROVENANCE_CALLER,
        force_mode="sim",
        warmup_skip=0,
        progress=False,
    )
    print(
        f"RED verdict={r['verdict']} rc={r['rc']} genuine={r['genuine_display_skips']} "
        f"reason={r['reason']}"
    )
    if r["rc"] != RC_SKIP_FAIL or r["genuine_display_skips"] < 1:
        print("FAIL RED")
        ok = False
    else:
        print("PASS RED")

    # ERROR19 path: 60fps exact intervals == min_hold → margin refuse UNSCORED
    # Need accepted>=P_min so we do not UNSCORE solely on n_accepted.
    z = work / "z60"
    z_pts = work / "z60_pts.csv"
    _synth_sequence(z, n0=2000, n_source_frames=120, capture_fps=60.0, pts_path=z_pts)
    zz = score(
        z,
        templates=tpath,
        pts=z_pts,
        source_fps=24.0,
        capture_fps=60.0,
        refresh_hz=60.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
        refresh_hz_src=PROVENANCE_CALLER,
        force_mode="sim",
        warmup_skip=0,
        progress=False,
    )
    sm = zz.get("sampling_margin") or {}
    if zz["rc"] != RC_UNSCORED or not sm.get("refuse_skip_verdict", False):
        print(f"FAIL ERROR19 want 77+refuse got {zz['rc']} margin={sm} reason={zz['reason']}")
        ok = False
    else:
        print(
            f"PASS ERROR19 UNSCORED rc=77 refuse "
            f"max_iv={sm.get('max_measured_capture_interval_ms')} "
            f"min_hold={sm.get('min_hold_ms')} reason={zz['reason']}"
        )

    if ok:
        print("SELF_TEST_OK")
        return RC_OK
    print("SELF_TEST_FAIL")
    return RC_INSTRUMENT_FAIL


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("capture_dir", nargs="?", type=Path)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--templates", type=Path, required=False)
    ap.add_argument("--pts", type=Path, default=None)
    ap.add_argument("--source-fps", type=float, default=None)
    ap.add_argument("--capture-fps", type=float, default=None)
    ap.add_argument("--refresh-hz", type=float, default=None)
    ap.add_argument("--force-mode", choices=("720", "1080", "sim"), default=None)
    ap.add_argument("--warmup-skip", type=int, default=0)
    ap.add_argument("--progress", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return run_self_test()
    if not args.capture_dir or not args.templates:
        ap.error("capture_dir and --templates required (or --self-test)")
        return RC_USAGE

    if args.source_fps is None:
        src_fps, src_src = 24.0, PROVENANCE_DEFAULT
    else:
        src_fps, src_src = float(args.source_fps), PROVENANCE_CALLER
    if args.capture_fps is None:
        cap_fps, cap_src = 60.0, PROVENANCE_DEFAULT
    else:
        cap_fps, cap_src = float(args.capture_fps), PROVENANCE_CALLER
    if args.refresh_hz is None:
        ref, ref_src = 60.0, PROVENANCE_DEFAULT
    else:
        ref, ref_src = float(args.refresh_hz), PROVENANCE_CALLER

    # Refuse rate-ish PASS path if fps DEFAULT — still allow hold report as UNSCORED
    out = score(
        args.capture_dir,
        templates=args.templates,
        pts=args.pts,
        source_fps=src_fps,
        capture_fps=cap_fps,
        refresh_hz=ref,
        source_fps_src=src_src,
        capture_fps_src=cap_src,
        refresh_hz_src=ref_src,
        force_mode=args.force_mode,
        warmup_skip=args.warmup_skip,
        progress=args.progress,
    )
    if args.json:
        print(json.dumps(out, indent=2, default=str))
    else:
        print(
            f"VERDICT={out['verdict']} rc={out['rc']} reason={out['reason']}"
        )
        print(
            f"accepted={out['n_accepted']}/{out['n_frames']} "
            f"span_ratio={out['span_ratio']} adj_hist={out['adj_hist']}"
        )
        print(
            f"hold_hist={out['hold_hist']} n={out['hold_n']} "
            f"mean={out['hold_mean']} median={out['hold_median']} "
            f"trim={out['hold_trimmed_mean']} ideal={out['ideal_hold']} "
            f"frac_ge4={out['hold_frac_ge4']} band={out['hold_ge4_band']} "
            f"ratio2_3={out['hold_ratio_2_3']}"
        )
        print(
            f"hold_acf_lag1={out['hold_acf_lag1']} "
            f"advance_acf_lag1={out['advance_acf_lag1']} "
            f"({out['acf_note']})"
        )
        iv = out.get("capture_intervals") or {}
        print(
            f"cap_iv median_ms={iv.get('median_ms')} "
            f"trim_mean_ms={iv.get('trimmed_mean_ms')} "
            f"raw_mean_DO_NOT_USE={iv.get('mean_ms_raw_DO_NOT_USE_ALONE')} "
            f"raw_sigma={iv.get('sigma_ms_raw')} "
            f"n_span={iv.get('n_span_local')} src={iv.get('src')}"
        )
        sm = out.get("sampling_margin") or {}
        print(
            f"margin_ok={sm.get('margin_ok')} max_iv={sm.get('max_measured_capture_interval_ms')} "
            f"min_hold={sm.get('min_hold_ms')} refuse={sm.get('refuse_skip_verdict')}"
        )
        print(
            f"genuine={out['genuine_display_skips']} "
            f"margin_unresolved={out.get('margin_unresolved_candidates')} "
            f"confirmed_torn={out.get('confirmed_torn')} "
            f"unresolved_band={out.get('unresolved_band')}"
        )
        for e in out.get("genuine_events") or []:
            print(
                f"GENUINE_SKIP v={e.get('v')} "
                f"a={e.get('bracket_a_file')} b={e.get('bracket_b_file')}"
            )
        for e in (out.get("margin_unresolved_events") or [])[:5]:
            print(f"MARGIN_UNRESOLVED v={e.get('v')}")
    return int(out["rc"])


if __name__ == "__main__":
    sys.exit(main())
