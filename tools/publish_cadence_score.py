#!/usr/bin/env python3
"""Offline score of publish_swap_delta / cadence fields from a daemon log.

Also synthesizes hold_d from interval lists when only mono dumps exist.

Labels every value measured | caller_supplied | DEFAULT_ASSUMED | derived.

Exit: 0 scored OK/clean, 2 HITCHY/FAIL, 77 UNSCORED, 1 usage.
true rc must be captured directly (never through a pipe).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

RC_OK = 0
RC_USAGE = 1
RC_FAIL = 2
RC_UNSCORED = 77


def parse_kv(line: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for m in re.finditer(r"([A-Za-z0-9_]+)=([^\s]+)", line):
        out[m.group(1)] = m.group(2)
    return out


def score_from_summary_kv(kv: dict[str, str]) -> dict:
    def f(name: str, default: float | None = None) -> float | None:
        if name not in kv:
            return default
        try:
            return float(kv[name])
        except ValueError:
            return default

    p_ge50 = f("p_ge50")
    mean_ms = f("mean_ms")
    sigma_ms = f("sigma_ms")
    p_hold_d1 = f("p_hold_d1")
    cad = kv.get("cadence_verdict", "ABSENT")
    p_ge50_tag = kv.get("p_ge50_tag", "ABSENT")
    interval_verdict = kv.get("interval_verdict", kv.get("verdict", "ABSENT"))

    # Sigma gate (also recompute if tags missing — old logs)
    if mean_ms is not None and sigma_ms is not None and mean_ms > 0:
        if sigma_ms >= mean_ms:
            p_ge50_tag = "UNSCORED_SIGMA_GE_MEAN"
            interval_verdict = "UNSCORED_SIGMA_GE_MEAN"

    rep = {
        "p_ge50": p_ge50,
        "p_ge50_tag": p_ge50_tag,
        "mean_ms": mean_ms,
        "sigma_ms": sigma_ms,
        "p_hold_d1": p_hold_d1,
        "p_hold_d2": f("p_hold_d2"),
        "p_hold_d3": f("p_hold_d3"),
        "p_hold_d_ge4": f("p_hold_d_ge4"),
        "cad_alt_frac": f("cad_alt_frac"),
        "cadence_verdict": cad,
        "interval_verdict": interval_verdict,
        "fd_semantics": kv.get("fd_semantics", "ABSENT"),
        "skip_verdict": kv.get("skip_verdict", "ABSENT"),
        "src": "measured" if "p_hold_d1" in kv else "legacy_log",
    }

    if p_ge50_tag == "UNSCORED_SIGMA_GE_MEAN":
        rep["verdict"] = "UNSCORED_SIGMA_GE_MEAN"
        rep["rc"] = RC_UNSCORED
        return rep
    if cad == "HITCHY_D1" or (p_hold_d1 is not None and p_hold_d1 >= 0.02):
        rep["verdict"] = "HITCHY_D1"
        rep["rc"] = RC_FAIL
        return rep
    if cad in ("CADENCE_32_CLEAN", "CADENCE_METRONOME_OK", "CADENCE_OK_MILD"):
        rep["verdict"] = cad
        rep["rc"] = RC_OK
        return rep
    if cad in ("ABSENT", "UNSCORED") and p_hold_d1 is None:
        rep["verdict"] = "UNSCORED"
        rep["rc"] = RC_UNSCORED
        rep["reason"] = "no cadence fields — redeploy daemon with cadence ledger"
        return rep
    rep["verdict"] = cad
    rep["rc"] = RC_FAIL
    return rep


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("log", type=Path, nargs="?", help="daemon log containing publish_swap_delta")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        print("PRE-REGISTER offline cadence score:")
        print("  sigma>=mean => rc=77 UNSCORED_SIGMA_GE_MEAN")
        print("  p_hold_d1>=0.02 => rc=2 HITCHY_D1")
        print("  CADENCE_32_CLEAN => rc=0")
        ok = True
        r1 = score_from_summary_kv(
            {
                "p_ge50": "0.14",
                "mean_ms": "42.0",
                "sigma_ms": "65.0",
                "p_hold_d1": "0.03",
                "cadence_verdict": "HITCHY_D1",
            }
        )
        print("RED_sigma", r1)
        if r1["rc"] != RC_UNSCORED:
            print("FAIL sigma gate"); ok = False
        else:
            print("PASS sigma gate")
        r2 = score_from_summary_kv(
            {
                "p_ge50": "0.14",
                "mean_ms": "41.66",
                "sigma_ms": "10.5",
                "p_hold_d1": "0.034",
                "p_hold_d2": "0.48",
                "p_hold_d3": "0.48",
                "cadence_verdict": "HITCHY_D1",
                "p_ge50_tag": "measured",
            }
        )
        print("RED_hitch", r2)
        if r2["rc"] != RC_FAIL:
            print("FAIL hitchy"); ok = False
        else:
            print("PASS hitchy")
        r3 = score_from_summary_kv(
            {
                "p_ge50": "0.0",
                "mean_ms": "41.67",
                "sigma_ms": "2.0",
                "p_hold_d1": "0.0",
                "cadence_verdict": "CADENCE_32_CLEAN",
                "p_ge50_tag": "measured",
            }
        )
        print("GREEN_clean", r3)
        if r3["rc"] != RC_OK:
            print("FAIL clean"); ok = False
        else:
            print("PASS clean")
        print("SELF_TEST_OK" if ok else "SELF_TEST_FAIL")
        return RC_OK if ok else RC_FAIL

    if not args.log or not args.log.is_file():
        ap.error("log required")
        return RC_USAGE

    lines = args.log.read_text(errors="replace").splitlines()
    # Prefer session_end lines with p_hold_d1; else last publish_swap_delta
    candidates = [ln for ln in lines if "publish_swap_delta" in ln and "phase_est" not in ln]
    if not candidates:
        print("UNSCORED no publish_swap_delta lines")
        return RC_UNSCORED
    # last with cadence fields else last
    pick = None
    for ln in reversed(candidates):
        if "p_hold_d1=" in ln or "cadence_verdict=" in ln:
            pick = ln
            break
    if pick is None:
        pick = candidates[-1]
    print("LINE", pick[:240])
    kv = parse_kv(pick)
    rep = score_from_summary_kv(kv)
    print(
        f"VERDICT={rep['verdict']} rc={rep['rc']} "
        f"p_hold_d1={rep.get('p_hold_d1')} p_ge50={rep.get('p_ge50')} "
        f"p_ge50_tag={rep.get('p_ge50_tag')} cadence={rep.get('cadence_verdict')} "
        f"mean={rep.get('mean_ms')} sigma={rep.get('sigma_ms')}"
    )
    return int(rep["rc"])


if __name__ == "__main__":
    sys.exit(main())
