#!/usr/bin/env python3
"""Attribute residual A/V offset spread: video quantisation vs daemon fields.

Host-only. Reads parent-captured avsync JSON + optional sixfield rec*.txt.
Does NOT touch the device.

Context (parent 2026-08-01):
  - 117 ms bimodality = INSTRUMENT ARTIFACT (OLD ffmpeg argv, no wallclock/copyts).
  - NEW argv (wallclock both + copyts + start_at_zero): n=16, range 25.00 ms.
  - flash_onset_n_interp=0 on essentially all flashes → video onset = capture frame
    grid (quant T = capture_frame_period_ms, typically ~33.3 ms @ 30 fps).
  - beep hop ~2 ms.

Pre-registered before measuring (this file's self-check documents the math;
live numbers come only from JSON/rec files you pass):

  H-QUANT: between-run range of medians ≤ capture_frame_quant_ms (one frame).
           Expected range for n i.i.d. Uniform[0,T] ≈ T*(n-1)/(n+1).
           If observed_range ≤ T and ≈ E[range], quantisation ALONE accounts
           for the residual → instrument floor is ~T; no A/V claim below T
           until ramped-flash (or sub-frame onset) lands.

  H-FIELD: some sixfield daemon field correlates with median_offset
           (|Spearman| > 0.5 and not constant). Else NULL — all fields
           identical or uncorrelated.

Exit:
  0  = analysis completed (quant accounts OR fields differ with numbers printed)
  2  = analysis completed and H-QUANT rejected (range >> T) without field explanation
  77 = could-not-measure (no JSON / missing fields)
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

RC_OK = 0
RC_REJECT = 2
RC_UNSCORED = 77

REC_FIELDS = [
    "plxa_used",
    "plxd_liveness_proven",
    "published_bank",
    "free_bank_mask",
    "disp_bank",
    "swap_pending",
    "frames_done",
    "av_hold_count",
    "av_hold_wait_us",
    "audio_queued_first_ge0_since_origin_ms",
    "ddr_total_us",
    "ddr_copy_us",
    "ddr_doorbell_us",
    "ddr_plxa_poll_us",
]


@dataclass
class RunJson:
    path: str
    median_ms: Optional[float] = None
    stdev_ms: Optional[float] = None
    n_pairs: int = 0
    n_interp: Optional[int] = None
    n_step: Optional[int] = None
    n_flashes: Optional[int] = None
    quant_ms: Optional[float] = None
    period_ms: Optional[float] = None
    hop_ms: Optional[float] = None
    fps_nom: Optional[float] = None
    first_pair_ms: Optional[float] = None
    early_minus_late_ms: Optional[float] = None
    capture_fp: Optional[str] = None
    pairs: List[float] = field(default_factory=list)
    tag: str = ""


def load_run(path: Path) -> RunJson:
    d = json.loads(path.read_text(encoding="utf-8"))
    r = d.get("result") or {}
    fm = r.get("flash_meta") or {}
    bm = r.get("beep_meta") or {}
    cc = d.get("capture_config") or {}
    fp = None
    if isinstance(cc, dict):
        fp = cc.get("fingerprint") or cc.get("sha256")
    # fingerprint sometimes only in log; JSON may nest differently
    if fp is None and isinstance(d.get("capture_config_fingerprint"), str):
        fp = d["capture_config_fingerprint"]
    pairs = []
    for p in r.get("pairs") or []:
        if isinstance(p, dict) and "offset_ms" in p:
            pairs.append(float(p["offset_ms"]))
    med = r.get("median_offset_ms")
    return RunJson(
        path=str(path),
        median_ms=float(med) if med is not None else None,
        stdev_ms=float(r["stdev_offset_ms"]) if r.get("stdev_offset_ms") is not None else None,
        n_pairs=int(r.get("n_pairs") or 0),
        n_interp=int(fm["flash_onset_n_interp"]) if fm.get("flash_onset_n_interp") is not None else None,
        n_step=int(fm["flash_onset_n_step"]) if fm.get("flash_onset_n_step") is not None else None,
        n_flashes=int(fm["n_flashes"]) if fm.get("n_flashes") is not None else None,
        quant_ms=(
            float(fm["capture_frame_quant_ms_no_interp"])
            if fm.get("capture_frame_quant_ms_no_interp") is not None
            else None
        ),
        period_ms=(
            float(fm["capture_frame_period_ms"])
            if fm.get("capture_frame_period_ms") is not None
            else None
        ),
        hop_ms=float(bm["hop_ms"]) if bm.get("hop_ms") is not None else None,
        fps_nom=float(fm["fps_nom"]) if fm.get("fps_nom") is not None else None,
        first_pair_ms=(
            float(r["first_pair_offset_ms"]) if r.get("first_pair_offset_ms") is not None else None
        ),
        early_minus_late_ms=(
            float(r["early_minus_late_ms"]) if r.get("early_minus_late_ms") is not None else None
        ),
        capture_fp=str(fp) if fp else None,
        pairs=pairs,
        tag=path.stem,
    )


def parse_rec(path: Path) -> Dict[str, Any]:
    text = path.read_text(encoding="utf-8", errors="replace")
    out: Dict[str, Any] = {"path": str(path), "raw": text.strip()}
    for key in REC_FIELDS:
        m = re.search(rf"\b{re.escape(key)}=(\S+)", text)
        if not m:
            out[key] = None
            continue
        s = m.group(1)
        try:
            if "." in s:
                out[key] = float(s)
            else:
                out[key] = int(s)
        except ValueError:
            out[key] = s
    return out


def spearman(xs: List[float], ys: List[float]) -> Optional[float]:
    n = len(xs)
    if n < 3 or n != len(ys):
        return None
    def ranks(a: List[float]) -> List[float]:
        order = sorted(range(n), key=lambda i: a[i])
        r = [0.0] * n
        i = 0
        while i < n:
            j = i
            while j + 1 < n and a[order[j + 1]] == a[order[i]]:
                j += 1
            avg = (i + j) / 2.0 + 1.0
            for k in range(i, j + 1):
                r[order[k]] = avg
            i = j + 1
        return r
    rx, ry = ranks(xs), ranks(ys)
    mx, my = sum(rx) / n, sum(ry) / n
    num = sum((rx[i] - mx) * (ry[i] - my) for i in range(n))
    dx = math.sqrt(sum((rx[i] - mx) ** 2 for i in range(n)))
    dy = math.sqrt(sum((ry[i] - my) ** 2 for i in range(n)))
    if dx == 0 or dy == 0:
        return 0.0  # constant series → no correlation possible
    return num / (dx * dy)


def expected_uniform_range(T: float, n: int) -> float:
    """E[max-min] for n i.i.d. Uniform[0, T] = T * (n-1)/(n+1)."""
    if n < 2:
        return float("nan")
    return T * (n - 1) / (n + 1)


def analyze_quant(runs: List[RunJson]) -> Dict[str, Any]:
    meds = [r.median_ms for r in runs if r.median_ms is not None]
    out: Dict[str, Any] = {
        "n_runs": len(meds),
        "n_runs_src": "measured",
    }
    if len(meds) < 2:
        out["status"] = "could-not-measure"
        out["rc"] = RC_UNSCORED
        return out

    meds_s = sorted(meds)
    rng = meds_s[-1] - meds_s[0]
    out["median_ms_list"] = meds_s
    out["between_run_range_ms"] = rng
    out["between_run_range_ms_src"] = "measured"
    out["between_run_stdev_ms"] = statistics.pstdev(meds) if len(meds) > 1 else 0.0
    out["between_run_stdev_ms_src"] = "measured"
    out["between_run_mean_ms"] = statistics.mean(meds)
    out["between_run_mean_ms_src"] = "measured"

    quants = [r.quant_ms for r in runs if r.quant_ms is not None]
    periods = [r.period_ms for r in runs if r.period_ms is not None]
    T = None
    if quants:
        T = statistics.median(quants)
        out["capture_frame_quant_ms"] = T
        out["capture_frame_quant_ms_src"] = "measured"
    elif periods:
        T = statistics.median(periods)
        out["capture_frame_quant_ms"] = T
        out["capture_frame_quant_ms_src"] = "measured_period"
    else:
        out["capture_frame_quant_ms"] = None
        out["capture_frame_quant_ms_src"] = "could-not-measure"

    n_interp = sum(r.n_interp or 0 for r in runs)
    n_step = sum(r.n_step or 0 for r in runs)
    n_flash = sum(r.n_flashes or 0 for r in runs)
    out["flash_onset_n_interp_total"] = n_interp
    out["flash_onset_n_step_total"] = n_step
    out["flash_onset_n_flashes_total"] = n_flash
    out["flash_onset_counts_src"] = "measured"

    hops = [r.hop_ms for r in runs if r.hop_ms is not None]
    if hops:
        out["beep_hop_ms"] = statistics.median(hops)
        out["beep_hop_ms_src"] = "measured"

    within = [r.stdev_ms for r in runs if r.stdev_ms is not None]
    if within:
        out["within_run_stdev_ms_median"] = statistics.median(within)
        out["within_run_stdev_ms_median_src"] = "measured"
        # Uniform[0,T] has stdev T/sqrt(12)
        if T:
            out["uniform_0_T_stdev_ms"] = T / math.sqrt(12.0)
            out["uniform_0_T_stdev_ms_src"] = "derived_from_measured_T"

    if T is None:
        out["H_QUANT"] = {"verdict": "UNSCORED", "verdict_src": "could-not-measure"}
        out["rc"] = RC_UNSCORED
        out["status"] = "could-not-measure"
        return out

    n = len(meds)
    e_range = expected_uniform_range(T, n)
    out["expected_uniform_range_ms"] = e_range
    out["expected_uniform_range_ms_src"] = "derived_E_max_min_Uniform_0_T"
    out["range_over_T"] = rng / T if T else None
    out["range_over_T_src"] = "measured/derived"

    # Session-constant phase bias model: each run median ≈ φ_run + ε
    # φ_run ~ approx Uniform on an interval of length T (first-hot-frame error).
    # Support H-QUANT if observed range ≤ T (hard ceiling) AND range is not
    # wildly larger than E[range] (allow 1.25× for finite-n luck).
    hard_ok = rng <= T + 1e-9
    soft_ok = rng <= e_range * 1.25 + 1e-9
    # Also: if ALL flashes are step (n_interp==0), quantisation is fully engaged.
    all_step = n_flash > 0 and n_interp == 0

    out["all_flashes_step_no_interp"] = all_step
    out["all_flashes_step_no_interp_src"] = "measured"

    if hard_ok and all_step:
        out["H_QUANT"] = {
            "verdict": "SUPPORTED",
            "verdict_src": "measured",
            "detail": (
                f"between_run_range_ms={rng:.4f} ≤ T={T:.4f}; "
                f"E[range|U(0,T),n={n}]={e_range:.4f}; "
                f"flash_onset_n_interp=0/{n_flash}"
            ),
        }
        out["instrument_floor_ms"] = T
        out["instrument_floor_ms_src"] = "measured_capture_frame_quant"
        out["consequence"] = (
            f"This instrument cannot resolve A/V error smaller than ~{T:.2f} ms "
            f"(one capture frame) while flash onset is step-quantised "
            f"(n_interp=0). No A/V claim below that threshold until ramped-flash "
            f"or sub-frame onset lands."
        )
        out["rc"] = RC_OK
        out["status"] = "quant_accounts_for_residual"
    elif not hard_ok:
        out["H_QUANT"] = {
            "verdict": "REJECTED",
            "verdict_src": "measured",
            "detail": f"between_run_range_ms={rng:.4f} > T={T:.4f}",
        }
        out["instrument_floor_ms"] = T
        out["instrument_floor_ms_src"] = "measured_capture_frame_quant"
        out["consequence"] = (
            f"Quantisation alone (T={T:.2f} ms) does NOT cover observed range "
            f"{rng:.2f} ms. Residual beyond one frame remains unexplained by "
            f"video grid alone."
        )
        out["rc"] = RC_REJECT
        out["status"] = "quant_insufficient"
    else:
        # hard_ok but some interp or range >> E[range]
        out["H_QUANT"] = {
            "verdict": "INCONCLUSIVE",
            "verdict_src": "measured",
            "detail": (
                f"range={rng:.4f} ≤ T={T:.4f} but soft_ok={soft_ok} "
                f"all_step={all_step} E[range]={e_range:.4f}"
            ),
        }
        out["instrument_floor_ms"] = T
        out["instrument_floor_ms_src"] = "measured_capture_frame_quant"
        out["consequence"] = (
            f"Range fits in one frame quant T={T:.2f} ms but conditions for a "
            f"hard SUPPORT are incomplete (interp or E[range] mismatch)."
        )
        out["rc"] = RC_OK
        out["status"] = "quant_plausible"
    return out


def analyze_fields(
    pairs: List[Tuple[RunJson, Dict[str, Any]]],
) -> Dict[str, Any]:
    out: Dict[str, Any] = {"n_paired": len(pairs), "n_paired_src": "measured"}
    if len(pairs) < 2:
        out["status"] = "could-not-measure"
        out["rc"] = RC_UNSCORED
        out["H_FIELD"] = {"verdict": "UNSCORED", "verdict_src": "could-not-measure"}
        return out

    meds = [p[0].median_ms for p in pairs]
    if any(m is None for m in meds):
        out["status"] = "could-not-measure"
        out["rc"] = RC_UNSCORED
        out["H_FIELD"] = {"verdict": "UNSCORED", "verdict_src": "could-not-measure"}
        return out
    meds_f = [float(m) for m in meds]  # type: ignore[arg-type]

    field_report = []
    any_varies = False
    any_corr = False
    for key in REC_FIELDS:
        vals = [p[1].get(key) for p in pairs]
        if all(v is None for v in vals):
            field_report.append(
                {
                    "field": key,
                    "status": "absent",
                    "unique": [],
                    "spearman": None,
                    "spearman_src": "could-not-measure",
                }
            )
            continue
        # numeric only for correlation
        num_pairs = [
            (meds_f[i], float(vals[i]))
            for i in range(len(vals))
            if isinstance(vals[i], (int, float))
        ]
        uniq = sorted({v for v in vals if v is not None}, key=lambda x: str(x))
        varies = len(uniq) > 1
        if varies:
            any_varies = True
        sp = None
        if varies and len(num_pairs) >= 3:
            sp = spearman([a for a, _ in num_pairs], [b for _, b in num_pairs])
            if sp is not None and abs(sp) > 0.5:
                any_corr = True
        field_report.append(
            {
                "field": key,
                "status": "varies" if varies else "constant",
                "unique": uniq[:12],
                "n_unique": len(uniq),
                "spearman": sp,
                "spearman_src": "measured" if sp is not None else "could-not-measure",
            }
        )

    out["fields"] = field_report
    if not any_varies:
        out["H_FIELD"] = {
            "verdict": "NULL_all_constant",
            "verdict_src": "measured",
            "detail": "all present daemon fields identical across runs; no correlation possible",
        }
        out["status"] = "null_fields_identical"
        out["rc"] = RC_OK
    elif not any_corr:
        out["H_FIELD"] = {
            "verdict": "NULL_no_correlation",
            "verdict_src": "measured",
            "detail": "some fields vary but |Spearman|≤0.5 vs median_offset for all",
        }
        out["status"] = "null_no_correlation"
        out["rc"] = RC_OK
    else:
        hits = [f for f in field_report if f.get("spearman") is not None and abs(f["spearman"]) > 0.5]
        out["H_FIELD"] = {
            "verdict": "CORRELATED",
            "verdict_src": "measured",
            "hits": hits,
        }
        out["status"] = "field_correlation"
        out["rc"] = RC_OK
    return out


def print_report(title: str, q: Dict[str, Any], f: Optional[Dict[str, Any]] = None) -> None:
    print(f"=== {title} ===")
    for k in [
        "n_runs",
        "between_run_range_ms",
        "between_run_stdev_ms",
        "between_run_mean_ms",
        "capture_frame_quant_ms",
        "expected_uniform_range_ms",
        "range_over_T",
        "flash_onset_n_interp_total",
        "flash_onset_n_step_total",
        "flash_onset_n_flashes_total",
        "beep_hop_ms",
        "within_run_stdev_ms_median",
        "uniform_0_T_stdev_ms",
        "all_flashes_step_no_interp",
        "instrument_floor_ms",
        "status",
    ]:
        if k in q and not k.endswith("_src"):
            src = q.get(f"{k}_src", q.get("H_QUANT", {}).get("verdict_src", "?"))
            if f"{k}_src" in q:
                src = q[f"{k}_src"]
            print(f"{k}={q[k]} src={src}")
    if "median_ms_list" in q:
        print(
            "median_ms_list="
            + ",".join(f"{x:.4f}" for x in q["median_ms_list"])
            + " src=measured"
        )
    hq = q.get("H_QUANT") or {}
    print(f"H_QUANT={hq.get('verdict')} src={hq.get('verdict_src')} detail={hq.get('detail')}")
    if q.get("consequence"):
        print(f"CONSEQUENCE={q['consequence']}")
    if f:
        print(f"H_FIELD={f.get('H_FIELD', {}).get('verdict')} src={f.get('H_FIELD', {}).get('verdict_src')}")
        print(f"H_FIELD_detail={f.get('H_FIELD', {}).get('detail')}")
        for fr in f.get("fields") or []:
            print(
                f"  field={fr['field']} status={fr['status']} "
                f"n_unique={fr.get('n_unique')} unique={fr.get('unique')} "
                f"spearman={fr.get('spearman')} src={fr.get('spearman_src')}"
            )


def self_test() -> int:
    fails = 0

    def check(c: bool, m: str) -> None:
        nonlocal fails
        if not c:
            print(f"FAIL {m}", file=sys.stderr)
            fails += 1
        else:
            print(f"PASS {m}")

    # E[range] for U(0,1), n=2 → 1/3
    check(abs(expected_uniform_range(1.0, 2) - 1.0 / 3.0) < 1e-9, "E range n=2")
    check(abs(expected_uniform_range(33.333, 16) - 33.333 * 15 / 17) < 1e-6, "E range n=16")

    # Synthetic: medians span 25 < T=33.3, all step
    runs = []
    for i, m in enumerate([-113, -107, -123, -113, -110, -119, -100, -125]):
        runs.append(
            RunJson(
                path=f"s{i}",
                median_ms=m,
                stdev_ms=14.0,
                n_pairs=40,
                n_interp=0,
                n_step=40,
                n_flashes=40,
                quant_ms=33.333,
                period_ms=33.333,
                hop_ms=2.0,
            )
        )
    q = analyze_quant(runs)
    check(q["H_QUANT"]["verdict"] == "SUPPORTED", f"quant support got {q['H_QUANT']['verdict']}")
    check(q["instrument_floor_ms"] == 33.333, "floor=T")

    # Reject: range 50 > T 33
    runs2 = [
        RunJson(path="a", median_ms=0, n_interp=0, n_step=10, n_flashes=10, quant_ms=33.3),
        RunJson(path="b", median_ms=50, n_interp=0, n_step=10, n_flashes=10, quant_ms=33.3),
    ]
    q2 = analyze_quant(runs2)
    check(q2["H_QUANT"]["verdict"] == "REJECTED", f"quant reject got {q2['H_QUANT']['verdict']}")

    # Field null constant
    rj = RunJson(path="x", median_ms=-110.0)
    rec = {k: 1 for k in REC_FIELDS}
    f = analyze_fields([(rj, rec), (RunJson(path="y", median_ms=-120.0), dict(rec))])
    check(f["H_FIELD"]["verdict"] == "NULL_all_constant", f"field null got {f['H_FIELD']['verdict']}")

    if fails:
        print(f"SELF_TEST_FAIL fails={fails}")
        return RC_REJECT
    print("SELF_TEST_OK")
    return RC_OK


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--json", action="append", default=[], help="avsync JSON (repeatable)")
    ap.add_argument("--json-glob", action="append", default=[], help="glob for JSON files")
    ap.add_argument("--rec", action="append", default=[], help="sixfield rec*.txt (repeatable)")
    ap.add_argument(
        "--rec-dir",
        type=Path,
        default=None,
        help="directory with recN.txt + avN.json paired by number",
    )
    ap.add_argument("--json-out", type=Path, default=None)
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    from glob import glob as gglob

    paths: List[Path] = [Path(p) for p in args.json]
    for g in args.json_glob:
        paths.extend(Path(p) for p in sorted(gglob(g)))

    # dedupe
    seen = set()
    uniq_paths: List[Path] = []
    for p in paths:
        if not p.exists():
            continue
        rp = str(p.resolve())
        if rp not in seen:
            seen.add(rp)
            uniq_paths.append(p)

    if args.rec_dir and args.rec_dir.is_dir():
        for jp in sorted(args.rec_dir.glob("av*.json")):
            if jp not in uniq_paths:
                uniq_paths.append(jp)

    if not uniq_paths:
        print("VERDICT=UNSCORED rc=77 reason=no_json src=could-not-measure")
        return RC_UNSCORED

    runs = [load_run(p) for p in uniq_paths]
    print(f"loaded_json_n={len(runs)} src=measured")
    for r in runs:
        print(
            f"  run={r.tag} median_ms={r.median_ms} quant_ms={r.quant_ms} "
            f"n_interp={r.n_interp} n_step={r.n_step} n_flash={r.n_flashes} "
            f"hop_ms={r.hop_ms} stdev_ms={r.stdev_ms} src=measured"
        )

    q = analyze_quant(runs)
    print_report("H-QUANT residual", q)

    # sixfield pairing
    field_pairs: List[Tuple[RunJson, Dict[str, Any]]] = []
    rec_paths = [Path(p) for p in args.rec]
    if args.rec_dir and args.rec_dir.is_dir():
        rec_paths.extend(sorted(args.rec_dir.glob("rec*.txt")))
    rec_by_num: Dict[str, Path] = {}
    for rp in rec_paths:
        m = re.search(r"rec(\d+)", rp.stem)
        if m:
            rec_by_num[m.group(1)] = rp
    for r in runs:
        m = re.search(r"(\d+)$", r.tag)
        if not m:
            m = re.search(r"av(\d+)", r.tag)
        if not m:
            continue
        num = m.group(1)
        if num in rec_by_num:
            field_pairs.append((r, parse_rec(rec_by_num[num])))

    frep = None
    if field_pairs:
        frep = analyze_fields(field_pairs)
        print_report("H-FIELD sixfield", q, frep)
    else:
        print("H_FIELD=UNSCORED src=could-not-measure detail=no_rec_pairs")

    payload = {"quant": q, "fields": frep, "runs": [r.tag for r in runs]}
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        # make JSON-safe
        args.json_out.write_text(json.dumps(payload, indent=2, default=str), encoding="utf-8")
        print(f"json_out={args.json_out} src=measured")

    rc = q.get("rc", RC_UNSCORED)
    # Field null does not override quant REJECT; quant SUPPORT stays 0
    print(f"VERDICT_RC={rc} src=measured")
    return int(rc)


if __name__ == "__main__":
    sys.exit(main())
