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

Daemon lines consumed (after parent deploys every-drop + cluster-axis patch)
---------------------------------------------------------------------------
  media: first_audio_pcm mono_ms=... wall_s=...|NO-DATA nbytes=... gate=closed|open
  media: A/V audio_release first_frame=... mono_ms=... wall_s=0.000 ...
  media: audio release ... held_ms=... mono_ms=... wall_s=... reason=...
  media: first_video_present wall_s=... mono_ms=... av_drift_ms=... frames=... presents=1
  media: A/V resync drop wall_s=... mono_ms=... drift_ms=... drops=... frames=... presents=...
  media: frames=... wall_s=... av_drift_ms=... presents=... drops=... residual=...

Cluster axis (parent HDMI offset clusters ~116 ms apart; av_drift_ms is BLIND)
------------------------------------------------------------------------------
Every run prints ONE block with three mono_ms values on the same axis:
  first_audio_pcm_mono_ms | audio_hold_release_mono_ms | first_video_present_mono_ms
plus deltas (ms). Absence is NO-DATA, never 0.0. wall_s is secondary (session-
relative; first_audio is usually pre-origin so wall_s=NO-DATA there).

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
    wall_s_raw: Optional[str] = None  # may be "NO-DATA"
    mono_ms: Optional[int] = None
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
    held_ms: Optional[float] = None
    gate: Optional[str] = None
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
    audio_release_mono_ms: Optional[int] = None
    audio_release_mono_ms_src: str = PROVENANCE_NO_DATA
    # Cluster axis (HDMI offset clusters ~116 ms; av_drift_ms is BLIND by design)
    first_audio_pcm_mono_ms: Optional[int] = None
    first_audio_pcm_mono_ms_src: str = PROVENANCE_NO_DATA
    first_audio_pcm_wall_s: Optional[float] = None
    first_audio_pcm_wall_s_src: str = PROVENANCE_NO_DATA
    first_audio_pcm_gate: Optional[str] = None
    first_video_mono_ms: Optional[int] = None
    first_video_mono_ms_src: str = PROVENANCE_NO_DATA
    av_audio_release_mono_ms: Optional[int] = None
    av_audio_release_mono_ms_src: str = PROVENANCE_NO_DATA
    av_audio_release_wall_s: Optional[float] = None
    av_audio_release_wall_s_src: str = PROVENANCE_NO_DATA
    # Preferred hold-release mono: pump "audio release" if present else A/V gate open
    hold_release_mono_ms: Optional[int] = None
    hold_release_mono_ms_src: str = PROVENANCE_NO_DATA
    hold_release_source: str = "NO-DATA"
    # Deltas on mono axis (ms). NO-DATA if either endpoint missing — never 0.0.
    delta_audio_pcm_to_video_ms: Optional[float] = None
    delta_audio_pcm_to_video_ms_src: str = PROVENANCE_NO_DATA
    delta_hold_release_to_video_ms: Optional[float] = None
    delta_hold_release_to_video_ms_src: str = PROVENANCE_NO_DATA
    delta_audio_pcm_to_hold_release_ms: Optional[float] = None
    delta_audio_pcm_to_hold_release_ms_src: str = PROVENANCE_NO_DATA
    audio_vs_video: str = "NO-DATA"
    cluster_axis: List[Dict[str, Any]] = field(default_factory=list)
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
    if "media: first_audio_pcm" in line:
        return "first_audio_pcm"
    if "media: A/V audio_release" in line or "ERROR media: A/V audio_release" in line:
        return "av_audio_release"
    if "media: audio release" in line or "ERROR media: audio release" in line:
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
    # wall_s may be the literal token NO-DATA (do not coerce to 0.0)
    if "wall_s" in kv:
        s.wall_s_raw = kv["wall_s"]
        if kv["wall_s"].upper() != "NO-DATA":
            s.wall_s = _f(kv, "wall_s")
    s.mono_ms = _i(kv, "mono_ms")
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
    s.held_ms = _f(kv, "held_ms")
    s.gate = kv.get("gate")
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
            rep.first_video_mono_ms = s.mono_ms
            rep.first_video_mono_ms_src = (
                PROVENANCE_MEASURED if s.mono_ms is not None else PROVENANCE_NO_DATA
            )
            break
    if rep.first_video_wall_s is None and rep.first_video_mono_ms is None:
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
                rep.first_video_mono_ms = s.mono_ms
                rep.first_video_mono_ms_src = (
                    PROVENANCE_MEASURED if s.mono_ms is not None else PROVENANCE_NO_DATA
                )
                rep.notes.append(
                    "first_video_present line absent — used first presents>=1 media line "
                    "(deploy daemon first_video_present log for hard edge)"
                )
                break

    # First audio PCM (pump input, usually pre-gate)
    for s in samples:
        if s.kind == "first_audio_pcm":
            rep.first_audio_pcm_mono_ms = s.mono_ms
            rep.first_audio_pcm_mono_ms_src = (
                PROVENANCE_MEASURED if s.mono_ms is not None else PROVENANCE_NO_DATA
            )
            rep.first_audio_pcm_wall_s = s.wall_s
            if s.wall_s is not None:
                rep.first_audio_pcm_wall_s_src = PROVENANCE_MEASURED
            elif s.wall_s_raw and s.wall_s_raw.upper() == "NO-DATA":
                rep.first_audio_pcm_wall_s_src = PROVENANCE_NO_DATA
            else:
                rep.first_audio_pcm_wall_s_src = PROVENANCE_NO_DATA
            rep.first_audio_pcm_gate = s.gate
            break

    # Video-thread gate open (A/V audio_release) — physical start / t0 latch
    for s in samples:
        if s.kind == "av_audio_release":
            rep.av_audio_release_mono_ms = s.mono_ms
            rep.av_audio_release_mono_ms_src = (
                PROVENANCE_MEASURED if s.mono_ms is not None else PROVENANCE_NO_DATA
            )
            rep.av_audio_release_wall_s = s.wall_s
            rep.av_audio_release_wall_s_src = (
                PROVENANCE_MEASURED if s.wall_s is not None else PROVENANCE_NO_DATA
            )
            break

    # Pump audio release (held PCM flush to MrAudio)
    for s in samples:
        if s.kind == "audio_release":
            kv = parse_kv(s.raw)
            held = s.held_ms if s.held_ms is not None else _f(kv, "held_ms")
            rep.audio_release_held_ms = held
            rep.audio_release_held_ms_src = (
                PROVENANCE_MEASURED if held is not None else PROVENANCE_NO_DATA
            )
            rep.audio_release_reason = kv.get("reason")
            rep.audio_release_mono_ms = s.mono_ms
            rep.audio_release_mono_ms_src = (
                PROVENANCE_MEASURED if s.mono_ms is not None else PROVENANCE_NO_DATA
            )
            if s.wall_s is not None:
                rep.audio_release_wall_s = s.wall_s
                rep.audio_release_wall_s_src = PROVENANCE_MEASURED
            else:
                rep.audio_release_wall_s = None
                rep.audio_release_wall_s_src = PROVENANCE_NO_DATA
                if not s.mono_ms:
                    rep.notes.append(
                        "audio release line has no wall_s/mono_ms — held_ms only; "
                        "wall_s=NO-DATA (not 0.0). Deploy cluster-axis daemon."
                    )
            break

    # Preferred hold-release endpoint for cluster: pump release mono, else gate open
    if rep.audio_release_mono_ms is not None:
        rep.hold_release_mono_ms = rep.audio_release_mono_ms
        rep.hold_release_mono_ms_src = PROVENANCE_MEASURED
        rep.hold_release_source = "audio_release_pump"
    elif rep.av_audio_release_mono_ms is not None:
        rep.hold_release_mono_ms = rep.av_audio_release_mono_ms
        rep.hold_release_mono_ms_src = PROVENANCE_MEASURED
        rep.hold_release_source = "av_audio_release_gate_open"
    else:
        rep.hold_release_mono_ms = None
        rep.hold_release_mono_ms_src = PROVENANCE_NO_DATA
        rep.hold_release_source = "NO-DATA"

    def _delta_ms(a: Optional[int], b: Optional[int]) -> Tuple[Optional[float], str]:
        if a is None or b is None:
            return None, PROVENANCE_NO_DATA
        return float(b - a), PROVENANCE_MEASURED

    rep.delta_audio_pcm_to_video_ms, rep.delta_audio_pcm_to_video_ms_src = _delta_ms(
        rep.first_audio_pcm_mono_ms, rep.first_video_mono_ms
    )
    rep.delta_hold_release_to_video_ms, rep.delta_hold_release_to_video_ms_src = _delta_ms(
        rep.hold_release_mono_ms, rep.first_video_mono_ms
    )
    rep.delta_audio_pcm_to_hold_release_ms, rep.delta_audio_pcm_to_hold_release_ms_src = (
        _delta_ms(rep.first_audio_pcm_mono_ms, rep.hold_release_mono_ms)
    )

    # Cluster axis block — always three slots, NO-DATA never coerced to 0
    rep.cluster_axis = [
        {
            "event": "first_audio_pcm",
            "mono_ms": rep.first_audio_pcm_mono_ms,
            "mono_ms_src": rep.first_audio_pcm_mono_ms_src,
            "wall_s": rep.first_audio_pcm_wall_s,
            "wall_s_src": rep.first_audio_pcm_wall_s_src,
            "gate": rep.first_audio_pcm_gate,
        },
        {
            "event": "audio_hold_release",
            "mono_ms": rep.hold_release_mono_ms,
            "mono_ms_src": rep.hold_release_mono_ms_src,
            "source": rep.hold_release_source,
            "held_ms": rep.audio_release_held_ms,
            "held_ms_src": rep.audio_release_held_ms_src,
            "wall_s": rep.audio_release_wall_s
            if rep.hold_release_source == "audio_release_pump"
            else rep.av_audio_release_wall_s,
            "wall_s_src": (
                rep.audio_release_wall_s_src
                if rep.hold_release_source == "audio_release_pump"
                else rep.av_audio_release_wall_s_src
            ),
        },
        {
            "event": "first_video_present",
            "mono_ms": rep.first_video_mono_ms,
            "mono_ms_src": rep.first_video_mono_ms_src,
            "wall_s": rep.first_video_wall_s,
            "wall_s_src": rep.first_video_wall_s_src,
            "av_drift_ms": rep.first_video_av_drift_ms,
            "av_drift_ms_src": rep.first_video_av_drift_ms_src,
            "note": "av_drift_ms is servo deadband readout, NOT HDMI accuracy",
        },
    ]

    # audio vs video ordering (prefer mono_ms; wall_s secondary)
    if (
        rep.hold_release_mono_ms is not None
        and rep.first_video_mono_ms is not None
    ):
        dv_ms = rep.first_video_mono_ms - rep.hold_release_mono_ms
        if abs(dv_ms) < 1:
            rep.audio_vs_video = "coincident_mono"
        elif dv_ms > 0:
            rep.audio_vs_video = f"hold_release_before_video_by_ms={dv_ms}"
        else:
            rep.audio_vs_video = f"video_before_hold_release_by_ms={-dv_ms}"
    elif (
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
    print("--- CLUSTER_AXIS (HDMI offset discriminator; av_drift BLIND) ---")
    for ev in rep.cluster_axis:
        print(
            f"  {ev.get('event')}: mono_ms={ev.get('mono_ms')} src={ev.get('mono_ms_src')} "
            f"wall_s={ev.get('wall_s')} wall_src={ev.get('wall_s_src')}"
            + (f" gate={ev.get('gate')}" if ev.get("gate") is not None else "")
            + (f" held_ms={ev.get('held_ms')}" if ev.get("held_ms") is not None else "")
            + (f" source={ev.get('source')}" if ev.get("source") is not None else "")
        )
    pv(
        "delta_audio_pcm_to_video_ms",
        rep.delta_audio_pcm_to_video_ms,
        rep.delta_audio_pcm_to_video_ms_src,
    )
    pv(
        "delta_audio_pcm_to_hold_release_ms",
        rep.delta_audio_pcm_to_hold_release_ms,
        rep.delta_audio_pcm_to_hold_release_ms_src,
    )
    pv(
        "delta_hold_release_to_video_ms",
        rep.delta_hold_release_to_video_ms,
        rep.delta_hold_release_to_video_ms_src,
    )
    pv("first_video_wall_s", rep.first_video_wall_s, rep.first_video_wall_s_src)
    pv("first_video_mono_ms", rep.first_video_mono_ms, rep.first_video_mono_ms_src)
    pv(
        "first_video_av_drift_ms",
        rep.first_video_av_drift_ms,
        rep.first_video_av_drift_ms_src,
    )
    pv("first_video_audio_s", rep.first_video_audio_s, rep.first_video_audio_s_src)
    pv(
        "first_audio_pcm_mono_ms",
        rep.first_audio_pcm_mono_ms,
        rep.first_audio_pcm_mono_ms_src,
    )
    pv("audio_release_wall_s", rep.audio_release_wall_s, rep.audio_release_wall_s_src)
    pv("audio_release_mono_ms", rep.audio_release_mono_ms, rep.audio_release_mono_ms_src)
    pv("audio_release_held_ms", rep.audio_release_held_ms, rep.audio_release_held_ms_src)
    print(f"audio_release_reason={rep.audio_release_reason}")
    print(f"hold_release_source={rep.hold_release_source}")
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

    # GREEN: synthetic startup with cluster axis + 5 per-drop lines + media
    # Cluster A: first_audio → video = 200 ms; Cluster B would be ~316 ms etc.
    lines = [
        "media: first_audio_pcm mono_ms=1000000 wall_s=NO-DATA nbytes=3840 gate=closed "
        "(cluster axis; pre-MrAudio)\n",
        "media: A/V audio_release first_frame=0 content_origin_ms=0 "
        "audio_bytes_at_release=0 mono_ms=1000200 wall_s=0.000 "
        "(MrAudio starts; held PCM from content t=0)\n",
        "media: audio release content_origin_ms=0 audio_bytes_at_release=0 "
        "held_bytes=48000 held_ms=250 reason=first_video_or_path "
        "mono_ms=1000205 wall_s=0.005\n",
        "media: first_video_present wall_s=0.020 mono_ms=1000220 av_drift_ms=-35 "
        "frames=1 presents=1 audio=on audio_s=0.25\n",
    ]
    for i, d in enumerate(range(1, 6), start=1):
        lines.append(
            f"media: A/V resync drop wall_s={0.05 + i * 0.1:.3f} mono_ms={1000300 + i * 100} "
            f"drift_ms={40 + i} drops={d} frames={d + 1} presents={1}\n"
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
        # Cluster axis: three mono_ms + deltas
        assert rep.first_audio_pcm_mono_ms == 1000000, rep
        assert rep.first_audio_pcm_wall_s is None, rep  # NO-DATA not 0.0
        assert rep.first_audio_pcm_wall_s_src == PROVENANCE_NO_DATA, rep
        assert rep.first_video_mono_ms == 1000220, rep
        assert rep.hold_release_mono_ms == 1000205, rep
        assert rep.hold_release_source == "audio_release_pump", rep
        assert rep.delta_audio_pcm_to_video_ms == 220.0, rep
        assert rep.delta_audio_pcm_to_video_ms_src == PROVENANCE_MEASURED, rep
        assert rep.delta_hold_release_to_video_ms == 15.0, rep
        assert len(rep.cluster_axis) == 3, rep.cluster_axis
        print("SELF_TEST synthetic startup SESSION_OK drop_events=5 cluster_axis OK")
    finally:
        os.unlink(path)

    # RED cluster: missing first_audio → deltas NO-DATA (never invent 0.0)
    thin = [
        "media: first_video_present wall_s=0.1 mono_ms=5000 av_drift_ms=-30 "
        "frames=1 presents=1 audio=off audio_s=0\n",
        "media: frames=50 wall_s=2.0 presents=40 drops=0 residual=10 av_drift_ms=-30\n",
        "media: frames=100 wall_s=4.0 presents=90 drops=0 residual=10 av_drift_ms=-30\n",
    ]
    with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as f:
        f.writelines(thin)
        path = f.name
    try:
        rep = analyze_samples(read_log_offline(Path(path)), hz_req=10.0, hz_src=PROVENANCE_CALLER)
        assert rep.rc == RC_OK, rep
        assert rep.first_audio_pcm_mono_ms is None, rep
        assert rep.delta_audio_pcm_to_video_ms is None, rep
        assert rep.delta_audio_pcm_to_video_ms_src == PROVENANCE_NO_DATA, rep
        assert rep.first_video_mono_ms == 5000, rep
        print("SELF_TEST missing first_audio → delta NO-DATA (not 0.0) OK")
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
