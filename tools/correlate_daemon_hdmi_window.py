#!/usr/bin/env python3
"""Correlate misterplexd 1 Hz lines with one HDMI lipsync report (same window).

Host-only. No device. Used by tools/avsync_pair_daemon_hdmi.sh after
tools/avsync_lipsync_soak.sh (does not reimplement the grabber instrument).

Exit:
  0  both sides scored; prints mechanism hit/miss vs pre-register
  77 NO-DATA (missing daemon lines and/or HDMI report) — never a pass
  2  parse/usage
  1  self-test fail
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path
from typing import Any

RE_NUM = re.compile(
    r"\b(frames|presents|drops|publish_misses|residual|vfps|pfps|wall_s|"
    r"av_drift_ms|av_display_offset_ms|av_pipe_ahead_ms|audio_s|"
    r"pub_iv_p_ge50_w60|pub_iv_mean_ms_w60|pub_iv_max_ms_w60|"
    r"pub_iv_p_ge50_w5|pub_iv_sess_p_ge50|pub_iv_n|pub_iv_write_max_us_w60)="
    r"(-?\d+(?:\.\d+)?)"
)
RE_DISC = re.compile(r"\b(pub_iv_disc_w60|pub_iv_disc_w5)=([A-Z_]+)")


def parse_media_frames_line(line: str) -> dict[str, float] | None:
    if "media:" not in line or "frames=" not in line:
        return None
    if "A/V resync drop" in line:
        return None
    out: dict[str, float] = {}
    for m in RE_NUM.finditer(line):
        # Skip NO-DATA tokens that look numeric-less
        try:
            out[m.group(1)] = float(m.group(2))
        except ValueError:
            continue
    for m in RE_DISC.finditer(line):
        # encode disc as sentinel strings via side channel keys (str kept separately)
        out["_disc_" + m.group(1)] = 0.0  # presence marker; real text in _disc_text
    if "frames" not in out or "wall_s" not in out:
        return None
    # attach disc text
    discs = {m.group(1): m.group(2) for m in RE_DISC.finditer(line)}
    if discs:
        out["_has_disc"] = 1.0
    # stash as attributes via parallel dict key namespace is float-only; keep on row via hack:
    for k, v in discs.items():
        # map CLEAN=0 LATE_ARRIVAL=1 LATE_OBSERVATION=2 MIXED=3 UNSCORED=4 NO-DATA=-1
        code = {
            "CLEAN": 0.0,
            "LATE_ARRIVAL": 1.0,
            "LATE_OBSERVATION": 2.0,
            "MIXED": 3.0,
            "UNSCORED": 4.0,
            "NO-DATA": -1.0,
        }.get(v, 9.0)
        out[k] = code
    return out


def series_stats(rows: list[dict[str, float]], key: str) -> dict[str, Any]:
    xs = [r[key] for r in rows if key in r and not math.isnan(r[key])]
    if not xs:
        return {"n": 0, "src": "NO-DATA"}
    xs.sort()
    n = len(xs)

    def pct(p: float) -> float:
        if n == 1:
            return xs[0]
        i = min(n - 1, max(0, int(round((p / 100.0) * (n - 1)))))
        return xs[i]

    return {
        "n": n,
        "min": xs[0],
        "p50": pct(50),
        "p95": pct(95),
        "max": xs[-1],
        "first": xs[0],
        "last": xs[-1],
        "src": "measured",
    }


def load_hdmi(report_path: str | None, stdout_path: str | None) -> dict[str, Any]:
    h: dict[str, Any] = {
        "timing_class": None,
        "residual_rms_ms": None,
        "detrended_max_abs_ms": None,
        "median_offset_ms": None,
        "n_pairs": None,
        "src": "NO-DATA",
    }
    if report_path and Path(report_path).is_file():
        try:
            data = json.loads(Path(report_path).read_text(encoding="utf-8", errors="replace"))
        except json.JSONDecodeError:
            data = {}
        # tolerate nested / flat
        def dig(*keys: str) -> Any:
            cur: Any = data
            for k in keys:
                if not isinstance(cur, dict) or k not in cur:
                    return None
                cur = cur[k]
            return cur

        for path in (
            ("timing_class",),
            ("timing", "timing_class"),
            ("result", "timing_class"),
        ):
            v = dig(*path)
            if v is not None:
                h["timing_class"] = v
                break
        for key, aliases in (
            ("residual_rms_ms", ("residual_rms_ms",)),
            ("detrended_max_abs_ms", ("detrended_max_abs_ms",)),
            ("median_offset_ms", ("median_offset_ms_raw", "median_offset_ms")),
            ("n_pairs", ("n_pairs",)),
        ):
            for a in aliases:
                v = dig(a)
                if v is None:
                    v = dig("timing", a)
                if v is None:
                    v = dig("result", a)
                if v is not None:
                    h[key] = v
                    break
        if h["timing_class"] is not None or h["residual_rms_ms"] is not None:
            h["src"] = "hdmi_report_json"
            return h

    if stdout_path and Path(stdout_path).is_file():
        text = Path(stdout_path).read_text(encoding="utf-8", errors="replace")
        m = re.search(r"timing_class=([A-Z_]+)", text)
        if m:
            h["timing_class"] = m.group(1)
        m = re.search(r"residual_rms_ms=([0-9.]+)", text)
        if m:
            h["residual_rms_ms"] = float(m.group(1))
        m = re.search(r"detrended_max_abs_ms=([0-9.]+)", text)
        if m:
            h["detrended_max_abs_ms"] = float(m.group(1))
        m = re.search(r"median_offset_ms(?:_raw)?=([-+0-9.]+)", text)
        if m:
            h["median_offset_ms"] = float(m.group(1))
        m = re.search(r"n_pairs=(\d+)", text)
        if m:
            h["n_pairs"] = int(m.group(1))
        if h["timing_class"] is not None:
            h["src"] = "hdmi_stdout"
    return h


def classify_mech(daemon: dict[str, Any], hdmi: dict[str, Any]) -> dict[str, Any]:
    """M1 FALSIFIED on parent pair (2026-08-01). Primary is now M2 publish-interval."""
    tc = hdmi.get("timing_class")
    vfps = daemon.get("vfps") or {}
    drops = daemon.get("drops") or {}
    pge = daemon.get("pub_iv_p_ge50_w60") or {}
    v50 = vfps.get("p50")
    pge50 = pge.get("p50") if pge.get("src") == "measured" else None
    d_first = drops.get("first")
    d_last = drops.get("last")
    d_delta = None
    if d_first is not None and d_last is not None:
        d_delta = d_last - d_first

    out: dict[str, Any] = {
        "primary_pred": "M2_PUBLISH_INTERVAL_JITTER",
        "retired_pred": "M1_UNDERPRODUCE_THEN_DROP",
        "m1_status": "FALSIFIED_parent_pair_vfps23.9_drops_delta0",
        "hits": [],
        "misses": [],
        "verdict": "NO-DATA",
        "bands_src": "M2_PUBLISH_INTERVAL_RCA.md + parent pair 2026-08-01",
    }
    if tc is None or v50 is None:
        out["verdict"] = "NO-DATA"
        return out

    wander = tc == "WANDER"
    stable = tc == "STABLE"

    # M1 — keep scorer so a future underproduce resurfaces; parent miss is published.
    m1 = False
    if wander and v50 <= 20.0 and d_delta is not None and d_delta >= 15:
        m1 = True
        out["hits"].append("M1_UNDERPRODUCE_THEN_DROP")
    elif wander and v50 >= 23.5 and (d_delta is None or d_delta <= 3):
        out["misses"].append("M1_FALSIFIED_high_vfps_flat_drops")
    elif stable and v50 >= 23.2 and (d_delta is None or d_delta <= 5):
        out["hits"].append("M1_STABLE_CONTROL_SHAPE")

    # M2 candidate: WANDER + healthy throughput (parent confirmed)
    if wander and v50 is not None and v50 >= 23.2 and (d_delta is None or d_delta <= 5):
        out["hits"].append("M2_PUBLISH_INTERVAL_JITTER_CANDIDATE")

    # M2 confirmed when rolling p_ge50 elevated in same window
    if wander and pge50 is not None and pge50 >= 0.03:
        out["hits"].append("M2_CONFIRMED_p_ge50_w60_ge_0.03")
    elif wander and pge50 is not None and pge50 < 0.03:
        out["misses"].append("M2_p_ge50_w60_clean_on_WANDER")
    elif wander and pge50 is None:
        out["misses"].append("M2_pub_iv_NO-DATA_deploy_tip_daemon")

    if stable and pge50 is not None and pge50 < 0.03:
        out["hits"].append("M2_STABLE_CONTROL_clean_p_ge50")
    elif stable and pge50 is not None and pge50 >= 0.09:
        out["misses"].append("M2_STABLE_but_high_p_ge50")

    if wander and not m1 and "M2_PUBLISH_INTERVAL_JITTER_CANDIDATE" not in out["hits"]:
        out["misses"].append("WANDER_unclassified")

    if out["hits"] and not any(
        x.startswith("M1_FALSIFIED") or x.startswith("M2_p_ge50_w60_clean") or x.startswith("M2_pub_iv")
        for x in out["misses"]
    ):
        out["verdict"] = "SCORED_HIT"
    elif out["misses"] and not out["hits"]:
        out["verdict"] = "SCORED_MISS"
    elif out["hits"] and out["misses"]:
        out["verdict"] = "SCORED_MIXED"
    else:
        out["verdict"] = "SCORED_NEUTRAL"

    out["inputs"] = {
        "timing_class": tc,
        "vfps_p50": v50,
        "drops_delta": d_delta,
        "pub_iv_p_ge50_w60_p50": pge50,
        "residual_rms_ms": hdmi.get("residual_rms_ms"),
        "detrended_max_abs_ms": hdmi.get("detrended_max_abs_ms"),
    }
    return out


def correlate(daemon_log: Path, hdmi_report: str | None, hdmi_stdout: str | None) -> dict[str, Any]:
    rows: list[dict[str, float]] = []
    drop_lines = 0
    if daemon_log.is_file():
        for line in daemon_log.read_text(encoding="utf-8", errors="replace").splitlines():
            if "A/V resync drop" in line:
                drop_lines += 1
            p = parse_media_frames_line(line)
            if p:
                rows.append(p)

    daemon_sum: dict[str, Any] = {
        "n_media_lines": len(rows),
        "n_drop_event_lines": drop_lines,
        "src": "measured" if rows else "NO-DATA",
    }
    for key in (
        "vfps",
        "pfps",
        "drops",
        "frames",
        "wall_s",
        "av_drift_ms",
        "av_display_offset_ms",
        "av_pipe_ahead_ms",
        "publish_misses",
        "residual",
        "audio_s",
        "pub_iv_p_ge50_w60",
        "pub_iv_mean_ms_w60",
        "pub_iv_max_ms_w60",
        "pub_iv_p_ge50_w5",
        "pub_iv_sess_p_ge50",
        "pub_iv_write_max_us_w60",
        "pub_iv_disc_w60",
    ):
        daemon_sum[key] = series_stats(rows, key)
    # Explain NO-DATA on tip fields when live daemon is old schema.
    if daemon_sum["publish_misses"].get("src") == "NO-DATA" and rows:
        daemon_sum["publish_misses_note"] = (
            "NO-DATA on line schema: live daemon omits frameLedgerTelemetryFragment "
            "(tip media_player emits publish_misses=). Deploy tip ARM binary."
        )
    if daemon_sum["av_display_offset_ms"].get("src") == "NO-DATA" and rows:
        daemon_sum["av_display_offset_note"] = (
            "NO-DATA: live daemon omits formatAvServoTelemetry fields. Deploy tip ARM."
        )
    if daemon_sum["pub_iv_p_ge50_w60"].get("src") == "NO-DATA" and rows:
        daemon_sum["pub_iv_note"] = (
            "NO-DATA: need tip formatHzFragment on 1 Hz line (pub_iv_p_ge50_w60=). "
            "M2 cannot confirm without deploy."
        )

    # Construction check: mean(vfps-pfps) vs mean Δdrops/Δwall when enough points
    gap_note = "NO-DATA"
    if len(rows) >= 2 and "vfps" in rows[0] and "pfps" in rows[0]:
        gaps = [r["vfps"] - r["pfps"] for r in rows if "vfps" in r and "pfps" in r]
        d0, d1 = rows[0].get("drops"), rows[-1].get("drops")
        w0, w1 = rows[0].get("wall_s"), rows[-1].get("wall_s")
        if gaps and d0 is not None and d1 is not None and w0 is not None and w1 is not None and w1 > w0:
            drop_rate = (d1 - d0) / (w1 - w0)
            mean_gap = sum(gaps) / len(gaps)
            gap_note = (
                f"mean_vfps_minus_pfps={mean_gap:.3f} drops_per_wall_s={drop_rate:.3f} "
                f"(expect ≈ if Drop-only present loss)"
            )
    daemon_sum["vfps_pfps_gap_vs_drops"] = gap_note

    hdmi = load_hdmi(hdmi_report, hdmi_stdout)
    mech = classify_mech(daemon_sum, hdmi)

    # clock=av-lock reminder
    note_avlock = (
        "clock=av-lock is a hardcoded telemetry string in media_player.cpp — "
        "not a health bit; av_drift_ms is servo deadband (av_drift_role=servo_error_not_lipsync)"
    )

    return {
        "daemon": daemon_sum,
        "hdmi": hdmi,
        "mechanism": mech,
        "notes": [note_avlock, "HDMI residual_rms is lipsync ground truth; daemon av_drift is not"],
        "prereg": "UNDERPRODUCE_THEN_DROP primary; see .agent-work/w-geom/P480_THROUGHPUT_WANDER_PREREG.md",
    }


def self_test() -> int:
    # RED: empty → NO-DATA rc path handled by main
    td = Path(__file__).resolve().parent.parent / ".agent-work" / "w-geom" / "_pair_selftest"
    td.mkdir(parents=True, exist_ok=True)
    lp = td / "d.log"
    rp = td / "h.json"

    # Parent-shaped WANDER: high vfps, flat drops, elevated p_ge50 → M2 confirm + M1 falsified
    d_parent = (
        "media: frames=100 vfps=23.9 pfps=23.8 wall_s=10.0 drops=11 "
        "publish_misses=0 residual=0 av_drift_ms=-35 av_display_offset_ms=40 "
        "pub_iv_n=240 pub_iv_p_ge50_w60=0.0800 pub_iv_mean_ms_w60=41.7 "
        "pub_iv_max_ms_w60=62.0 pub_iv_disc_w60=LATE_ARRIVAL "
        "pub_iv_p_ge50_w5=0.1000 pub_iv_disc_w5=LATE_ARRIVAL audio_s=10.0\n"
        "media: frames=200 vfps=23.9 pfps=23.8 wall_s=20.0 drops=11 "
        "publish_misses=0 residual=0 av_drift_ms=-36 av_display_offset_ms=42 "
        "pub_iv_n=480 pub_iv_p_ge50_w60=0.0900 pub_iv_mean_ms_w60=41.8 "
        "pub_iv_max_ms_w60=70.0 pub_iv_disc_w60=LATE_ARRIVAL "
        "pub_iv_p_ge50_w5=0.1200 pub_iv_disc_w5=LATE_ARRIVAL audio_s=20.0\n"
    )
    h_w = {
        "timing_class": "WANDER",
        "residual_rms_ms": 14.398,
        "detrended_max_abs_ms": 50.803,
        "n_pairs": 30,
        "median_offset_ms_raw": -10.0,
    }
    lp.write_text(d_parent, encoding="utf-8")
    rp.write_text(json.dumps(h_w), encoding="utf-8")
    r = correlate(lp, str(rp), None)
    hits = r["mechanism"]["hits"]
    if "M2_PUBLISH_INTERVAL_JITTER_CANDIDATE" not in hits:
        print("FAIL expected M2 candidate", r["mechanism"], file=sys.stderr)
        return 1
    if "M2_CONFIRMED_p_ge50_w60_ge_0.03" not in hits:
        print("FAIL expected M2 confirmed", r["mechanism"], file=sys.stderr)
        return 1
    if "M1_UNDERPRODUCE_THEN_DROP" in hits:
        print("FAIL M1 must not hit parent shape", r["mechanism"], file=sys.stderr)
        return 1
    if "M1_FALSIFIED_high_vfps_flat_drops" not in r["mechanism"]["misses"]:
        print("FAIL expected M1 falsified miss tag", r["mechanism"], file=sys.stderr)
        return 1

    # STABLE control clean p_ge50
    d2 = (
        "media: frames=240 vfps=23.9 pfps=23.9 wall_s=10.0 drops=11 "
        "publish_misses=0 pub_iv_p_ge50_w60=0.0100 pub_iv_disc_w60=CLEAN "
        "av_drift_ms=-40 av_display_offset_ms=40 audio_s=10.0\n"
        "media: frames=480 vfps=24.0 pfps=24.0 wall_s=20.0 drops=11 "
        "publish_misses=0 pub_iv_p_ge50_w60=0.0050 pub_iv_disc_w60=CLEAN "
        "av_drift_ms=-40 av_display_offset_ms=40 audio_s=20.0\n"
    )
    h2 = {"timing_class": "STABLE", "residual_rms_ms": 8.0, "detrended_max_abs_ms": 20.0, "n_pairs": 20}
    lp.write_text(d2, encoding="utf-8")
    rp.write_text(json.dumps(h2), encoding="utf-8")
    r2 = correlate(lp, str(rp), None)
    if "M2_STABLE_CONTROL_clean_p_ge50" not in r2["mechanism"]["hits"]:
        print("FAIL STABLE clean p_ge50", r2["mechanism"], file=sys.stderr)
        return 1

    # RED: WANDER + high vfps + clean p_ge50 → M2 candidate but p_ge50 miss
    d3 = (
        "media: frames=240 vfps=23.9 pfps=23.9 wall_s=10.0 drops=11 "
        "publish_misses=0 pub_iv_p_ge50_w60=0.0050 pub_iv_disc_w60=CLEAN "
        "av_drift_ms=-40 audio_s=10.0\n"
        "media: frames=480 vfps=24.0 pfps=24.0 wall_s=20.0 drops=11 "
        "publish_misses=0 pub_iv_p_ge50_w60=0.0050 pub_iv_disc_w60=CLEAN "
        "av_drift_ms=-40 audio_s=20.0\n"
    )
    h3 = {"timing_class": "WANDER", "residual_rms_ms": 40.0, "detrended_max_abs_ms": 100.0, "n_pairs": 20}
    lp.write_text(d3, encoding="utf-8")
    rp.write_text(json.dumps(h3), encoding="utf-8")
    r3 = correlate(lp, str(rp), None)
    if "M2_PUBLISH_INTERVAL_JITTER_CANDIDATE" not in r3["mechanism"]["hits"]:
        print("FAIL M2 candidate on clean-pge WANDER", r3["mechanism"], file=sys.stderr)
        return 1
    if "M2_p_ge50_w60_clean_on_WANDER" not in r3["mechanism"]["misses"]:
        print("FAIL expected M2 p_ge50 clean miss", r3["mechanism"], file=sys.stderr)
        return 1
    print("CORRELATE_SELFTEST_OK M2_confirm M1_falsified STABLE_control M2_pge_miss")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--daemon-log", default="")
    ap.add_argument("--hdmi-report", default="")
    ap.add_argument("--hdmi-stdout", default="")
    ap.add_argument("--out-dir", default="")
    ap.add_argument("--soak-rc", type=int, default=0)
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    if not args.daemon_log:
        print("usage: --daemon-log PATH or --self-test", file=sys.stderr)
        return 2

    result = correlate(
        Path(args.daemon_log),
        args.hdmi_report or None,
        args.hdmi_stdout or None,
    )
    result["soak_rc"] = args.soak_rc

    text_lines = [
        "=== PAIR CORRELATION (daemon × HDMI same window) ===",
        f"prereg={result['prereg']}",
        f"daemon_n_media_lines={result['daemon']['n_media_lines']} src={result['daemon']['src']}",
        f"daemon_drop_event_lines={result['daemon']['n_drop_event_lines']}",
        f"vfps={result['daemon']['vfps']}",
        f"pfps={result['daemon']['pfps']}",
        f"drops={result['daemon']['drops']}",
        f"av_display_offset_ms={result['daemon']['av_display_offset_ms']}",
        f"av_drift_ms={result['daemon']['av_drift_ms']}  # servo only",
        f"publish_misses={result['daemon']['publish_misses']}",
        f"pub_iv_p_ge50_w60={result['daemon']['pub_iv_p_ge50_w60']}",
        f"pub_iv_max_ms_w60={result['daemon']['pub_iv_max_ms_w60']}",
        f"pub_iv_disc_w60={result['daemon']['pub_iv_disc_w60']}",
        f"gap_check={result['daemon']['vfps_pfps_gap_vs_drops']}",
        f"hdmi_src={result['hdmi']['src']} timing_class={result['hdmi']['timing_class']}",
        f"residual_rms_ms={result['hdmi']['residual_rms_ms']} "
        f"detrended_max_abs_ms={result['hdmi']['detrended_max_abs_ms']}",
        f"m1_status={result['mechanism'].get('m1_status')}",
        f"mechanism_verdict={result['mechanism']['verdict']}",
        f"mechanism_hits={result['mechanism']['hits']}",
        f"mechanism_misses={result['mechanism']['misses']}",
        f"mechanism_inputs={result['mechanism'].get('inputs')}",
    ]
    for nk in (
        "publish_misses_note",
        "av_display_offset_note",
        "pub_iv_note",
    ):
        if nk in result["daemon"]:
            text_lines.append(f"NOTE: {result['daemon'][nk]}")
    for n in result["notes"]:
        text_lines.append(f"NOTE: {n}")
    text = "\n".join(text_lines) + "\n"
    print(text, end="")

    if args.out_dir:
        od = Path(args.out_dir)
        od.mkdir(parents=True, exist_ok=True)
        (od / "pair_correlation.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        (od / "pair_correlation.txt").write_text(text, encoding="utf-8")

    d_ok = result["daemon"]["n_media_lines"] > 0
    h_ok = result["hdmi"]["src"] != "NO-DATA" and result["hdmi"].get("timing_class") is not None
    if not d_ok or not h_ok:
        print(
            f"VERDICT=UNSCORED rc=77 reason=missing_side daemon_ok={d_ok} hdmi_ok={h_ok}",
            file=sys.stderr,
        )
        return 77
    print(f"VERDICT={result['mechanism']['verdict']} rc=0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
