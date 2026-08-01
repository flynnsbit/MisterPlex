#!/usr/bin/env python3
"""Analyze MrAudio handoff snaps (host-only).

Parses daemon log lines produced by media_player handoff instrumentation:
  media: MrAudio handoff_at=audio_release|first_video_present ...
  media: MrAudio ring_at_open ...
  media: MrAudio ring_after_first_write ...
  media: MrAudio early_traj chunk=N ...

Optional: pair two runs and test whether ring pointers differ by a
*caller-supplied* separation (--sep-ms). There is NO default lab separation:
the former 117.10 ms default was an OLD-argv instrument artifact and was
deleted. Pass --sep-ms explicitly when testing a hypothesis.

Pre-registered prediction templates (sep is caller_supplied only):
  P-RPTR: opposite groups differ in absolute rptr (or wptr) by
          sep_ms × 192000 B/s at the same handoff_at tag,
          while len_B stays within ~5 ms (960 B).
  P-FDONE: frames_done lag differs by N display frames
           (T_disp = 638×524/20e6 = 16.715600 ms from RTL literals).
  Kill either: snaps identical across groups within noise.

Every printed quantity is tagged measured | caller_supplied | DEFAULT_ASSUMED.

Exit codes (never through a pipe):
  0  = analysis completed; no pre-registered kill fired (or --self-test PASS)
  2  = analysis completed AND a prediction is REJECTED by the data
  77 = could-not-measure (no snaps, missing files, missing --sep-ms when required)
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

# host/libmisterplex/mraudio_status.hpp
BYTES_PER_SEC = 48000 * 4  # 192000 — s16le stereo @ 48 kHz
# No default sep: OLD 117.10 was retracted (instrument artifact). Require --sep-ms.
DEFAULT_SEP_MS = None
# colorbars.sv H_LAST=637 → 638 clocks/line; NTSC scandouble vc wrap 523 → 524 lines;
# clk_sys 20 MHz (pll). T_disp = 638*524/20e6 s.
T_DISP_MS = (638 * 524) / 20_000_000.0 * 1000.0  # 16.715600 ms
DEFAULT_LEN_MATCH_MS = 5.0  # parent held_ms noise class
DEFAULT_RPTR_TOL_FRAC = 0.20  # ±20% on 22483 B band

RC_OK = 0
RC_REJECT = 2
RC_UNSCORED = 77

HANDOFF_RE = re.compile(
    r"MrAudio\s+handoff_at=(?P<where>\S+)"
    r".*?\bmono_ms=(?P<mono>-?\d+)"
    r".*?\brptr=(?P<rptr>-?\d+)"
    r".*?\bwptr=(?P<wptr>-?\d+)"
    r".*?\blen_B=(?P<len_b>-?\d+)"
    r"(?:.*?\blen_ms=(?P<len_ms>-?\d+))?"
    r"(?:.*?\bcomp=(?P<comp>-?\d+))?"
    r"(?:.*?\bframes_done=(?P<fdone>\S+))?"
    r"(?:.*?\bwritten_B=(?P<written>-?\d+))?"
)

RING_RE = re.compile(
    r"MrAudio\s+(?P<kind>ring_at_open|ring_after_first_write)"
    r".*?\bmono_ms=(?P<mono>-?\d+)"
    r".*?\brptr=(?P<rptr>-?\d+)"
    r".*?\bwptr=(?P<wptr>-?\d+)"
    r".*?\blen_B=(?P<len_b>-?\d+)"
)

EARLY_RE = re.compile(
    r"MrAudio\s+early_traj\s+chunk=(?P<chunk>\d+)"
    r".*?\bmono_ms=(?P<mono>-?\d+)"
    r".*?\brptr=(?P<rptr>-?\d+)"
    r".*?\bwptr=(?P<wptr>-?\d+)"
    r".*?\blen_B=(?P<len_b>-?\d+)"
)


def _i(s: Optional[str]) -> Optional[int]:
    if s is None or s in ("", "NO-DATA", "UNREADABLE", "-1"):
        return None
    try:
        return int(s)
    except ValueError:
        return None


@dataclass
class Snap:
    kind: str  # handoff_at=... | ring_at_open | ...
    where: str
    mono_ms: Optional[int] = None
    rptr: Optional[int] = None
    wptr: Optional[int] = None
    len_b: Optional[int] = None
    len_ms: Optional[int] = None
    comp: Optional[int] = None
    frames_done: Optional[int] = None
    written_b: Optional[int] = None
    line_no: int = 0
    raw: str = ""


@dataclass
class RunSnaps:
    run_id: str
    snaps: List[Snap] = field(default_factory=list)
    cluster: Optional[str] = None  # "A" | "B" | None
    offset_ms: Optional[float] = None  # HDMI median if parent supplied


def parse_log_text(text: str, run_id: str = "run") -> RunSnaps:
    out = RunSnaps(run_id=run_id)
    for i, line in enumerate(text.splitlines(), 1):
        m = HANDOFF_RE.search(line)
        if m:
            fd = m.group("fdone")
            fdi = _i(fd) if fd and fd not in ("NO-DATA", "UNREADABLE") else None
            out.snaps.append(
                Snap(
                    kind="handoff",
                    where=m.group("where"),
                    mono_ms=_i(m.group("mono")),
                    rptr=_i(m.group("rptr")),
                    wptr=_i(m.group("wptr")),
                    len_b=_i(m.group("len_b")),
                    len_ms=_i(m.group("len_ms")),
                    comp=_i(m.group("comp")),
                    frames_done=fdi,
                    written_b=_i(m.group("written")),
                    line_no=i,
                    raw=line.strip(),
                )
            )
            continue
        m = RING_RE.search(line)
        if m:
            out.snaps.append(
                Snap(
                    kind=m.group("kind"),
                    where=m.group("kind"),
                    mono_ms=_i(m.group("mono")),
                    rptr=_i(m.group("rptr")),
                    wptr=_i(m.group("wptr")),
                    len_b=_i(m.group("len_b")),
                    line_no=i,
                    raw=line.strip(),
                )
            )
            continue
        m = EARLY_RE.search(line)
        if m:
            out.snaps.append(
                Snap(
                    kind="early_traj",
                    where=f"early_traj_{m.group('chunk')}",
                    mono_ms=_i(m.group("mono")),
                    rptr=_i(m.group("rptr")),
                    wptr=_i(m.group("wptr")),
                    len_b=_i(m.group("len_b")),
                    line_no=i,
                    raw=line.strip(),
                )
            )
    return out


def first_snap(run: RunSnaps, where: str) -> Optional[Snap]:
    for s in run.snaps:
        if s.where == where or s.kind == where:
            return s
    return None


def ptr_delta_bytes(a: Optional[int], b: Optional[int], ring: int = 512 * 1024) -> Optional[int]:
    """Minimal absolute distance on a circular ring (bytes)."""
    if a is None or b is None:
        return None
    d = abs(a - b) % ring
    return min(d, ring - d)


def analyze_pair(
    run_a: RunSnaps,
    run_b: RunSnaps,
    *,
    sep_ms: float,
    len_match_ms: float,
    rptr_tol_frac: float,
    where: str = "audio_release",
) -> Dict[str, Any]:
    sa = first_snap(run_a, where)
    sb = first_snap(run_b, where)
    expect_b = sep_ms * BYTES_PER_SEC / 1000.0
    len_match_b = len_match_ms * BYTES_PER_SEC / 1000.0
    out: Dict[str, Any] = {
        "where": where,
        "expect_rptr_delta_B": expect_b,
        "expect_rptr_delta_B_src": "caller_supplied_sep_ms * measured_format_192000",
        "sep_ms": sep_ms,
        "sep_ms_src": "caller_supplied",
        "T_disp_ms": T_DISP_MS,
        "T_disp_ms_src": "measured_from_RTL_constants",  # formula from cited params
        "n_frames_for_sep": sep_ms / T_DISP_MS if T_DISP_MS else None,
    }
    if sa is None or sb is None:
        out["status"] = "could-not-measure"
        out["reason"] = f"missing handoff snap where={where}"
        out["rc"] = RC_UNSCORED
        out["P_RPTR"] = {"verdict": "UNSCORED", "verdict_src": "could-not-measure"}
        out["P_FDONE"] = {"verdict": "UNSCORED", "verdict_src": "could-not-measure"}
        out["delta_rptr_B"] = None
        out["delta_wptr_B"] = None
        out["delta_len_B"] = None
        out["delta_rptr_B_src"] = "could-not-measure"
        out["delta_wptr_B_src"] = "could-not-measure"
        out["delta_len_B_src"] = "could-not-measure"
        return out

    dr = ptr_delta_bytes(sa.rptr, sb.rptr)
    dw = ptr_delta_bytes(sa.wptr, sb.wptr)
    dlen = None
    if sa.len_b is not None and sb.len_b is not None:
        dlen = abs(sa.len_b - sb.len_b)

    out["run_a"] = {
        "id": run_a.run_id,
        "cluster": run_a.cluster,
        "rptr": sa.rptr,
        "wptr": sa.wptr,
        "len_B": sa.len_b,
        "frames_done": sa.frames_done,
        "mono_ms": sa.mono_ms,
    }
    out["run_b"] = {
        "id": run_b.run_id,
        "cluster": run_b.cluster,
        "rptr": sb.rptr,
        "wptr": sb.wptr,
        "len_B": sb.len_b,
        "frames_done": sb.frames_done,
        "mono_ms": sb.mono_ms,
    }
    out["delta_rptr_B"] = dr
    out["delta_wptr_B"] = dw
    out["delta_len_B"] = dlen
    out["delta_rptr_B_src"] = "measured" if dr is not None else "could-not-measure"
    out["delta_wptr_B_src"] = "measured" if dw is not None else "could-not-measure"
    out["delta_len_B_src"] = "measured" if dlen is not None else "could-not-measure"

    # P-RPTR
    lo = expect_b * (1.0 - rptr_tol_frac)
    hi = expect_b * (1.0 + rptr_tol_frac)
    len_ok = dlen is not None and dlen <= len_match_b
    rptr_in_band = dr is not None and lo <= dr <= hi
    wptr_in_band = dw is not None and lo <= dw <= hi
    ptr_in_band = bool(rptr_in_band or wptr_in_band)
    snaps_identical = (
        dr is not None
        and dr <= 64  # one stereo sample noise floor
        and dw is not None
        and dw <= 64
        and len_ok
    )

    out["P_RPTR"] = {
        "band_B": [lo, hi],
        "rptr_in_band": rptr_in_band,
        "wptr_in_band": wptr_in_band,
        "len_match": len_ok,
        "snaps_identical": snaps_identical,
    }
    if snaps_identical:
        out["P_RPTR"]["verdict"] = "REJECTED_identical_snaps"
        out["P_RPTR"]["verdict_src"] = "measured"
    elif ptr_in_band and len_ok:
        out["P_RPTR"]["verdict"] = "SUPPORTED"
        out["P_RPTR"]["verdict_src"] = "measured"
    elif dr is None and dw is None:
        out["P_RPTR"]["verdict"] = "UNSCORED"
        out["P_RPTR"]["verdict_src"] = "could-not-measure"
    else:
        out["P_RPTR"]["verdict"] = "INCONCLUSIVE_out_of_band"
        out["P_RPTR"]["verdict_src"] = "measured"

    # P-FDONE: need frames_done at two tags within each run
    def fdone_lag(run: RunSnaps) -> Optional[int]:
        r = first_snap(run, "audio_release")
        p = first_snap(run, "first_video_present")
        if not r or not p or r.frames_done is None or p.frames_done is None:
            return None
        return p.frames_done - r.frames_done

    la, lb = fdone_lag(run_a), fdone_lag(run_b)
    out["frames_done_lag_a"] = la
    out["frames_done_lag_b"] = lb
    out["frames_done_lag_a_src"] = "measured" if la is not None else "could-not-measure"
    out["frames_done_lag_b_src"] = "measured" if lb is not None else "could-not-measure"
    if la is not None and lb is not None:
        dfd = abs(la - lb)
        out["delta_frames_done_lag"] = dfd
        out["delta_frames_done_lag_src"] = "measured"
        # 7 frames is the arithmetic target; accept 6..8
        if dfd in (6, 7, 8):
            out["P_FDONE"] = {"verdict": "SUPPORTED", "verdict_src": "measured", "delta_N": dfd}
        elif dfd == 0:
            out["P_FDONE"] = {
                "verdict": "REJECTED_identical_lag",
                "verdict_src": "measured",
                "delta_N": dfd,
            }
        else:
            out["P_FDONE"] = {
                "verdict": "INCONCLUSIVE_other_N",
                "verdict_src": "measured",
                "delta_N": dfd,
            }
    else:
        out["P_FDONE"] = {"verdict": "UNSCORED", "verdict_src": "could-not-measure"}

    # RC: 2 only on hard REJECTED; 77 if nothing measurable; 0 otherwise
    verdicts = [out["P_RPTR"]["verdict"], out["P_FDONE"]["verdict"]]
    if all(v == "UNSCORED" for v in verdicts):
        out["rc"] = RC_UNSCORED
        out["status"] = "could-not-measure"
    elif any(v.startswith("REJECTED") for v in verdicts):
        out["rc"] = RC_REJECT
        out["status"] = "prediction_rejected"
    else:
        out["rc"] = RC_OK
        out["status"] = "analyzed"
    return out


def load_cluster_map(path: Optional[Path]) -> Dict[str, Dict[str, Any]]:
    """JSON: { "run_id": {"cluster": "A"|"B", "offset_ms": float}, ... }"""
    if path is None:
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("cluster map must be a JSON object")
    return data


def self_test() -> int:
    """Synthetic logs: SUPPORT rptr band, REJECT identical, UNSCORED empty."""
    fails = 0

    def check(cond: bool, msg: str) -> None:
        nonlocal fails
        if not cond:
            print(f"FAIL {msg}", file=sys.stderr)
            fails += 1
        else:
            print(f"PASS {msg}")

    # Support: Δrptr = 22464, len match
    log_a = (
        "media: MrAudio handoff_at=audio_release mono_ms=1000 rptr=10000 wptr=29200 "
        "len_B=19200 len_ms=100 comp=0 frames_done=0 written_B=0 tag=measured\n"
        "media: MrAudio handoff_at=first_video_present mono_ms=1080 rptr=12000 wptr=31200 "
        "len_B=19200 len_ms=100 comp=0 frames_done=1 written_B=3840 tag=measured\n"
    )
    log_b = (
        "media: MrAudio handoff_at=audio_release mono_ms=2000 rptr=32464 wptr=51664 "
        "len_B=19200 len_ms=100 comp=0 frames_done=0 written_B=0 tag=measured\n"
        "media: MrAudio handoff_at=first_video_present mono_ms=2200 rptr=36000 wptr=55200 "
        "len_B=19200 len_ms=100 comp=0 frames_done=8 written_B=3840 tag=measured\n"
    )
    ra, rb = parse_log_text(log_a, "a"), parse_log_text(log_b, "b")
    ra.cluster, rb.cluster = "A", "B"
    r = analyze_pair(ra, rb, sep_ms=100.0, len_match_ms=5.0, rptr_tol_frac=0.20)
    check(r["P_RPTR"]["verdict"] == "SUPPORTED", f"P_RPTR SUPPORT got {r['P_RPTR']['verdict']}")
    check(r["P_FDONE"]["verdict"] == "SUPPORTED", f"P_FDONE SUPPORT got {r['P_FDONE']['verdict']}")
    check(r["rc"] == RC_OK, f"rc OK got {r['rc']}")

    # Reject identical
    r2 = analyze_pair(ra, ra, sep_ms=100.0, len_match_ms=5.0, rptr_tol_frac=0.20)
    check(
        r2["P_RPTR"]["verdict"] == "REJECTED_identical_snaps",
        f"identical reject got {r2['P_RPTR']['verdict']}",
    )
    check(r2["rc"] == RC_REJECT, f"rc REJECT got {r2['rc']}")

    # Unscored empty
    empty = parse_log_text("no handoff here\n", "e")
    r3 = analyze_pair(empty, empty, sep_ms=100.0, len_match_ms=5.0, rptr_tol_frac=0.20)
    check(r3["rc"] == RC_UNSCORED, f"empty UNSCORED got {r3['rc']}")

    # Parse ring_at_open
    ring = parse_log_text(
        "media: MrAudio ring_at_open mono_ms=1 rptr=0 wptr=0 len_B=0 len_ms=0 comp=0 raw=\"x\" tag=measured\n",
        "r",
    )
    check(len(ring.snaps) == 1 and ring.snaps[0].kind == "ring_at_open", "parse ring_at_open")

    print(f"T_disp_ms={T_DISP_MS:.6f} src=measured_from_RTL_constants")
    print(f"7*T_disp_ms={7 * T_DISP_MS:.6f} src=derived_from_RTL_literals_not_lab_sep")
    print(f"expect_B_at_100.0ms={100.0 * BYTES_PER_SEC / 1000.0:.1f} src=caller_supplied*format")

    if fails:
        print(f"SELF_TEST_FAIL fails={fails}")
        return RC_REJECT
    print("SELF_TEST_OK")
    return RC_OK


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--log", action="append", default=[], help="daemon log file (repeatable)")
    ap.add_argument(
        "--log-pair",
        nargs=2,
        action="append",
        default=[],
        metavar=("LOG_A", "LOG_B"),
        help="explicit opposite-cluster log pair",
    )
    ap.add_argument(
        "--cluster-map",
        type=Path,
        default=None,
        help="JSON map run_id -> {cluster, offset_ms}",
    )
    ap.add_argument("--sep-ms", type=float, default=None, help="caller_supplied sep ms (required for pair analysis; no default)")
    ap.add_argument("--len-match-ms", type=float, default=DEFAULT_LEN_MATCH_MS)
    ap.add_argument("--rptr-tol-frac", type=float, default=DEFAULT_RPTR_TOL_FRAC)
    ap.add_argument(
        "--where",
        default="audio_release",
        help="handoff_at tag to compare (default audio_release)",
    )
    ap.add_argument("--json-out", type=Path, default=None)
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    cmap = load_cluster_map(args.cluster_map)
    results: List[Dict[str, Any]] = []
    rc = RC_UNSCORED

    pairs: List[Tuple[RunSnaps, RunSnaps]] = []

    for path_a, path_b in args.log_pair:
        ta = Path(path_a).read_text(encoding="utf-8", errors="replace")
        tb = Path(path_b).read_text(encoding="utf-8", errors="replace")
        ra = parse_log_text(ta, Path(path_a).name)
        rb = parse_log_text(tb, Path(path_b).name)
        if ra.run_id in cmap:
            ra.cluster = cmap[ra.run_id].get("cluster")
            ra.offset_ms = cmap[ra.run_id].get("offset_ms")
        if rb.run_id in cmap:
            rb.cluster = cmap[rb.run_id].get("cluster")
            rb.offset_ms = cmap[rb.run_id].get("offset_ms")
        pairs.append((ra, rb))

    # Single multi-run log: split on session markers if present; else one run
    for path in args.log:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        # Split on audio_release as session starts (each cast)
        parts = re.split(r"(?=media: A/V audio_release )", text)
        runs: List[RunSnaps] = []
        for i, part in enumerate(parts):
            if "MrAudio" not in part and "handoff_at" not in part:
                continue
            rid = f"{Path(path).name}#{i}"
            r = parse_log_text(part, rid)
            if r.snaps:
                runs.append(r)
        # Pair consecutive A/B if cluster map says so; else all pairs of runs with snaps
        if len(runs) < 2:
            print(f"log={path} runs_with_snaps={len(runs)} src=measured")
            continue
        # Prefer pairing by cluster map labels if available
        labeled = [r for r in runs if r.run_id in cmap]
        if len(labeled) >= 2:
            as_ = [r for r in labeled if cmap[r.run_id].get("cluster") == "A"]
            bs_ = [r for r in labeled if cmap[r.run_id].get("cluster") == "B"]
            for a in as_:
                a.cluster = "A"
                a.offset_ms = cmap[a.run_id].get("offset_ms")
                for b in bs_:
                    b.cluster = "B"
                    b.offset_ms = cmap[b.run_id].get("offset_ms")
                    pairs.append((a, b))
        else:
            # All unique pairs — parent still gets numbers; no cluster claim
            for i in range(len(runs)):
                for j in range(i + 1, len(runs)):
                    pairs.append((runs[i], runs[j]))

    if not pairs:
        print("VERDICT=UNSCORED rc=77 reason=no_log_pairs src=could-not-measure")
        print(
            "need --log-pair A.log B.log (opposite clusters) or --log with handoff lines"
        )
        return RC_UNSCORED

    if args.sep_ms is None:
        print("VERDICT=UNSCORED rc=77 reason=missing_sep_ms src=could-not-measure")
        print("pass --sep-ms explicitly; DEFAULT 117.10 was retracted (OLD-argv artifact)")
        return RC_UNSCORED

    print("=== analyze_mraudio_handoff ===")
    print(f"sep_ms={args.sep_ms} src=caller_supplied")
    print(f"expect_rptr_delta_B={args.sep_ms * BYTES_PER_SEC / 1000.0:.1f} src=caller_supplied*format")
    print(f"T_disp_ms={T_DISP_MS:.6f} src=measured_from_RTL_constants")
    print(f"7*T_disp_ms={7 * T_DISP_MS:.6f} src=derived_from_RTL_literals_not_lab_sep")
    print(f"n_pairs={len(pairs)} src=measured")

    worst_rc = RC_OK
    any_measured = False
    for ra, rb in pairs:
        r = analyze_pair(
            ra,
            rb,
            sep_ms=args.sep_ms,
            len_match_ms=args.len_match_ms,
            rptr_tol_frac=args.rptr_tol_frac,
            where=args.where,
        )
        results.append(r)
        print(
            f"pair {ra.run_id}({ra.cluster}) vs {rb.run_id}({rb.cluster}) "
            f"where={r['where']} status={r['status']} rc={r['rc']}"
        )
        print(
            f"  delta_rptr_B={r.get('delta_rptr_B')} src={r.get('delta_rptr_B_src')} "
            f"delta_wptr_B={r.get('delta_wptr_B')} src={r.get('delta_wptr_B_src')} "
            f"delta_len_B={r.get('delta_len_B')} src={r.get('delta_len_B_src')}"
        )
        print(
            f"  P_RPTR={r['P_RPTR'].get('verdict')} src={r['P_RPTR'].get('verdict_src')} "
            f"P_FDONE={r['P_FDONE'].get('verdict')} src={r['P_FDONE'].get('verdict_src')}"
        )
        if r["rc"] != RC_UNSCORED:
            any_measured = True
        if r["rc"] == RC_REJECT:
            worst_rc = RC_REJECT
        elif r["rc"] == RC_UNSCORED and worst_rc == RC_OK and not any_measured:
            worst_rc = RC_UNSCORED

    if not any_measured:
        worst_rc = RC_UNSCORED

    print(f"VERDICT_RC={worst_rc} src=measured")
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps({"results": results}, indent=2), encoding="utf-8")
        print(f"json_out={args.json_out} src=measured")

    return worst_rc


if __name__ == "__main__":
    sys.exit(main())
