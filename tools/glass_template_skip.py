#!/usr/bin/env python3
"""Template counter decoder + completeness skip detector (parent method).

Parent findings folded in (device-measured 2026-08-01, 720p60 bank /tmp/p60):
  F1 Checksum gate: overlay is ``G n=NNNNNN c=D`` with
     D == (sum of six digits) mod 10. Decode 7 cells; accept ONLY if checksum
     closes. Replaces reliance on dist/margin alone.
  F2 Derived cells: 1080p hardcoded coords are WRONG at 720p (only rate that
     reaches 60 fps). Yellow-mask column runs + fixed-pitch on the n= field
     extent; works at 1080 and 720.
  F3 Completeness detector (bias-free): for each value v in [lo,hi] absent from
     the accepted set, find bracketing accepted captures a<b. v is a genuine
     display skip IFF rejected_between == []. Transition-torn rejects must not
     count as skips (adjacent-Δ under-counts / mis-counts).
  F4 ERROR-18 sampling-margin gate: refuse skip verdict (rc=77) when
     max_measured_capture_interval_ms >= min_hold_ms. Intervals from pts.csv
     (ffprobe pts_time), NEVER from di/capture_fps.

Also: LOO on SIM templates is labelled SIM_ONLY — never presented as device
accuracy. Device LOO requires --bootstrap-viewed-gt / parent T60.pkl.

k-means is FORBIDDEN (produced fictitious decreasing sequences).

Exit codes
----------
  0  SKIP_OK — margin OK, completeness finds 0 genuine skips, invariants hold
  2  SKIP_FAIL — ≥1 genuine display skip (rejected_between=[]) or physics break
  77 UNSCORED — no data / zero sampling margin / fps not authoritative
  1  usage / internal

  rc=77 is never a pass. Capture true rc DIRECTLY (never through a pipe).

Usage
-----
  python3 tools/glass_template_skip.py --self-test; echo "true rc=$?"
  python3 tools/glass_template_skip.py --p60-acceptance; echo "true rc=$?"
  python3 tools/glass_template_skip.py /tmp/p60/png \\
      --templates /tmp/p60/T60.pkl --pts /tmp/p60/pts.csv \\
      --source-fps 24 --capture-fps 60 --refresh-hz 60 --force-mode 720 \\
      ; echo "true rc=$?"
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from dataclasses import dataclass, field
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
# Constants
# ---------------------------------------------------------------------------
YELLOW_R_MIN = 140
YELLOW_G_MIN = 140
YELLOW_B_MAX = 120
CELL_W = 24
CELL_H = 28
N_DIGITS = 6
# Soft NN gate; checksum is the hard accept (F1). Parent run60 used max_dist<8.
DIST_MAX_SOFT = 8.0

# Parent-viewed 720p anchors (dec60.py) — locked for p60 acceptance
P720_ROWS = (26, 68)
P720_N_BOUNDS = [221, 264, 307, 349, 392, 435, 479]
P720_C = (592, 640)
# Parent-viewed 1080p anchors
P1080_ROWS = (36, 104)
P1080_N_BOUNDS = [331, 395, 460, 524, 589, 653, 718]
P1080_C = (780, 850)
# Host sim (mono font + capture chain) — SIM_ONLY LOO
SIM_ROWS = (32, 90)
SIM_N_BOUNDS = [325, 399, 473, 547, 621, 695, 759]
SIM_C = (980, 1060)

PROVENANCE_MEASURED = "measured"
PROVENANCE_CALLER = "caller_supplied"
PROVENANCE_DEFAULT = "DEFAULT_ASSUMED"
PROVENANCE_SIM_ONLY = "SIM_ONLY"

RC_OK = 0
RC_FAIL = 2
RC_UNSCORED = 77
RC_USAGE = 1

DEFAULT_ASSUMED_SRC_FPS = 24.0  # NOT 23.976
DEFAULT_ASSUMED_CAP_FPS = 30.0
DEFAULT_ASSUMED_REFRESH_HZ = 60.0

TEMPLATE_PATH = Path(__file__).resolve().parent / "glass_digit_templates.npz"


# ---------------------------------------------------------------------------
# Yellow mask + geometry (F2)
# ---------------------------------------------------------------------------
def yellow_mask(rgb: np.ndarray) -> np.ndarray:
    return (
        (rgb[:, :, 0] > YELLOW_R_MIN)
        & (rgb[:, :, 1] > YELLOW_G_MIN)
        & (rgb[:, :, 2] < YELLOW_B_MAX)
    )


def _column_runs(
    col: np.ndarray, *, min_width: int = 3, gap_split: int = 3
) -> list[tuple[int, int]]:
    n = int(col.shape[0])
    raw: list[tuple[int, int]] = []
    i = 0
    while i < n:
        if col[i]:
            j = i
            while j < n and col[j]:
                j += 1
            raw.append((i, j))
            i = j
        else:
            i += 1
    if not raw:
        return []
    merged = [list(raw[0])]
    for a, b in raw[1:]:
        if a - merged[-1][1] < gap_split:
            merged[-1][1] = b
        else:
            merged.append([a, b])
    return [(a, b) for a, b in merged if b - a >= min_width]


def _bounds_to_cells(bounds: list[int]) -> list[tuple[int, int]]:
    return [(int(bounds[i]), int(bounds[i + 1])) for i in range(len(bounds) - 1)]


def derive_overlay_geometry(
    rgb: np.ndarray,
    *,
    force_mode: str | None = None,
) -> dict[str, Any]:
    """Derive row band, 6 n-cells, c-cell from yellow mask (F2)."""
    h, w = rgb.shape[:2]
    if force_mode == "720":
        return _anchor_geometry(P720_ROWS, P720_N_BOUNDS, P720_C, w, h, "parent_dec60_720")
    if force_mode == "1080":
        return _anchor_geometry(
            P1080_ROWS, P1080_N_BOUNDS, P1080_C, w, h, "parent_anchor_1080"
        )
    if force_mode == "sim":
        return _anchor_geometry(SIM_ROWS, SIM_N_BOUNDS, SIM_C, w, h, "sim_fixed")

    mask = yellow_mask(rgb)
    top_lim = max(80, h // 4)
    row_any = mask[:top_lim].any(axis=1)
    rs = np.where(row_any)[0]
    if rs.size < 4:
        return _fallback_geometry(h, w, "no_yellow_rows")
    r0, r1 = int(rs[0]), int(rs[-1]) + 1
    col = mask[r0:r1].any(axis=0)
    runs = _column_runs(col, min_width=3, gap_split=3)

    if len(runs) >= 10:
        # G n= DDDDDD c= C  → last run = checksum; digits after first '=' (run3)
        n_x0 = int(runs[3][0])
        n_x1 = int(runs[-4][1])
        if n_x1 - n_x0 >= 6 * 20:
            pitch = (n_x1 - n_x0) / float(N_DIGITS)
            n_bounds = [int(round(n_x0 + i * pitch)) for i in range(N_DIGITS + 1)]
            n_bounds[-1] = n_x1
            c0, c1 = int(runs[-1][0]), int(runs[-1][1])
            pad = max(2, (c1 - c0) // 10)
            c_cell = (max(0, c0 - pad), min(w, c1 + pad))
            return {
                "rows": (r0, r1),
                "n_bounds": n_bounds,
                "cells": _bounds_to_cells(n_bounds),
                "c_cell": c_cell,
                "runs": runs,
                "geometry_src": "derived_yellow_runs",
                "frame_wh": (w, h),
                "frame_wh_src": PROVENANCE_MEASURED,
            }
    return _fallback_geometry(h, w, f"runs={len(runs)}")


def _anchor_geometry(rows, n_bounds, c_cell, w, h, src: str) -> dict[str, Any]:
    nb = list(n_bounds)
    return {
        "rows": tuple(rows),
        "n_bounds": nb,
        "cells": _bounds_to_cells(nb),
        "c_cell": tuple(c_cell),
        "runs": [],
        "geometry_src": src,
        "frame_wh": (w, h),
        "frame_wh_src": PROVENANCE_MEASURED,
    }


def _fallback_geometry(h: int, w: int, reason: str) -> dict[str, Any]:
    if h <= 800:
        return _anchor_geometry(
            P720_ROWS, P720_N_BOUNDS, P720_C, w, h, f"p720_fallback:{reason}"
        )
    if h >= 1000:
        return _anchor_geometry(
            P1080_ROWS, P1080_N_BOUNDS, P1080_C, w, h, f"p1080_fallback:{reason}"
        )
    return _anchor_geometry(
        P720_ROWS, P720_N_BOUNDS, P720_C, w, h, f"p720_fallback:{reason}"
    )


def _cell_vector_from_mask(
    mask: np.ndarray, x0: int, x1: int, y0: int, y1: int
) -> np.ndarray:
    h, w = mask.shape[:2]
    xa, xb = max(0, int(x0)), min(w, int(x1))
    ya, yb = max(0, int(y0)), min(h, int(y1))
    if xb <= xa or yb <= ya:
        return np.zeros((CELL_H * CELL_W,), dtype=np.float32)
    patch = mask[ya:yb, xa:xb].astype(np.float32)
    im = Image.fromarray((np.clip(patch, 0, 1) * 255).astype(np.uint8))
    im = im.resize((CELL_W, CELL_H), Image.Resampling.NEAREST)
    return (np.asarray(im).astype(np.float32) / 255.0).ravel()


# ---------------------------------------------------------------------------
# Templates
# ---------------------------------------------------------------------------
@dataclass
class TemplateBank:
    vectors: np.ndarray
    labels: np.ndarray
    frame_ids: np.ndarray
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
        path = Path(path)
        if path.suffix == ".pkl":
            return TemplateBank.from_parent_pkl(path)
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

    @staticmethod
    def from_parent_pkl(path: Path) -> "TemplateBank":
        import pickle

        raw = pickle.load(open(path, "rb"))
        vectors = []
        labels = []
        frame_ids = []
        fi = 0
        # One sample id per template vector so LOO is leave-one-SAMPLE-out
        # (parent device LOO 98.32% = 117/119 was sample-level).
        for d, ts in sorted(raw.items(), key=lambda kv: str(kv[0])):
            lab = int(str(d))
            for t in ts:
                vectors.append(np.asarray(t, dtype=np.float32).ravel())
                labels.append(lab)
                frame_ids.append(fi)
                fi += 1
        return TemplateBank(
            vectors=np.stack(vectors, axis=0),
            labels=np.array(labels, dtype=np.int16),
            frame_ids=np.array(frame_ids, dtype=np.int32),
            meta={
                "label_src": "parent_viewed_pixels_T60",
                "path": str(path),
                "loo_scope": "device_templates",
            },
        )


def match_digit(
    vec: np.ndarray,
    bank: TemplateBank,
    *,
    exclude_frame: int | None = None,
    dist_max: float = DIST_MAX_SOFT,
) -> tuple[int | None, float, float, str]:
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
    rival = d2[labs != digit]
    second_d = float(rival.min()) if rival.size else 1e9
    margin = second_d - best_d
    if best_d >= dist_max:
        return None, best_d, margin, "low_confidence"
    return digit, best_d, margin, "ok"


def checksum_mod10(digits: list[int]) -> int:
    return int(sum(digits) % 10)


def decode_frame(
    rgb: np.ndarray,
    bank: TemplateBank,
    *,
    geom: dict[str, Any] | None = None,
    force_mode: str | None = None,
    exclude_frame: int | None = None,
    dist_max: float = DIST_MAX_SOFT,
) -> dict[str, Any]:
    """Decode one RGB frame → n via 6 digits + c checksum (F1)."""
    h, w = rgb.shape[:2]
    if h < 40 or w < 400:
        return {
            "ok": False,
            "n": None,
            "status": "UNRESOLVED",
            "reason": "frame_too_small",
            "n_src": PROVENANCE_MEASURED,
        }
    mask = yellow_mask(rgb)
    if geom is None:
        geom = derive_overlay_geometry(rgb, force_mode=force_mode)
    r0, r1 = geom["rows"]
    cells: list[tuple[int, int]] = list(geom["cells"])
    c_cell = tuple(geom["c_cell"])
    band_ink = int(mask[r0:r1].sum())
    if band_ink < 40:
        return {
            "ok": False,
            "n": None,
            "status": "UNRESOLVED",
            "reason": "no_yellow_overlay",
            "band_ink": band_ink,
            "n_src": PROVENANCE_MEASURED,
            "geom": geom,
        }

    digits: list[int] = []
    dists: list[float] = []
    margins: list[float] = []
    for x0, x1 in cells:
        vec = _cell_vector_from_mask(mask, x0, x1, r0, r1)
        d, dist, margin, st = match_digit(
            vec, bank, exclude_frame=exclude_frame, dist_max=dist_max
        )
        if d is None:
            return {
                "ok": False,
                "n": None,
                "status": "UNRESOLVED",
                "reason": f"digit_{st}",
                "dist": dist,
                "margin": margin,
                "partial": digits,
                "geom": geom,
                "n_src": PROVENANCE_MEASURED,
            }
        digits.append(int(d))
        dists.append(dist)
        margins.append(margin)

    vec_c = _cell_vector_from_mask(mask, c_cell[0], c_cell[1], r0, r1)
    c_hat, c_dist, c_margin, c_st = match_digit(
        vec_c, bank, exclude_frame=exclude_frame, dist_max=dist_max
    )
    if c_hat is None:
        return {
            "ok": False,
            "n": None,
            "status": "UNRESOLVED",
            "reason": f"checksum_digit_{c_st}",
            "dist": c_dist,
            "geom": geom,
            "digits": digits,
            "n_src": PROVENANCE_MEASURED,
        }
    expect_c = checksum_mod10(digits)
    if int(c_hat) != expect_c:
        return {
            "ok": False,
            "n": None,
            "status": "UNRESOLVED",
            "reason": "checksum_mismatch",
            "digits": digits,
            "c_hat": int(c_hat),
            "c_expect": expect_c,
            "dists": dists + [c_dist],
            "max_dist": float(max(dists + [c_dist])),
            "geom": geom,
            "n_src": PROVENANCE_MEASURED,
            "checksum_src": PROVENANCE_MEASURED,
        }

    n = 0
    for d in digits:
        n = n * 10 + d
    return {
        "ok": True,
        "n": int(n),
        "status": "OK",
        "reason": "template_nn_checksum_ok",
        "digits": digits,
        "c": int(c_hat),
        "c_expect": expect_c,
        "dists": dists + [c_dist],
        "margins": margins + [c_margin],
        "max_dist": float(max(dists + [c_dist])),
        "min_margin": float(min(margins + [c_margin])),
        "geom": geom,
        "geometry_src": geom.get("geometry_src"),
        "n_src": PROVENANCE_MEASURED,
        "checksum_src": PROVENANCE_MEASURED,
    }


# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
def _render_hdmi_frame(n: int) -> np.ndarray:
    from glass_frame_id import CANVAS_H, CANVAS_W, draw_id_band, simulate_capture_chain

    rgb = np.zeros((CANVAS_H, CANVAS_W, 3), dtype=np.uint8)
    draw_id_band(rgb, n)
    return simulate_capture_chain(rgb)


def bootstrap_templates_sim(
    values: list[int] | None = None,
    *,
    path: Path | None = None,
) -> tuple[TemplateBank, dict[str, Any]]:
    """SIM_ONLY templates from generator GT (== viewed on host synth)."""
    if values is None:
        values = []
        values += list(range(0, 20))
        values += [64, 46, 460, 640, 146, 164, 246, 264, 346, 364, 464, 646, 664]
        values += [1000, 1099, 1101, 1103, 1104, 1106, 1107, 1110]
        values += [2352, 2358, 2377, 2378, 2491, 2521, 3024, 3025]
        values += [999999, 100000, 200000, 555555, 888888, 444444, 666666]
        values += [
            8,
            18,
            80,
            88,
            800,
            808,
            880,
            8080,
            8808,
            180818,
            818181,
            777777,
            700007,
        ]
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
    geom = {
        "rows": SIM_ROWS,
        "n_bounds": list(SIM_N_BOUNDS),
        "cells": _bounds_to_cells(SIM_N_BOUNDS),
        "c_cell": SIM_C,
        "geometry_src": "sim_fixed",
    }
    for fi, n in enumerate(values):
        cap = _render_hdmi_frame(n)
        mask = yellow_mask(cap)
        r0, r1 = geom["rows"]
        s = f"{n:06d}"
        for di, ch in enumerate(s):
            x0, x1 = geom["cells"][di]
            vectors.append(_cell_vector_from_mask(mask, x0, x1, r0, r1))
            labels.append(int(ch))
            frame_ids.append(fi)
        c = checksum_mod10([int(ch) for ch in s])
        cx0, cx1 = geom["c_cell"]
        vectors.append(_cell_vector_from_mask(mask, cx0, cx1, r0, r1))
        labels.append(c)
        frame_ids.append(fi)

    bank = TemplateBank(
        vectors=np.stack(vectors, axis=0),
        labels=np.array(labels, dtype=np.int16),
        frame_ids=np.array(frame_ids, dtype=np.int32),
        meta={
            "n_frames": len(values),
            "n_samples": len(labels),
            "values": values,
            "geometry": geom,
            "label_src": "generator_ground_truth_equals_viewed_pixels",
            "loo_scope": PROVENANCE_SIM_ONLY,
            "note": "k-means forbidden; LOO is SIM_ONLY not device accuracy",
        },
    )
    if path is not None:
        bank.save(path)
    cov = sorted(set(int(x) for x in labels))
    info = {
        "n_frames": len(values),
        "n_samples": len(labels),
        "digit_coverage": cov,
        "all_digits_present": cov == list(range(10)),
        "loo_scope": PROVENANCE_SIM_ONLY,
        "path": str(path) if path else None,
    }
    return bank, info


def bootstrap_templates_from_viewed_gt(
    png_dir: Path,
    gt: dict[int, str],
    *,
    path: Path | None = None,
    force_mode: str | None = "720",
) -> tuple[TemplateBank, dict[str, Any]]:
    files = list_pngs(Path(png_dir))
    vectors: list[np.ndarray] = []
    labels: list[int] = []
    frame_ids: list[int] = []
    geom = None
    used = 0
    for idx, val in sorted(gt.items()):
        if idx < 0 or idx >= len(files):
            continue
        rgb = np.asarray(Image.open(files[idx]).convert("RGB"))
        if geom is None:
            geom = derive_overlay_geometry(rgb, force_mode=force_mode)
        mask = yellow_mask(rgb)
        r0, r1 = geom["rows"]
        val_s = str(val).zfill(6)[-6:]
        for di, ch in enumerate(val_s):
            x0, x1 = geom["cells"][di]
            vectors.append(_cell_vector_from_mask(mask, x0, x1, r0, r1))
            labels.append(int(ch))
            frame_ids.append(used)
        chk = checksum_mod10([int(x) for x in val_s])
        cx0, cx1 = geom["c_cell"]
        vectors.append(_cell_vector_from_mask(mask, cx0, cx1, r0, r1))
        labels.append(chk)
        frame_ids.append(used)
        used += 1

    bank = TemplateBank(
        vectors=np.stack(vectors, axis=0),
        labels=np.array(labels, dtype=np.int16),
        frame_ids=np.array(frame_ids, dtype=np.int32),
        meta={
            "n_frames": used,
            "n_samples": len(labels),
            "gt_indices": sorted(gt.keys()),
            "geometry": geom,
            "label_src": "parent_viewed_pixels",
            "loo_scope": "device_capture",
            "note": "k-means forbidden",
        },
    )
    if path is not None:
        bank.save(path)
    cov = sorted(set(int(x) for x in labels))
    return bank, {
        "n_frames": used,
        "n_samples": len(labels),
        "digit_coverage": cov,
        "all_digits_present": cov == list(range(10)),
        "loo_scope": "device_capture",
        "geometry_src": geom.get("geometry_src") if geom else None,
        "path": str(path) if path else None,
    }


def leave_one_frame_out(bank: TemplateBank) -> dict[str, Any]:
    frame_ids = sorted(set(int(x) for x in bank.frame_ids))
    total = correct = 0
    failures: list[dict[str, Any]] = []
    per_digit = Counter()
    per_digit_ok = Counter()
    for fi in frame_ids:
        idx = np.where(bank.frame_ids == fi)[0]
        for j in idx:
            true = int(bank.labels[j])
            hat, dist, margin, st = match_digit(
                bank.vectors[j], bank, exclude_frame=fi, dist_max=DIST_MAX_SOFT
            )
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
    scope = bank.meta.get("loo_scope", PROVENANCE_SIM_ONLY)
    return {
        "loo_per_digit_correct": correct,
        "loo_per_digit_total": total,
        "loo_per_digit_accuracy": round(acc, 6),
        "loo_per_digit_accuracy_pct": round(100.0 * acc, 4),
        "loo_src": PROVENANCE_MEASURED,
        "loo_scope": scope,
        "loo_scope_note": (
            "SIM_ONLY — not device accuracy"
            if scope == PROVENANCE_SIM_ONLY
            else "device_or_viewed_templates"
        ),
        "per_digit_support": {str(k): int(per_digit[k]) for k in range(10)},
        "per_digit_correct": {str(k): int(per_digit_ok[k]) for k in range(10)},
        "n_failures": len(failures),
        "failures_head": failures[:12],
        "gate": "PASS" if acc >= 0.95 and total >= 50 else "FAIL",
    }


# ---------------------------------------------------------------------------
# PTS / sampling margin (F4 ERROR-18)
# ---------------------------------------------------------------------------
def load_pts_ms(pts_path: Path) -> tuple[list[float], str]:
    pts_path = Path(pts_path)
    pts: list[float] = []
    with open(pts_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.lower().startswith("pts"):
                continue
            part = line.split(",")[0].strip()
            try:
                pts.append(float(part))
            except ValueError:
                continue
    return pts, PROVENANCE_MEASURED


def sampling_margin_gate(
    pts_s: list[float] | None,
    *,
    source_fps: float,
    refresh_hz: float,
    source_fps_src: str,
    refresh_hz_src: str,
    outlier_ms: float = 100.0,
) -> dict[str, Any]:
    """F4: refuse skip verdict when max interval >= min_hold_ms."""
    min_hold_ms = (1000.0 / refresh_hz) * float(np.floor(refresh_hz / source_fps))
    min_hold_src = (
        PROVENANCE_MEASURED
        if source_fps_src != PROVENANCE_DEFAULT and refresh_hz_src != PROVENANCE_DEFAULT
        else PROVENANCE_DEFAULT
    )
    out: dict[str, Any] = {
        "min_hold_ms": round(min_hold_ms, 4),
        "min_hold_ms_src": min_hold_src,
        "min_hold_formula": "1000/refresh_hz * floor(refresh_hz/source_fps)",
        "source_fps": source_fps,
        "source_fps_src": source_fps_src,
        "refresh_hz": refresh_hz,
        "refresh_hz_src": refresh_hz_src,
        "pts_available": pts_s is not None and len(pts_s) >= 3,
    }
    if pts_s is None or len(pts_s) < 3:
        out.update(
            {
                "margin_ok": False,
                "reason": "no_pts_measured_intervals_required",
                "refuse_skip_verdict": True,
                "intervals_src": PROVENANCE_DEFAULT,
            }
        )
        return out
    iv_ms = np.diff(np.asarray(pts_s, dtype=np.float64)) * 1000.0
    iv_non = iv_ms[iv_ms < outlier_ms]
    if iv_non.size == 0:
        out.update(
            {
                "margin_ok": False,
                "reason": "all_intervals_outlier",
                "refuse_skip_verdict": True,
                "intervals_src": PROVENANCE_MEASURED,
            }
        )
        return out
    max_iv = float(iv_non.max())
    med_iv = float(np.median(iv_ms))
    hist = Counter(int(round(float(x))) for x in iv_ms)
    margin_ok = max_iv < min_hold_ms
    out.update(
        {
            "max_measured_capture_interval_ms": round(max_iv, 4),
            "median_capture_interval_ms": round(med_iv, 4),
            "interval_hist_ms_rounded": {str(k): int(hist[k]) for k in sorted(hist)},
            "intervals_src": PROVENANCE_MEASURED,
            "margin_ok": margin_ok,
            "refuse_skip_verdict": not margin_ok,
            "reason": (
                "sampling_margin_ok"
                if margin_ok
                else (
                    f"ERROR18_zero_margin max_iv={max_iv:.3f}ms >= "
                    f"min_hold={min_hold_ms:.3f}ms — refuse skip verdict"
                )
            ),
        }
    )
    return out


# ---------------------------------------------------------------------------
# Completeness detector (F3)
# ---------------------------------------------------------------------------
def analyze_completeness(
    per_frame: list[dict[str, Any]],
    *,
    source_fps: float,
    capture_fps: float,
    source_fps_src: str,
    capture_fps_src: str,
    margin: dict[str, Any],
) -> dict[str, Any]:
    accepted = [
        (int(r["idx"]), int(r["n"]), str(r.get("path", "")))
        for r in per_frame
        if r.get("ok") and r.get("n") is not None
    ]
    rejected_set = {
        int(r["idx"])
        for r in per_frame
        if not (r.get("ok") and r.get("n") is not None)
    }
    path_by_idx = {int(r["idx"]): str(r.get("path", "")) for r in per_frame}

    if len(accepted) < 3:
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": f"insufficient_accepted={len(accepted)}",
            "n_accepted": len(accepted),
            "n_frames": len(per_frame),
        }

    adj_hist: Counter = Counter()
    decreasing = 0
    for (i0, n0, _), (i1, n1, _) in zip(accepted, accepted[1:]):
        if i1 == i0 + 1:
            d = n1 - n0
            adj_hist[d] += 1
            if d < 0:
                decreasing += 1

    lo_n = accepted[0][1]
    hi_n = accepted[-1][1]
    obs = {n for _, n, _ in accepted}
    missing = [v for v in range(lo_n, hi_n + 1) if v not in obs]

    genuine: list[dict[str, Any]] = []
    torn_not_skip: list[dict[str, Any]] = []
    for v in missing:
        befores = [(i, n, p) for i, n, p in accepted if n < v]
        afters = [(i, n, p) for i, n, p in accepted if n > v]
        if not befores or not afters:
            continue
        a = befores[-1]
        b = afters[0]
        rej_between = [j for j in range(a[0] + 1, b[0]) if j in rejected_set]
        rec = {
            "v": v,
            "bracket_a_idx": a[0],
            "bracket_a_n": a[1],
            "bracket_a_file": a[2] or path_by_idx.get(a[0], ""),
            "bracket_b_idx": b[0],
            "bracket_b_n": b[1],
            "bracket_b_file": b[2] or path_by_idx.get(b[0], ""),
            "rejected_between": rej_between,
            "rejected_between_files": [path_by_idx.get(j, "") for j in rej_between],
            "evidence_src": PROVENANCE_MEASURED,
        }
        if not rej_between:
            rec["type"] = "GENUINE_DISPLAY_SKIP"
            genuine.append(rec)
        else:
            rec["type"] = "TORN_TRANSITION_NOT_SKIP"
            torn_not_skip.append(rec)

    cap0, cap1 = accepted[0][0], accepted[-1][0]
    caps = max(1, cap1 - cap0)
    adv_span = hi_n - lo_n
    span_ratio = adv_span / float(caps)
    n_adj_steps = sum(
        1
        for (i0, _, _), (i1, _, _) in zip(accepted, accepted[1:])
        if i1 == i0 + 1
    )
    adj_adv = sum(d * c for d, c in adj_hist.items() if d > 0)
    adj_ratio = adj_adv / float(n_adj_steps or 1)

    fps_auth = (
        source_fps_src != PROVENANCE_DEFAULT
        and capture_fps_src != PROVENANCE_DEFAULT
    )
    ideal = source_fps / capture_fps if capture_fps > 0 else None
    G = None
    G_src = PROVENANCE_DEFAULT
    if fps_auth and ideal and ideal > 0:
        G = adv_span / ideal - caps
        # G is computed: adv/caps are measured; ideal ratio is caller_supplied fps.
        G_src = "computed(adv_caps=measured;ideal_ratio=caller_supplied_fps)"

    refuse = bool(margin.get("refuse_skip_verdict", True))
    if refuse:
        verdict, rc = "UNSCORED", RC_UNSCORED
        reason = str(margin.get("reason", "sampling_margin_refused"))
    elif decreasing > 0:
        verdict, rc = "INSTRUMENT_OR_FIXTURE_FAIL", RC_FAIL
        reason = f"decreasing_pairs={decreasing}"
    elif genuine:
        verdict, rc = "SKIP_FAIL", RC_FAIL
        reason = (
            f"genuine_display_skips={len(genuine)} "
            f"(completeness rejected_between=[]); "
            f"torn_not_skip={len(torn_not_skip)}"
        )
    elif not fps_auth:
        verdict, rc = "UNSCORED", RC_UNSCORED
        reason = "RATE_REFUSED: src_fps or cap_fps DEFAULT_ASSUMED (ERROR 17)"
    else:
        verdict, rc = "SKIP_OK", RC_OK
        reason = (
            f"completeness_clean genuine=0 torn_not_skip={len(torn_not_skip)} "
            f"margin_ok"
        )

    return {
        "verdict": verdict,
        "rc": rc,
        "reason": reason,
        "n_frames": len(per_frame),
        "n_accepted": len(accepted),
        "n_rejected": len(rejected_set),
        "accepted_frac": round(len(accepted) / max(1, len(per_frame)), 4),
        "accepted_frac_src": PROVENANCE_MEASURED,
        "n_min": lo_n,
        "n_max": hi_n,
        "cap_first": cap0,
        "cap_last": cap1,
        "adv_span": adv_span,
        "caps_span": caps,
        "span_ratio": round(span_ratio, 6),
        "span_ratio_src": PROVENANCE_MEASURED,
        "ideal_src_over_cap": round(ideal, 6) if ideal is not None else None,
        "ideal_src": source_fps_src if fps_auth else PROVENANCE_DEFAULT,
        "adjacent_delta_histogram": {
            str(k): int(adj_hist[k]) for k in sorted(adj_hist)
        },
        "adjacent_delta_histogram_src": PROVENANCE_MEASURED,
        "adjacent_ratio": round(adj_ratio, 6),
        "adjacent_ratio_note": (
            "biased low vs span_ratio when rejects hit transitions (F3)"
        ),
        "missing_from_accepted": len(missing),
        "genuine_display_skips": len(genuine),
        "torn_transition_not_skip": len(torn_not_skip),
        "genuine_events": genuine,
        "torn_events_head": torn_not_skip[:8],
        "decreasing_pairs": decreasing,
        "G_grabber_confound": round(G, 4) if G is not None else None,
        "G_src": G_src,
        "G_formula": "G = adv_span/(src_fps/cap_fps) - caps_span",
        "G_note": (
            "G>0 consistent with grabber losing captures (raises adv/caps). "
            "G≈0 match. G<0 is NOT grabber-drop: advance slightly under ideal "
            "(display skips, span endpoints, or cap_fps slightly high). "
            "p60 parent: G≈-5.5 on caps≈3578 is |G|/caps≈0.15% — shortfall "
            "adv vs ideal*caps of ~2.2 source units (G*(src/cap)); "
            "at 30fps parent measured G≈0. Do not treat small negative G as defect."
        ),
        "source_fps": source_fps,
        "source_fps_src": source_fps_src,
        "capture_fps": capture_fps,
        "capture_fps_src": capture_fps_src,
        "fps_authoritative": fps_auth,
        "sampling_margin": margin,
        "detector": "completeness_rejected_between_empty",
        "detector_note": (
            "Genuine skip iff value absent from accepted set AND no rejected "
            "capture between bracketing accepts. Adjacent-Δ alone is biased."
        ),
    }


# ---------------------------------------------------------------------------
# Capture scoring
# ---------------------------------------------------------------------------
def list_pngs(src: Path) -> list[Path]:
    files = sorted(Path(src).glob("f_*.png"))
    if not files:
        files = sorted(Path(src).glob("*.png"))
    return files


def score_capture_dir(
    src: Path,
    bank: TemplateBank,
    *,
    source_fps: float,
    capture_fps: float,
    source_fps_src: str,
    capture_fps_src: str,
    refresh_hz: float = DEFAULT_ASSUMED_REFRESH_HZ,
    refresh_hz_src: str = PROVENANCE_DEFAULT,
    pts_path: Path | None = None,
    force_mode: str | None = None,
    warmup_skip: int = 0,
    freeze_geom: bool = True,
    progress: bool = False,
    dist_max: float = DIST_MAX_SOFT,
) -> dict[str, Any]:
    files = list_pngs(src)
    if not files:
        return {
            "verdict": "UNSCORED",
            "rc": RC_UNSCORED,
            "reason": "no_pngs",
            "src": str(src),
        }

    pts_s = None
    pts_src = PROVENANCE_DEFAULT
    if pts_path is not None and Path(pts_path).is_file():
        pts_s, pts_src = load_pts_ms(Path(pts_path))

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
                    "reason": "warmup",
                }
            )
            continue
        rgb = np.asarray(Image.open(path).convert("RGB"))
        if geom is None or not freeze_geom:
            g = derive_overlay_geometry(rgb, force_mode=force_mode)
            if freeze_geom:
                geom = g
        else:
            g = geom
        r = decode_frame(rgb, bank, geom=g, force_mode=force_mode, dist_max=dist_max)
        r["idx"] = i
        r["path"] = str(path)
        if pts_s is not None and i < len(pts_s):
            r["pts_s"] = pts_s[i]
            r["pts_src"] = pts_src
        per_frame.append(r)
        if progress and (i + 1) % 200 == 0:
            ok_n = sum(1 for x in per_frame if x.get("ok"))
            print(f"  ... {i+1}/{len(files)} accepted={ok_n}", file=sys.stderr)

    rep = analyze_completeness(
        per_frame,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
        margin=margin,
    )
    rep["src"] = str(src)
    rep["geometry_frozen"] = geom
    rep["pts_path"] = str(pts_path) if pts_path else None
    rep["pts_src"] = pts_src if pts_s is not None else PROVENANCE_DEFAULT
    rep["warmup_skip"] = warmup_skip
    rep["per_frame_head"] = [
        {k: x.get(k) for k in ("idx", "ok", "n", "reason", "max_dist", "c", "path")}
        for x in per_frame[:5]
    ]
    rep["per_frame_tail"] = [
        {k: x.get(k) for k in ("idx", "ok", "n", "reason", "max_dist", "c", "path")}
        for x in per_frame[-5:]
    ]
    return rep


# ---------------------------------------------------------------------------
# Self-test + p60 acceptance
# ---------------------------------------------------------------------------
def _synth_sequence(
    out_dir: Path,
    *,
    n0: int,
    n_source_frames: int,
    source_fps: float = 24.0,
    capture_fps: float = 60.0,
    skip_at_source: set[int] | None = None,
    pts_path: Path | None = None,
) -> dict[str, Any]:
    out_dir.mkdir(parents=True, exist_ok=True)
    skip_at_source = set(skip_at_source or ())
    n_caps = int(round(n_source_frames * capture_fps / source_fps))
    available = [
        n0 + i for i in range(n_source_frames) if (n0 + i) not in skip_at_source
    ]
    shown: list[int] = []
    pts: list[float] = []
    for k in range(n_caps):
        t = k / capture_fps
        src_i = n0 + int(np.floor(t * source_fps + 1e-9))
        src_i = min(src_i, n0 + n_source_frames - 1)
        show = available[0]
        for a in available:
            if a <= src_i:
                show = a
            else:
                break
        Image.fromarray(_render_hdmi_frame(show)).save(out_dir / f"f_{k:04d}.png")
        shown.append(show)
        pts.append(t)
    if pts_path is not None:
        pts_path.write_text("\n".join(f"{p:.6f}" for p in pts) + "\n")
    return {
        "n_caps": n_caps,
        "shown_unique": len(set(shown)),
        "skip_at_source": sorted(skip_at_source),
    }


def run_self_test() -> int:
    work = ROOT / ".agent-work" / "w-instr" / "template-skip-gate"
    work.mkdir(parents=True, exist_ok=True)
    bank, binfo = bootstrap_templates_sim(path=work / "templates_sim.npz")
    loo = leave_one_frame_out(bank)
    print("BOOTSTRAP_SIM", json.dumps(binfo, indent=2))
    print(
        f"LOO_SIM_ONLY {loo['loo_per_digit_correct']}/{loo['loo_per_digit_total']} "
        f"= {loo['loo_per_digit_accuracy_pct']}% scope={loo['loo_scope']} "
        f"({loo['loo_scope_note']}) gate={loo['gate']}"
    )
    if loo["gate"] != "PASS":
        print("SELF_TEST_FAIL loo_sim")
        return RC_FAIL
    bank.save(TEMPLATE_PATH)

    green = work / "green60"
    red = work / "red60"
    g_pts = work / "green60_pts.csv"
    r_pts = work / "red60_pts.csv"
    _synth_sequence(green, n0=1000, n_source_frames=48, capture_fps=60.0, pts_path=g_pts)
    _synth_sequence(
        red,
        n0=1000,
        n_source_frames=72,
        capture_fps=60.0,
        skip_at_source={1017, 1034, 1051, 1068},
        pts_path=r_pts,
    )

    common = dict(
        source_fps=24.0,
        capture_fps=60.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
        refresh_hz=60.0,
        refresh_hz_src=PROVENANCE_CALLER,
        force_mode="sim",
        warmup_skip=0,
    )
    g = score_capture_dir(green, bank, pts_path=g_pts, **common)
    r = score_capture_dir(red, bank, pts_path=r_pts, **common)
    print(
        f"GREEN verdict={g.get('verdict')} rc={g.get('rc')} "
        f"genuine={g.get('genuine_display_skips')} torn={g.get('torn_transition_not_skip')} "
        f"span_ratio={g.get('span_ratio')} adj_hist={g.get('adjacent_delta_histogram')} "
        f"margin_ok={g.get('sampling_margin', {}).get('margin_ok')}"
    )
    print(
        f"RED   verdict={r.get('verdict')} rc={r.get('rc')} "
        f"genuine={r.get('genuine_display_skips')} events="
        f"{json.dumps(r.get('genuine_events', [])[:4], indent=2)}"
    )

    ok = True
    if g.get("rc") != RC_OK or g.get("genuine_display_skips", 1) != 0:
        print(f"FAIL GREEN rc={g.get('rc')} genuine={g.get('genuine_display_skips')}")
        ok = False
    else:
        print("PASS GREEN")
    if r.get("rc") != RC_FAIL or r.get("genuine_display_skips", 0) < 1:
        print(f"FAIL RED rc={r.get('rc')} genuine={r.get('genuine_display_skips')}")
        ok = False
    else:
        print("PASS RED")

    zm = work / "zero_margin"
    zm_pts = work / "zero_margin_pts.csv"
    _synth_sequence(zm, n0=2000, n_source_frames=24, capture_fps=30.0, pts_path=zm_pts)
    z = score_capture_dir(
        zm,
        bank,
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
        refresh_hz=60.0,
        refresh_hz_src=PROVENANCE_CALLER,
        pts_path=zm_pts,
        force_mode="sim",
        warmup_skip=0,
    )
    if z.get("rc") != RC_UNSCORED or not z.get("sampling_margin", {}).get(
        "refuse_skip_verdict", False
    ):
        print(f"FAIL ERROR18 gate rc={z.get('rc')} margin={z.get('sampling_margin')}")
        ok = False
    else:
        print(f"PASS ERROR18 refuse rc=77 reason={z.get('reason')}")

    p60 = Path("/tmp/p60/png")
    if p60.is_dir():
        sample = list_pngs(p60)[100]
        rgb = np.asarray(Image.open(sample).convert("RGB"))
        dg = derive_overlay_geometry(rgb)  # auto derive, not force
        print(
            f"DERIVE720 rows={dg['rows']} n_bounds={dg['n_bounds']} "
            f"c={dg['c_cell']} src={dg['geometry_src']}"
        )
        nb = dg["n_bounds"]
        if abs(nb[0] - 221) > 15 or abs(nb[-1] - 479) > 15:
            print(f"FAIL derive720 n-field far from parent anchors: {nb}")
            ok = False
        else:
            print("PASS derive720 near parent anchors")

    if ok:
        print("SELF_TEST_OK")
        return RC_OK
    print("SELF_TEST_FAIL")
    return RC_FAIL


def run_p60_acceptance() -> int:
    """Reproduce parent p60 numbers exactly (device banked, no device touch)."""
    png = Path("/tmp/p60/png")
    pts = Path("/tmp/p60/pts.csv")
    t60 = Path("/tmp/p60/T60.pkl")
    if not png.is_dir() or not t60.is_file() or not pts.is_file():
        print("P60_SKIP missing /tmp/p60 bank")
        return RC_UNSCORED

    bank_pkl = TemplateBank.from_parent_pkl(t60)
    loo = leave_one_frame_out(bank_pkl)
    print(
        f"P60_DEVICE_LOO {loo['loo_per_digit_correct']}/{loo['loo_per_digit_total']} "
        f"= {loo['loo_per_digit_accuracy_pct']}% scope={loo['loo_scope']} "
        f"({loo['loo_scope_note']})"
    )

    geom = {
        "rows": P720_ROWS,
        "n_bounds": list(P720_N_BOUNDS),
        "cells": _bounds_to_cells(P720_N_BOUNDS),
        "c_cell": P720_C,
        "geometry_src": "parent_dec60_locked",
        "frame_wh": (1280, 720),
    }
    files = list_pngs(png)
    pts_s, _ = load_pts_ms(pts)
    per_frame: list[dict[str, Any]] = []
    for i, path in enumerate(files):
        rgb = np.asarray(Image.open(path).convert("RGB"))
        r = decode_frame(rgb, bank_pkl, geom=geom, dist_max=8.0)
        r["idx"] = i
        r["path"] = str(path)
        per_frame.append(r)
        if (i + 1) % 500 == 0:
            print(
                f"  p60 {i+1} ok={sum(1 for x in per_frame if x.get('ok'))}",
                file=sys.stderr,
            )

    margin = sampling_margin_gate(
        pts_s,
        source_fps=24.0,
        refresh_hz=60.0,
        source_fps_src=PROVENANCE_MEASURED,
        refresh_hz_src=PROVENANCE_CALLER,
    )
    rep = analyze_completeness(
        per_frame,
        source_fps=24.0,
        capture_fps=60.0,
        source_fps_src=PROVENANCE_MEASURED,
        capture_fps_src=PROVENANCE_MEASURED,
        margin=margin,
    )
    print(
        f"P60 accepted={rep['n_accepted']}/{rep['n_frames']} "
        f"frac={rep['accepted_frac']} decr={rep['decreasing_pairs']}"
    )
    print(
        f"P60 adj_hist={rep['adjacent_delta_histogram']} "
        f"span_ratio={rep['span_ratio']} genuine={rep['genuine_display_skips']}"
    )
    print(f"P60 genuine_events={json.dumps(rep.get('genuine_events'), indent=2)}")
    print(
        f"P60 margin_ok={margin.get('margin_ok')} "
        f"max_iv={margin.get('max_measured_capture_interval_ms')} "
        f"min_hold={margin.get('min_hold_ms')} "
        f"iv_hist={margin.get('interval_hist_ms_rounded')}"
    )
    print(f"P60 verdict={rep['verdict']} rc={rep['rc']} reason={rep['reason']}")

    ok = True
    if rep["n_accepted"] != 3179 or rep["n_frames"] != 3591:
        print(
            f"FAIL accepted want 3179/3591 got {rep['n_accepted']}/{rep['n_frames']}"
        )
        ok = False
    else:
        print("PASS accepted 3179/3591")
    if rep["decreasing_pairs"] != 0:
        print(f"FAIL decreasing={rep['decreasing_pairs']}")
        ok = False
    else:
        print("PASS decreasing=0")
    want_hist = {"0": 1916, "1": 1107, "2": 1}
    if rep["adjacent_delta_histogram"] != want_hist:
        print(
            f"FAIL adj_hist want {want_hist} got {rep['adjacent_delta_histogram']}"
        )
        ok = False
    else:
        print("PASS adj_hist {0:1916,1:1107,2:1}")
    if abs(float(rep["span_ratio"]) - 0.3994) > 0.0002:
        print(f"FAIL span_ratio want ~0.3994 got {rep['span_ratio']}")
        ok = False
    else:
        print("PASS span_ratio ~0.3994")
    if rep["genuine_display_skips"] != 1:
        print(f"FAIL genuine want 1 got {rep['genuine_display_skips']}")
        ok = False
    else:
        g0 = rep["genuine_events"][0]
        if int(g0["v"]) != 5578:
            print(f"FAIL genuine v want 5578 got {g0['v']}")
            ok = False
        else:
            print("PASS genuine skip exactly 005578")
    if not margin.get("margin_ok"):
        print(f"FAIL margin should be ok at 60fps: {margin}")
        ok = False
    else:
        print("PASS sampling margin ok at 60fps")
    if rep["rc"] != RC_FAIL:
        print(f"FAIL rc want 2 got {rep['rc']}")
        ok = False
    else:
        print("PASS rc=2 SKIP_FAIL")

    if ok:
        print("P60_ACCEPTANCE_OK")
        return RC_OK
    print("P60_ACCEPTANCE_FAIL")
    return RC_FAIL


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("capture_dir", nargs="?", default=None)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument(
        "--p60-acceptance",
        action="store_true",
        help="reproduce parent /tmp/p60 numbers (3179/3591, genuine=005578)",
    )
    ap.add_argument("--bootstrap", action="store_true", help="rebuild SIM templates + LOO")
    ap.add_argument(
        "--bootstrap-viewed-gt",
        type=Path,
        default=None,
        help="JSON {frame_index: 'NNNNnn'} viewed labels for device bootstrap",
    )
    ap.add_argument("--templates", type=Path, default=TEMPLATE_PATH)
    ap.add_argument("--pts", type=Path, default=None, help="pts.csv from ffprobe pts_time")
    ap.add_argument("--source-fps", type=float, default=None)
    ap.add_argument("--capture-fps", type=float, default=None)
    ap.add_argument("--refresh-hz", type=float, default=None)
    ap.add_argument(
        "--force-mode",
        choices=("720", "1080", "sim"),
        default=None,
        help="lock geometry anchors (720=parent dec60 cells)",
    )
    ap.add_argument("--warmup-skip", type=int, default=0)
    ap.add_argument("--dist-max", type=float, default=DIST_MAX_SOFT)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--progress", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return run_self_test()
    if args.p60_acceptance:
        return run_p60_acceptance()

    if args.bootstrap or not Path(args.templates).is_file():
        bank, binfo = bootstrap_templates_sim(path=Path(args.templates))
        loo = leave_one_frame_out(bank)
        print("BOOTSTRAP_SIM", json.dumps({**binfo, **loo}, indent=2))
        if args.bootstrap and not args.capture_dir:
            return RC_OK if loo["gate"] == "PASS" else RC_FAIL

    if args.bootstrap_viewed_gt is not None:
        gt = json.loads(Path(args.bootstrap_viewed_gt).read_text())
        gt = {int(k): str(v) for k, v in gt.items()}
        if not args.capture_dir:
            ap.error("--bootstrap-viewed-gt needs capture_dir of PNGs")
        bank, binfo = bootstrap_templates_from_viewed_gt(
            Path(args.capture_dir),
            gt,
            path=Path(args.templates),
            force_mode=args.force_mode or "720",
        )
        loo = leave_one_frame_out(bank)
        print("BOOTSTRAP_VIEWED", json.dumps({**binfo, **loo}, indent=2))
        return RC_OK if loo["gate"] == "PASS" else RC_FAIL

    if not args.capture_dir:
        ap.error("capture_dir required (or --self-test / --p60-acceptance)")

    bank = TemplateBank.load(args.templates)
    loo = leave_one_frame_out(bank)

    if args.source_fps is None:
        source_fps, source_fps_src = DEFAULT_ASSUMED_SRC_FPS, PROVENANCE_DEFAULT
    else:
        source_fps, source_fps_src = float(args.source_fps), PROVENANCE_CALLER
    if args.capture_fps is None:
        capture_fps, capture_fps_src = DEFAULT_ASSUMED_CAP_FPS, PROVENANCE_DEFAULT
    else:
        capture_fps, capture_fps_src = float(args.capture_fps), PROVENANCE_CALLER
    if args.refresh_hz is None:
        refresh_hz, refresh_hz_src = DEFAULT_ASSUMED_REFRESH_HZ, PROVENANCE_DEFAULT
    else:
        refresh_hz, refresh_hz_src = float(args.refresh_hz), PROVENANCE_CALLER

    force = args.force_mode
    if force is None and str(args.templates).endswith("T60.pkl"):
        force = "720"

    rep = score_capture_dir(
        Path(args.capture_dir),
        bank,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
        refresh_hz=refresh_hz,
        refresh_hz_src=refresh_hz_src,
        pts_path=args.pts,
        force_mode=force,
        warmup_skip=args.warmup_skip,
        progress=args.progress,
        dist_max=float(args.dist_max),
    )
    rep["loo"] = loo
    rep["templates"] = str(args.templates)

    if args.json:
        print(json.dumps(rep, indent=2, default=str))
    else:
        print(
            f"VERDICT={rep.get('verdict')} rc={rep.get('rc')} reason={rep.get('reason')}"
        )
        print(
            f"accepted={rep.get('n_accepted')}/{rep.get('n_frames')} "
            f"frac={rep.get('accepted_frac')} src={rep.get('accepted_frac_src')} "
            f"span n={rep.get('n_min')}->{rep.get('n_max')} "
            f"span_ratio={rep.get('span_ratio')} src={rep.get('span_ratio_src')}"
        )
        print(
            f"src_fps={rep.get('source_fps')} src={rep.get('source_fps_src')} "
            f"cap_fps={rep.get('capture_fps')} src={rep.get('capture_fps_src')} "
            f"fps_auth={rep.get('fps_authoritative')}"
        )
        sm = rep.get("sampling_margin") or {}
        print(
            f"margin_ok={sm.get('margin_ok')} "
            f"max_iv_ms={sm.get('max_measured_capture_interval_ms')} "
            f"min_hold_ms={sm.get('min_hold_ms')} iv_src={sm.get('intervals_src')} "
            f"refuse={sm.get('refuse_skip_verdict')}"
        )
        print(
            f"adj_hist={rep.get('adjacent_delta_histogram')} "
            f"genuine={rep.get('genuine_display_skips')} "
            f"torn_not_skip={rep.get('torn_transition_not_skip')} "
            f"G={rep.get('G_grabber_confound')} G_src={rep.get('G_src')} "
            f"G_formula={rep.get('G_formula')}"
        )
        if rep.get("G_note"):
            print(f"G_note={rep.get('G_note')}")
        print(
            f"LOO {loo['loo_per_digit_correct']}/{loo['loo_per_digit_total']} "
            f"= {loo['loo_per_digit_accuracy_pct']}% scope={loo['loo_scope']} "
            f"({loo['loo_scope_note']})"
        )
        for e in rep.get("genuine_events") or []:
            print(
                f"GENUINE_SKIP v={e.get('v')} "
                f"a={e.get('bracket_a_n')}@"
                f"{Path(str(e.get('bracket_a_file', '') or '')).name} "
                f"b={e.get('bracket_b_n')}@"
                f"{Path(str(e.get('bracket_b_file', '') or '')).name} "
                f"rejected_between={e.get('rejected_between')}"
            )
    return int(rep.get("rc", RC_UNSCORED))


if __name__ == "__main__":
    sys.exit(main())
