#!/usr/bin/env python3
"""Infer source vertical raster period from an HDMI capture frame.

*** PARTIAL WITHDRAWAL (rd-review / parent) ***
Period alone does NOT prove 240 vs 480 source rows: 480→720 also yields
period 3. max/min contrast inflates with period. For the B2 discriminator
use tools/hdmi_vstore_discriminate.py (n_low_phases at fundamental).
This tool remains for period/FFT cross-check reporting only.

Parent measurement (720p live OCR fixture)::

  period 2 (360 src lines) contrast 1.69
  period 3 (240)          contrast 10.97   ← winner
  period 4 (180)          contrast 3.21
  period 5 (144)          contrast 2.61
  period 6                17.51 but HARMONIC of 3, not independent
  horizontal: no strong period (best 1.42) — 529→1280 non-integer resample

RTL (quoted present_core.sv:161-164)::

  H_DE = 529
  V_STORE = 240
  STORE_Y_SCALE = (FRAME_H * 65536) / 240
  At FRAME_H=480 → scale=2.0 exact → store_y = py*2 → only even store rows.

Method A — phase-binned row-diff contrast (parent method)
  For candidate period p: mean |row[i]-row[i-1]| binned by (i mod p).
  contrast(p) = max_phase_mean / min_phase_mean (guard min>eps).

Method B — vertical autocorrelation / Fourier cross-check
  Autocorr of mean-row luma at lag p; also |FFT| peak at frequency N/p.
  Rank periods by normalized power.

Agreement rule
  If argmax of A (non-harmonic-preferred) != argmax of B → UNSCORED rc=77.
  Harmonics: if best is multiple of a stronger fundamental, prefer fundamental
  when fundamental contrast >= 0.5 * harmonic contrast (parent period-6 case).

Exit codes
  0  RES_OK — estimators agree, confidence above floor
  2  RES_FAIL — used only for self-test assertion failure
  77 UNSCORED — disagree / low confidence / bad input (never a pass)
  1  usage

Every printed value tagged measured | caller_supplied | DEFAULT_ASSUMED | SIM_ONLY.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import numpy as np

try:
    from PIL import Image
except ImportError as e:
    raise SystemExit(f"Pillow required: {e}") from e

RC_OK = 0
RC_USAGE = 1
RC_FAIL = 2
RC_UNSCORED = 77

PROVENANCE_MEASURED = "measured"
PROVENANCE_CALLER = "caller_supplied"
PROVENANCE_DEFAULT = "DEFAULT_ASSUMED"
PROVENANCE_SIM = "SIM_ONLY"

# Parent-measured reference (caller_supplied for comparison prints)
PARENT_P720_VERTICAL = {
    2: 1.69,
    3: 10.97,
    4: 3.21,
    5: 2.61,
}


def load_rgb(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)


def row_luma(rgb: np.ndarray) -> np.ndarray:
    # Rec.601-ish; any consistent luma works for structure
    return 0.299 * rgb[:, :, 0] + 0.587 * rgb[:, :, 1] + 0.114 * rgb[:, :, 2]


def phase_contrast_vertical(luma: np.ndarray, periods: list[int]) -> dict[int, float]:
    """Parent estimator: max/min of mean |Δrow| binned by row mod p."""
    d = np.abs(np.diff(luma, axis=0)).mean(axis=1)  # (H-1,)
    out: dict[int, float] = {}
    for p in periods:
        if p < 2:
            continue
        bins = [[] for _ in range(p)]
        for i, val in enumerate(d):
            bins[(i + 1) % p].append(float(val))  # row index of lower row ≈ i+1
        means = []
        for b in bins:
            if b:
                means.append(float(np.mean(b)))
        if len(means) < 2:
            out[p] = 1.0
            continue
        mn = min(means)
        mx = max(means)
        out[p] = float(mx / max(mn, 1e-6))
    return out


def phase_contrast_horizontal(luma: np.ndarray, periods: list[int]) -> dict[int, float]:
    d = np.abs(np.diff(luma, axis=1)).mean(axis=0)
    out: dict[int, float] = {}
    for p in periods:
        if p < 2:
            continue
        bins = [[] for _ in range(p)]
        for i, val in enumerate(d):
            bins[(i + 1) % p].append(float(val))
        means = [float(np.mean(b)) for b in bins if b]
        if len(means) < 2:
            out[p] = 1.0
            continue
        out[p] = float(max(means) / max(min(means), 1e-6))
    return out


def _row_delta_energy(luma: np.ndarray) -> np.ndarray:
    """Per-boundary mean absolute row difference (length H-1)."""
    return np.abs(np.diff(luma, axis=0)).mean(axis=1)


def autocorr_lag_scores(luma: np.ndarray, periods: list[int]) -> dict[int, float]:
    """Autocorr of |Δrow| energy at lag p (peaks when edges repeat every p)."""
    sig = _row_delta_energy(luma)
    sig = sig - sig.mean()
    var = float(np.dot(sig, sig)) + 1e-12
    out: dict[int, float] = {}
    n = len(sig)
    for p in periods:
        if p < 1 or p >= n:
            out[p] = 0.0
            continue
        out[p] = float(np.dot(sig[:-p], sig[p:]) / var)
    return out


def fourier_period_scores(luma: np.ndarray, periods: list[int]) -> dict[int, float]:
    """|FFT| power of |Δrow| energy near frequency 1/p."""
    sig = _row_delta_energy(luma)
    sig = sig - sig.mean()
    n = len(sig)
    spec = np.abs(np.fft.rfft(sig)) ** 2
    freqs = np.fft.rfftfreq(n, d=1.0)  # cycles per row-step
    out: dict[int, float] = {}
    for p in periods:
        if p < 2:
            out[p] = 0.0
            continue
        target = 1.0 / p
        k = int(np.argmin(np.abs(freqs - target)))
        lo = max(1, k - 1)
        hi = min(len(spec) - 1, k + 1)
        out[p] = float(np.max(spec[lo : hi + 1]))
    mx = max(out.values()) if out else 1.0
    if mx > 0:
        out = {k: v / mx for k, v in out.items()}
    return out


def prefer_fundamental(
    scores: dict[int, float], *, harm_ratio: float = 0.5
) -> tuple[int, float]:
    """Pick best period; if best is harmonic of a strong fundamental, prefer fund."""
    if not scores:
        return 0, 0.0
    ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
    best_p, best_s = ranked[0]
    # check fundamentals
    for p, s in ranked[1:]:
        if best_p % p == 0 and best_p // p >= 2:
            if s >= harm_ratio * best_s:
                return p, s
    return best_p, best_s


def analyze_frame(
    rgb: np.ndarray,
    *,
    periods: list[int] | None = None,
) -> dict[str, Any]:
    if periods is None:
        periods = [2, 3, 4, 5, 6, 8, 10]
    h, w = rgb.shape[:2]
    luma = row_luma(rgb)

    a_v = phase_contrast_vertical(luma, periods)
    a_h = phase_contrast_horizontal(luma, periods)
    ac = autocorr_lag_scores(luma, periods)
    ft = fourier_period_scores(luma, periods)
    # Method B combined: 0.5*norm_ac + 0.5*ft (ac shifted to positive)
    ac_pos = {p: max(0.0, v) for p, v in ac.items()}
    ac_mx = max(ac_pos.values()) if ac_pos else 1.0
    ac_n = {p: (v / ac_mx if ac_mx > 0 else 0.0) for p, v in ac_pos.items()}
    b_comb = {p: 0.5 * ac_n.get(p, 0.0) + 0.5 * ft.get(p, 0.0) for p in periods}

    pick_a, score_a = prefer_fundamental(a_v)
    pick_b, score_b = prefer_fundamental(b_comb)

    # confidence: contrast of winner and separation from second
    ranked_a = sorted(a_v.items(), key=lambda kv: kv[1], reverse=True)
    sep_a = (
        ranked_a[0][1] / max(ranked_a[1][1], 1e-6) if len(ranked_a) > 1 else ranked_a[0][1]
    )

    agree = pick_a == pick_b and pick_a >= 2
    # low confidence if contrast weak
    conf_floor = 2.0  # parent period-3 was ~11; weak periods ~1.5-3
    low_conf = score_a < conf_floor

    if not agree:
        verdict, rc = "UNSCORED", RC_UNSCORED
        reason = f"estimators_disagree A={pick_a} B={pick_b}"
    elif low_conf:
        verdict, rc = "UNSCORED", RC_UNSCORED
        reason = f"low_contrast winner={pick_a} contrast={score_a:.3f} < {conf_floor}"
    else:
        # map period → source lines at this capture height
        # If capture H and period p, distinct src rows ≈ H/p when p is vertical repeat
        src_lines_est = int(round(h / float(pick_a)))
        verdict, rc = "RES_OK", RC_OK
        reason = (
            f"vertical_period={pick_a} ≈ {src_lines_est} distinct source lines "
            f"at capture_h={h}"
        )

    # RTL expectation note
    rtl = {
        "V_STORE": 240,
        "V_STORE_src": "present_core.sv:162",
        "H_DE": 529,
        "H_DE_src": "present_core.sv:161",
        "STORE_Y_SCALE_at_480": 2.0,
        "STORE_Y_SCALE_src": "present_core.sv:164 (FRAME_H*65536)/240",
        "expected_period_at_480_capture_scale": (
            "period 3 on 720p if 240 store lines doubled then scaled to 720"
        ),
    }

    return {
        "verdict": verdict,
        "rc": rc,
        "reason": reason,
        "frame_wh": [w, h],
        "frame_wh_src": PROVENANCE_MEASURED,
        "method_a_phase_contrast_v": {str(k): round(v, 4) for k, v in sorted(a_v.items())},
        "method_a_phase_contrast_h": {str(k): round(v, 4) for k, v in sorted(a_h.items())},
        "method_a_pick": pick_a,
        "method_a_score": round(score_a, 4),
        "method_a_separation": round(float(sep_a), 4),
        "method_a_src": PROVENANCE_MEASURED,
        "method_b_autocorr": {str(k): round(v, 4) for k, v in sorted(ac.items())},
        "method_b_fourier": {str(k): round(v, 4) for k, v in sorted(ft.items())},
        "method_b_combined": {str(k): round(v, 4) for k, v in sorted(b_comb.items())},
        "method_b_pick": pick_b,
        "method_b_score": round(score_b, 4),
        "method_b_src": PROVENANCE_MEASURED,
        "estimators_agree": agree,
        "parent_p720_contrast_caller_supplied": PARENT_P720_VERTICAL,
        "rtl": rtl,
        "inferred_vertical_period": pick_a if agree and not low_conf else None,
        "inferred_source_lines": int(round(h / float(pick_a))) if agree and not low_conf else None,
        "confidence_floor": conf_floor,
        "confidence_floor_src": PROVENANCE_DEFAULT,
    }


def _synth_period_frame(h: int, w: int, period: int) -> np.ndarray:
    """Synthetic vertical hold structure (SIM_ONLY).

    Models ``period`` capture rows per source line (parent 720p/240 → p=3):
    each source line is held constant for ``period`` rows, then jumps.
    Phase-binned |Δrow| is ~0 inside a hold and large on the boundary phase.
    """
    rgb = np.zeros((h, w, 3), dtype=np.float64)
    x = np.linspace(0, 12, w)
    for y in range(h):
        src_line = y // period
        # alternate block luma so jumps are large
        val = 40.0 + (src_line % 7) * 28.0
        row = val + x * 0.3
        rgb[y, :, 0] = row
        rgb[y, :, 1] = row * 0.98
        rgb[y, :, 2] = row * 0.95
    return np.clip(rgb, 0, 255).astype(np.uint8)


def run_self_test() -> int:
    work = Path(__file__).resolve().parents[1] / ".agent-work" / "w-instr" / "src-res"
    work.mkdir(parents=True, exist_ok=True)
    ok = True

    # SIM: period-3 structure at 720p should agree on 3
    f3 = _synth_period_frame(720, 1280, 3)
    Image.fromarray(f3).save(work / "sim_p3.png")
    r3 = analyze_frame(f3.astype(np.float64))
    print("SIM_P3", json.dumps({k: r3[k] for k in (
        "verdict", "rc", "method_a_pick", "method_b_pick", "method_a_score", "reason"
    )}, indent=2))
    if r3["rc"] != RC_OK or r3["method_a_pick"] != 3 or r3["method_b_pick"] != 3:
        print("FAIL sim period-3")
        ok = False
    else:
        print("PASS sim period-3 RES_OK")

    # SIM: period-2
    f2 = _synth_period_frame(720, 1280, 2)
    r2 = analyze_frame(f2.astype(np.float64))
    print("SIM_P2", r2["method_a_pick"], r2["method_b_pick"], r2["verdict"])
    if r2["rc"] != RC_OK or r2["method_a_pick"] != 2:
        print("FAIL sim period-2")
        ok = False
    else:
        print("PASS sim period-2")

    # Disagree path: scramble so methods may disagree → force by checking
    # flat field → low contrast UNSCORED
    flat = np.full((720, 1280, 3), 80, dtype=np.uint8)
    rf = analyze_frame(flat.astype(np.float64))
    print("FLAT", rf["verdict"], rf["rc"], rf["reason"])
    if rf["rc"] != RC_UNSCORED:
        print("FAIL flat should UNSCORE")
        ok = False
    else:
        print("PASS flat UNSCORED")

    # Optional: live banked frame if present
    for cand in (
        Path("/tmp/p60/png/f_0500.png"),
        Path("/tmp/p60/png/f_1200.png"),
        Path("/tmp/p60/png/f_2400.png"),
    ):
        if cand.is_file():
            rgb = load_rgb(cand)
            rr = analyze_frame(rgb)
            print(
                f"DEVICE {cand.name} verdict={rr['verdict']} rc={rr['rc']} "
                f"A={rr['method_a_pick']}({rr['method_a_score']}) "
                f"B={rr['method_b_pick']}({rr['method_b_score']}) "
                f"a_v={rr['method_a_phase_contrast_v']}"
            )
            # Parent expects period 3 dominant; if both agree on 3, good.
            # If disagree, UNSCORED is correct behavior — do not fail self-test.
            break

    if ok:
        print("SELF_TEST_OK")
        return RC_OK
    print("SELF_TEST_FAIL")
    return RC_FAIL


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("images", nargs="*", type=Path, help="PNG/JPG capture frames")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument(
        "--periods",
        type=str,
        default="2,3,4,5,6,8,10",
        help="comma periods to test (caller_supplied)",
    )
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return run_self_test()
    if not args.images:
        ap.error("images required (or --self-test)")
        return RC_USAGE

    periods = [int(x) for x in args.periods.split(",") if x.strip()]
    rc_out = RC_OK
    reports = []
    for img in args.images:
        if not img.is_file():
            print(f"MISSING {img}", file=sys.stderr)
            rc_out = RC_UNSCORED
            continue
        rgb = load_rgb(img)
        rep = analyze_frame(rgb, periods=periods)
        rep["path"] = str(img)
        rep["path_src"] = PROVENANCE_MEASURED
        reports.append(rep)
        if args.json:
            print(json.dumps(rep, indent=2))
        else:
            print(
                f"FILE={img} VERDICT={rep['verdict']} rc={rep['rc']} "
                f"reason={rep['reason']}"
            )
            print(
                f"  A_phase_v pick={rep['method_a_pick']} score={rep['method_a_score']} "
                f"sep={rep['method_a_separation']} src={rep['method_a_src']} "
                f"hist={rep['method_a_phase_contrast_v']}"
            )
            print(
                f"  B_ac+fft pick={rep['method_b_pick']} score={rep['method_b_score']} "
                f"src={rep['method_b_src']} ac={rep['method_b_autocorr']} "
                f"fft={rep['method_b_fourier']}"
            )
            print(
                f"  H_phase hist={rep['method_a_phase_contrast_h']} "
                f"agree={rep['estimators_agree']} "
                f"src_lines={rep.get('inferred_source_lines')}"
            )
            print(
                f"  rtl V_STORE={rep['rtl']['V_STORE']} src={rep['rtl']['V_STORE_src']} "
                f"H_DE={rep['rtl']['H_DE']}"
            )
        if rep["rc"] == RC_UNSCORED:
            rc_out = RC_UNSCORED
        elif rep["rc"] != RC_OK and rc_out == RC_OK:
            rc_out = int(rep["rc"])

    # Multi-frame: if any UNSCORED and none OK-agree, 77; if mix, prefer 77
    if reports and all(r["rc"] == RC_UNSCORED for r in reports):
        return RC_UNSCORED
    if any(r["rc"] == RC_UNSCORED for r in reports) and not any(
        r["rc"] == RC_OK for r in reports
    ):
        return RC_UNSCORED
    return rc_out if reports else RC_UNSCORED


if __name__ == "__main__":
    sys.exit(main())
