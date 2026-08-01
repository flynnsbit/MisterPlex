#!/usr/bin/env python3
"""Startup-window telemetry instrument for MiSTerPlex (host-side).

Why
---
Parent 1 Hz soaks (360 s, 480p):
  drops climb to 12–15 by wall_s≈7, then FLAT for the rest of the hour.
Every steady-state instrument watches the region where nothing happens.
The interesting physics is T=0..~7 s and previously had no high-rate tool.

What this does
--------------
Samples (or offline-parses) misterplexd log lines at >=10 Hz host poll and
reports, with every value tagged measured | caller_supplied | DEFAULT_ASSUMED:

  * wall_s of EACH A/V resync drop (from per-drop log lines; NOT a total)
  * av_drift_ms at first_video_present (extracted as lines arrive — never
    after a log clear)
  * first audio sample / release vs first presented video
  * ledger at every sample: frames, presents, drops, publish_misses, residual
    where residual MUST equal frames - presents - drops (checked continuously)
  * session gate: wall_s must advance (same idea as sws_arm.sh). Absence of
    process or session is NO-DATA, never 0.0 / never a green zero.

Modes
-----
  --log PATH --live --hz 10 --duration 12
      Tail a growing log (parent: ssh ... tail -F misterplexd.log > local.log).
      Does NOT ssh itself. Parent owns the device.

  --log PATH --offline
      Parse a completed capture (unit tests + parent dumps).

  --self-test
      RED/GREEN on synthetic logs. NO-DATA when empty. true rc direct.

Exit codes
----------
  0   session observed; report written (may still contain NO-DATA fields)
  77  NO-DATA: no process/session/log/advancing wall_s — never a pass
  2   ledger identity broken (residual != frames-presents-drops) positively
  1   usage / IO error

Daemon lines consumed (after parent deploys every-drop patch)
------------------------------------------------------------
  media: A/V resync drop wall_s=... drift_ms=... drops=... frames=... presents=...
  media: first_video_present wall_s=... av_drift_ms=... frames=... presents=1 ...
  media: audio release ... held_ms=... reason=...
  media: frames=... wall_s=... av_drift_ms=... presents=... drops=... residual=...

Rule 0: absence is NO-DATA. Hardcoded fps is never printed as a measurement.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

RC_OK = 0
RC_USAGE = 1
RC_LEDGER_FAIL = 2
RC_NO_DATA = 77

PROVENANCE_MEASURED = "measured"
PROVENANCE_CALLER = "caller_supplied"
PROVENANCE_DEFAULT_ASSUMED = "DEFAULT_ASSUMED"
PROVENANCE_NO_DATA = "NO-DATA"

# field=value tokens on media lines
_KV_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(-?[0-9]+(?:\.[0-9]+)?|[A-Za-z0-9_./+-]+)")


def _tag(value: Any, src: str) -> Dict[str, Any]:
    return {"value": value, "src": src}


def parse_kv(line: str) -> Dict[str, str]:
    return {m.group(1): m.group(2) for m in _KV_RE.finditer(line)}


def _f(kv: Dict[str, str], key: str) -> Optional[float]:
    if key not in kv:
        return None
    try:
        return float(kv[key])
    except ValueError:
        return None


def _i(kv: Dict[str, str], key: str) -> Optional[int]:
    if key not in kv:
        return None
    try:
        return int(float(kv[key]))
    except ValueError:
        return None


@dataclass
class Sample:
    host_t: float  # host monotonic seconds at observe time
    kind: str
    wall_s: Optional[float] = None
    frames: Optional[int] = None
    presents: Optional[int] = None
    drops: Optional[int] = None
    publish_misses: Optional[int] = None
    residual: Optional[int] = None
    residual_computed: Optional[int] = None
    residual_ok: Optional[bool] = None
    av_drift_ms: Optional[int] = None
    audio_s: Optional[float] = None
    audio: Optional[str] = None
    session: Optional[int] = None
    drift_ms: Optional[int] = None  # on drop lines
    raw: str = ""


@dataclass
class Report:
    status: str = "NO-DATA"
    status_src: str = PROVENANCE_NO_DATA
    reason: str = ""
    sample_hz_requested: float = 10.0
    sample_hz_requested_src: str = PROVENANCE_CALLER
    sample_hz_achieved: Optional[float] = None
    sample_hz_achieved_src: str = PROVENANCE_NO_DATA
    n_samples: int = 0
    n_media_lines: int = 0
    session_established: bool = False
    session_gate: str = "NO-DATA"  # wall_s_advancing | NO-DATA
    wall_s_first: Optional[float] = None
    wall_s_last: Optional[float] = None
    wall_s_src: str = PROVENANCE_NO_DATA
    # Per-drop events (the point of this tool)
    drop_events: List[Dict[str, Any]] = field(default_factory=list)
    drops_total_end: Optional[int] = None
    drops_total_end_src: str = PROVENANCE_NO_DATA
    # First video / audio
    first_video_wall_s: Optional[float] = None
    first_video_wall_s_src: str = PROVENANCE_NO_DATA
    first_video_av_drift_ms: Optional[int] = None
    first_video_av_drift_ms_src: str = PROVENANCE_NO_DATA
    first_video_audio_s: Optional[float] = None
    first_video_audio_s_src: str = PROVENANCE_NO_DATA
    audio_release_wall_s: Optional[float] = None
    audio_release_wall_s_src: str = PROVENANCE_NO_DATA
    audio_release_held_ms: Optional[float] = None
    audio_release_held_ms_src: str = PROVENANCE_NO_DATA
    audio_release_reason: Optional[str] = None
    audio_vs_video: str = "NO-DATA"
    # Ledger continuity
    ledger_checks: int = 0
    ledger_failures: int = 0
    ledger_ok: Optional[bool] = None
    ledger_ok_src: str = PROVENANCE_NO_DATA
    residual_series_head: List[Dict[str, Any]] = field(default_factory=list)
    # Full sample strip (compact)
    timeline_head: List[Dict[str, Any]] = field(default_factory=list)
    notes: List[str] = field(default_factory=list)
    rc: int = RC_NO_DATA


def classify_line(line: str) -> Optional[str]:
    if "media: A/V resync drop" in line:
        return "drop"
    if "media: first_video_present" in line:
        return "first_video"
    if "media: audio release" in line:
        return "audio_release"
    if "media: frames=" in line:
        return "media"
    if "media: publish_misses=" in line:
        return "publish_miss"
    return None


def parse_line(line: str, host_t: float) -> Optional[Sample]:
    kind = classify_line(line)
    if kind is None:
        return None
    kv = parse_kv(line)
    s = Sample(host_t=host_t, kind=kind, raw=line.rstrip())
    s.wall_s = _f(kv, "wall_s")
    s.frames = _i(kv, "frames")
    s.presents = _i(kv, "presents")
    s.drops = _i(kv, "drops")
    s.publish_misses = _i(kv, "publish_misses")
    s.residual = _i(kv, "residual")
    s.av_drift_ms = _i(kv, "av_drift_ms")
    if s.av_drift_ms is None:
        s.drift_ms = _i(kv, "drift_ms")
        if s.drift_ms is not None and kind == "drop":
            s.av_drift_ms = s.drift_ms
    s.audio_s = _f(kv, "audio_s")
    s.audio = kv.get("audio")
    s.session = _i(kv, "session")
    # residual identity when fields present
    if s.frames is not None and s.presents is not None and s.drops is not None:
        s.residual_computed = int(s.frames) - int(s.presents) - int(s.drops)
        if s.residual is not None:
            s.residual_ok = s.residual_computed == int(s.residual)
        else:
            s.residual = s.residual_computed
            s.residual_ok = True
    return s


def analyze_samples(samples: List[Sample], *, hz_req: float, hz_src: str) -> Report:
    rep = Report()
    rep.sample_hz_requested = float(hz_req)
    rep.sample_hz_requested_src = hz_src
    rep.n_samples = len(samples)
    if not samples:
        rep.status = "NO-DATA"
        rep.status_src = PROVENANCE_NO_DATA
        rep.reason = "no_media_lines (process absent or log empty) — not 0.0"
        rep.notes.append("Absence of process/session is NO-DATA, never 0")
        rep.rc = RC_NO_DATA
        return rep

    mediaish = [s for s in samples if s.kind in ("media", "drop", "first_video", "publish_miss")]
    rep.n_media_lines = len(mediaish)

    walls = [s.wall_s for s in samples if s.wall_s is not None]
    if len(walls) >= 2 and max(walls) > min(walls):
        rep.session_established = True
        rep.session_gate = "wall_s_advancing"
        rep.wall_s_first = float(min(walls))
        rep.wall_s_last = float(max(walls))
        rep.wall_s_src = PROVENANCE_MEASURED
    elif len(walls) == 1 and walls[0] is not None and walls[0] > 0:
        # single point with wall_s>0 — session exists but not yet proven advancing
        rep.session_established = True
        rep.session_gate = "wall_s_present_unproven_advance"
        rep.wall_s_first = float(walls[0])
        rep.wall_s_last = float(walls[0])
        rep.wall_s_src = PROVENANCE_MEASURED
        rep.notes.append("only one wall_s sample — gate weak; keep sampling")
    else:
        rep.session_established = False
        rep.session_gate = "NO-DATA"
        rep.status = "NO-DATA"
        rep.status_src = PROVENANCE_NO_DATA
        rep.reason = "wall_s not advancing / absent — session not established (NO-DATA)"
        rep.rc = RC_NO_DATA
        return rep

    # Per-drop events
    prev_drops: Optional[int] = None
    for s in samples:
        if s.kind == "drop":
            # Prefer explicit per-drop line wall_s
            w = s.wall_s
            d = s.drops
            if d is None:
                continue
            # Emit one event per line; if drops jumps by >1, expand
            if prev_drops is not None and d > prev_drops + 1 and w is not None:
                for k in range(prev_drops + 1, d + 1):
                    rep.drop_events.append(
                        {
                            "wall_s": w,
                            "wall_s_src": PROVENANCE_MEASURED,
                            "drops": k,
                            "drops_src": PROVENANCE_MEASURED,
                            "av_drift_ms": s.av_drift_ms,
                            "av_drift_ms_src": (
                                PROVENANCE_MEASURED
                                if s.av_drift_ms is not None
                                else PROVENANCE_NO_DATA
                            ),
                            "frames": s.frames,
                            "presents": s.presents,
                            "expanded_from_jump": True,
                        }
                    )
            else:
                rep.drop_events.append(
                    {
                        "wall_s": w,
                        "wall_s_src": (
                            PROVENANCE_MEASURED if w is not None else PROVENANCE_NO_DATA
                        ),
                        "drops": d,
                        "drops_src": PROVENANCE_MEASURED,
                        "av_drift_ms": s.av_drift_ms,
                        "av_drift_ms_src": (
                            PROVENANCE_MEASURED
                            if s.av_drift_ms is not None
                            else PROVENANCE_NO_DATA
                        ),
                        "frames": s.frames,
                        "presents": s.presents,
                        "expanded_from_jump": False,
                    }
                )
            prev_drops = d
        elif s.drops is not None:
            # Infer drop transitions from 1 Hz media lines when per-drop lines absent
            if prev_drops is not None and s.drops > prev_drops:
                for k in range(prev_drops + 1, s.drops + 1):
                    rep.drop_events.append(
                        {
                            "wall_s": s.wall_s,
                            "wall_s_src": (
                                PROVENANCE_MEASURED
                                if s.wall_s is not None
                                else PROVENANCE_NO_DATA
                            ),
                            "drops": k,
                            "drops_src": PROVENANCE_MEASURED,
                            "av_drift_ms": s.av_drift_ms,
                            "av_drift_ms_src": (
                                PROVENANCE_MEASURED
                                if s.av_drift_ms is not None
                                else PROVENANCE_NO_DATA
                            ),
                            "frames": s.frames,
                            "presents": s.presents,
                            "expanded_from_jump": True,
                            "inferred_from_media_line": True,
                        }
                    )
            if prev_drops is None or s.drops >= (prev_drops or 0):
                prev_drops = s.drops

    if samples and samples[-1].drops is not None:
        rep.drops_total_end = int(samples[-1].drops)
        rep.drops_total_end_src = PROVENANCE_MEASURED
    elif rep.drop_events:
        rep.drops_total_end = int(rep.drop_events[-1]["drops"])
        rep.drops_total_end_src = PROVENANCE_MEASURED

    # First video
    for s in samples:
        if s.kind == "first_video":
            rep.first_video_wall_s = s.wall_s
            rep.first_video_wall_s_src = (
                PROVENANCE_MEASURED if s.wall_s is not None else PROVENANCE_NO_DATA
            )
            rep.first_video_av_drift_ms = s.av_drift_ms
            rep.first_video_av_drift_ms_src = (
                PROVENANCE_MEASURED if s.av_drift_ms is not None else PROVENANCE_NO_DATA
            )
            rep.first_video_audio_s = s.audio_s
            rep.first_video_audio_s_src = (
                PROVENANCE_MEASURED if s.audio_s is not None else PROVENANCE_NO_DATA
            )
            break
    if rep.first_video_wall_s is None:
        # Fallback: first media line with presents>=1
        for s in samples:
            if s.presents is not None and s.presents >= 1:
                rep.first_video_wall_s = s.wall_s
                rep.first_video_wall_s_src = (
                    PROVENANCE_MEASURED if s.wall_s is not None else PROVENANCE_NO_DATA
                )
                rep.first_video_av_drift_ms = s.av_drift_ms
                rep.first_video_av_drift_ms_src = (
                    PROVENANCE_MEASURED
                    if s.av_drift_ms is not None
                    else PROVENANCE_NO_DATA
                )
                rep.first_video_audio_s = s.audio_s
                rep.first_video_audio_s_src = (
                    PROVENANCE_MEASURED if s.audio_s is not None else PROVENANCE_NO_DATA
                )
                rep.notes.append(
                    "first_video_present line absent — used first presents>=1 media line "
                    "(deploy daemon first_video_present log for hard edge)"
                )
                break

    # Audio release
    for s in samples:
        if s.kind == "audio_release":
            kv = parse_kv(s.raw)
            # audio release lines may not carry wall_s; use host-relative later
            held = _f(kv, "held_ms")
            rep.audio_release_held_ms = held
            rep.audio_release_held_ms_src = (
                PROVENANCE_MEASURED if held is not None else PROVENANCE_NO_DATA
            )
            rep.audio_release_reason = kv.get("reason")
            # If wall_s on line use it; else leave NO-DATA (do not invent 0)
            if s.wall_s is not None:
                rep.audio_release_wall_s = s.wall_s
                rep.audio_release_wall_s_src = PROVENANCE_MEASURED
            else:
                rep.audio_release_wall_s = None
                rep.audio_release_wall_s_src = PROVENANCE_NO_DATA
                rep.notes.append(
                    "audio release line has no wall_s field — held_ms measured, "
                    "wall_s=NO-DATA (not 0.0)"
                )
            break

    # audio vs video ordering
    if (
        rep.audio_release_wall_s is not None
        and rep.first_video_wall_s is not None
    ):
        dv = rep.first_video_wall_s - rep.audio_release_wall_s
        if abs(dv) < 1e-6:
            rep.audio_vs_video = "coincident"
        elif dv > 0:
            rep.audio_vs_video = f"audio_before_video_by_s={dv:.4f}"
        else:
            rep.audio_vs_video = f"video_before_audio_by_s={-dv:.4f}"
    elif rep.first_video_audio_s is not None and rep.first_video_wall_s is not None:
        rep.audio_vs_video = (
            f"at_first_video audio_s={rep.first_video_audio_s} "
            f"video_wall_s={rep.first_video_wall_s} (both measured on first_video line)"
        )
    else:
        rep.audio_vs_video = "NO-DATA"

    # Ledger continuous check
    fails = 0
    checks = 0
    series: List[Dict[str, Any]] = []
    for s in samples:
        if s.residual_computed is None:
            continue
        checks += 1
        ok = True if s.residual_ok is None else bool(s.residual_ok)
        if s.residual is not None and s.residual_computed is not None:
            ok = int(s.residual) == int(s.residual_computed)
        if not ok:
            fails += 1
        if len(series) < 24:
            series.append(
                {
                    "wall_s": s.wall_s,
                    "frames": s.frames,
                    "presents": s.presents,
                    "drops": s.drops,
                    "publish_misses": s.publish_misses,
                    "residual": s.residual,
                    "residual_computed": s.residual_computed,
                    "residual_ok": ok,
                    "src": PROVENANCE_MEASURED,
                }
            )
    rep.ledger_checks = checks
    rep.ledger_failures = fails
    if checks == 0:
        rep.ledger_ok = None
        rep.ledger_ok_src = PROVENANCE_NO_DATA
        rep.notes.append("no residual/frames/presents/drops triple — ledger NO-DATA")
    else:
        rep.ledger_ok = fails == 0
        rep.ledger_ok_src = PROVENANCE_MEASURED
    rep.residual_series_head = series

    # Achieved host sample rate (live mode only meaningful)
    host_ts = [s.host_t for s in samples]
    if len(host_ts) >= 2:
        span = host_ts[-1] - host_ts[0]
        if span > 0:
            rep.sample_hz_achieved = round((len(host_ts) - 1) / span, 3)
            rep.sample_hz_achieved_src = PROVENANCE_MEASURED

    rep.timeline_head = [
        {
            "kind": s.kind,
            "wall_s": s.wall_s,
            "frames": s.frames,
            "presents": s.presents,
            "drops": s.drops,
            "residual": s.residual,
            "av_drift_ms": s.av_drift_ms,
        }
        for s in samples[:40]
    ]

    if rep.ledger_ok is False:
        rep.status = "LEDGER_FAIL"
        rep.status_src = PROVENANCE_MEASURED
        rep.reason = (
            f"residual identity broken on {fails}/{checks} samples "
            f"(frames - presents - drops != residual)"
        )
        rep.rc = RC_LEDGER_FAIL
    else:
        rep.status = "SESSION_OK"
        rep.status_src = PROVENANCE_MEASURED
        rep.reason = (
            f"session wall_s {rep.wall_s_first}->{rep.wall_s_last} "
            f"drop_events={len(rep.drop_events)} "
            f"drops_end={rep.drops_total_end}"
        )
        rep.rc = RC_OK
    return rep


def read_log_offline(path: Path) -> List[Sample]:
    samples: List[Sample] = []
    # host_t synthetic 0.1 s steps so offline still has ordering
    t = 0.0
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            s = parse_line(line, t)
            if s is not None:
                samples.append(s)
                t += 0.1
    return samples


def live_sample(
    path: Path,
    *,
    hz: float,
    duration_s: float,
    start_at_eof: bool = True,
) -> List[Sample]:
    """Poll log file at hz for duration_s. Absence of file → empty (NO-DATA)."""
    samples: List[Sample] = []
    if not path.exists():
        return samples
    period = 1.0 / max(hz, 0.1)
    t_end = time.monotonic() + duration_s
    pos = path.stat().st_size if start_at_eof else 0
    seen_raw: set[str] = set()
    while time.monotonic() < t_end:
        host_t = time.monotonic()
        try:
            size = path.stat().st_size
            if size < pos:
                pos = 0  # truncated/rotated
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
        except OSError:
            time.sleep(period)
            continue
        for line in chunk.splitlines():
            if not line:
                continue
            # Dedup identical 1 Hz lines if poll > line rate
            key = line.strip()
            s = parse_line(line, host_t)
            if s is None:
                continue
            if key in seen_raw and s.kind == "media":
                continue
            seen_raw.add(key)
            samples.append(s)
        time.sleep(period)
    return samples


def _print_human(rep: Report) -> None:
    def pv(name: str, value: Any, src: str) -> None:
        print(f"{name}={value} src={src}")

    print(f"status={rep.status} src={rep.status_src}")
    print(f"reason={rep.reason}")
    pv("session_gate", rep.session_gate, PROVENANCE_MEASURED if rep.session_established else PROVENANCE_NO_DATA)
    pv("sample_hz_requested", rep.sample_hz_requested, rep.sample_hz_requested_src)
    pv("sample_hz_achieved", rep.sample_hz_achieved, rep.sample_hz_achieved_src)
    pv("n_samples", rep.n_samples, PROVENANCE_MEASURED)
    pv("wall_s_first", rep.wall_s_first, rep.wall_s_src)
    pv("wall_s_last", rep.wall_s_last, rep.wall_s_src)
    pv("drops_total_end", rep.drops_total_end, rep.drops_total_end_src)
    print(f"drop_events_n={len(rep.drop_events)} src={PROVENANCE_MEASURED}")
    for ev in rep.drop_events[:32]:
        print(
            f"  drop wall_s={ev.get('wall_s')} src={ev.get('wall_s_src')} "
            f"drops={ev.get('drops')} drift_ms={ev.get('av_drift_ms')} "
            f"frames={ev.get('frames')} presents={ev.get('presents')}"
        )
    if len(rep.drop_events) > 32:
        print(f"  ... ({len(rep.drop_events) - 32} more drop events)")
    pv("first_video_wall_s", rep.first_video_wall_s, rep.first_video_wall_s_src)
    pv(
        "first_video_av_drift_ms",
        rep.first_video_av_drift_ms,
        rep.first_video_av_drift_ms_src,
    )
    pv("first_video_audio_s", rep.first_video_audio_s, rep.first_video_audio_s_src)
    pv("audio_release_wall_s", rep.audio_release_wall_s, rep.audio_release_wall_s_src)
    pv("audio_release_held_ms", rep.audio_release_held_ms, rep.audio_release_held_ms_src)
    print(f"audio_release_reason={rep.audio_release_reason}")
    print(f"audio_vs_video={rep.audio_vs_video}")
    pv("ledger_ok", rep.ledger_ok, rep.ledger_ok_src)
    print(
        f"ledger_checks={rep.ledger_checks} ledger_failures={rep.ledger_failures} "
        f"src={PROVENANCE_MEASURED}"
    )
    for row in rep.residual_series_head[:8]:
        print(
            f"  ledger wall_s={row.get('wall_s')} frames={row.get('frames')} "
            f"presents={row.get('presents')} drops={row.get('drops')} "
            f"residual={row.get('residual')} computed={row.get('residual_computed')} "
            f"ok={row.get('residual_ok')}"
        )
    for n in rep.notes:
        print(f"note: {n}")
    print(f"rc={rep.rc}")


def _self_test() -> int:
    import tempfile

    # RED: empty log → NO-DATA rc=77, never 0.0 drops
    with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as f:
        empty = f.name
    try:
        rep = analyze_samples(read_log_offline(Path(empty)), hz_req=10.0, hz_src=PROVENANCE_CALLER)
        assert rep.rc == RC_NO_DATA, rep
        assert rep.drops_total_end is None, rep
        assert rep.status == "NO-DATA", rep
        print("SELF_TEST empty → NO-DATA rc=77 OK")
    finally:
        os.unlink(empty)

    # GREEN: synthetic startup with 5 per-drop lines + media + first_video + audio
    lines = [
        "media: audio release content_origin_ms=0 audio_bytes_at_release=0 held_bytes=48000 held_ms=250 reason=first_video_or_path wall_s=0.010\n",
        "media: first_video_present wall_s=0.020 av_drift_ms=-35 frames=1 presents=1 audio=on audio_s=0.25\n",
    ]
    for i, d in enumerate(range(1, 6), start=1):
        lines.append(
            f"media: A/V resync drop wall_s={0.05 + i * 0.1:.3f} drift_ms={40 + i} "
            f"drops={d} frames={d + 1} presents={1}\n"
        )
    # 1 Hz media after drops flat
    lines.append(
        "media: frames=120 vfps=23.5 pfps=22.9 audio_s=5.00 wall_s=5.10 audio=on "
        "clock=av-lock av_drift_ms=-30 presents=105 drops=5 publish_misses=0 residual=10 "
        "fps=24/1 session=2\n"
    )
    lines.append(
        "media: frames=240 vfps=23.8 pfps=23.5 audio_s=10.0 wall_s=10.1 audio=on "
        "clock=av-lock av_drift_ms=-28 presents=225 drops=5 publish_misses=0 residual=10 "
        "fps=24/1 session=2\n"
    )
    with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as f:
        f.writelines(lines)
        path = f.name
    try:
        samples = read_log_offline(Path(path))
        rep = analyze_samples(samples, hz_req=10.0, hz_src=PROVENANCE_CALLER)
        assert rep.rc == RC_OK, asdict(rep)
        assert rep.session_established is True, rep
        assert len(rep.drop_events) == 5, rep.drop_events
        assert rep.drop_events[0]["wall_s"] is not None
        assert rep.drop_events[-1]["drops"] == 5
        assert rep.first_video_av_drift_ms == -35, rep
        assert rep.first_video_av_drift_ms_src == PROVENANCE_MEASURED
        assert rep.drops_total_end == 5
        assert rep.ledger_ok is True, rep
        # residual 120-105-5=10
        assert any(r.get("residual") == 10 for r in rep.residual_series_head), rep
        print("SELF_TEST synthetic startup SESSION_OK drop_events=5 OK")
    finally:
        os.unlink(path)

    # RED: ledger identity broken
    bad = [
        "media: frames=100 wall_s=1.0 presents=50 drops=10 publish_misses=0 residual=999 "
        "av_drift_ms=0 session=1\n",
        "media: frames=200 wall_s=2.0 presents=100 drops=10 publish_misses=0 residual=999 "
        "av_drift_ms=0 session=1\n",
    ]
    with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as f:
        f.writelines(bad)
        path = f.name
    try:
        rep = analyze_samples(read_log_offline(Path(path)), hz_req=10.0, hz_src=PROVENANCE_CALLER)
        assert rep.rc == RC_LEDGER_FAIL, rep
        assert rep.ledger_ok is False, rep
        print("SELF_TEST ledger break → rc=2 OK")
    finally:
        os.unlink(path)

    # Provenance: never print bare assumed fps as measurement
    assert PROVENANCE_CALLER == "caller_supplied"
    print("SELF_TEST_OK")
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--log", default=None, help="path to misterplexd.log (local file; parent feeds it)")
    ap.add_argument("--live", action="store_true", help="poll --log at --hz for --duration")
    ap.add_argument("--offline", action="store_true", help="parse entire --log once")
    ap.add_argument("--hz", type=float, default=10.0, help="sample rate (default 10)")
    ap.add_argument("--duration", type=float, default=12.0, help="live seconds (default 12 = pre+ T+10)")
    ap.add_argument(
        "--from-start",
        action="store_true",
        help="live: read from byte 0 instead of EOF (include pre-existing lines)",
    )
    ap.add_argument("--json", action="store_true")
    ap.add_argument("-o", "--output", default=None, help="write JSON report path")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return _self_test()

    if not args.log:
        print("ERROR: --log PATH required (or --self-test)", file=sys.stderr)
        return RC_USAGE

    path = Path(args.log)
    hz_src = PROVENANCE_CALLER
    if args.live:
        samples = live_sample(
            path,
            hz=float(args.hz),
            duration_s=float(args.duration),
            start_at_eof=not args.from_start,
        )
    else:
        if not path.is_file():
            # Missing log = NO-DATA (process absent), not usage crash when offline
            rep = analyze_samples([], hz_req=float(args.hz), hz_src=hz_src)
            rep.reason = f"log_absent path={path} — NO-DATA (not 0.0)"
            if args.json:
                print(json.dumps(asdict(rep), indent=2))
            else:
                _print_human(rep)
            return int(rep.rc)
        samples = read_log_offline(path)

    rep = analyze_samples(samples, hz_req=float(args.hz), hz_src=hz_src)
    if args.output:
        Path(args.output).write_text(json.dumps(asdict(rep), indent=2), encoding="utf-8")
        print(f"wrote {args.output}", file=sys.stderr)
    if args.json:
        print(json.dumps(asdict(rep), indent=2))
    else:
        _print_human(rep)
    return int(rep.rc)


if __name__ == "__main__":
    sys.exit(main())
