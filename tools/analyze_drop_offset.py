#!/usr/bin/env python3
"""Analyze startup-drop vs lipsync-offset correlation (H-DROP) from captured data.

Pure host-side analysis. No device access.

Inputs (paths overridable):
  - avsync_measure_hdmi.py JSON outputs (result.pairs with t_flash_s, offset_ms)
  - optional 1 Hz telemetry text dumps (media: ... drops=N wall_s=...)

H-DROP (parent pre-registration):
  offset_ms ≈ a - (1000/24) * startup_drops
  i.e. each startup drop shifts lipsync by one content frame at measured 24.000 fps.

Sign convention (from instrument): offset_ms = t_audio - t_video;
  NEGATIVE = audio LEADS video. All absolute medians are raw_uncalibrated unless
  the JSON says otherwise — this tool never re-labels them as calibrated.

Exit codes:
  0  = analysis completed on sufficient paired points (or --self-test PASS)
  2  = analysis completed and H-DROP is rejected at the stated residual gate
  77 = could-not-measure (missing files, <2 paired runs, empty pairs)
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import statistics
import sys
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Tuple


# Measured fixture fps (parent ffprobe on rk8). NOT a 23.976 default.
FRAME_MS_24 = 1000.0 / 24.0  # 41.666... ms
# host/libmisterplex/mraudio_status.hpp: kFeedTargetBytes = kMrAudioBytesPerSec/10
PREFILL_BYTES = 19200
PREFILL_MS = PREFILL_BYTES / (48000.0 * 4.0) * 1000.0  # 100.0 exactly


def tag(value: Any, src: str) -> str:
    return f"{value}  src={src}"


def median(xs: Sequence[float]) -> float:
    return float(statistics.median(xs))


def mean(xs: Sequence[float]) -> float:
    return float(statistics.mean(xs))


def pstdev(xs: Sequence[float]) -> float:
    if len(xs) < 1:
        return float("nan")
    return float(statistics.pstdev(xs))


def load_avsync(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    res = doc.get("result", doc)
    pairs = res.get("pairs") or []
    if not pairs:
        raise ValueError(f"no pairs in {path}")
    offs = [float(p["offset_ms"]) for p in pairs]
    ts = [float(p["t_flash_s"]) for p in pairs]
    return {
        "path": path,
        "pairs": pairs,
        "offsets": offs,
        "t_flash_s": ts,
        "n_pairs": len(pairs),
        "median_offset_ms": median(offs),
        "mean_offset_ms": mean(offs),
        "stdev_offset_ms": pstdev(offs),
        "slope_json": res.get("slope_ms_per_s"),
        "unpaired_flashes": res.get("unpaired_flashes"),
        "unpaired_beeps": res.get("unpaired_beeps"),
        "median_tag": doc.get("median_offset_ms_tag") or res.get("median_offset_ms_tag")
        or "raw_uncalibrated",
        "rc_tool": doc.get("rc"),
    }


def parse_tele(path: str) -> Dict[str, Any]:
    """Parse 1 Hz media telemetry dump. drops field may appear only after first media line."""
    rows: List[Dict[str, Any]] = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            body = line.strip()
            midx = re.match(r"^(\d+)\s+(.*)$", body)
            if midx:
                body = midx.group(2)
            wall = re.search(r"wall_s=([0-9.]+)", body)
            drops = re.search(r"drops=(\d+)", body)
            frames = re.search(r"frames=(\d+)", body)
            presents = re.search(r"presents=(\d+)", body)
            residual = re.search(r"residual=(\d+)", body)
            pub = re.search(r"publish_misses=(\d+)", body)
            drift = re.search(r"av_drift_ms=(-?\d+)", body)
            lat = re.search(r"audio latency\s+(\d+)ms", body)
            queued = re.search(r"queued=(\d+)B", body)
            audio_s = re.search(r"audio_s=([0-9.]+)", body)
            row: Dict[str, Any] = {"raw": body[:160]}
            if wall:
                row["wall_s"] = float(wall.group(1))
            if drops:
                row["drops"] = int(drops.group(1))
            if frames:
                row["frames"] = int(frames.group(1))
            if presents:
                row["presents"] = int(presents.group(1))
            if residual:
                row["residual"] = int(residual.group(1))
            if pub:
                row["publish_misses"] = int(pub.group(1))
            if drift:
                row["av_drift_ms"] = int(drift.group(1))
            if lat:
                row["audio_latency_ms"] = int(lat.group(1))
            if queued:
                row["queued_B"] = int(queued.group(1))
            if audio_s:
                row["audio_s"] = float(audio_s.group(1))
            rows.append(row)

    drop_rows = [r for r in rows if "drops" in r and "wall_s" in r]
    if not drop_rows:
        return {
            "path": path,
            "ok": False,
            "reason": "no_drops_field",
            "rows": rows,
        }

    transitions = 0
    prev = None
    for r in drop_rows:
        d = r["drops"]
        if prev is not None and d != prev:
            transitions += 1
        prev = d

    first = drop_rows[0]
    last = drop_rows[-1]
    final = last["drops"]
    first_at_final = next(r["wall_s"] for r in drop_rows if r["drops"] == final)

    late = [r for r in drop_rows if r["wall_s"] > (first_at_final + 0.5)]
    late_drops = [r["drops"] for r in late] if late else [final]
    steady_flat = max(late_drops) == min(late_drops) == final

    lat_list = [r["audio_latency_ms"] for r in rows if "audio_latency_ms" in r]
    q_list = [r["queued_B"] for r in rows if "queued_B" in r]
    q_ms = [q / (48000.0 * 4.0) * 1000.0 for q in q_list]

    ledger = None
    if all(k in last for k in ("frames", "presents", "drops")):
        ledger = last["frames"] - last["presents"] - last["drops"]

    return {
        "path": path,
        "ok": True,
        "startup_drops": final,  # measured: final == first sample drops when transitions=0
        "first_drops": first["drops"],
        "final_drops": final,
        "transitions": transitions,
        "first_wall_s": first["wall_s"],
        "last_wall_s": last["wall_s"],
        "first_wall_at_final_drops": first_at_final,
        "steady_state_flat": steady_flat,
        "n_drop_samples": len(drop_rows),
        "ledger_frames_minus_presents_minus_drops": ledger,
        "last_residual": last.get("residual"),
        "last_publish_misses": last.get("publish_misses"),
        "latency_ms_median": median(lat_list) if lat_list else None,
        "queued_B_median": median(q_list) if q_list else None,
        "queued_ms_median": median(q_ms) if q_ms else None,
        "n_latency_samples": len(lat_list),
        "n_queued_samples": len(q_list),
        "first_media": {
            "wall_s": first.get("wall_s"),
            "drops": first.get("drops"),
            "frames": first.get("frames"),
            "presents": first.get("presents"),
            "audio_s": first.get("audio_s"),
        },
    }


def ols(ts: Sequence[float], ys: Sequence[float]) -> Tuple[float, float, List[float]]:
    n = len(ts)
    if n < 2:
        raise ValueError("ols needs n>=2")
    mt, my = mean(ts), mean(ys)
    sxx = sum((t - mt) ** 2 for t in ts)
    if sxx <= 0:
        raise ValueError("ols degenerate x")
    b = sum((t - mt) * (y - my) for t, y in zip(ts, ys)) / sxx
    a = my - b * mt
    resid = [y - (a + b * t) for t, y in zip(ts, ys)]
    return a, b, resid


def ar1_rho(resid: Sequence[float]) -> float:
    n = len(resid)
    if n < 3:
        return float("nan")
    m = mean(resid)
    num = sum((resid[i] - m) * (resid[i - 1] - m) for i in range(1, n))
    den = sum((r - m) ** 2 for r in resid)
    if den <= 0:
        return float("nan")
    return num / den


def slope_with_ar1(ts: Sequence[float], ys: Sequence[float]) -> Dict[str, float]:
    a, b, resid = ols(ts, ys)
    n = len(ts)
    mt = mean(ts)
    sxx = sum((t - mt) ** 2 for t in ts)
    s_yx = math.sqrt(sum(r * r for r in resid) / (n - 2))
    se_naive = s_yx / math.sqrt(sxx)
    rho = ar1_rho(resid)
    # Simple AR(1) variance inflation for regression slope SE.
    if rho != rho or abs(rho) >= 0.999:
        infl = float("inf")
        se_ar1 = float("inf")
    else:
        infl = (1.0 + rho) / (1.0 - rho)
        se_ar1 = se_naive * math.sqrt(max(infl, 0.0))
    t_ar1 = b / se_ar1 if se_ar1 and se_ar1 != float("inf") and se_ar1 > 0 else float("nan")
    return {
        "intercept": a,
        "slope": b,
        "rho1": rho,
        "se_naive": se_naive,
        "se_ar1": se_ar1,
        "inflation": infl if isinstance(infl, float) else float("nan"),
        "t_ar1": t_ar1,
        "n": float(n),
        "s_yx": s_yx,
    }


def block_medians(
    t_flash: Sequence[float], offsets: Sequence[float], block_s: float = 10.0
) -> Tuple[List[float], List[float]]:
    if not t_flash:
        return [], []
    t0 = t_flash[0]
    buckets: Dict[int, List[float]] = {}
    for t, y in zip(t_flash, offsets):
        bi = int((t - t0) // block_s)
        buckets.setdefault(bi, []).append(y)
    ts: List[float] = []
    ms: List[float] = []
    for bi in sorted(buckets):
        ts.append(t0 + (bi + 0.5) * block_s)
        ms.append(median(buckets[bi]))
    return ts, ms


@dataclass
class PairedRun:
    name: str
    avsync_path: str
    tele_path: Optional[str]
    av: Dict[str, Any] = field(default_factory=dict)
    tele: Optional[Dict[str, Any]] = None


def fit_line(xs: Sequence[float], ys: Sequence[float]) -> Dict[str, float]:
    a, b, resid = ols(xs, ys)
    my = mean(ys)
    ss_res = sum(r * r for r in resid)
    ss_tot = sum((y - my) ** 2 for y in ys)
    r2 = 1.0 - ss_res / ss_tot if ss_tot > 0 else float("nan")
    n = len(xs)
    s_yx = math.sqrt(ss_res / (n - 2)) if n > 2 else float("nan")
    return {
        "a": a,
        "b": b,
        "r2": r2,
        "s_yx": s_yx,
        "ss_res": ss_res,
        "n": float(n),
    }


def print_kv(k: str, v: Any, src: str) -> None:
    print(f"{k}={v}  src={src}")


def analyze(runs: List[PairedRun], frame_ms: float, reject_resid_ms: float) -> int:
    print("=== DROP/OFFSET ANALYSIS ===")
    print_kv("frame_ms", frame_ms, "DEFAULT_ASSUMED_from_measured_24.000_fps")
    print_kv("prefill_ms", PREFILL_MS, "DEFAULT_ASSUMED_from_kFeedTargetBytes_19200")
    print_kv("prefill_bytes", PREFILL_BYTES, "DEFAULT_ASSUMED_from_mraudio_status.hpp")
    print_kv("reject_resid_ms", reject_resid_ms, "caller_supplied_or_default")
    print()

    paired: List[Tuple[str, float, float, PairedRun]] = []
    unpaired_av: List[PairedRun] = []

    for run in runs:
        try:
            run.av = load_avsync(run.avsync_path)
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as e:
            print(f"FAIL load avsync {run.avsync_path}: {e}  src=measured")
            return 77
        if run.tele_path:
            if not os.path.isfile(run.tele_path):
                print(f"FAIL missing tele {run.tele_path}  src=measured")
                return 77
            run.tele = parse_tele(run.tele_path)
            if not run.tele.get("ok"):
                print(f"FAIL tele parse {run.tele_path}: {run.tele.get('reason')}  src=measured")
                return 77
            paired.append(
                (
                    run.name,
                    float(run.tele["startup_drops"]),
                    float(run.av["median_offset_ms"]),
                    run,
                )
            )
        else:
            unpaired_av.append(run)

    print("--- per-run summary ---")
    for run in runs:
        av = run.av
        print(f"[{run.name}] avsync={run.avsync_path}")
        print_kv("  n_pairs", av["n_pairs"], "measured")
        print_kv("  median_offset_ms", f"{av['median_offset_ms']:.6f}", "measured")
        print_kv("  median_tag", av["median_tag"], "caller_supplied_from_json")
        print_kv("  mean_offset_ms", f"{av['mean_offset_ms']:.6f}", "measured")
        print_kv("  stdev_offset_ms", f"{av['stdev_offset_ms']:.6f}", "measured")
        print_kv("  slope_json_ms_per_s", av["slope_json"], "measured_from_json")
        print_kv("  unpaired_flashes", av["unpaired_flashes"], "measured")
        print_kv("  unpaired_beeps", av["unpaired_beeps"], "measured")
        if run.tele:
            t = run.tele
            print_kv("  startup_drops", t["startup_drops"], "measured")
            print_kv("  drop_transitions", t["transitions"], "measured")
            print_kv("  first_wall_s_with_drops", t["first_wall_s"], "measured")
            print_kv("  last_wall_s", t["last_wall_s"], "measured")
            print_kv("  steady_state_drops_flat", t["steady_state_flat"], "measured")
            print_kv(
                "  ledger_f-p-d",
                t["ledger_frames_minus_presents_minus_drops"],
                "measured",
            )
            print_kv("  last_residual", t["last_residual"], "measured")
            print_kv("  last_publish_misses", t["last_publish_misses"], "measured")
            print_kv("  latency_ms_median", t["latency_ms_median"], "measured")
            print_kv("  queued_ms_median", t["queued_ms_median"], "measured")
            print_kv("  first_media", t["first_media"], "measured")
        else:
            print("  tele=NONE  src=measured  (startup_drops unresolvable)")
        print()

    # --- H-DROP ---
    print("--- H-DROP test ---")
    print(
        "Model under test: offset_ms = a + b * startup_drops, "
        f"with b ≈ -frame_ms ({-frame_ms:.6f})."
    )
    print(
        "With n paired runs you can ALWAYS fit a line through n points when n=2 "
        "(zero residual by construction). That fit establishes NOTHING about "
        "out-of-sample truth. The 3rd independent point is the first real test; "
        "n=3 leaves one residual degree of freedom. Confidence here is the "
        "out-of-sample residual magnitude vs within-run median SE, not a ratio of "
        "two deltas that both sit inside a loose 42 ms band."
    )

    hdrop_rejected = False
    if len(paired) < 2:
        print("H-DROP: could-not-measure (need >=2 runs with tele+avsync)  src=measured")
        if not paired and not unpaired_av:
            return 77
    else:
        xs = [p[1] for p in paired]
        ys = [p[2] for p in paired]
        print("paired_points (name, drops, median_offset_ms):")
        for name, x, y, _ in paired:
            print(f"  {name}: drops={x:.0f}  median_offset_ms={y:.6f}  src=measured")

        # 2-point free fit on first two, predict rest
        if len(paired) >= 2:
            fit2 = fit_line(xs[:2], ys[:2])
            print_kv("fit2_intercept_a", f"{fit2['a']:.6f}", "measured")
            print_kv("fit2_slope_b_ms_per_drop", f"{fit2['b']:.6f}", "measured")
            print_kv("fit2_expected_b", f"{-frame_ms:.6f}", "DEFAULT_ASSUMED_frame_quantum")
            for name, x, y, _ in paired:
                pred = fit2["a"] + fit2["b"] * x
                resid = y - pred
                src = "measured" if name in (paired[0][0], paired[1][0]) else "measured"
                kind = "in_sample" if name in (paired[0][0], paired[1][0]) else "OOS"
                print(
                    f"  pred2[{name}] pred={pred:.6f} y={y:.6f} resid={resid:.6f} "
                    f"kind={kind}  src={src}"
                )
                if kind == "OOS" and abs(resid) > reject_resid_ms:
                    hdrop_rejected = True

        # Forced slope = -frame_ms, intercept from first two
        b_q = -frame_ms
        a_q = mean([y - b_q * x for x, y in zip(xs[:2], ys[:2])])
        print_kv("fit2_forced_frame_intercept", f"{a_q:.6f}", "measured")
        print_kv("fit2_forced_frame_slope", f"{b_q:.6f}", "DEFAULT_ASSUMED_frame_quantum")
        for name, x, y, _ in paired:
            pred = a_q + b_q * x
            resid = y - pred
            kind = "in_sample" if name in (paired[0][0], paired[1][0]) else "OOS"
            print(
                f"  pred2_forced[{name}] pred={pred:.6f} y={y:.6f} resid={resid:.6f} "
                f"kind={kind}  src=measured"
            )
            if kind == "OOS" and abs(resid) > reject_resid_ms:
                hdrop_rejected = True

        if len(paired) >= 3:
            fitn = fit_line(xs, ys)
            print_kv("fitN_intercept_a", f"{fitn['a']:.6f}", "measured")
            print_kv("fitN_slope_b_ms_per_drop", f"{fitn['b']:.6f}", "measured")
            print_kv("fitN_r_squared", f"{fitn['r2']:.6f}", "measured")
            print_kv("fitN_s_yx_ms", f"{fitn['s_yx']:.6f}", "measured")
            # Pearson
            mx, my = mean(xs), mean(ys)
            num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
            den = math.sqrt(
                sum((x - mx) ** 2 for x in xs) * sum((y - my) ** 2 for y in ys)
            )
            r = num / den if den > 0 else float("nan")
            print_kv("pearson_r_drops_vs_offset", f"{r:.6f}", "measured")
            for name, x, y, _ in paired:
                pred = fitn["a"] + fitn["b"] * x
                print(
                    f"  predN[{name}] pred={pred:.6f} y={y:.6f} resid={y-pred:.6f}  src=measured"
                )
            # Reject if |b + frame_ms| is large relative to frame OR r2 near 0 with large s_yx
            if abs(fitn["b"] + frame_ms) > 20.0 and fitn["r2"] < 0.5:
                hdrop_rejected = True
            if fitn["r2"] == fitn["r2"] and fitn["r2"] < 0.2 and fitn["s_yx"] > reject_resid_ms:
                hdrop_rejected = True

        # Between-run deltas vs candidate quanta
        print("--- between-run median deltas vs candidate quanta ---")
        for i in range(len(paired)):
            for j in range(i + 1, len(paired)):
                ni, xi, yi, _ = paired[i]
                nj, xj, yj, _ = paired[j]
                d_off = yj - yi
                d_drop = xj - xi
                print(
                    f"  Δ({nj}-{ni}): d_offset_ms={d_off:.6f} d_drops={d_drop:.0f}  src=measured"
                )
                for label, q in (
                    ("1*frame_ms", frame_ms),
                    ("2*frame_ms", 2 * frame_ms),
                    ("3*frame_ms", 3 * frame_ms),
                    ("1*prefill_ms", PREFILL_MS),
                    ("prefill+0.5*frame", PREFILL_MS + 0.5 * frame_ms),
                    ("prefill+frame", PREFILL_MS + frame_ms),
                ):
                    # compare absolute jump size (phase flip), not signed model
                    err = abs(abs(d_off) - q)
                    print(f"    | |d_off| - {label} | = {err:.6f}  src=measured")

    # Steady-state queue identical?
    print("--- prefill/queue across paired runs ---")
    qmeds = []
    for name, x, y, run in paired:
        qm = run.tele.get("queued_ms_median") if run.tele else None
        lm = run.tele.get("latency_ms_median") if run.tele else None
        print_kv(f"  {name}.queued_ms_median", qm, "measured")
        print_kv(f"  {name}.latency_ms_median", lm, "measured")
        if qm is not None:
            qmeds.append(qm)
    if len(qmeds) >= 2:
        print_kv("queued_ms_median_range", max(qmeds) - min(qmeds), "measured")
        print(
            "Note: identical steady-state queue depth does NOT kill a one-shot "
            "startup phase equal to one prefill quantum; depth≠content phase.  src=measured"
        )

    # Cluster note
    if len(paired) >= 2:
        meds = sorted(y for _, _, y, _ in paired)
        gaps = [meds[i + 1] - meds[i] for i in range(len(meds) - 1)]
        print_kv("sorted_medians", meds, "measured")
        print_kv("adjacent_median_gaps_ms", gaps, "measured")

    # --- within-run structure ---
    print("--- within-run slope (drops cannot explain: steady drops flat) ---")
    for run in runs:
        av = run.av
        ts = av["t_flash_s"]
        ys = av["offsets"]
        st = slope_with_ar1(ts, ys)
        bt, bm = block_medians(ts, ys, block_s=10.0)
        if len(bt) >= 3:
            bst = slope_with_ar1(bt, bm)
        else:
            bst = None
        print(f"[{run.name}]")
        print_kv("  per_pair_slope_ms_per_s", f"{st['slope']:.6f}", "measured")
        print_kv("  per_pair_rho1", f"{st['rho1']:.6f}", "measured")
        print_kv("  per_pair_SE_naive", f"{st['se_naive']:.6f}", "measured")
        print_kv("  per_pair_SE_AR1", f"{st['se_ar1']:.6f}", "measured")
        print_kv("  per_pair_t_AR1", f"{st['t_ar1']:.4f}", "measured")
        if bst:
            print_kv("  block10_slope_ms_per_s", f"{bst['slope']:.6f}", "measured")
            print_kv("  block10_n", int(bst["n"]), "measured")
            print_kv("  block10_rho1", f"{bst['rho1']:.6f}", "measured")
            print_kv("  block10_SE_AR1", f"{bst['se_ar1']:.6f}", "measured")
            print_kv("  block10_t_AR1", f"{bst['t_ar1']:.4f}", "measured")
        # early/late fifths
        n = len(ys)
        e = ys[: max(1, n // 5)]
        l = ys[-max(1, n // 5) :]
        print_kv("  early_fifth_median", f"{median(e):.6f}", "measured")
        print_kv("  late_fifth_median", f"{median(l):.6f}", "measured")
        print_kv("  late_minus_early_ms", f"{median(l) - median(e):.6f}", "measured")

    # --- 240p / unpaired ---
    print("--- arms without tele (e.g. 240p) ---")
    if not unpaired_av:
        print("none  src=measured")
    for run in unpaired_av:
        print(f"[{run.name}] median_offset_ms={run.av['median_offset_ms']:.6f}  src=measured")
        print(
            "  startup_drops=UNRESOLVABLE (no telemetry file). "
            "H-DROP cannot be tested on this arm.  src=measured"
        )
        if len(paired) >= 2:
            fit2 = fit_line(
                [p[1] for p in paired[:2]], [p[2] for p in paired[:2]]
            )
            # implied drops under 2pt model — labeled DEFAULT_ASSUMED model invert, not measured
            if abs(fit2["b"]) > 1e-9:
                implied = (run.av["median_offset_ms"] - fit2["a"]) / fit2["b"]
                print_kv(
                    "  implied_drops_under_fit2_NOT_MEASURED",
                    f"{implied:.3f}",
                    "DEFAULT_ASSUMED_model_invert",
                )

    # --- discrimination design ---
    print("--- discrimination design (100 ms prefill vs 3*frame=125 ms) ---")
    print(
        "Both 100.0 ms and 125.0 ms sit inside a ±42 ms gate around a ~119 ms jump; "
        "that gate cannot decide. Use one of:\n"
        "  D1. More sessions with tele: if offset is bimodal (~-316 vs ~-196) while "
        "startup_drops varies freely inside each mode (already seen: drops 12 and 18 "
        "share ~-196), H-DROP linear is dead; report mode separation vs quanta.\n"
        "  D2. Intervention on feed target: rebuild/conf a non-100 ms kFeedTargetBytes "
        "(e.g. 50 ms and 150 ms). If between-mode gap tracks feed target, prefill-phase "
        "wins; if gap stays ~3 frames independent of feed target, frame-quantum phase wins.\n"
        "  D3. Log audio clock origin / hold-release / pcm_silence_head at play start "
        "alongside startup_drops; correlate phase markers with median_offset cluster id.\n"
        "  D4. Do NOT use av_drift_ms (self-graded; blind to content phase)."
    )

    print("--- VERDICT ---")
    if len(paired) < 3:
        print(
            "H-DROP=INCONCLUSIVE_NEED_OOS  (n<3 paired tele runs; 2-pt fit is tautology)  src=measured"
        )
        return 0
    if hdrop_rejected:
        print(
            "H-DROP=REJECTED  OOS residual and/or 3-pt fit incompatible with "
            f"-frame_ms/drop model (gate resid>{reject_resid_ms} ms)  src=measured"
        )
        return 2
    print("H-DROP=NOT_REJECTED_AT_GATE  src=measured")
    return 0


def build_default_runs() -> List[PairedRun]:
    """Parent lab defaults under /tmp (capture host)."""
    return [
        PairedRun("rep1", "/tmp/avsync_rep1.json", "/tmp/tele_1.txt"),
        PairedRun("rep2", "/tmp/avsync_rep2.json", "/tmp/tele_2.txt"),
        PairedRun("rep3", "/tmp/avsync_rep3.json", "/tmp/tele_3.txt"),
        PairedRun("480_330", "/tmp/avsync_480_330.json", None),
        PairedRun("240_330", "/tmp/avsync_240_330.json", None),
    ]


def self_test() -> int:
    """Synthetic RED/GREEN for H-DROP logic. No /tmp dependency."""
    import tempfile

    def write_avsync(path: str, median_center: float, n: int = 40, slope: float = -0.1):
        pairs = []
        for i in range(n):
            t = 1.0 + i
            # mild noise
            off = median_center + slope * (t - 1.0) + (0.5 if i % 2 == 0 else -0.5)
            pairs.append({"t_flash_s": t, "t_beep_s": t + off / 1000.0, "offset_ms": off})
        doc = {
            "rc": 2,
            "median_offset_ms_tag": "raw_uncalibrated",
            "result": {
                "pairs": pairs,
                "n_pairs": n,
                "n_flashes": n,
                "n_beeps": n,
                "unpaired_flashes": 0,
                "unpaired_beeps": 0,
                "median_offset_ms": median( [p["offset_ms"] for p in pairs] ),
                "slope_ms_per_s": slope,
            },
        }
        with open(path, "w", encoding="utf-8") as f:
            json.dump(doc, f)

    def write_tele(path: str, drops: int, n: int = 30):
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"1 media: audio latency 100ms queued=19200B\n")
            for i in range(n):
                wall = 7.0 + i
                frames = 160 + 24 * i
                presents = frames - drops
                f.write(
                    f"{i+2} media: frames={frames} wall_s={wall:.3f} audio_s={wall-0.1:.3f} "
                    f"av_drift_ms=-30 presents={presents} drops={drops} "
                    f"publish_misses=0 residual=0\n"
                )

    td = tempfile.mkdtemp(prefix="hdrop_selftest_")
    # GREEN path for analyzer plumbing: linear H-DROP-like synthetic (should NOT reject if consistent)
    # Actually we want:
    #  - case A: OOS consistent → rc 0 NOT_REJECTED
    #  - case B: OOS breaks → rc 2 REJECTED
    a1 = os.path.join(td, "a1.json")
    a2 = os.path.join(td, "a2.json")
    a3good = os.path.join(td, "a3good.json")
    a3bad = os.path.join(td, "a3bad.json")
    t1 = os.path.join(td, "t1.txt")
    t2 = os.path.join(td, "t2.txt")
    t3 = os.path.join(td, "t3.txt")

    # offset = 300 - 41.6667*drops
    def off(d):
        return 300.0 - FRAME_MS_24 * d

    write_avsync(a1, off(15))
    write_avsync(a2, off(12))
    write_avsync(a3good, off(18))
    write_avsync(a3bad, off(12))  # same offset as 12 but drops will be 18
    write_tele(t1, 15)
    write_tele(t2, 12)
    write_tele(t3, 18)

    # Case good
    runs_good = [
        PairedRun("r1", a1, t1),
        PairedRun("r2", a2, t2),
        PairedRun("r3", a3good, t3),
    ]
    # capture output optionally quiet
    import io
    from contextlib import redirect_stdout

    buf = io.StringIO()
    with redirect_stdout(buf):
        rc_good = analyze(runs_good, FRAME_MS_24, reject_resid_ms=20.0)
    if rc_good != 0:
        print(f"SELFTEST FAIL: expected rc=0 on consistent H-DROP, got {rc_good}")
        print(buf.getvalue()[-2000:])
        return 2

    runs_bad = [
        PairedRun("r1", a1, t1),
        PairedRun("r2", a2, t2),
        PairedRun("r3", a3bad, t3),
    ]
    buf2 = io.StringIO()
    with redirect_stdout(buf2):
        rc_bad = analyze(runs_bad, FRAME_MS_24, reject_resid_ms=20.0)
    if rc_bad != 2:
        print(f"SELFTEST FAIL: expected rc=2 on broken H-DROP, got {rc_bad}")
        print(buf2.getvalue()[-2000:])
        return 2

    # missing file → 77
    runs_miss = [PairedRun("x", os.path.join(td, "nope.json"), None)]
    buf3 = io.StringIO()
    with redirect_stdout(buf3):
        rc_miss = analyze(runs_miss, FRAME_MS_24, reject_resid_ms=20.0)
    if rc_miss != 77:
        print(f"SELFTEST FAIL: expected rc=77 on missing, got {rc_miss}")
        return 2

    print("SELFTEST_PASS rc_good=0 rc_bad=2 rc_miss=77  src=measured")
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--run",
        action="append",
        default=[],
        metavar="name,avsync.json[,tele.txt]",
        help="Paired run spec. Repeatable. tele optional.",
    )
    ap.add_argument(
        "--defaults",
        action="store_true",
        help="Use parent lab defaults under /tmp (rep1..3 + 480/240).",
    )
    ap.add_argument(
        "--frame-ms",
        type=float,
        default=FRAME_MS_24,
        help=f"Content frame period ms (default {FRAME_MS_24:.6f} = 1000/24)",
    )
    ap.add_argument(
        "--reject-resid-ms",
        type=float,
        default=30.0,
        help="OOS |residual| above this rejects H-DROP (default 30 ms)",
    )
    ap.add_argument("--self-test", action="store_true", help="Synthetic RED/GREEN and exit")
    args = ap.parse_args(argv)

    print_kv("tool", "analyze_drop_offset.py", "DEFAULT_ASSUMED")
    print_kv("frame_ms_arg", args.frame_ms, "caller_supplied" if args.frame_ms != FRAME_MS_24 else "DEFAULT_ASSUMED")

    if args.self_test:
        return self_test()

    runs: List[PairedRun] = []
    if args.defaults or not args.run:
        runs.extend(build_default_runs())
    for spec in args.run:
        parts = spec.split(",")
        if len(parts) < 2:
            print(f"bad --run spec: {spec}  src=caller_supplied")
            return 77
        name = parts[0].strip()
        av = parts[1].strip()
        tele = parts[2].strip() if len(parts) >= 3 and parts[2].strip() else None
        runs.append(PairedRun(name, av, tele))

    # Drop default runs that are missing when user only wants existing files
    filtered: List[PairedRun] = []
    for r in runs:
        if not os.path.isfile(r.avsync_path):
            print(f"skip missing avsync {r.avsync_path}  src=measured")
            continue
        if r.tele_path and not os.path.isfile(r.tele_path):
            print(f"skip missing tele for {r.name}: {r.tele_path}  src=measured")
            # keep avsync-only
            filtered.append(PairedRun(r.name, r.avsync_path, None))
            continue
        filtered.append(r)
    if not filtered:
        print("no runnable inputs  src=measured")
        return 77

    return analyze(filtered, frame_ms=float(args.frame_ms), reject_resid_ms=float(args.reject_resid_ms))


if __name__ == "__main__":
    try:
        rc = main()
    except Exception as e:  # noqa: BLE001 — top-level tool boundary
        print(f"FATAL {type(e).__name__}: {e}  src=measured")
        rc = 77
    print(f"exit_rc={rc}  src=measured")
    sys.exit(rc)
