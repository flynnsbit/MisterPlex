#!/usr/bin/env python3
"""Classify multi-capture median spread: SESSION-STABLE vs CAPTURE-RACE-SUSPECT.

Compares within-session (or within-series) median spread to an optional
between-group separation the *caller* supplies. Does not assert device defect.

RETRACTION (2026-08-01): The prior canonical self-test used OLD-argv medians
(-293.33/-296/-292.67) and between_cluster_sep=116.89 as "DEVICE CONFIRMED".
That separation was an instrument artifact (no wallclock/copyts). Self-test now
uses synthetic numbers only and never claims device confirmation.

Exit codes
----------
  0   SESSION_STABLE — within spread ≤ max_within_ms (and sep clears min_sep if given)
  2   CAPTURE_RACE_SUSPECT — within spread > max_within_ms
  77  UNSCORED — too few captures / missing numbers (never a pass)
  1   usage

Thresholds (override with flags; defaults DEFAULT_ASSUMED):
  --max-within-ms 30
  --min-sep-ms 80        only if --between-cluster-sep-ms is set
  --min-captures 3

Every value tagged measured | caller_supplied | DEFAULT_ASSUMED | NO-DATA.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

RC_STABLE = 0
RC_USAGE = 1
RC_RACE = 2
RC_UNSCORED = 77

PROVENANCE_MEASURED = "measured"
PROVENANCE_CALLER = "caller_supplied"
PROVENANCE_DEFAULT_ASSUMED = "DEFAULT_ASSUMED"
PROVENANCE_NO_DATA = "NO-DATA"

DEFAULT_MAX_WITHIN_MS = 30.0  # parent pre-reg
DEFAULT_MIN_SEP_MS = 80.0  # below cluster sep but above noise
DEFAULT_MIN_CAPTURES = 3


def _tag(v: Any, src: str) -> str:
    return f"{v} src={src}"


def load_medians_from_json(paths: Sequence[Path]) -> List[Dict[str, Any]]:
    rows = []
    for p in paths:
        doc = json.loads(p.read_text(encoding="utf-8"))
        res = doc.get("result") or doc
        med = res.get("median_offset_ms")
        if med is None and res.get("pairs"):
            offs = [float(x["offset_ms"]) for x in res["pairs"]]
            med = statistics.median(offs) if offs else None
        if med is None:
            continue
        fp = res.get("first_pair_offset_ms")
        rows.append(
            {
                "path": str(p),
                "name": p.name,
                "median_ms": float(med),
                "median_src": PROVENANCE_MEASURED,
                "first_pair_ms": float(fp) if fp is not None else None,
                "n_pairs": int(res.get("n_pairs") or len(res.get("pairs") or [])),
            }
        )
    return rows


def classify(
    medians: List[float],
    *,
    max_within_ms: float,
    max_within_src: str,
    min_sep_ms: float,
    min_sep_src: str,
    min_captures: int,
    min_captures_src: str,
    between_cluster_sep_ms: Optional[float],
    between_src: str,
) -> Dict[str, Any]:
    n = len(medians)
    rep: Dict[str, Any] = {
        "n_captures": {"value": n, "src": PROVENANCE_MEASURED},
        "min_captures": {"value": min_captures, "src": min_captures_src},
        "max_within_ms": {"value": max_within_ms, "src": max_within_src},
        "min_sep_ms_context": {"value": min_sep_ms, "src": min_sep_src},
        "medians_ms": {"value": medians, "src": PROVENANCE_MEASURED if medians else PROVENANCE_NO_DATA},
    }
    if n < min_captures:
        rep["verdict"] = "UNSCORED"
        rep["rc"] = RC_UNSCORED
        rep["reason"] = f"n_captures={n} < min_captures={min_captures}"
        rep["within_spread_ms"] = {"value": None, "src": PROVENANCE_NO_DATA}
        return rep

    lo, hi = min(medians), max(medians)
    spread = hi - lo
    rep["within_min_ms"] = {"value": lo, "src": PROVENANCE_MEASURED}
    rep["within_max_ms"] = {"value": hi, "src": PROVENANCE_MEASURED}
    rep["within_spread_ms"] = {"value": spread, "src": PROVENANCE_MEASURED}
    rep["within_mean_ms"] = {"value": statistics.fmean(medians), "src": PROVENANCE_MEASURED}

    if between_cluster_sep_ms is not None:
        rep["between_cluster_sep_ms"] = {
            "value": float(between_cluster_sep_ms),
            "src": between_src,
        }
        ratio = (
            float(between_cluster_sep_ms) / spread if spread > 1e-9 else float("inf")
        )
        rep["sep_over_within_ratio"] = {"value": ratio, "src": PROVENANCE_MEASURED}
    else:
        rep["between_cluster_sep_ms"] = {"value": None, "src": PROVENANCE_NO_DATA}
        rep["sep_over_within_ratio"] = {"value": None, "src": PROVENANCE_NO_DATA}

    # Decision (parent pre-reg): spread < max_within → SESSION_STABLE
    if spread <= max_within_ms:
        # If between-sep provided, require it clears min_sep (else weak claim)
        if between_cluster_sep_ms is not None and between_cluster_sep_ms < min_sep_ms:
            rep["verdict"] = "UNSCORED"
            rep["rc"] = RC_UNSCORED
            rep["reason"] = (
                f"within_spread={spread:.3f}<={max_within_ms} but "
                f"between_sep={between_cluster_sep_ms:.3f}<min_sep={min_sep_ms} "
                "— cannot claim latch vs noise"
            )
            return rep
        rep["verdict"] = "SESSION_STABLE"
        rep["rc"] = RC_STABLE
        rep["reason"] = (
            f"within_spread_ms={spread:.3f} <= max_within_ms={max_within_ms} "
            f"(spread within max_within_ms; not a device-defect claim)"
        )
        return rep

    rep["verdict"] = "CAPTURE_RACE_SUSPECT"
    rep["rc"] = RC_RACE
    rep["reason"] = (
        f"within_spread_ms={spread:.3f} > max_within_ms={max_within_ms} "
        "— capture-to-capture alignment may dominate"
    )
    return rep


def print_rep(rep: Dict[str, Any], rows: List[Dict[str, Any]]) -> None:
    print("=== avsync_session_latch ===")
    print(
        "pre_register: within_spread < max_within_ms ⇒ SESSION_STABLE "
        "(spread ≤ max_within; optional between-sep is caller_supplied only)"
    )
    print(f"verdict={rep.get('verdict')} rc={rep.get('rc')}")
    print(f"reason={rep.get('reason')}")
    for k in (
        "n_captures",
        "min_captures",
        "max_within_ms",
        "within_spread_ms",
        "within_min_ms",
        "within_max_ms",
        "within_mean_ms",
        "between_cluster_sep_ms",
        "sep_over_within_ratio",
    ):
        cell = rep.get(k)
        if isinstance(cell, dict) and "value" in cell:
            print(f"{k}={_tag(cell['value'], cell['src'])}")
    print("captures:")
    for r in rows:
        print(
            f"  {r.get('name')} median_ms={r.get('median_ms')} "
            f"src={r.get('median_src')} first_pair_ms={r.get('first_pair_ms')} "
            f"n_pairs={r.get('n_pairs')}"
        )


def _self_test() -> int:
    # Synthetic: tight within-spread, large caller_supplied between-sep.
    # Numbers are fixtures for the classifier, NOT lab device claims.
    meds = [-110.0, -112.0, -109.0]
    rep = classify(
        meds,
        max_within_ms=30.0,
        max_within_src=PROVENANCE_CALLER,
        min_sep_ms=80.0,
        min_sep_src=PROVENANCE_CALLER,
        min_captures=3,
        min_captures_src=PROVENANCE_CALLER,
        between_cluster_sep_ms=100.0,
        between_src=PROVENANCE_CALLER,
    )
    assert rep["rc"] == RC_STABLE, rep
    assert abs(rep["within_spread_ms"]["value"] - 3.0) < 0.01, rep
    assert rep["verdict"] == "SESSION_STABLE", rep
    print("SELF_TEST synthetic SESSION_STABLE rc=0 OK")

    # Capture race scale: spread > max_within
    rep = classify(
        [-110.0, -40.0, -100.0],
        max_within_ms=30.0,
        max_within_src=PROVENANCE_CALLER,
        min_sep_ms=80.0,
        min_sep_src=PROVENANCE_CALLER,
        min_captures=3,
        min_captures_src=PROVENANCE_CALLER,
        between_cluster_sep_ms=100.0,
        between_src=PROVENANCE_CALLER,
    )
    assert rep["rc"] == RC_RACE, rep
    print("SELF_TEST race-scale CAPTURE_RACE_SUSPECT rc=2 OK")

    rep = classify(
        [-300.0],
        max_within_ms=30.0,
        max_within_src=PROVENANCE_CALLER,
        min_sep_ms=80.0,
        min_sep_src=PROVENANCE_CALLER,
        min_captures=3,
        min_captures_src=PROVENANCE_CALLER,
        between_cluster_sep_ms=None,
        between_src=PROVENANCE_NO_DATA,
    )
    assert rep["rc"] == RC_UNSCORED, rep
    print("SELF_TEST n=1 UNSCORED rc=77 OK")
    print("SELF_TEST_OK")
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--values", nargs="*", type=float, default=None)
    ap.add_argument("--json", nargs="*", default=None)
    ap.add_argument("--json-dir", default=None)
    ap.add_argument(
        "--between-cluster-sep-ms",
        type=float,
        default=None,
        help="caller-supplied between-cluster separation for ratio print",
    )
    ap.add_argument("--max-within-ms", type=float, default=None)
    ap.add_argument("--min-sep-ms", type=float, default=None)
    ap.add_argument("--min-captures", type=int, default=None)
    ap.add_argument("--json-out", default=None)
    args = ap.parse_args(list(argv) if argv is not None else None)

    if args.self_test:
        return _self_test()

    def pick(val, default):
        if val is None:
            return default, PROVENANCE_DEFAULT_ASSUMED
        return val, PROVENANCE_CALLER

    max_w, max_w_src = pick(args.max_within_ms, DEFAULT_MAX_WITHIN_MS)
    min_sep, min_sep_src = pick(args.min_sep_ms, DEFAULT_MIN_SEP_MS)
    min_cap, min_cap_src = pick(args.min_captures, DEFAULT_MIN_CAPTURES)

    rows: List[Dict[str, Any]] = []
    medians: List[float] = []
    if args.values is not None:
        for i, v in enumerate(args.values):
            rows.append(
                {
                    "name": f"value_{i}",
                    "median_ms": float(v),
                    "median_src": PROVENANCE_CALLER,
                    "first_pair_ms": None,
                    "n_pairs": None,
                }
            )
            medians.append(float(v))
    paths: List[Path] = []
    if args.json:
        paths.extend(Path(p) for p in args.json)
    if args.json_dir:
        paths.extend(sorted(Path(args.json_dir).glob("*.json")))
    if paths:
        loaded = load_medians_from_json(paths)
        rows.extend(loaded)
        medians.extend(r["median_ms"] for r in loaded)

    if not medians:
        print("ERROR: provide --values / --json / --json-dir", file=sys.stderr)
        return RC_USAGE

    if args.between_cluster_sep_ms is None:
        bsep, bsrc = None, PROVENANCE_NO_DATA
    else:
        bsep, bsrc = float(args.between_cluster_sep_ms), PROVENANCE_CALLER

    rep = classify(
        medians,
        max_within_ms=float(max_w),
        max_within_src=max_w_src,
        min_sep_ms=float(min_sep),
        min_sep_src=min_sep_src,
        min_captures=int(min_cap),
        min_captures_src=min_cap_src,
        between_cluster_sep_ms=bsep,
        between_src=bsrc,
    )
    print_rep(rep, rows)
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(rep, indent=2) + "\n")
    return int(rep["rc"])


if __name__ == "__main__":
    sys.exit(main())
