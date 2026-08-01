#!/usr/bin/env python3
"""B2: discriminate 240-row vs 480-row source through resamples (rd-review).

WHY period alone is VOID (parent / rd-review — do not repeat)
------------------------------------------------------------
A 480→720 resample and a 240→720 resample can BOTH produce period-3 structure.
``max/min`` phase contrast **inflates with the period** (why period-6 scored
17.51). That claim was WITHDRAWN.

Discriminator that survives the objection
-----------------------------------------
For the fundamental vertical hold period p (typically 3 at 720p):

  phase_means[i] = mean |Δrow| for rows with (row mod p) == i
  low phase = phase_mean < tau * max(phase_means)   (default tau=0.35)

  n_low_phases:
    * 240-line source held ×3 onto 720 → **2 low phases** (flat inside triple)
    * 480-line source scaled 1.5× → typically **1 low phase** (thinner holds)

Cross-check: Fourier/autocorr of |Δrow| must agree on fundamental p, else
UNSCORED. Never use max/min contrast rank alone as the verdict.

Also: odd-only / even-only energy probes (ceiling fix before/after)
------------------------------------------------------------------
present_core.sv: store_y = py * STORE_Y_SCALE>>16 with V_STORE=240 and
FRAME_H=480 ⇒ scale=2 ⇒ only **even** store rows fetched (50% never read).

Fixture (scripts/gen_vstore_ceiling_fixture.py):
  even_only: content on even source rows only
  odd_only:  content on odd source rows only
  full:      content on all rows

BEFORE (broken V_STORE=240 path): odd_only energy ≈ 0; even_only strong.
AFTER  (full 480 fetch): both odd_only and even_only show comparable structure.

Markers are **≥2 source rows thick** and full-width bars so they survive
529/640 column decimation + ascal + grabber.

Exit: 0 RES_OK agree, 2 self-test fail, 77 UNSCORED, 1 usage.
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


def load_rgb(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)


def luma(rgb: np.ndarray) -> np.ndarray:
    return 0.299 * rgb[:, :, 0] + 0.587 * rgb[:, :, 1] + 0.114 * rgb[:, :, 2]


def row_delta(luma_img: np.ndarray) -> np.ndarray:
    return np.abs(np.diff(luma_img, axis=0)).mean(axis=1)


def phase_means(d: np.ndarray, p: int) -> list[float]:
    bins: list[list[float]] = [[] for _ in range(p)]
    for i, v in enumerate(d):
        bins[(i + 1) % p].append(float(v))
    return [float(np.mean(b)) if b else 0.0 for b in bins]


def n_low_phases(means: list[float], tau: float = 0.35) -> int:
    if not means:
        return 0
    mx = max(means)
    if mx < 1e-9:
        return 0
    thr = tau * mx
    return int(sum(1 for m in means if m < thr))


def fundamental_period_fft(d: np.ndarray, candidates: list[int]) -> tuple[int, dict[int, float]]:
    sig = d - d.mean()
    n = len(sig)
    spec = np.abs(np.fft.rfft(sig)) ** 2
    freqs = np.fft.rfftfreq(n, d=1.0)
    scores: dict[int, float] = {}
    for p in candidates:
        if p < 2:
            continue
        target = 1.0 / p
        k = int(np.argmin(np.abs(freqs - target)))
        lo, hi = max(1, k - 1), min(len(spec) - 1, k + 1)
        scores[p] = float(np.max(spec[lo : hi + 1]))
    if not scores:
        return 0, {}
    # prefer fundamental over harmonic if close
    ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
    best_p, best_s = ranked[0]
    for p, s in ranked[1:]:
        if best_p % p == 0 and best_p // p >= 2 and s >= 0.5 * best_s:
            return p, scores
    return best_p, scores


def analyze_low_phases(
    rgb: np.ndarray,
    *,
    periods: list[int] | None = None,
    tau: float = 0.35,
) -> dict[str, Any]:
    """Primary B2 scorer: n_low_phases at FFT-agreed fundamental."""
    if periods is None:
        periods = [2, 3, 4, 5, 6]
    print("PRE-REGISTER B2 low-phase discriminator (before compute):")
    print("  n_low==2 at p=3 → consistent with 240-line hold×3 (broken V_STORE path)")
    print("  n_low==1 at p=3 → consistent with denser 480-line scale")
    print("  FFT fundamental must agree with phase period else UNSCORED")
    print("  max/min contrast is REPORTED but never the verdict (rd-review)")
    print(f"  tau_low={tau} src={PROVENANCE_DEFAULT}")

    L = luma(rgb)
    d = row_delta(L)
    h, w = rgb.shape[:2]
    fft_p, fft_scores = fundamental_period_fft(d, periods)

    # phase means for each candidate; pick p that maximizes n_low among strong fft
    per_p: dict[str, Any] = {}
    best_p = fft_p
    best_nlow = -1
    for p in periods:
        means = phase_means(d, p)
        nl = n_low_phases(means, tau=tau)
        mx, mn = (max(means), min(means)) if means else (0.0, 0.0)
        contrast = mx / max(mn, 1e-9)
        per_p[str(p)] = {
            "phase_means": [round(m, 4) for m in means],
            "n_low_phases": nl,
            "contrast_max_min_DO_NOT_VERDICT": round(contrast, 4),
            "fft_score": round(fft_scores.get(p, 0.0), 6),
        }
        # prefer FFT winner; track n_low there
        if p == fft_p:
            best_nlow = nl
            best_p = p

    # Cross-check: autocorr lag peak
    sig = d - d.mean()
    var = float(np.dot(sig, sig)) + 1e-12
    ac = {}
    for p in periods:
        if p < len(sig):
            ac[p] = float(np.dot(sig[:-p], sig[p:]) / var)
    ac_p = max(ac, key=ac.get) if ac else 0
    # harmonic prefer
    if ac_p and fft_p and ac_p != fft_p:
        if ac_p % fft_p == 0 or fft_p % ac_p == 0:
            agree = True
            fund = min(ac_p, fft_p) if min(ac_p, fft_p) >= 2 else fft_p
        else:
            agree = False
            fund = fft_p
    else:
        agree = True
        fund = fft_p

    if fund != best_p and fund in periods:
        means = phase_means(d, fund)
        best_nlow = n_low_phases(means, tau=tau)
        best_p = fund

    if not agree:
        verdict, rc = "UNSCORED", RC_UNSCORED
        reason = f"fft_p={fft_p} ac_p={ac_p} disagree"
        row_class = None
    elif best_p < 2 or best_nlow < 1:
        verdict, rc = "UNSCORED", RC_UNSCORED
        reason = f"weak structure p={best_p} n_low={best_nlow}"
        row_class = None
    elif best_p == 3 and best_nlow >= 2:
        verdict, rc = "ROWS_240_HOLD", RC_OK
        reason = f"p={best_p} n_low={best_nlow} (≥2 low phases ⇒ 240-line hold)"
        row_class = 240
    elif best_p == 3 and best_nlow == 1:
        verdict, rc = "ROWS_480ISH", RC_OK
        reason = f"p={best_p} n_low={best_nlow} (1 low phase ⇒ denser vertical)"
        row_class = 480
    else:
        verdict, rc = "ROWS_OTHER", RC_OK
        reason = f"p={best_p} n_low={best_nlow}"
        row_class = None

    return {
        "verdict": verdict,
        "rc": rc,
        "reason": reason,
        "frame_wh": [w, h],
        "frame_wh_src": PROVENANCE_MEASURED,
        "fundamental_p": best_p,
        "n_low_phases": best_nlow,
        "row_class_estimate": row_class,
        "fft_p": fft_p,
        "ac_p": ac_p,
        "estimators_agree": agree,
        "per_period": per_p,
        "tau_low": tau,
        "tau_low_src": PROVENANCE_DEFAULT,
        "rtl": {
            "V_STORE": 240,
            "V_STORE_src": "present_core.sv:162",
            "STORE_Y_SCALE_at_480": 2.0,
            "effect": "store_y=py*2 ⇒ even rows only when V_STORE=240",
        },
        "rd_review_note": (
            "period alone is NOT proof of 240 vs 480; n_low_phases is. "
            "max/min contrast inflates with period — never verdict."
        ),
    }


def odd_even_energy(rgb: np.ndarray) -> dict[str, Any]:
    """Structure energy on odd vs even capture rows (ceiling probe)."""
    L = luma(rgb)
    # active letterbox crop: drop near-black bars
    row_m = L.mean(axis=1)
    thr = 0.15 * (row_m.max() - row_m.min()) + row_m.min()
    active = np.where(row_m > thr)[0]
    if active.size < 32:
        active = np.arange(L.shape[0])
    y0, y1 = int(active[0]), int(active[-1]) + 1
    crop = L[y0:y1]
    even = crop[0::2]
    odd = crop[1::2]
    # energy = variance + mean |Δ|
    def eng(plane: np.ndarray) -> float:
        if plane.shape[0] < 2:
            return 0.0
        d = np.abs(np.diff(plane, axis=0)).mean()
        return float(plane.var() + d)

    e_even, e_odd = eng(even), eng(odd)
    ratio = e_odd / max(e_even, 1e-9)
    return {
        "active_rows": [y0, y1],
        "energy_even": round(e_even, 4),
        "energy_odd": round(e_odd, 4),
        "odd_over_even": round(ratio, 4),
        "src": PROVENANCE_MEASURED,
        "note": (
            "odd_only fixture BEFORE ceiling fix ⇒ odd_over_even << 1; "
            "AFTER fix ⇒ closer to 1 on full content"
        ),
    }


def _synth_hold(h: int, w: int, src_lines: int) -> np.ndarray:
    """SIM: src_lines unique lines held evenly onto h rows."""
    rgb = np.zeros((h, w, 3), dtype=np.float64)
    for y in range(h):
        src = int(y * src_lines / h)
        val = 20.0 + (src % 17) * 12.0
        rgb[y, :, :] = val
    # hard edges at source boundaries
    return np.clip(rgb, 0, 255).astype(np.uint8)


def run_self_test() -> int:
    work = Path(__file__).resolve().parents[1] / ".agent-work" / "w-instr" / "vstore-b2"
    work.mkdir(parents=True, exist_ok=True)
    ok = True

    # 240 lines → 720: expect n_low>=2 at p=3
    f240 = _synth_hold(720, 1280, 240)
    Image.fromarray(f240).save(work / "sim240.png")
    r240 = analyze_low_phases(f240.astype(np.float64))
    print("SIM240", json.dumps({k: r240[k] for k in (
        "verdict", "rc", "fundamental_p", "n_low_phases", "row_class_estimate", "reason"
    )}, indent=2))
    if r240["row_class_estimate"] != 240 or r240["n_low_phases"] < 2:
        print("FAIL sim240 expected n_low>=2 class 240")
        ok = False
    else:
        print("PASS sim240")

    # 480 lines → 720: expect n_low==1 at fundamental near 1.5→ use p that wins
    f480 = _synth_hold(720, 1280, 480)
    Image.fromarray(f480).save(work / "sim480.png")
    r480 = analyze_low_phases(f480.astype(np.float64))
    print("SIM480", json.dumps({k: r480[k] for k in (
        "verdict", "rc", "fundamental_p", "n_low_phases", "row_class_estimate", "reason"
    )}, indent=2))
    # 480→720 hold length alternates 1 and 2; n_low at p=3 should be 1 or class != 240
    if r480.get("row_class_estimate") == 240 and r480["n_low_phases"] >= 2:
        print("FAIL sim480 must not look like 240-hold")
        ok = False
    else:
        print("PASS sim480 distinct from 240-hold")

    # flat → UNSCORED
    flat = np.full((720, 1280, 3), 40, dtype=np.uint8)
    rf = analyze_low_phases(flat.astype(np.float64))
    if rf["rc"] != RC_UNSCORED:
        print("FAIL flat")
        ok = False
    else:
        print("PASS flat UNSCORED")

    # device bank if present
    for cand in (
        Path("/tmp/p60/png/f_01200.png"),
        Path("/tmp/p60/png/f_02400.png"),
    ):
        if cand.is_file():
            rr = analyze_low_phases(load_rgb(cand))
            ee = odd_even_energy(load_rgb(cand))
            print(
                f"DEVICE {cand.name} verdict={rr['verdict']} p={rr['fundamental_p']} "
                f"n_low={rr['n_low_phases']} class={rr['row_class_estimate']} "
                f"odd/even={ee['odd_over_even']}"
            )
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
    ap.add_argument("images", nargs="*", type=Path)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--tau", type=float, default=0.35)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--odd-even", action="store_true", help="also print odd/even energy")
    args = ap.parse_args(argv)

    if args.self_test:
        return run_self_test()
    if not args.images:
        ap.error("images required")
        return RC_USAGE

    rc_out = RC_OK
    for img in args.images:
        if not img.is_file():
            print(f"MISSING {img}", file=sys.stderr)
            rc_out = RC_UNSCORED
            continue
        rgb = load_rgb(img)
        rep = analyze_low_phases(rgb, tau=args.tau)
        rep["path"] = str(img)
        if args.odd_even:
            rep["odd_even"] = odd_even_energy(rgb)
        if args.json:
            print(json.dumps(rep, indent=2))
        else:
            print(
                f"FILE={img} VERDICT={rep['verdict']} rc={rep['rc']} "
                f"p={rep['fundamental_p']} n_low={rep['n_low_phases']} "
                f"class={rep['row_class_estimate']} reason={rep['reason']}"
            )
            print(f"  per_period={json.dumps(rep['per_period'])}")
            if "odd_even" in rep:
                print(f"  odd_even={rep['odd_even']}")
            print(f"  note={rep['rd_review_note']}")
        if rep["rc"] == RC_UNSCORED:
            rc_out = RC_UNSCORED
    return rc_out


if __name__ == "__main__":
    sys.exit(main())
