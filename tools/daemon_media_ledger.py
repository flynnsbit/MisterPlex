#!/usr/bin/env python3
"""Reconstruct the ARM supply frame ledger from daemon media: log lines.

WHY (promotion blocker / rd-review S2)
-------------------------------------
Parent's pixel-blind soak tool printed:
  presents=null publish_misses=NO-DATA residual=NO-DATA
because the running daemon emits counters on TWO separate lines:

  media: frames=699 vfps=... drops=4 fps=24/1 ...     # 1 Hz stats (no presents)
  media: fpga frame_tx ok via DDR presents=672 frames=676 ms=4   # every 48 presents

Those two lines are sampled at different instants (frames disagree: 699 vs 676).
A tool that only reads the 1 Hz line cannot close the free ledger:

  residual = frames - presents - drops

and under-states loss as drops alone (ERROR class: quoting drops=4 while
~16 frames are unaccounted vs wall*src_fps).

THIS TOOL
---------
1. Prefer an ATOMIC 1 Hz line that already carries frames+presents+drops
   (+ residual/publish_misses) via frameLedgerTelemetryFragment — tag measured.
2. Else RECONSTRUCT by pairing each DDR presents line with the nearest stats
   line's drops (and report frames_skew). Tag residual reconstructed — never
   measured. Per ERROR 17 provenance rules.
3. residual != 0 (and not explained by publish_misses) is LOUD FAIL.
4. Session restart / counter reset / multi-epoch → VERDICT=SESSION_INVALID
   rc=79 — same convention as w-avsync (avsync_audio_telemetry_verdict /
   score_supply_starve SESSION_INVALID). Never a pass.

HONEST DAEMON FIX (preferred over reconstruction)
-------------------------------------------------
Tip media_player.cpp already builds the 1 Hz line as:
  log("media: " + frameLedgerTelemetryFragment(led) + " vfps=...");
which emits frames/presents/drops/publish_misses/residual atomically
(tag=measured). If your log looks like the split fixture, the deployed
binary is older than that fragment OR the collector filtered fields.

Minimal additive patch on the DDR heartbeat (even on old trees) so a single
line is a closed snapshot without waiting for 1 Hz:

  // media_player.cpp ~presentCount_%48==0 block
  log("media: fpga frame_tx ok via DDR"
      " presents=" + std::to_string(presentCount_) +
      " frames=" + std::to_string(frameIndex) +
      " drops=" + std::to_string(droppedFrames_.load()) +
      " publish_misses=" + std::to_string(publishMisses_.load()) +
      " residual=" + std::to_string(
            frameLedgerResidual(frameIndex, presentCount_,
                                droppedFrames_.load())) +
      " residual_eq=frames-presents-drops"
      " tag=measured"
      " ms=" + ...);

Parent deploys; this tool then scores residual as measured.

Exit codes (capture DIRECTLY: cmd; echo "true rc=$?" — never through a pipe)
--------------------------------------------------------------------------
  0   LEDGER_OK          residual==0 or residual==publish_misses
  2   LEDGER_RESIDUAL    residual unexplained and non-zero (LOUD)
  79  SESSION_INVALID    epoch/pid/respawn/counter-reset (align w-avsync)
  77  NO-DATA            cannot pair / no media lines — never a pass
  1   usage

Rule 0: every value tagged measured | reconstructed | caller_supplied |
DEFAULT_ASSUMED | NO-DATA. Reconstruction is never printed as measured.
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

RC_OK = 0
RC_USAGE = 1
RC_RESIDUAL = 2
RC_SESSION_INVALID = 79  # w-avsync SESSION_INVALID / session_epoch_changed
RC_NO_DATA = 77

PROV_MEASURED = "measured"
PROV_RECON = "reconstructed"
PROV_CALLER = "caller_supplied"
PROV_DEFAULT = "DEFAULT_ASSUMED"
PROV_NO_DATA = "NO-DATA"

RE_KV = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)")
RE_EXIT = re.compile(
    r"\bEXIT pid=\d+\b|\bSUPERVISE_EXIT\b|\bevent=process_exit\b|\bevent=process_start\b"
)


def _i(kv: Dict[str, str], k: str) -> Optional[int]:
    v = kv.get(k)
    if v is None or v == "NO-DATA":
        return None
    try:
        return int(float(v))
    except ValueError:
        return None


def _f(kv: Dict[str, str], k: str) -> Optional[float]:
    v = kv.get(k)
    if v is None or v == "NO-DATA":
        return None
    try:
        return float(v)
    except ValueError:
        return None


@dataclass
class MediaEvent:
    line_no: int
    kind: str  # stats | ddr | atomic | other | exit
    raw: str
    frames: Optional[int] = None
    presents: Optional[int] = None
    drops: Optional[int] = None
    publish_misses: Optional[int] = None
    residual_logged: Optional[int] = None
    wall_s: Optional[float] = None
    vfps: Optional[float] = None
    pfps: Optional[float] = None
    session_epoch: Optional[str] = None
    process_epoch: Optional[str] = None
    pid: Optional[str] = None
    fps_num: Optional[int] = None
    fps_den: Optional[int] = None


@dataclass
class PairSnap:
    """One closed (or nearly closed) ledger snapshot."""
    frames: int
    presents: int
    drops: int
    publish_misses: Optional[int]
    residual: int
    residual_src: str  # measured | reconstructed
    frames_src: str
    presents_src: str
    drops_src: str
    frames_skew: int  # stats.frames - ddr.frames when paired; 0 if atomic
    pair_method: str
    wall_s: Optional[float]
    line_no: int
    raw_stats: str = ""
    raw_ddr: str = ""


@dataclass
class Report:
    verdict: str
    rc: int
    reason: str
    snaps: List[PairSnap] = field(default_factory=list)
    last: Optional[PairSnap] = None
    continuity_ok: bool = True
    continuity_reason: str = "continuous"
    n_stats: int = 0
    n_ddr: int = 0
    n_atomic: int = 0
    n_exit: int = 0
    session_epochs: List[str] = field(default_factory=list)
    process_epochs: List[str] = field(default_factory=list)
    pids: List[str] = field(default_factory=list)
    notes: List[str] = field(default_factory=list)


def parse_events(text: str) -> List[MediaEvent]:
    evs: List[MediaEvent] = []
    for i, line in enumerate(text.splitlines(), 1):
        if RE_EXIT.search(line) and "media:" not in line:
            evs.append(MediaEvent(line_no=i, kind="exit", raw=line.strip()))
            continue
        if "media:" not in line:
            continue
        body = line.split("media:", 1)[1].strip()
        kv = {a: b for a, b in RE_KV.findall(body)}
        frames = _i(kv, "frames")
        presents = _i(kv, "presents")
        drops = _i(kv, "drops")
        pub = _i(kv, "publish_misses")
        resid = _i(kv, "residual")
        if resid is None:
            resid = _i(kv, "unaccounted")

        kind = "other"
        if body.startswith("fpga frame_tx") or (
            "frame_tx ok" in body and presents is not None
        ):
            kind = "ddr"
        elif (
            frames is not None
            and presents is not None
            and drops is not None
            and not body.startswith("session end")
        ):
            kind = "atomic"
        elif frames is not None and (
            "vfps=" in body or "wall_s=" in body or "drops=" in body
        ):
            kind = "stats"
        elif body.startswith("session end") and frames is not None and presents is not None:
            kind = "atomic"

        fps_num = fps_den = None
        if "fps=" in kv:
            # kv fps may be "24/1"
            pass
        m_fps = re.search(r"\bfps=(\d+)/(\d+)\b", body)
        if m_fps:
            fps_num, fps_den = int(m_fps.group(1)), int(m_fps.group(2))

        # pid only when it is daemon pid on media line (not si_pid)
        pid = None
        cleaned = re.sub(r"\bsi_pid=[0-9]+", " ", body)
        mp = re.search(r"(?:^|[\s])pid=([0-9]+)\b", cleaned)
        if mp:
            pid = mp.group(1)

        evs.append(
            MediaEvent(
                line_no=i,
                kind=kind,
                raw=line.strip(),
                frames=frames,
                presents=presents,
                drops=drops,
                publish_misses=pub,
                residual_logged=resid,
                wall_s=_f(kv, "wall_s"),
                vfps=_f(kv, "vfps"),
                pfps=_f(kv, "pfps"),
                session_epoch=kv.get("session_epoch"),
                process_epoch=kv.get("process_epoch"),
                pid=pid,
                fps_num=fps_num,
                fps_den=fps_den,
            )
        )
    return evs


def check_continuity(evs: List[MediaEvent]) -> Tuple[bool, str]:
    """Return (ok, reason). Fail closed on restart signatures."""
    epochs = {e.session_epoch for e in evs if e.session_epoch}
    peps = {e.process_epoch for e in evs if e.process_epoch}
    pids = {e.pid for e in evs if e.pid}
    n_exit = sum(1 for e in evs if e.kind == "exit")
    if n_exit > 0:
        return False, f"session_restart_marker exit_lines={n_exit}"
    if len(epochs) > 1:
        return False, f"session_epoch_changed {sorted(epochs)}"
    if len(peps) > 1:
        return False, f"process_epoch_changed {sorted(peps)}"
    if len(pids) > 1:
        return False, f"pid_changed {sorted(pids)}"

    prev_f: Optional[int] = None
    prev_w: Optional[float] = None
    for e in evs:
        if e.kind not in ("stats", "atomic", "ddr"):
            continue
        if e.wall_s is not None:
            if prev_w is not None and e.wall_s + 0.05 < prev_w:
                return False, f"wall_s_reset {prev_w}->{e.wall_s} line={e.line_no}"
            prev_w = e.wall_s
        if e.frames is not None and e.kind in ("stats", "atomic"):
            if prev_f is not None and e.frames < prev_f:
                return False, f"frames_reset {prev_f}->{e.frames} line={e.line_no}"
            prev_f = e.frames
    return True, "continuous"


def _nearest_stats(
    stats: List[MediaEvent], target_frames: int, at_or_before_line: int
) -> Optional[MediaEvent]:
    """Prefer stats with frames closest to target, at or before DDR line."""
    cand = [s for s in stats if s.line_no <= at_or_before_line and s.drops is not None]
    if not cand:
        cand = [s for s in stats if s.drops is not None]
    if not cand:
        return None
    cand.sort(key=lambda s: (abs((s.frames or 0) - target_frames), -s.line_no))
    return cand[0]


def build_snaps(evs: List[MediaEvent]) -> Tuple[List[PairSnap], List[str]]:
    notes: List[str] = []
    atomics = [e for e in evs if e.kind == "atomic"]
    stats = [e for e in evs if e.kind == "stats"]
    ddrs = [e for e in evs if e.kind == "ddr"]
    snaps: List[PairSnap] = []

    # Path A — measured atomic lines (preferred)
    for e in atomics:
        assert e.frames is not None and e.presents is not None and e.drops is not None
        resid = e.frames - e.presents - e.drops
        if e.residual_logged is not None and e.residual_logged != resid:
            notes.append(
                f"atomic residual_logged={e.residual_logged} != calc={resid} "
                f"line={e.line_no} (using calc)"
            )
        snaps.append(
            PairSnap(
                frames=e.frames,
                presents=e.presents,
                drops=e.drops,
                publish_misses=e.publish_misses,
                residual=resid,
                residual_src=PROV_MEASURED,
                frames_src=PROV_MEASURED,
                presents_src=PROV_MEASURED,
                drops_src=PROV_MEASURED,
                frames_skew=0,
                pair_method="atomic_single_line",
                wall_s=e.wall_s,
                line_no=e.line_no,
                raw_stats=e.raw,
            )
        )
    if snaps:
        notes.append(
            f"used n_atomic={len(snaps)} single-line snapshots src={PROV_MEASURED}"
        )
        return snaps, notes

    # Path B — reconstruct from split DDR + stats
    if not ddrs:
        notes.append("no DDR presents= lines and no atomic lines")
        return [], notes
    if not stats:
        notes.append("no stats drops= lines to pair with DDR presents")
        # still can emit presents-only NO residual without drops
        return [], notes

    for d in ddrs:
        if d.presents is None or d.frames is None:
            continue
        s = _nearest_stats(stats, d.frames, d.line_no)
        if s is None or s.drops is None:
            continue
        # residual closed on the DDR snapshot's frames/presents + paired drops
        resid = d.frames - d.presents - s.drops
        skew = (s.frames or d.frames) - d.frames
        snaps.append(
            PairSnap(
                frames=d.frames,
                presents=d.presents,
                drops=s.drops,
                publish_misses=s.publish_misses if s.publish_misses is not None else d.publish_misses,
                residual=resid,
                residual_src=PROV_RECON,
                frames_src=f"{PROV_MEASURED}_ddr_line",
                presents_src=f"{PROV_MEASURED}_ddr_line",
                drops_src=f"{PROV_RECON}_nearest_stats_line",
                frames_skew=int(skew),
                pair_method="ddr_presents+nearest_stats_drops",
                wall_s=s.wall_s,
                line_no=d.line_no,
                raw_stats=s.raw,
                raw_ddr=d.raw,
            )
        )

    # Also emit a terminal cross-line view using LAST stats frames + LAST ddr
    # presents — this is what a naive tool would do; we label the confound.
    if stats and ddrs and snaps:
        s_last = stats[-1]
        d_last = ddrs[-1]
        if (
            s_last.frames is not None
            and s_last.drops is not None
            and d_last.presents is not None
            and d_last.frames is not None
        ):
            cross_resid = s_last.frames - d_last.presents - s_last.drops
            cross_skew = s_last.frames - d_last.frames
            notes.append(
                f"cross_line_naive frames_stats={s_last.frames} "
                f"presents_ddr={d_last.presents} drops_stats={s_last.drops} "
                f"residual_cross={cross_resid} frames_skew={cross_skew} "
                f"src={PROV_RECON} — residual_cross confounds true residual "
                f"with sampling lag; prefer ddr-snapshot residual "
                f"({snaps[-1].residual})"
            )

    notes.append(
        f"reconstructed n_snaps={len(snaps)} from n_ddr={len(ddrs)} n_stats={len(stats)} "
        f"src={PROV_RECON} — NOT measured; deploy atomic 1 Hz fragment to upgrade"
    )
    return snaps, notes


def classify(evs: List[MediaEvent]) -> Report:
    ok_c, reason_c = check_continuity(evs)
    stats = [e for e in evs if e.kind == "stats"]
    ddrs = [e for e in evs if e.kind == "ddr"]
    atomics = [e for e in evs if e.kind == "atomic"]
    exits = [e for e in evs if e.kind == "exit"]
    epochs = sorted({e.session_epoch for e in evs if e.session_epoch})
    peps = sorted({e.process_epoch for e in evs if e.process_epoch})
    pids = sorted({e.pid for e in evs if e.pid})

    rep = Report(
        verdict="NO-DATA",
        rc=RC_NO_DATA,
        reason="init",
        n_stats=len(stats),
        n_ddr=len(ddrs),
        n_atomic=len(atomics),
        n_exit=len(exits),
        session_epochs=epochs,
        process_epochs=peps,
        pids=pids,
        continuity_ok=ok_c,
        continuity_reason=reason_c,
    )

    if not ok_c:
        rep.verdict = "SESSION_INVALID"
        rep.rc = RC_SESSION_INVALID
        rep.reason = reason_c
        # still try to parse snaps for diagnostics
        snaps, notes = build_snaps(evs)
        rep.snaps = snaps
        rep.last = snaps[-1] if snaps else None
        rep.notes = notes
        return rep

    snaps, notes = build_snaps(evs)
    rep.snaps = snaps
    rep.notes = notes
    if not snaps:
        rep.verdict = "NO-DATA"
        rep.rc = RC_NO_DATA
        rep.reason = (
            "cannot_close_ledger: need atomic frames+presents+drops line "
            "OR ddr presents= + stats drops= pair"
        )
        return rep

    last = snaps[-1]
    rep.last = last
    pub = last.publish_misses
    explained = pub is not None and last.residual == pub
    closed = last.residual == 0 or explained

    # Any snap with unexplained residual is loud (session not fully closed)
    bad = [
        s
        for s in snaps
        if s.residual != 0
        and not (s.publish_misses is not None and s.residual == s.publish_misses)
    ]
    # Tolerate tiny reconstruction noise only if |residual|<=0 — never weaken.
    if bad:
        b = bad[-1]
        rep.verdict = "LEDGER_RESIDUAL"
        rep.rc = RC_RESIDUAL
        rep.reason = (
            f"unexplained_residual={b.residual} "
            f"frames={b.frames} presents={b.presents} drops={b.drops} "
            f"publish_misses={b.publish_misses} "
            f"residual_src={b.residual_src} pair={b.pair_method}"
        )
        return rep

    if closed:
        rep.verdict = "LEDGER_OK"
        rep.rc = RC_OK
        rep.reason = (
            f"residual={last.residual} explained_by_publish_misses="
            f"{1 if explained else 0} residual_src={last.residual_src}"
        )
        return rep

    rep.verdict = "LEDGER_RESIDUAL"
    rep.rc = RC_RESIDUAL
    rep.reason = f"residual={last.residual} residual_src={last.residual_src}"
    return rep


def print_report(rep: Report) -> int:
    print("=== daemon_media_ledger ===")
    print(
        "semantics: frames=pipe assembled; presents=DDR publish ok; "
        "drops=A/V-pacer skips ONLY; publish_misses=DDR fail; "
        "residual=frames-presents-drops"
    )
    print(
        "CANNOT_CLAIM: drops alone is full loss; cross-line residual confounds "
        "sampling lag with true residual — prefer atomic 1 Hz fragment"
    )
    print(
        f"n_stats={rep.n_stats} n_ddr={rep.n_ddr} n_atomic={rep.n_atomic} "
        f"n_exit={rep.n_exit} n_snaps={len(rep.snaps)} src={PROV_MEASURED}"
    )
    print(
        f"continuity_ok={1 if rep.continuity_ok else 0} "
        f"reason={rep.continuity_reason} src={PROV_MEASURED}"
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
    for n in rep.notes:
        print(f"NOTE: {n}")

    if rep.last:
        s = rep.last
        print("--- ledger (last closed snapshot) ---")
        print(f"frames={s.frames} src={s.frames_src}")
        print(f"presents={s.presents} src={s.presents_src}")
        print(f"drops={s.drops} src={s.drops_src}")
        if s.publish_misses is None:
            print(f"publish_misses=NO-DATA src={PROV_NO_DATA}")
        else:
            pm_src = (
                PROV_MEASURED
                if s.residual_src == PROV_MEASURED
                else f"{PROV_RECON}_paired_line"
            )
            print(f"publish_misses={s.publish_misses} src={pm_src}")
        print(f"residual={s.residual} src={s.residual_src}")
        print(f"residual_eq=frames-presents-drops src={PROV_MEASURED}")
        print(f"frames_skew={s.frames_skew} src={s.residual_src}")
        print(f"pair_method={s.pair_method} src={PROV_MEASURED}")
        if s.wall_s is not None:
            print(f"wall_s={s.wall_s} src={PROV_MEASURED}")
        print(f"line_no={s.line_no} src={PROV_MEASURED}")
        # series summary
        resid_series = [x.residual for x in rep.snaps]
        print(
            f"residual_series_n={len(resid_series)} "
            f"min={min(resid_series)} max={max(resid_series)} "
            f"last={resid_series[-1]} src={s.residual_src}"
        )
        unexplained = [
            x.residual
            for x in rep.snaps
            if x.residual != 0
            and not (
                x.publish_misses is not None and x.residual == x.publish_misses
            )
        ]
        print(
            f"unexplained_residual_count={len(unexplained)} src={PROV_MEASURED}"
        )
    else:
        print("--- ledger ---")
        print(f"frames=NO-DATA presents=NO-DATA drops=NO-DATA residual=NO-DATA "
              f"src={PROV_NO_DATA}")

    print(f"reason={rep.reason}")
    print(f"VERDICT={rep.verdict} rc={rep.rc}")
    if rep.rc == RC_SESSION_INVALID:
        print(
            "NOTE: rc=79 SESSION_INVALID aligns w-avsync "
            "(session_epoch_changed / process respawn); ledger spanning a "
            "restart is void — never a pass"
        )
    if rep.rc == RC_RESIDUAL:
        print(
            "NOTE: non-zero residual is unexplained supply loss "
            "(not equal to publish_misses). Do not promote on drops alone."
        )
    if rep.rc == RC_NO_DATA:
        print("NOTE: rc=77 NO-DATA is never a pass")
    return rep.rc


def _self_test() -> int:
    # GREEN: atomic residual 0
    atomic_ok = (
        "media: frames=100 presents=96 drops=4 publish_misses=0 residual=0 "
        "wall_s=4.0 vfps=24.0 session_epoch=1.1 process_epoch=1 pid=10 tag=measured\n"
        "media: frames=200 presents=196 drops=4 publish_misses=0 residual=0 "
        "wall_s=8.0 vfps=24.0 session_epoch=1.1 process_epoch=1 pid=10 tag=measured\n"
    )
    r = classify(parse_events(atomic_ok))
    assert r.rc == RC_OK and r.verdict == "LEDGER_OK", r
    assert r.last and r.last.residual_src == PROV_MEASURED
    assert r.last.presents == 196
    print("SELF_TEST atomic LEDGER_OK rc=0 OK")

    # RED: atomic residual unexplained
    atomic_bad = (
        "media: frames=100 presents=80 drops=4 publish_misses=0 residual=16 "
        "wall_s=4.0 session_epoch=1.1 process_epoch=1 pid=10\n"
    )
    r = classify(parse_events(atomic_bad))
    assert r.rc == RC_RESIDUAL and r.verdict == "LEDGER_RESIDUAL", r
    assert r.last and r.last.residual == 16
    print("SELF_TEST atomic residual LOUD rc=2 OK")

    # GREEN: residual explained by publish_misses
    atomic_pub = (
        "media: frames=100 presents=95 drops=3 publish_misses=2 residual=2 "
        "wall_s=4.0 session_epoch=1.1 process_epoch=1 pid=10\n"
    )
    r = classify(parse_events(atomic_pub))
    assert r.rc == RC_OK and r.last and r.last.residual == 2, r
    print("SELF_TEST residual==publish_misses OK rc=0")

    # GREEN reconstructed: DDR frames-presents == drops from stats
    split_ok = (
        "media: frames=50 vfps=20 wall_s=2.0 drops=4 fps=24/1\n"
        "media: fpga frame_tx ok via DDR presents=48 frames=52 ms=4\n"
        "media: frames=96 vfps=23 wall_s=4.0 drops=4 fps=24/1\n"
        "media: fpga frame_tx ok via DDR presents=96 frames=100 ms=4\n"
        "media: frames=120 vfps=23.5 wall_s=5.0 drops=4 fps=24/1\n"
    )
    r = classify(parse_events(split_ok))
    assert r.rc == RC_OK, (r.verdict, r.reason, r.last)
    assert r.last and r.last.residual_src == PROV_RECON
    assert r.last.residual == 0 and r.last.presents == 96
    assert any("reconstructed" in n for n in r.notes)
    print("SELF_TEST split reconstruct residual=0 rc=0 OK")

    # RED reconstructed residual
    split_bad = (
        "media: frames=50 vfps=20 wall_s=2.0 drops=0 fps=24/1\n"
        "media: fpga frame_tx ok via DDR presents=40 frames=52 ms=4\n"
    )
    r = classify(parse_events(split_bad))
    assert r.rc == RC_RESIDUAL, r
    assert r.last and r.last.residual == 12  # 52-40-0
    print("SELF_TEST split residual LOUD rc=2 OK")

    # RED session restart via frames reset
    respawn = (
        "media: frames=500 presents=496 drops=4 residual=0 "
        "wall_s=20 session_epoch=1.1 process_epoch=1 pid=10\n"
        "media: frames=10 presents=9 drops=1 residual=0 "
        "wall_s=0.5 session_epoch=1.2 process_epoch=2 pid=11\n"
    )
    r = classify(parse_events(respawn))
    assert r.rc == RC_SESSION_INVALID and r.verdict == "SESSION_INVALID", r
    assert "session_epoch_changed" in r.reason or "process_epoch" in r.reason or "frames_reset" in r.reason
    print("SELF_TEST session invalid rc=79 OK")

    # RED EXIT marker
    exit_log = (
        "media: frames=100 presents=96 drops=4 residual=0 wall_s=4 session_epoch=1.1\n"
        "EXIT pid=1234 rc=0 run_s=1543\n"
        "media: frames=20 presents=20 drops=0 residual=0 wall_s=1 session_epoch=2.1\n"
    )
    r = classify(parse_events(exit_log))
    assert r.rc == RC_SESSION_INVALID, r
    print("SELF_TEST EXIT marker rc=79 OK")

    # NO-DATA: stats only
    stats_only = "media: frames=100 vfps=23 drops=4 wall_s=4 fps=24/1\n"
    r = classify(parse_events(stats_only))
    assert r.rc == RC_NO_DATA, r
    print("SELF_TEST stats-only NO-DATA rc=77 OK")

    print("SELF_TEST_OK")
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument(
        "--log",
        action="append",
        default=[],
        help="daemon media log path (repeatable)",
    )
    ap.add_argument(
        "path",
        nargs="?",
        default=None,
        help="daemon media log (positional alternative to --log)",
    )
    args = ap.parse_args(list(argv) if argv is not None else None)

    if args.self_test:
        return _self_test()

    paths = list(args.log)
    if args.path:
        paths.append(args.path)
    if not paths:
        print("ERROR: provide log path or --self-test", file=sys.stderr)
        return RC_USAGE

    chunks: List[str] = []
    for p in paths:
        try:
            chunks.append(Path(p).read_text(encoding="utf-8", errors="replace"))
        except OSError as e:
            print(f"ERROR: {e}", file=sys.stderr)
            return RC_USAGE
    text = "\n".join(chunks)
    rep = classify(parse_events(text))
    return print_report(rep)


if __name__ == "__main__":
    sys.exit(main())
