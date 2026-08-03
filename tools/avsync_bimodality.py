#!/usr/bin/env python3
"""Data-driven bimodality classifier for HDMI A/V offset runs.

WHY
---
Parent measured a BIMODAL 480p offset: two clusters ~117 ms apart, n=8 balanced
4/4, interleaved in ONE daemon lifetime on byte-identical config. Every
daemon-side observable is blind. tools/avsync_measure_hdmi.py is the only
sensor; this tool classifies a *set of run medians* honestly.

DOES NOT hardcode cluster centres from a previous experiment (ERROR 17 class).
Centres are measured from the supplied values via a 1-D two-means split.

Exit codes
----------
  0   UNIMODAL — positively one cluster (product-stable)
  2   BIMODAL  — positively two clusters with n>=min each (the defect)
  3   MIXED_CAPTURE_CONFIG — HARD FAIL: JSON runs have differing (or missing)
      capture_config.fingerprint. Parent: wallclock fix shifted absolute median
      ~90 ms; pooling pre/post configs manufactures fake bimodality. Never 77.
  77  UNSCORED — n too small / cannot assign min-n per cluster (never a pass)
  1   usage

A positively measured BIMODAL never decays to 77.
MIXED_CAPTURE_CONFIG never decays to 77.

Every printed value: measured | caller_supplied | DEFAULT_ASSUMED | NO-DATA.

Any "first" value carries its own timestamp / index (sampling-phase trap).

Usage
-----
  python3 tools/avsync_bimodality.py --values -314.3 -316.0 -197.2 -196.0 -318 -197 -314 -198
  python3 tools/avsync_bimodality.py --json-dir .agent-work/avsync-cluster/
  python3 tools/avsync_bimodality.py --csv runs.csv   # columns: session_id,offset_ms[,t_s]
  python3 tools/avsync_bimodality.py --self-test; echo "true rc=$?"
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

RC_UNIMODAL = 0
RC_USAGE = 1
RC_BIMODAL = 2
# Hard fail: mixed or missing capture_config fingerprints on JSON inputs.
# Distinct from UNSCORED (could not classify) and BIMODAL (measured defect).
RC_MIXED_CAPTURE_CONFIG = 3
RC_UNSCORED = 77

PROVENANCE_MEASURED = "measured"
PROVENANCE_CALLER = "caller_supplied"
PROVENANCE_DEFAULT_ASSUMED = "DEFAULT_ASSUMED"
PROVENANCE_NO_DATA = "NO-DATA"

# Design floor: parent pre-reg requires n>=2 per cluster before directional claim.
DEFAULT_MIN_N_PER_CLUSTER = 2
# Separation must exceed this multiple of pooled within-cluster std to call BIMODAL.
DEFAULT_SEP_SIGMA = 3.0
# Absolute floor (ms): below this, even a clean split is UNIMODAL (noise).
# Half of measured ~117 ms cluster sep is a design bound, not a measurement.
DEFAULT_MIN_SEP_MS = 40.0


def _tag(value: Any, src: str) -> str:
    if isinstance(value, float):
        if value is None or (isinstance(value, float) and (math.isnan(value) or math.isinf(value))):
            return f"{value} src={src}"
        return f"{value:.6g} src={src}"
    return f"{value} src={src}"


def _extract_capture_fingerprint(doc: Dict[str, Any]) -> Optional[str]:
    """Return capture_config.fingerprint or None if absent (legacy/invalid)."""
    cc = doc.get("capture_config")
    if isinstance(cc, dict):
        fp = cc.get("fingerprint")
        if isinstance(fp, str) and fp.strip():
            return fp.strip()
    # Also accept top-level stamp
    fp2 = doc.get("capture_config_fingerprint")
    if isinstance(fp2, str) and fp2.strip():
        return fp2.strip()
    return None


def load_json_reports(paths: Sequence[Path]) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for p in paths:
        with p.open(encoding="utf-8") as f:
            doc = json.load(f)
        res = doc.get("result") or doc
        med = res.get("median_offset_ms")
        if med is None and res.get("pairs"):
            offs = [float(x["offset_ms"]) for x in res["pairs"]]
            med = statistics.median(offs) if offs else None
        if med is None:
            continue
        # first pair timestamp if present (sampling-phase discipline)
        t0 = None
        pairs = res.get("pairs") or []
        if pairs:
            t0 = float(pairs[0].get("t_flash_s", pairs[0].get("t_flash", 0.0)))
        fp = _extract_capture_fingerprint(doc)
        rows.append(
            {
                "session": p.name,
                "offset_ms": float(med),
                "offset_src": PROVENANCE_MEASURED,
                "n_pairs": int(res.get("n_pairs") or len(pairs) or 0),
                "first_pair_t_flash_s": t0,
                "first_pair_t_src": PROVENANCE_MEASURED if t0 is not None else PROVENANCE_NO_DATA,
                "path": str(p),
                "capture_fingerprint": fp,
                "capture_fingerprint_src": PROVENANCE_MEASURED
                if fp is not None
                else PROVENANCE_NO_DATA,
            }
        )
    return rows


def check_capture_fingerprints(rows: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    """HARD FAIL report if JSON-sourced rows mix capture configs.

    - Any missing fingerprint among JSON rows → MIXED_CAPTURE_CONFIG (legacy
      historical dataset is INVALID after wallclock fix; refuse to pool).
    - Two or more distinct fingerprints → MIXED_CAPTURE_CONFIG.
    - Pure --values / CSV without fingerprints: skip (no capture config).
    Returns None if OK to classify.
    """
    json_rows = [r for r in rows if str(r.get("path") or "").endswith(".json")]
    if not json_rows:
        return None

    fps = [r.get("capture_fingerprint") for r in json_rows]
    missing = [r["session"] for r, fp in zip(json_rows, fps) if not fp]
    unique = sorted({fp for fp in fps if fp})
    if missing or len(unique) != 1:
        reason = (
            "missing_capture_config_fingerprint"
            if missing and not unique
            else "missing_or_divergent_capture_config_fingerprint"
            if missing
            else "divergent_capture_config_fingerprint"
        )
        return {
            "verdict": "MIXED_CAPTURE_CONFIG",
            "rc": RC_MIXED_CAPTURE_CONFIG,
            "reason": {"value": reason, "src": PROVENANCE_MEASURED},
            "missing_sessions": {"value": missing, "src": PROVENANCE_MEASURED},
            "fingerprints": {
                "value": unique,
                "src": PROVENANCE_MEASURED if unique else PROVENANCE_NO_DATA,
            },
            "n_json_runs": {"value": len(json_rows), "src": PROVENANCE_MEASURED},
            "note": (
                "Refuse to cluster runs under different capture ffmpeg argv. "
                "Parent: corrected wallclock alignment shifted median ~90 ms; "
                "pooling old+new configs invents false bimodality. "
                "rc=3 is HARD FAIL, never soft-skip 77."
            ),
        }
    return None


def load_csv(path: Path) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    with path.open(newline="", encoding="utf-8") as f:
        r = csv.DictReader(f)
        for i, row in enumerate(r):
            val = row.get("offset_ms") or row.get("median_offset_ms") or row.get("value_ms")
            if val is None or str(val).strip() == "":
                continue
            t_s = row.get("t_s") or row.get("first_pair_t_flash_s") or row.get("wall_s")
            rows.append(
                {
                    "session": str(row.get("session_id") or row.get("session") or i),
                    "offset_ms": float(val),
                    "offset_src": str(row.get("src") or PROVENANCE_CALLER),
                    "n_pairs": int(row["n_pairs"]) if row.get("n_pairs") else None,
                    "first_pair_t_flash_s": float(t_s) if t_s not in (None, "") else None,
                    "first_pair_t_src": PROVENANCE_CALLER
                    if t_s not in (None, "")
                    else PROVENANCE_NO_DATA,
                    "path": str(path),
                }
            )
    return rows


def best_two_means_split(
    values: Sequence[float],
    *,
    min_n: int,
) -> Optional[Dict[str, Any]]:
    """Exhaustive 1-D split on sorted values; both sides >= min_n.

    Returns None if no legal split exists.
    """
    xs = sorted(float(v) for v in values)
    n = len(xs)
    if n < 2 * min_n:
        return None
    best: Optional[Dict[str, Any]] = None
    for k in range(min_n, n - min_n + 1):
        left = xs[:k]
        right = xs[k:]
        m_l = statistics.fmean(left)
        m_r = statistics.fmean(right)
        # within SS
        ss_l = sum((x - m_l) ** 2 for x in left)
        ss_r = sum((x - m_r) ** 2 for x in right)
        ss_w = ss_l + ss_r
        sep = abs(m_r - m_l)
        # prefer max separation; tie-break min within SS
        cand = {
            "k": k,
            "left": left,
            "right": right,
            "mean_lo": min(m_l, m_r),
            "mean_hi": max(m_l, m_r),
            "n_lo": len(left) if m_l <= m_r else len(right),
            "n_hi": len(right) if m_l <= m_r else len(left),
            "vals_lo": left if m_l <= m_r else right,
            "vals_hi": right if m_l <= m_r else left,
            "sep_ms": sep,
            "ss_within": ss_w,
            "std_lo": statistics.pstdev(left if m_l <= m_r else right)
            if len(left if m_l <= m_r else right) > 1
            else 0.0,
            "std_hi": statistics.pstdev(right if m_l <= m_r else left)
            if len(right if m_l <= m_r else left) > 1
            else 0.0,
        }
        # pooled within std
        dof = n - 2
        pooled = math.sqrt(ss_w / dof) if dof > 0 and ss_w >= 0 else 0.0
        cand["pooled_std_ms"] = pooled
        if best is None:
            best = cand
            continue
        # primary: larger separation; secondary: smaller within SS
        if cand["sep_ms"] > best["sep_ms"] + 1e-9:
            best = cand
        elif abs(cand["sep_ms"] - best["sep_ms"]) <= 1e-9 and cand["ss_within"] < best["ss_within"]:
            best = cand
    return best


def classify(
    rows: List[Dict[str, Any]],
    *,
    min_n_per_cluster: int,
    min_n_src: str,
    sep_sigma: float,
    sep_sigma_src: str,
    min_sep_ms: float,
    min_sep_src: str,
) -> Dict[str, Any]:
    values = [float(r["offset_ms"]) for r in rows]
    n = len(values)
    rep: Dict[str, Any] = {
        "n_runs": {"value": n, "src": PROVENANCE_MEASURED},
        "min_n_per_cluster": {"value": min_n_per_cluster, "src": min_n_src},
        "sep_sigma": {"value": sep_sigma, "src": sep_sigma_src},
        "min_sep_ms": {"value": min_sep_ms, "src": min_sep_src},
        "values_ms": {"value": values, "src": PROVENANCE_MEASURED if values else PROVENANCE_NO_DATA},
        "runs": rows,
    }
    if n < 2 * min_n_per_cluster:
        rep["verdict"] = "UNSCORED"
        rep["status"] = "NO-DATA"
        rep["status_src"] = PROVENANCE_NO_DATA
        rep["reason"] = (
            f"n_runs={n} < 2*min_n_per_cluster={2 * min_n_per_cluster} — "
            "refuse to classify (not a pass)"
        )
        rep["rc"] = RC_UNSCORED
        rep["separation_ms"] = {"value": None, "src": PROVENANCE_NO_DATA}
        return rep

    split = best_two_means_split(values, min_n=min_n_per_cluster)
    if split is None:
        rep["verdict"] = "UNSCORED"
        rep["status"] = "NO-DATA"
        rep["status_src"] = PROVENANCE_NO_DATA
        rep["reason"] = "no legal split with min_n per cluster"
        rep["rc"] = RC_UNSCORED
        return rep

    pooled = float(split["pooled_std_ms"])
    sep = float(split["sep_ms"])
    sigma_need = sep_sigma * pooled if pooled > 1e-9 else 0.0
    # BIMODAL if separation clears BOTH absolute floor and sigma gate
    # (when pooled~0, pure two-point masses, absolute floor decides).
    clears_abs = sep >= min_sep_ms
    clears_sigma = (pooled <= 1e-9 and clears_abs) or (sep >= sigma_need and clears_abs)
    is_bimodal = bool(clears_abs and clears_sigma)

    # Assign each run to lo/hi by nearest mean
    m_lo = float(split["mean_lo"])
    m_hi = float(split["mean_hi"])
    assignments: List[Dict[str, Any]] = []
    for r in rows:
        v = float(r["offset_ms"])
        cl = "lo" if abs(v - m_lo) <= abs(v - m_hi) else "hi"
        assignments.append(
            {
                "session": r.get("session"),
                "offset_ms": v,
                "offset_src": r.get("offset_src", PROVENANCE_MEASURED),
                "cluster": cl,
                "first_pair_t_flash_s": r.get("first_pair_t_flash_s"),
                "first_pair_t_src": r.get("first_pair_t_src", PROVENANCE_NO_DATA),
                # index among input runs (sampling-phase: "first" must carry when)
                "run_index": len(assignments),
            }
        )

    n_lo = sum(1 for a in assignments if a["cluster"] == "lo")
    n_hi = sum(1 for a in assignments if a["cluster"] == "hi")
    # Re-check min_n after nearest-mean assignment (can unbalance)
    if n_lo < min_n_per_cluster or n_hi < min_n_per_cluster:
        rep["verdict"] = "UNSCORED"
        rep["status"] = "NO-DATA"
        rep["status_src"] = PROVENANCE_NO_DATA
        rep["reason"] = (
            f"after assignment n_lo={n_lo} n_hi={n_hi} < min_n_per_cluster="
            f"{min_n_per_cluster} — refuse (not a pass)"
        )
        rep["rc"] = RC_UNSCORED
        rep["split_sep_ms"] = {"value": sep, "src": PROVENANCE_MEASURED}
        rep["n_lo"] = {"value": n_lo, "src": PROVENANCE_MEASURED}
        rep["n_hi"] = {"value": n_hi, "src": PROVENANCE_MEASURED}
        rep["assignments"] = assignments
        return rep

    rep["cluster_lo"] = {
        "n": {"value": n_lo, "src": PROVENANCE_MEASURED},
        "mean_ms": {"value": m_lo, "src": PROVENANCE_MEASURED},
        "std_ms": {"value": float(split["std_lo"]), "src": PROVENANCE_MEASURED},
        "min_ms": {"value": min(split["vals_lo"]), "src": PROVENANCE_MEASURED},
        "max_ms": {"value": max(split["vals_lo"]), "src": PROVENANCE_MEASURED},
    }
    rep["cluster_hi"] = {
        "n": {"value": n_hi, "src": PROVENANCE_MEASURED},
        "mean_ms": {"value": m_hi, "src": PROVENANCE_MEASURED},
        "std_ms": {"value": float(split["std_hi"]), "src": PROVENANCE_MEASURED},
        "min_ms": {"value": min(split["vals_hi"]), "src": PROVENANCE_MEASURED},
        "max_ms": {"value": max(split["vals_hi"]), "src": PROVENANCE_MEASURED},
    }
    rep["separation_ms"] = {"value": sep, "src": PROVENANCE_MEASURED}
    rep["pooled_std_ms"] = {"value": pooled, "src": PROVENANCE_MEASURED}
    rep["sigma_need_ms"] = {
        "value": sigma_need,
        "src": PROVENANCE_MEASURED if pooled > 1e-9 else PROVENANCE_NO_DATA,
    }
    rep["clears_abs_floor"] = {"value": clears_abs, "src": PROVENANCE_MEASURED}
    rep["clears_sigma_gate"] = {"value": clears_sigma, "src": PROVENANCE_MEASURED}
    rep["assignments"] = assignments
    # first run in each cluster with its timestamp (never a bare "first" without when)
    for label, key in (("lo", "cluster_lo"), ("hi", "cluster_hi")):
        members = [a for a in assignments if a["cluster"] == label]
        if members:
            # earliest by run_index (input order) — report index + t
            first = members[0]
            rep[key]["first_session"] = {
                "value": first["session"],
                "src": PROVENANCE_MEASURED,
            }
            rep[key]["first_run_index"] = {
                "value": first["run_index"],
                "src": PROVENANCE_MEASURED,
            }
            rep[key]["first_pair_t_flash_s"] = {
                "value": first.get("first_pair_t_flash_s"),
                "src": first.get("first_pair_t_src", PROVENANCE_NO_DATA),
            }
            rep[key]["first_offset_ms"] = {
                "value": first["offset_ms"],
                "src": first.get("offset_src", PROVENANCE_MEASURED),
            }

    if is_bimodal:
        rep["verdict"] = "BIMODAL"
        rep["status"] = "BIMODAL"
        rep["status_src"] = PROVENANCE_MEASURED
        rep["reason"] = (
            f"sep_ms={sep:.3f} >= min_sep_ms={min_sep_ms} and sigma gate; "
            f"n_lo={n_lo} n_hi={n_hi}"
        )
        rep["rc"] = RC_BIMODAL
    else:
        rep["verdict"] = "UNIMODAL"
        rep["status"] = "UNIMODAL"
        rep["status_src"] = PROVENANCE_MEASURED
        rep["reason"] = (
            f"sep_ms={sep:.3f} below floor/sigma (min_sep={min_sep_ms}, "
            f"sigma_need={sigma_need:.3f}); treat as one cluster"
        )
        rep["rc"] = RC_UNIMODAL
        # single-cluster stats
        rep["unimodal_mean_ms"] = {
            "value": statistics.fmean(values),
            "src": PROVENANCE_MEASURED,
        }
        rep["unimodal_std_ms"] = {
            "value": statistics.pstdev(values) if n > 1 else 0.0,
            "src": PROVENANCE_MEASURED,
        }
    return rep


def _print_cell(name: str, cell: Any) -> None:
    if isinstance(cell, dict) and "value" in cell and "src" in cell:
        print(f"{name}={_tag(cell['value'], cell['src'])}")
    else:
        print(f"{name}={cell}")


def print_report(rep: Dict[str, Any]) -> None:
    print("=== avsync_bimodality ===")
    print(
        "note: centres are FITTED from supplied offsets (measured), "
        "never hardcoded from a prior run (ERROR 17)"
    )
    print(f"verdict={rep.get('verdict')} rc={rep.get('rc')}")
    print(f"status={rep.get('status')} src={rep.get('status_src')}")
    print(f"reason={rep.get('reason')}")
    _print_cell("n_runs", rep.get("n_runs"))
    _print_cell("min_n_per_cluster", rep.get("min_n_per_cluster"))
    _print_cell("min_sep_ms", rep.get("min_sep_ms"))
    _print_cell("sep_sigma", rep.get("sep_sigma"))
    _print_cell("separation_ms", rep.get("separation_ms"))
    _print_cell("pooled_std_ms", rep.get("pooled_std_ms"))
    if rep.get("cluster_lo"):
        print("-- cluster_lo --")
        for k, v in rep["cluster_lo"].items():
            _print_cell(f"lo_{k}", v)
    if rep.get("cluster_hi"):
        print("-- cluster_hi --")
        for k, v in rep["cluster_hi"].items():
            _print_cell(f"hi_{k}", v)
    if rep.get("unimodal_mean_ms"):
        _print_cell("unimodal_mean_ms", rep["unimodal_mean_ms"])
        _print_cell("unimodal_std_ms", rep["unimodal_std_ms"])
    print("-- assignments (run_index is input order; first_* carry timestamps) --")
    for a in rep.get("assignments") or []:
        print(
            f"  run_index={a.get('run_index')} session={a.get('session')} "
            f"cluster={a.get('cluster')} offset_ms={a.get('offset_ms')} "
            f"src={a.get('offset_src')} first_pair_t_flash_s={a.get('first_pair_t_flash_s')} "
            f"t_src={a.get('first_pair_t_src')}"
        )


def _self_test() -> int:
    # RED: parent-scale bimodal ~117 ms
    rows = [
        {"session": f"r{i}", "offset_ms": v, "offset_src": PROVENANCE_MEASURED,
         "first_pair_t_flash_s": 1.0 + i, "first_pair_t_src": PROVENANCE_MEASURED}
        for i, v in enumerate([-314.3, -316.0, -197.2, -196.0, -318.0, -197.5, -314.0, -198.1])
    ]
    rep = classify(
        rows,
        min_n_per_cluster=2,
        min_n_src=PROVENANCE_CALLER,
        sep_sigma=3.0,
        sep_sigma_src=PROVENANCE_CALLER,
        min_sep_ms=40.0,
        min_sep_src=PROVENANCE_CALLER,
    )
    assert rep["rc"] == RC_BIMODAL, rep
    assert rep["verdict"] == "BIMODAL", rep
    assert abs(rep["separation_ms"]["value"] - 117.0) < 10.0, rep
    assert rep["rc"] != RC_UNSCORED
    print("SELF_TEST bimodal RED → rc=2 OK")

    # GREEN: tight unimodal
    tight = [
        {"session": f"u{i}", "offset_ms": v, "offset_src": PROVENANCE_MEASURED,
         "first_pair_t_flash_s": float(i), "first_pair_t_src": PROVENANCE_MEASURED}
        for i, v in enumerate([-314.0, -312.5, -315.0, -313.2, -314.8, -313.9])
    ]
    rep = classify(
        tight,
        min_n_per_cluster=2,
        min_n_src=PROVENANCE_CALLER,
        sep_sigma=3.0,
        sep_sigma_src=PROVENANCE_CALLER,
        min_sep_ms=40.0,
        min_sep_src=PROVENANCE_CALLER,
    )
    assert rep["rc"] == RC_UNIMODAL, rep
    assert rep["verdict"] == "UNIMODAL", rep
    print("SELF_TEST unimodal GREEN → rc=0 OK")

    # UNSCORED: n=1
    rep = classify(
        [{"session": "x", "offset_ms": -300.0, "offset_src": PROVENANCE_CALLER}],
        min_n_per_cluster=2,
        min_n_src=PROVENANCE_CALLER,
        sep_sigma=3.0,
        sep_sigma_src=PROVENANCE_CALLER,
        min_sep_ms=40.0,
        min_sep_src=PROVENANCE_CALLER,
    )
    assert rep["rc"] == RC_UNSCORED, rep
    print("SELF_TEST n=1 → UNSCORED rc=77 OK")

    # UNSCORED: 3 points cannot fill 2+2
    rep = classify(
        [
            {"session": "a", "offset_ms": -300.0, "offset_src": PROVENANCE_CALLER},
            {"session": "b", "offset_ms": -200.0, "offset_src": PROVENANCE_CALLER},
            {"session": "c", "offset_ms": -301.0, "offset_src": PROVENANCE_CALLER},
        ],
        min_n_per_cluster=2,
        min_n_src=PROVENANCE_CALLER,
        sep_sigma=3.0,
        sep_sigma_src=PROVENANCE_CALLER,
        min_sep_ms=40.0,
        min_sep_src=PROVENANCE_CALLER,
    )
    assert rep["rc"] == RC_UNSCORED, rep
    print("SELF_TEST n=3 min=2 → UNSCORED rc=77 OK")

    # first_* carry timestamps
    rows2 = [
        {"session": "s0", "offset_ms": -310.0, "offset_src": PROVENANCE_MEASURED,
         "first_pair_t_flash_s": 0.5, "first_pair_t_src": PROVENANCE_MEASURED},
        {"session": "s1", "offset_ms": -200.0, "offset_src": PROVENANCE_MEASURED,
         "first_pair_t_flash_s": 0.6, "first_pair_t_src": PROVENANCE_MEASURED},
        {"session": "s2", "offset_ms": -312.0, "offset_src": PROVENANCE_MEASURED,
         "first_pair_t_flash_s": 0.7, "first_pair_t_src": PROVENANCE_MEASURED},
        {"session": "s3", "offset_ms": -198.0, "offset_src": PROVENANCE_MEASURED,
         "first_pair_t_flash_s": 0.8, "first_pair_t_src": PROVENANCE_MEASURED},
    ]
    rep = classify(
        rows2,
        min_n_per_cluster=2,
        min_n_src=PROVENANCE_CALLER,
        sep_sigma=3.0,
        sep_sigma_src=PROVENANCE_CALLER,
        min_sep_ms=40.0,
        min_sep_src=PROVENANCE_CALLER,
    )
    assert rep["rc"] == RC_BIMODAL, rep
    assert rep["cluster_lo"]["first_pair_t_flash_s"]["value"] is not None, rep
    assert rep["cluster_lo"]["first_run_index"]["value"] == 0, rep
    print("SELF_TEST first_* carries timestamp+index OK")

    # RED: mixed capture fingerprints must HARD FAIL rc=3 (never 77)
    mixed = [
        {
            "session": "old.json",
            "offset_ms": -312.0,
            "offset_src": PROVENANCE_MEASURED,
            "path": "/tmp/old.json",
            "capture_fingerprint": "sha256:aaa",
            "first_pair_t_flash_s": 1.0,
            "first_pair_t_src": PROVENANCE_MEASURED,
        },
        {
            "session": "new.json",
            "offset_ms": -105.0,
            "offset_src": PROVENANCE_MEASURED,
            "path": "/tmp/new.json",
            "capture_fingerprint": "sha256:bbb",
            "first_pair_t_flash_s": 1.0,
            "first_pair_t_src": PROVENANCE_MEASURED,
        },
        {
            "session": "new2.json",
            "offset_ms": -106.0,
            "offset_src": PROVENANCE_MEASURED,
            "path": "/tmp/new2.json",
            "capture_fingerprint": "sha256:bbb",
            "first_pair_t_flash_s": 1.0,
            "first_pair_t_src": PROVENANCE_MEASURED,
        },
        {
            "session": "old2.json",
            "offset_ms": -310.0,
            "offset_src": PROVENANCE_MEASURED,
            "path": "/tmp/old2.json",
            "capture_fingerprint": "sha256:aaa",
            "first_pair_t_flash_s": 1.0,
            "first_pair_t_src": PROVENANCE_MEASURED,
        },
    ]
    gate = check_capture_fingerprints(mixed)
    assert gate is not None and gate["rc"] == RC_MIXED_CAPTURE_CONFIG, gate
    assert gate["rc"] != RC_UNSCORED
    print("SELF_TEST mixed fingerprints → rc=3 HARD FAIL OK")

    # RED: missing fingerprint on JSON (legacy) HARD FAIL
    legacy = [
        {
            "session": "legacy.json",
            "offset_ms": -312.0,
            "offset_src": PROVENANCE_MEASURED,
            "path": "/tmp/legacy.json",
            "capture_fingerprint": None,
        },
        {
            "session": "legacy2.json",
            "offset_ms": -105.0,
            "offset_src": PROVENANCE_MEASURED,
            "path": "/tmp/legacy2.json",
            "capture_fingerprint": None,
        },
    ]
    gate = check_capture_fingerprints(legacy)
    assert gate is not None and gate["rc"] == RC_MIXED_CAPTURE_CONFIG, gate
    print("SELF_TEST missing fingerprints → rc=3 HARD FAIL OK")

    # GREEN: identical fingerprints pass the gate
    same = [
        {
            "session": f"r{i}.json",
            "offset_ms": v,
            "offset_src": PROVENANCE_MEASURED,
            "path": f"/tmp/r{i}.json",
            "capture_fingerprint": "sha256:same",
            "first_pair_t_flash_s": 1.0,
            "first_pair_t_src": PROVENANCE_MEASURED,
        }
        for i, v in enumerate([-105.0, -104.5, -106.0, -105.2])
    ]
    assert check_capture_fingerprints(same) is None
    print("SELF_TEST identical fingerprints → gate open OK")

    # values-only (no JSON path) skips fingerprint gate
    assert check_capture_fingerprints(rows) is None
    print("SELF_TEST values-only skips fingerprint gate OK")

    assert RC_MIXED_CAPTURE_CONFIG == 3 and RC_MIXED_CAPTURE_CONFIG != RC_UNSCORED
    print("SELF_TEST_OK")
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--values", nargs="*", type=float, default=None)
    ap.add_argument("--csv", default=None)
    ap.add_argument("--json", nargs="*", default=None, help="avsync_measure_hdmi report JSONs")
    ap.add_argument("--json-dir", default=None, help="directory of report JSONs")
    ap.add_argument(
        "--min-n-per-cluster",
        type=int,
        default=None,
        help=f"default {DEFAULT_MIN_N_PER_CLUSTER} DEFAULT_ASSUMED (parent pre-reg n>=2)",
    )
    ap.add_argument(
        "--min-sep-ms",
        type=float,
        default=None,
        help=f"absolute separation floor (default {DEFAULT_MIN_SEP_MS} DEFAULT_ASSUMED)",
    )
    ap.add_argument(
        "--sep-sigma",
        type=float,
        default=None,
        help=f"sep >= sigma * pooled_std (default {DEFAULT_SEP_SIGMA} DEFAULT_ASSUMED)",
    )
    ap.add_argument("--json-out", default=None)
    args = ap.parse_args(list(argv) if argv is not None else None)

    if args.self_test:
        return _self_test()

    if args.min_n_per_cluster is None:
        min_n, min_n_src = DEFAULT_MIN_N_PER_CLUSTER, PROVENANCE_DEFAULT_ASSUMED
    else:
        min_n, min_n_src = int(args.min_n_per_cluster), PROVENANCE_CALLER
    if args.min_sep_ms is None:
        min_sep, min_sep_src = DEFAULT_MIN_SEP_MS, PROVENANCE_DEFAULT_ASSUMED
    else:
        min_sep, min_sep_src = float(args.min_sep_ms), PROVENANCE_CALLER
    if args.sep_sigma is None:
        sep_sig, sep_sig_src = DEFAULT_SEP_SIGMA, PROVENANCE_DEFAULT_ASSUMED
    else:
        sep_sig, sep_sig_src = float(args.sep_sigma), PROVENANCE_CALLER

    rows: List[Dict[str, Any]] = []
    try:
        if args.values is not None:
            for i, v in enumerate(args.values):
                rows.append(
                    {
                        "session": f"value_{i}",
                        "offset_ms": float(v),
                        "offset_src": PROVENANCE_CALLER,
                        "first_pair_t_flash_s": None,
                        "first_pair_t_src": PROVENANCE_NO_DATA,
                        "run_index": i,
                    }
                )
        if args.csv:
            rows.extend(load_csv(Path(args.csv)))
        json_paths: List[Path] = []
        if args.json:
            json_paths.extend(Path(p) for p in args.json)
        if args.json_dir:
            d = Path(args.json_dir)
            json_paths.extend(sorted(d.glob("*.json")))
        if json_paths:
            rows.extend(load_json_reports(json_paths))
    except (OSError, ValueError, json.JSONDecodeError, KeyError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return RC_USAGE

    if not rows:
        print(
            "ERROR: provide --values / --csv / --json / --json-dir (or --self-test)",
            file=sys.stderr,
        )
        return RC_USAGE

    # Capture-config fingerprint gate BEFORE classify — never invent bimodality
    # from a tool change (parent: ~90 ms absolute shift after wallclock fix).
    gate = check_capture_fingerprints(rows)
    if gate is not None:
        print(f"VERDICT={gate['verdict']} rc={gate['rc']}")
        print(f"reason={gate['reason']['value']} src={gate['reason']['src']}")
        if gate.get("missing_sessions"):
            print(f"missing_sessions={gate['missing_sessions']['value']} src=measured")
        print(f"fingerprints={gate['fingerprints']['value']} src={gate['fingerprints']['src']}")
        print(f"note={gate.get('note')}")
        if args.json_out:
            Path(args.json_out).write_text(json.dumps(gate, indent=2, default=str) + "\n")
            print(f"json_out={args.json_out} src=measured")
        return int(gate["rc"])

    rep = classify(
        rows,
        min_n_per_cluster=min_n,
        min_n_src=min_n_src,
        sep_sigma=sep_sig,
        sep_sigma_src=sep_sig_src,
        min_sep_ms=min_sep,
        min_sep_src=min_sep_src,
    )
    # Surface the shared fingerprint when present
    fps = sorted(
        {
            r.get("capture_fingerprint")
            for r in rows
            if r.get("capture_fingerprint")
        }
    )
    if fps:
        print(f"capture_config_fingerprint={fps[0]} src=measured n_unique={len(fps)}")
    print_report(rep)
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(rep, indent=2, default=str) + "\n")
        print(f"json_out={args.json_out} src=measured")
    return int(rep["rc"])


if __name__ == "__main__":
    sys.exit(main())
