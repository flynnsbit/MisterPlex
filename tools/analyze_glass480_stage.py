#!/usr/bin/env python3
"""Stage-split 480p glass frame loss using daemon 1 Hz lines (+ optional glass holes).

WHY
---
Glass can lose ~0.70% of source frames while daemon `drops` stays flat.
Host residual:
  unaccounted = frames - presents - drops
cannot see frames never produced (never enter frames) NOR post-present scanout
loss (present already counted). Those two collapse into the same residual=0 cell.

DISCRIMINATOR (supply_bucket + ffmpeg_out_frames now in daemon)
---------------------------------------------------------------
On a single session_epoch, steady window wall_s in [T0, T1] (default 10..end):

  d_wall_s   = wall_s(T1) - wall_s(T0)                         measured
  d_frames   = frames(T1) - frames(T0)                         measured
  expected   = d_wall_s * fps_num / fps_den                    derived (caller fps)
  supply_gap = expected - d_frames                             derived
  d_ffmpeg_out = ffmpeg_out_frames(T1)-ffmpeg_out_frames(T0)  measured (or NO-DATA)
  host_gap   = unaccounted(T1) - unaccounted(T0)               measured delta
  glass_holes = caller_supplied ABSENT source indices

Also accepts 1 Hz `media: supply_bucket ...` lines (sums d_* over window).

Decision table (all integers; see THRESHOLDS):
  glass_holes >= GLASS_LOSS_MIN  (else UNSCORED — no loss to attribute)
  PIPE_* / SUPPLY_PIPE_IDENTITY_FAIL → STAGE=PIPE
  host_gap >= HOST_GAP_HIT ≈ glass → HOST_MID (± publish)
  ffmpeg known + ff_gap≥HIT + frames≈ffmpeg + host flat → PRE_FFMPEG_SUPPLY
  ffmpeg known + ffmpeg−frames ≥HIT + host flat → PIPE_READ_SHORT
  supply_gap ≥ HIT + host flat → PRE_FRAMEINDEX_SUPPLY
  supply flat + host flat + (ff flat if known) → POST_PRESENT_SCANOUT
  else → AMBIGUOUS

CAN: PRE-ffmpeg vs pipe-read vs post-present (when ffmpeg_out_frames measured).
CANNOT: DDR bank vs RTL vs HDMI PHY inside POST_PRESENT.

THRESHOLDS — resolution proof for 0.70% / ~15 frames in 90 s @ 24 fps
--------------------------------------------------------------------
Counters are integers ⇒ resolution = 1 frame.

  Expected steady 80 s @ 24.000: 1920 frames; 0.70% ≈ 13.4 → budget 15 holes.

  HOST_GAP_FLAT   = 2     # unaccounted growth ≤2 cannot explain 15 glass holes
  HOST_GAP_HIT    = 10    # ≥10 can carry the ~15-hole signal (clear gap vs FLAT)
  SUPPLY_GAP_FLAT = 2     # same for supply_gap
  SUPPLY_GAP_HIT  = 10
  PAIR_TOL        = 5     # |gap - glass_holes| for "explains glass"
  GLASS_LOSS_MIN  = 3     # below this, do not attribute (noise / OCR)

Proof that FLAT=2 distinguishes 15 from 0:
  unaccounted is exact integer arithmetic on counters (no float).
  Decision HOST_GAP_FLAT requires host_gap ≤ 2.
  Decision HOST_GAP_HIT requires host_gap ≥ 10.
  15 lies in HIT; 0 lies in FLAT; band (3..9) is AMBIGUOUS — never silently
  collapsed into either. Self-test asserts this trichotomy.

ffmpeg_out_frames: play path uses -stats -loglevel info; stderr pump splits on
CR/LF and stores last frame=N. If every line shows ffmpeg_out_frames=NO-DATA,
that is measured absence of stats parse — do not invent a count. Prefer
supply_bucket.d_ffmpeg_out when present.

Exit codes
----------
  0  STAGE decided (PRE_* | POST_PRESENT_SCANOUT | HOST_MID | PIPE | PIPE_READ_SHORT)
  2  AMBIGUOUS or threshold conflict
  77 could-not-measure (no lines / multi epoch / short window) — NEVER a pass
  1  usage

Rule 0: every printed value tagged measured | caller_supplied | derived | NO-DATA.
true rc: cmd; echo "true rc=$?"
"""
from __future__ import annotations

import argparse
import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Tuple

RC_OK = 0
RC_USAGE = 1
RC_AMBIGUOUS = 2
RC_NO_DATA = 77

# --- locked thresholds (see module docstring) ---
HOST_GAP_FLAT = 2
HOST_GAP_HIT = 10
SUPPLY_GAP_FLAT = 2
SUPPLY_GAP_HIT = 10
PAIR_TOL = 5
GLASS_LOSS_MIN = 3
MIN_STEADY_S = 60.0  # need ≥60 s steady after T0 for 0.7% to be ~10+ frames
DEFAULT_T0_S = 10.0
DEFAULT_FPS_NUM = 24
DEFAULT_FPS_DEN = 1

RE_MEDIA = re.compile(r"media:\s+(?P<body>.+)")
RE_KV = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)")
RE_PIPE = re.compile(r"PIPE_(?:BYTE_MISALIGN|DESYNC)|SUPPLY_PIPE_IDENTITY_FAIL")


@dataclass
class Sample:
    wall_s: float
    frames: int
    presents: int
    drops: int
    unaccounted: int
    publish_misses: int
    session_epoch: str
    ffmpeg_out_frames: Optional[int] = None  # None = NO-DATA
    av_drift_ms: Optional[float] = None
    av_servo_margin_ms: Optional[float] = None
    av_display_offset_ms: Optional[float] = None
    av_servo_setpoint_ms: Optional[float] = None
    lead_ms: Optional[float] = None
    is_supply_bucket: bool = False
    d_frames: Optional[int] = None
    d_ffmpeg_out: Optional[int] = None
    supply_gap_line: Optional[float] = None
    raw: str = ""


def _f(kv: dict, k: str) -> Optional[float]:
    v = kv.get(k)
    if v is None:
        return None
    try:
        return float(v)
    except ValueError:
        return None


def _i(kv: dict, k: str) -> Optional[int]:
    v = kv.get(k)
    if v is None:
        return None
    try:
        return int(float(v))
    except ValueError:
        return None


def _ffmpeg_out(kv: dict) -> Optional[int]:
    v = kv.get("ffmpeg_out_frames")
    if v is None or v == "NO-DATA":
        return None
    try:
        return int(float(v))
    except ValueError:
        return None


def parse_log(text: str) -> Tuple[List[Sample], bool]:
    samples: List[Sample] = []
    pipe_hit = bool(RE_PIPE.search(text))
    for line in text.splitlines():
        if (
            "PIPE_BYTE_MISALIGN" in line
            or "PIPE_DESYNC" in line
            or "SUPPLY_PIPE_IDENTITY_FAIL" in line
        ):
            pipe_hit = True
        m = RE_MEDIA.search(line)
        if not m:
            continue
        body = m.group("body")
        if body.startswith("session end"):
            continue
        kv = {a: b for a, b in RE_KV.findall(body)}
        is_bucket = body.startswith("supply_bucket") or "supply_bucket " in body
        if "frames=" not in body or "presents=" not in body:
            continue
        wall = _f(kv, "wall_s")
        frames = _i(kv, "frames")
        presents = _i(kv, "presents")
        drops = _i(kv, "drops")
        if wall is None or frames is None or presents is None or drops is None:
            continue
        unacc = _i(kv, "unaccounted")
        if unacc is None:
            unacc = frames - presents - drops  # derived identity
        pm = _i(kv, "publish_misses")
        if pm is None:
            pm = 0
        se = kv.get("session_epoch", "NO-DATA")
        d_ff = None
        if kv.get("d_ffmpeg_out") not in (None, "NO-DATA"):
            d_ff = _i(kv, "d_ffmpeg_out")
        samples.append(
            Sample(
                wall_s=wall,
                frames=frames,
                presents=presents,
                drops=drops,
                unaccounted=unacc,
                publish_misses=pm,
                session_epoch=se,
                ffmpeg_out_frames=_ffmpeg_out(kv),
                av_drift_ms=_f(kv, "av_drift_ms"),
                av_servo_margin_ms=_f(kv, "av_servo_margin_ms"),
                av_display_offset_ms=_f(kv, "av_display_offset_ms"),
                av_servo_setpoint_ms=_f(kv, "av_servo_setpoint_ms"),
                lead_ms=_f(kv, "lead_ms"),
                is_supply_bucket=is_bucket,
                d_frames=_i(kv, "d_frames") if is_bucket else None,
                d_ffmpeg_out=d_ff if is_bucket else None,
                supply_gap_line=_f(kv, "supply_gap") if is_bucket else None,
                raw=line,
            )
        )
    return samples, pipe_hit


def pick_window(
    samples: List[Sample], t0: float, t1: Optional[float]
) -> Tuple[Optional[Sample], Optional[Sample], str]:
    if not samples:
        return None, None, "no_samples"
    # single epoch only
    epochs = {s.session_epoch for s in samples if s.session_epoch != "NO-DATA"}
    if len(epochs) > 1:
        return None, None, f"multi_session_epoch={sorted(epochs)}"
    steady = [s for s in samples if s.wall_s + 1e-9 >= t0]
    if t1 is not None:
        steady = [s for s in steady if s.wall_s <= t1 + 1e-9]
    if len(steady) < 2:
        return None, None, "window_too_few_samples"
    a, b = steady[0], steady[-1]
    if b.wall_s - a.wall_s < MIN_STEADY_S - 1e-9:
        return None, None, f"steady_span_s={b.wall_s - a.wall_s:.3f}<{MIN_STEADY_S}"
    return a, b, "ok"


def decide(
    supply_gap: float,
    host_gap: int,
    glass_holes: Optional[int],
    pipe_hit: bool,
    pm_delta: int,
    d_frames: Optional[int] = None,
    d_ffmpeg_out: Optional[int] = None,
    expected: Optional[float] = None,
) -> Tuple[str, int, str]:
    if pipe_hit:
        return "PIPE", RC_OK, "PIPE_* / SUPPLY_PIPE_IDENTITY_FAIL in log — stop"
    if glass_holes is not None and glass_holes < GLASS_LOSS_MIN:
        return (
            "NO_GLASS_LOSS",
            RC_NO_DATA,
            f"glass_holes={glass_holes}<{GLASS_LOSS_MIN} — nothing to attribute",
        )

    gh = glass_holes
    # HOST mid path
    if host_gap >= HOST_GAP_HIT:
        if gh is None or abs(host_gap - gh) <= PAIR_TOL:
            if pm_delta >= HOST_GAP_HIT and abs(pm_delta - host_gap) <= PAIR_TOL:
                return (
                    "HOST_MID_PUBLISH",
                    RC_OK,
                    "unaccounted≈publish_misses≈glass — DDR publish",
                )
            return (
                "HOST_MID",
                RC_OK,
                "unaccounted growth explains glass; not pure supply/scanout",
            )

    supply_hit = supply_gap >= SUPPLY_GAP_HIT
    supply_flat = supply_gap <= SUPPLY_GAP_FLAT
    host_flat = host_gap <= HOST_GAP_FLAT
    ff_known = (
        d_ffmpeg_out is not None
        and d_frames is not None
        and expected is not None
    )

    if ff_known and host_flat:
        ff_gap = float(expected) - float(d_ffmpeg_out)
        pipe_vs_ff = int(d_frames) - int(d_ffmpeg_out)
        if (
            ff_gap >= SUPPLY_GAP_HIT
            and abs(pipe_vs_ff) <= HOST_GAP_FLAT
            and (gh is None or abs(ff_gap - gh) <= PAIR_TOL or abs(supply_gap - gh) <= PAIR_TOL)
        ):
            return (
                "PRE_FFMPEG_SUPPLY",
                RC_OK,
                "ffmpeg_out short vs wall; frames≈ffmpeg_out — PMS/decode short",
            )
        if int(d_ffmpeg_out) - int(d_frames) >= HOST_GAP_HIT:
            return (
                "PIPE_READ_SHORT",
                RC_OK,
                "ffmpeg_out advances more than frameIndex — daemon read short",
            )

    if supply_hit and host_flat:
        if gh is None or abs(supply_gap - gh) <= PAIR_TOL:
            label = "PRE_FRAMEINDEX_SUPPLY"
            detail = "wall×fps − Δframes explains glass; residual flat"
            if not ff_known:
                detail += " (ffmpeg_out NO-DATA — cannot split decode vs pipe)"
            return (label, RC_OK, detail)

    if supply_flat and host_flat and (gh is None or gh >= GLASS_LOSS_MIN):
        if ff_known:
            ff_gap = float(expected) - float(d_ffmpeg_out)
            if ff_gap > SUPPLY_GAP_FLAT:
                return (
                    "AMBIGUOUS",
                    RC_AMBIGUOUS,
                    f"frames matched wall but ffmpeg_out gap={ff_gap:.2f}",
                )
        return (
            "POST_PRESENT_SCANOUT",
            RC_OK,
            "supply matched wall; residual flat; glass holes ⇒ post-present",
        )

    return (
        "AMBIGUOUS",
        RC_AMBIGUOUS,
        f"supply_gap={supply_gap:.2f} host_gap={host_gap} glass={gh} "
        f"d_ffmpeg_out={d_ffmpeg_out} flat_max={HOST_GAP_FLAT} hit_min={HOST_GAP_HIT}",
    )


def analyze(
    log_text: str,
    glass_holes: Optional[int],
    fps_num: int,
    fps_den: int,
    t0: float,
    t1: Optional[float],
) -> dict:
    samples, pipe_hit = parse_log(log_text)
    out: dict = {
        "n_samples": len(samples),
        "pipe_hit": pipe_hit,
        "fps_num": fps_num,
        "fps_den": fps_den,
        "fps_src": "caller_supplied",
        "t0_s": t0,
        "thresholds": {
            "HOST_GAP_FLAT": HOST_GAP_FLAT,
            "HOST_GAP_HIT": HOST_GAP_HIT,
            "SUPPLY_GAP_FLAT": SUPPLY_GAP_FLAT,
            "SUPPLY_GAP_HIT": SUPPLY_GAP_HIT,
            "PAIR_TOL": PAIR_TOL,
            "GLASS_LOSS_MIN": GLASS_LOSS_MIN,
            "MIN_STEADY_S": MIN_STEADY_S,
        },
    }
    if glass_holes is not None:
        out["glass_holes"] = glass_holes
        out["glass_holes_src"] = "caller_supplied"
    else:
        out["glass_holes"] = None
        out["glass_holes_src"] = "NO-DATA"

    a, b, why = pick_window(samples, t0, t1)
    if a is None or b is None:
        out["rc"] = RC_NO_DATA
        out["stage"] = "NO-DATA"
        out["reason"] = why
        return out

    d_wall = b.wall_s - a.wall_s
    d_frames = b.frames - a.frames
    d_presents = b.presents - a.presents
    d_drops = b.drops - a.drops
    host_gap = b.unaccounted - a.unaccounted
    pm_delta = b.publish_misses - a.publish_misses
    expected = d_wall * float(fps_num) / float(fps_den)
    supply_gap = expected - float(d_frames)
    d_ffmpeg_out: Optional[int] = None
    d_ffmpeg_src = "NO-DATA"
    if a.ffmpeg_out_frames is not None and b.ffmpeg_out_frames is not None:
        d_ffmpeg_out = b.ffmpeg_out_frames - a.ffmpeg_out_frames
        d_ffmpeg_src = "measured"
    else:
        # Prefer summed supply_bucket d_ffmpeg_out over the steady window.
        bucket_ff = [
            s.d_ffmpeg_out
            for s in samples
            if s.is_supply_bucket
            and s.d_ffmpeg_out is not None
            and s.wall_s + 1e-9 >= a.wall_s
            and s.wall_s <= b.wall_s + 1e-9
        ]
        if bucket_ff:
            d_ffmpeg_out = sum(bucket_ff)
            d_ffmpeg_src = "measured_sum_supply_bucket"

    out.update(
        {
            "session_epoch": a.session_epoch,
            "wall_s_a": a.wall_s,
            "wall_s_b": b.wall_s,
            "d_wall_s": d_wall,
            "d_wall_s_src": "measured",
            "d_frames": d_frames,
            "d_frames_src": "measured",
            "d_presents": d_presents,
            "d_drops": d_drops,
            "d_ffmpeg_out": d_ffmpeg_out,
            "d_ffmpeg_out_src": d_ffmpeg_src,
            "ffmpeg_out_a": a.ffmpeg_out_frames,
            "ffmpeg_out_b": b.ffmpeg_out_frames,
            "expected_frames": expected,
            "expected_frames_src": "derived_wall_times_fps",
            "supply_gap": supply_gap,
            "supply_gap_src": "derived_expected_minus_d_frames",
            "host_gap": host_gap,
            "host_gap_src": "measured_delta_unaccounted",
            "publish_misses_delta": pm_delta,
            "unaccounted_a": a.unaccounted,
            "unaccounted_b": b.unaccounted,
            "av_drift_ms_b": b.av_drift_ms,
            "av_servo_margin_ms_b": b.av_servo_margin_ms,
            "av_display_offset_ms_b": b.av_display_offset_ms,
            "av_servo_setpoint_ms_b": b.av_servo_setpoint_ms,
            "lead_ms_b": b.lead_ms,
        }
    )
    stage, rc, reason = decide(
        supply_gap,
        host_gap,
        glass_holes,
        pipe_hit,
        pm_delta,
        d_frames=d_frames,
        d_ffmpeg_out=d_ffmpeg_out,
        expected=expected,
    )
    out["stage"] = stage
    out["rc"] = rc
    out["reason"] = reason
    return out


def print_report(out: dict) -> None:
    print("=== glass480 stage attribution ===")
    th = out["thresholds"]
    print(
        f"THRESHOLDS HOST_GAP_FLAT={th['HOST_GAP_FLAT']} HOST_GAP_HIT={th['HOST_GAP_HIT']} "
        f"SUPPLY_GAP_FLAT={th['SUPPLY_GAP_FLAT']} SUPPLY_GAP_HIT={th['SUPPLY_GAP_HIT']} "
        f"PAIR_TOL={th['PAIR_TOL']} GLASS_LOSS_MIN={th['GLASS_LOSS_MIN']} "
        f"MIN_STEADY_S={th['MIN_STEADY_S']} src=caller_supplied_locked"
    )
    print(
        f"RESOLUTION_PROOF unaccounted_integer=1 frame; "
        f"FLAT≤{th['HOST_GAP_FLAT']} vs HIT≥{th['HOST_GAP_HIT']} leaves "
        f"(FLAT+1..HIT-1) as AMBIGUOUS; 15∈HIT 0∈FLAT src=derived"
    )
    print(f"n_samples={out['n_samples']} src=measured")
    print(f"pipe_hit={out['pipe_hit']} src=measured")
    print(
        f"fps={out['fps_num']}/{out['fps_den']} fps_src={out['fps_src']} "
        f"(do not assume 23.976)"
    )
    print(f"glass_holes={out['glass_holes']} src={out['glass_holes_src']}")
    if out.get("stage") in (None, "NO-DATA") or out.get("rc") == RC_NO_DATA:
        print(f"STAGE={out.get('stage')} rc={out.get('rc')} reason={out.get('reason')}")
        print(f"VERDICT=NO-DATA rc={RC_NO_DATA}")
        return
    for k in (
        "session_epoch",
        "wall_s_a",
        "wall_s_b",
        "d_wall_s",
        "d_frames",
        "d_presents",
        "d_drops",
        "d_ffmpeg_out",
        "ffmpeg_out_a",
        "ffmpeg_out_b",
        "expected_frames",
        "supply_gap",
        "host_gap",
        "publish_misses_delta",
        "unaccounted_a",
        "unaccounted_b",
        "av_drift_ms_b",
        "av_servo_margin_ms_b",
        "av_display_offset_ms_b",
        "av_servo_setpoint_ms_b",
        "lead_ms_b",
    ):
        if k not in out:
            continue
        src = out.get(f"{k}_src")
        if not src:
            if k in ("expected_frames", "supply_gap"):
                src = "derived"
            elif k in ("d_ffmpeg_out", "ffmpeg_out_a", "ffmpeg_out_b") and out.get(k) is None:
                src = "NO-DATA"
            else:
                src = "measured"
        print(f"{k}={out[k]} src={src}")
    print(f"STAGE={out['stage']} reason={out['reason']}")
    print(f"VERDICT={out['stage']} rc={out['rc']}")


def self_test() -> int:
    fails = 0

    def check(cond: bool, msg: str) -> None:
        nonlocal fails
        if not cond:
            print(f"FAIL {msg}", file=sys.stderr)
            fails += 1
        else:
            print(f"PASS {msg}")

    # Resolution trichotomy on decide()
    st, rc, _ = decide(0.0, 0, 15, False, 0)
    check(st == "POST_PRESENT_SCANOUT" and rc == RC_OK, "15 glass + flat supply/host → POST")
    st, rc, _ = decide(15.0, 0, 15, False, 0)
    check(st == "PRE_FRAMEINDEX_SUPPLY" and rc == RC_OK, "15 supply_gap → PRE")
    st, rc, _ = decide(
        15.0, 0, 15, False, 0, d_frames=9, d_ffmpeg_out=9, expected=24.0
    )
    check(st == "PRE_FFMPEG_SUPPLY" and rc == RC_OK, "ffmpeg short → PRE_FFMPEG")
    st, rc, _ = decide(
        15.0, 0, 15, False, 0, d_frames=9, d_ffmpeg_out=24, expected=24.0
    )
    check(st == "PIPE_READ_SHORT" and rc == RC_OK, "ffmpeg>frames → PIPE_READ_SHORT")
    st, rc, _ = decide(0.0, 15, 15, False, 15)
    check(st == "HOST_MID_PUBLISH" and rc == RC_OK, "15 host+pm → PUBLISH")
    st, rc, _ = decide(0.0, 15, 15, False, 0)
    check(st == "HOST_MID" and rc == RC_OK, "15 host no pm → HOST_MID")
    st, rc, _ = decide(0.0, 0, 0, False, 0)
    check(rc == RC_NO_DATA, "0 glass → NO-DATA")
    st, rc, _ = decide(5.0, 5, 15, False, 0)
    check(st == "AMBIGUOUS" and rc == RC_AMBIGUOUS, "mid band 5 → AMBIGUOUS not collapsed")
    st, rc, _ = decide(0.0, 0, 15, True, 0)
    check(st == "PIPE" and rc == RC_OK, "PIPE wins")

    # Synthetic 80 s steady @24 fps, perfect supply, 15 glass holes
    lines = []
    epoch = "1000.1"
    for w in range(0, 91):
        # startup: 10 drops in first 2s then flat — frames track 24*w after t=0
        frames = int(24 * w)
        drops = 10 if w >= 2 else min(5 * w, 10)
        presents = frames - drops
        unacc = 0
        lines.append(
            f"media: frames={frames} presents={presents} drops={drops} "
            f"publish_misses=0 unaccounted={unacc} residual={unacc} "
            f"ffmpeg_out_frames={frames} "
            f"wall_s={float(w):.1f} session_epoch={epoch} "
            f"av_drift_ms=-30 av_servo_setpoint_ms=-40 av_servo_margin_ms=10 "
            f"av_display_offset_ms=-30 lead_ms=40 tag=measured"
        )
    log = "\n".join(lines)
    out = analyze(log, glass_holes=15, fps_num=24, fps_den=1, t0=10.0, t1=None)
    check(out["rc"] == RC_OK, f"synth POST rc got {out['rc']} stage={out.get('stage')}")
    check(out["stage"] == "POST_PRESENT_SCANOUT", f"synth stage {out.get('stage')}")
    check(abs(out["supply_gap"]) <= SUPPLY_GAP_FLAT + 0.01, f"supply_gap {out.get('supply_gap')}")
    check(out["host_gap"] <= HOST_GAP_FLAT, f"host_gap {out.get('host_gap')}")

    # Supply short 15 frames *inside* the steady window: at T0 frames still on
    # schedule; after T0 a one-shot loss of 15 so d_frames = expected - 15.
    lines2 = []
    for w in range(0, 91):
        frames = int(24 * w) - (15 if w > 10 else 0)
        if frames < 0:
            frames = 0
        presents = frames
        lines2.append(
            f"media: frames={frames} presents={presents} drops=0 publish_misses=0 "
            f"unaccounted=0 wall_s={float(w):.1f} session_epoch={epoch} tag=measured"
        )
    out2 = analyze("\n".join(lines2), 15, 24, 1, 10.0, None)
    check(out2["stage"] == "PRE_FRAMEINDEX_SUPPLY", f"supply synth {out2.get('stage')} gap={out2.get('supply_gap')}")
    check(out2["supply_gap"] >= SUPPLY_GAP_HIT, f"supply_gap hit {out2.get('supply_gap')}")

    # Prove 15 vs 0 resolution on host_gap
    check(HOST_GAP_FLAT < 15 < 999 and HOST_GAP_HIT <= 15, "15 is HIT not FLAT")
    check(0 <= HOST_GAP_FLAT, "0 is FLAT")
    check(HOST_GAP_FLAT + 1 < HOST_GAP_HIT, "ambiguous band non-empty")

    # empty log
    out3 = analyze("", None, 24, 1, 10.0, None)
    check(out3["rc"] == RC_NO_DATA, "empty → 77")

    if fails:
        print(f"SELF_TEST_FAIL fails={fails}", file=sys.stderr)
        return RC_AMBIGUOUS
    print("SELF_TEST_OK")
    return RC_OK


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--log", type=Path, help="daemon log with media: 1 Hz lines")
    ap.add_argument("--glass-holes", type=int, default=None, help="caller_supplied ABSENT count")
    ap.add_argument("--fps-num", type=int, default=DEFAULT_FPS_NUM)
    ap.add_argument("--fps-den", type=int, default=DEFAULT_FPS_DEN)
    ap.add_argument("--t0-s", type=float, default=DEFAULT_T0_S, help="steady window start wall_s")
    ap.add_argument("--t1-s", type=float, default=None, help="steady window end wall_s")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.log:
        print("usage: --log PATH or --self-test", file=sys.stderr)
        return RC_USAGE
    if not args.log.is_file():
        print(f"NO-DATA log missing: {args.log}", file=sys.stderr)
        return RC_NO_DATA
    if args.fps_num <= 0 or args.fps_den <= 0:
        print("FAIL fps must be positive", file=sys.stderr)
        return RC_USAGE

    text = args.log.read_text(errors="replace")
    out = analyze(text, args.glass_holes, args.fps_num, args.fps_den, args.t0_s, args.t1_s)
    print_report(out)
    return int(out["rc"])


if __name__ == "__main__":
    sys.exit(main())
