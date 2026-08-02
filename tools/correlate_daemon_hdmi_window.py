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
    r"av_drift_ms|av_display_offset_ms|av_pipe_ahead_ms|audio_s)="
    r"(-?\d+(?:\.\d+)?)"
)


def parse_media_frames_line(line: str) -> dict[str, float] | None:
    if "media:" not in line or "frames=" not in line:
        return None
    if "A/V resync drop" in line:
        return None
    out: dict[str, float] = {}
    for m in RE_NUM.finditer(line):
        out[m.group(1)] = float(m.group(2))
    if "frames" not in out or "wall_s" not in out:
        return None
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
    """Pre-register bands from P480_THROUGHPUT_WANDER_PREREG.md — publish miss after live."""
    tc = hdmi.get("timing_class")
    vfps = daemon.get("vfps") or {}
    drops = daemon.get("drops") or {}
    v50 = vfps.get("p50")
    d_first = drops.get("first")
    d_last = drops.get("last")
    d_delta = None
    if d_first is not None and d_last is not None:
        d_delta = d_last - d_first

    out: dict[str, Any] = {
        "primary_pred": "UNDERPRODUCE_THEN_DROP",
        "secondary_pred": "PUBLISH_INTERVAL_JITTER",
        "hits": [],
        "misses": [],
        "verdict": "NO-DATA",
        "bands_src": "P480_THROUGHPUT_WANDER_PREREG.md",
    }
    if tc is None or v50 is None:
        out["verdict"] = "NO-DATA"
        return out

    wander = tc == "WANDER"
    stable = tc == "STABLE"

    # M1 bands
    m1 = False
    if wander and v50 <= 20.0 and d_delta is not None and d_delta >= 15:
        m1 = True
        out["hits"].append("M1_UNDERPRODUCE_THEN_DROP")
    elif wander and v50 >= 23.5 and (d_delta is None or d_delta <= 3):
        out["misses"].append("M1_expected_low_vfps_on_WANDER")
    elif stable and v50 >= 23.2 and (d_delta is None or d_delta <= 5):
        out["hits"].append("M1_STABLE_CONTROL_SHAPE")
    elif stable and v50 is not None and v50 <= 21.0:
        out["misses"].append("M1_STABLE_but_low_vfps")

    # M2: WANDER with healthy vfps (publish jitter suspected; interval lines separate)
    if wander and v50 is not None and v50 >= 23.2 and (d_delta is None or d_delta <= 5):
        out["hits"].append("M2_PUBLISH_INTERVAL_JITTER_CANDIDATE")
        out["misses"].append("M1_not_underproduce")

    if wander and not m1 and "M2_PUBLISH_INTERVAL_JITTER_CANDIDATE" not in out["hits"]:
        out["misses"].append("WANDER_unclassified_vs_M1_M2_bands")

    if out["hits"] and not any(x.startswith("M1_expected") or x.startswith("WANDER_unclass") for x in out["misses"]):
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
    ):
        daemon_sum[key] = series_stats(rows, key)

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
    # GREEN synthetic: WANDER + low vfps + rising drops → M1 hit
    dlog = (
        "media: frames=100 vfps=18.0 pfps=17.2 wall_s=10.0 drops=20 "
        "av_drift_ms=-39 av_display_offset_ms=200 publish_misses=0 residual=0 audio_s=8.0\n"
        "media: frames=280 vfps=17.5 pfps=16.8 wall_s=20.0 drops=45 "
        "av_drift_ms=-38 av_display_offset_ms=400 publish_misses=0 residual=0 audio_s=16.0\n"
        "media: A/V resync drop wall_s=12.0 drops=21 frames=120 presents=100\n"
    )
    hrep = {
        "timing_class": "WANDER",
        "residual_rms_ms": 46.41,
        "detrended_max_abs_ms": 224.2,
        "n_pairs": 20,
        "median_offset_ms_raw": -10.0,
    }
    td = Path(__file__).resolve().parent.parent / ".agent-work" / "w-geom" / "_pair_selftest"
    td.mkdir(parents=True, exist_ok=True)
    lp = td / "d.log"
    rp = td / "h.json"
    lp.write_text(dlog, encoding="utf-8")
    rp.write_text(json.dumps(hrep), encoding="utf-8")
    r = correlate(lp, str(rp), None)
    hits = r["mechanism"]["hits"]
    if "M1_UNDERPRODUCE_THEN_DROP" not in hits:
        print("FAIL self-test expected M1 hit", r["mechanism"], file=sys.stderr)
        return 1
    # STABLE high vfps control
    d2 = (
        "media: frames=240 vfps=23.9 pfps=23.8 wall_s=10.0 drops=12 "
        "av_drift_ms=-40 av_display_offset_ms=50 publish_misses=0 residual=0 audio_s=10.0\n"
        "media: frames=480 vfps=24.0 pfps=23.9 wall_s=20.0 drops=12 "
        "av_drift_ms=-39 av_display_offset_ms=40 publish_misses=0 residual=0 audio_s=20.0\n"
    )
    h2 = {"timing_class": "STABLE", "residual_rms_ms": 8.0, "detrended_max_abs_ms": 20.0, "n_pairs": 20}
    lp.write_text(d2, encoding="utf-8")
    rp.write_text(json.dumps(h2), encoding="utf-8")
    r2 = correlate(lp, str(rp), None)
    if "M1_STABLE_CONTROL_SHAPE" not in r2["mechanism"]["hits"]:
        print("FAIL self-test expected STABLE control", r2["mechanism"], file=sys.stderr)
        return 1
    # RED: WANDER + high vfps + no drops → M1 miss, M2 candidate
    d3 = (
        "media: frames=240 vfps=23.9 pfps=23.9 wall_s=10.0 drops=12 "
        "av_drift_ms=-40 av_display_offset_ms=40 publish_misses=0 residual=0 audio_s=10.0\n"
        "media: frames=480 vfps=24.0 pfps=24.0 wall_s=20.0 drops=12 "
        "av_drift_ms=-40 av_display_offset_ms=40 publish_misses=0 residual=0 audio_s=20.0\n"
    )
    h3 = {"timing_class": "WANDER", "residual_rms_ms": 40.0, "detrended_max_abs_ms": 100.0, "n_pairs": 20}
    lp.write_text(d3, encoding="utf-8")
    rp.write_text(json.dumps(h3), encoding="utf-8")
    r3 = correlate(lp, str(rp), None)
    if "M2_PUBLISH_INTERVAL_JITTER_CANDIDATE" not in r3["mechanism"]["hits"]:
        print("FAIL self-test expected M2 candidate", r3["mechanism"], file=sys.stderr)
        return 1
    if "M1_UNDERPRODUCE_THEN_DROP" in r3["mechanism"]["hits"]:
        print("FAIL self-test M1 must not hit on high vfps", r3["mechanism"], file=sys.stderr)
        return 1
    print("CORRELATE_SELFTEST_OK M1_hit STABLE_control M2_candidate")
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
        f"gap_check={result['daemon']['vfps_pfps_gap_vs_drops']}",
        f"hdmi_src={result['hdmi']['src']} timing_class={result['hdmi']['timing_class']}",
        f"residual_rms_ms={result['hdmi']['residual_rms_ms']} "
        f"detrended_max_abs_ms={result['hdmi']['detrended_max_abs_ms']}",
        f"mechanism_verdict={result['mechanism']['verdict']}",
        f"mechanism_hits={result['mechanism']['hits']}",
        f"mechanism_misses={result['mechanism']['misses']}",
        f"mechanism_inputs={result['mechanism'].get('inputs')}",
    ]
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
