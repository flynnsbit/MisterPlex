#!/usr/bin/env python3
"""Multi-session hold_wall_ms / held_ms stability gate (host-side).

Why
---
Parent measured n=8 HDMI offset clusters ~117 ms apart (A mean -314, B mean -197).
A single instrumented run showed hold_wall ≈ 120 ms — matching the cluster step.
av_drift_ms is BLIND to this (servo deadband). Nothing in-repo previously failed
when hold duration varied across identical sessions.

This gate FAILS when hold_wall_ms (preferred) or held_ms_content varies across
sessions beyond a caller-supplied max range. It does not invent green zeros:
absence of data is NO-DATA rc=77.

Inputs
------
  --sessions-json PATH   JSON list of per-session origin reports, OR
  --csv PATH             CSV with columns session_id,hold_wall_ms[,held_ms_content]
  --log PATH [PATH ...]  One or more misterplexd logs → extract via startup sampler
  --values MS MS ...     Caller-supplied measured values (tagged caller_supplied)

Threshold
---------
  --max-range-ms N   FAIL when (max-min) > N. Default 40 (design: half of the
                     measured ~117 ms cluster separation; not a measurement).
                     Labelled DEFAULT_ASSUMED unless --max-range-ms given
                     (then caller_supplied).

Exit codes
----------
  0   HOLD_STABLE — range within threshold, n_sessions >= min
  4   HOLD_VARIANCE_FAIL — positively measured range exceeds threshold
  77  NO-DATA — fewer than --min-sessions usable values (never a pass)
  1   usage

Rule 0: every printed value tagged measured | caller_supplied | DEFAULT_ASSUMED | NO-DATA.
true rc captured DIRECTLY by the parent (never through a pipe).
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

RC_OK = 0
RC_USAGE = 1
RC_VARIANCE_FAIL = 4
RC_NO_DATA = 77

PROVENANCE_MEASURED = "measured"
PROVENANCE_CALLER = "caller_supplied"
PROVENANCE_DEFAULT_ASSUMED = "DEFAULT_ASSUMED"
PROVENANCE_NO_DATA = "NO-DATA"

# Design bound: parent cluster separation ~117 ms; half is a tight stability band.
DEFAULT_MAX_RANGE_MS = 40.0
DEFAULT_MIN_SESSIONS = 3


def _tag(value: Any, src: str) -> Dict[str, Any]:
    return {"value": value, "src": src}


def extract_from_log(path: Path) -> Optional[Dict[str, Any]]:
    """Use startup_window_sample offline parse; return hold metrics or None."""
    # Import sibling tool
    here = Path(__file__).resolve().parent
    if str(here) not in sys.path:
        sys.path.insert(0, str(here))
    import startup_window_sample as sws  # type: ignore

    samples = sws.read_log_offline(path)
    rep = sws.analyze_samples(samples, hz_req=10.0, hz_src=PROVENANCE_CALLER)
    if rep.rc == sws.RC_NO_DATA:
        return None
    # Prefer hold_wall_ms (first_audio→release wall); fall back to held_ms_content
    val = rep.hold_wall_ms
    src = rep.hold_wall_ms_src
    kind = "hold_wall_ms"
    if val is None:
        val = rep.held_ms_content
        src = rep.held_ms_content_src
        kind = "held_ms_content"
    if val is None:
        return None
    return {
        "session": path.name,
        "value_ms": float(val),
        "value_src": src if src == PROVENANCE_MEASURED else src,
        "metric": kind,
        "hold_wall_ms": rep.hold_wall_ms,
        "hold_wall_ms_src": rep.hold_wall_ms_src,
        "held_ms_content": rep.held_ms_content,
        "held_ms_content_src": rep.held_ms_content_src,
        "first_audio_pcm_mono_ms": rep.first_audio_pcm_mono_ms,
        "hold_release_mono_ms": rep.hold_release_mono_ms,
        "since_audio_release_ms": rep.since_audio_release_ms,
        "log": str(path),
    }


def load_sessions_json(path: Path) -> List[Dict[str, Any]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(data, dict) and "sessions" in data:
        data = data["sessions"]
    if not isinstance(data, list):
        raise ValueError("sessions JSON must be a list or {sessions:[...]}")
    out: List[Dict[str, Any]] = []
    for i, row in enumerate(data):
        if not isinstance(row, dict):
            raise ValueError(f"session[{i}] not an object")
        # accept hold_wall_ms or held_ms or value_ms
        val = row.get("hold_wall_ms", row.get("held_ms", row.get("value_ms")))
        if val is None:
            continue
        out.append(
            {
                "session": str(row.get("session", row.get("id", i))),
                "value_ms": float(val),
                "value_src": str(
                    row.get("src", row.get("value_src", PROVENANCE_CALLER))
                ),
                "metric": str(row.get("metric", "hold_wall_ms")),
                "raw": row,
            }
        )
    return out


def load_csv(path: Path) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    with open(path, newline="", encoding="utf-8") as f:
        r = csv.DictReader(f)
        for i, row in enumerate(r):
            val = row.get("hold_wall_ms") or row.get("held_ms") or row.get("value_ms")
            if val is None or str(val).strip() == "":
                continue
            out.append(
                {
                    "session": str(row.get("session_id") or row.get("session") or i),
                    "value_ms": float(val),
                    "value_src": str(row.get("src") or PROVENANCE_CALLER),
                    "metric": "hold_wall_ms"
                    if row.get("hold_wall_ms")
                    else ("held_ms" if row.get("held_ms") else "value_ms"),
                }
            )
    return out


def analyze(
    sessions: List[Dict[str, Any]],
    *,
    max_range_ms: float,
    max_range_src: str,
    min_sessions: int,
    min_sessions_src: str,
) -> Dict[str, Any]:
    values = [float(s["value_ms"]) for s in sessions]
    n = len(values)
    rep: Dict[str, Any] = {
        "n_sessions": _tag(n, PROVENANCE_MEASURED),
        "min_sessions_required": _tag(min_sessions, min_sessions_src),
        "max_range_ms_threshold": _tag(max_range_ms, max_range_src),
        "sessions": sessions,
        "values_ms": _tag(values, PROVENANCE_MEASURED if values else PROVENANCE_NO_DATA),
    }
    if n < min_sessions:
        rep["status"] = "NO-DATA"
        rep["status_src"] = PROVENANCE_NO_DATA
        rep["reason"] = (
            f"n_sessions={n} < min_sessions={min_sessions} — "
            "absence is NO-DATA, never a green zero"
        )
        rep["range_ms"] = _tag(None, PROVENANCE_NO_DATA)
        rep["min_ms"] = _tag(None, PROVENANCE_NO_DATA)
        rep["max_ms"] = _tag(None, PROVENANCE_NO_DATA)
        rep["mean_ms"] = _tag(None, PROVENANCE_NO_DATA)
        rep["verdict"] = "NO-DATA"
        rep["rc"] = RC_NO_DATA
        return rep

    vmin = min(values)
    vmax = max(values)
    vrange = vmax - vmin
    vmean = sum(values) / n
    rep["min_ms"] = _tag(round(vmin, 3), PROVENANCE_MEASURED)
    rep["max_ms"] = _tag(round(vmax, 3), PROVENANCE_MEASURED)
    rep["range_ms"] = _tag(round(vrange, 3), PROVENANCE_MEASURED)
    rep["mean_ms"] = _tag(round(vmean, 3), PROVENANCE_MEASURED)

    if vrange > max_range_ms:
        rep["status"] = "HOLD_VARIANCE_FAIL"
        rep["status_src"] = PROVENANCE_MEASURED
        rep["reason"] = (
            f"hold range_ms={vrange:.3f} > max_range_ms={max_range_ms} "
            f"(min={vmin:.3f} max={vmax:.3f} n={n}) — cluster-class instability"
        )
        rep["verdict"] = "HOLD_VARIANCE_FAIL"
        rep["rc"] = RC_VARIANCE_FAIL
    else:
        rep["status"] = "HOLD_STABLE"
        rep["status_src"] = PROVENANCE_MEASURED
        rep["reason"] = (
            f"hold range_ms={vrange:.3f} <= max_range_ms={max_range_ms} "
            f"(min={vmin:.3f} max={vmax:.3f} n={n})"
        )
        rep["verdict"] = "HOLD_STABLE"
        rep["rc"] = RC_OK
    return rep


def _print_human(rep: Dict[str, Any]) -> None:
    def pv(name: str, cell: Any) -> None:
        if isinstance(cell, dict) and "value" in cell and "src" in cell:
            print(f"{name}={cell['value']} src={cell['src']}")
        else:
            print(f"{name}={cell}")

    print(f"status={rep.get('status')} src={rep.get('status_src')}")
    print(f"verdict={rep.get('verdict')} rc={rep.get('rc')}")
    print(f"reason={rep.get('reason')}")
    pv("n_sessions", rep.get("n_sessions"))
    pv("min_sessions_required", rep.get("min_sessions_required"))
    pv("max_range_ms_threshold", rep.get("max_range_ms_threshold"))
    pv("min_ms", rep.get("min_ms"))
    pv("max_ms", rep.get("max_ms"))
    pv("range_ms", rep.get("range_ms"))
    pv("mean_ms", rep.get("mean_ms"))
    print(f"values_ms={rep.get('values_ms')}")
    for s in rep.get("sessions") or []:
        print(
            f"  session={s.get('session')} value_ms={s.get('value_ms')} "
            f"src={s.get('value_src')} metric={s.get('metric')}"
        )


def _self_test() -> int:
    import tempfile

    # RED: empty → NO-DATA 77
    rep = analyze(
        [],
        max_range_ms=DEFAULT_MAX_RANGE_MS,
        max_range_src=PROVENANCE_DEFAULT_ASSUMED,
        min_sessions=DEFAULT_MIN_SESSIONS,
        min_sessions_src=PROVENANCE_DEFAULT_ASSUMED,
    )
    assert rep["rc"] == RC_NO_DATA, rep
    assert rep["range_ms"]["value"] is None, rep
    print("SELF_TEST empty → NO-DATA rc=77 OK")

    # RED: variance across sessions (parent cluster step scale)
    # 120 vs 200 vs 125 → range 80 > 40
    sess = [
        {"session": "r1", "value_ms": 120.0, "value_src": PROVENANCE_MEASURED, "metric": "hold_wall_ms"},
        {"session": "r2", "value_ms": 200.0, "value_src": PROVENANCE_MEASURED, "metric": "hold_wall_ms"},
        {"session": "r3", "value_ms": 125.0, "value_src": PROVENANCE_MEASURED, "metric": "hold_wall_ms"},
        {"session": "r4", "value_ms": 118.0, "value_src": PROVENANCE_MEASURED, "metric": "hold_wall_ms"},
    ]
    rep = analyze(
        sess,
        max_range_ms=40.0,
        max_range_src=PROVENANCE_CALLER,
        min_sessions=3,
        min_sessions_src=PROVENANCE_CALLER,
    )
    assert rep["rc"] == RC_VARIANCE_FAIL, rep
    assert rep["verdict"] == "HOLD_VARIANCE_FAIL", rep
    assert abs(rep["range_ms"]["value"] - 82.0) < 0.01, rep
    assert rep["rc"] != RC_NO_DATA, "measured FAIL must never decay to 77"
    print("SELF_TEST variance RED → HOLD_VARIANCE_FAIL rc=4 OK")

    # GREEN: tight cluster
    tight = [
        {"session": f"r{i}", "value_ms": v, "value_src": PROVENANCE_MEASURED, "metric": "hold_wall_ms"}
        for i, v in enumerate([118.0, 120.0, 119.0, 121.0, 120.5])
    ]
    rep = analyze(
        tight,
        max_range_ms=40.0,
        max_range_src=PROVENANCE_CALLER,
        min_sessions=3,
        min_sessions_src=PROVENANCE_CALLER,
    )
    assert rep["rc"] == RC_OK, rep
    assert rep["verdict"] == "HOLD_STABLE", rep
    assert rep["range_ms"]["value"] <= 40.0, rep
    print("SELF_TEST tight GREEN → HOLD_STABLE rc=0 OK")

    # n=2 < min=3 → NO-DATA even if values differ (do not under-claim)
    rep = analyze(
        sess[:2],
        max_range_ms=40.0,
        max_range_src=PROVENANCE_CALLER,
        min_sessions=3,
        min_sessions_src=PROVENANCE_CALLER,
    )
    assert rep["rc"] == RC_NO_DATA, rep
    print("SELF_TEST n=2 < min=3 → NO-DATA rc=77 OK")

    # Log path: synthetic daemon lines → extract hold_wall_ms=120
    lines = [
        "media: first_audio_pcm mono_ms=1000 wall_s=NO-DATA nbytes=3840 gate=closed tag=measured\n",
        "media: A/V audio_release first_frame=0 content_origin_ms=0 "
        "audio_bytes_at_release=0 mono_ms=1120 wall_s=0.000 held_ms=0 "
        "hold_wall_ms=120 tag=measured\n",
        "media: first_video_present wall_s=0.02 mono_ms=1140 "
        "since_first_audio_pcm_ms=140 since_audio_release_ms=20 "
        "av_drift_ms=20 frames=1 presents=1 tag=measured\n",
        "media: frames=50 wall_s=2.0 presents=40 drops=0 residual=10 av_drift_ms=20\n",
        "media: frames=100 wall_s=4.0 presents=90 drops=0 residual=10 av_drift_ms=20\n",
    ]
    with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as f:
        f.writelines(lines)
        p = Path(f.name)
    try:
        row = extract_from_log(p)
        assert row is not None, row
        assert row["value_ms"] == 120.0, row
        assert row["metric"] == "hold_wall_ms", row
        print("SELF_TEST log extract hold_wall_ms=120 OK")
    finally:
        p.unlink()

    # Provenance tags present
    assert PROVENANCE_CALLER == "caller_supplied"
    assert DEFAULT_MAX_RANGE_MS == 40.0
    print("SELF_TEST_OK")
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--sessions-json", default=None, help="JSON list of sessions")
    ap.add_argument("--csv", default=None, help="CSV session_id,hold_wall_ms")
    ap.add_argument(
        "--log",
        nargs="*",
        default=None,
        help="one or more misterplexd logs (extract hold_wall_ms)",
    )
    ap.add_argument(
        "--values",
        nargs="*",
        type=float,
        default=None,
        help="caller-supplied measured hold_wall_ms values",
    )
    ap.add_argument(
        "--max-range-ms",
        type=float,
        default=None,
        help=f"FAIL if max-min exceeds this (default {DEFAULT_MAX_RANGE_MS} DEFAULT_ASSUMED)",
    )
    ap.add_argument(
        "--min-sessions",
        type=int,
        default=None,
        help=f"minimum sessions to score (default {DEFAULT_MIN_SESSIONS} DEFAULT_ASSUMED)",
    )
    ap.add_argument("--json", action="store_true")
    ap.add_argument("-o", "--output", default=None)
    args = ap.parse_args(list(argv) if argv is not None else None)

    if args.self_test:
        return _self_test()

    if args.max_range_ms is None:
        max_range = DEFAULT_MAX_RANGE_MS
        max_src = PROVENANCE_DEFAULT_ASSUMED
    else:
        max_range = float(args.max_range_ms)
        max_src = PROVENANCE_CALLER

    if args.min_sessions is None:
        min_sess = DEFAULT_MIN_SESSIONS
        min_src = PROVENANCE_DEFAULT_ASSUMED
    else:
        min_sess = int(args.min_sessions)
        min_src = PROVENANCE_CALLER

    sessions: List[Dict[str, Any]] = []
    try:
        if args.sessions_json:
            sessions.extend(load_sessions_json(Path(args.sessions_json)))
        if args.csv:
            sessions.extend(load_csv(Path(args.csv)))
        if args.log:
            for lp in args.log:
                row = extract_from_log(Path(lp))
                if row is not None:
                    sessions.append(row)
        if args.values:
            for i, v in enumerate(args.values):
                sessions.append(
                    {
                        "session": f"value_{i}",
                        "value_ms": float(v),
                        "value_src": PROVENANCE_CALLER,
                        "metric": "hold_wall_ms",
                    }
                )
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return RC_USAGE

    if not (
        args.sessions_json or args.csv or args.log or args.values is not None
    ):
        print(
            "ERROR: provide --sessions-json / --csv / --log / --values (or --self-test)",
            file=sys.stderr,
        )
        return RC_USAGE

    rep = analyze(
        sessions,
        max_range_ms=max_range,
        max_range_src=max_src,
        min_sessions=min_sess,
        min_sessions_src=min_src,
    )
    if args.output:
        Path(args.output).write_text(json.dumps(rep, indent=2), encoding="utf-8")
        print(f"wrote {args.output}", file=sys.stderr)
    if args.json:
        print(json.dumps(rep, indent=2))
    else:
        _print_human(rep)
    return int(rep["rc"])


if __name__ == "__main__":
    sys.exit(main())
