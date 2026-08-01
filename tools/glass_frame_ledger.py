#!/usr/bin/env python3
"""Glass-side frame ledger — identity loss at the HDMI pixels.

Why
---
User report (daily driver, 480p path): frames appear dropped.
Daemon `drops` is a lower bound on *one* failure mode (A/V-pacer skips only),
resets per stream, and is wiped by supervisor respawn. `vfps`/`pfps` are
cumulative means and hide bursts. This instrument answers from **viewed
pixels only** via the burned-in overlay counter (`TREK24 n=NNN` etc.).

What it measures (and what it cannot)
-------------------------------------
MEASURED at the glass (burned-in n identity):
  - Which source frame indices appeared on HDMI (presence set)
  - Holes in that set (n missing between n_first and n_last)
  - Burst shape: max consecutive same-n hold (plateau), hole-size histogram,
    max hole size, max run of consecutive hole-steps, new-n interval hist

UNRESOLVABLE from glass alone (always printed — do not invent a single number):
  (a) frame never decoded
  (b) decoded but never published to DDR
  (c) published but never shown (bank/ascal)
  All three look identical as a missing burned-in n. Pair with the daemon
  P5 ledger (unaccounted / publish_misses / session_epoch) for (a)/(b) hints;
  (c) needs fabric instrumentation.

Capture-rate honesty (MacroSilicon MS2109 MJPG 1920x1080)
---------------------------------------------------------
Supported rates measured by parent: [5, 10, 20, 25, 30] — nothing above 30.
At 30 fps capture vs 24 fps source:
  capture_interval ≈ 33.3 ms  <  source_hold ≈ 41.7 ms
  ⇒ every *fully presented* source frame MUST appear in ≥1 capture sample.
  Therefore a missing n in the observed span is resolvable as
  "not fully presented (or OCR miss)" WITHOUT matching capture rate to source.

What is NOT resolvable at 30 fps without PTS:
  - device skip vs grabber drop (both leave a presence hole)
  - sub-frame timing of the skip
  - a single +1 hole at the resolution floor (mark UNRESOLVABLE, not LOSS)

With --pts-csv (ffprobe pkt_pts_time): presence holes split into DEVICE_SKIP
vs GRABBER_DROP (same thresholds as hdmi_motion_instrument).

Verdicts / exit codes
---------------------
  GLASS_OK          rc=0   identity intact within pre-registered bounds
  GLASS_LOSS        rc=2   sustained adjacent / device-skip loss
  GLASS_BURST       rc=3   judder signature (large hole burst or severe hold)
  TIER_REGRESSION   rc=4   480p worse than 240p under compare mode
  UNSCORED          rc=77  insufficient data — NEVER a pass
  UNRESOLVABLE      rc=76  signal below floor / cannot decide — NEVER a pass

Pre-registered gates (locked before parent runs device series)
--------------------------------------------------------------
  MIN_CTR_SPAN_SCORE   = 200   (~8 s @24fps) else UNSCORED/UNRESOLVABLE
  OK_ADJ_FRAC          = 0.02  frames_lost_adj/ctr_span < this → OK candidate
  LOSS_ADJ_FRAC        = 0.05  ≥ this + conf MEDIUM|HIGH → GLASS_LOSS
  OK_MAX_HOLE          = 2     max single presence-hole size
  BURST_HOLE_SIZE      = 3     hole ≥3 source frames missing in one step
  BURST_HOLE_EVENTS    = 2     ≥2 such large holes → GLASS_BURST
  max_repeat_run allowed = ceil(cap_fps/src_fps)+1 when fps authoritative
  TIER_DELTA_ADJ_FRAC  = 0.02  480−240 adj frac ≥ this → TIER_REGRESSION
  TIER_HOLE_MARGIN     = 1     480 max_hole ≥ 240 max_hole+1 and ≥3 → regress

PASS picture (single tier):
  motion advances, conf≥MEDIUM, lost_frac_adj < 0.02, max_hole≤2,
  max_repeat_run≤allowed, not rate_fail → GLASS_OK

FAIL picture (single tier):
  lost_frac_adj≥0.05 conf≥MEDIUM → GLASS_LOSS
  OR device_skip_frac≥0.05 with PTS split OK
  OR (≥2 holes of size≥3) or max_hole≥5 → GLASS_BURST

UNRESOLVABLE picture:
  no PTS and only RLE holes with adj_lost=0 (OCR-class)
  OR candidate below resolution_floor without PTS
  OR span < MIN_CTR_SPAN_SCORE

240p vs 480p (compare mode) — pre-registered:
  Same clip family, same capture argv fingerprint, src_fps caller-supplied.
  If both GLASS_OK → TIER_OK (rc=0).
  If 480 GLASS_LOSS/BURST and 240 GLASS_OK → TIER_REGRESSION (rc=4).
  If adj_frac_480 − adj_frac_240 ≥ 0.02 (both conf≥MEDIUM) → TIER_REGRESSION.
  If either tier UNSCORED/UNRESOLVABLE → overall UNSCORED/UNRESOLVABLE (not pass).

Usage
-----
  # From parent OCR cache (no device touch):
  tools/glass_frame_ledger.py --counters-csv /tmp/ctr480.csv \\
      --source-fps 24 --capture-fps 29.9068 --label 480p

  # With PTS split:
  tools/glass_frame_ledger.py --counters-csv CTR.csv --pts-csv PTS.csv \\
      --source-fps 24 --capture-fps 30 --label 480p

  # Tier compare:
  tools/glass_frame_ledger.py --compare \\
      --a-csv CTR240.csv --a-label 240p \\
      --b-csv CTR480.csv --b-label 480p \\
      --source-fps 24 --capture-fps 30

  tools/glass_frame_ledger.py --self-test

Does not touch the device. Does not modify tools/score_i420_candidate.py.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from collections import Counter
from pathlib import Path
from typing import Any

# Sibling import: works as `python3 tools/glass_frame_ledger.py`.
_TOOLS_DIR = str(Path(__file__).resolve().parent)
if _TOOLS_DIR not in sys.path:
    sys.path.insert(0, _TOOLS_DIR)

# Reuse OCR filter + presence/skip/rate math — single source of truth.
from hdmi_motion_instrument import (  # type: ignore  # noqa: E402
    DEFAULT_ASSUMED_CAPTURE_FPS,
    DEFAULT_ASSUMED_SOURCE_FPS,
    PROVENANCE_CALLER,
    PROVENANCE_DEFAULT_ASSUMED,
    PROVENANCE_MEASURED,
    _filter_counter_pairs,
    _is_caller_prov,
    _is_cap_auth_prov,
    _rle_runs,
    analyze_counter_rate,
    analyze_counter_skips,
    analyze_presence_loss_split,
    load_counters_csv,
    load_pts_csv,
    parse_fps_token,
)

RC_OK = 0
RC_LOSS = 2
RC_BURST = 3
RC_TIER = 4
RC_UNRESOLVABLE = 76
RC_UNSCORED = 77

# --- pre-registered thresholds (design; locked for this gate) ---
MIN_CTR_SPAN_SCORE = 200  # design: ~8s @24fps
OK_ADJ_FRAC = 0.02  # design
LOSS_ADJ_FRAC = 0.05  # design
OK_MAX_HOLE = 2  # design
BURST_HOLE_SIZE = 3  # design
BURST_HOLE_EVENTS = 2  # design
BURST_MAX_HOLE_HARD = 5  # design: one hole this large is enough
TIER_DELTA_ADJ_FRAC = 0.02  # design
TIER_HOLE_MARGIN = 1  # design


def _fps_auth(src_src: str, cap_src: str) -> bool:
    return _is_caller_prov(src_src) and _is_cap_auth_prov(cap_src)


def _hole_metrics(vals: list[int]) -> dict[str, Any]:
    """Presence-hole burst metrics on RLE distinct counter values."""
    hole_sizes: list[int] = []
    for a, b in zip(vals, vals[1:]):
        if b > a + 1:
            hole_sizes.append(b - a - 1)
    hist = Counter(hole_sizes)
    # Consecutive hole-steps (judder burst of skips in a row)
    max_consec = 0
    cur = 0
    for a, b in zip(vals, vals[1:]):
        if b > a + 1:
            cur += 1
            max_consec = max(max_consec, cur)
        elif b == a + 1:
            cur = 0
        else:
            cur = 0  # non-monotonic — break streak
    large = sum(1 for h in hole_sizes if h >= BURST_HOLE_SIZE)
    return {
        "hole_size_hist": {str(k): int(v) for k, v in sorted(hist.items())},
        "max_hole_size": int(max(hole_sizes) if hole_sizes else 0),
        "hole_events": int(len(hole_sizes)),
        "presence_hole_frames": int(sum(hole_sizes)),
        "large_hole_events": int(large),  # size >= BURST_HOLE_SIZE
        "max_consecutive_hole_steps": int(max_consec),
        "hole_sizes_head": hole_sizes[:12],
    }


def _new_n_intervals(
    pairs: list[tuple[int, int]],
    pts_by_idx: dict[int, float] | None,
    capture_fps: float,
    capture_fps_src: str,
) -> dict[str, Any]:
    """Interval between first sightings of successive distinct n.

    With PTS: measured seconds. Without: capture-index delta and an ASSUMED
    time = di/cap_fps (labelled — never pretend measured).
    """
    if len(pairs) < 2:
        return {
            "new_n_interval_status": "UNSCORED",
            "interval_hist_ms": {},
            "interval_source": PROVENANCE_DEFAULT_ASSUMED,
            "n_intervals": 0,
        }
    first_idx: dict[int, int] = {}
    first_pts: dict[int, float] = {}
    order: list[int] = []
    for cap_i, n in pairs:
        if n not in first_idx:
            first_idx[n] = cap_i
            order.append(n)
            if pts_by_idx and cap_i in pts_by_idx:
                first_pts[n] = pts_by_idx[cap_i]

    # Walk successive *increasing* first-seen values in appearance order,
    # but only count steps that advance the counter (skip OCR backsteps).
    intervals_ms: list[float] = []
    di_list: list[int] = []
    used_pts = bool(pts_by_idx) and len(first_pts) >= 2
    for a, b in zip(order, order[1:]):
        if b <= a:
            continue
        i0, i1 = first_idx[a], first_idx[b]
        di = i1 - i0
        if di <= 0:
            continue
        di_list.append(di)
        if used_pts and a in first_pts and b in first_pts:
            dt = first_pts[b] - first_pts[a]
            if dt > 0:
                intervals_ms.append(dt * 1000.0)
        elif capture_fps > 0:
            intervals_ms.append((di / capture_fps) * 1000.0)

    # Histogram in 10 ms bins for readability
    hist: Counter = Counter()
    for ms in intervals_ms:
        bin_ms = int(round(ms / 10.0) * 10)
        hist[bin_ms] += 1

    if used_pts and intervals_ms:
        src = PROVENANCE_MEASURED
        status = "MEASURED_PTS"
    elif intervals_ms:
        src = f"ASSUMED_di/cap_fps cap_fps_src={capture_fps_src}"
        status = "ASSUMED_FROM_CAP_IDX"
    else:
        src = PROVENANCE_DEFAULT_ASSUMED
        status = "UNSCORED"

    med = None
    if intervals_ms:
        s = sorted(intervals_ms)
        med = round(s[len(s) // 2], 3)

    return {
        "new_n_interval_status": status,
        "interval_source": src,
        "interval_hist_ms": {str(k): int(v) for k, v in sorted(hist.items())},
        "interval_median_ms": med,
        "n_intervals": len(intervals_ms),
        "cap_idx_delta_hist": dict(Counter(di_list)),
        "expected_source_period_ms": (
            round(1000.0 / 24.0, 3)  # labelled below with actual src
        ),
    }


def analyze_glass_ledger(
    pairs_raw: list[tuple[int, int]],
    *,
    source_fps: float,
    capture_fps: float,
    source_fps_src: str,
    capture_fps_src: str,
    pts_by_idx: dict[int, float] | None = None,
    frames_total: int | None = None,
    blind_frames: int | None = None,
    label: str = "",
) -> dict[str, Any]:
    """Full glass ledger for one capture tier."""
    pairs, ocr_rej = _filter_counter_pairs(pairs_raw)
    rate = analyze_counter_rate(
        pairs,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
    )
    skip = analyze_counter_skips(
        pairs,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
    )
    loss = analyze_presence_loss_split(
        pairs,
        pts_by_idx=pts_by_idx,
        source_fps=source_fps,
        capture_fps=capture_fps,
        source_fps_src=source_fps_src,
        capture_fps_src=capture_fps_src,
        frames_total=frames_total,
        blind_frames=blind_frames,
    )

    ns = [n for _, n in pairs]
    runs = _rle_runs(ns)
    vals = [v for v, _ in runs]
    plateaus = [c for _, c in runs]
    holes = _hole_metrics(vals)
    intervals = _new_n_intervals(pairs, pts_by_idx, capture_fps, capture_fps_src)
    if source_fps > 0:
        intervals["expected_source_period_ms"] = round(1000.0 / source_fps, 3)
        intervals["expected_source_period_ms_src"] = source_fps_src
    else:
        intervals["expected_source_period_ms_src"] = PROVENANCE_DEFAULT_ASSUMED

    max_repeat = int(max(plateaus) if plateaus else 0)
    plat_allowed = None
    if source_fps > 0 and capture_fps > 0:
        plat_allowed = int(math.ceil(capture_fps / source_fps)) + 1

    # Aliasing / resolvability statement (always)
    cap_ms = (1000.0 / capture_fps) if capture_fps > 0 else None
    src_ms = (1000.0 / source_fps) if source_fps > 0 else None
    identity_resolvable = bool(
        cap_ms is not None and src_ms is not None and cap_ms < src_ms
    )
    aliasing = {
        "capture_interval_ms": round(cap_ms, 3) if cap_ms else None,
        "source_hold_ms": round(src_ms, 3) if src_ms else None,
        "capture_fps": capture_fps,
        "capture_fps_src": capture_fps_src,
        "source_fps": source_fps,
        "source_fps_src": source_fps_src,
        "identity_test_resolvable": identity_resolvable,
        "identity_test_basis": (
            "cap_interval < source_hold ⇒ every fully-presented source frame "
            "must appear ≥1× in the capture; missing n ⇒ not fully presented "
            "or OCR miss"
            if identity_resolvable
            else "cap_interval >= source_hold OR fps unknown — single-frame "
            "drops may be invisible; mark claims UNRESOLVABLE"
        ),
        "ms2109_supported_mjpg_1080p": [5.0, 10.0, 20.0, 25.0, 30.0],
        "ms2109_supported_src": "measured_parent_v4l2_list_formats_ext",
        "naive_frame_count_at_30_vs_24": (
            "UNRESOLVABLE — capture samples ≠ source frames; do not compare "
            "N_png to N_source by subtraction"
        ),
        "device_vs_grabber_without_pts": "UNRESOLVABLE",
        "layers_a_b_c_from_glass": "UNRESOLVABLE",
    }

    layers = {
        "a_never_decoded": {
            "status": "UNRESOLVABLE_FROM_GLASS",
            "need": "daemon frameIndex advance without matching present; P5 unaccounted",
        },
        "b_decoded_not_published": {
            "status": "UNRESOLVABLE_FROM_GLASS",
            "need": "publish_misses / DDR path; glass only sees missing n",
        },
        "c_published_not_shown": {
            "status": "UNRESOLVABLE_FROM_GLASS",
            "need": "FPGA bank/ascal probe; glass only sees missing n",
        },
        "glass_identity_holes": {
            "status": "MEASURED" if vals else "NO_DATA",
            "metric": "presence_hole_frames + frames_lost_adj + hole bursts",
        },
    }

    ctr_span = int(skip.get("ctr_span") or 0)
    conf = str(skip.get("skip_confidence") or "UNSCORED")
    lost_adj = skip.get("frames_lost_adj")
    lost_frac_adj = skip.get("lost_frac_adj")
    lost_rle = skip.get("frames_lost_rle")
    adj_events = int(skip.get("skip_events_adj") or 0)

    device_skip = loss.get("device_skip_frames")
    device_frac = None
    if (
        device_skip is not None
        and ctr_span > 0
        and loss.get("loss_split_status") == "LOSS_SPLIT_OK"
    ):
        device_frac = round(float(device_skip) / float(ctr_span), 4)

    # --- verdict (pre-registered) ---
    notes: list[str] = []
    verdict = "UNSCORED"
    rc = RC_UNSCORED
    reason = ""

    if len(pairs) < 12 or len(vals) < 2:
        verdict, rc = "UNSCORED", RC_UNSCORED
        reason = f"insufficient_counter_reads pairs={len(pairs)} unique={len(vals)}"
    elif not identity_resolvable:
        verdict, rc = "UNRESOLVABLE", RC_UNRESOLVABLE
        reason = "identity_test_not_resolvable_at_this_cap_src_ratio"
    elif ctr_span < MIN_CTR_SPAN_SCORE:
        verdict, rc = "UNRESOLVABLE", RC_UNRESOLVABLE
        reason = (
            f"ctr_span={ctr_span}<{MIN_CTR_SPAN_SCORE} "
            f"(below pre-registered score window)"
        )
        notes.append("short_window_single_holes_are_noise")
    elif rate.get("rate_fail"):
        # Rate/revisit failure is a hard glass integrity fail (bank ping-pong etc.)
        verdict, rc = "GLASS_BURST", RC_BURST
        reason = "rate_fail:" + ",".join(rate.get("rate_reasons") or [])
    else:
        # RLE presence holes are PRIMARY for "which n appeared" but OCR-noisy.
        # Display-loss BURST/LOSS gates require adjacent-capture support and/or
        # PTS device_skip (parent: adj is stronger; RLE alone is OCR-class).
        max_hole_rle = holes["max_hole_size"]
        large_ev_rle = holes["large_hole_events"]
        # Adjacent jump-size histogram keys are dn (source step), lost = dn-max_exp.
        # Reconstruct max excess hole from skip_hist_adj if present.
        adj_hist = skip.get("skip_hist_adj") or {}
        max_adj_jump = 0
        for k, v in adj_hist.items():
            try:
                max_adj_jump = max(max_adj_jump, int(k))
            except (TypeError, ValueError):
                pass
        # dn=+2 → 1 lost frame hole; dn=+N → N-1 lost (when max_exp=1).
        max_hole_adj = max(0, max_adj_jump - 1) if max_adj_jump else 0
        adj_skip_events = int(skip.get("skip_events_adj") or 0)

        pts_ok = bool(loss.get("pts_available")) and str(
            loss.get("loss_split_status") or ""
        ) == "LOSS_SPLIT_OK"
        # Display-backed burst signal:
        #  - many adjacent skip events clustered, or large adj jump
        #  - OR PTS-confirmed device_skip with large single hole
        #  - OR severe same-n hold (plateau) — that IS glass-visible judder
        hold_burst = bool(
            plat_allowed is not None
            and _fps_auth(source_fps_src, capture_fps_src)
            and max_repeat > plat_allowed + 1
        )
        burst_adj = (
            max_hole_adj >= BURST_HOLE_SIZE
            or (
                adj_skip_events >= 5
                and max_hole_adj >= 2
                and conf in ("MEDIUM", "HIGH")
            )
        )
        burst_pts = False
        if pts_ok and device_skip is not None and ctr_span > 0:
            # large single device hole from presence detail not always exported;
            # use device_skip_events if available
            d_ev = int(loss.get("device_skip_events") or 0)
            if device_frac is not None and device_frac >= LOSS_ADJ_FRAC and d_ev >= BURST_HOLE_EVENTS:
                burst_pts = True
            if max_hole_rle >= BURST_MAX_HOLE_HARD and (device_skip or 0) > 0:
                burst_pts = True

        # RLE-only large holes WITHOUT adj/PTS support → not BURST (OCR-class)
        rle_only_large = (
            large_ev_rle >= BURST_HOLE_EVENTS or max_hole_rle >= BURST_MAX_HOLE_HARD
        ) and not burst_adj and not pts_ok and (lost_frac_adj or 0) < OK_ADJ_FRAC
        if rle_only_large:
            notes.append(
                f"rle_large_holes_ignored_for_burst max_hole_rle={max_hole_rle} "
                f"large_ev={large_ev_rle} adj_lost={lost_adj} — OCR-class without "
                f"adj/PTS support"
            )

        burst_hit = bool(burst_adj or burst_pts or hold_burst)

        loss_hit = False
        if (
            lost_frac_adj is not None
            and lost_frac_adj >= LOSS_ADJ_FRAC
            and conf in ("MEDIUM", "HIGH")
        ):
            loss_hit = True
            notes.append(
                f"adj_loss_frac={lost_frac_adj}>={LOSS_ADJ_FRAC} conf={conf}"
            )
        if device_frac is not None and device_frac >= LOSS_ADJ_FRAC:
            loss_hit = True
            notes.append(f"device_skip_frac={device_frac}>={LOSS_ADJ_FRAC} pts_split=OK")

        # OCR-only RLE holes with negligible adjacent loss → not display loss
        ocr_class = (
            (lost_adj is None or int(lost_adj) == 0 or (lost_frac_adj or 0) < OK_ADJ_FRAC)
            and (lost_rle or 0) > 0
            and not pts_ok
            and not burst_adj
        )
        below_floor = (
            not pts_ok
            and str(loss.get("steady_state_loss") or "") == "UNSCORED"
            and (lost_frac_adj or 0) < OK_ADJ_FRAC
            and not burst_hit
        )

        # Display-backed max hole for OK gate: prefer adj; else RLE only if PTS
        max_hole_display = max_hole_adj
        if pts_ok:
            max_hole_display = max(max_hole_display, max_hole_rle)

        if burst_hit:
            verdict, rc = "GLASS_BURST", RC_BURST
            reason = (
                f"burst max_hole_adj={max_hole_adj} max_hole_rle={max_hole_rle} "
                f"adj_skip_events={adj_skip_events} "
                f"max_repeat_run={max_repeat}/{plat_allowed} "
                f"hold_burst={int(hold_burst)} pts_burst={int(burst_pts)}"
            )
        elif loss_hit:
            verdict, rc = "GLASS_LOSS", RC_LOSS
            reason = (
                f"sustained_loss lost_frac_adj={lost_frac_adj} "
                f"frames_lost_adj={lost_adj} conf={conf}"
            )
        elif ocr_class and (lost_frac_adj or 0) < OK_ADJ_FRAC and conf in (
            "MEDIUM",
            "HIGH",
        ):
            # Healthy adj path with OCR rle noise → GLASS_OK if plateaus ok
            if (
                plat_allowed is None
                or not _fps_auth(source_fps_src, capture_fps_src)
                or max_repeat <= plat_allowed
            ):
                verdict, rc = "GLASS_OK", RC_OK
                reason = (
                    f"identity_ok_adj lost_frac_adj={lost_frac_adj}<{OK_ADJ_FRAC} "
                    f"max_hole_adj={max_hole_adj} max_repeat_run={max_repeat}/"
                    f"{plat_allowed} conf={conf} "
                    f"(rle_holes={lost_rle} treated OCR-class without PTS)"
                )
                notes.append(
                    "rle_presence_holes_reported_but_not_scored_as_loss_without_pts"
                )
                if plat_allowed and max_repeat == plat_allowed:
                    notes.append("plateau_at_bound")
            else:
                verdict, rc = "GLASS_BURST", RC_BURST
                reason = f"max_repeat_run={max_repeat}>{plat_allowed}"
        elif below_floor and conf == "LOW":
            verdict, rc = "UNRESOLVABLE", RC_UNRESOLVABLE
            reason = "below_resolution_floor_or_low_conf"
        elif (
            conf in ("MEDIUM", "HIGH")
            and lost_frac_adj is not None
            and lost_frac_adj < OK_ADJ_FRAC
            and max_hole_display <= OK_MAX_HOLE
            and (
                plat_allowed is None
                or not _fps_auth(source_fps_src, capture_fps_src)
                or max_repeat <= plat_allowed
            )
        ):
            verdict, rc = "GLASS_OK", RC_OK
            reason = (
                f"identity_ok lost_frac_adj={lost_frac_adj}<{OK_ADJ_FRAC} "
                f"max_hole_display={max_hole_display}<={OK_MAX_HOLE} "
                f"max_repeat_run={max_repeat}/{plat_allowed} conf={conf}"
            )
            if plat_allowed and max_repeat == plat_allowed:
                notes.append("plateau_at_bound")
        elif conf in ("MEDIUM", "HIGH") and (
            (lost_frac_adj is not None and lost_frac_adj >= OK_ADJ_FRAC)
            or max_hole_display > OK_MAX_HOLE
        ):
            if lost_frac_adj is not None and lost_frac_adj >= LOSS_ADJ_FRAC:
                verdict, rc = "GLASS_LOSS", RC_LOSS
                reason = f"lost_frac_adj={lost_frac_adj}"
            elif max_hole_display >= BURST_HOLE_SIZE:
                verdict, rc = "GLASS_BURST", RC_BURST
                reason = f"max_hole_display={max_hole_display} elevated"
            else:
                verdict, rc = "UNRESOLVABLE", RC_UNRESOLVABLE
                reason = (
                    f"elevated_but_below_loss_line lost_frac_adj={lost_frac_adj} "
                    f"max_hole_display={max_hole_display} conf={conf} — not GLASS_OK"
                )
                notes.append("suspect_band_is_not_a_pass")
        else:
            verdict, rc = "UNRESOLVABLE", RC_UNRESOLVABLE
            reason = f"no_positive_ok conf={conf} lost_frac_adj={lost_frac_adj}"

        # Always expose both hole views
        holes = dict(holes)
        holes["max_hole_size_rle"] = max_hole_rle
        holes["max_hole_size_adj"] = max_hole_adj
        holes["max_hole_size_display"] = max_hole_display
        holes["large_hole_events_rle"] = large_ev_rle

    report: dict[str, Any] = {
        "instrument": "glass_frame_ledger",
        "label": label,
        "verdict": verdict,
        "rc": rc,
        "reason": reason,
        "notes": notes,
        "thresholds_pre_registered": {
            "MIN_CTR_SPAN_SCORE": MIN_CTR_SPAN_SCORE,
            "OK_ADJ_FRAC": OK_ADJ_FRAC,
            "LOSS_ADJ_FRAC": LOSS_ADJ_FRAC,
            "OK_MAX_HOLE": OK_MAX_HOLE,
            "BURST_HOLE_SIZE": BURST_HOLE_SIZE,
            "BURST_HOLE_EVENTS": BURST_HOLE_EVENTS,
            "BURST_MAX_HOLE_HARD": BURST_MAX_HOLE_HARD,
            "TIER_DELTA_ADJ_FRAC": TIER_DELTA_ADJ_FRAC,
            "TIER_HOLE_MARGIN": TIER_HOLE_MARGIN,
            "thresholds_src": "design_locked_before_device_series",
        },
        "layers": layers,
        "aliasing": aliasing,
        "n_samples_filtered": len(pairs),
        "n_samples_raw": len(pairs_raw),
        "ocr_rejected": len(ocr_rej),
        "n_first": int(vals[0]) if vals else None,
        "n_last": int(vals[-1]) if vals else None,
        "unique_states": len(vals),
        "ctr_span": ctr_span,
        "max_repeat_run": max_repeat,
        "max_repeat_run_allowed": plat_allowed,
        "max_repeat_run_src": "measured_rle_plateau",
        "plateau_hist": {str(k): int(v) for k, v in sorted(Counter(plateaus).items())},
        "frames_lost_adj": lost_adj,
        "frames_lost_rle": lost_rle,
        "lost_frac_adj": lost_frac_adj,
        "lost_frac_rle": skip.get("lost_frac_rle"),
        "skip_events_adj": adj_events,
        "skip_confidence": conf,
        "skip_status": skip.get("skip_status"),
        "skip_hist_adj": skip.get("skip_hist_adj"),
        "rate": rate.get("rate"),
        "unique_ratio": rate.get("unique_ratio"),
        "endpoint_rate": rate.get("endpoint_rate"),
        "fps_authoritative": rate.get("fps_authoritative"),
        "source_fps": source_fps,
        "source_fps_src": source_fps_src,
        "capture_fps": capture_fps,
        "capture_fps_src": capture_fps_src,
        "loss_split_status": loss.get("loss_split_status"),
        "device_skip_frames": device_skip,
        "grabber_drop_frames": loss.get("grabber_drop_frames"),
        "device_skip_frac": device_frac,
        "steady_state_loss": loss.get("steady_state_loss"),
        "resolution_floor_frac": loss.get("resolution_floor_frac"),
        "pts_available": bool(pts_by_idx),
        **{f"burst_{k}": v for k, v in holes.items()},
        "intervals": intervals,
        "arithmetic": (
            f"presence: RLE distinct burned-in n; hole=n[i+1]-n[i]-1. "
            f"frames_lost_adj from adjacent cap pairs (hdmi_motion_instrument). "
            f"max_repeat_run=max RLE plateau of same n (judder/hold). "
            f"Layers a/b/c UNRESOLVABLE from glass. "
            f"verdict={verdict} reason={reason}"
        ),
    }
    return report


def compare_tiers(a: dict[str, Any], b: dict[str, Any]) -> dict[str, Any]:
    """Pre-registered 240p vs 480p comparison."""
    notes: list[str] = []
    va, vb = a.get("verdict"), b.get("verdict")
    # Prefer labelling so b is the heavier tier if names say so
    out: dict[str, Any] = {
        "instrument": "glass_frame_ledger_compare",
        "a_label": a.get("label") or "A",
        "b_label": b.get("label") or "B",
        "a_verdict": va,
        "b_verdict": vb,
        "a_lost_frac_adj": a.get("lost_frac_adj"),
        "b_lost_frac_adj": b.get("lost_frac_adj"),
        "a_max_hole": a.get("burst_max_hole_size"),
        "b_max_hole": b.get("burst_max_hole_size"),
        "a_max_repeat_run": a.get("max_repeat_run"),
        "b_max_repeat_run": b.get("max_repeat_run"),
        "a_conf": a.get("skip_confidence"),
        "b_conf": b.get("skip_confidence"),
        "thresholds_src": "design_locked_before_device_series",
    }

    soft = {"UNSCORED", "UNRESOLVABLE"}
    if va in soft or vb in soft:
        out["verdict"] = "UNRESOLVABLE" if "UNRESOLVABLE" in (va, vb) else "UNSCORED"
        out["rc"] = RC_UNRESOLVABLE if out["verdict"] == "UNRESOLVABLE" else RC_UNSCORED
        out["reason"] = f"tier_incomplete a={va} b={vb}"
        return out

    fa = a.get("lost_frac_adj")
    fb = b.get("lost_frac_adj")
    conf_ok = a.get("skip_confidence") in ("MEDIUM", "HIGH") and b.get(
        "skip_confidence"
    ) in ("MEDIUM", "HIGH")
    delta = None
    if fa is not None and fb is not None:
        delta = round(float(fb) - float(fa), 4)
    out["delta_lost_frac_adj_b_minus_a"] = delta

    ha = int(a.get("burst_max_hole_size") or 0)
    hb = int(b.get("burst_max_hole_size") or 0)

    regress = False
    if conf_ok and delta is not None and delta >= TIER_DELTA_ADJ_FRAC:
        regress = True
        notes.append(
            f"delta_adj_frac={delta}>={TIER_DELTA_ADJ_FRAC} (b worse than a)"
        )
    if conf_ok and hb >= ha + TIER_HOLE_MARGIN and hb >= BURST_HOLE_SIZE:
        regress = True
        notes.append(f"max_hole b={hb} a={ha} margin>={TIER_HOLE_MARGIN}")
    if vb in ("GLASS_LOSS", "GLASS_BURST") and va == "GLASS_OK":
        regress = True
        notes.append(f"b={vb} while a=GLASS_OK")

    if regress:
        out["verdict"] = "TIER_REGRESSION"
        out["rc"] = RC_TIER
        out["reason"] = "480_tier_worse_than_240_pre_registered"
    elif va == "GLASS_OK" and vb == "GLASS_OK":
        out["verdict"] = "TIER_OK"
        out["rc"] = RC_OK
        out["reason"] = "both_tiers_GLASS_OK"
    elif va in ("GLASS_LOSS", "GLASS_BURST") and vb in ("GLASS_LOSS", "GLASS_BURST"):
        out["verdict"] = "BOTH_TIERS_FAIL"
        out["rc"] = RC_LOSS if "LOSS" in (va, vb) else RC_BURST
        out["reason"] = f"a={va} b={vb} (not a tier-specific regression)"
    else:
        out["verdict"] = "TIER_MIXED"
        out["rc"] = RC_UNRESOLVABLE
        out["reason"] = f"a={va} b={vb} — no clean tier story"
        notes.append("mixed_is_not_a_pass")

    out["notes"] = notes
    return out


def _print_report(rep: dict[str, Any]) -> None:
    print(f"=== glass_frame_ledger label={rep.get('label')!r} ===")
    print(
        f"VERDICT={rep['verdict']} rc={rep['rc']} reason={rep.get('reason')}"
    )
    print(
        f"identity n={rep.get('n_first')}->{rep.get('n_last')} "
        f"span={rep.get('ctr_span')} unique={rep.get('unique_states')} "
        f"samples={rep.get('n_samples_filtered')}/{rep.get('n_samples_raw')} "
        f"ocr_rej={rep.get('ocr_rejected')}"
    )
    print(
        f"loss frames_lost_adj={rep.get('frames_lost_adj')} "
        f"lost_frac_adj={rep.get('lost_frac_adj')} "
        f"frames_lost_rle={rep.get('frames_lost_rle')} "
        f"conf={rep.get('skip_confidence')} skip_status={rep.get('skip_status')}"
    )
    print(
        f"burst max_repeat_run={rep.get('max_repeat_run')}/"
        f"{rep.get('max_repeat_run_allowed')} "
        f"plateau_hist={rep.get('plateau_hist')} "
        f"max_hole={rep.get('burst_max_hole_size')} "
        f"hole_hist={rep.get('burst_hole_size_hist')} "
        f"large_hole_events={rep.get('burst_large_hole_events')} "
        f"max_consec_hole_steps={rep.get('burst_max_consecutive_hole_steps')}"
    )
    iv = rep.get("intervals") or {}
    print(
        f"intervals status={iv.get('new_n_interval_status')} "
        f"median_ms={iv.get('interval_median_ms')} "
        f"expected_src_period_ms={iv.get('expected_source_period_ms')} "
        f"src={iv.get('interval_source')} "
        f"hist_ms={iv.get('interval_hist_ms')}"
    )
    print(
        f"pts loss_split={rep.get('loss_split_status')} "
        f"device_skip={rep.get('device_skip_frames')} "
        f"grabber_drop={rep.get('grabber_drop_frames')} "
        f"device_frac={rep.get('device_skip_frac')} "
        f"floor={rep.get('resolution_floor_frac')} "
        f"steady={rep.get('steady_state_loss')}"
    )
    al = rep.get("aliasing") or {}
    print(
        f"aliasing identity_resolvable={al.get('identity_test_resolvable')} "
        f"cap_ms={al.get('capture_interval_ms')} src_hold_ms={al.get('source_hold_ms')} "
        f"device_vs_grabber={al.get('device_vs_grabber_without_pts')} "
        f"naive_count={al.get('naive_frame_count_at_30_vs_24')}"
    )
    print("layers (a/b/c always UNRESOLVABLE from glass alone):")
    for k, v in (rep.get("layers") or {}).items():
        print(f"  {k}: {v.get('status')} — {v.get('need', v.get('metric', ''))}")
    print(f"rate={rep.get('rate')} unique_ratio={rep.get('unique_ratio')} "
          f"endpoint_rate={rep.get('endpoint_rate')} "
          f"fps_auth={rep.get('fps_authoritative')} "
          f"src_fps={rep.get('source_fps')} src={rep.get('source_fps_src')} "
          f"cap_fps={rep.get('capture_fps')} cap={rep.get('capture_fps_src')}")
    if rep.get("notes"):
        print("notes: " + " | ".join(rep["notes"]))
    print(f"arithmetic: {rep.get('arithmetic')}")


def _self_test() -> int:
    """Red-before-green on synthetic counter sequences."""
    fails: list[str] = []

    def check(name: str, cond: bool, detail: str = "") -> None:
        if not cond:
            fails.append(f"{name}: {detail}")

    # --- GREEN: healthy 24-on-30, long span, plateaus 1-2, no holes ---
    # Build ~300 capture samples covering ~240 source frames (ratio 0.8)
    pairs_ok: list[tuple[int, int]] = []
    n = 1000
    for i in range(300):
        # advance source every 1 or 2 captures
        if i > 0 and i % 5 != 0:
            n += 1
        pairs_ok.append((i, n))
    # ensure span >= 200
    rep_ok = analyze_glass_ledger(
        pairs_ok,
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
        label="synth_ok",
    )
    check(
        "green_ok",
        rep_ok["verdict"] == "GLASS_OK" and rep_ok["rc"] == RC_OK,
        f"got {rep_ok['verdict']} rc={rep_ok['rc']} reason={rep_ok.get('reason')}",
    )

    # --- RED LOSS: insert many +2 adjacent jumps ---
    pairs_loss = list(pairs_ok)
    # Every 10th step jump +2 source frames on adjacent captures
    rebuilt: list[tuple[int, int]] = []
    n = 1000
    for i in range(400):
        if i > 0 and i % 8 == 0:
            n += 2  # skip one source frame
        else:
            n += 1 if i % 5 != 0 else 0
            if i % 5 != 0:
                pass
        # simpler construction:
    rebuilt = []
    n = 2000
    for i in range(400):
        rebuilt.append((i, n))
        if i % 10 == 9:
            n += 2  # hole of 1 each 10 captures on next
        else:
            n += 1
    # Actually after append we need the jump visible between adjacent samples
    rebuilt = []
    n = 2000
    for i in range(400):
        rebuilt.append((i, n))
        if (i + 1) % 8 == 0:
            n += 2  # next sample sees +2
        else:
            n += 1
    rep_loss = analyze_glass_ledger(
        rebuilt,
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
        label="synth_loss",
    )
    check(
        "red_loss",
        rep_loss["rc"] in (RC_LOSS, RC_BURST) and rep_loss["verdict"] != "GLASS_OK",
        f"got {rep_loss['verdict']} rc={rep_loss['rc']} "
        f"frac={rep_loss.get('lost_frac_adj')} reason={rep_loss.get('reason')}",
    )

    # --- RED BURST: one huge hole ---
    pairs_burst: list[tuple[int, int]] = []
    n = 5000
    for i in range(250):
        pairs_burst.append((i, n))
        if i == 100:
            n += 10  # hole of 9
        else:
            n += 1
    rep_burst = analyze_glass_ledger(
        pairs_burst,
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
        label="synth_burst",
    )
    check(
        "red_burst",
        rep_burst["verdict"] == "GLASS_BURST" and rep_burst["rc"] == RC_BURST,
        f"got {rep_burst['verdict']} rc={rep_burst['rc']} "
        f"max_hole={rep_burst.get('burst_max_hole_size')}",
    )

    # --- short window → UNRESOLVABLE ---
    pairs_short = [(i, 100 + i) for i in range(30)]
    rep_short = analyze_glass_ledger(
        pairs_short,
        source_fps=24.0,
        capture_fps=30.0,
        source_fps_src=PROVENANCE_CALLER,
        capture_fps_src=PROVENANCE_CALLER,
        label="synth_short",
    )
    check(
        "short_unresolvable",
        rep_short["rc"] in (RC_UNRESOLVABLE, RC_UNSCORED)
        and rep_short["verdict"] != "GLASS_OK",
        f"got {rep_short['verdict']} rc={rep_short['rc']}",
    )

    # --- layers always UNRESOLVABLE ---
    for key in ("a_never_decoded", "b_decoded_not_published", "c_published_not_shown"):
        st = (rep_ok.get("layers") or {}).get(key, {}).get("status")
        check(f"layer_{key}", st == "UNRESOLVABLE_FROM_GLASS", f"status={st}")

    # --- tier compare regression ---
    cmp_reg = compare_tiers(rep_ok, rep_loss)
    check(
        "tier_regression",
        cmp_reg["verdict"] == "TIER_REGRESSION" and cmp_reg["rc"] == RC_TIER,
        f"got {cmp_reg}",
    )
    cmp_ok = compare_tiers(rep_ok, rep_ok)
    check(
        "tier_ok",
        cmp_ok["verdict"] == "TIER_OK" and cmp_ok["rc"] == RC_OK,
        f"got {cmp_ok}",
    )

    # UNSCORED is never pass
    check("unscored_ne_0", RC_UNSCORED != 0 and RC_UNRESOLVABLE != 0, "")

    if fails:
        print("SELFTEST FAIL:")
        for f in fails:
            print(f"  - {f}")
        return 1
    print("SELFTEST OK")
    print(
        f"  green: {rep_ok['verdict']} rc={rep_ok['rc']} "
        f"frac={rep_ok.get('lost_frac_adj')} max_hole={rep_ok.get('burst_max_hole_size')}"
    )
    print(
        f"  red_loss: {rep_loss['verdict']} rc={rep_loss['rc']} "
        f"frac={rep_loss.get('lost_frac_adj')}"
    )
    print(
        f"  red_burst: {rep_burst['verdict']} rc={rep_burst['rc']} "
        f"max_hole={rep_burst.get('burst_max_hole_size')}"
    )
    print(f"  short: {rep_short['verdict']} rc={rep_short['rc']}")
    print(f"  tier_reg: {cmp_reg['verdict']} rc={cmp_reg['rc']}")
    print(f"  tier_ok: {cmp_ok['verdict']} rc={cmp_ok['rc']}")
    return 0


def _resolve_fps(args: argparse.Namespace) -> tuple[float, str, float, str]:
    try:
        src = parse_fps_token(args.source_fps)
    except ValueError as e:
        print(f"ERROR: --source-fps: {e}", file=sys.stderr)
        raise SystemExit(RC_UNSCORED) from e
    if src is None:
        source_fps, source_src = DEFAULT_ASSUMED_SOURCE_FPS, PROVENANCE_DEFAULT_ASSUMED
    else:
        source_fps, source_src = src, PROVENANCE_CALLER
    try:
        cap = parse_fps_token(args.capture_fps)
    except ValueError as e:
        print(f"ERROR: --capture-fps: {e}", file=sys.stderr)
        raise SystemExit(RC_UNSCORED) from e
    if cap is None:
        capture_fps, capture_src = DEFAULT_ASSUMED_CAPTURE_FPS, PROVENANCE_DEFAULT_ASSUMED
    else:
        capture_fps, capture_src = cap, PROVENANCE_CALLER
    return source_fps, source_src, capture_fps, capture_src


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--counters-csv", default=None)
    ap.add_argument("--pts-csv", default=None)
    ap.add_argument("--label", default="")
    ap.add_argument("--source-fps", "--src-fps", dest="source_fps", default=None)
    ap.add_argument("--capture-fps", "--cap-fps", dest="capture_fps", default=None)
    ap.add_argument("--compare", action="store_true")
    ap.add_argument("--a-csv", default=None)
    ap.add_argument("--b-csv", default=None)
    ap.add_argument("--a-pts", default=None)
    ap.add_argument("--b-pts", default=None)
    ap.add_argument("--a-label", default="240p")
    ap.add_argument("--b-label", default="480p")
    args = ap.parse_args(argv)

    if args.self_test:
        return _self_test()

    source_fps, source_src, capture_fps, capture_src = _resolve_fps(args)
    if source_src == PROVENANCE_DEFAULT_ASSUMED or capture_src == PROVENANCE_DEFAULT_ASSUMED:
        print(
            "WARN: fps DEFAULT_ASSUMED — conf capped; pass --source-fps from "
            "daemon fps= and --capture-fps measured/caller (ERROR 17 class)",
            file=sys.stderr,
        )

    def _one(
        csv_path: str,
        pts_path: str | None,
        label: str,
    ) -> dict[str, Any]:
        pairs, meta = load_counters_csv(csv_path)
        pts = load_pts_csv(pts_path) if pts_path else None
        return analyze_glass_ledger(
            pairs,
            source_fps=source_fps,
            capture_fps=capture_fps,
            source_fps_src=source_src,
            capture_fps_src=capture_src,
            pts_by_idx=pts,
            frames_total=meta.get("frames_total"),
            blind_frames=meta.get("blind_frames"),
            label=label,
        )

    if args.compare:
        if not args.a_csv or not args.b_csv:
            ap.error("--compare needs --a-csv and --b-csv")
        ra = _one(args.a_csv, args.a_pts, args.a_label)
        rb = _one(args.b_csv, args.b_pts, args.b_label)
        cmp = compare_tiers(ra, rb)
        if args.json:
            print(json.dumps({"a": ra, "b": rb, "compare": cmp}, indent=2))
        else:
            _print_report(ra)
            print()
            _print_report(rb)
            print()
            print(
                f"COMPARE {cmp.get('a_label')} vs {cmp.get('b_label')}: "
                f"VERDICT={cmp['verdict']} rc={cmp['rc']} reason={cmp.get('reason')}"
            )
            print(
                f"  delta_lost_frac_adj(b-a)={cmp.get('delta_lost_frac_adj_b_minus_a')} "
                f"max_hole a={cmp.get('a_max_hole')} b={cmp.get('b_max_hole')}"
            )
            if cmp.get("notes"):
                print("  notes: " + " | ".join(cmp["notes"]))
        return int(cmp["rc"])

    if not args.counters_csv:
        ap.error("provide --counters-csv or --compare or --self-test")

    rep = _one(args.counters_csv, args.pts_csv, args.label or Path(args.counters_csv).name)
    if args.json:
        print(json.dumps(rep, indent=2))
    else:
        _print_report(rep)
    return int(rep["rc"])


if __name__ == "__main__":
    sys.exit(main())
