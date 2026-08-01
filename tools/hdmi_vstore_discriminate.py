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

Binary flat-field suite (rd-review B2 / parent preferred — immune to alias confounds)
------------------------------------------------------------------------------------
Publish via product path (NO H.264)::

  push_frame --ddr --pattern mid_grey|even_black|even_white|odd_black|odd_white

  even_black → solid BLACK on glass (current V_STORE=240)
  even_white → solid WHITE
  phase shift inverts; mid_grey CONTROL must be uniform mid-grey

Score::

  tools/hdmi_vstore_discriminate.py --flat-suite CAP_DIR
  # expects mid_grey.png even_black.png even_white.png [odd_black.png odd_white.png]

If CONTROL fails → rc=77 UNSCORED (never a pass).
If even_black class == even_white class → CEILING_FALSIFIED (claim withdrawn).
If predictions match → CEILING_240_HOLD.

ESTABLISHED FACT (parent 2026-08-01, RBF c5382bee, viewed pixels — not inference)
-------------------------------------------------------------------------------
5/5 pre-register hit, std=0.00 on all five patterns: opposite solid fields under
one-row phase shift. Odd rows **entirely absent**. Vertical 240-row ceiling is
**proven**. Scope: vertical only; H 529/640 not glass-proven.
Bank: .agent-work/w-instr/VSTORE_CEILING_BEFORE_c5382bee.json

AFTER w-geom T7 (unique rows 240→480) — use ``--expect-after-fix``:
  solid BLACK/WHITE collapse on even_black/even_white **must break**
  (stripes, grey average, or non-opposite classes). CEILING_240_HOLD after fix
  is a FAIL (fix did not land on glass). Control still required.

Markers are **≥2 source rows thick** and full-width bars so they survive
529/640 column decimation + ascal + grabber. 1-row stripes via H.264 are VOID
(codec destroys Nyquist vertical).

Exit: 0 RES_OK / CEILING match / AFTER_FIX_OK, 2 FAIL / falsified / self-test fail,
      77 UNSCORED, 1 usage.
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

# Glass flat-field classes (after ascal+grabber; video-range mapped to 8-bit RGB).
# Thresholds are loose enough for grabber MJPG; tight enough to reject garbage.
FLAT_BLACK_MAX = 45.0
FLAT_WHITE_MIN = 200.0
FLAT_MID_LO = 85.0
FLAT_MID_HI = 175.0
FLAT_STD_MAX = 40.0  # solid field must be low-variance


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


def active_letterbox(L: np.ndarray) -> tuple[int, int]:
    """Return [y0, y1) active rows; fall back to full frame if bars not found."""
    row_m = L.mean(axis=1)
    span = float(row_m.max() - row_m.min())
    if span < 5.0:
        # nearly flat — whole frame is the content (solid field case)
        return 0, int(L.shape[0])
    thr = 0.15 * span + float(row_m.min())
    active = np.where(row_m > thr)[0]
    if active.size < 32:
        return 0, int(L.shape[0])
    return int(active[0]), int(active[-1]) + 1


def odd_even_energy(rgb: np.ndarray) -> dict[str, Any]:
    """Structure energy on odd vs even capture rows (ceiling probe)."""
    L = luma(rgb)
    y0, y1 = active_letterbox(L)
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


def classify_flat_field(rgb: np.ndarray) -> dict[str, Any]:
    """Classify a capture as BLACK / WHITE / MID_GREY / OTHER from viewed pixels.

    Used for the even-black / even-white / mid-grey control suite. Solid-field
    answer only — no period, no OCR, no md5.
    """
    L = luma(rgb)
    y0, y1 = active_letterbox(L)
    crop = L[y0:y1]
    # central 60% columns avoid pillarbox / edge grabber junk
    x0 = int(crop.shape[1] * 0.2)
    x1 = int(crop.shape[1] * 0.8)
    roi = crop[:, x0:x1] if x1 > x0 + 8 else crop
    mean_l = float(roi.mean())
    std_l = float(roi.std())
    solid = std_l <= FLAT_STD_MAX
    if solid and mean_l <= FLAT_BLACK_MAX:
        cls = "BLACK"
    elif solid and mean_l >= FLAT_WHITE_MIN:
        cls = "WHITE"
    elif solid and FLAT_MID_LO <= mean_l <= FLAT_MID_HI:
        cls = "MID_GREY"
    else:
        cls = "OTHER"
    return {
        "class": cls,
        "mean_luma": round(mean_l, 3),
        "std_luma": round(std_l, 3),
        "solid": solid,
        "active_rows": [y0, y1],
        "roi_x": [x0, x1],
        "src": PROVENANCE_MEASURED,
        "thresholds": {
            "black_max": FLAT_BLACK_MAX,
            "white_min": FLAT_WHITE_MIN,
            "mid_lo": FLAT_MID_LO,
            "mid_hi": FLAT_MID_HI,
            "std_max": FLAT_STD_MAX,
        },
    }


def _find_named(cap_dir: Path, stem: str) -> Path | None:
    for ext in (".png", ".jpg", ".jpeg", ".bmp"):
        p = cap_dir / f"{stem}{ext}"
        if p.is_file():
            return p
    # allow f_001 style dirs only if single file named stem*
    hits = sorted(cap_dir.glob(f"{stem}*"))
    return hits[0] if len(hits) == 1 else None


def score_flat_suite(cap_dir: Path) -> dict[str, Any]:
    """Score mid_grey control + even_black/even_white (+ optional odd_*).

    PRE-REGISTER (current RBF, store_y=py*2):
      mid_grey    → MID_GREY   (CONTROL — fail ⇒ whole suite UNSCORED)
      even_black  → BLACK
      even_white  → WHITE
      odd_black   → WHITE      (phase invert)
      odd_white   → BLACK

    If even_black class == even_white class → CEILING_FALSIFIED.
    """
    required = ("mid_grey", "even_black", "even_white")
    optional = ("odd_black", "odd_white")
    frames: dict[str, dict[str, Any]] = {}
    missing = []
    for name in required:
        p = _find_named(cap_dir, name)
        if p is None:
            missing.append(name)
            continue
        frames[name] = {"path": str(p), **classify_flat_field(load_rgb(p))}
    for name in optional:
        p = _find_named(cap_dir, name)
        if p is not None:
            frames[name] = {"path": str(p), **classify_flat_field(load_rgb(p))}

    if missing:
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": f"missing required captures: {missing}",
            "frames": frames,
            "src": PROVENANCE_MEASURED,
        }

    ctrl = frames["mid_grey"]["class"]
    if ctrl != "MID_GREY":
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": (
                f"CONTROL mid_grey class={ctrl} mean={frames['mid_grey']['mean_luma']} "
                f"std={frames['mid_grey']['std_luma']} — publish path broken or "
                f"capture wrong; do not score ceiling"
            ),
            "frames": frames,
            "pre_register": "control_must_be_MID_GREY",
            "src": PROVENANCE_MEASURED,
        }

    eb = frames["even_black"]["class"]
    ew = frames["even_white"]["class"]
    # Falsifier: phases identical → no even-only fetch
    if eb == ew and eb in ("BLACK", "WHITE", "MID_GREY"):
        return {
            "verdict": "CEILING_FALSIFIED",
            "rc": RC_FAIL,
            "reason": (
                f"even_black={eb} even_white={ew} IDENTICAL solid class — "
                f"240-row even-fetch claim FALSIFIED (both phases same on glass)"
            ),
            "frames": frames,
            "pre_register": "even_black→BLACK even_white→WHITE",
            "src": PROVENANCE_MEASURED,
        }

    pred = {"even_black": "BLACK", "even_white": "WHITE"}
    opt_pred = {"odd_black": "WHITE", "odd_white": "BLACK"}
    mismatches = []
    for k, want in pred.items():
        got = frames[k]["class"]
        if got != want:
            mismatches.append(f"{k}:got={got} want={want}")
    for k, want in opt_pred.items():
        if k not in frames:
            continue
        got = frames[k]["class"]
        if got != want:
            mismatches.append(f"{k}:got={got} want={want}")

    if mismatches:
        # control passed but phase prediction missed — still a real result
        return {
            "verdict": "CEILING_MISMATCH",
            "rc": RC_FAIL,
            "reason": "control OK but phase classes != pre-register: " + "; ".join(mismatches),
            "frames": frames,
            "pre_register": "even_black→BLACK even_white→WHITE odd_black→WHITE odd_white→BLACK",
            "src": PROVENANCE_MEASURED,
            "mode": "before_ceiling",
        }

    return {
        "verdict": "CEILING_240_HOLD",
        "rc": RC_OK,
        "reason": (
            "control MID_GREY; even_black→BLACK; even_white→WHITE"
            + ("; phase invert OK" if "odd_black" in frames or "odd_white" in frames else "")
            + " — matches store_y=py*2 even-row fetch"
        ),
        "frames": frames,
        "pre_register": "even_black→BLACK even_white→WHITE",
        "src": PROVENANCE_MEASURED,
        "mode": "before_ceiling",
        "established_fact_note": (
            "Parent 2026-08-01 on c5382bee: std=0.00 opposite solids; "
            "vertical 240 ceiling ESTABLISHED (not inference). Vertical only."
        ),
    }


def score_flat_suite_after_fix(cap_dir: Path) -> dict[str, Any]:
    """Score AFTER w-geom T7: solid opposite-field collapse must BREAK.

    Control mid_grey still required (path soundness).
    PASS (AFTER_FIX_OK): control OK AND NOT (even_black=BLACK and even_white=WHITE).
    FAIL: still shows CEILING_240_HOLD pattern (fix not visible on glass).
    UNSCORED: control fail / missing.

    Does not treat CEILING_FALSIFIED / MISMATCH from the before-scorer as
    terminal — those are exactly the glass signatures we want after the fix.
    """
    # Load/classify without using before-mode terminal verdicts as fail.
    required = ("mid_grey", "even_black", "even_white")
    frames: dict[str, dict[str, Any]] = {}
    missing = []
    for name in required:
        p = _find_named(cap_dir, name)
        if p is None:
            missing.append(name)
            continue
        frames[name] = {"path": str(p), **classify_flat_field(load_rgb(p))}
    for name in ("odd_black", "odd_white"):
        p = _find_named(cap_dir, name)
        if p is not None:
            frames[name] = {"path": str(p), **classify_flat_field(load_rgb(p))}

    if missing:
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": f"missing required captures: {missing}",
            "frames": frames,
            "src": PROVENANCE_MEASURED,
            "mode": "after_fix",
        }

    if frames["mid_grey"]["class"] != "MID_GREY":
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": (
                f"CONTROL mid_grey class={frames['mid_grey']['class']} — "
                f"publish path broken; do not score after-fix"
            ),
            "frames": frames,
            "src": PROVENANCE_MEASURED,
            "mode": "after_fix",
        }

    eb = frames["even_black"]["class"]
    ew = frames["even_white"]["class"]
    still_collapsed = eb == "BLACK" and ew == "WHITE"

    if still_collapsed:
        return {
            "verdict": "AFTER_FIX_STILL_240",
            "rc": RC_FAIL,
            "reason": (
                "control OK but even_black→BLACK and even_white→WHITE still hold — "
                "glass still shows 240-row even-fetch; T7 not proven on glass"
            ),
            "frames": frames,
            "pre_register": "after_fix: solid opposite collapse MUST break",
            "src": PROVENANCE_MEASURED,
            "mode": "after_fix",
            "before_bank": "VSTORE_CEILING_BEFORE_c5382bee.json",
        }

    return {
        "verdict": "AFTER_FIX_OK",
        "rc": RC_OK,
        "reason": (
            f"control MID_GREY; even_black={eb} even_white={ew} — opposite solid "
            f"collapse broken (glass proof of denser vertical fetch)"
        ),
        "frames": frames,
        "pre_register": "after_fix: solid opposite collapse MUST break",
        "src": PROVENANCE_MEASURED,
        "mode": "after_fix",
        "before_bank": "VSTORE_CEILING_BEFORE_c5382bee.json",
    }


def run_flat_suite_self_test() -> bool:
    """SIM red/green for flat suite (not device accuracy)."""
    work = Path(__file__).resolve().parents[1] / ".agent-work" / "w-instr" / "vstore-flat-sim"
    work.mkdir(parents=True, exist_ok=True)
    ok = True

    def solid(val: int, name: str) -> None:
        arr = np.full((720, 1280, 3), val, dtype=np.uint8)
        Image.fromarray(arr).save(work / f"{name}.png")

    # GREEN: control mid, even black, even white
    solid(128, "mid_grey")
    solid(10, "even_black")
    solid(240, "even_white")
    solid(240, "odd_black")
    solid(10, "odd_white")
    g = score_flat_suite(work)
    print("FLAT_SIM_GREEN", json.dumps({k: g[k] for k in ("verdict", "rc", "reason")}, indent=2))
    if g["verdict"] != "CEILING_240_HOLD" or g["rc"] != RC_OK:
        print("FAIL flat green")
        ok = False
    else:
        print("PASS flat green SIM_ONLY")

    # RED: control broken → UNSCORED
    solid(10, "mid_grey")  # black control
    r = score_flat_suite(work)
    print("FLAT_SIM_CTRL_FAIL", r["verdict"], r["rc"])
    if r["rc"] != RC_UNSCORED or r["verdict"] != "UNSCORED":
        print("FAIL control-fail must UNSCORED")
        ok = False
    else:
        print("PASS control-fail UNSCORED SIM_ONLY")

    # RED: identical phases → FALSIFIED
    solid(128, "mid_grey")
    solid(10, "even_black")
    solid(10, "even_white")
    f = score_flat_suite(work)
    print("FLAT_SIM_FALSIFIED", f["verdict"], f["rc"])
    if f["verdict"] != "CEILING_FALSIFIED" or f["rc"] != RC_FAIL:
        print("FAIL identical phases must CEILING_FALSIFIED")
        ok = False
    else:
        print("PASS CEILING_FALSIFIED SIM_ONLY")

    # AFTER-fix mode: still-collapsed (BLACK/WHITE) must FAIL
    solid(128, "mid_grey")
    solid(10, "even_black")
    solid(240, "even_white")
    af_bad = score_flat_suite_after_fix(work)
    print("FLAT_SIM_AFTER_STILL240", af_bad["verdict"], af_bad["rc"])
    if af_bad["verdict"] != "AFTER_FIX_STILL_240" or af_bad["rc"] != RC_FAIL:
        print("FAIL after-fix still-collapsed must AFTER_FIX_STILL_240")
        ok = False
    else:
        print("PASS AFTER_FIX_STILL_240 SIM_ONLY")

    # AFTER-fix mode: collapse broken (both mid / both other) → OK
    solid(128, "mid_grey")
    solid(128, "even_black")  # stripes would average; mid is enough for SIM
    solid(128, "even_white")
    af_ok = score_flat_suite_after_fix(work)
    print("FLAT_SIM_AFTER_OK", af_ok["verdict"], af_ok["rc"])
    # identical mid greys → CEILING_FALSIFIED in before-scorer base, but after_fix
    # treats non-BLACK/WHITE pair as collapse broken. score_flat_suite_after_fix
    # returns early only on UNSCORED; FALSIFIED base still has frames — need path.
    # even_black=MID even_white=MID → still_collapsed False → AFTER_FIX_OK
    if af_ok.get("verdict") == "UNSCORED":
        print("FAIL after-fix broken collapse UNSCORED unexpectedly")
        ok = False
    elif af_ok["rc"] == RC_OK and af_ok["verdict"] == "AFTER_FIX_OK":
        print("PASS AFTER_FIX_OK SIM_ONLY")
    elif af_ok["verdict"] == "CEILING_FALSIFIED":
        # base returned falsified before after-logic — fix after_fix to continue
        print("FAIL after_fix short-circuited on FALSIFIED; need continue-to-after")
        ok = False
    else:
        print(f"FAIL after-fix unexpected {af_ok['verdict']} rc={af_ok['rc']}")
        ok = False

    return ok


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

    if not run_flat_suite_self_test():
        ok = False

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
    ap.add_argument(
        "--classify-flat",
        action="store_true",
        help="classify each image as BLACK/WHITE/MID_GREY/OTHER (solid field)",
    )
    ap.add_argument(
        "--flat-suite",
        type=Path,
        default=None,
        help="dir with mid_grey/even_black/even_white[.png] captures; control-fail→77",
    )
    ap.add_argument(
        "--expect-after-fix",
        action="store_true",
        help="with --flat-suite: PASS only if opposite solid collapse BROKE (T7 glass proof)",
    )
    args = ap.parse_args(argv)

    if args.self_test:
        return run_self_test()

    if args.flat_suite is not None:
        if not args.flat_suite.is_dir():
            print(f"MISSING dir {args.flat_suite}", file=sys.stderr)
            return RC_UNSCORED
        if args.expect_after_fix:
            print(
                "PRE-REGISTER after_fix (before score): opposite solid "
                "even_black=BLACK/even_white=WHITE collapse MUST break; "
                "control MID_GREY required; BEFORE bank=c5382bee ESTABLISHED"
            )
            rep = score_flat_suite_after_fix(args.flat_suite)
        else:
            print(
                "PRE-REGISTER before_ceiling (before score): even_black→BLACK "
                "even_white→WHITE mid_grey→MID; ESTABLISHED on c5382bee parent 2026-08-01"
            )
            rep = score_flat_suite(args.flat_suite)
        if args.json:
            print(json.dumps(rep, indent=2))
        else:
            print(f"VERDICT={rep['verdict']} rc={rep['rc']} mode={rep.get('mode')}")
            print(f"  reason={rep['reason']}")
            for name, fr in rep.get("frames", {}).items():
                print(
                    f"  {name}: class={fr['class']} mean={fr['mean_luma']} "
                    f"std={fr['std_luma']} path={fr.get('path')}"
                )
            if "pre_register" in rep:
                print(f"  pre_register={rep['pre_register']}")
            if rep.get("established_fact_note"):
                print(f"  note={rep['established_fact_note']}")
        return int(rep["rc"])

    if not args.images:
        ap.error("images required (or --flat-suite DIR or --self-test)")
        return RC_USAGE

    rc_out = RC_OK
    for img in args.images:
        if not img.is_file():
            print(f"MISSING {img}", file=sys.stderr)
            rc_out = RC_UNSCORED
            continue
        rgb = load_rgb(img)
        if args.classify_flat:
            fr = classify_flat_field(rgb)
            fr["path"] = str(img)
            if args.json:
                print(json.dumps(fr, indent=2))
            else:
                print(
                    f"FILE={img} class={fr['class']} mean={fr['mean_luma']} "
                    f"std={fr['std_luma']} solid={fr['solid']}"
                )
            if fr["class"] == "OTHER":
                rc_out = RC_UNSCORED if rc_out == RC_OK else rc_out
            continue
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
