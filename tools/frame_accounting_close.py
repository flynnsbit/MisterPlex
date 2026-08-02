#!/usr/bin/env python3
"""Close the ARM supply frame ledger (user 480p "frames dropped" bug).

USER (verbatim): verify framerate / frames look dropped on the 480p path.

WHY DROPS= ALONE IS UNTRUSTWORTHY (this tree — quote product, not parent lore)
---------------------------------------------------------------------------
  drops          = deliberate A/V-pacer skips ONLY
                   droppedFrames_.fetch_add after AvAction::Drop
                   (~media_player.cpp present loop; tip ~:4185)
  presentCount_  = increments ONLY on successful DDR/FPGA publish (~:3677)
  publishMisses_ = present attempted, publish failed (~:3641)
  resets         = play-path store(0) ~:3010/:3011 (respawn / new stream)
  residual_arm   = frames - presents - drops
                   (frame_ledger.hpp; == publish_misses when closed)
  residual_unexplained = frames - presents - drops - publish_misses
                   NONZERO ⇒ frames vanished on a path we do NOT instrument.
                   THAT is the user finding drops= cannot settle.

vfps on the 1 Hz line is CUMULATIVE from session start (media_player ~:3158+).
"vfps improving 23.6→23.9" is an averaging artifact. Interval truth is
d_frames/d_wall from supply_bucket (or consecutive media snaps). Tip prints
fmtFpsRate as %.6f (was substr(0,4) historically — do not trust old binaries).

supply_ratio (audio_s/wall_s) is ASYMMETRIC:
  ratio << 1  → trustworthy starvation signal (bytes not submitted)
  ratio ≈ 1.0 → NOT health proof (MrAudio never blocks; submitted ≠ played)
  NEVER use supply_ratio to separate socket-starved vs video-consumer-blocked
  (ffmpeg A/V lockstep; VOID endpoint for that dichotomy).

session_epoch / process_epoch / pid continuity: mid-soak daemon EXIT rc=0 +
respawn re-zeroes counters → window INVALID rc=79 (align w-instr
tools/daemon_media_ledger.py and avsync_* SESSION_INVALID).

Exit codes (capture DIRECTLY: cmd; echo "true rc=$?" — never through a pipe)
--------------------------------------------------------------------------
  0   LEDGER_OK           residual_unexplained==0 for all valid rounds
  2   LEDGER_RESIDUAL     residual_unexplained != 0 (LOUD user finding)
  3   FPS_COLLAPSE        per-round d_frames/d_wall short vs content fps
  4   BOTH_RESIDUAL_FPS
 78   INSUFFICIENT_EVIDENCE  cannot close (missing presents/publish_misses)
 79   SESSION_INVALID     epoch/pid/counter reset mid-window
 77   NO-DATA             no usable samples — never a pass
  6   self-test designed sensitivity

Every printed value tagged measured | reconstructed | caller_supplied |
DEFAULT_ASSUMED | NO-DATA. Never hardcode 23.976; content fps is caller_supplied
or measured from log fps=N/D (fixtures are 24.000 exact).

Usage:
  python3 tools/frame_accounting_close.py --self-test; echo "true rc=$?"
  python3 tools/frame_accounting_close.py --daemon-log path.txt \\
      --content-fps 24 --content-fps-src caller_supplied
  echo "true rc=$?"
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

# --- exit codes (align w-instr daemon_media_ledger + w-avsync) -----------------
RC_OK = 0
RC_USAGE = 1
RC_RESIDUAL = 2
RC_FPS = 3
RC_BOTH = 4
RC_SELFTEST = 6
RC_INSUFFICIENT = 78
RC_SESSION = 79
RC_NO_DATA = 77

PROV_MEASURED = "measured"
PROV_RECON = "reconstructed"
PROV_CALLER = "caller_supplied"
PROV_DEFAULT = "DEFAULT_ASSUMED"
PROV_NO_DATA = "NO-DATA"

RE_KV = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)")
RE_EXIT = re.compile(
    r"\bEXIT pid=\d+\b|\bSUPERVISE_EXIT\b|\bevent=process_exit\b|"
    r"\bevent=process_start\b|\bEXIT rc=\d+\b"
)


def _i(kv: Dict[str, str], k: str) -> Optional[int]:
    v = kv.get(k)
    if v is None or v in ("NO-DATA", "null", "None"):
        return None
    try:
        return int(float(v))
    except ValueError:
        return None


def _f(kv: Dict[str, str], k: str) -> Optional[float]:
    v = kv.get(k)
    if v is None or v in ("NO-DATA", "null", "None"):
        return None
    try:
        return float(v)
    except ValueError:
        return None


def residual_arm(frames: int, presents: int, drops: int) -> int:
    return frames - presents - drops


def residual_unexplained(frames: int, presents: int, drops: int, pub: int) -> int:
    return frames - presents - drops - pub


@dataclass
class Round:
    """One closed 1 Hz (or reconstructed) accounting sample."""

    wall_s: Optional[float]
    d_wall_s: Optional[float]
    d_frames: Optional[int]
    d_presents: Optional[int]
    d_drops: Optional[int]
    d_publish_misses: Optional[int]
    frames: int
    presents: int
    drops: int
    publish_misses: Optional[int]
    residual_arm: int
    residual_unexplained: Optional[int]  # None if publish_misses NO-DATA
    iv_vfps: Optional[float]  # d_frames/d_wall (full float)
    iv_pfps: Optional[float]
    cum_vfps_logged: Optional[float]  # cumulative log vfps (artifact-prone)
    session_epoch: Optional[str]
    process_epoch: Optional[str]
    pid: Optional[str]
    src: str  # measured supply_bucket | measured atomic | reconstructed
    line_no: int
    invalid: bool = False
    invalid_reason: str = ""


@dataclass
class Report:
    verdict: str
    rc: int
    reason: str
    rounds: List[Round] = field(default_factory=list)
    n_supply_bucket: int = 0
    n_atomic: int = 0
    n_recon: int = 0
    n_exit: int = 0
    session_epochs: List[str] = field(default_factory=list)
    process_epochs: List[str] = field(default_factory=list)
    pids: List[str] = field(default_factory=list)
    content_fps: float = 24.0
    content_fps_src: str = PROV_DEFAULT
    notes: List[str] = field(default_factory=list)
    coverage: Dict[str, Any] = field(default_factory=dict)


def parse_log(text: str) -> Tuple[List[Round], Dict[str, Any], List[str]]:
    """Parse supply_bucket preferred; else atomic media; else consecutive media."""
    rounds: List[Round] = []
    notes: List[str] = []
    meta = {
        "n_supply_bucket": 0,
        "n_atomic": 0,
        "n_media_stats": 0,
        "n_exit": 0,
        "session_epochs": [],
        "process_epochs": [],
        "pids": [],
    }
    epochs: List[str] = []
    peps: List[str] = []
    pids: List[str] = []

    # First pass: collect supply_bucket + atomic media + exit markers
    prev_snap: Optional[Dict[str, Any]] = None
    for i, line in enumerate(text.splitlines(), 1):
        if RE_EXIT.search(line) and "media:" not in line and "supply_bucket" not in line:
            meta["n_exit"] += 1
            rounds.append(
                Round(
                    wall_s=None,
                    d_wall_s=None,
                    d_frames=None,
                    d_presents=None,
                    d_drops=None,
                    d_publish_misses=None,
                    frames=0,
                    presents=0,
                    drops=0,
                    publish_misses=None,
                    residual_arm=0,
                    residual_unexplained=None,
                    iv_vfps=None,
                    iv_pfps=None,
                    cum_vfps_logged=None,
                    session_epoch=None,
                    process_epoch=None,
                    pid=None,
                    src="exit_marker",
                    line_no=i,
                    invalid=True,
                    invalid_reason="exit_or_process_marker",
                )
            )
            continue

        is_sb = "supply_bucket" in line
        is_media = "media:" in line
        if not is_sb and not is_media:
            continue

        body = line
        if is_media:
            body = line.split("media:", 1)[1].strip()
        kv = {a: b for a, b in RE_KV.findall(body)}

        se = kv.get("session_epoch")
        pe = kv.get("process_epoch")
        pid = kv.get("pid")
        if se:
            epochs.append(se)
        if pe:
            peps.append(pe)
        if pid:
            pids.append(pid)

        frames = _i(kv, "frames")
        presents = _i(kv, "presents")
        drops = _i(kv, "drops")
        pub = _i(kv, "publish_misses")
        wall = _f(kv, "wall_s")
        cum_vfps = _f(kv, "vfps")

        if is_sb:
            meta["n_supply_bucket"] += 1
            if frames is None or presents is None or drops is None:
                notes.append(f"L{i}: supply_bucket missing frames/presents/drops")
                continue
            d_wall = _f(kv, "d_wall_s")
            d_fr = _i(kv, "d_frames")
            d_pr = _i(kv, "d_presents")
            d_dr = _i(kv, "d_drops")
            d_pm = _i(kv, "d_publish_misses")
            iv_v = _f(kv, "iv_vfps")
            iv_p = _f(kv, "iv_pfps")
            if iv_v is None and d_wall and d_wall > 0 and d_fr is not None:
                iv_v = d_fr / d_wall
            if iv_p is None and d_wall and d_wall > 0 and d_pr is not None:
                iv_p = d_pr / d_wall
            ra = residual_arm(frames, presents, drops)
            ru = residual_unexplained(frames, presents, drops, pub) if pub is not None else None
            # Prefer logged residual_unexplained if present
            if "residual_unexplained" in kv:
                ru_log = _i(kv, "residual_unexplained")
                if ru_log is not None:
                    ru = ru_log
            rounds.append(
                Round(
                    wall_s=wall,
                    d_wall_s=d_wall,
                    d_frames=d_fr,
                    d_presents=d_pr,
                    d_drops=d_dr,
                    d_publish_misses=d_pm,
                    frames=frames,
                    presents=presents,
                    drops=drops,
                    publish_misses=pub,
                    residual_arm=ra,
                    residual_unexplained=ru,
                    iv_vfps=iv_v,
                    iv_pfps=iv_p,
                    cum_vfps_logged=cum_vfps,
                    session_epoch=se,
                    process_epoch=pe,
                    pid=pid,
                    src="measured_supply_bucket",
                    line_no=i,
                )
            )
            continue

        # atomic: frames+presents+drops on one media line
        if (
            frames is not None
            and presents is not None
            and drops is not None
            and not body.startswith("fpga frame_tx")
        ):
            meta["n_atomic"] += 1
            ra = residual_arm(frames, presents, drops)
            ru = residual_unexplained(frames, presents, drops, pub) if pub is not None else None
            if "residual_unexplained" in kv:
                ru_log = _i(kv, "residual_unexplained")
                if ru_log is not None:
                    ru = ru_log
            d_wall = d_fr = d_pr = d_dr = d_pm = None
            iv_v = iv_p = None
            if prev_snap is not None and wall is not None and prev_snap.get("wall_s") is not None:
                dw = wall - prev_snap["wall_s"]
                if dw > 0:
                    d_wall = dw
                    d_fr = frames - prev_snap["frames"]
                    d_pr = presents - prev_snap["presents"]
                    d_dr = drops - prev_snap["drops"]
                    if pub is not None and prev_snap.get("pub") is not None:
                        d_pm = pub - prev_snap["pub"]
                    iv_v = d_fr / dw
                    iv_p = d_pr / dw
                    # counter reset detection
                    if d_fr < 0 or d_pr < 0 or d_dr < 0:
                        rounds.append(
                            Round(
                                wall_s=wall,
                                d_wall_s=d_wall,
                                d_frames=d_fr,
                                d_presents=d_pr,
                                d_drops=d_dr,
                                d_publish_misses=d_pm,
                                frames=frames,
                                presents=presents,
                                drops=drops,
                                publish_misses=pub,
                                residual_arm=ra,
                                residual_unexplained=ru,
                                iv_vfps=None,
                                iv_pfps=None,
                                cum_vfps_logged=cum_vfps,
                                session_epoch=se,
                                process_epoch=pe,
                                pid=pid,
                                src="measured_atomic",
                                line_no=i,
                                invalid=True,
                                invalid_reason="counter_reset_negative_delta",
                            )
                        )
                        prev_snap = {
                            "wall_s": wall,
                            "frames": frames,
                            "presents": presents,
                            "drops": drops,
                            "pub": pub,
                            "se": se,
                            "pe": pe,
                            "pid": pid,
                        }
                        continue
            rounds.append(
                Round(
                    wall_s=wall,
                    d_wall_s=d_wall,
                    d_frames=d_fr,
                    d_presents=d_pr,
                    d_drops=d_dr,
                    d_publish_misses=d_pm,
                    frames=frames,
                    presents=presents,
                    drops=drops,
                    publish_misses=pub,
                    residual_arm=ra,
                    residual_unexplained=ru,
                    iv_vfps=iv_v,
                    iv_pfps=iv_p,
                    cum_vfps_logged=cum_vfps,
                    session_epoch=se,
                    process_epoch=pe,
                    pid=pid,
                    src="measured_atomic",
                    line_no=i,
                )
            )
            prev_snap = {
                "wall_s": wall,
                "frames": frames,
                "presents": presents,
                "drops": drops,
                "pub": pub,
                "se": se,
                "pe": pe,
                "pid": pid,
            }
            continue

        if frames is not None and drops is not None and presents is None:
            meta["n_media_stats"] += 1

    meta["session_epochs"] = sorted(set(epochs))
    meta["process_epochs"] = sorted(set(peps))
    meta["pids"] = sorted(set(pids))
    return rounds, meta, notes


def check_session(rounds: List[Round], meta: Dict[str, Any]) -> Tuple[bool, str]:
    if meta.get("n_exit", 0) > 0:
        return False, "exit_or_process_marker_in_window"
    epochs = meta.get("session_epochs") or []
    if len(epochs) > 1:
        return False, f"session_epoch_changed {epochs}"
    peps = meta.get("process_epochs") or []
    if len(peps) > 1:
        return False, f"process_epoch_changed {peps}"
    pids = meta.get("pids") or []
    if len(pids) > 1:
        return False, f"pid_changed {pids}"
    for r in rounds:
        if r.invalid and r.invalid_reason == "counter_reset_negative_delta":
            return False, "counter_reset_negative_delta"
    # Monotonic frames across valid rounds
    last_f: Optional[int] = None
    for r in rounds:
        if r.src == "exit_marker" or r.invalid:
            continue
        if last_f is not None and r.frames < last_f:
            return False, f"frames_reset {last_f}->{r.frames} L{r.line_no}"
        last_f = r.frames
    return True, "continuous"


def classify(
    rounds: List[Round],
    meta: Dict[str, Any],
    notes: List[str],
    content_fps: float,
    content_fps_src: str,
    fps_ok_min_ratio: float = 0.90,
    min_rounds: int = 3,
) -> Report:
    ok_c, reason_c = check_session(rounds, meta)
    valid = [r for r in rounds if not r.invalid and r.src != "exit_marker"]
    rep = Report(
        verdict="NO-DATA",
        rc=RC_NO_DATA,
        reason="init",
        rounds=rounds,
        n_supply_bucket=meta.get("n_supply_bucket", 0),
        n_atomic=meta.get("n_atomic", 0),
        n_recon=meta.get("n_recon", 0),
        n_exit=meta.get("n_exit", 0),
        session_epochs=meta.get("session_epochs") or [],
        process_epochs=meta.get("process_epochs") or [],
        pids=meta.get("pids") or [],
        content_fps=content_fps,
        content_fps_src=content_fps_src,
        notes=list(notes),
    )

    if not ok_c:
        rep.verdict = "SESSION_INVALID"
        rep.rc = RC_SESSION
        rep.reason = reason_c
        rep.coverage = _coverage(valid, content_fps)
        return rep

    if not valid:
        rep.verdict = "NO-DATA"
        rep.rc = RC_NO_DATA
        rep.reason = "no_closed_ledger_samples"
        rep.coverage = _coverage(valid, content_fps)
        return rep

    # Need publish_misses to close unexplained residual
    missing_pub = [r for r in valid if r.publish_misses is None]
    if missing_pub and all(r.residual_unexplained is None for r in valid):
        # Can still score residual_arm if residual_arm==0 for all
        if any(r.residual_arm != 0 for r in valid):
            rep.verdict = "INSUFFICIENT_EVIDENCE"
            rep.rc = RC_INSUFFICIENT
            rep.reason = (
                "publish_misses=NO-DATA while residual_arm!=0 — cannot separate "
                "publish fail from uninstrumented gap"
            )
            rep.coverage = _coverage(valid, content_fps)
            return rep

    # residual_unexplained
    bad_u = [
        r
        for r in valid
        if r.residual_unexplained is not None and r.residual_unexplained != 0
    ]
    # residual_arm != 0 and != publish_misses
    bad_arm = [
        r
        for r in valid
        if r.residual_unexplained is None
        and r.residual_arm != 0
        and not (
            r.publish_misses is not None and r.residual_arm == r.publish_misses
        )
    ]

    residual_fail = bool(bad_u or bad_arm)

    # Per-round FPS (skip first round if no d_frames)
    rate_rounds = [
        r
        for r in valid
        if r.iv_vfps is not None
        and r.d_wall_s is not None
        and r.d_wall_s >= 0.5
        and r.d_frames is not None
    ]
    fps_fail = False
    fps_reason = ""
    if len(rate_rounds) >= min_rounds:
        # Drop first 2 rounds as warm-up (startup transient parent-measured)
        body = rate_rounds[2:] if len(rate_rounds) > 5 else rate_rounds
        floor = content_fps * fps_ok_min_ratio
        short = [r for r in body if r.iv_vfps is not None and r.iv_vfps < floor]
        frac_short = len(short) / max(len(body), 1)
        # Collapse if ≥20% of body rounds below floor OR median far below
        med = statistics.median([r.iv_vfps for r in body if r.iv_vfps is not None])
        if frac_short >= 0.20 or med < floor:
            fps_fail = True
            fps_reason = (
                f"iv_vfps_collapse med={med:.4f} floor={floor:.4f} "
                f"frac_short={frac_short:.3f} n={len(body)} "
                f"fps_ok_min_ratio={fps_ok_min_ratio} src={PROV_DEFAULT}"
            )
    else:
        rep.notes.append(
            f"FPS axis: only {len(rate_rounds)} interval samples "
            f"(need>={min_rounds}); FPS not scored (not a pass on FPS)"
        )

    if residual_fail and fps_fail:
        b = (bad_u or bad_arm)[-1]
        rep.verdict = "BOTH_RESIDUAL_FPS"
        rep.rc = RC_BOTH
        rep.reason = (
            f"residual_unexplained={b.residual_unexplained} "
            f"residual_arm={b.residual_arm} + {fps_reason}"
        )
    elif residual_fail:
        b = (bad_u or bad_arm)[-1]
        rep.verdict = "LEDGER_RESIDUAL"
        rep.rc = RC_RESIDUAL
        rep.reason = (
            f"residual_unexplained={b.residual_unexplained} "
            f"residual_arm={b.residual_arm} frames={b.frames} "
            f"presents={b.presents} drops={b.drops} "
            f"publish_misses={b.publish_misses} L{b.line_no}"
        )
    elif fps_fail:
        rep.verdict = "FPS_COLLAPSE"
        rep.rc = RC_FPS
        rep.reason = fps_reason
    else:
        last = valid[-1]
        rep.verdict = "LEDGER_OK"
        rep.rc = RC_OK
        rep.reason = (
            f"residual_unexplained={last.residual_unexplained} "
            f"residual_arm={last.residual_arm} n_valid={len(valid)}"
        )

    rep.coverage = _coverage(valid, content_fps)
    rep.notes.append(
        "supply_ratio is VOID for local-vs-path and asymmetric: "
        "<1 trustworthy starvation; ~1.0 is NOT health proof"
    )
    rep.notes.append(
        "drops= pacer skips ONLY; residual_unexplained is the uninstrumented gap"
    )
    rep.notes.append(
        "av_drift_ms locked band is setpoint readout (avDecide Hold); "
        "not lipsync — run LEAD 40→20→40 falsifier (docs/FRAME_ACCOUNTING_CLOSE.md)"
    )
    rep.notes.append(
        "CANNOT_SETTLE: glass/HDMI pixels, perceived lipsync, FPGA scanout, "
        "grabber drop; cumulative vfps is averaging artifact — use iv_vfps"
    )
    return rep


def _coverage(valid: List[Round], content_fps: float) -> Dict[str, Any]:
    has_pres = sum(1 for r in valid if r.presents is not None)
    has_pub = sum(1 for r in valid if r.publish_misses is not None)
    has_iv = sum(1 for r in valid if r.iv_vfps is not None)
    has_ru = sum(1 for r in valid if r.residual_unexplained is not None)
    walls = [r.wall_s for r in valid if r.wall_s is not None]
    window = None
    if len(walls) >= 2:
        window = max(walls) - min(walls)
    return {
        "n_valid_rounds": len(valid),
        "axis_presents": "DATA" if has_pres == len(valid) and valid else "NO-DATA",
        "axis_publish_misses": "DATA" if has_pub == len(valid) and valid else (
            "PARTIAL" if has_pub else "NO-DATA"
        ),
        "axis_interval_fps": "DATA" if has_iv else "NO-DATA",
        "axis_residual_unexplained": "DATA" if has_ru == len(valid) and valid else (
            "PARTIAL" if has_ru else "NO-DATA"
        ),
        "window_wall_s": window,
        "content_fps_ref": content_fps,
    }


def print_report(rep: Report) -> int:
    print("=== frame_accounting_close ===")
    print(
        "semantics: frames=pipe_assemble; presents=arm_publish_ok; "
        "drops=av_pacer_only; publish_misses=arm_publish_fail; "
        "residual_arm=frames-presents-drops; "
        "residual_unexplained=frames-presents-drops-publish_misses"
    )
    print(
        "CANNOT_CLAIM: drops alone = full loss; supply_ratio~1 = health; "
        "av_drift band = lipsync; cumulative vfps = interval health"
    )
    print(
        f"content_fps={rep.content_fps} src={rep.content_fps_src}"
    )
    print(
        f"n_supply_bucket={rep.n_supply_bucket} n_atomic={rep.n_atomic} "
        f"n_exit={rep.n_exit} n_rounds={len(rep.rounds)} src={PROV_MEASURED}"
    )
    print(
        f"session_epochs={rep.session_epochs or 'NO-DATA'} src="
        f"{PROV_MEASURED if rep.session_epochs else PROV_NO_DATA}"
    )
    print(
        f"process_epochs={rep.process_epochs or 'NO-DATA'} src="
        f"{PROV_MEASURED if rep.process_epochs else PROV_NO_DATA}"
    )
    print(
        f"pids={rep.pids or 'NO-DATA'} src="
        f"{PROV_MEASURED if rep.pids else PROV_NO_DATA}"
    )
    print(f"coverage={json.dumps(rep.coverage, sort_keys=True)}")

    valid = [r for r in rep.rounds if not r.invalid and r.src != "exit_marker"]
    if valid:
        print("--- per-round (interval; full float iv_*) ---")
        # show up to last 12 + first 2
        show = valid if len(valid) <= 16 else valid[:2] + valid[-12:]
        if len(valid) > 16:
            print(f"(showing first 2 + last 12 of {len(valid)})")
        for r in show:
            iv = f"{r.iv_vfps:.6f}" if r.iv_vfps is not None else "NO-DATA"
            ip = f"{r.iv_pfps:.6f}" if r.iv_pfps is not None else "NO-DATA"
            cv = (
                f"{r.cum_vfps_logged:.6f}"
                if r.cum_vfps_logged is not None
                else "NO-DATA"
            )
            ru = (
                str(r.residual_unexplained)
                if r.residual_unexplained is not None
                else "NO-DATA"
            )
            pm = (
                str(r.publish_misses)
                if r.publish_misses is not None
                else "NO-DATA"
            )
            print(
                f"L{r.line_no} wall={r.wall_s} d_wall={r.d_wall_s} "
                f"d_fr={r.d_frames} d_pr={r.d_presents} d_dr={r.d_drops} "
                f"d_pm={r.d_publish_misses} "
                f"frames={r.frames} presents={r.presents} drops={r.drops} "
                f"publish_misses={pm} residual_arm={r.residual_arm} "
                f"residual_unexplained={ru} iv_vfps={iv} iv_pfps={ip} "
                f"cum_vfps={cv} src={r.src}"
            )

        last = valid[-1]
        print("--- ledger (last valid) ---")
        print(f"frames={last.frames} src={PROV_MEASURED}")
        print(f"presents={last.presents} src={PROV_MEASURED}")
        print(f"drops={last.drops} src={PROV_MEASURED}")
        if last.publish_misses is None:
            print(f"publish_misses=NO-DATA src={PROV_NO_DATA}")
        else:
            print(f"publish_misses={last.publish_misses} src={PROV_MEASURED}")
        print(f"residual_arm={last.residual_arm} eq=frames-presents-drops src={PROV_MEASURED}")
        if last.residual_unexplained is None:
            print(f"residual_unexplained=NO-DATA src={PROV_NO_DATA}")
        else:
            print(
                f"residual_unexplained={last.residual_unexplained} "
                f"eq=frames-presents-drops-publish_misses src={PROV_MEASURED}"
            )
        # series
        ras = [r.residual_arm for r in valid]
        rus = [r.residual_unexplained for r in valid if r.residual_unexplained is not None]
        print(
            f"residual_arm_series n={len(ras)} min={min(ras)} max={max(ras)} "
            f"last={ras[-1]} src={PROV_MEASURED}"
        )
        if rus:
            print(
                f"residual_unexplained_series n={len(rus)} min={min(rus)} "
                f"max={max(rus)} last={rus[-1]} src={PROV_MEASURED}"
            )
        ivs = [r.iv_vfps for r in valid if r.iv_vfps is not None]
        if ivs:
            print(
                f"iv_vfps_series n={len(ivs)} min={min(ivs):.6f} "
                f"median={statistics.median(ivs):.6f} max={max(ivs):.6f} "
                f"src={PROV_MEASURED}"
            )

    for n in rep.notes:
        print(f"NOTE: {n}")
    print(f"reason={rep.reason}")
    print(f"VERDICT={rep.verdict} rc={rep.rc}")
    if rep.rc == RC_SESSION:
        print(
            "NOTE: rc=79 SESSION_INVALID aligns w-instr daemon_media_ledger / "
            "w-avsync; soak spanning respawn is void — never a pass"
        )
    if rep.rc == RC_RESIDUAL:
        print(
            "NOTE: residual_unexplained!=0 is the user finding — frames missing "
            "outside pacer Drop and counted publish fail"
        )
    if rep.rc == RC_NO_DATA:
        print("NOTE: rc=77 NO-DATA is never a pass")
    if rep.rc == RC_INSUFFICIENT:
        print("NOTE: rc=78 INSUFFICIENT_EVIDENCE is never a pass")
    return rep.rc


def _self_test() -> int:
    fails = 0

    def check(cond: bool, msg: str) -> None:
        nonlocal fails
        if cond:
            print(f"PASS {msg}")
        else:
            print(f"FAIL {msg}")
            fails += 1

    # GREEN: closed residual_unexplained=0, healthy iv_vfps
    healthy_lines = []
    for t in range(0, 20):
        fr = 24 * t
        pr = fr  # no drops
        healthy_lines.append(
            f"media: supply_bucket wall_s={t+1:.3f} d_wall_s=1.000 "
            f"d_frames=24 d_presents=24 d_drops=0 d_publish_misses=0 "
            f"d_residual=0 residual=0 residual_unexplained=0 "
            f"frames={fr+24} presents={pr+24} drops=0 publish_misses=0 "
            f"iv_vfps=24.000000 iv_pfps=24.000000 "
            f"fps=24/1 fps_src=caller_supplied session_epoch=1.1 "
            f"process_epoch=1 pid=10 tag=measured"
        )
    rounds, meta, notes = parse_log("\n".join(healthy_lines))
    r = classify(rounds, meta, notes, 24.0, PROV_CALLER)
    check(r.rc == RC_OK and r.verdict == "LEDGER_OK", f"healthy LEDGER_OK got rc={r.rc} {r.verdict}")

    # RED: residual_unexplained = 16 (user finding)
    bad = (
        "media: supply_bucket wall_s=5.000 d_wall_s=1.000 d_frames=24 d_presents=8 "
        "d_drops=0 d_publish_misses=0 d_residual=16 residual=16 residual_unexplained=16 "
        "frames=100 presents=80 drops=4 publish_misses=0 "
        "iv_vfps=24.000000 iv_pfps=8.000000 session_epoch=1.1 process_epoch=1 pid=10\n"
        "media: supply_bucket wall_s=6.000 d_wall_s=1.000 d_frames=24 d_presents=24 "
        "d_drops=0 d_publish_misses=0 d_residual=0 residual=16 residual_unexplained=16 "
        "frames=124 presents=104 drops=4 publish_misses=0 "
        "iv_vfps=24.000000 iv_pfps=24.000000 session_epoch=1.1 process_epoch=1 pid=10\n"
        "media: supply_bucket wall_s=7.000 d_wall_s=1.000 d_frames=24 d_presents=24 "
        "d_drops=0 d_publish_misses=0 d_residual=0 residual=16 residual_unexplained=16 "
        "frames=148 presents=128 drops=4 publish_misses=0 "
        "iv_vfps=24.000000 iv_pfps=24.000000 session_epoch=1.1 process_epoch=1 pid=10\n"
    )
    rounds, meta, notes = parse_log(bad)
    r = classify(rounds, meta, notes, 24.0, PROV_CALLER)
    check(
        r.rc == RC_RESIDUAL and r.verdict == "LEDGER_RESIDUAL",
        f"unexplained residual LOUD rc=2 got rc={r.rc} {r.verdict}",
    )
    check(
        r.rounds[-1].residual_unexplained == 16,
        f"residual_unexplained=16 got {r.rounds[-1].residual_unexplained}",
    )

    # GREEN: residual_arm==publish_misses ⇒ unexplained 0
    pub_ok = (
        "media: frames=100 presents=95 drops=3 publish_misses=2 residual=2 "
        "residual_unexplained=0 wall_s=4.0 session_epoch=1.1 process_epoch=1 pid=10 "
        "tag=measured\n"
        "media: frames=124 presents=119 drops=3 publish_misses=2 residual=2 "
        "residual_unexplained=0 wall_s=5.0 session_epoch=1.1 process_epoch=1 pid=10 "
        "tag=measured\n"
        "media: frames=148 presents=143 drops=3 publish_misses=2 residual=2 "
        "residual_unexplained=0 wall_s=6.0 session_epoch=1.1 process_epoch=1 pid=10 "
        "tag=measured\n"
        "media: frames=172 presents=167 drops=3 publish_misses=2 residual=2 "
        "residual_unexplained=0 wall_s=7.0 session_epoch=1.1 process_epoch=1 pid=10 "
        "tag=measured\n"
    )
    rounds, meta, notes = parse_log(pub_ok)
    r = classify(rounds, meta, notes, 24.0, PROV_CALLER)
    check(
        r.rc == RC_OK and r.rounds[-1].residual_unexplained == 0,
        f"explained by publish_misses OK got rc={r.rc} ru={r.rounds[-1].residual_unexplained}",
    )

    # RED: FPS collapse (lockstep short) with closed residual
    collapse = []
    for t in range(0, 15):
        # 12 fps instead of 24 after warm-up
        fr = 12 * (t + 1)
        collapse.append(
            f"media: supply_bucket wall_s={float(t+1):.3f} d_wall_s=1.000 "
            f"d_frames=12 d_presents=12 d_drops=0 d_publish_misses=0 "
            f"d_residual=0 residual=0 residual_unexplained=0 "
            f"frames={fr} presents={fr} drops=0 publish_misses=0 "
            f"iv_vfps=12.000000 iv_pfps=12.000000 "
            f"session_epoch=1.1 process_epoch=1 pid=10 tag=measured"
        )
    rounds, meta, notes = parse_log("\n".join(collapse))
    r = classify(rounds, meta, notes, 24.0, PROV_CALLER)
    check(
        r.rc in (RC_FPS, RC_BOTH) and "FPS" in r.verdict,
        f"FPS_COLLAPSE got rc={r.rc} {r.verdict}",
    )

    # RED: session respawn
    respawn = (
        "media: frames=500 presents=496 drops=4 publish_misses=0 residual=0 "
        "residual_unexplained=0 wall_s=20 session_epoch=1.1 process_epoch=1 pid=10\n"
        "media: frames=10 presents=9 drops=1 publish_misses=0 residual=0 "
        "residual_unexplained=0 wall_s=0.5 session_epoch=1.2 process_epoch=2 pid=11\n"
    )
    rounds, meta, notes = parse_log(respawn)
    r = classify(rounds, meta, notes, 24.0, PROV_CALLER)
    check(
        r.rc == RC_SESSION and r.verdict == "SESSION_INVALID",
        f"session invalid rc=79 got rc={r.rc} {r.verdict} {r.reason}",
    )

    # RED: EXIT marker mid-window
    exit_log = (
        "media: frames=100 presents=100 drops=0 publish_misses=0 residual=0 "
        "residual_unexplained=0 wall_s=4 session_epoch=1.1 process_epoch=1 pid=10\n"
        "EXIT pid=1234 rc=0 run_s=1543\n"
        "media: frames=20 presents=20 drops=0 publish_misses=0 residual=0 "
        "residual_unexplained=0 wall_s=1 session_epoch=2.1 process_epoch=2 pid=11\n"
    )
    rounds, meta, notes = parse_log(exit_log)
    r = classify(rounds, meta, notes, 24.0, PROV_CALLER)
    check(r.rc == RC_SESSION, f"EXIT marker rc=79 got rc={r.rc}")

    # cumulative vs interval artifact fixture
    # cumulative vfps looks "improving" while interval stays short
    art = []
    # 10s at 12fps then continues — cumulative climbs toward 12, not 24
    for t in range(1, 12):
        fr = 12 * t
        # fake cumulative vfps = frames/wall climbing display artifact style
        cum = fr / float(t)  # always 12
        art.append(
            f"media: frames={fr} presents={fr} drops=0 publish_misses=0 residual=0 "
            f"residual_unexplained=0 wall_s={float(t):.1f} vfps={cum:.4f} "
            f"session_epoch=1.1 process_epoch=1 pid=10 tag=measured"
        )
    rounds, meta, notes = parse_log("\n".join(art))
    r = classify(rounds, meta, notes, 24.0, PROV_CALLER)
    check(
        r.rc in (RC_FPS, RC_BOTH) or (
            r.rc == RC_OK and any("FPS axis" in n for n in r.notes)
        ),
        f"interval detects short (not cum vfps) rc={r.rc} notes={r.notes[:2]}",
    )
    # Ensure we computed iv from deltas
    ivs = [x.iv_vfps for x in rounds if x.iv_vfps is not None]
    check(ivs and all(abs(v - 12.0) < 0.01 for v in ivs), f"iv_vfps~12 got {ivs[:5]}")

    # Identity unit
    check(residual_unexplained(100, 80, 4, 0) == 16, "identity unexplained 16")
    check(residual_unexplained(100, 95, 3, 2) == 0, "identity explained 0")
    check(residual_arm(100, 95, 3) == 2, "identity residual_arm 2")

    if fails:
        print(f"SELF_TEST_FAIL fails={fails}")
        return 1
    print("SELF_TEST_OK red-before-green")
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--daemon-log", type=Path, help="daemon log / pulled media lines")
    ap.add_argument(
        "--content-fps",
        type=float,
        default=None,
        help="content fps (fixtures 24.000 exact). Required for FPS axis unless fps= in log",
    )
    ap.add_argument(
        "--content-fps-src",
        choices=(PROV_MEASURED, PROV_CALLER, PROV_DEFAULT),
        default=None,
    )
    ap.add_argument(
        "--fps-ok-min-ratio",
        type=float,
        default=0.90,
        help="DEFAULT_ASSUMED floor = content_fps * ratio for iv_vfps (default 0.90)",
    )
    ap.add_argument("--min-rounds", type=int, default=3)
    ap.add_argument("--json", action="store_true", help="emit JSON report line")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(list(argv) if argv is not None else None)

    if args.self_test:
        return _self_test()

    if not args.daemon_log:
        ap.error("--daemon-log required (or --self-test)")
        return RC_USAGE

    text = args.daemon_log.read_text(errors="replace")
    rounds, meta, notes = parse_log(text)

    # content fps resolution
    content_fps = args.content_fps
    content_fps_src = args.content_fps_src
    if content_fps is None:
        # try fps=N/D from first supply_bucket / media
        m = re.search(r"\bfps=(\d+)/(\d+)", text)
        if m:
            den = int(m.group(2)) or 1
            content_fps = int(m.group(1)) / den
            content_fps_src = PROV_MEASURED
            notes.append(f"content_fps from log fps={m.group(1)}/{m.group(2)}")
        else:
            content_fps = 24.0
            content_fps_src = PROV_DEFAULT
            notes.append(
                "content_fps=24.0 DEFAULT_ASSUMED — pass --content-fps with "
                "caller_supplied or measured PMS frameRate"
            )
    else:
        if content_fps_src is None:
            content_fps_src = PROV_CALLER

    rep = classify(
        rounds,
        meta,
        notes,
        content_fps=content_fps,
        content_fps_src=content_fps_src or PROV_CALLER,
        fps_ok_min_ratio=args.fps_ok_min_ratio,
        min_rounds=args.min_rounds,
    )
    rc = print_report(rep)
    if args.json:
        print(
            "JSON "
            + json.dumps(
                {
                    "verdict": rep.verdict,
                    "rc": rep.rc,
                    "reason": rep.reason,
                    "coverage": rep.coverage,
                    "content_fps": rep.content_fps,
                    "content_fps_src": rep.content_fps_src,
                },
                sort_keys=True,
            )
        )
    return rc


if __name__ == "__main__":
    sys.exit(main())
