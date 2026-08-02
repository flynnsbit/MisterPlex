#!/usr/bin/env python3
"""One-shot supply starve locus scorer for parent device runs.

Classifies supply_ratio starvation locus using only sampleable signals:
  supply_ratio, optional recv_q / wchan / sock_Bps / pipe_fill, session continuity.

Classes:
  ok | starved_transport | starved_consumer | starved_unknown | NO-DATA | SESSION_INVALID

Exit codes (capture DIRECTLY — never through a pipe):
   0  ok
   2  starved_transport
   3  starved_consumer
   4  starved_unknown   (positively starved; locus not proven — common)
  79  SESSION_INVALID   (process_epoch / session_epoch / pid changed mid-window)
  77  NO-DATA

ok_min default 0.90 is labelled DEFAULT_ASSUMED (ERROR 17 discipline).

drops = A/V pacer skips only (media_player.cpp droppedFrames_ on !present).
residual = frames - presents - drops (free ledger; surfaces non-drop gaps).

Does NOT touch the device by itself. Parent runs it against a log and optional
probe file collected on the MiSTer.

Self-check (host, no device):
  python3 tools/score_supply_starve.py --self-test
  echo "true rc=$?"
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


# --- pure locus (mirrors supply_starve_locus.hpp) --------------------------------

OK_MIN_DEFAULT = 0.90
OK_MIN_SRC_DEFAULT = "DEFAULT_ASSUMED"


@dataclass
class LocusResult:
    cls: str
    reason: str
    supply_ratio: Optional[float]
    ok_min: float
    ok_min_src: str
    residual: Optional[int]
    supply_starved: bool = False


def compute_locus(
    *,
    supply_ratio: Optional[float],
    ok_min: float = OK_MIN_DEFAULT,
    ok_min_src: str = OK_MIN_SRC_DEFAULT,
    session_invalid: bool = False,
    ffmpeg_in_pipe_write: Optional[bool] = None,  # None=NO-DATA
    daemon_in_pipe_read: Optional[bool] = None,
    recv_q: Optional[int] = None,  # None=NO-DATA; 0 is measured
    pipe_fill_peak: Optional[float] = None,
    pipe_fill_full_min: float = 0.80,
    pipe_fill_empty_max: float = 0.10,
    frames: Optional[int] = None,
    presents: Optional[int] = None,
    drops: Optional[int] = None,
) -> LocusResult:
    residual = None
    if frames is not None and presents is not None and drops is not None:
        residual = frames - presents - drops

    if session_invalid:
        return LocusResult(
            "SESSION_INVALID",
            "session_epoch_or_pid_changed",
            supply_ratio,
            ok_min,
            ok_min_src,
            residual,
        )
    if supply_ratio is None:
        return LocusResult("NO-DATA", "supply_ratio_NO-DATA", None, ok_min, ok_min_src, residual)

    starved = supply_ratio < ok_min
    if not starved:
        return LocusResult("ok", "supply_ok", supply_ratio, ok_min, ok_min_src, residual, False)

    fill_full = pipe_fill_peak is not None and pipe_fill_peak >= pipe_fill_full_min
    fill_empty = pipe_fill_peak is not None and pipe_fill_peak < pipe_fill_empty_max
    recv_high = recv_q is not None and recv_q > 0
    recv_zero = recv_q is not None and recv_q == 0

    if ffmpeg_in_pipe_write is True or fill_full or recv_high:
        reason = (
            "ffmpeg_blocked_pipe_write"
            if ffmpeg_in_pipe_write is True
            else ("rawvideo_pipe_full" if fill_full else "recv_q_nonzero")
        )
        return LocusResult(
            "starved_consumer", reason, supply_ratio, ok_min, ok_min_src, residual, True
        )

    consumer_waiting = daemon_in_pipe_read is True or fill_empty
    producer_not_blocked = ffmpeg_in_pipe_write is False
    if consumer_waiting and producer_not_blocked and recv_zero:
        return LocusResult(
            "starved_transport",
            "consumer_wait_producer_idle_recv_q_0",
            supply_ratio,
            ok_min,
            ok_min_src,
            residual,
            True,
        )

    if (
        recv_q is None
        and ffmpeg_in_pipe_write is None
        and daemon_in_pipe_read is None
        and pipe_fill_peak is None
    ):
        reason = "starved_no_locus_probes"
    elif recv_q is None or ffmpeg_in_pipe_write is None or daemon_in_pipe_read is None:
        reason = "starved_partial_probes"
    else:
        reason = "starved_probes_conflict"
    return LocusResult(
        "starved_unknown", reason, supply_ratio, ok_min, ok_min_src, residual, True
    )


def gate_rc(cls: str) -> int:
    return {
        "ok": 0,
        "starved_transport": 2,
        "starved_consumer": 3,
        "starved_unknown": 4,
        "SESSION_INVALID": 79,
        "NO-DATA": 77,
    }.get(cls, 77)


# --- log parse -------------------------------------------------------------------

RE_MEDIA = re.compile(r"\bmedia:")
RE_AUDIO = re.compile(r"\baudio_s=(?P<a>[0-9.]+)\b")
RE_WALL = re.compile(r"\bwall_s=(?P<w>[0-9.]+)\b")
RE_SR = re.compile(r"\bsupply_ratio=(?P<sr>NO-DATA|[0-9.]+)")
RE_SR_CLS = re.compile(r"\bsupply_ratio_class=(?P<c>ok|starved|NO-DATA)")
RE_EPOCH = re.compile(r"\bsession_epoch=(?P<e>[^\s]+)")
RE_PEPOCH = re.compile(r"\bprocess_epoch=(?P<p>\d+)")
RE_PID = re.compile(r"\bpid=(?P<pid>\d+)")
RE_FRAMES = re.compile(r"\bframes=(?P<v>\d+)")
RE_PRESENTS = re.compile(r"\bpresents=(?P<v>\d+)")
RE_DROPS = re.compile(r"\bdrops=(?P<v>\d+)")
RE_PUB = re.compile(r"\bpublish_misses=(?P<v>\d+)")
RE_RES = re.compile(r"\bresidual=(?P<v>-?\d+)")
RE_PFPS = re.compile(r"\bpfps=(?P<v>[0-9.]+)")


@dataclass
class MediaHit:
    line_no: int
    audio_s: Optional[float] = None
    wall_s: Optional[float] = None
    supply_ratio: Optional[float] = None  # interval if printed
    supply_ratio_kind: str = "NO-DATA"  # measured|reconstructed|NO-DATA
    session_epoch: Optional[str] = None
    process_epoch: Optional[str] = None
    pid: Optional[str] = None
    frames: Optional[int] = None
    presents: Optional[int] = None
    drops: Optional[int] = None
    publish_misses: Optional[int] = None
    residual: Optional[int] = None
    pfps: Optional[float] = None


def parse_media_lines(text: str) -> List[MediaHit]:
    hits: List[MediaHit] = []
    prev_aw: Optional[Tuple[float, float]] = None
    for i, line in enumerate(text.splitlines(), 1):
        if not RE_MEDIA.search(line):
            continue
        if "supply_bucket" in line or "supply_ledger" in line or "publish_miss " in line:
            continue
        h = MediaHit(line_no=i)
        am, wm = RE_AUDIO.search(line), RE_WALL.search(line)
        if am:
            h.audio_s = float(am.group("a"))
        if wm:
            h.wall_s = float(wm.group("w"))
        sm = RE_SR.search(line)
        if sm and sm.group("sr") != "NO-DATA":
            try:
                h.supply_ratio = float(sm.group("sr"))
                h.supply_ratio_kind = "measured"
            except ValueError:
                pass
        if h.supply_ratio is None and h.audio_s is not None and h.wall_s is not None:
            if prev_aw is not None:
                da = h.audio_s - prev_aw[0]
                dw = h.wall_s - prev_aw[1]
                if dw >= 0.40 and da >= 0.0:
                    h.supply_ratio = da / dw
                    h.supply_ratio_kind = "reconstructed"
            # also allow cumulative as last-resort window ratio when only one line
        if h.audio_s is not None and h.wall_s is not None:
            prev_aw = (h.audio_s, h.wall_s)
        em = RE_EPOCH.search(line)
        if em:
            h.session_epoch = em.group("e")
        pm = RE_PEPOCH.search(line)
        if pm:
            h.process_epoch = pm.group("p")
        pidm = RE_PID.search(line)
        if pidm:
            h.pid = pidm.group("pid")
        for rx, attr in (
            (RE_FRAMES, "frames"),
            (RE_PRESENTS, "presents"),
            (RE_DROPS, "drops"),
            (RE_PUB, "publish_misses"),
            (RE_RES, "residual"),
        ):
            m = rx.search(line)
            if m:
                setattr(h, attr, int(m.group("v")))
        pfm = RE_PFPS.search(line)
        if pfm:
            h.pfps = float(pfm.group("v"))
        # Prefer arithmetic residual when counters present
        if h.frames is not None and h.presents is not None and h.drops is not None:
            h.residual = h.frames - h.presents - h.drops
        hits.append(h)
    return hits


def window_continuity(hits: List[MediaHit]) -> Tuple[bool, str]:
    """Return (invalid, reason)."""
    epochs = {h.session_epoch for h in hits if h.session_epoch}
    peps = {h.process_epoch for h in hits if h.process_epoch}
    pids = {h.pid for h in hits if h.pid}
    if len(epochs) > 1:
        return True, f"session_epoch_changed values={sorted(epochs)}"
    if len(peps) > 1:
        return True, f"process_epoch_changed values={sorted(peps)}"
    if len(pids) > 1:
        return True, f"pid_changed values={sorted(pids)}"
    # Counter reset trap: wall_s or frames going backwards mid-window
    prev_w = None
    prev_f = None
    for h in hits:
        if h.wall_s is not None:
            if prev_w is not None and h.wall_s + 0.05 < prev_w:
                return True, f"wall_s_reset {prev_w}->{h.wall_s} line={h.line_no}"
            prev_w = h.wall_s
        if h.frames is not None:
            if prev_f is not None and h.frames < prev_f:
                return True, f"frames_reset {prev_f}->{h.frames} line={h.line_no}"
            prev_f = h.frames
    return False, "continuous"


def window_supply_ratio(hits: List[MediaHit]) -> Tuple[Optional[float], str]:
    """Prefer last established interval; else cumulative first→last audio/wall."""
    for h in reversed(hits):
        if h.supply_ratio is not None and h.supply_ratio_kind in ("measured", "reconstructed"):
            return h.supply_ratio, h.supply_ratio_kind
    # cumulative endpoints
    aw = [(h.audio_s, h.wall_s) for h in hits if h.audio_s is not None and h.wall_s is not None]
    if len(aw) >= 2:
        a0, w0 = aw[0]
        a1, w1 = aw[-1]
        dw = w1 - w0
        da = a1 - a0
        if dw >= 0.40 and da >= 0.0:
            return da / dw, "reconstructed_window"
    if len(aw) == 1 and aw[0][1] and aw[0][1] >= 3.0:
        return aw[0][0] / aw[0][1], "cumulative_single"
    return None, "NO-DATA"


def last_ledger(hits: List[MediaHit]) -> Tuple[Optional[int], Optional[int], Optional[int], Optional[int]]:
    for h in reversed(hits):
        if h.frames is not None and h.presents is not None and h.drops is not None:
            return h.frames, h.presents, h.drops, h.publish_misses
    return None, None, None, None


def load_probes(path: Optional[str]) -> Dict[str, Any]:
    if not path:
        return {}
    with open(path, "r", errors="replace") as f:
        return json.load(f)


def probes_to_kwargs(probes: Dict[str, Any]) -> Dict[str, Any]:
    """Map probe JSON to compute_locus kwargs. Missing keys stay NO-DATA."""
    kw: Dict[str, Any] = {}

    def tri(key: str) -> Optional[bool]:
        if key not in probes:
            return None
        v = probes[key]
        if v is None or v == "NO-DATA":
            return None
        if isinstance(v, bool):
            return v
        if isinstance(v, str):
            if v.lower() in ("yes", "true", "1"):
                return True
            if v.lower() in ("no", "false", "0"):
                return False
        return None

    kw["ffmpeg_in_pipe_write"] = tri("ffmpeg_in_pipe_write")
    if kw["ffmpeg_in_pipe_write"] is None and "ffmpeg_wchan" in probes:
        # list of wchan strings
        wh = probes.get("ffmpeg_wchan") or []
        if isinstance(wh, list) and wh:
            kw["ffmpeg_in_pipe_write"] = any("pipe_write" in str(x) for x in wh)
        elif wh == "NO-DATA" or wh is None:
            kw["ffmpeg_in_pipe_write"] = None

    kw["daemon_in_pipe_read"] = tri("daemon_in_pipe_read")
    if kw["daemon_in_pipe_read"] is None and "daemon_wchan" in probes:
        wh = probes.get("daemon_wchan") or []
        if isinstance(wh, list) and wh:
            kw["daemon_in_pipe_read"] = any("pipe_read" in str(x) for x in wh)

    if "recv_q" in probes and probes["recv_q"] not in (None, "NO-DATA"):
        kw["recv_q"] = int(probes["recv_q"])
    if "pipe_fill_peak" in probes and probes["pipe_fill_peak"] not in (None, "NO-DATA"):
        kw["pipe_fill_peak"] = float(probes["pipe_fill_peak"])
    if "sock_Bps" in probes and probes["sock_Bps"] not in (None, "NO-DATA"):
        # carried for print only; locus uses recv_q/wchan primarily
        pass
    return kw


def score_text(
    text: str,
    *,
    ok_min: float,
    ok_min_src: str,
    probes: Dict[str, Any],
) -> Tuple[LocusResult, Dict[str, Any]]:
    hits = parse_media_lines(text)
    meta: Dict[str, Any] = {
        "n_media_hits": len(hits),
        "ok_min": ok_min,
        "ok_min_src": ok_min_src,
    }
    if not hits:
        r = compute_locus(supply_ratio=None, ok_min=ok_min, ok_min_src=ok_min_src)
        meta["note"] = "no_media_lines"
        return r, meta

    invalid, inv_reason = window_continuity(hits)
    meta["continuity"] = inv_reason
    meta["continuity_tag"] = "measured"

    ratio, rkind = window_supply_ratio(hits)
    meta["supply_ratio"] = ratio
    meta["supply_ratio_kind"] = rkind
    meta["supply_ratio_tag"] = rkind if ratio is not None else "NO-DATA"

    fr, pr, dr, pub = last_ledger(hits)
    meta["frames"] = fr
    meta["presents"] = pr
    meta["drops"] = dr
    meta["publish_misses"] = pub if pub is not None else "NO-DATA"
    meta["drops_src"] = "av_pacer_only"
    meta["drops_note"] = (
        "drops counts deliberate A/V-pacer skips only "
        "(media_player.cpp droppedFrames_.fetch_add on !present); "
        "not ffmpeg shortfall; not DDR publish fail"
    )
    if fr is not None and pr is not None and dr is not None:
        meta["residual"] = fr - pr - dr
        meta["residual_eq"] = "frames-presents-drops"
        meta["residual_tag"] = "measured"
    else:
        meta["residual"] = "NO-DATA"
        meta["residual_tag"] = "NO-DATA"

    pkw = probes_to_kwargs(probes)
    meta["probes"] = {
        "ffmpeg_in_pipe_write": pkw.get("ffmpeg_in_pipe_write", "NO-DATA"),
        "daemon_in_pipe_read": pkw.get("daemon_in_pipe_read", "NO-DATA"),
        "recv_q": pkw.get("recv_q", "NO-DATA"),
        "pipe_fill_peak": pkw.get("pipe_fill_peak", "NO-DATA"),
        "sock_Bps": probes.get("sock_Bps", "NO-DATA"),
        "probes_tag": "caller_supplied" if probes else "NO-DATA",
    }

    r = compute_locus(
        supply_ratio=ratio,
        ok_min=ok_min,
        ok_min_src=ok_min_src,
        session_invalid=invalid,
        frames=fr,
        presents=pr,
        drops=dr,
        **pkw,
    )
    return r, meta


def print_report(r: LocusResult, meta: Dict[str, Any]) -> None:
    print(f"starve_locus={r.cls} reason={r.reason} tag=measured")
    print(
        f"supply_ratio={r.supply_ratio if r.supply_ratio is not None else 'NO-DATA'} "
        f"kind={meta.get('supply_ratio_kind', 'NO-DATA')} "
        f"ok_min={r.ok_min:.3f} ok_min_src={r.ok_min_src}"
    )
    print(
        f"residual={r.residual if r.residual is not None else meta.get('residual', 'NO-DATA')} "
        f"residual_eq=frames-presents-drops "
        f"drops_src=av_pacer_only tag={meta.get('residual_tag', 'NO-DATA')}"
    )
    print(
        f"frames={meta.get('frames')} presents={meta.get('presents')} "
        f"drops={meta.get('drops')} publish_misses={meta.get('publish_misses')}"
    )
    print(f"continuity={meta.get('continuity')} tag=measured")
    print(f"probes={meta.get('probes')}")
    print(f"n_media_hits={meta.get('n_media_hits')} tag=measured")
    print(f"VERDICT={r.cls} gate_rc={gate_rc(r.cls)}")
    print("NOTE rc=77 is never a pass; starved_unknown is hard rc=4 not 77")


# --- parent archived fixtures (caller_supplied numbers from silicon) -------------

FIXTURE_COLLAPSED = """\
media: frames=10 presents=8 drops=2 publish_misses=0 residual=0 audio_s=1.000 wall_s=1.400 pfps=12.9 session_epoch=100.1 process_epoch=100 pid=9000
media: frames=3150 presents=2120 drops=1030 publish_misses=0 residual=0 audio_s=175.3 wall_s=244.6 pfps=12.9 session_epoch=100.1 process_epoch=100 pid=9000 av_drift_ms=133
"""

FIXTURE_HEALTHY = """\
media: frames=10 presents=9 drops=1 publish_misses=0 residual=0 audio_s=1.000 wall_s=1.010 pfps=23.5 session_epoch=200.1 process_epoch=200 pid=9100
media: frames=1170 presents=1157 drops=13 publish_misses=0 residual=0 audio_s=49.4 wall_s=49.8 pfps=23.5 session_epoch=200.1 process_epoch=200 pid=9100 av_drift_ms=-30
"""

FIXTURE_HEALTHY2 = """\
media: frames=100 presents=98 drops=2 publish_misses=0 audio_s=10.0 wall_s=10.2 session_epoch=201.1 process_epoch=201 pid=9101
media: frames=3840 presents=3791 drops=49 publish_misses=0 audio_s=162.6 wall_s=166.4 pfps=23.1 session_epoch=201.1 process_epoch=201 pid=9101 av_drift_ms=-30
"""

FIXTURE_RESPAWN = """\
media: frames=500 presents=480 drops=20 audio_s=20.0 wall_s=20.5 session_epoch=300.1 process_epoch=300 pid=9200
media: frames=10 presents=9 drops=1 audio_s=0.5 wall_s=0.6 session_epoch=300.2 process_epoch=301 pid=9201
media: frames=100 presents=90 drops=10 audio_s=5.0 wall_s=5.2 session_epoch=300.2 process_epoch=301 pid=9201
"""

# Parent collapse transport probes (verbatim shape)
PROBES_TRANSPORT = {
    "ffmpeg_in_pipe_write": False,
    "daemon_in_pipe_read": True,
    "recv_q": 0,
    "sock_Bps": 50000,
    "note": "parent: ZERO pipe_write; daemon pipe_read; recv_q=0 9/10",
}


def self_test() -> int:
    fails = 0

    def check(cond: bool, msg: str) -> None:
        nonlocal fails
        if not cond:
            print(f"FAIL {msg}", file=sys.stderr)
            fails += 1
        else:
            print(f"PASS {msg}")

    # collapsed cumulative
    r, meta = score_text(
        FIXTURE_COLLAPSED, ok_min=0.90, ok_min_src=OK_MIN_SRC_DEFAULT, probes={}
    )
    check(r.cls == "starved_unknown", f"collapsed no-probe → unknown got {r.cls}")
    check(gate_rc(r.cls) == 4, f"collapsed rc=4 got {gate_rc(r.cls)}")
    check(r.supply_ratio is not None and r.supply_ratio < 0.72, f"ratio={r.supply_ratio}")
    check(r.ok_min_src == "DEFAULT_ASSUMED", "ok_min labelled DEFAULT_ASSUMED")

    r2, _ = score_text(
        FIXTURE_COLLAPSED,
        ok_min=0.90,
        ok_min_src=OK_MIN_SRC_DEFAULT,
        probes=PROBES_TRANSPORT,
    )
    check(r2.cls == "starved_transport", f"collapsed+probes → transport got {r2.cls}")
    check(gate_rc(r2.cls) == 2, f"transport rc=2 got {gate_rc(r2.cls)}")

    rh, mh = score_text(
        FIXTURE_HEALTHY, ok_min=0.90, ok_min_src=OK_MIN_SRC_DEFAULT, probes={}
    )
    check(rh.cls == "ok", f"healthy1 → ok got {rh.cls}")
    check(gate_rc(rh.cls) == 0, "healthy1 rc=0")
    check(mh.get("residual") == 0, f"healthy residual {mh.get('residual')}")

    rh2, _ = score_text(
        FIXTURE_HEALTHY2, ok_min=0.90, ok_min_src=OK_MIN_SRC_DEFAULT, probes={}
    )
    check(rh2.cls == "ok", f"healthy2 → ok got {rh2.cls}")

    ri, mi = score_text(
        FIXTURE_RESPAWN, ok_min=0.90, ok_min_src=OK_MIN_SRC_DEFAULT, probes={}
    )
    check(ri.cls == "SESSION_INVALID", f"respawn → INVALID got {ri.cls}")
    check(gate_rc(ri.cls) == 79, "respawn rc=79")
    check("changed" in str(mi.get("continuity", "")), f"continuity {mi.get('continuity')}")

    # consumer
    rc, _ = score_text(
        FIXTURE_COLLAPSED,
        ok_min=0.90,
        ok_min_src=OK_MIN_SRC_DEFAULT,
        probes={"ffmpeg_in_pipe_write": True},
    )
    check(rc.cls == "starved_consumer", f"pipe_write → consumer got {rc.cls}")
    check(gate_rc(rc.cls) == 3, "consumer rc=3")

    if fails:
        print(f"self_test FAIL count={fails}", file=sys.stderr)
        return 1
    print("self_test OK red-before-green (collapsed unknown/transport, healthy ok, respawn 79)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("log", nargs="?", help="daemon log path")
    ap.add_argument("--probes", help="JSON probe file (recv_q, wchan, …)")
    ap.add_argument("--ok-min", type=float, default=OK_MIN_DEFAULT)
    ap.add_argument(
        "--ok-min-src",
        default=OK_MIN_SRC_DEFAULT,
        help="DEFAULT_ASSUMED unless conf/env override",
    )
    ap.add_argument(
        "--self-test",
        action="store_true",
        help="run embedded parent fixture red-before-green (no device)",
    )
    ap.add_argument(
        "--expect",
        choices=("ok", "starved_transport", "starved_consumer", "starved_unknown",
                 "SESSION_INVALID", "NO-DATA"),
        help="if set, rc=1 when locus class mismatches (still prints real class)",
    )
    args = ap.parse_args()

    if args.ok_min == OK_MIN_DEFAULT and args.ok_min_src == OK_MIN_SRC_DEFAULT:
        ok_src = OK_MIN_SRC_DEFAULT
    else:
        ok_src = args.ok_min_src if args.ok_min_src != OK_MIN_SRC_DEFAULT else "caller_supplied"

    if args.self_test:
        return self_test()

    if not args.log:
        print("usage: score_supply_starve.py LOG [--probes P.json] | --self-test", file=sys.stderr)
        return 77

    text = Path(args.log).read_text(errors="replace")
    probes = load_probes(args.probes)
    r, meta = score_text(text, ok_min=args.ok_min, ok_min_src=ok_src, probes=probes)
    print_report(r, meta)
    rc = gate_rc(r.cls)
    if args.expect and r.cls != args.expect:
        print(f"EXPECT_MISS expected={args.expect} got={r.cls}", file=sys.stderr)
        return 1 if rc == 0 else rc
    return rc


if __name__ == "__main__":
    sys.exit(main())
