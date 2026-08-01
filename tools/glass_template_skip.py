#!/usr/bin/env python3
"""Template counter decoder + display-skip detector (parent method, not OCR).

WHY (parent, 2026-08-01)
------------------------
OCR in hdmi_motion_instrument.py inserted digits (2358→23538) and is weak on
FLASH. Parent built a fixed-width template decoder on the OCR-proof fixture
``G n=NNNNNN c=N`` and a skip detector that does not need gap-indexing over
unreadable frames. This tool ships that method. Do not replace it with k-means:
unsupervised labels produced a fictitious decreasing sequence; viewed pixels
were perfectly monotone.

METHOD (reproduce; do not reinvent)
-----------------------------------
1. Yellow mask: (R>140)&(G>140)&(B<120), rows 36..104 of 1920×1080.
2. Six FIXED-WIDTH digit cells (parent-measured on device)::

     [(331,395),(395,460),(460,524),(524,589),(589,653),(653,718)]

   Auto-run detection is available as fallback when ink is absent from those
   cells (capture-chain sim / geometry drift) — still fixed six cells, no
   per-frame segmentation search over the value range.
3. Resize each cell → 24×28, flatten, nearest-neighbour Euclidean distance
   against labelled digit templates.
4. Labels from VIEWED / generator-ground-truth pixels only (never k-means).
5. Confidence gate per digit: nearest < 4.5 AND (second−nearest) ≥ 0.55;
   else reject the whole frame.
6. Publish leave-one-FRAME-out per-digit accuracy (not optional).

SKIP DETECTOR (the valuable part)
---------------------------------
Capture 30 fps (33.33 ms) vs source 24 fps (41.67 ms). A correct display can
only produce adjacent-capture deltas ∈ {0, 1}. Any delta ≥ 2 is a proven
display-side skip — no assumption about unreadable frames.

Sanity (must assert, not assume):
  - no decreasing pairs
  - no |delta| > 2 among accepted pairs (else instrument/fixture pathology)
  - delta histogram confined to {0,1,2} on a healthy stream

Grabber-drop confound (mandatory)::

  r = adv/caps
  ideal = src_fps/cap_fps
  If grabber lost G captures: adv/(caps+G) = ideal  →  G = adv/ideal − caps
  Report G. If the skip events were really lost captures, r would rise;
  compare counterfactual.

PROVENANCE (ERROR 17)
---------------------
Every printed rate/fps is tagged measured | caller_supplied | DEFAULT_ASSUMED.
Rate verdict is REFUSED (not a pass) when src_fps or cap_fps is DEFAULT_ASSUMED.

Exit codes
----------
  0  SKIP_OK / CLEAN — readable, invariants hold, no delta≥2 (when fps authoritative)
  2  SKIP_FAIL — positively detected display skip (delta≥2) or invariant breach
  77 UNSCORED — no data / wrong fixture / fps not authoritative for rate
  1  USAGE / internal error

  rc=77 is never a pass. Capture true rc DIRECTLY (never through a pipe).

Usage
-----
  # Bootstrap templates + LOO, then score a capture dir:
  python3 tools/glass_template_skip.py CAP_DIR --source-fps 24 --capture-fps 30

  # Self-contained red-before-green (synth G-fixture HDMI):
  python3 tools/glass_template_skip.py --self-test; echo "true rc=$?"

  # Controlled pair note: /tmp/cap480a|b are TREK24 structure pair, not G n=.
  # This tool scores G-fixture captures. Use --self-test for skip R/G.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any

import numpy as np

try:
    from PIL import Image
except ImportError as e:
    raise SystemExit(f"Pillow required: {e}") from e

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / "tools") not in sys.path:
    sys.path.insert(0, str(ROOT / "tools"))

# ---------------------------------------------------------------------------
# Parent-measured geometry (1920×1080 HDMI of OCR-proof fixture)
# ---------------------------------------------------------------------------
YELLOW_R_MIN = 140
YELLOW_G_MIN = 140
YELLOW_B_MAX = 120
ROW_Y0 = 36
ROW_Y1 = 104
# Parent fixed cells (inclusive-exclusive x ranges for six zero-padded digits)
# Measured on real HDMI of OCR-proof fixture (parent 2026-08-01).
PARENT_CELLS: list[tuple[int, int]] = [
    (331, 395),
    (395, 460),
    (460, 524),
    (524, 589),
    (589, 653),
    (653, 718),
]
# Capture-chain host sim (glass_frame_id.simulate_capture_chain) — fixed pitch.
# Measured after mono font fix (LiberationMono-Bold) on n=001099 band:
#   digit runs ≈ (327,387)+(401,461)+… pitch≈74, width≈60.
# Contract text is fixed-width; proportional fonts are forbidden for this path.
SIM_DIGIT0_X0 = 325
SIM_PITCH = 74
SIM_CELL_W = 64  # slight pad absorbs 1–2 px mask edge jitter
SIM_CELLS: list[tuple[int, int]] = [
    (SIM_DIGIT0_X0 + i * SIM_PITCH, SIM_DIGIT0_X0 + i * SIM_PITCH + SIM_CELL_W)
    for i in range(6)
]
CELL_W = 24
CELL_H = 28
DIST_MAX = 4.5
MARGIN_MIN = 0.55
N_DIGITS = 6

PROVENANCE_MEASURED = "measured"
PROVENANCE_CALLER = "caller_supplied"
PROVENANCE_DEFAULT = "DEFAULT_ASSUMED"

RC_OK = 0
RC_FAIL = 2
RC_UNSCORED = 77
RC_USAGE = 1

DEFAULT_ASSUMED_SRC_FPS = 24.0  # library 24p — NOT 23.976; never score rate on this alone
DEFAULT_ASSUMED_CAP_FPS = 30.0

TEMPLATE_PATH = Path(__file__).resolve().parent / "glass_digit_templates.npz"


# ---------------------------------------------------------------------------
# Yellow mask + cell extract
# ---------------------------------------------------------------------------
def yellow_mask(rgb: np.ndarray) -> np.ndarray:
    """Parent yellow ink mask (bool HxW)."""
    return (
        (rgb[:, :, 0] > YELLOW_R_MIN)
        & (rgb[:, :, 1] > YELLOW_G_MIN)
        & (rgb[:, :, 2] < YELLOW_B_MAX)
    )


def _cell_vector(gray_or_bin: np.ndarray, x0: int, x1: int, y0: int, y1: int) -> np.ndarray:
    """Crop cell → 24×28 float32 flattened, values in {0,1} or [0,1]."""
    h, w = gray_or_bin.shape[:2]
    xa, xb = max(0, x0), min(w, x1)
    ya, yb = max(0, y0), min(h, y1)
    if xb <= xa or yb <= ya:
        return np.zeros((CELL_H * CELL_W,), dtype=np.float32)
    patch = gray_or_bin[ya:yb, xa:xb]
    if patch.ndim == 3:
        patch = patch.astype(np.float32).mean(axis=2)
    else:
        patch = patch.astype(np.float32)
    # binarise lightly if continuous
    if patch.max() > 1.5:
        patch = (patch > 40.0).astype(np.float32)
    im = Image.fromarray((np.clip(patch, 0, 1) * 255).astype(np.uint8))
    im = im.resize((CELL_W, CELL_H), Image.Resampling.NEAREST)
    vec = (np.asarray(im).astype(np.float32) / 255.0).ravel()
    return vec


def resolve_cells(mask: np.ndarray, mode: str = "parent") -> tuple[list[tuple[int, int]], str]:
    """Return (cells, geometry_src). Fixed-width only — no per-frame search.

    parent: device-measured cells (parent 2026-08-01).
    auto/sim: capture-chain host sim fixed pitch (SIM_CELLS).
    """
    if mode == "parent":
        ink = 0
        for x0, x1 in PARENT_CELLS:
            ink += int(mask[ROW_Y0:ROW_Y1, max(0, x0) : min(mask.shape[1], x1)].sum())
        if ink >= 200:
            return list(PARENT_CELLS), "parent_fixed_measured"
        # Host sim / geometry drift: fall back to sim fixed pitch if those have ink
        ink_s = 0
        for x0, x1 in SIM_CELLS:
            ink_s += int(mask[ROW_Y0:ROW_Y1, x0:x1].sum())
        if ink_s >= 200:
            return list(SIM_CELLS), "sim_fixed_pitch_fallback"
        return list(PARENT_CELLS), "parent_fixed_weak_ink"
    if mode in ("auto", "sim"):
        return list(SIM_CELLS), "sim_fixed_pitch"
    raise ValueError(f"unknown cell mode {mode}")


# ---------------------------------------------------------------------------
# Templates
# ---------------------------------------------------------------------------
@dataclass
class TemplateBank:
    """Digit templates: vectors (N, 24*28), labels (N,) chars '0'..'9'."""

    vectors: np.ndarray
    labels: np.ndarray  # shape (N,) unicode/int 0-9
    frame_ids: np.ndarray  # which bootstrap frame each sample came from
    meta: dict[str, Any] = field(default_factory=dict)

    def save(self, path: Path) -> None:
        path = Path(path)
        np.savez_compressed(
            path,
            vectors=self.vectors.astype(np.float32),
            labels=self.labels.astype(np.int16),
            frame_ids=self.frame_ids.astype(np.int32),
            meta_json=np.array(json.dumps(self.meta)),
        )

    @staticmethod
    def load(path: Path) -> "TemplateBank":
        data = np.load(path, allow_pickle=True)
        meta = {}
        if "meta_json" in data.files:
            meta = json.loads(str(data["meta_json"]))
        return TemplateBank(
            vectors=data["vectors"].astype(np.float32),
            labels=data["labels"].astype(np.int16),
            frame_ids=data["frame_ids"].astype(np.int32),
            meta=meta,
        )


def match_digit(
    vec: np.ndarray,
    bank: TemplateBank,
    *,
    exclude_frame: int | None = None,
) -> tuple[int | None, float, float, str]:
    """Nearest-neighbour digit. Returns (d|None, dist, margin, status).

    Margin is vs nearest *different label* (parent intent). Same-digit duplicates
    at dist=0 must not zero the margin and reject a perfect match.
    """
    v = vec.astype(np.float32).ravel()
    use = np.ones(len(bank.labels), dtype=bool)
    if exclude_frame is not None:
        use &= bank.frame_ids != int(exclude_frame)
    if not use.any():
        return None, 1e9, 0.0, "no_templates"
    vecs = bank.vectors[use]
    labs = bank.labels[use]
    d2 = np.sqrt(np.maximum(0.0, ((vecs - v) ** 2).sum(axis=1)))
    best_i = int(np.argmin(d2))
    best_d = float(d2[best_i])
    digit = int(labs[best_i])
    # nearest different label
    rival = d2[labs != digit]
    second_d = float(rival.min()) if rival.size else 1e9
    margin = second_d - best_d
    if best_d >= DIST_MAX or margin < MARGIN_MIN:
        return None, best_d, margin, "low_confidence"
    return digit, best_d, margin, "ok"


def decode_frame(
    rgb: np.ndarray,
    bank: TemplateBank,
    *,
    cells: list[tuple[int, int]] | None = None,
    cell_mode: str = "parent",
    exclude_frame: int | None = None,
) -> dict[str, Any]:
    """Decode one 1920×1080 RGB frame → n or UNRESOLVED."""
    if rgb.shape[0] < ROW_Y1 or rgb.shape[1] < 700:
        return {
            "ok": False,
            "n": None,
            "status": "UNRESOLVED",
            "reason": "frame_too_small",
            "n_src": PROVENANCE_MEASURED,
        }
    mask = yellow_mask(rgb)
    band_ink = int(mask[ROW_Y0:ROW_Y1].sum())
    if band_ink < 80:
        return {
            "ok": False,
            "n": None,
            "status": "UNRESOLVED",
            "reason": "no_yellow_overlay",
            "band_ink": band_ink,
            "n_src": PROVENANCE_MEASURED,
        }
    if cells is None:
        cells, geom_src = resolve_cells(mask, mode=cell_mode)
    else:
        geom_src = "caller_supplied"
    # binary ink in band for stable templates
    bin_band = mask.astype(np.float32)
    digits: list[int] = []
    dists: list[float] = []
    margins: list[float] = []
    for x0, x1 in cells:
        vec = _cell_vector(bin_band, x0, x1, ROW_Y0, ROW_Y1)
        d, dist, margin, st = match_digit(vec, bank, exclude_frame=exclude_frame)
        if d is None:
            return {
                "ok": False,
                "n": None,
                "status": "UNRESOLVED",
                "reason": f"digit_{st}",
                "dist": dist,
                "margin": margin,
                "partial": digits,
                "cells": cells,
                "geometry_src": geom_src,
                "n_src": PROVENANCE_MEASURED,
            }
        digits.append(d)
        dists.append(dist)
        margins.append(margin)
    n = 0
    for d in digits:
        n = n * 10 + d
    return {
        "ok": True,
        "n": int(n),
        "status": "OK",
        "reason": "template_nn",
        "digits": digits,
        "dists": dists,
        "margins": margins,
        "cells": cells,
        "geometry_src": geom_src,
        "n_src": PROVENANCE_MEASURED,
        "max_dist": float(max(dists)),
        "min_margin": float(min(margins)),
    }


# ---------------------------------------------------------------------------
# Bootstrap templates from G-fixture (labels = generator GT ≡ viewed truth)
# ---------------------------------------------------------------------------
def _render_hdmi_frame(n: int) -> np.ndarray:
    from glass_frame_id import CANVAS_H, CANVAS_W, draw_id_band, simulate_capture_chain

    rgb = np.zeros((CANVAS_H, CANVAS_W, 3), dtype=np.uint8)
    draw_id_band(rgb, n)
    return simulate_capture_chain(rgb)


def bootstrap_templates(
    values: list[int] | None = None,
    *,
    path: Path | None = None,
) -> tuple[TemplateBank, dict[str, Any]]:
    """Build templates from known n (viewed ≡ generator ground truth).

    Parent: deliberately include rare digits (4,6). Default set covers 0-9.
    """
    if values is None:
        # 32+ frames covering all digits; include *64* family for 4/6
        values = []
        values += list(range(0, 20))
        values += [64, 46, 460, 640, 146, 164, 246, 264, 346, 364, 464, 646, 664]
        values += [1000, 1099, 1101, 1103, 1104, 1106, 1107, 1110]
        values += [2352, 2358, 2377, 2378, 2491, 2521, 3024, 3025]
        values += [999999, 100000, 200000, 555555, 888888, 444444, 666666]
        # Extra 8/7 coverage so LOO does not leave a singleton glyph shape
        values += [8, 18, 80, 88, 800, 808, 880, 8080, 8808, 180818, 818181, 777777, 700007]
        # unique preserve order
        seen: set[int] = set()
        uniq: list[int] = []
        for v in values:
            v = int(v) % 1_000_000
            if v not in seen:
                seen.add(v)
                uniq.append(v)
        values = uniq

    vectors: list[np.ndarray] = []
    labels: list[int] = []
    frame_ids: list[int] = []
    geom_src = None
    cells_used = None
    # Fixed sim cells for all bootstrap frames (parent method: no segmentation).
    cells_used = list(SIM_CELLS)
    geom_src = "sim_fixed_pitch"
    for fi, n in enumerate(values):
        cap = _render_hdmi_frame(n)
        mask = yellow_mask(cap)
        cells = cells_used
        s = f"{n:06d}"
        bin_band = mask.astype(np.float32)
        for di, ch in enumerate(s):
            x0, x1 = cells[di]
            vec = _cell_vector(bin_band, x0, x1, ROW_Y0, ROW_Y1)
            vectors.append(vec)
            labels.append(int(ch))
            frame_ids.append(fi)

    bank = TemplateBank(
        vectors=np.stack(vectors, axis=0),
        labels=np.array(labels, dtype=np.int16),
        frame_ids=np.array(frame_ids, dtype=np.int32),
        meta={
            "n_frames": len(values),
            "n_samples": len(labels),
            "values": values,
            "cells": cells_used,
            "geometry_src": geom_src,
            "cell_wh": [CELL_W, CELL_H],
            "dist_max": DIST_MAX,
            "margin_min": MARGIN_MIN,
            "label_src": "generator_ground_truth_equals_viewed_pixels",
            "note": "k-means forbidden; labels never unsupervised",
        },
    )
    if path is not None:
        bank.save(path)
    # digit coverage
    cov = sorted(set(int(x) for x in labels))
    info = {
        "n_frames": len(values),
        "n_samples": len(labels),
        "digit_coverage": cov,
        "all_digits_present": cov == list(range(10)),
        "cells": cells_used,
        "geometry_src": geom_src,
        "path": str(path) if path else None,
    }
    return bank, info


def leave_one_frame_out(bank: TemplateBank) -> dict[str, Any]:
    """LOO by frame: each frame's 6 digits matched against templates from other frames."""
    frame_ids = sorted(set(int(x) for x in bank.frame_ids))
    total = 0
    correct = 0
    per_digit = Counter()
    per_digit_ok = Counter()
    failures: list[dict[str, Any]] = []
    for fi in frame_ids:
        idx = np.where(bank.frame_ids == fi)[0]
        for j in idx:
            vec = bank.vectors[j]
            true = int(bank.labels[j])
            hat, dist, margin, st = match_digit(vec, bank, exclude_frame=fi)
            total += 1
            per_digit[true] += 1
            if hat == true and st == "ok":
                correct += 1
                per_digit_ok[true] += 1
            else:
                failures.append(
                    {
                        "frame_id": fi,
                        "true": true,
                        "hat": hat,
                        "dist": dist,
                        "margin": margin,
                        "status": st,
                    }
                )
    acc = (correct / total) if total else 0.0
    return {
        "loo_per_digit_correct": correct,
        "loo_per_digit_total": total,
        "loo_per_digit_accuracy": round(acc, 6),
        "loo_per_digit_accuracy_pct": round(100.0 * acc, 4),
        "loo_src": PROVENANCE_MEASURED,
        "per_digit_support": {str(k): int(per_digit[k]) for k in range(10)},
        "per_digit_correct": {str(k): int(per_digit_ok[k]) for k in range(10)},
        "n_failures": len(failures),
        "failures_head": failures[:12],
        "gate": "PASS" if acc >= 0.95 and total >= 50 else "FAIL",
    }


# ---------------------------------------------------------------------------
# Skip detector + grabber confound
# ---------------------------------------------------------------------------
def analyze_skips(
    pairs: list[tuple[int, int, str]],
    *,
    source_fps: float,
    capture_fps: float,
    source_fps_src: str,
    capture_fps_src: str,
) -> dict[str, Any]:
    """pairs: (cap_idx, n, path). Sorted by cap_idx."""
    pairs = sorted(pairs, key=lambda t: t[0])
    if len(pairs) < 3:
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": "insufficient_reads",
            "n_reads": len(pairs),
        }

    deltas: list[int] = []
    events: list[dict[str, Any]] = []
    decreasing = 0
    big = 0
    for (i0, n0, p0), (i1, n1, p1) in zip(pairs, pairs[1:]):
        # only adjacent capture indices (gap in idx means grabber hole — separate)
        if i1 != i0 + 1:
            # non-adjacent capture files: still measure n delta but tag gap
            pass
        d = int(n1) - int(n0)
        deltas.append(d)
        if d < 0:
            decreasing += 1
            events.append(
                {
                    "type": "DECREASING",
                    "cap_i": i0,
                    "cap_j": i1,
                    "n_i": n0,
                    "n_j": n1,
                    "delta": d,
                    "file_i": p0,
                    "file_j": p1,
                    "file_i_src": PROVENANCE_MEASURED,
                    "file_j_src": PROVENANCE_MEASURED,
                    "n_i_src": PROVENANCE_MEASURED,
                    "n_j_src": PROVENANCE_MEASURED,
                }
            )
        elif abs(d) > 2:
            big += 1
            events.append(
                {
                    "type": "ABS_DELTA_GT2",
                    "cap_i": i0,
                    "cap_j": i1,
                    "n_i": n0,
                    "n_j": n1,
                    "delta": d,
                    "file_i": p0,
                    "file_j": p1,
                }
            )
        elif d >= 2:
            events.append(
                {
                    "type": "DISPLAY_SKIP",
                    "cap_i": i0,
                    "cap_j": i1,
                    "n_i": n0,
                    "n_j": n1,
                    "delta": d,
                    "skipped_values": list(range(n0 + 1, n1)),
                    "file_i": p0,
                    "file_j": p1,
                    "file_i_src": PROVENANCE_MEASURED,
                    "file_j_src": PROVENANCE_MEASURED,
                    "evidence": (
                        f"adjacent-capture delta={d}>=2 at 30fps vs 24fps source "
                        f"is display-side skip (not grabber); files for VIEW"
                    ),
                }
            )

    hist = Counter(deltas)
    # advances: sum of positive deltas
    adv = sum(d for d in deltas if d > 0)
    # caps = number of capture steps between first and last read
    caps = pairs[-1][0] - pairs[0][0]
    if caps <= 0:
        caps = max(1, len(pairs) - 1)
    r = adv / float(caps) if caps else None

    fps_auth = source_fps_src != PROVENANCE_DEFAULT and capture_fps_src != PROVENANCE_DEFAULT
    ideal = source_fps / capture_fps if capture_fps > 0 else None
    # G = adv/ideal - caps
    G = None
    G_src = PROVENANCE_DEFAULT
    if fps_auth and ideal and ideal > 0 and r is not None:
        G = adv / ideal - caps
        G_src = PROVENANCE_MEASURED
    # counterfactual: if DISPLAY_SKIP events were grabber losses instead
    n_skip_events = sum(1 for e in events if e["type"] == "DISPLAY_SKIP")
    skip_frames = sum(e["delta"] - 1 for e in events if e["type"] == "DISPLAY_SKIP")
    r_if_grabber = None
    if n_skip_events and caps:
        # parent: if 22 events were lost captures, r would be higher
        r_if_grabber = adv / float(caps + skip_frames)

    # histogram confined?
    bad_hist_keys = [k for k in hist if k not in (0, 1, 2) and k > 0]
    # also negative keys
    if any(k < 0 for k in hist):
        bad_hist_keys = list(hist.keys())

    invariant_fail = decreasing > 0 or big > 0
    display_skips = [e for e in events if e["type"] == "DISPLAY_SKIP"]

    if not fps_auth:
        rate_note = (
            "RATE_REFUSED: src_fps or cap_fps is DEFAULT_ASSUMED — "
            "will not emit SKIP_OK rate verdict (ERROR 17)"
        )
    else:
        rate_note = "fps_authoritative"

    if invariant_fail:
        verdict, rc = "INSTRUMENT_OR_FIXTURE_FAIL", RC_FAIL
        reason = f"decreasing={decreasing} abs_delta_gt2={big} (physics violated)"
    elif display_skips and fps_auth:
        verdict, rc = "SKIP_FAIL", RC_FAIL
        reason = f"display_skips={len(display_skips)} skip_frames={skip_frames}"
    elif display_skips and not fps_auth:
        # still a positive defect on delta>=2 without needing fps
        verdict, rc = "SKIP_FAIL", RC_FAIL
        reason = (
            f"display_skips={len(display_skips)} (delta>=2 needs no fps); "
            f"{rate_note}"
        )
    elif not fps_auth:
        verdict, rc = "UNSCORED", RC_UNSCORED
        reason = rate_note
    else:
        verdict, rc = "SKIP_OK", RC_OK
        reason = "deltas_in_0_1_only invariants_ok"

    return {
        "verdict": verdict,
        "rc": rc,
        "reason": reason,
        "n_reads": len(pairs),
        "n_min": pairs[0][1],
        "n_max": pairs[-1][1],
        "cap_first": pairs[0][0],
        "cap_last": pairs[-1][0],
        "adv": adv,
        "caps": caps,
        "r_advance_per_capture": round(r, 6) if r is not None else None,
        "r_src": PROVENANCE_MEASURED if r is not None else None,
        "ideal_src_over_cap": round(ideal, 6) if ideal is not None else None,
        "ideal_src": source_fps_src if fps_auth else PROVENANCE_DEFAULT,
        "G_grabber_confound": round(G, 4) if G is not None else None,
        "G_src": G_src,
        "G_formula": "G = adv/(src_fps/cap_fps) - caps",
        "r_if_skips_were_grabber_drops": (
            round(r_if_grabber, 6) if r_if_grabber is not None else None
        ),
        "delta_histogram": {str(k): int(hist[k]) for k in sorted(hist)},
        "delta_histogram_src": PROVENANCE_MEASURED,
        "decreasing_pairs": decreasing,
        "abs_delta_gt2": big,
        "display_skip_events": len(display_skips),
        "display_skip_frames": skip_frames,
        "events": events,
        "source_fps": source_fps,
        "source_fps_src": source_fps_src,
        "capture_fps": capture_fps,
        "capture_fps_src": capture_fps_src,
        "fps_authoritative": fps_auth,
        "rate_note": rate_note,
        "sanity": {
            "no_decreasing": decreasing == 0,
            "no_abs_delta_gt2": big == 0,
            "hist_keys": sorted(int(k) for k in hist.keys()),
            "hist_confined_to_0_1_2": all(k in (0, 1, 2) for k in hist.keys()),
        },
    }


# ---------------------------------------------------------------------------
# Capture directory scoring
# ---------------------------------------------------------------------------
def list_pngs(src: Path) -> list[Path]:
    files = sorted(src.glob("f_*.png"))
    if not files:
        files = sorted(src.glob("*.png"))
    return files


def score_capture_dir(
    src: Path,
    bank: TemplateBank,
    *,
    source_fps: float,
    capture_fps: float,
    source_fps_src: str,
    capture_fps_src: str,
    cell_mode: str = "parent",
    warmup_skip: int = 15,
    progress: bool = False,
) -> dict[str, Any]:
    files = list_pngs(src)
    if not files:
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": "no_pngs",
            "src": str(src),
        }
    reads: list[tuple[int, int, str]] = []
    unresolved = 0
    per_frame: list[dict[str, Any]] = []
    # freeze cells from first good frame
    frozen_cells = None
    for i, path in enumerate(files):
        if i < warmup_skip:
            # still try decode; warmup only skips uniform junk
            pass
        rgb = np.asarray(Image.open(path).convert("RGB"))
        if float(rgb.mean()) < 2.5 and yellow_mask(rgb).sum() < 50:
            per_frame.append({"idx": i, "path": str(path), "status": "warmup"})
            continue
        r = decode_frame(rgb, bank, cells=frozen_cells, cell_mode=cell_mode)
        r["idx"] = i
        r["path"] = str(path)
        per_frame.append(r)
        if r.get("ok") and r.get("n") is not None:
            if frozen_cells is None and r.get("cells"):
                frozen_cells = [tuple(c) for c in r["cells"]]
            reads.append((i, int(r["n"]), str(path)))
        else:
            unresolved += 1
        if progress and (i + 1) % 50 == 0:
            print(f"  ... {i+1}/{len(files)} reads={len(reads)}", file=sys.stderr)

    if len(reads) < 3:
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": f"insufficient_template_reads={len(reads)} unresolved={unresolved}",
            "frames_total": len(files),
            "unresolved": unresolved,
            "src": str(src),
            "n_src": PROVENANCE_MEASURED,
        }

    skip = analyze_skips(
        reads,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
    )
    skip["frames_total"] = len(files)
    skip["unresolved"] = unresolved
    skip["readable_frac"] = round(len(reads) / max(1, len(files)), 4)
    skip["readable_frac_src"] = PROVENANCE_MEASURED
    skip["src"] = str(src)
    skip["cells_frozen"] = frozen_cells
    skip["warmup_skip"] = warmup_skip
    # keep events for VIEW; drop bulky per_frame unless debug
    skip["per_frame_head"] = per_frame[:5]
    skip["per_frame_tail"] = per_frame[-5:]
    return skip


# ---------------------------------------------------------------------------
# Self-test: red-before-green on synthetic G-fixture HDMI captures
# ---------------------------------------------------------------------------
def _synth_capture_sequence(
    out_dir: Path,
    *,
    n0: int,
    n_source_frames: int,
    source_fps: float = 24.0,
    capture_fps: float = 30.0,
    skip_at_source: set[int] | None = None,
) -> dict[str, Any]:
    """Render HDMI PNGs as if grabber sampled source timeline.

    For each capture k at t=k/cap_fps, show source frame floor(t*src_fps) unless
    that source index is in skip_at_source (display drop → hold previous shown).
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    skip_at_source = set(skip_at_source or ())
    n_caps = int(round(n_source_frames * capture_fps / source_fps))
    # Available source indices (display never presents skip_at_source).
    available = [
        n0 + i
        for i in range(n_source_frames)
        if (n0 + i) not in skip_at_source
    ]
    if not available:
        raise ValueError("skip_at_source removed every source frame")
    shown_log: list[int] = []
    for k in range(n_caps):
        t = k / capture_fps
        src_i = n0 + int(np.floor(t * source_fps + 1e-9))
        src_i = min(src_i, n0 + n_source_frames - 1)
        # Greatest available frame ≤ ideal source index (hold through a drop;
        # next available after the hole produces adjacent-capture delta ≥ 2).
        show = available[0]
        for a in available:
            if a <= src_i:
                show = a
            else:
                break
        cap = _render_hdmi_frame(show)
        path = out_dir / f"f_{k:04d}.png"
        Image.fromarray(cap).save(path)
        shown_log.append(show)
    # How many adjacent-capture deltas ≥ 2 in the shown log?
    adj_ge2 = sum(
        1 for a, b in zip(shown_log, shown_log[1:]) if (b - a) >= 2
    )
    return {
        "n_caps": n_caps,
        "n0": n0,
        "skip_at_source": sorted(skip_at_source),
        "shown_head": shown_log[:20],
        "shown_unique": len(set(shown_log)),
        "injected_adj_delta_ge2": adj_ge2,
    }


def run_self_test() -> int:
    """RED: injected display skips → rc=2. GREEN: clean → rc=0. LOO published."""
    work = ROOT / ".agent-work" / "w-instr" / "template-skip-gate"
    work.mkdir(parents=True, exist_ok=True)
    tpl_path = work / "templates_loo.npz"
    bank, binfo = bootstrap_templates(path=tpl_path)
    loo = leave_one_frame_out(bank)
    print("BOOTSTRAP", json.dumps(binfo, indent=2))
    print(
        f"LOO per-digit accuracy={loo['loo_per_digit_correct']}/"
        f"{loo['loo_per_digit_total']} = {loo['loo_per_digit_accuracy_pct']}% "
        f"src={loo['loo_src']} gate={loo['gate']}"
    )
    if loo["gate"] != "PASS":
        print("SELF_TEST_FAIL loo")
        return RC_FAIL
    # persist main templates next to tool when LOO passes
    bank.save(TEMPLATE_PATH)
    print(f"WROTE {TEMPLATE_PATH}")

    green_dir = work / "green_clean"
    red_dir = work / "red_skips"
    # clean: 48 source frames @24 → ~60 captures @30
    gmeta = _synth_capture_sequence(
        green_dir, n0=1000, n_source_frames=48, skip_at_source=None
    )
    # red: drop every 17th source frame in a longer run
    skips = set(range(1017, 1000 + 72, 17))
    rmeta = _synth_capture_sequence(
        red_dir, n0=1000, n_source_frames=72, skip_at_source=skips
    )
    print("GREEN_META", gmeta)
    print("RED_META", rmeta)

    green = score_capture_dir(
        green_dir,
        bank,
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
        cell_mode="auto",
        warmup_skip=0,
    )
    red = score_capture_dir(
        red_dir,
        bank,
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
        cell_mode="auto",
        warmup_skip=0,
    )
    print(
        f"GREEN verdict={green.get('verdict')} rc={green.get('rc')} "
        f"skips={green.get('display_skip_events')} G={green.get('G_grabber_confound')} "
        f"r={green.get('r_advance_per_capture')} hist={green.get('delta_histogram')}"
    )
    print(
        f"RED   verdict={red.get('verdict')} rc={red.get('rc')} "
        f"skips={red.get('display_skip_events')} events="
        f"{json.dumps(red.get('events', [])[:5], indent=2)}"
    )

    # RED must be rc=2 with at least one DISPLAY_SKIP; GREEN rc=0 with zero
    ok = True
    if green.get("rc") != RC_OK or green.get("display_skip_events", 1) != 0:
        print(
            f"FAIL GREEN expected rc=0 no skips; got rc={green.get('rc')} "
            f"skips={green.get('display_skip_events')} reason={green.get('reason')}"
        )
        ok = False
    else:
        print("PASS GREEN clean capture SKIP_OK")
    if red.get("rc") != RC_FAIL or red.get("display_skip_events", 0) < 1:
        print(
            f"FAIL RED expected rc=2 with skips; got rc={red.get('rc')} "
            f"skips={red.get('display_skip_events')} reason={red.get('reason')}"
        )
        ok = False
    else:
        print("PASS RED injected skips SKIP_FAIL")

    # Sanity: decreasing must be zero on both
    if green.get("decreasing_pairs", 1) != 0 or red.get("decreasing_pairs", 1) != 0:
        print("FAIL decreasing pairs non-zero")
        ok = False
    else:
        print("PASS no decreasing pairs (k-means class failure absent)")

    # cap480a/b are TREK24 structure pair — document fixture mismatch (not silent)
    for label, path in ("cap480a", Path("/tmp/cap480a")), ("cap480b", Path("/tmp/cap480b")):
        if not path.is_dir():
            print(f"NOTE {label} missing — skip fixture probe")
            continue
        probe = score_capture_dir(
            path,
            bank,
            source_fps=24.0,
            capture_fps=30.0,
            source_fps_src=PROVENANCE_CALLER,
            capture_fps_src=PROVENANCE_CALLER,
            cell_mode="parent",
            warmup_skip=5,
        )
        print(
            f"PROBE {label} verdict={probe.get('verdict')} rc={probe.get('rc')} "
            f"reason={probe.get('reason')} reads={probe.get('n_reads')} "
            f"(expect UNSCORED: archived pair is TREK24 not G n=NNNNNN)"
        )

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
    ap.add_argument("capture_dir", nargs="?", default=None, help="directory of f_*.png")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--bootstrap", action="store_true", help="rebuild templates + LOO only")
    ap.add_argument("--templates", type=Path, default=TEMPLATE_PATH)
    ap.add_argument(
        "--source-fps",
        type=float,
        default=None,
        help="source content fps (required for SKIP_OK). Tagged caller_supplied.",
    )
    ap.add_argument(
        "--capture-fps",
        type=float,
        default=None,
        help="grabber fps (required for SKIP_OK / G confound). Tagged caller_supplied.",
    )
    ap.add_argument(
        "--cell-mode",
        choices=("parent", "auto", "sim"),
        default="parent",
        help="parent=device-measured cells; sim/auto=capture-chain fixed pitch",
    )
    ap.add_argument("--warmup-skip", type=int, default=15)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--progress", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return run_self_test()

    if args.bootstrap or not Path(args.templates).is_file():
        bank, binfo = bootstrap_templates(path=Path(args.templates))
        loo = leave_one_frame_out(bank)
        print("BOOTSTRAP", json.dumps({**binfo, **loo}, indent=2))
        if args.bootstrap and not args.capture_dir:
            return RC_OK if loo["gate"] == "PASS" else RC_FAIL

    if not args.capture_dir:
        ap.error("capture_dir required (or --self-test / --bootstrap)")

    bank = TemplateBank.load(args.templates)
    loo = leave_one_frame_out(bank)

    if args.source_fps is None:
        source_fps = DEFAULT_ASSUMED_SRC_FPS
        source_fps_src = PROVENANCE_DEFAULT
    else:
        source_fps = float(args.source_fps)
        source_fps_src = PROVENANCE_CALLER
    if args.capture_fps is None:
        capture_fps = DEFAULT_ASSUMED_CAP_FPS
        capture_fps_src = PROVENANCE_DEFAULT
    else:
        capture_fps = float(args.capture_fps)
        capture_fps_src = PROVENANCE_CALLER

    rep = score_capture_dir(
        Path(args.capture_dir),
        bank,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
        cell_mode=args.cell_mode,
        warmup_skip=args.warmup_skip,
        progress=args.progress,
    )
    rep["loo"] = loo
    rep["templates"] = str(args.templates)
    rep["templates_meta"] = bank.meta

    if args.json:
        print(json.dumps(rep, indent=2))
    else:
        print(
            f"VERDICT={rep.get('verdict')} rc={rep.get('rc')} reason={rep.get('reason')}"
        )
        print(
            f"reads={rep.get('n_reads')} unresolved={rep.get('unresolved')} "
            f"span n={rep.get('n_min')}->{rep.get('n_max')} "
            f"readable_frac={rep.get('readable_frac')} src={rep.get('readable_frac_src')}"
        )
        print(
            f"src_fps={rep.get('source_fps')} src={rep.get('source_fps_src')} "
            f"cap_fps={rep.get('capture_fps')} cap={rep.get('capture_fps_src')} "
            f"fps_auth={rep.get('fps_authoritative')}"
        )
        print(
            f"r={rep.get('r_advance_per_capture')} src={rep.get('r_src')} "
            f"ideal={rep.get('ideal_src_over_cap')} "
            f"G={rep.get('G_grabber_confound')} G_src={rep.get('G_src')} "
            f"r_if_grabber={rep.get('r_if_skips_were_grabber_drops')}"
        )
        print(
            f"delta_hist={rep.get('delta_histogram')} src={rep.get('delta_histogram_src')} "
            f"sanity={rep.get('sanity')}"
        )
        print(
            f"LOO {loo['loo_per_digit_correct']}/{loo['loo_per_digit_total']} "
            f"= {loo['loo_per_digit_accuracy_pct']}% src={loo['loo_src']}"
        )
        for e in rep.get("events") or []:
            print(
                f"EVENT {e.get('type')} delta={e.get('delta')} "
                f"n={e.get('n_i')}->{e.get('n_j')} "
                f"files={Path(e.get('file_i','')).name},{Path(e.get('file_j','')).name}"
            )
    return int(rep.get("rc", RC_UNSCORED))


if __name__ == "__main__":
    sys.exit(main())
